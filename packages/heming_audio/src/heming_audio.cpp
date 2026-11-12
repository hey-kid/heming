#ifdef _WIN32
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <audioclient.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#endif
#ifdef __ANDROID__
#include <aaudio/AAudio.h>
#endif
#define MA_NO_ENGINE
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_GENERATION
#define MA_NO_ENCODING
#define MA_NO_NULL
#define MINIAUDIO_IMPLEMENTATION
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "heming_audio.h"
#include "sync/hardware_clock.h"
#include "sync/output_timing.h"
#include "vendor/miniaudio.h"

namespace {
constexpr uint32_t kRate = 48000, kCapacity = kRate * 5, kChunk = 4800;
constexpr uint32_t kMagic = 0x484D5031;
enum State { Idle, Preparing, Ready, Scheduled, Playing, Completed, Failed };
#ifdef _WIN32
using Socket = SOCKET;
constexpr Socket bad = INVALID_SOCKET;
void close_socket(Socket s) {
  if (s != bad) closesocket(s);
}
void shutdown_socket(Socket s) {
  if (s != bad) shutdown(s, SD_BOTH);
}
void init_sockets() {
  static const bool initialized = []() {
    WSADATA w;
    return WSAStartup(MAKEWORD(2, 2), &w) == 0;
  }();
  (void)initialized;
}
#else
using Socket = int;
constexpr Socket bad = -1;
void close_socket(Socket s) {
  if (s != bad) close(s);
}
void shutdown_socket(Socket s) {
  if (s != bad) shutdown(s, SHUT_RDWR);
}
void init_sockets() {}
#endif
int64_t now_us() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}
void sleep_ms(int ms) {
  std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}
bool connect_bounded(Socket socket, const sockaddr_in& address,
                     const std::atomic<bool>& cancel) {
#ifdef _WIN32
  u_long nonblocking = 1;
  ioctlsocket(socket, FIONBIO, &nonblocking);
#else
  int flags = fcntl(socket, F_GETFL, 0);
  fcntl(socket, F_SETFL, flags | O_NONBLOCK);
#endif
  bool connected =
      connect(socket, (const sockaddr*)&address, sizeof(address)) == 0;
  int64_t deadline = now_us() + 3000000;
  while (!connected && !cancel && now_us() < deadline) {
    fd_set writable;
    FD_ZERO(&writable);
    FD_SET(socket, &writable);
    timeval wait{0, 100000};
    int r = select((int)socket + 1, nullptr, &writable, nullptr, &wait);
    if (r < 0) break;
    if (!r) continue;
    int error = 0;
#ifdef _WIN32
    int size = sizeof(error);
#else
    socklen_t size = sizeof(error);
#endif
    if (getsockopt(socket, SOL_SOCKET, SO_ERROR, (char*)&error, &size) != 0 ||
        error != 0)
      break;
    connected = true;
  }
#ifdef _WIN32
  nonblocking = 0;
  ioctlsocket(socket, FIONBIO, &nonblocking);
#else
  fcntl(socket, F_SETFL, flags);
#endif
  return connected && !cancel;
}
void timeout(Socket s, int ms) {
#ifdef _WIN32
  DWORD t = ms;
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (char*)&t, sizeof(t));
  setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (char*)&t, sizeof(t));
#else
  timeval t{ms / 1000, (ms % 1000) * 1000};
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof(t));
  setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &t, sizeof(t));
#endif
}
bool low_latency_tcp(Socket s) {
  // Each pull contains just 100 ms of PCM. Nagle combined with delayed ACKs
  // can otherwise hold a small request or response tail for longer than that.
  const int enabled = 1;
  return setsockopt(s, IPPROTO_TCP, TCP_NODELAY,
                    (const char*)&enabled, sizeof(enabled)) == 0;
}
bool send_all(Socket s, const void* data, size_t n) {
  const char* p = (const char*)data;
  while (n) {
#ifdef _WIN32
    int r = send(s, p, (int)n, 0);
#else
    int r = (int)send(s, p, n, MSG_NOSIGNAL);
#endif
    if (r <= 0) return false;
    p += r;
    n -= r;
  }
  return true;
}
bool recv_all(Socket s, void* data, size_t n) {
  char* p = (char*)data;
  while (n) {
    int r = (int)recv(s, p, (int)n, 0);
    if (r <= 0) return false;
    p += r;
    n -= r;
  }
  return true;
}
bool recv_cancellable(Socket s, void* data, size_t n,
                      const std::atomic<bool>& cancel, int idleMs) {
  auto* bytes = (char*)data;
  int64_t deadline = now_us() + (int64_t)idleMs * 1000;
  while (n && !cancel) {
    fd_set readable;
    FD_ZERO(&readable);
    FD_SET(s, &readable);
    timeval wait{0, 100000};
    int ready = select((int)s + 1, &readable, nullptr, nullptr, &wait);
    if (ready < 0 || now_us() > deadline) return false;
    if (!ready) continue;
    if (cancel) return false;
    int count = (int)recv(s, bytes, (int)n, 0);
    if (count <= 0) return false;
    bytes += count;
    n -= count;
  }
  return n == 0 && !cancel;
}
void put64(uint8_t* p, uint64_t v) {
  for (int i = 7; i >= 0; --i) {
    p[i] = (uint8_t)v;
    v >>= 8;
  }
}
uint64_t get64(const uint8_t* p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; ++i) v = (v << 8) | p[i];
  return v;
}
void put32(uint8_t* p, uint32_t v) {
  p[0] = v >> 24;
  p[1] = v >> 16;
  p[2] = v >> 8;
  p[3] = v;
}
uint32_t get32(const uint8_t* p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
         (uint32_t(p[2]) << 8) | p[3];
}
std::string escape(const std::string& s) {
  std::string o;
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') o += '\\';
    if (c >= 32) o += c;
  }
  return o;
}
char* text(const std::string& s) {
  char* p = (char*)malloc(s.size() + 1);
  if (p) memcpy(p, s.c_str(), s.size() + 1);
  return p;
}
uint64_t fingerprint(const char* s) {
  uint64_t h = 14695981039346656037ull;
  for (; *s; ++s) {
    h ^= (uint8_t)*s;
    h *= 1099511628211ull;
  }
  return h;
}
FILE* open_file(const char* path, const char* mode) {
#ifdef _WIN32
  int n = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, path, -1, w.data(), n);
  std::wstring m;
  while (*mode) m += *mode++;
  return _wfopen(w.c_str(), m.c_str());
