// GaugeDemo's deliberate work (Work.h). Original Ycode sample code.
#include "Work.h"
#include <mach/mach_time.h>
#include <os/log.h>
#include <os/signpost.h>
#include <stdlib.h>
#include <string.h>

static os_log_t demo_log(void) {
    static os_log_t log;
    if (!log) log = os_log_create("dev.ycode.GaugeDemo", "Work");
    return log;
}

/// Counts primes below `limit` with a sieve (memory-bound inner loops).
__attribute__((noinline)) static uint64_t sieve_primes(uint32_t limit) {
    uint8_t *composite = calloc(limit, 1);
    uint64_t count = 0;
    for (uint32_t i = 2; i < limit; i++) {
        if (composite[i]) continue;
        count += i;
        for (uint64_t j = (uint64_t)i * i; j < limit; j += i) composite[j] = 1;
    }
    free(composite);
    return count;
}

/// n × n matrix product (compute-bound).
__attribute__((noinline)) static uint64_t multiply_matrices(int n, int seed) {
    double *a = malloc(sizeof(double) * n * n), *b = malloc(sizeof(double) * n * n), *c = calloc((size_t)n * n, sizeof(double));
    for (int i = 0; i < n * n; i++) { a[i] = (i * 7 + seed) % 13; b[i] = (i * 11 + seed) % 17; }
    for (int i = 0; i < n; i++)
        for (int k = 0; k < n; k++) {
            double aik = a[i * n + k];
            for (int j = 0; j < n; j++) c[i * n + j] += aik * b[k * n + j];
        }
    uint64_t sum = 0;
    for (int i = 0; i < n * n; i += n + 1) sum += (uint64_t)c[i];
    free(a); free(b); free(c);
    return sum;
}

static double ms_since(uint64_t start) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)(mach_absolute_time() - start) * tb.numer / tb.denom / 1e6;
}

double gauge_demo_round(int round, uint64_t *checksum) {
    os_log_t log = demo_log();
    os_signpost_id_t id = os_signpost_id_generate(log);
    uint64_t start = mach_absolute_time();
    os_signpost_interval_begin(log, id, "Crunch", "round %d", round);

    os_signpost_id_t sid = os_signpost_id_generate(log);
    os_signpost_interval_begin(log, sid, "Sieve");
    *checksum += sieve_primes(6000000 + (uint32_t)(round & 7));
    os_signpost_interval_end(log, sid, "Sieve");

    os_signpost_id_t mid = os_signpost_id_generate(log);
    os_signpost_interval_begin(log, mid, "Matrix");
    *checksum += multiply_matrices(190, round);
    os_signpost_interval_end(log, mid, "Matrix");

    os_signpost_interval_end(log, id, "Crunch", "done");
    return ms_since(start);
}

uint64_t gauge_demo_background(int round) {
    os_log_t log = demo_log();
    os_signpost_id_t id = os_signpost_id_generate(log);
    os_signpost_interval_begin(log, id, "Background");
    uint64_t s = sieve_primes(400000 + (uint32_t)round);
    os_signpost_interval_end(log, id, "Background");
    return s;
}

void gauge_demo_tick(int round) {
    os_signpost_event_emit(demo_log(), OS_SIGNPOST_ID_EXCLUSIVE, "Tick", "round %d", round);
}
