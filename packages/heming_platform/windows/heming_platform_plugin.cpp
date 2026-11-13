#include "heming_platform_plugin.h"
#include "media_decoder.h"
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>
#include <algorithm>
#include <cwctype>
#include <string>

namespace heming_platform {
namespace {
constexpr UINT kComplete = WM_APP + 142;
constexpr UINT kOutputChange = WM_APP + 143;
using V = flutter::EncodableValue;
using Result = flutter::MethodResult<V>;

flutter::EncodableList DefaultMediaFolders() {
  flutter::EncodableList folders;
  std::vector<std::wstring> resolved;
  const KNOWNFOLDERID* ids[] = {
      &FOLDERID_Music, &FOLDERID_Videos, &FOLDERID_Downloads};
  for (const auto* id : ids) {
    PWSTR raw_path = nullptr;
    // Resolve the user's current (possibly redirected) folder, without creating
    // or probing it. Dart enumerates existing, accessible locations off the UI.
    const HRESULT status = SHGetKnownFolderPath(
        *id, KF_FLAG_DONT_VERIFY, nullptr, &raw_path);
    std::wstring path;
    if (SUCCEEDED(status) && raw_path) path = raw_path;
    CoTaskMemFree(raw_path);
    if (path.empty()) continue;
    while (path.size() > 3 && (path.back() == L'\\' || path.back() == L'/')) {
      path.pop_back();
    }
    bool duplicate = false;
    for (const auto& previous : resolved) {
      if (CompareStringOrdinal(path.c_str(), -1, previous.c_str(), -1, TRUE) ==
          CSTR_EQUAL) {
        duplicate = true;
        break;
      }
    }
    if (duplicate) continue;
    const int length = static_cast<int>(path.size());
    const int bytes = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, path.data(), length, nullptr, 0,
        nullptr, nullptr);
    if (bytes <= 0) continue;
    std::string utf8(static_cast<size_t>(bytes), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.data(), length,
                           utf8.data(), bytes, nullptr, nullptr) != bytes) {
      continue;
    }
    resolved.push_back(path);
    folders.emplace_back(utf8);
  }
  return folders;
}

std::string Argument(const flutter::MethodCall<V>& call, const char* key) {
  if (!call.arguments()) throw std::runtime_error("Missing arguments");
  const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!map) throw std::runtime_error("Invalid arguments");
  const auto found = map->find(V(key));
  if (found == map->end() || !std::holds_alternative<std::string>(found->second))
    throw std::runtime_error("Missing path");
  return std::get<std::string>(found->second);
}