#else
  return fopen(path, mode);
#endif
}
void remove_file(const std::string& path) {
#ifdef _WIN32
  int n = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, w.data(), n);
  _wremove(w.c_str());
#else
  remove(path.c_str());
#endif
}
struct Decoder {
  ma_decoder value{};
  bool valid = false;
  ~Decoder() {
    if (valid) ma_decoder_uninit(&value);
  }
  bool open(const std::string& p, bool convert) {
    ma_decoder_config cfg =
        ma_decoder_config_init(convert ? ma_format_s16 : ma_format_unknown,
                               convert ? 2 : 0, convert ? kRate : 0);
#ifdef _WIN32
    int n = MultiByteToWideChar(CP_UTF8, 0, p.c_str(), -1, nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, p.c_str(), -1, w.data(), n);
    valid = ma_decoder_init_file_w(w.c_str(), &cfg, &value) == MA_SUCCESS;
#else
    valid = ma_decoder_init_file(p.c_str(), &cfg, &value) == MA_SUCCESS;
#endif
    return valid;
  }
};
struct Media {
  std::string codec;
  uint32_t rate = 0, channels = 0, bits = 0;
  uint64_t frames = 0;
};
bool inspect(const std::string& path, Media& m, bool verify, std::string& error,
             const std::atomic<bool>* cancelled = nullptr) {
  FILE* f = open_file(path.c_str(), "rb");
  if (!f) {
    error = "无法读取文件";
    return false;
  }
  uint8_t h[42]{};
  size_t n = fread(h, 1, sizeof(h), f);
  fclose(f);
  if (n >= 42 && memcmp(h, "fLaC", 4) == 0 && (h[4] & 127) == 0 && h[5] == 0 &&
      h[6] == 0 && h[7] == 34) {
    uint64_t v = get64(h + 18);
    m.codec = "flac";
    m.rate = (v >> 44) & 0xfffff;
    m.channels = ((v >> 41) & 7) + 1;
    m.bits = ((v >> 36) & 31) + 1;
    m.frames = v & 0xfffffffffull;
  }
  Decoder d;
  if (!d.open(path, false)) {
    error = "此格式需要系统解码器，或文件没有可解码音轨";
    return false;
  }
  if (m.codec.empty()) {
    m.rate = d.value.outputSampleRate;
    m.channels = d.value.outputChannels;
    m.bits = ma_get_bytes_per_sample(d.value.outputFormat) * 8;
    m.codec =
        n >= 12 && memcmp(h, "RIFF", 4) == 0 && memcmp(h + 8, "WAVE", 4) == 0
            ? "wav"
            : "mp3";
    ma_uint64 length = 0;
    ma_decoder_get_length_in_pcm_frames(&d.value, &length);
    m.frames = length;
  }
  if (!m.rate || !m.channels) {
    error = "音频参数无效";
    return false;
  }
  if (verify) {
    std::vector<uint8_t> b(
        4096 *
        ma_get_bytes_per_frame(d.value.outputFormat, d.value.outputChannels));
    uint64_t count = 0;
    for (;;) {
      if (cancelled && cancelled->load()) {
        error = "转换已取消";
        return false;
      }
      ma_uint64 read = 0;
      ma_result r = ma_decoder_read_pcm_frames(&d.value, b.data(), 4096, &read);
      count += read;
      if (r != MA_SUCCESS && r != MA_AT_END) {
        error = "音频解码失败";
        return false;
      }
      if (!read) break;
    }
    if (!count || (m.frames && count != m.frames)) {
      error = "音频不完整或样本数校验失败";
      return false;
    }
    m.frames = count;
  }
  return true;
}
struct Peer {
  Socket socket = bad;
  std::thread thread;
  std::atomic<bool> finished{false};
};
struct Engine {
  std::mutex operation, errors, peersLock;
  std::string error, path;
  uint64_t session = 0, task = 0;
  std::atomic<int> state{Idle};
  std::atomic<bool> cancel{false}, eof{false};
  std::atomic<uint64_t> written{0}, read{0}, total{0};
  std::vector<int16_t> ring = std::vector<int16_t>(kCapacity * 2);
  std::atomic<int64_t> start{0}, offset{0}, rtt{0};
  std::atomic<int64_t> latencyCompensation{0};
  std::atomic<double> volume{1};
  std::atomic<int> channel{0};
  std::atomic<bool> muted{false};
  std::atomic<int> callbackError{0};
  std::atomic<int> port{0};
  std::atomic<double> driftPpm{0};
  std::atomic<double> hardwareRatePpm{0};
  std::atomic<int64_t> hardwarePositionMicros{0}, hardwareTimestampMicros{0};
  std::atomic<int> hardwareClockSource{0}, hardwareRateWindows{0};
  std::atomic<bool> hardwareClockValid{false};
  std::atomic<int> outputUnderruns{0}, outputSampleRate{0}, callbackFrames{0};
  heming::OutputDrain outputDrain;
  heming::SustainedPhaseGuard phaseGuard;
  std::atomic<int64_t> phaseErrorMicros{0};
#ifdef _WIN32
  IAudioClock* deviceClock = nullptr;
  UINT64 deviceClockFrequency = 0;
  heming::HardwareClockRate hardwareClockRate;
#endif
  double fraction = 0;
  bool remote = false;
  ma_context context{};
  ma_device device{};
  bool contextOpen = false, deviceOpen = false;
  Socket listener = bad, udp = bad, receiver = bad;
  std::thread producer, acceptor, clock;
  std::vector<std::shared_ptr<Peer>> peers;
  std::atomic<int> activePeers{0};
  void fail(const std::string& message) {
    if (cancel) return;
    {
      std::lock_guard<std::mutex> guard(errors);
      error = message;
    }
    state = Failed;
  }
};
void audio_callback(ma_device* device, void* output, const void*,
                    ma_uint32 count) {
  auto* e = (Engine*)device->pUserData;
  auto* out = (int16_t*)output;
  memset(out, 0, count * 4);
  if (e->cancel) return;
  e->callbackFrames = (int)count;
  e->outputSampleRate = (int)device->playback.internalSampleRate;
  // Prediction includes one backend period; each output route still requires
  // measured calibration. This is not a claim of measured speaker precision.
  int64_t lead = (int64_t)device->playback.internalPeriodSizeInFrames *
                 1000000 / device->playback.internalSampleRate;
  int64_t present = now_us() + lead;
#ifdef _WIN32
  // Position units vary between backends. Divide by the separately queried
  // frequency, and use the correlated QPC time (100ns units) for rate fitting.
  e->hardwareClockValid = false;
  if (e->deviceClock && e->deviceClockFrequency) {
    UINT64 position = 0, qpc100ns = 0;
    const HRESULT result = e->deviceClock->GetPosition(&position, &qpc100ns);
    const int64_t stamp = (int64_t)(qpc100ns / 10);
    const int64_t sampleNow = now_us();
    if (result == S_OK && stamp > 0 && sampleNow >= stamp &&
        sampleNow - stamp < 100000) {
      const double seconds = (double)position / e->deviceClockFrequency;
      if (e->hardwareClockRate.observe(seconds, stamp)) {
        e->hardwareClockValid = true;
        e->hardwareClockSource = 1;
        e->hardwarePositionMicros = (int64_t)(seconds * 1000000.0);
        e->hardwareTimestampMicros = stamp;
      }
      e->hardwareRatePpm = e->hardwareClockRate.ppm();
      e->hardwareRateWindows = e->hardwareClockRate.goodWindows();
    } else if (result == AUDCLNT_E_DEVICE_INVALIDATED ||
               result == AUDCLNT_E_SERVICE_NOT_RUNNING) {
      e->callbackError = 2;
      e->state = Failed;
      return;
    }
    // Ignore S_FALSE (inaccurate); never retry indefinitely in the callback.
  }
  ma_uint32 queued = 0;
  if (device->wasapi.pAudioClientPlayback &&
      ma_IAudioClient_GetCurrentPadding(
          (ma_IAudioClient*)device->wasapi.pAudioClientPlayback, &queued) ==
          S_OK)
    present =
        now_us() + (int64_t)((double)queued * 1000000.0 /
                             (device->playback.internalSampleRate *
                              (1.0 + e->hardwareRatePpm.load() / 1000000.0)));
#elif defined(__ANDROID__)
  auto* stream = (AAudioStream*)device->aaudio.pStreamPlayback;
  int64_t hardwareFrame = 0, hardwareNs = 0;
  const int32_t streamRate = stream ? AAudioStream_getSampleRate(stream) : 0;
  const int64_t framesWritten =
      stream ? AAudioStream_getFramesWritten(stream) : 0;
  if (stream && streamRate > 0) {
    const int64_t framesRead = AAudioStream_getFramesRead(stream);
    const int64_t queued = framesWritten - framesRead;
    if (queued >= 0 && queued <= int64_t(streamRate) * 2)
      present = now_us() + queued * 1000000 / streamRate;
    e->outputUnderruns = std::max(0, AAudioStream_getXRunCount(stream));
  }
  if (stream &&
      AAudioStream_getTimestamp(stream, CLOCK_MONOTONIC, &hardwareFrame,
                                &hardwareNs) == AAUDIO_OK &&
      hardwareNs / 1000 >= e->hardwareTimestampMicros.load() &&
      heming::estimateAndroidPresentation(now_us(), hardwareFrame, hardwareNs,
                                          framesWritten, streamRate,
                                          &present)) {
    e->hardwareClockValid = true;
    e->hardwareClockSource = 2;
    e->hardwareTimestampMicros = hardwareNs / 1000;
    e->hardwarePositionMicros = hardwareFrame * 1000000 / streamRate;
  } else {
    e->hardwareClockValid = false;
  }
#endif
  int state = e->state.load(std::memory_order_acquire);
  if (state != Scheduled && state != Playing) return;
  const int64_t localPresentation = present + e->latencyCompensation.load();
  present = localPresentation + e->offset.load();
  int64_t target = e->start.load();
  uint32_t skip = 0;
  if (present < target) {
    int64_t frames = (target - present) * kRate / 1000000;
    if (frames >= count) return;
    skip = (uint32_t)frames;
  }
  if (e->cancel) return;
  if (state == Scheduled) {
    int expected = Scheduled;
    if (!e->state.compare_exchange_strong(expected, Playing)) return;
  } else if (e->state != Playing) {
    return;
  }
  uint64_t read = e->read.load(std::memory_order_relaxed);
  uint64_t written = e->written.load(std::memory_order_acquire);
  double desired = std::max<int64_t>(0, present - target) * kRate / 1000000.0;
  e->phaseErrorMicros = (int64_t)((desired - double(read)) * 1000000.0 / kRate);
  const bool activelyPlaying =
      state == Playing && !(e->eof && read >= e->total);
  if (e->phaseGuard.observe(
          now_us(), e->phaseErrorMicros,
          e->hardwareClockValid ? e->hardwareTimestampMicros.load() : 0,
          activelyPlaying)) {
    e->callbackError = 3;
    int expected = Playing;
    e->state.compare_exchange_strong(expected, Failed);
    return;
  }
  double ppm =
      std::clamp((desired - double(read)) * 2.0 - e->hardwareRatePpm.load(),
                 -500.0, 500.0);
  e->driftPpm = ppm;
  double ratio = 1.0 + ppm / 1000000.0;
  float gain = e->muted ? 0.f : (float)e->volume.load();
  int channel = e->channel.load();
  for (uint32_t i = skip; i < count && !e->cancel && e->state == Playing; ++i) {
    // The producer can publish a new block while this callback is rendering.
    // Recheck its release-store before declaring an actual buffer exhaustion.
    if (read >= written) written = e->written.load(std::memory_order_acquire);
    if (read >= written) {
      if (e->eof && read >= e->total) {
        if (!e->outputDrain.armed())
          e->outputDrain.arm(localPresentation, i, kRate, lead);
        if (e->outputDrain.complete(now_us())) {
          int expected = Playing;
          e->state.compare_exchange_strong(expected, Completed);
        }
      } else {
        e->callbackError = 1;
        int expected = Playing;
        e->state.compare_exchange_strong(expected, Failed);
      }
      break;
    }
    size_t a = (read % kCapacity) * 2,
           b = ((std::min(read + 1, written - 1)) % kCapacity) * 2;
    float left = (float)(e->ring[a] + (e->ring[b] - e->ring[a]) * e->fraction);
    float right = (float)(e->ring[a + 1] +
                          (e->ring[b + 1] - e->ring[a + 1]) * e->fraction);
    if (channel == 1)
      right = left;
    else if (channel == 2)
      left = right;
    out[i * 2] = (int16_t)std::clamp(left * gain, -32768.f, 32767.f);
    out[i * 2 + 1] = (int16_t)std::clamp(right * gain, -32768.f, 32767.f);
    e->fraction += ratio;
    while (e->fraction >= 1) {
      if (read < written) ++read;
      e->fraction -= 1;
    }
    if (e->eof && read >= e->total && !e->outputDrain.armed())
      e->outputDrain.arm(localPresentation, i + 1, kRate, lead);
  }
  e->read.store(read, std::memory_order_release);
}
void device_notification(const ma_device_notification* n) {
  auto* e = (Engine*)n->pDevice->pUserData;
  if (!e || e->cancel) return;
  if (n->type == ma_device_notification_type_rerouted ||
      n->type == ma_device_notification_type_interruption_began ||
      (n->type == ma_device_notification_type_stopped &&
       e->state != Completed && e->state != Idle)) {
    e->callbackError = 2;
    e->state = Failed;
  }
}
bool open_output(Engine* e) {
  ma_backend backend;
#ifdef _WIN32
  backend = ma_backend_wasapi;
#elif defined(__ANDROID__)
  backend = ma_backend_aaudio;
#else
  e->fail("当前平台没有音频输出后端");
  return false;
#endif
  if (ma_context_init(&backend, 1, nullptr, &e->context) != MA_SUCCESS) {
    e->fail("无法初始化系统音频服务");
    return false;
  }
  e->contextOpen = true;
  ma_device_config c = ma_device_config_init(ma_device_type_playback);
  c.playback.format = ma_format_s16;
  c.playback.channels = 2;
  c.sampleRate = kRate;
  c.periodSizeInMilliseconds = 5;
  c.periods = 2;
  // Preserve each backend callback's time domain instead of splitting it into
  // fixed-size chunks which all observe the same native framesWritten value.
  c.noFixedSizedCallback = MA_TRUE;
#ifdef __ANDROID__
  c.aaudio.noAutoStartAfterReroute = MA_TRUE;
#endif
  c.performanceProfile = ma_performance_profile_low_latency;
  c.dataCallback = audio_callback;
  c.notificationCallback = device_notification;
  c.pUserData = e;
  if (ma_device_init(&e->context, &c, &e->device) != MA_SUCCESS) {
    e->fail("无法打开当前音频输出设备");
    return false;
  }
  e->deviceOpen = true;
#ifdef _WIN32
  auto* client =
      static_cast<IAudioClient*>(e->device.wasapi.pAudioClientPlayback);
  if (client &&
      SUCCEEDED(client->GetService(
          __uuidof(IAudioClock), reinterpret_cast<void**>(&e->deviceClock)))) {
    if (e->deviceClock->GetFrequency(&e->deviceClockFrequency) != S_OK ||
        !e->deviceClockFrequency) {
      e->deviceClock->Release();
      e->deviceClock = nullptr;
      e->deviceClockFrequency = 0;
    }
  }
#endif
  if (ma_device_start(&e->device) != MA_SUCCESS) {
    e->fail("无法启动音频输出");
    return false;
  }
  return true;
}
void stop_locked(Engine* e) {
  e->cancel = true;
  e->state = Idle;
  shutdown_socket(e->listener);
  shutdown_socket(e->udp);
  shutdown_socket(e->receiver);
  if (e->deviceOpen) {
    ma_device_uninit(&e->device);
    e->deviceOpen = false;
  }
#ifdef _WIN32
  if (e->deviceClock) {
    e->deviceClock->Release();
    e->deviceClock = nullptr;
  }
  e->deviceClockFrequency = 0;
  e->hardwareClockRate = heming::HardwareClockRate{};
#endif
  if (e->contextOpen) {
    ma_context_uninit(&e->context);
    e->contextOpen = false;
  }
  if (e->acceptor.joinable()) e->acceptor.join();
  if (e->clock.joinable()) e->clock.join();
  if (e->producer.joinable()) e->producer.join();
  {
    std::lock_guard<std::mutex> g(e->peersLock);
    for (auto& p : e->peers) shutdown_socket(p->socket);
  }
  for (auto& p : e->peers) {
    if (p->thread.joinable()) p->thread.join();
    close_socket(p->socket);
  }
  e->peers.clear();
  close_socket(e->listener);
  close_socket(e->udp);
  close_socket(e->receiver);
  e->listener = e->udp = e->receiver = bad;
  e->port = 0;
  e->written = 0;
  e->read = 0;
  e->total = 0;
  e->fraction = 0;
  e->start = 0;
  e->offset = 0;
  e->rtt = 0;
  e->eof = false;
  e->callbackError = 0;
  e->driftPpm = 0;
  e->hardwareRatePpm = 0;
  e->hardwarePositionMicros = 0;
  e->hardwareTimestampMicros = 0;
  e->hardwareClockSource = 0;
  e->hardwareRateWindows = 0;
  e->hardwareClockValid = false;
  e->outputUnderruns = 0;
  e->outputSampleRate = 0;
  e->callbackFrames = 0;
  e->outputDrain = heming::OutputDrain{};
  e->phaseGuard = heming::SustainedPhaseGuard{};
  e->phaseErrorMicros = 0;
  e->state = Idle;
}
void begin(Engine* e, const char* session, const char* task) {
  stop_locked(e);
  {
    std::lock_guard<std::mutex> g(e->errors);
    e->error.clear();
  }
  e->session = fingerprint(session);
  e->task = fingerprint(task);
  e->cancel = false;
  e->state = Preparing;
}
bool push(Engine* e, const int16_t* pcm, uint32_t frames) {
  while (!e->cancel && e->state != Failed) {
    uint64_t w = e->written.load(std::memory_order_relaxed),
             r = e->read.load(std::memory_order_acquire);
    if (kCapacity - (w - r) >= frames) {
      for (uint32_t i = 0; i < frames; ++i) {
        size_t index = ((w + i) % kCapacity) * 2;
        e->ring[index] = pcm[i * 2];
        e->ring[index + 1] = pcm[i * 2 + 1];
      }
      e->written.store(w + frames, std::memory_order_release);
      if (e->state == Preparing &&
          (w + frames >= std::min<uint64_t>(kCapacity, e->total.load())))
        e->state = Ready;
      return true;
    }
    sleep_ms(3);
  }
  return false;
}
void produce_local(Engine* e) {
  Decoder d;
  if (!d.open(e->path, true)) {
    e->fail("无法解码播放副本");
    return;
  }
  std::array<int16_t, kChunk * 2> pcm;
  while (!e->cancel && e->state != Failed) {
    uint64_t w = e->written.load();
    if (w >= e->total) {
      e->eof = true;
      if (e->state == Preparing) e->state = Ready;
      break;
    }
    uint32_t request = (uint32_t)std::min<uint64_t>(kChunk, e->total - w);
    ma_uint64 got = 0;
    ma_result r =
        ma_decoder_read_pcm_frames(&d.value, pcm.data(), request, &got);
    if (!got || (r != MA_SUCCESS && r != MA_AT_END)) {
      e->fail("资源解码中断");
      break;
    }
    if (!push(e, pcm.data(), (uint32_t)got)) break;
  }
}
void serve_peer(Engine* e, std::shared_ptr<Peer> peer) {
  Socket s = peer->socket;
  bool authenticated = false;
  struct Cleanup {
    Engine* e;
    std::shared_ptr<Peer> p;
    bool& authenticated;
    ~Cleanup() {
      shutdown_socket(p->socket);
      if (authenticated) --e->activePeers;
      p->finished = true;
    }
  } cleanup{e, peer, authenticated};
  if (!low_latency_tcp(s)) return;
  timeout(s, 3000);
  uint8_t hello[24];
  if (!recv_cancellable(s, hello, sizeof(hello), e->cancel, 3000) ||
      get32(hello) != kMagic || get32(hello + 4) != 1 ||
      get64(hello + 8) != e->session || get64(hello + 16) != e->task)
    return;
  if (e->activePeers.fetch_add(1) >= 5) {
    --e->activePeers;
    return;
  }
  authenticated = true;
  timeout(s, 3000);
  Decoder d;
  if (!d.open(e->path, true)) return;
  uint8_t reply[16];
  put64(reply, e->total);
  put32(reply + 8, kRate);
  put32(reply + 12, 2);
  if (!send_all(s, reply, sizeof(reply))) return;
  std::array<int16_t, kChunk * 2> pcm;
  std::array<uint8_t, 12 + kChunk * 4> packet;
  uint64_t position = 0;
  while (!e->cancel) {
    uint8_t request[12];
    if (!recv_cancellable(s, request, sizeof(request), e->cancel, 45000)) break;
    uint64_t frame = get64(request);
    uint32_t count = get32(request + 8);
    if (frame != position || count == 0 || count > kChunk || frame > e->total)
      break;
    ma_uint64 got = 0;
    ma_result result =
        ma_decoder_read_pcm_frames(&d.value, pcm.data(), count, &got);
    if (result != MA_SUCCESS && result != MA_AT_END) break;
    // Submit the response as one message, rather than a tiny header followed by
    // a separate body that can become dependent on acknowledging that header.
    put64(packet.data(), position);
    put32(packet.data() + 8, (uint32_t)got);
    memcpy(packet.data() + 12, pcm.data(), (size_t)got * 4);
    if (!send_all(s, packet.data(), 12 + (size_t)got * 4)) break;
    position += got;
    if (!got) break;
  }
  shutdown_socket(s);
}
bool open_server(Engine* e, int port) {
  e->listener = socket(AF_INET, SOCK_STREAM, 0);
  e->udp = socket(AF_INET, SOCK_DGRAM, 0);
  if (e->listener == bad || e->udp == bad) {
    e->fail("无法创建音频传输端口");
    return false;
  }
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_ANY);
  address.sin_port = htons((uint16_t)port);
  if (bind(e->listener, (sockaddr*)&address, sizeof(address)) != 0 ||
      listen(e->listener, 5) != 0) {
    e->fail("音频端口被占用");
    return false;
  }
