#include "include/heming_platform/heming_platform_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "heming_platform_plugin.h"

void HemingPlatformPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  heming_platform::HemingPlatformPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
