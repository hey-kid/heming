#pragma once
#include <flutter/encodable_value.h>
#include <atomic>
#include <string>

namespace heming_platform {
flutter::EncodableValue InspectMedia(const std::string& path);
void ExtractAudio(const std::string& input, const std::string& output,
                  const std::atomic<bool>& cancel);
}