#ifdef _WIN32
  int len = sizeof(address);
#else
  socklen_t len = sizeof(address);
#endif
  getsockname(e->listener, (sockaddr*)&address, &len);
  e->port = ntohs(address.sin_port);
  if (bind(e->udp, (sockaddr*)&address, sizeof(address)) != 0) {
    e->fail("校时端口被占用");
    return false;
  }
  timeout(e->udp, 300);
  e->acceptor = std::thread([e]() {
    while (!e->cancel) {
      fd_set set;
      FD_ZERO(&set);
      FD_SET(e->listener, &set);
      timeval wait{0, 200000};
      int ready = select((int)e->listener + 1, &set, nullptr, nullptr, &wait);
      if (ready <= 0) continue;
      if (e->cancel) break;
      Socket s = accept(e->listener, nullptr, nullptr);
      if (s == bad) break;
      if (e->cancel) {
        close_socket(s);
        break;
      }
      std::lock_guard<std::mutex> g(e->peersLock);
      for (auto i = e->peers.begin(); i != e->peers.end();) {
        if ((*i)->finished) {
          (*i)->thread.join();
          close_socket((*i)->socket);
          i = e->peers.erase(i);
        } else
          ++i;
      }
      if (e->peers.size() >= 10) {
        close_socket(s);
        continue;
      }
      auto p = std::make_shared<Peer>();
      p->socket = s;
      e->peers.push_back(p);
      p->thread = std::thread(serve_peer, e, p);
    }
  });
  e->clock = std::thread([e]() {
    while (!e->cancel) {
      uint8_t message[48]{};
      sockaddr_in from{};
#ifdef _WIN32
      int n = sizeof(from);
#else
      socklen_t n = sizeof(from);
#endif
      int size =
          (int)recvfrom(e->udp, (char*)message, 32, 0, (sockaddr*)&from, &n);
      int64_t t2 = now_us();
      if (size != 32 || get32(message) != kMagic ||
          get64(message + 8) != e->session || get64(message + 16) != e->task)
        continue;
      put64(message + 32, t2);
      put64(message + 40, now_us());
      sendto(e->udp, (char*)message, 48, 0, (sockaddr*)&from, n);
    }
  });
  return true;
}
bool calibrate(Engine* e, const sockaddr_in& target, bool smooth = false) {
  Socket s = socket(AF_INET, SOCK_DGRAM, 0);
  if (s == bad) return false;
  timeout(s, 250);
  if (connect(s, (const sockaddr*)&target, sizeof(target)) != 0) {
    close_socket(s);
    return false;
  }
  int64_t best = INT64_MAX, offset = 0;
  for (int i = 0; i < 8 && !e->cancel; ++i) {
    uint8_t message[48]{};
    put32(message, kMagic);
    put32(message + 4, 1);
    put64(message + 8, e->session);
    put64(message + 16, e->task);
    int64_t t1 = now_us();
    put64(message + 24, t1);
    if (send(s, (char*)message, 32, 0) != 32) continue;
    int count = (int)recv(s, (char*)message, 48, 0);
    int64_t t4 = now_us();
    if (count != 48 || get64(message + 24) != (uint64_t)t1) continue;
    const uint64_t stamp2 = get64(message + 32), stamp3 = get64(message + 40);
    if (stamp2 > INT64_MAX / 4 || stamp3 > INT64_MAX / 4 || stamp3 < stamp2 ||
        stamp3 - stamp2 > 1000000)
      continue;
    int64_t t2 = (int64_t)stamp2, t3 = (int64_t)stamp3,
            rtt = (t4 - t1) - (t3 - t2);
    if (rtt >= 0 && rtt < best) {
      best = rtt;
      offset = ((t2 - t1) + (t3 - t4)) / 2;
    }
  }
  close_socket(s);
  if (best == INT64_MAX || best > 100000) return false;
  e->rtt = best;
  if (smooth) {
    int64_t delta = offset - e->offset.load();
    if (std::abs(delta) > 50000) {
      e->fail("时钟同步偏差过大，已停止播放");
      return false;
    }
    e->offset = e->offset.load() + std::clamp<int64_t>(delta, -1000, 1000);
  } else
    e->offset = offset;
  return true;
}
void produce_remote(Engine* e) {
  std::array<int16_t, kChunk * 2> pcm;
  uint64_t position = 0;
  while (!e->cancel && e->state != Failed) {
    if (position >= e->total) {
      e->eof = true;
      if (e->state == Preparing) e->state = Ready;
      break;
    }
    while (!e->cancel && e->state != Failed &&
           e->written - e->read > kCapacity - kChunk)
      sleep_ms(3);
    if (e->cancel || e->state == Failed) break;
    uint8_t request[12];
    put64(request, position);
    put32(request + 8,
          (uint32_t)std::min<uint64_t>(kChunk, e->total - position));
    uint8_t header[12];
    if (!send_all(e->receiver, request, 12) ||
        !recv_all(e->receiver, header, 12)) {
      e->fail("音频连接中断");
      break;
    }
    uint32_t frames = get32(header + 8);
    if (get64(header) != position || frames == 0 || frames > kChunk ||
        position + frames > e->total ||
        !recv_all(e->receiver, pcm.data(), frames * 4)) {
      e->fail("音频数据不完整或任务失效");
      break;
    }
    if (!push(e, pcm.data(), frames)) break;
    position += frames;
  }
}

