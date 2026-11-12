#pragma once
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>
#include <atomic>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace heming_platform {
class DeviceNotifications;
class HemingPlatformPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
  explicit HemingPlatformPlugin(flutter::PluginRegistrarWindows* registrar);
  ~HemingPlatformPlugin() override;
  HemingPlatformPlugin(const HemingPlatformPlugin&) = delete;
  HemingPlatformPlugin& operator=(const HemingPlatformPlugin&) = delete;
 private:
  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Emit(const char* event);
  DWORD SetPlaybackActive(bool active);
  std::optional<LRESULT> WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_ = nullptr;
  int delegate_ = -1;
  HANDLE playback_power_request_ = INVALID_HANDLE_VALUE;
  std::atomic<bool> cancel_{false};
  std::atomic<bool> closing_{false};
  Microsoft::WRL::ComPtr<IMMDeviceEnumerator> devices_;
  DeviceNotifications* notifications_ = nullptr;
  std::mutex completion_mutex_;
  std::deque<std::function<void()>> completions_;
  std::vector<std::thread> workers_;
};
}

