#include "sync/hardware_clock.h"

#include <cassert>
#include <cmath>
#include <limits>

int main() {
  heming::HardwareClockRate clock;
  assert(clock.observe(0, 1000000));
  // Actual hardware advances 100 ppm faster than the monotonic reference.
  for (int i = 1; i <= 40; ++i)
    assert(clock.observe(i * 0.5 * 1.0001, 1000000 + i * 500000));
  assert(clock.stable());
  assert(std::abs(clock.ppm() - 100) < 0.1);
  assert(!clock.observe(20 * 1.0001, 21000000));
  assert(clock.stable());
  assert(!clock.observe(std::numeric_limits<double>::quiet_NaN(), 22000000));
  // Reset/backward device position must not retain the previous rate model.
  assert(!clock.observe(0, 22000000));
  assert(!clock.stable());
  assert(clock.rate() == 1.0);
  // Reject a quantized/outlier sample instead of feeding it to the resampler.
  assert(!clock.observe(2, 22500000));
  assert(!clock.stable());
  assert(clock.observe(2.5, 23000000));
  assert(clock.observe(3, 23500000));
  assert(clock.observe(3.5, 24000000));
  assert(clock.stable());
  assert(std::abs(clock.ppm()) < 0.01);
  return 0;
}
