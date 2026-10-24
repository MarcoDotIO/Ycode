/* Ycode performance probe: can a guest thread keep a 60 Hz frame clock?
 * (specs/simulator/display-stream.md section 10). Original Ycode code.
 *
 * A render loop or a display link wakes once per display refresh. This
 * probe asks for a 60 Hz cadence (period 16 666 667 ns) through each
 * public wait primitive for SECONDS seconds and reports, in microseconds,
 * how late each wakeup came against its ideal time, and how many periods
 * were missed:
 *   wait_until   mach_wait_until(absolute deadline), deadlines advancing by
 *                one period (a drift-free loop);
 *   nanosleep    nanosleep(one period) back to back (relative);
 *   dispatch0    a dispatch timer source, interval one period, leeway 0;
 *   dispatchL    the same with the default leeway (DISPATCH_TIMER... none:
 *                leeway = interval / 10, as libdispatch documents);
 *   kevent       an EVFILT_TIMER, NOTE_NSECONDS, period one period;
 *   machrcv      mach_msg receive with MACH_RCV_TIMEOUT, re-armed to the
 *                next absolute period each time.
 * It also compares mach time with CLOCK_MONOTONIC over the run (rate error
 * in ppm) and prints the timebase.
 * Output: "frameclock <name> n= expect= late p50= p90= p99= max= missed=",
 * then "frameclock ok". */
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdint.h>
#include <sys/event.h>

#include "../stage4b/probe_util.h"

#define SECONDS 3
#define PERIOD_NS 16666667ull
#define MAX_SAMPLES (SECONDS * 60 + 64)

static mach_timebase_info_data_t timebase;

static uint64_t ns_to_ticks(uint64_t ns) { return ns * timebase.denom / timebase.numer; }
static double ticks_to_us(uint64_t t) { return (double)t * timebase.numer / timebase.denom / 1000.0; }

static int compare_u64(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

/* wake[i] = mach time of the i-th wakeup; ideal i-th time = start + (i+1) P. */
static void report(const char *name, uint64_t start, const uint64_t *wake, int n)
{
    static uint64_t late[MAX_SAMPLES];
    uint64_t period = ns_to_ticks(PERIOD_NS);
    int missed = 0;
    for (int i = 0; i < n; i++) {
        uint64_t ideal = start + (uint64_t)(i + 1) * period;
        late[i] = wake[i] > ideal ? wake[i] - ideal : 0;
        if (i > 0 && wake[i] - wake[i - 1] > period + period / 2) missed++;
    }
    uint64_t total = n ? wake[n - 1] - start : 0;
    qsort(late, (size_t)n, sizeof late[0], compare_u64);
    int p90 = (n * 9 + 9) / 10 - 1, p99 = (n * 99 + 99) / 100 - 1;
    printf("frameclock %-11s n=%d in %.0f ms (rate %.1f Hz) late p50=%.0f p90=%.0f p99=%.0f max=%.0f us, gaps>1.5P %d\n",
           name, n, ticks_to_us(total) / 1000, n && total ? n / (ticks_to_us(total) / 1e6) : 0, ticks_to_us(late[n / 2]),
           ticks_to_us(late[p90]), ticks_to_us(late[p99]), ticks_to_us(late[n - 1]), missed);
    fflush(stdout);
}

static uint64_t samples[MAX_SAMPLES];
#define COUNT (SECONDS * 60)

static void run_wait_until(void)
{
    uint64_t period = ns_to_ticks(PERIOD_NS), start = mach_absolute_time();
    for (int i = 0; i < COUNT; i++) {
        mach_wait_until(start + (uint64_t)(i + 1) * period);
        samples[i] = mach_absolute_time();
    }
    report("wait_until", start, samples, COUNT);
}

static void run_nanosleep(void)
{
    uint64_t start = mach_absolute_time();
    /* Relative sleeps drift by design; the lateness is measured against the
     * previous wakeup + one period, i.e. the per-sleep overshoot. */
    static uint64_t over[MAX_SAMPLES];
    uint64_t prev = start, period = ns_to_ticks(PERIOD_NS);
    for (int i = 0; i < COUNT; i++) {
        struct timespec ts = {0, (long)PERIOD_NS};
        nanosleep(&ts, NULL);
        samples[i] = mach_absolute_time();
        over[i] = samples[i] - prev > period ? samples[i] - prev - period : 0;
        prev = samples[i];
    }
    qsort(over, COUNT, sizeof over[0], compare_u64);
    printf("frameclock %-11s n=%d overshoot per sleep p50=%.0f p90=%.0f p99=%.0f max=%.0f us (rate %.1f Hz)\n", "nanosleep",
           COUNT, ticks_to_us(over[COUNT / 2]), ticks_to_us(over[COUNT * 9 / 10]), ticks_to_us(over[COUNT * 99 / 100]),
           ticks_to_us(over[COUNT - 1]), COUNT / (ticks_to_us(samples[COUNT - 1] - start) / 1e6));
    fflush(stdout);
}

static _Atomic int fired;
static uint64_t dstart;
static dispatch_semaphore_t done;

static void on_timer(void *ctx)
{
    (void)ctx;
    int i = atomic_fetch_add(&fired, 1);
    if (i < COUNT) samples[i] = mach_absolute_time();
    if (i == COUNT - 1) dispatch_semaphore_signal(done);
}

static void run_dispatch(const char *name, uint64_t leeway)
{
    atomic_store(&fired, 0);
    done = dispatch_semaphore_create(0);
    dispatch_queue_t q = dispatch_queue_create("frameclock", NULL);
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_event_handler_f(t, on_timer);
    dstart = mach_absolute_time();
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)PERIOD_NS), PERIOD_NS, leeway);
    dispatch_resume(t);
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SECONDS + 10) * 1000000000LL)) != 0)
        printf("frameclock %s: timed out after %d wakeups\n", name, atomic_load(&fired));
    dispatch_source_cancel(t);
    report(name, dstart, samples, atomic_load(&fired) < COUNT ? atomic_load(&fired) : COUNT);
}

