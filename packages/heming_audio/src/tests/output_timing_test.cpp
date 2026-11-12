#include "sync/output_timing.h"

#include <cassert>

int main() {
  int64_t predicted = 0;
  assert(heming::estimateAndroidPresentation(1000000, 48000, 1000000000, 48480,
                                             48000, &predicted));
  assert(predicted == 1010000);
  assert(!heming::estimateAndroidPresentation(3000000, 48000, 1000000000, 48480,
                                              48000, &predicted));
  assert(!heming::estimateAndroidPresentation(1000000, -1, 1000000000, 48480,
                                              48000, &predicted));
  assert(!heming::estimateAndroidPresentation(1000000, 48000, 1000000000, 47999,
                                              48000, &predicted));
  assert(!heming::estimateAndroidPresentation(1000000, 48000, 1000000000,
                                              500000, 48000, &predicted));
  // Counters crossing signed 32-bit range must retain their frame difference.
  assert(heming::estimateAndroidPresentation(
      1000000, int64_t{1} << 33, 1000000000, (int64_t{1} << 33) + 480, 48000,
      &predicted));
  assert(predicted == 1010000);
  heming::OutputDrain drain;
  assert(!drain.complete(2000000));
  drain.arm(1000000, 480, 48000, 5000);
  assert(!drain.complete(1014999));
  assert(drain.complete(1015000));
  drain.arm(900000, 48, 48000, 0);
  assert(!drain.complete(1014999));
  heming::SustainedPhaseGuard guard;
  // Startup and fallback estimates never trip the trusted-timestamp guard.
  assert(!guard.observe(1000000, 100000, 900000, false));
  assert(!guard.observe(1100000, 100000, 0, true));
  assert(!guard.observe(1200000, 100000, 1190000, true));
  assert(!guard.observe(1300000, 100000, 1190000, true));  // duplicate
  assert(!guard.observe(1310000, 0, 1300000, true));       // outlier recovered
  assert(!guard.observe(1400000, -100000, 1390000, true));
  assert(!guard.observe(1450000, -100000, 1440000, true));
  assert(guard.observe(1500000, -100000, 1490000, true));
  // A missing timestamp resets the consecutive failure window.
  assert(!guard.observe(1600000, -100000, 0, true));
  assert(!guard.observe(1700000, -100000, 1690000, true));
  return 0;
}