// Only a local, existing media document is accepted. No command lines, URI
// schemes, device paths, alternate data streams or shell names reach the shell.
std::wstring LocalMediaPath(const std::string& value) {
  if (value.empty() || value.find('\0') != std::string::npos || value.size() > 32767)
    throw std::runtime_error("Invalid media path");
  const int chars = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (chars <= 0) throw std::runtime_error("Invalid media path");
  std::wstring path(static_cast<size_t>(chars), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), path.data(), chars) != chars)
    throw std::runtime_error("Invalid media path");
  std::replace(path.begin(), path.end(), L'/', L'\\');
  if (path.size() < 4 || !((path[0] >= L'A' && path[0] <= L'Z') ||
      (path[0] >= L'a' && path[0] <= L'z')) || path[1] != L':' || path[2] != L'\\' ||
      path.find(L':', 2) != std::wstring::npos ||
      path.find_first_of(L"\r\n\"<>|?*") != std::wstring::npos)
    throw std::runtime_error("Invalid media path");
  const DWORD length = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
  if (length == 0 || length > 32768) throw std::runtime_error("Invalid media path");
  std::wstring full(length, L'\0');
  const DWORD written = GetFullPathNameW(path.c_str(), length, full.data(), nullptr);
  if (written == 0 || written >= length) throw std::runtime_error("Invalid media path");
  full.resize(written);
  const std::wstring drive = full.substr(0, 3);
  const UINT drive_type = GetDriveTypeW(drive.c_str());
  if (drive_type == DRIVE_REMOTE || drive_type == DRIVE_UNKNOWN ||
      drive_type == DRIVE_NO_ROOT_DIR)
    throw std::runtime_error("Only local media files can be opened");
  const DWORD attributes = GetFileAttributesW(full.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_DEVICE)))
    throw std::runtime_error("Media file does not exist");
  const auto dot = full.find_last_of(L'.');
  const auto slash = full.find_last_of(L'\\');
  if (dot == std::wstring::npos || dot <= slash) throw std::runtime_error("Not a media file");
  auto extension = full.substr(dot);
  std::transform(extension.begin(), extension.end(), extension.begin(),
      [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  const std::vector<std::wstring> extensions = {
      L".mp3", L".flac", L".wav", L".m4a", L".aac", L".ogg", L".opus", L".wma",
      L".aiff", L".aif", L".alac", L".amr", L".ape", L".ac3", L".caf", L".m4b",
      L".mp4", L".mkv", L".mov", L".webm", L".avi", L".m4v", L".wmv", L".3gp",
      L".3g2", L".mpeg", L".mpg", L".ts", L".mts", L".m2ts", L".flv", L".vob"};
  if (std::find(extensions.begin(), extensions.end(), extension) == extensions.end())
    throw std::runtime_error("Not a media file");
  return full;
}

class ScopedShellCom {
 public:
  ScopedShellCom() : status_(CoInitializeEx(nullptr,
      COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE)) {}
  ~ScopedShellCom() { if (SUCCEEDED(status_)) CoUninitialize(); }
  bool ready() const { return SUCCEEDED(status_) || status_ == RPC_E_CHANGED_MODE; }
 private:
  HRESULT status_;
};

void OpenLocalMedia(const flutter::MethodCall<V>& call, HWND window,
    std::unique_ptr<Result> result) {
  std::wstring path;
  try { path = LocalMediaPath(Argument(call, "locator")); }
  catch (const std::exception&) {
    result->Error("open_arguments", "文件不存在或不是可打开的本地媒体，请刷新列表");
    return;
  }
  ScopedShellCom com;
  if (!com.ready()) {
    result->Error("open_failed", "暂时无法打开文件，请重试");
    return;
  }
  if (call.method_name() == "revealMedia") {
    PIDLIST_ABSOLUTE item = nullptr;
    HRESULT status = SHParseDisplayName(path.c_str(), nullptr, &item, 0, nullptr);
    if (SUCCEEDED(status)) status = SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
    CoTaskMemFree(item);
    if (FAILED(status)) result->Error("open_failed", "无法在文件夹中显示此文件");
    else result->Success();
    return;
  }
  SHELLEXECUTEINFOW info{};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_FLAG_NO_UI;
  info.hwnd = window;
  info.lpVerb = L"open";
  info.lpFile = path.c_str();
  // lpParameters is deliberately null: this is a document, never a command.
  info.nShow = SW_SHOWNORMAL;
  if (!ShellExecuteExW(&info)) {
    const DWORD error = GetLastError();
    result->Error("open_failed", error == ERROR_NO_ASSOCIATION
        ? "没有可打开此文件的默认播放器，请先选择默认应用"
        : "无法打开该媒体，请检查默认播放器或在文件夹中查看");
  } else result->Success();
}
}
class DeviceNotifications final : public IMMNotificationClient {
 public:
  explicit DeviceNotifications(HWND window) : window_(window) {}
  void SetWindow(HWND window) { window_ = window; }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
    if (!out) return E_POINTER;
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IMMNotificationClient)) {
      *out = static_cast<IMMNotificationClient*>(this); AddRef(); return S_OK;
    }
    *out = nullptr; return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG refs = --refs_; if (!refs) delete this; return refs;
  }
  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR) override {
    if (flow == eRender && (role == eConsole || role == eMultimedia)) PostMessage(window_, kOutputChange, 0, 0);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { return S_OK; }
 private:
  std::atomic<ULONG> refs_{1};
  std::atomic<HWND> window_;
};
void HemingPlatformPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<HemingPlatformPlugin>(registrar));
}
HemingPlatformPlugin::HemingPlatformPlugin(flutter::PluginRegistrarWindows* registrar) : registrar_(registrar) {
  channel_ = std::make_unique<flutter::MethodChannel<V>>(registrar->messenger(), "heming_platform",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
  scan_channel_ = std::make_unique<flutter::MethodChannel<V>>(
      registrar->messenger(), "heming_media_scan",
      &flutter::StandardMethodCodec::GetInstance());
  scan_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "defaultFolders") {
      result->Success(V(DefaultMediaFolders()));
    } else if (call.method_name() == "openMedia" || call.method_name() == "revealMedia") {
      const HWND window = registrar_->GetView()
          ? GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT) : window_;
      OpenLocalMedia(call, window, std::move(result));
    } else {
      result->NotImplemented();
    }
  });
  if (registrar->GetView()) {
    window_ = GetAncestor(registrar->GetView()->GetNativeWindow(), GA_ROOT);
    delegate_ = registrar->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT message, WPARAM wp, LPARAM lp) { return WindowProc(hwnd, message, wp, lp); });
    if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&devices_)))) {
      notifications_ = new DeviceNotifications(window_);
      devices_->RegisterEndpointNotificationCallback(notifications_);
    }
  }
}
HemingPlatformPlugin::~HemingPlatformPlugin() {
  closing_ = true; cancel_ = true;
  SetPlaybackActive(false);
  if (notifications_) {
    devices_->UnregisterEndpointNotificationCallback(notifications_);
    notifications_->Release();
  }
  if (delegate_ != -1) registrar_->UnregisterTopLevelWindowProcDelegate(delegate_);
  for (auto& worker : workers_) if (worker.joinable()) worker.join();
  channel_->SetMethodCallHandler(nullptr);
  scan_channel_->SetMethodCallHandler(nullptr);
}
void HemingPlatformPlugin::Emit(const char* event) {
  if (!closing_) channel_->InvokeMethod("onInterruption", std::make_unique<V>(event));
}
DWORD HemingPlatformPlugin::SetPlaybackActive(bool active) {
  if (!active) {
    if (playback_power_request_ != INVALID_HANDLE_VALUE) {
      PowerClearRequest(playback_power_request_, PowerRequestSystemRequired);
      // Closing also cleans up the object if Windows already terminated its
      // request during a user-initiated sleep transition.
      CloseHandle(playback_power_request_);
      playback_power_request_ = INVALID_HANDLE_VALUE;
    }
    return ERROR_SUCCESS;
  }
  // PowerSetRequest increments a reference count. Repeated active updates must
  // not accumulate requests that would outlive the playback task.
  if (playback_power_request_ != INVALID_HANDLE_VALUE) return ERROR_SUCCESS;
  wchar_t reason[] = L"和鸣正在同步播放局域网音频";
  REASON_CONTEXT context{};
  context.Version = POWER_REQUEST_CONTEXT_VERSION;
  context.Flags = POWER_REQUEST_CONTEXT_SIMPLE_STRING;
  context.Reason.SimpleReasonString = reason;
  const HANDLE request = PowerCreateRequest(&context);
  if (request == INVALID_HANDLE_VALUE) return GetLastError();
  // Keep the system working during playback, while allowing the display to turn
  // off and respecting explicit sleep. Do not request display or away mode.
  if (!PowerSetRequest(request, PowerRequestSystemRequired)) {
    const DWORD error = GetLastError();
    CloseHandle(request);
    return error;
  }
  playback_power_request_ = request;
  return ERROR_SUCCESS;
}
std::optional<LRESULT> HemingPlatformPlugin::WindowProc(HWND, UINT message, WPARAM wp, LPARAM) {
  if (message == WM_POWERBROADCAST && wp == PBT_APMSUSPEND) {
    SetPlaybackActive(false);
    Emit("suspending");
  }
  if (message == kOutputChange) Emit("outputChanged");
  if (message == kComplete) {
    std::deque<std::function<void()>> ready;
    { std::lock_guard<std::mutex> lock(completion_mutex_); ready.swap(completions_); }
    for (auto& completion : ready) completion();
    return 0;
  }
  return std::nullopt;
}
void HemingPlatformPlugin::HandleMethodCall(const flutter::MethodCall<V>& call, std::unique_ptr<Result> result) {
  // Plugins are registered before FlutterWindow attaches its child view. Resolve
  // the final top-level HWND here, after Dart starts calling the channel.
  if (registrar_->GetView()) {
    const auto current = GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
    if (current != window_) {
      window_ = current;
      if (notifications_) notifications_->SetWindow(window_);
    }
  }
  const auto& method = call.method_name();
  if (method == "initialize") { result->Success(); return; }
  if (method == "acquireAudioFocus") { result->Success(V(true)); return; }
  if (method == "releaseAudioFocus") { SetPlaybackActive(false); result->Success(); return; }
  if (method == "setPlaybackActive") {
    bool active = false;
    if (call.arguments()) {
      const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
      if (map) { const auto it = map->find(V("active")); active = it != map->end() && it->second == V(true); }
    }
    const DWORD error = SetPlaybackActive(active);
    if (error != ERROR_SUCCESS) {
      result->Error("playback_power_error", "Unable to keep the system awake for playback (" + std::to_string(error) + ")");
      return;
    }
    result->Success(); return;
  }
  if (method == "cancelMediaExtraction") { cancel_ = true; result->Success(); return; }
  if (method == "inspectMedia" || method == "extractAudio") {
    try {
      const bool inspect = method == "inspectMedia";
      auto input = Argument(call, inspect ? "path" : "input");
      auto output = inspect ? std::string() : Argument(call, "output");
      if (!inspect) cancel_ = false;
      auto pending = std::shared_ptr<Result>(std::move(result));
      workers_.emplace_back([this, pending, input, output, inspect] {
        V value;
        std::string error;
        try {
          if (inspect) value = InspectMedia(input);
          else ExtractAudio(input, output, cancel_);
        } catch (const std::exception& failure) { error = failure.what(); }
        if (!closing_) {
          { std::lock_guard<std::mutex> lock(completion_mutex_);
            completions_.push_back([pending, value, error] {
              if (error.empty()) pending->Success(value); else pending->Error("media_error", error);
            });
          }
          PostMessage(window_, kComplete, 0, 0);
        }
      });
    } catch (const std::exception& failure) { if (result) result->Error("media_error", failure.what()); }
    return;
  }
  result->NotImplemented();
}
}