static void run_kevent(void)
{
    int kq = kqueue();
    if (kq < 0) probe_fail("kqueue");
    struct kevent ev;
    EV_SET(&ev, 1, EVFILT_TIMER, EV_ADD | EV_ENABLE, NOTE_NSECONDS, (intptr_t)PERIOD_NS, NULL);
    uint64_t start = mach_absolute_time();
    if (kevent(kq, &ev, 1, NULL, 0, NULL) < 0) probe_fail("kevent add");
    int n = 0;
    while (n < COUNT) {
        struct kevent out;
        struct timespec to = {2, 0};
        int r = kevent(kq, NULL, 0, &out, 1, &to);
        if (r <= 0) break;
        uint64_t now = mach_absolute_time();
        for (intptr_t k = 0; k < out.data && n < COUNT; k++) samples[n++] = now; /* each expiry counts */
    }
    close(kq);
    report("kevent", start, samples, n);
}

static void run_machrcv(void)
{
    mach_port_t port;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) probe_fail("port");
    uint64_t period = ns_to_ticks(PERIOD_NS), start = mach_absolute_time();
    for (int i = 0; i < COUNT; i++) {
        uint64_t deadline = start + (uint64_t)(i + 1) * period, now = mach_absolute_time();
        uint64_t wait_ms_x1000 = deadline > now ? (uint64_t)ticks_to_us(deadline - now) : 0;
        struct {
            mach_msg_header_t h;
            char body[64];
        } m;
        /* MACH_RCV_TIMEOUT takes milliseconds: round up, the usual way a
         * millisecond API is driven at 60 Hz. */
        mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, port, (mach_msg_timeout_t)((wait_ms_x1000 + 999) / 1000),
                 MACH_PORT_NULL);
        samples[i] = mach_absolute_time();
    }
    report("machrcv", start, samples, COUNT);
}

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    (void)probe_self_path;
    probe_name = "p_frameclock";
    mach_timebase_info(&timebase);
    printf("frameclock timebase %u/%u (%.3f MHz)\n", timebase.numer, timebase.denom, 1000.0 * timebase.denom / timebase.numer);
    struct timespec m0, m1;
    clock_gettime(CLOCK_MONOTONIC, &m0);
    uint64_t t0 = mach_absolute_time();

    run_wait_until();
    run_nanosleep();
    run_dispatch("dispatch0", 0);
    run_dispatch("dispatchL", PERIOD_NS / 10);
    run_kevent();
    run_machrcv();

    clock_gettime(CLOCK_MONOTONIC, &m1);
    uint64_t t1 = mach_absolute_time();
    double mono_ns = (double)(m1.tv_sec - m0.tv_sec) * 1e9 + (double)(m1.tv_nsec - m0.tv_nsec);
    double mach_ns = ticks_to_us(t1 - t0) * 1000;
    printf("frameclock clocks: mach %.3f ms, CLOCK_MONOTONIC %.3f ms, rate error %.0f ppm\n", mach_ns / 1e6, mono_ns / 1e6,
           (mach_ns - mono_ns) / mono_ns * 1e6);
    printf("frameclock ok\n");
    return 0;
}
