// GaugeDemo's deliberate work (specs/ide/profiler.md §10): CPU-bound C
// functions with signposts, so a profile has a known hot path.
#ifndef GAUGEDEMO_WORK_H
#define GAUGEDEMO_WORK_H
#include <stdint.h>

/// One round on the calling thread: a "Crunch" signpost interval holding
/// a "Sieve" interval (about 60 % of the round) and a "Matrix" interval
/// (about 40 %). Returns the round's milliseconds (measured with
/// mach_absolute_time) and adds to a checksum.
double gauge_demo_round(int round, uint64_t *checksum);

/// A short piece of background work (a "Background" interval).
uint64_t gauge_demo_background(int round);

/// Emits a "Tick" signpost event.
void gauge_demo_tick(int round);
#endif