// RFC 9639 verbatim FLAC subframes preserve each converted PCM sample.
uint8_t crc8(const uint8_t* p, size_t n) {
  uint8_t c = 0;
  while (n--) {
    c ^= *p++;
    for (int i = 0; i < 8; i++)
      c = (c & 128) ? (uint8_t)((c << 1) ^ 7) : (uint8_t)(c << 1);
  }
  return c;
}
uint16_t crc16(const uint8_t* p, size_t n) {
  uint16_t c = 0;
  while (n--) {
    c ^= (uint16_t)*p++ << 8;
    for (int i = 0; i < 8; i++)
      c = (c & 32768) ? (uint16_t)((c << 1) ^ 0x8005) : (uint16_t)(c << 1);
  }
  return c;
}
void utf8_number(std::vector<uint8_t>& b, uint64_t n) {
  if (n < 128) {
    b.push_back((uint8_t)n);
    return;
  }
  int count = 2;
  while (count < 7 && n >= (1ull << (5 * count + 1))) ++count;
  uint8_t tail[6];
  for (int i = count - 2; i >= 0; --i) {
    tail[i] = 0x80 | (n & 63);
    n >>= 6;
  }
  b.push_back((uint8_t)((0xff << (8 - count)) | n));
  for (int i = 0; i < count - 1; i++) b.push_back(tail[i]);
}
struct Conversion {
  std::string input, output, error;
  std::atomic<bool> cancel{false};
  std::atomic<int> state{0};
  std::atomic<double> progress{0};
  std::mutex lock;
  std::thread worker;
};
void convert_worker(Conversion* job) {
  FILE* out = nullptr;
  auto fail = [&](const std::string& error) {
    if (out) {
      fclose(out);
      out = nullptr;
    }
    remove_file(job->output);
    {
      std::lock_guard<std::mutex> g(job->lock);
      job->error = error;
    }
    job->state = job->cancel ? 3 : 2;
  };
  Decoder d;
  if (!d.open(job->input, true)) {
    fail("无法解码此音频，请使用系统转换器");
    return;
  }
  ma_uint64 total = 0;
  ma_decoder_get_length_in_pcm_frames(&d.value, &total);
  out = open_file(job->output.c_str(), "wb");
  if (!out) {
    fail("无法创建转换文件，请检查存储空间");
    return;
  }
  uint8_t stream[42]{};
  memcpy(stream, "fLaC", 4);
  stream[4] = 0x80;
  stream[7] = 34;
  stream[8] = 0x10;
  stream[10] = 0x10;
  put64(stream + 18, ((uint64_t)kRate << 44) | (1ull << 41) | (15ull << 36));
  if (fwrite(stream, 1, 42, out) != 42) {
    fail("写入失败，可能存储空间不足");
    return;
  }
  std::array<int16_t, 4096 * 2> pcm;
  uint64_t position = 0, index = 0;
  uint32_t minBlock = 4096, maxBlock = 0;
  for (;;) {
    if (job->cancel) {
      fail("转换已取消");
      return;
    }
    ma_uint64 got = 0;
    ma_result result =
        ma_decoder_read_pcm_frames(&d.value, pcm.data(), 4096, &got);
    if (result != MA_SUCCESS && result != MA_AT_END) {
      fail("源文件解码失败");
      return;
    }
    if (!got) break;
    std::vector<uint8_t> frame{0xff, 0xf8, 0x7a, 0x18};
    utf8_number(frame, index++);
    frame.push_back((uint8_t)((got - 1) >> 8));
    frame.push_back((uint8_t)(got - 1));
    frame.push_back(crc8(frame.data(), frame.size()));
    for (int c = 0; c < 2; c++) {
      frame.push_back(0x02);
      for (size_t i = 0; i < got; i++) {
        uint16_t v = (uint16_t)pcm[i * 2 + c];
        frame.push_back(v >> 8);
        frame.push_back(v);
      }
    }
    uint16_t crc = crc16(frame.data(), frame.size());
    frame.push_back(crc >> 8);
    frame.push_back(crc);
    if (fwrite(frame.data(), 1, frame.size(), out) != frame.size()) {
      fail("写入失败，可能存储空间不足");
      return;
    }
    position += got;
    minBlock = std::min<uint32_t>(minBlock, (uint32_t)got);
    maxBlock = std::max<uint32_t>(maxBlock, (uint32_t)got);
    job->progress = total ? std::min(0.98, (double)position / total) : 0;
  }
  if (!position || position > 0xfffffffffull) {
    fail("音频为空或超出 FLAC 长度限制");
    return;
  }
  stream[8] = minBlock >> 8;
  stream[9] = minBlock;
  stream[10] = maxBlock >> 8;
  stream[11] = maxBlock;
  put64(stream + 18,
        ((uint64_t)kRate << 44) | (1ull << 41) | (15ull << 36) | position);
  if (fseek(out, 0, SEEK_SET) != 0 || fwrite(stream, 1, 42, out) != 42 ||
      fflush(out) != 0) {
    fail("转换输出校验前写入失败");
    return;
  }
  fclose(out);
  out = nullptr;
  if (job->cancel) {
    fail("转换已取消");
    return;
  }
  Media media;
  std::string error;
  if (!inspect(job->output, media, true, error, &job->cancel) ||
      media.rate != kRate || media.channels != 2 || media.bits != 16 ||
      media.frames != position) {
    fail("转换输出校验失败：" + error);
    return;
  }
  if (job->cancel) {
    fail("转换已取消");
    return;
  }
  job->progress = 1;
  job->state = 1;
}
}  // namespace

