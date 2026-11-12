#include "media_decoder.h"
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <propvarutil.h>
#include <wrl/client.h>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <vector>

namespace heming_platform {
using Microsoft::WRL::ComPtr;
namespace {
void Check(HRESULT hr) {
  if (FAILED(hr)) throw std::runtime_error("System media decoder failed (" + std::to_string(hr) + ")");
}
std::wstring Wide(const std::string& value) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (!length) throw std::runtime_error("Invalid file path");
  std::wstring out(length, 0);
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), out.data(), length);
  return out;
}
struct MediaRuntime {
  MediaRuntime() { Check(CoInitializeEx(nullptr, COINIT_MULTITHREADED)); Check(MFStartup(MF_VERSION)); }
  ~MediaRuntime() { MFShutdown(); CoUninitialize(); }
};
ComPtr<IMFSourceReader> Open(const std::string& path) {
  ComPtr<IMFSourceReader> reader;
  Check(MFCreateSourceReaderFromURL(Wide(path).c_str(), nullptr, &reader));
  Check(reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE));
  Check(reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), TRUE));
  return reader;
}
void U16(std::ostream& stream, uint16_t n) {
  char value[] = {static_cast<char>(n), static_cast<char>(n >> 8)}; stream.write(value, 2);
}
void U32(std::ostream& stream, uint32_t n) {
  char value[] = {static_cast<char>(n), static_cast<char>(n >> 8), static_cast<char>(n >> 16), static_cast<char>(n >> 24)};
  stream.write(value, 4);
}
}
flutter::EncodableValue InspectMedia(const std::string& path) {
  MediaRuntime runtime;
  auto reader = Open(path);
  ComPtr<IMFMediaType> type;
  Check(reader->GetNativeMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0, &type));
  PROPVARIANT duration;
  PropVariantInit(&duration);
  double seconds = 0;
  if (SUCCEEDED(reader->GetPresentationAttribute(static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION, &duration))) {
    if (duration.vt == VT_UI8) seconds = duration.uhVal.QuadPart / 10000000.0;
  }
  PropVariantClear(&duration);
  using V = flutter::EncodableValue;
  return V(flutter::EncodableMap{
    {V("codec"), V("system audio")},
    {V("sampleRate"), V(static_cast<int32_t>(MFGetAttributeUINT32(type.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 0)))},
    {V("channels"), V(static_cast<int32_t>(MFGetAttributeUINT32(type.Get(), MF_MT_AUDIO_NUM_CHANNELS, 0)))},
    {V("bitsPerSample"), V(static_cast<int32_t>(MFGetAttributeUINT32(type.Get(), MF_MT_AUDIO_BITS_PER_SAMPLE, 0)))},
    {V("durationSeconds"), V(seconds)}});
}
void ExtractAudio(const std::string& input, const std::string& output, const std::atomic<bool>& cancel) {
  const auto input_path = std::filesystem::absolute(Wide(input));
  const auto output_path = std::filesystem::absolute(Wide(output));
  if (input_path == output_path || (std::filesystem::exists(output_path) && std::filesystem::equivalent(input_path, output_path)))
    throw std::runtime_error("Conversion cannot overwrite original");
  MediaRuntime runtime;
  try {
    auto reader = Open(input);
    ComPtr<IMFMediaType> requested;
    Check(MFCreateMediaType(&requested));
    Check(requested->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio));
    Check(requested->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM));
    Check(requested->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16));
    Check(reader->SetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr, requested.Get()));
    ComPtr<IMFMediaType> format;
    Check(reader->GetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), &format));
    const uint32_t rate = MFGetAttributeUINT32(format.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 0);
    const uint32_t channels = MFGetAttributeUINT32(format.Get(), MF_MT_AUDIO_NUM_CHANNELS, 0);
    const uint32_t bits = MFGetAttributeUINT32(format.Get(), MF_MT_AUDIO_BITS_PER_SAMPLE, 0);
    if (!rate || !channels || channels > 32 || bits != 16) throw std::runtime_error("Unsupported PCM output");
    std::ofstream file(output_path, std::ios::binary | std::ios::trunc);
    if (!file) throw std::runtime_error("Cannot create temporary audio file");
    file.exceptions(std::ios::badbit | std::ios::failbit);
    const char empty[44] = {};
    file.write(empty, sizeof(empty));
    uint64_t bytes = 0;
    while (true) {
      if (cancel) throw std::runtime_error("Conversion cancelled");
      DWORD flags = 0;
      ComPtr<IMFSample> sample;
      Check(reader->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0, nullptr, &flags, nullptr, &sample));
      if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) throw std::runtime_error("Audio format changed mid-stream");
      if (sample) {
        ComPtr<IMFMediaBuffer> buffer;
        Check(sample->ConvertToContiguousBuffer(&buffer));
        BYTE* data = nullptr; DWORD length = 0;
        Check(buffer->Lock(&data, nullptr, &length));
        try {
          if (bytes + length > 0xffffffffULL - 44) throw std::runtime_error("Temporary WAV exceeds 4GB limit");
          file.write(reinterpret_cast<const char*>(data), length);
          bytes += length;
        } catch (...) { buffer->Unlock(); throw; }
        Check(buffer->Unlock());
      }
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    }
    if (!bytes) throw std::runtime_error("Audio track contains no decoded samples");
    file.seekp(0);
    file.write("RIFF", 4); U32(file, static_cast<uint32_t>(bytes + 36)); file.write("WAVEfmt ", 8);
    U32(file, 16); U16(file, 1); U16(file, static_cast<uint16_t>(channels)); U32(file, rate);
    U32(file, rate * channels * 2); U16(file, static_cast<uint16_t>(channels * 2)); U16(file, 16);
    file.write("data", 4); U32(file, static_cast<uint32_t>(bytes));
    file.close();
  } catch (...) {
    std::error_code ignored;
    std::filesystem::remove(output_path, ignored);
    throw;
  }
}
}

