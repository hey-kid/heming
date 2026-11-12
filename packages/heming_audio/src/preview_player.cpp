// Local audition owns only a decoder and an output device. It never creates a
// synchronized engine, a session, a transport thread, or a listening socket.
#ifdef _WIN32
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif
#define MA_NO_ENGINE
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_GENERATION
#define MA_NO_ENCODING
#define MA_NO_NULL
#include "vendor/miniaudio.h"
#include "heming_audio.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {
constexpr ma_uint32 preview_rate = 48000;
constexpr ma_uint32 preview_capacity = preview_rate; // One second, stereo f32.
enum PreviewState { Idle, Loading, Paused, Playing, Completed, Failed };

class PreviewPlayer {
 public:
  explicit PreviewPlayer(bool output = true) : output_enabled(output) {}
  ~PreviewPlayer() { stop(); }

  // Non-blocking cancellation is safe while open/start is running on a worker.
  // A stale start can never reactivate its callback after this token changes.
  uint64_t interrupt() { return epoch.fetch_add(1) + 1; }
  void volume(double value) {
    gain.store(static_cast<float>(std::clamp(value, 0.0, 1.0)));
  }

  int open(const char* path) {
    const auto operation_epoch = epoch.load();
    clear();
    set_error("");
    state.store(Loading);
    ma_decoder_config config =
        ma_decoder_config_init(ma_format_f32, 2, preview_rate);
    ma_result result;
#ifdef _WIN32
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path,
                                         -1, nullptr, 0);
    if (size <= 0) return fail("音频文件路径无效");
    std::wstring wide(size, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1,
                        wide.data(), size);
    result = ma_decoder_init_file_w(wide.c_str(), &config, &decoder);
#else
    result = ma_decoder_init_file(path, &config, &decoder);
#endif
    if (result != MA_SUCCESS) {
      return fail("无法预览此音频，请检查文件或先生成播放副本");
    }
    decoder_valid = true;
    ma_uint64 frames = 0;
    if (ma_decoder_get_length_in_pcm_frames(&decoder, &frames) == MA_SUCCESS)
      total.store(frames);
    if (epoch.load() != operation_epoch) return cancelled();
    if (output_enabled) {
      ma_device_config device_config = ma_device_config_init(ma_device_type_playback);
      device_config.playback.format = ma_format_f32;
      device_config.playback.channels = 2;
      device_config.sampleRate = preview_rate;
      device_config.dataCallback = callback;
      device_config.pUserData = this;
      device_config.periodSizeInMilliseconds = 20;
      if (ma_device_init(nullptr, &device_config, &device) != MA_SUCCESS) {
        clear();
        return fail("无法打开本机音频输出设备");
      }
      device_valid = true;
    }
    if (epoch.load() != operation_epoch) return cancelled();
    state.store(Paused);
    start_worker(operation_epoch);
    return state.load() == Failed ? -1 : 0;
  }

  int play(uint64_t operation_epoch) {
    if (operation_epoch != epoch.load()) return 1;
    if (!decoder_valid) return fail("请先选择要预览的音频");
    if (state.load() == Playing && active_epoch.load() == operation_epoch)
      return 0;
    stop_device();
    if (state.load() == Completed) {
      stop_worker();
      if (ma_decoder_seek_to_pcm_frame(&decoder, 0) != MA_SUCCESS)
        return fail("无法重新播放此音频");
      reset_buffer(0);
      state.store(Paused);
      start_worker(operation_epoch);
    }
    if (state.load() == Failed) return -1;
    if (epoch.load() != operation_epoch) return 1;
    active_epoch.store(operation_epoch);
    int previous = state.load();
    if (previous == Failed || !state.compare_exchange_strong(previous, Playing))
      return previous == Failed ? -1 : 1;
    if (device_valid) {
      if (ma_device_start(&device) != MA_SUCCESS)
        return fail("无法开始本机音频播放");
      device_started = true;
    }
    // Do not write Playing here: a very short file may have already completed.
    if (epoch.load() != operation_epoch) {
      stop_device();
      if (state.load() == Playing) state.store(Paused);
      return 1;
    }
    return 0;
  }

  void pause() {
    // The caller invalidates starts before queueing this blocking operation.
    if (state.load() == Playing) state.store(Paused);
    stop_device();
  }

  int seek(int64_t milliseconds, uint64_t operation_epoch) {
    if (operation_epoch != epoch.load()) return 1;
    if (!decoder_valid) return fail("请先选择要预览的音频");
    const bool resume = state.load() == Playing &&
                        active_epoch.load() == epoch.load();
    stop_device();
    stop_worker();
    ma_uint64 frame = static_cast<ma_uint64>(std::max<int64_t>(0, milliseconds)) *
                      (preview_rate / 1000);
    const ma_uint64 length = total.load();
    if (length != 0) frame = std::min(frame, length);
    if (ma_decoder_seek_to_pcm_frame(&decoder, frame) != MA_SUCCESS)
      return fail("此音频无法跳转到所选位置");
    reset_buffer(frame);
    state.store(length != 0 && frame == length ? Completed : Paused);
    if (state.load() != Completed) start_worker(operation_epoch);
    if (state.load() == Failed) return -1;
    return resume && state.load() != Completed ? play(operation_epoch) : 0;
  }

  void stop() {
    state.store(Idle);
    clear();
    set_error("");
    state.store(Idle);
  }

  std::string status() {
    std::ostringstream out;
    out << "{\"state\":" << state.load()
        << ",\"positionMs\":" << position.load() / (preview_rate / 1000)
        << ",\"durationMs\":" << total.load() / (preview_rate / 1000)
        << ",\"error\":";
    std::lock_guard<std::mutex> lock(error_mutex);
    if (error.empty()) out << "null";
    else {
      out << '"';
      for (const unsigned char c : error) {
        if (c == '"' || c == '\\') out << '\\';
        if (c >= 32) out << static_cast<char>(c);
      }
      out << '"';
    }
    out << '}';
    return out.str();
  }

  // A single producer fills a fixed one-second PCM ring. This callback does
  // only bounded copies and gain: no file I/O, decoder calls, locks, allocation,
  // waiting, or error formatting on the audio thread.
  void render(float* output, ma_uint32 frames) {
    std::fill_n(output, static_cast<size_t>(frames) * 2, 0.0f);
    const auto callback_epoch = active_epoch.load();
    if (state.load() != Playing || callback_epoch != epoch.load()) return;
    const uint64_t head = ring_read.load(std::memory_order_relaxed);
    const uint64_t tail = ring_write.load(std::memory_order_acquire);
    const ma_uint64 read = std::min<uint64_t>(frames, tail - head);
    const float level = gain.load();
    for (ma_uint64 i = 0; i < read; ++i) {
      const auto source = ((head + i) % preview_capacity) * 2;
      output[i * 2] = ring[source] * level;
      output[i * 2 + 1] = ring[source + 1] * level;
    }
    if (callback_epoch != epoch.load()) {
      std::fill_n(output, static_cast<size_t>(frames) * 2, 0.0f);
      return;
    }
    ring_read.store(head + read, std::memory_order_release);
    position.fetch_add(read);
    if (decoder_ended.load(std::memory_order_acquire) &&
        head + read == ring_write.load(std::memory_order_acquire)) {
      state.store(Completed);
    }
  }

 private:
  static void callback(ma_device* device, void* output, const void*, ma_uint32 frames) {
    static_cast<PreviewPlayer*>(device->pUserData)->render(static_cast<float*>(output), frames);
  }
  void stop_device() {
    if (device_valid && device_started) {
      ma_device_stop(&device);
      device_started = false;
    }
  }
  void clear() {
    stop_device();
    stop_worker();
    if (device_valid) ma_device_uninit(&device);
    device_valid = false;
    if (decoder_valid) ma_decoder_uninit(&decoder);
    decoder_valid = false;
    reset_buffer(0);
    total.store(0);
  }
  void reset_buffer(uint64_t frame) {
    ring_read.store(0);
    ring_write.store(0);
    decoder_ended.store(false);
    position.store(frame);
  }
  void start_worker(uint64_t operation_epoch) {
    worker_cancelled.store(false);
    worker = std::thread([this] {
      std::array<float, 4096 * 2> decoded{};
      uint64_t decoded_position = position.load();
      while (!worker_cancelled.load()) {
        const uint64_t head = ring_read.load(std::memory_order_acquire);
        const uint64_t tail = ring_write.load(std::memory_order_relaxed);
        const auto free = preview_capacity - (tail - head);
        if (free == 0) {
          std::unique_lock<std::mutex> lock(worker_mutex);
          worker_changed.wait_for(lock, std::chrono::milliseconds(20),
                                  [this] { return worker_cancelled.load(); });
          continue;
        }
        ma_uint64 read = 0;
        const auto requested = std::min<uint64_t>(4096, free);
        const ma_result result = ma_decoder_read_pcm_frames(
            &decoder, decoded.data(), requested, &read);
        if (worker_cancelled.load()) break;
        for (uint64_t i = 0; i < read; ++i) {
          const auto destination = ((tail + i) % preview_capacity) * 2;
          ring[destination] = decoded[i * 2];
          ring[destination + 1] = decoded[i * 2 + 1];
        }
        decoded_position += read;
        ring_write.store(tail + read, std::memory_order_release);
        if (result != MA_SUCCESS && result != MA_AT_END) {
          fail("音频解码失败，请检查文件是否损坏");
          worker_changed.notify_all();
          break;
        }
        if (result == MA_AT_END || read < requested) {
          total.store(decoded_position);
          decoder_ended.store(true, std::memory_order_release);
          worker_changed.notify_all();
          break;
        }
        worker_changed.notify_all();
      }
    });
    // A short prefill usually finishes within a few milliseconds. Cancellation
    // never waits for an entire recording, and no prefill blocks the UI isolate.
    std::unique_lock<std::mutex> lock(worker_mutex);
    worker_changed.wait_for(lock, std::chrono::milliseconds(250), [this, operation_epoch] {
      return ring_write.load() >= preview_rate / 10 || decoder_ended.load() ||
             state.load() == Failed || epoch.load() != operation_epoch;
    });
  }
  void stop_worker() {
    worker_cancelled.store(true);
    worker_changed.notify_all();
    if (worker.joinable()) worker.join();
  }
  int cancelled() {
    clear();
    state.store(Idle);
    return 1;
  }
  void set_error(const std::string& message) {
    std::lock_guard<std::mutex> lock(error_mutex);
    error = message;
  }
  int fail(const std::string& message) {
    set_error(message);
    state.store(Failed);
    return -1;
  }
  ma_decoder decoder{};
  ma_device device{};
  bool decoder_valid = false, device_valid = false, device_started = false;
  const bool output_enabled;
  std::atomic<int> state{Idle};
  std::atomic<ma_uint64> position{0}, total{0};
  std::atomic<uint64_t> epoch{1}, active_epoch{0};
  std::atomic<float> gain{1.0f};
  std::array<float, preview_capacity * 2> ring{};
  std::atomic<uint64_t> ring_read{0}, ring_write{0};
  std::atomic<bool> worker_cancelled{false}, decoder_ended{false};
  std::thread worker;
  std::mutex worker_mutex;
  std::condition_variable worker_changed;
  std::mutex error_mutex;
  std::string error;
};
}  // namespace

