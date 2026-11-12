#include "heming_audio.h"
#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

extern "C" {
void* hm_preview_create_for_testing();
void hm_preview_render_for_testing(void*, float*, uint32_t);
}

static std::string status(void* handle) {
  char* raw = hm_preview_status(handle);
  std::string result(raw);
  hm_free(raw);
  return result;
}
static void expect(void* handle, const std::string& field) {
  const auto actual = status(handle);
  if (actual.find(field) == std::string::npos) {
    std::cerr << "Expected " << field << " in " << actual << '\n';
    assert(false);
  }
}
static void number(std::ofstream& out, uint32_t value, int bytes) {
  for (int i = 0; i < bytes; ++i) out.put(static_cast<char>(value >> (8 * i)));
}
static void make_wav(const std::filesystem::path& path) {
  std::ofstream out(path, std::ios::binary);
  constexpr uint32_t frames = 44100 * 2;
  out.write("RIFF", 4); number(out, 36 + frames * 2, 4);
  out.write("WAVEfmt ", 8); number(out, 16, 4);
  number(out, 1, 2); number(out, 1, 2); number(out, 44100, 4);
  number(out, 88200, 4); number(out, 2, 2); number(out, 16, 2);
  out.write("data", 4); number(out, frames * 2, 4);
  for (uint32_t i = 0; i < frames; ++i)
    number(out, static_cast<uint16_t>(static_cast<int16_t>(
      std::sin(i * 440.0 * 6.283185307179586 / 44100) * 16000)), 2);
}

int main() {
  const auto path = std::filesystem::temp_directory_path() / u8"和鸣-preview-测试.wav";
  make_wav(path);
  void* player = hm_preview_create_for_testing(); // No device, threads, or sockets.
  uint64_t epoch = 1;
  assert(hm_preview_open(player, path.u8string().c_str()) == 0);
  expect(player, "\"state\":2");
  expect(player, "\"durationMs\":2000");
  std::vector<float> output(480 * 2, 42.0f);
  hm_preview_render_for_testing(player, output.data(), 480);
  assert(std::all_of(output.begin(), output.end(), [](float f) { return f == 0; }));
  assert(hm_preview_play(player, epoch) == 0);
  hm_preview_render_for_testing(player, output.data(), 480);
  assert(std::any_of(output.begin(), output.end(), [](float f) { return f != 0; }));
  expect(player, "\"positionMs\":10");
  epoch = hm_preview_interrupt(player);
  hm_preview_pause(player);
  hm_preview_render_for_testing(player, output.data(), 480);
  expect(player, "\"positionMs\":10");
  expect(player, "\"state\":2");
  assert(hm_preview_seek(player, 1250, epoch) == 0);
  expect(player, "\"positionMs\":1250");
  assert(hm_preview_play(player, epoch) == 0);
  hm_preview_volume(player, 0);
  hm_preview_render_for_testing(player, output.data(), 480);
  assert(std::all_of(output.begin(), output.end(), [](float f) { return f == 0; }));
  expect(player, "\"positionMs\":1260");
  assert(hm_preview_seek(player, 1990, epoch) == 0);
  for (int i = 0; i < 5; ++i) hm_preview_render_for_testing(player, output.data(), 480);
  expect(player, "\"state\":4");
  expect(player, "\"positionMs\":2000");
  assert(hm_preview_play(player, epoch) == 0); // Completed restarts from zero.
  expect(player, "\"positionMs\":0");
  const auto stale = epoch;
  epoch = hm_preview_interrupt(player);
  assert(hm_preview_play(player, stale) == 1);
  assert(hm_preview_seek(player, 0, stale) == 1);
  hm_preview_render_for_testing(player, output.data(), 480);
  assert(std::all_of(output.begin(), output.end(), [](float f) { return f == 0; }));
  hm_preview_stop(player);
  expect(player, "\"state\":0");
  expect(player, "\"durationMs\":0");
  assert(hm_preview_open(player, "file-that-does-not-exist.invalid") < 0);
  expect(player, "\"state\":5");
  assert(hm_preview_open(player, path.u8string().c_str()) == 0);
  assert(hm_preview_seek(player, -10, epoch) == 0);
  expect(player, "\"positionMs\":0");
  assert(hm_preview_seek(player, 99999, epoch) == 0);
  expect(player, "\"positionMs\":2000");
  // Consume beyond the fixed one-second ring capacity, so the producer and
  // consumer both wrap. A fast test callback may underrun; it must emit silence
  // without advancing the song position or treating that gap as EOF.
  assert(hm_preview_play(player, epoch) == 0);
  for (int i = 0; i < 1000 && status(player).find("\"state\":4") == std::string::npos; ++i) {
    hm_preview_render_for_testing(player, output.data(), 480);
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  expect(player, "\"state\":4");
  expect(player, "\"positionMs\":2000");
  hm_preview_destroy(player);
  std::filesystem::remove(path);
  std::cout << "Local preview: stream, seek, gain, pause, EOF, cancellation passed\n";
}
