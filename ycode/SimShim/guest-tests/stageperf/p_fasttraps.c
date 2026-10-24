/* Ycode performance probe: the exit-free hot calls of
 * specs/simulator/fast-traps.md agree with the traps they replace.
 * Original Ycode code.
 *
 * The probe makes each trap itself with an inline `svc #0x80`, so one run
 * compares the library's answer (in place when the commpage allows it,
 * otherwise also a trap) with the kernel's:
 *   1. mach time: trap(-3) <= mach_absolute_time() <= trap(-3), and the same
 *      for mach_continuous_time and trap -4 (1000 rounds);
 *   2. monotonic within and across 8 threads (200000 reads each);
 *   3. across processes: before <= a spawned child's clock <= after;
 *   4. a 50 ms nanosleep takes 40...2000 ms of mach time;
 *   5. gettimeofday() within 5 ms of BSD 116, also after a 1.2 s pause
 *      (the commpage snapshot is then stale and refreshed by the trap);
 *   6. getuid/geteuid/getgid/getegid equal BSD 24/25/47/43, also in a
 *      spawned child (fork is not implemented by Ycode's kernel: posix_spawn
 *      is the process-creation path; a fork child is checked when fork
 *      works);
 *   7. per-call cost of every path (ns).
 * Prints "fasttraps ok flags=0xNN ..." then one "bench" line. */
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <sys/time.h>

#include "../stage4b/probe_util.h"

#define THREADS 8
#define READS 200000
#define COMMPAGE_RW 0xFFFFFC000ull

static uint64_t trap_mach(long n)
{
    register uint64_t x0 __asm__("x0") = 0;
    register long x16 __asm__("x16") = n;
    __asm__ volatile("svc #0x80" : "+r"(x0), "+r"(x16) : : "x1", "memory", "cc");
    return x0;
}

static uint64_t trap_bsd0(long n)
{
    register uint64_t x0 __asm__("x0");
    register long x16 __asm__("x16") = n;
    __asm__ volatile("svc #0x80" : "=r"(x0), "+r"(x16) : : "x1", "memory", "cc");
    return x0;
}

static int trap_gettimeofday(struct timeval *tv)
{
    register uint64_t x0 __asm__("x0") = (uint64_t)(uintptr_t)tv;
    register uint64_t x1 __asm__("x1") = 0;
    register uint64_t x2 __asm__("x2") = 0;
    register long x16 __asm__("x16") = 116;
    __asm__ volatile("svc #0x80" : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x16) : : "memory", "cc");
    return (int)x0;
}

static int64_t tv_us(const struct timeval *tv) { return (int64_t)tv->tv_sec * 1000000 + tv->tv_usec; }

static _Atomic uint64_t published;
static _Atomic long backwards_within, backwards_across;

static void *reader(void *arg)
{
    (void)arg;
    uint64_t last = 0;
    for (int i = 0; i < READS; i++) {
        uint64_t seen = atomic_load_explicit(&published, memory_order_acquire);
        uint64_t now = mach_absolute_time();
        if (now < last)
            atomic_fetch_add(&backwards_within, 1);
        if (now < seen)
            atomic_fetch_add(&backwards_across, 1);
        last = now;
        uint64_t cur = seen;
        while (cur < now && !atomic_compare_exchange_weak_explicit(&published, &cur, now, memory_order_release,
                                                                  memory_order_acquire)) {
        }
    }
    return NULL;
}

static void check_ids(const char *where)
{
    static const long nums[4] = {24, 25, 47, 43};
    unsigned lib[4] = {getuid(), geteuid(), getgid(), getegid()};
    for (int i = 0; i < 4; i++) {
        unsigned trapped = (unsigned)trap_bsd0(nums[i]);
        if (lib[i] != trapped)
            probe_fail("%s: id call %d: library %u, BSD %ld %u", where, i, lib[i], nums[i], trapped);
    }
}

static double ns_per_call(uint64_t t0, uint64_t t1, long n, const mach_timebase_info_data_t *tb)
{
    return (double)(t1 - t0) * tb->numer / tb->denom / (double)n;
}

