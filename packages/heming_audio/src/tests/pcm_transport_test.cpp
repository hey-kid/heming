#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
using Socket = SOCKET;
constexpr Socket invalidSocket = INVALID_SOCKET;
static void closeSocket(Socket s) { closesocket(s); }
#else
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
using Socket = int;
constexpr Socket invalidSocket = -1;
static void closeSocket(Socket s) { close(s); }
#endif
#include "heming_audio.h"
#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

extern "C" int hm_transport_source_for_testing(void*, const char*, const char*,
                                               const char*);
using Clock = std::chrono::steady_clock;
static constexpr uint32_t rate = 48000, totalFrames = rate * 3;

static void put64(uint8_t* p, uint64_t n) {
  for (int i = 7; i >= 0; --i) { p[i] = uint8_t(n); n >>= 8; }
}
static void put32(uint8_t* p, uint32_t n) {
  for (int i = 3; i >= 0; --i) { p[i] = uint8_t(n); n >>= 8; }
}
static uint64_t get64(const uint8_t* p) {
  uint64_t n = 0;
  for (int i = 0; i < 8; ++i) n = (n << 8) | p[i];
  return n;
}
static uint32_t get32(const uint8_t* p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
         (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}
static uint64_t fingerprint(const char* text) {
  uint64_t hash = 14695981039346656037ull;
  for (; *text; ++text) { hash ^= uint8_t(*text); hash *= 1099511628211ull; }
  return hash;
}
static bool sendAll(Socket s, const void* data, size_t size) {
  auto* p = static_cast<const char*>(data);
  while (size) {
#ifdef _WIN32
    int sent = send(s, p, int(size), 0);
#else
    int sent = int(send(s, p, size, MSG_NOSIGNAL));
#endif
    if (sent <= 0) return false;
    p += sent; size -= sent;
  }
  return true;
}
static bool receive(Socket s, void* data, size_t size) {
  auto* p = static_cast<char*>(data);
  // Small reads deliberately cover headers and PCM split across recv calls.
  while (size) {
    int got = int(recv(s, p, int(std::min<size_t>(size, 137)), 0));
    if (got <= 0) return false;
    p += got; size -= got;
  }
  return true;
}
static Socket connectTo(int port) {
  auto s = socket(AF_INET, SOCK_STREAM, 0);
  assert(s != invalidSocket);
  int yes = 1;
  assert(setsockopt(s, IPPROTO_TCP, TCP_NODELAY,
                   reinterpret_cast<char*>(&yes), sizeof(yes)) == 0);
#ifdef _WIN32
  DWORD timeout = 2000;
#else
  timeval timeout{2, 0};
#endif
  assert(setsockopt(s, SOL_SOCKET, SO_RCVTIMEO,
                   reinterpret_cast<char*>(&timeout), sizeof(timeout)) == 0);
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_port = htons(uint16_t(port));
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  assert(connect(s, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
  return s;
}
static void handshake(Socket s) {
  std::array<uint8_t, 24> hello{};
  put32(hello.data(), 0x484d5031); put32(hello.data() + 4, 1);
  put64(hello.data() + 8, fingerprint("transport-session"));
  put64(hello.data() + 16, fingerprint("transport-task"));
  assert(sendAll(s, hello.data(), 7));
  assert(sendAll(s, hello.data() + 7, hello.size() - 7));
  std::array<uint8_t, 16> reply{};
  assert(receive(s, reply.data(), reply.size()));
  assert(get64(reply.data()) == totalFrames);
  assert(get32(reply.data() + 8) == rate && get32(reply.data() + 12) == 2);
}
static int16_t sample(uint64_t frame, int channel) {
  return int16_t(int((frame * 37 + channel * 101) % 30001) - 15000);
}
static uint32_t pull(Socket s, uint64_t position, uint32_t frames) {
  std::array<uint8_t, 12> request{};
  put64(request.data(), position); put32(request.data() + 8, frames);
  assert(sendAll(s, request.data(), 5));
  assert(sendAll(s, request.data() + 5, request.size() - 5));
  std::array<uint8_t, 12> header{};
  assert(receive(s, header.data(), header.size()));
  assert(get64(header.data()) == position);
  const auto got = get32(header.data() + 8);
  assert(got == std::min<uint64_t>(frames, totalFrames - position));
  std::vector<int16_t> pcm(got * 2);
  assert(receive(s, pcm.data(), pcm.size() * sizeof(int16_t)));
  for (uint32_t i = 0; i < got; ++i) {
    assert(pcm[i * 2] == sample(position + i, 0));
    assert(pcm[i * 2 + 1] == sample(position + i, 1));
  }
  return got;
}
static void number(std::ofstream& out, uint32_t value, int bytes) {
  for (int i = 0; i < bytes; ++i) out.put(char(value >> (i * 8)));
}
static void makeWav(const std::filesystem::path& path) {
  std::ofstream out(path, std::ios::binary);
  out.write("RIFF", 4); number(out, 36 + totalFrames * 4, 4);
  out.write("WAVEfmt ", 8); number(out, 16, 4); number(out, 1, 2);
  number(out, 2, 2); number(out, rate, 4); number(out, rate * 4, 4);
  number(out, 4, 2); number(out, 16, 2);
  out.write("data", 4); number(out, totalFrames * 4, 4);
  for (uint32_t i = 0; i < totalFrames; ++i) {
    number(out, uint16_t(sample(i, 0)), 2);
    number(out, uint16_t(sample(i, 1)), 2);
  }
}
int main() {
#ifdef _WIN32
  WSADATA startup;
  assert(WSAStartup(MAKEWORD(2, 2), &startup) == 0);
#endif
  auto path = std::filesystem::temp_directory_path() /
      ("heming-pcm-transport-" + std::to_string(hm_now_us()) + ".wav");
  makeWav(path);
  void* engine = hm_create();
  const int port = hm_transport_source_for_testing(engine,
      path.u8string().c_str(), "transport-session", "transport-task");
  assert(port > 0);
  Socket s = connectTo(port);
  handshake(s);
  uint64_t position = 0;
  const auto started = Clock::now();
  // Frequent short replies expose the split-header/body ACK dependency. The
  // budget allows scheduler noise, but not a delayed ACK on every reply.
  for (int i = 0; i < 100; ++i) position += pull(s, position, 48);
  const auto tinyMs = std::chrono::duration_cast<std::chrono::milliseconds>(
      Clock::now() - started).count();
  std::cout << "100 small PCM pulls: " << tinyMs << " ms\n" << std::flush;
  assert(tinyMs < 2000);
  while (position < totalFrames) position += pull(s, position, 4800);
  assert(pull(s, position, 1) == 0); // Explicit EOF preserves wire framing.
  closeSocket(s);
  // A new client disconnecting halfway through a pull must not pin shutdown.
  s = connectTo(port); handshake(s);
  std::array<uint8_t, 5> truncated{};
  assert(sendAll(s, truncated.data(), truncated.size()));
  closeSocket(s);
  // Also cancel an authenticated peer that stays connected without a request.
  s = connectTo(port); handshake(s);
  const auto stopping = Clock::now();
  hm_stop(engine);
  const auto stopMs = std::chrono::duration_cast<std::chrono::milliseconds>(
      Clock::now() - stopping).count();
  assert(stopMs < 1500);
  closeSocket(s);
  hm_destroy(engine);
  std::filesystem::remove(path);
  std::cout << "PCM bytes, chunk boundaries, EOF and cancellation passed; stop "
            << stopMs << " ms\n";
}
