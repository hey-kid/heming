#include "heming_platform_plugin.h"
#include "media_decoder.h"
#include <flutter/standard_method_codec.h>

namespace heming_platform {
namespace {
constexpr UINT kComplete = WM_APP + 142;
constexpr UINT kOutputChange = WM_APP + 143;
using V = flutter::EncodableValue;
using Result = flutter::MethodResult<V>;
std::string Argument(const flutter::MethodCall<V>& call, const char* key) {
  if (!call.arguments()) throw std::runtime_error("Missing arguments");
  const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!map) throw std::runtime_error("Invalid arguments");
  const auto found = map->find(V(key));
  if (found == map->end() || !std::holds_alternative<std::string>(found->second))
    throw std::runtime_error("Missing path");
  return std::get<std::string>(found->second);
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

