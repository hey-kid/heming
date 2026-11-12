#pragma once
#include <algorithm>
#include <cstdint>

namespace heming {
// AAudio's timestamp frame and framesWritten use the same stream frame domain.
// Vendor timestamps can be temporarily unavailable or stale during startup.
inline bool estimateAndroidPresentation(int64_t nowMicros, int64_t frame,
                                        int64_t timestampNanos,
                                        int64_t framesWritten,
                                        int32_t sampleRate,
                                        int64_t* presentationMicros) {
  if (!presentationMicros || sampleRate <= 0 || sampleRate > 768000 ||
      frame < 0 || framesWritten < frame || timestampNanos <= 0)
    return false;
  const int64_t stamp = timestampNanos / 1000;
  const int64_t age = nowMicros - stamp;
  const int64_t queued = framesWritten - frame;
  if (age < -10000 || age > 1000000 || queued > int64_t(sampleRate) * 2)
    return false;
  const int64_t candidate = stamp + queued * 1000000 / sampleRate;
  if (candidate < nowMicros - 100000 || candidate > nowMicros + 2000000)
    return false;
  *presentationMicros = candidate;
  return true;
}

// A file is not completed until the last submitted output frame is expected to
// have reached the device. User-requested stop still bypasses this drain.
class OutputDrain {
 public:
  void arm(int64_t firstPresentationMicros, uint32_t outputFrames,
           uint32_t sampleRate, int64_t guardMicros) {
    if (!sampleRate) return;
    deadline_ =
        std::max(deadline_, firstPresentationMicros +
                                int64_t(outputFrames) * 1000000 / sampleRate +
                                std::max<int64_t>(0, guardMicros));
  }
  bool armed() const { return deadline_ != 0; }
  bool complete(int64_t nowMicros) const {
    return armed() && nowMicros >= deadline_;
  }

 private:
  int64_t deadline_ = 0;
};

// Abort only a sustained >50ms software phase error supported by fresh native
// timestamps. Startup, missing/fallback timestamps and one outlier reset it.
class SustainedPhaseGuard {
 public:
  bool observe(int64_t nowMicros, int64_t errorMicros,
               int64_t hardwareTimestampMicros, bool activelyPlaying) {
    if (!activelyPlaying || hardwareTimestampMicros <= 0 ||
        (errorMicros >= -50000 && errorMicros <= 50000)) {
      reset();
      return false;
    }
    if (tracking_ &&
        (hardwareTimestampMicros < lastStamp_ || nowMicros < since_))
      reset();
    if (tracking_ && hardwareTimestampMicros == lastStamp_) return false;
    if (!tracking_) {
      tracking_ = true;
      since_ = nowMicros;
    }
    lastStamp_ = hardwareTimestampMicros;
    ++samples_;
    return samples_ >= 3 && nowMicros - since_ >= 100000;
  }

 private:
  void reset() {
    tracking_ = false;
    since_ = lastStamp_ = 0;
    samples_ = 0;
  }
  bool tracking_ = false;
  int64_t since_ = 0, lastStamp_ = 0;
  int samples_ = 0;
};
}  // namespace heming
