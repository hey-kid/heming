#pragma once
#include <cmath>
#include <cstdint>

namespace heming {
// Position input is stream seconds (raw position / GetFrequency), never the
// application's converted PCM frame counter. Accessed by one callback thread.
class HardwareClockRate {
 public:
  bool observe(double deviceSeconds, int64_t monotonicMicros) {
    if (!std::isfinite(deviceSeconds) || deviceSeconds < 0 ||
        monotonicMicros <= 0)
      return false;
    if (!hasAnchor_) {
      anchor(deviceSeconds, monotonicMicros);
      return true;
    }
    const int64_t elapsed = monotonicMicros - anchorMicros_;
    const double advanced = deviceSeconds - anchorSeconds_;
    if (elapsed == 0 && advanced == 0) return false;
    if (elapsed <= 0 || advanced < 0 || elapsed > 2000000) {
      goodWindows_ = 0;
      rate_ = 1;
      anchor(deviceSeconds, monotonicMicros);
      return false;
    }
    if (elapsed < 500000) return true;
    const double candidate = advanced * 1000000.0 / elapsed;
    anchor(deviceSeconds, monotonicMicros);
    if (candidate < 0.995 || candidate > 1.005) {
      goodWindows_ = 0;
      return false;
    }
    rate_ += (candidate - rate_) * 0.2;
    ++goodWindows_;
    return true;
  }
  bool stable() const { return goodWindows_ >= 3; }
  double rate() const { return stable() ? rate_ : 1.0; }
  double ppm() const { return (rate() - 1.0) * 1000000.0; }
  int goodWindows() const { return goodWindows_; }

 private:
  void anchor(double seconds, int64_t micros) {
    hasAnchor_ = true;
    anchorSeconds_ = seconds;
    anchorMicros_ = micros;
  }
  bool hasAnchor_ = false;
  double anchorSeconds_ = 0, rate_ = 1;
  int64_t anchorMicros_ = 0;
  int goodWindows_ = 0;
};
}  // namespace heming