extern "C" {
void* hm_create() {
  init_sockets();
  try {
    return new Engine();
  } catch (...) {
    return nullptr;
  }
}
void hm_destroy(void* pointer) {
  if (!pointer) return;
  auto* e = (Engine*)pointer;
  {
    std::lock_guard<std::mutex> g(e->operation);
    stop_locked(e);
  }
  delete e;
}
int64_t hm_now_us() { return now_us(); }
#ifdef HEMING_TRANSPORT_TESTING
// Exercise the production TCP/decoder path without an output device. Only the
// standalone native test build exports this entry point.
HM_EXPORT int hm_transport_source_for_testing(void* pointer, const char* path,
                                             const char* session,
                                             const char* task) {
  auto* e = (Engine*)pointer;
  std::lock_guard<std::mutex> guard(e->operation);
  begin(e, session, task);
  Media media;
  std::string error;
  if (!inspect(path, media, false, error) || !media.frames) return -1;
  e->path = path;
  e->total = media.frames;
  if (!open_server(e, 0)) return -1;
  e->state = Ready;
  return e->port;
}
#endif
void hm_stop(void* pointer) {
  auto* e = (Engine*)pointer;
  e->cancel = true;
  e->state = Idle;
  std::lock_guard<std::mutex> guard(e->operation);
  stop_locked(e);
}
void hm_interrupt(void* pointer) {
  auto* e = (Engine*)pointer;
  e->cancel = true;
  e->state = Idle;
}
int hm_prepare_local(void* pointer, const char* path, const char* session,
                     const char* task, int port) {
  auto* e = (Engine*)pointer;
  std::lock_guard<std::mutex> guard(e->operation);
  begin(e, session, task);
  e->remote = false;
  e->path = path;
  Media media;
  std::string error;
  bool valid = inspect(path, media, false, error);
  // A zero STREAMINFO length is legal; verify and count before output opens.
  if (valid && media.codec == "flac" && !media.frames)
    valid = inspect(path, media, true, error);
  if (!valid || media.codec != "flac" || media.rate != kRate ||
      media.channels != 2 || media.bits != 16 || !media.frames) {
    e->fail(error.empty() ? "播放副本必须是 FLAC / 48 kHz / 16-bit / 双声道"
                          : error);
    return -1;
  }
  e->total = media.frames;
  if (!open_output(e) || !open_server(e, port)) return -1;
  e->producer = std::thread(produce_local, e);
  return 0;
}
int hm_prepare_remote(void* pointer, const char* host, int port,
                      const char* session, const char* task) {
  auto* e = (Engine*)pointer;
  std::lock_guard<std::mutex> guard(e->operation);
  begin(e, session, task);
  e->remote = true;
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_port = htons((uint16_t)port);
  if (inet_pton(AF_INET, host, &address.sin_addr) != 1) {
    e->fail("音频地址必须是 IPv4 地址");
    return -1;
  }
  if (!calibrate(e, address)) {
    e->fail("无法完成局域网时钟校准");
    return -1;
  }
  e->receiver = socket(AF_INET, SOCK_STREAM, 0);
  if (e->receiver == bad || !low_latency_tcp(e->receiver)) {
    e->fail("无法配置实时音频连接");
    return -1;
  }
  timeout(e->receiver, 3000);
  if (!connect_bounded(e->receiver, address, e->cancel)) {
    e->fail("无法连接主控音频端口");
    return -1;
  }
  uint8_t hello[24];
  put32(hello, kMagic);
  put32(hello + 4, 1);
  put64(hello + 8, e->session);
  put64(hello + 16, e->task);
  uint8_t reply[16];
  if (!send_all(e->receiver, hello, 24) || !recv_all(e->receiver, reply, 16) ||
      get32(reply + 8) != kRate || get32(reply + 12) != 2 ||
      get64(reply) == 0 || get64(reply) > 0xfffffffffull) {
    e->fail("主控音频任务无效");
    return -1;
  }
  e->total = get64(reply);
  if (!open_output(e)) return -1;
  e->producer = std::thread(produce_remote, e);
  e->clock = std::thread([e, address]() {
    int misses = 0;
    while (!e->cancel && e->state != Failed) {
      for (int i = 0; i < 30 && !e->cancel; i++) sleep_ms(100);
      if (e->cancel) break;
      if (calibrate(e, address, true))
        misses = 0;
      else if (++misses >= 3) {
        e->fail("持续无法校准时钟，已停止播放");
        break;
      }
    }
  });
  return 0;
}
int hm_schedule(void* pointer, int64_t master_time) {
  auto* e = (Engine*)pointer;
  if (e->cancel || e->state != Ready ||
      master_time < now_us() + e->offset +
                        std::max<int64_t>(0, e->latencyCompensation.load()) +
                        20000)
    return -1;
  e->start = master_time;
  int expected = Ready;
  return e->state.compare_exchange_strong(expected, Scheduled) ? 0 : -1;
}
void hm_output(void* pointer, double volume, int channel, int muted) {
  auto* e = (Engine*)pointer;
  e->volume = std::clamp(std::isfinite(volume) ? volume : 0., 0., 1.);
  e->channel = std::clamp(channel, 0, 2);
  e->muted = muted != 0;
}
void hm_latency_compensation(void* pointer, int64_t microseconds) {
  ((Engine*)pointer)->latencyCompensation =
      std::clamp<int64_t>(microseconds, -250000, 250000);
}
char* hm_status(void* pointer) {
  auto* e = (Engine*)pointer;
  std::string error;
  {
    std::lock_guard<std::mutex> g(e->errors);
    error = e->error;
  }
  if (e->callbackError == 1) error = "播放缓冲耗尽，已停止出声";
  if (e->callbackError == 2) error = "音频输出中断或发生变化，已停止出声";
  if (e->callbackError == 3) error = "音频时间轴持续失同步，已停止出声";
  uint64_t w = e->written.load(), r = e->read.load();
  std::ostringstream o;
  o << "{\"state\":" << e->state << ",\"audioPort\":" << e->port
    << ",\"bufferedFrames\":" << (w >= r ? w - r : 0)
    << ",\"playedFrames\":" << r << ",\"totalFrames\":" << e->total
    << ",\"clockOffsetMicros\":" << e->offset
    << ",\"clockRttMicros\":" << e->rtt
    << ",\"latencyCompensationMicros\":" << e->latencyCompensation
    << ",\"hardwarePositionMicros\":" << e->hardwarePositionMicros
    << ",\"hardwareTimestampMicros\":" << e->hardwareTimestampMicros
    << ",\"hardwareClockSource\":" << e->hardwareClockSource
    << ",\"hardwareClockValid\":" << (e->hardwareClockValid ? "true" : "false")
    << ",\"hardwareRateWindows\":" << e->hardwareRateWindows
    << ",\"hardwareRatePpm\":" << e->hardwareRatePpm
    << ",\"outputUnderruns\":" << e->outputUnderruns
    << ",\"outputSampleRate\":" << e->outputSampleRate
    << ",\"callbackFrames\":" << e->callbackFrames
    << ",\"phaseErrorMicros\":" << e->phaseErrorMicros
    << ",\"driftPpm\":" << e->driftPpm << ",\"error\":\"" << escape(error)
    << "\"}";
  return text(o.str());
}
char* hm_probe(const char* path, int verify) {
  Media m;
  std::string error;
  if (!inspect(path, m, verify != 0, error))
    return text("{\"error\":\"" + escape(error) + "\"}");
  std::ostringstream o;
  o << "{\"codec\":\"" << m.codec << "\",\"sampleRate\":" << m.rate
    << ",\"channels\":" << m.channels << ",\"bitsPerSample\":" << m.bits
    << ",\"totalFrames\":" << m.frames
    << ",\"verified\":" << (verify ? "true" : "false") << "}";
  return text(o.str());
}
void hm_free(void* p) { free(p); }
void* hm_convert(const char* input, const char* output) {
  if (!input || !output || strcmp(input, output) == 0) return nullptr;
  FILE* existing = open_file(output, "rb");
  if (existing) {
    fclose(existing);
    return nullptr;
  }
  auto* job = new Conversion();
  job->input = input;
  job->output = output;
  job->worker = std::thread(convert_worker, job);
  return job;
}
char* hm_conversion_status(void* pointer) {
  auto* j = (Conversion*)pointer;
  std::lock_guard<std::mutex> g(j->lock);
  std::ostringstream o;
  o << "{\"state\":" << j->state << ",\"progress\":" << j->progress
    << ",\"error\":\"" << escape(j->error) << "\"}";
  return text(o.str());
}
void hm_conversion_cancel(void* pointer) {
  ((Conversion*)pointer)->cancel = true;
}
void hm_conversion_destroy(void* pointer) {
  auto* j = (Conversion*)pointer;
  if (j->worker.joinable()) j->worker.join();
  delete j;
}
}