extern "C" {
void* hm_preview_create() { return new PreviewPlayer(); }
void hm_preview_destroy(void* handle) { delete static_cast<PreviewPlayer*>(handle); }
int hm_preview_open(void* handle, const char* path) {
  return static_cast<PreviewPlayer*>(handle)->open(path);
}
int hm_preview_play(void* handle, int64_t epoch) { return static_cast<PreviewPlayer*>(handle)->play(epoch); }
void hm_preview_pause(void* handle) { static_cast<PreviewPlayer*>(handle)->pause(); }
int hm_preview_seek(void* handle, int64_t milliseconds, int64_t epoch) {
  return static_cast<PreviewPlayer*>(handle)->seek(milliseconds, epoch);
}
void hm_preview_stop(void* handle) { static_cast<PreviewPlayer*>(handle)->stop(); }
int64_t hm_preview_interrupt(void* handle) { return static_cast<PreviewPlayer*>(handle)->interrupt(); }
void hm_preview_volume(void* handle, double volume) { static_cast<PreviewPlayer*>(handle)->volume(volume); }
char* hm_preview_status(void* handle) {
  const auto value = static_cast<PreviewPlayer*>(handle)->status();
  auto* result = static_cast<char*>(std::malloc(value.size() + 1));
  if (result) std::memcpy(result, value.c_str(), value.size() + 1);
  return result;
}
#ifdef HEMING_PREVIEW_TESTING
HM_EXPORT void* hm_preview_create_for_testing() { return new PreviewPlayer(false); }
HM_EXPORT void hm_preview_render_for_testing(void* handle, float* output, uint32_t frames) {
  static_cast<PreviewPlayer*>(handle)->render(output, frames);
}
#endif
}