int main(int argc, char **argv)
{
    probe_name = "p_fasttraps";
    if (argc >= 3 && strcmp(argv[1], "child") == 0) {
        check_ids("spawned child");
        uint64_t now = mach_absolute_time();
        int fd = atoi(argv[2]);
        if (write(fd, &now, sizeof now) != (ssize_t)sizeof now)
            return 3;
        return 0;
    }
    unsigned flags = *(volatile uint8_t *)(uintptr_t)(COMMPAGE_RW + 0x0F8);
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);

    /* 1. The library's clock lies between two kernel readings. */
    for (int i = 0; i < 1000; i++) {
        uint64_t a = trap_mach(-3), b = mach_absolute_time(), c = trap_mach(-3);
        if (!(a <= b && b <= c))
            probe_fail("mach_absolute_time %llu outside the traps [%llu, %llu]", (unsigned long long)b,
                       (unsigned long long)a, (unsigned long long)c);
        a = trap_mach(-4);
        b = mach_continuous_time();
        c = trap_mach(-4);
        if (!(a <= b && b <= c))
            probe_fail("mach_continuous_time %llu outside the traps [%llu, %llu]", (unsigned long long)b,
                       (unsigned long long)a, (unsigned long long)c);
        b = mach_approximate_time();
        c = trap_mach(-3);
        if (b > c)
            probe_fail("mach_approximate_time %llu is newer than the trap %llu", (unsigned long long)b,
                       (unsigned long long)c);
    }

    /* 2. Threads. */
    pthread_t t[THREADS];
    for (int i = 0; i < THREADS; i++)
        if (pthread_create(&t[i], NULL, reader, NULL) != 0)
            probe_fail("pthread_create %d", i);
    for (int i = 0; i < THREADS; i++)
        pthread_join(t[i], NULL);
    if (backwards_within != 0 || backwards_across != 0)
        probe_fail("time went backwards: %ld within a thread, %ld across threads", (long)backwards_within,
                   (long)backwards_across);
    /* A thread created after the others still agrees with the kernel. */
    {
        uint64_t a = trap_mach(-3), b = mach_absolute_time(), c = trap_mach(-3);
        if (!(a <= b && b <= c))
            probe_fail("after thread creation: %llu outside [%llu, %llu]", (unsigned long long)b,
                       (unsigned long long)a, (unsigned long long)c);
    }

    /* 3. Across processes (and the ids in the child). */
    int fds[2];
    if (pipe(fds) != 0)
        probe_fail("pipe: %s", strerror(errno));
    char fdtext[16];
    snprintf(fdtext, sizeof fdtext, "%d", fds[1]);
    const char *extra[] = {fdtext, NULL};
    uint64_t before = mach_absolute_time();
    pid_t child = -1;
    int err = probe_spawn(&child, probe_self_path(argv[0]), NULL, NULL, "child", extra);
    if (err != 0)
        probe_fail("posix_spawn: %d (%s)", err, strerror(err));
    uint64_t theirs = 0;
    if (read(fds[0], &theirs, sizeof theirs) != (ssize_t)sizeof theirs)
        probe_fail("read from the child: %s", strerror(errno));
    uint64_t after = mach_absolute_time();
    probe_expect_exit(child, 0, "spawned child");
    if (theirs < before || theirs > after)
        probe_fail("child clock %llu outside [%llu, %llu]", (unsigned long long)theirs, (unsigned long long)before,
                   (unsigned long long)after);

    /* 4. Sleeping agrees with the clock. */
    uint64_t s0 = mach_absolute_time();
    probe_sleep_ms(50);
    uint64_t ms = (mach_absolute_time() - s0) * tb.numer / tb.denom / 1000000;
    if (ms < 40 || ms > 2000)
        probe_fail("a 50 ms sleep took %llu ms of mach time", (unsigned long long)ms);

    /* 5. The wall clock. */
    int64_t worst = 0;
    for (int round = 0; round < 2; round++) {
        for (int i = 0; i < 100; i++) {
            struct timeval a, b, c;
            trap_gettimeofday(&a);
            gettimeofday(&b, NULL);
            trap_gettimeofday(&c);
            int64_t lo = tv_us(&a) - 5000, hi = tv_us(&c) + 5000;
            if (tv_us(&b) < lo || tv_us(&b) > hi)
                probe_fail("gettimeofday %lld us outside [%lld, %lld] (round %d)", (long long)tv_us(&b),
                           (long long)tv_us(&a), (long long)tv_us(&c), round);
            int64_t d = tv_us(&b) - tv_us(&a);
            if (d < 0)
                d = -d;
            if (d > worst)
                worst = d;
        }
        if (round == 0)
            probe_sleep_ms(1200); /* the snapshot is now stale */
    }

    /* 6. Credentials (and a fork child, when fork works). */
    check_ids("parent");
    pid_t f = fork();
    if (f == 0) {
        check_ids("fork child");
        _exit(0);
    }
    const char *forked = "unsupported";
    if (f > 0) {
        probe_expect_exit(f, 0, "fork child");
        forked = "ok";
    }

    /* 7. Cost per call. */
    enum { N = 20000 };
    double r[10];
    uint64_t t0;
    volatile uint64_t sink = 0;
    struct timeval tv;
    t0 = mach_absolute_time(); for (int i = 0; i < N; i++) sink += mach_absolute_time(); r[0] = ns_per_call(t0, mach_absolute_time(), N, &tb);
    t0 = mach_absolute_time(); for (int i = 0; i < N; i++) sink += trap_mach(-3); r[1] = ns_per_call(t0, mach_absolute_time(), N, &tb);
    t0 = mach_absolute_time(); for (int i = 0; i < N; i++) sink += mach_continuous_time(); r[2] = ns_per_call(t0, mach_absolute_time(), N, &tb);
    t0 = mach_absolute_time(); for (int i = 0; i < N; i++) { gettimeofday(&tv, NULL); sink += tv.tv_usec; } r[3] = ns_per_call(t0, mach_absolute_time(), N, &tb);
    t0 = mach_absolute_time(); for (int i = 0; i < N; i++) { trap_gettimeofday(&tv); sink += tv.tv_usec; } r[4] = ns_per_call(t0, mach_absolute_time(), N, &tb);
    t0 = mach_absolute_time(); for (int i = 0; i < N; i++) sink += geteuid(); r[5] = ns_per_call(t0, mach_absolute_time(), N, &tb);
    t0 = mach_absolute_time(); for (int i = 0; i < N; i++) sink += trap_bsd0(25); r[6] = ns_per_call(t0, mach_absolute_time(), N, &tb);
    t0 = mach_absolute_time(); for (int i = 0; i < N; i++) sink += (uint64_t)getppid(); r[7] = ns_per_call(t0, mach_absolute_time(), N, &tb);
    (void)sink;

    printf("fasttraps ok flags=0x%02x threads=%d cross=ok sleep_ms=%llu tod_worst_us=%lld fork=%s\n", flags, THREADS,
           (unsigned long long)ms, (long long)worst, forked);
    printf("bench ns/call: mach_absolute_time %.0f (trap -3 %.0f), mach_continuous_time %.0f, gettimeofday %.0f "
           "(BSD 116 %.0f), geteuid %.0f (BSD 25 %.0f), getppid (trap) %.0f\n",
           r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]);
    return 0;
}
