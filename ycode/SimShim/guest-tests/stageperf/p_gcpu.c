/* Ycode performance probe: guest execution efficiency (specs/simulator/guest-cpu.md).
 * Original Ycode code. The same source builds as a guest program (iOS
 * simulator platform, build-stageperf.sh) and as a native Linux arm64 program
 * (cc -O2 -pthread p_gcpu.c), so each workload can be timed both ways on the
 * same host.
 *
 * Usage: p_gcpu [-r repeats] [-d dir] [-f file] [phase ...]
 *   phases (default: all but "switch" and "null"; "files" and "file" only with -d/-f):
 *   alu chase tlb16k tlb4k hash copy touch branch str files file atomic timer trap churn
 *   switch null
 *   -d dir: a directory of regular files for "files" (open, mmap, read, unmap)
 *   -f file: a large read-only file for "file" (cold and warm page touches)
 * Every result line: "gcpu <name> <median> <unit> (min <a> max <b>, n <r>)".
 * "null" does nothing (start-up cost of the program for counter baselines).
 * Native only: GCPU_NO_THP=1 turns transparent huge pages off for the process
 * (prctl PR_SET_THP_DISABLE), so its anonymous memory is 4 KiB pages as the
 * guest's mostly is. */
#define _GNU_SOURCE
#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach_time.h>
#endif
#ifdef __linux__
#include <sys/prctl.h>
#endif

#define MAXR 32
static int repeats = 5;
static const char *dir_arg, *file_arg;

static double now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e9 + (double)t.tv_nsec;
}

static uint64_t rng = 88172645463325252ull;
static uint64_t next(void)
{
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}

static volatile uint64_t sink;

static int cmp_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static void report(const char *name, const char *unit, double *v, int n)
{
    qsort(v, (size_t)n, sizeof v[0], cmp_double);
    printf("gcpu %-18s %10.3f %-6s (min %.3f max %.3f, n %d)\n", name, v[n / 2], unit, v[0], v[n - 1], n);
    fflush(stdout);
}

static void *big_alloc(size_t size)
{
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        exit(1);
    }
    return p;
}

/* ---- 1. alu: a dependent integer chain ---- */
static void phase_alu(void)
{
    double v[MAXR];
    const long iters = 100000000;
    for (int r = 0; r < repeats; r++) {
        uint64_t x = 1 + (uint64_t)r;
        double t0 = now_ns();
        for (long i = 0; i < iters; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; }
        v[r] = (now_ns() - t0) / (double)iters;
        sink = x;
    }
    report("alu", "ns/it", v, repeats);
}

/* ---- pointer chases ---- */
/* n slots; slot i at base + i*stride + (i*rot % wrap); a random cycle. */
static void **make_chain(char *mem, size_t n, size_t stride, size_t rot, size_t wrap)
{
    size_t *order = malloc(n * sizeof(size_t));
    for (size_t i = 0; i < n; i++) order[i] = i;
    for (size_t i = n - 1; i > 0; i--) {
        size_t j = next() % (i + 1);
        size_t t = order[i]; order[i] = order[j]; order[j] = t;
    }
#define SLOT(i) ((void **)(mem + (i) * stride + (wrap ? ((i) * rot) % wrap : 0)))
    for (size_t i = 0; i < n; i++) *SLOT(order[i]) = SLOT(order[(i + 1) % n]);
    void **start = SLOT(order[0]);
#undef SLOT
    free(order);
    return start;
}

static double run_chase(void **p, size_t hops)
{
    double t0 = now_ns();
    for (size_t i = 0; i < hops; i++) p = (void **)*p;
    double t = (now_ns() - t0) / (double)hops;
    sink = (uint64_t)(uintptr_t)p;
    return t;
}

static void chase_case(const char *name, size_t n, size_t stride, size_t rot, size_t wrap, size_t hops)
{
    size_t bytes = n * stride + 4096;
    char *mem = big_alloc(bytes);
    void **p = make_chain(mem, n, stride, rot, wrap);
    run_chase(p, n < hops ? n : hops); /* warm */
    double v[MAXR];
    for (int r = 0; r < repeats; r++) v[r] = run_chase(p, hops);
    report(name, "ns/hop", v, repeats);
    munmap(mem, bytes);
}

static void phase_chase(void)
{
    chase_case("chase_l1_16k", 256, 64, 0, 0, 50000000);
    chase_case("chase_l2_1m", 16384, 64, 0, 0, 20000000);
    chase_case("chase_l3_8m", 131072, 64, 0, 0, 10000000);
    chase_case("chase_dram_512m", 8388608, 64, 0, 0, 4000000);
}

/* One cache line per page: the data stays cached, the translations do not. */
static void phase_tlb(size_t page, const char *prefix)
{
    static const size_t counts[] = {64, 512, 2048, 8192, 32768};
    for (size_t k = 0; k < sizeof counts / sizeof counts[0]; k++) {
        char name[32];
        snprintf(name, sizeof name, "%s_%zu", prefix, counts[k]);
        chase_case(name, counts[k], page, 64, page, 10000000);
    }
}

/* ---- hash table (open addressing, 16-byte slots) ---- */
static void phase_hash(void)
{
    const size_t slots = (size_t)1 << 22, mask = slots - 1;
    const size_t inserts = slots / 2, lookups = slots;
    uint64_t *tab = big_alloc(slots * 16);
    double vi[MAXR], vl[MAXR];
    for (int r = 0; r < repeats; r++) {
        memset(tab, 0, slots * 16);
        rng = 12345 + (uint64_t)r;
        double t0 = now_ns();
        for (size_t i = 0; i < inserts; i++) {
            uint64_t key = next() | 1;
            size_t h = (size_t)((key * 0x9E3779B97F4A7C15ull) >> 40) & mask;
            while (tab[2 * h] != 0 && tab[2 * h] != key) h = (h + 1) & mask;
            tab[2 * h] = key;
            tab[2 * h + 1] = i;
        }
        vi[r] = (now_ns() - t0) / (double)inserts;
        rng = 12345 + (uint64_t)r;
        uint64_t found = 0;
        t0 = now_ns();
        for (size_t i = 0; i < lookups; i++) {
            uint64_t key = (i & 1) ? (next() | 1) : (next() & ~1ull);
            size_t h = (size_t)((key * 0x9E3779B97F4A7C15ull) >> 40) & mask;
            while (tab[2 * h] != 0) {
                if (tab[2 * h] == key) { found += tab[2 * h + 1]; break; }
                h = (h + 1) & mask;
            }
        }
        vl[r] = (now_ns() - t0) / (double)lookups;
        sink = found;
    }
    report("hash_insert_64m", "ns/op", vi, repeats);
    report("hash_lookup_64m", "ns/op", vl, repeats);
    munmap(tab, slots * 16);
}

/* ---- memory bandwidth ---- */
__attribute__((noinline, no_builtin("memcpy")))
static void own_copy(uint64_t *restrict d, const uint64_t *restrict s, size_t bytes)
{
    for (size_t i = 0; i < bytes / 8; i += 8) {
        uint64_t a = s[i], b = s[i + 1], c = s[i + 2], e = s[i + 3];
        uint64_t f = s[i + 4], g = s[i + 5], h = s[i + 6], k = s[i + 7];
        d[i] = a; d[i + 1] = b; d[i + 2] = c; d[i + 3] = e;
        d[i + 4] = f; d[i + 5] = g; d[i + 6] = h; d[i + 7] = k;
    }
}

static void copy_case_at(const char *name, size_t bytes, int kind, size_t src_off)
{
    char *src = big_alloc(bytes + 64) + src_off, *dst = big_alloc(bytes + 64);
    memset(src, 1, bytes);
    memset(dst, 2, bytes);
    size_t total = (size_t)1 << 30; /* about 1 GiB moved per repeat */
    size_t rounds = total / bytes;
    if (rounds < 1) rounds = 1;
    double v[MAXR];
    for (int r = 0; r < repeats; r++) {
        double t0 = now_ns();
        for (size_t i = 0; i < rounds; i++) {
            switch (kind) {
            case 0: memcpy(dst, src, bytes); break;
            case 1: own_copy((uint64_t *)dst, (const uint64_t *)src, bytes); break;
            case 2: memset(dst, (int)(i & 0x7f) | 1, bytes); break;
            default: memset(dst, 0, bytes); break;
            }
            __asm__ volatile("" ::: "memory");
        }
        double s = (now_ns() - t0) / 1e9;
        v[r] = (double)(rounds * bytes) / s / 1e9;
    }
    sink = (uint64_t)dst[bytes / 2];
    report(name, "GB/s", v, repeats);
    munmap(src - src_off, bytes + 64);
    munmap(dst, bytes + 64);
}

static void copy_case(const char *name, size_t bytes, int kind) { copy_case_at(name, bytes, kind, 0); }

static void phase_copy(void)
{
    copy_case("memcpy_8k", 8192, 0);
    copy_case_at("memcpy_8k_unal", 8192, 0, 3);
    copy_case_at("memcpy_100_unal", 100, 0, 5);
    copy_case("memset_100", 100, 2);
    copy_case("memcpy_512k", 512 << 10, 0);
    copy_case("memcpy_128m", 128 << 20, 0);
    copy_case("owncopy_128m", 128 << 20, 1);
    copy_case("memset_128m", 128 << 20, 2);
    copy_case("bzero_128m", 128 << 20, 3);
}

/* ---- fresh memory: map, touch every 4 KiB, unmap ---- */
static void phase_touch(void)
{
    const size_t bytes = 64 << 20;
    double vf[MAXR], vw[MAXR];
    for (int r = 0; r < repeats; r++) {
        double t0 = now_ns();
        char *p = big_alloc(bytes);
        for (size_t o = 0; o < bytes; o += 4096) p[o] = 1;
        double t1 = now_ns();
        for (size_t o = 0; o < bytes; o += 4096) p[o] = 2;
        double t2 = now_ns();
        munmap(p, bytes);
        double t3 = now_ns();
        vf[r] = (t1 - t0 + t3 - t2) / (double)(bytes / 16384) / 1000.0;
        vw[r] = (t2 - t1) / (double)(bytes / 16384);
    }
    report("touch_fresh_64m", "us/16k", vf, repeats);
    report("touch_warm_64m", "ns/16k", vw, repeats);
}

/* ---- branches ---- */
static void phase_branch(void)
{
    const size_t n = 1 << 18; /* 1 MiB of sorted keys */
    uint32_t *a = malloc(n * sizeof(uint32_t));
    for (size_t i = 0; i < n; i++) a[i] = (uint32_t)(i * 7 + 3);
    const size_t lookups = 4000000;
    double v[MAXR];
    for (int r = 0; r < repeats; r++) {
        uint64_t s = 0;
        rng = 777 + (uint64_t)r;
        double t0 = now_ns();
        for (size_t q = 0; q < lookups; q++) {
            uint32_t key = (uint32_t)(next() % (n * 7));
            size_t lo = 0, hi = n;
            while (lo < hi) { /* data-dependent branch each step */
                size_t mid = (lo + hi) / 2;
                if (a[mid] < key) lo = mid + 1; else hi = mid;
                __asm__ volatile("" ::: "memory");
            }
            s += lo;
        }
        v[r] = (now_ns() - t0) / (double)lookups;
        sink = s;
    }
    report("bsearch_1m", "ns/op", v, repeats);

    /* An interpreter-style dispatch over random opcodes (indirect branches). */
    const size_t ops = 1 << 16;
    uint8_t *code = malloc(ops);
    for (size_t i = 0; i < ops; i++) code[i] = (uint8_t)(next() % 8);
    const size_t steps = 50000000;
    for (int r = 0; r < repeats; r++) {
        uint64_t acc = 1;
        double t0 = now_ns();
        for (size_t i = 0; i < steps; i++) {
            switch (code[i & (ops - 1)]) {
            case 0: acc += 3; break;
            case 1: acc ^= acc >> 3; break;
            case 2: acc *= 5; break;
            case 3: acc -= 7; break;
            case 4: acc = (acc << 1) | (acc >> 63); break;
            case 5: acc |= 0x10; break;
            case 6: acc &= ~0x3ull; break;
            default: acc += i; break;
            }
        }
        v[r] = (now_ns() - t0) / (double)steps;
        sink = acc;
    }
    report("dispatch_rand", "ns/op", v, repeats);
    free(code);
    free(a);
}

/* ---- path string compares (a loader comparing install names) ---- */
__attribute__((noinline)) static int own_strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

static void phase_str(void)
{
    const size_t n = 2048;
    char **paths = malloc(n * sizeof(char *));
    for (size_t i = 0; i < n; i++) {
        paths[i] = malloc(128);
        snprintf(paths[i], 128, "/System/Library/%sFrameworks/Fw%04zx%s.framework/Fw%04zx",
                 (i & 1) ? "Private" : "", i * 2654435761u % 65536, (i & 2) ? "Core" : "Kit", i);
    }
    const size_t lookups = 2000;
    double v[MAXR], w[MAXR];
    for (int pass = 0; pass < 2; pass++) {
        for (int r = 0; r < repeats; r++) {
            size_t cmps = 0, hits = 0;
            rng = 99 + (uint64_t)r;
            double t0 = now_ns();
            for (size_t q = 0; q < lookups; q++) {
                const char *key = paths[next() % n];
                for (size_t i = 0; i < n; i++) {
                    cmps++;
                    if ((pass ? own_strcmp(paths[i], key) : strcmp(paths[i], key)) == 0) { hits++; break; }
                }
            }
            (pass ? w : v)[r] = (now_ns() - t0) / (double)cmps;
            sink = hits;
        }
    }
    report("strcmp_libc", "ns/cmp", v, repeats);
    report("strcmp_own", "ns/cmp", w, repeats);
    for (size_t i = 0; i < n; i++) free(paths[i]);
    free(paths);
}

/* ---- a loader-like file workload: stat, open, map, read headers, unmap ---- */
static void phase_files(void)
{
    if (!dir_arg) { printf("gcpu files: skipped (no -d)\n"); return; }
    DIR *d = opendir(dir_arg);
    if (!d) { perror(dir_arg); return; }
    char **names = NULL;
    size_t n = 0, cap = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        if (n == cap) { cap = cap ? cap * 2 : 256; names = realloc(names, cap * sizeof(char *)); }
        size_t len = strlen(dir_arg) + strlen(e->d_name) + 2;
        names[n] = malloc(len);
        snprintf(names[n], len, "%s/%s", dir_arg, e->d_name);
        n++;
    }
    closedir(d);
    if (n == 0) { printf("gcpu files: skipped (empty)\n"); return; }
    double vs[MAXR], vm[MAXR], vt[MAXR];
    for (int r = 0; r < repeats; r++) {
        struct stat st;
        double t0 = now_ns();
        for (size_t i = 0; i < n; i++) if (stat(names[i], &st) != 0) { perror(names[i]); exit(1); }
        vs[r] = (now_ns() - t0) / (double)n / 1000.0;
        double map_ns = 0, touch_ns = 0;
        size_t pages = 0;
        uint64_t s = 0;
        for (size_t i = 0; i < n; i++) {
            double a = now_ns();
            int fd = open(names[i], O_RDONLY);
            if (fd < 0) { perror(names[i]); exit(1); }
            fstat(fd, &st);
            size_t len = (size_t)st.st_size;
            const char *p = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
            if (p == MAP_FAILED) { perror("mmap file"); exit(1); }
            double b = now_ns();
            for (size_t o = 0; o < len; o += 16384) { s += (unsigned char)p[o]; pages++; }
            double c = now_ns();
            munmap((void *)p, len);
            close(fd);
            map_ns += (b - a) + (now_ns() - c);
            touch_ns += c - b;
        }
        vm[r] = map_ns / (double)n / 1000.0;
        vt[r] = touch_ns / (double)pages;
        sink = s;
    }
    report("files_stat", "us/file", vs, repeats);
    report("files_map_unmap", "us/file", vm, repeats);
    report("files_touch", "ns/16k", vt, repeats);
}

/* ---- a large read-only file: first touches (cold for this process), then warm ---- */
static void phase_file(void)
{
    if (!file_arg) { printf("gcpu file: skipped (no -f)\n"); return; }
    int fd = open(file_arg, O_RDONLY);
    if (fd < 0) { perror(file_arg); return; }
    struct stat st;
    fstat(fd, &st);
    size_t len = (size_t)st.st_size;
    size_t span = len < ((size_t)512 << 20) ? len : ((size_t)512 << 20);
    const char *p = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
    if (p == MAP_FAILED) { perror("mmap"); return; }
    size_t pages = span / 16384;
    size_t *order = malloc(pages * sizeof(size_t));
    for (size_t i = 0; i < pages; i++) order[i] = i;
    for (size_t i = pages - 1; i > 0; i--) {
        size_t j = next() % (i + 1);
        size_t t = order[i]; order[i] = order[j]; order[j] = t;
    }
    uint64_t s = 0;
    /* cold: the first touch of every 4 KiB of the span, in order */
    double t0 = now_ns();
    for (size_t o = 0; o < span; o += 4096) s += (unsigned char)p[o];
    double cold = (now_ns() - t0) / (double)(span / 4096);
    double v[MAXR];
    for (int r = 0; r < repeats; r++) {
        t0 = now_ns();
        for (size_t i = 0; i < pages; i++) s += (unsigned char)p[order[i] * 16384 + (i & 3) * 4096];
        v[r] = (now_ns() - t0) / (double)pages;
    }
    sink = s;
    double c[1] = {cold};
    report("file_cold_4k", "ns/4k", c, 1);
    report("file_warm_rand", "ns/16k", v, repeats);
    munmap((void *)p, len);
    close(fd);
    free(order);
}

/* ---- atomics and locks ---- */
static _Atomic uint64_t shared_ctr __attribute__((aligned(128)));
static _Atomic int ping __attribute__((aligned(128)));
static long contend_iters;

static void *contend_thread(void *arg)
{
    (void)arg;
    for (long i = 0; i < contend_iters; i++) atomic_fetch_add_explicit(&shared_ctr, 1, memory_order_relaxed);
    return NULL;
}

static long pingpong_iters;
static void *pong_thread(void *arg)
{
    (void)arg;
    for (long i = 0; i < pingpong_iters; i++) {
        while (atomic_load_explicit(&ping, memory_order_acquire) != 1) {}
        atomic_store_explicit(&ping, 0, memory_order_release);
    }
    return NULL;
}

static void phase_atomic(void)
{
    double v[MAXR];
    const long n = 20000000;
    _Atomic uint64_t local __attribute__((aligned(128)));
    atomic_init(&local, 0);
    for (int r = 0; r < repeats; r++) {
        double t0 = now_ns();
        for (long i = 0; i < n; i++) atomic_fetch_add_explicit(&local, 1, memory_order_relaxed);
        v[r] = (now_ns() - t0) / (double)n;
    }
    report("atomic_add", "ns/op", v, repeats);
    for (int r = 0; r < repeats; r++) {
        double t0 = now_ns();
        for (long i = 0; i < n; i++) {
            uint64_t old = atomic_load_explicit(&local, memory_order_relaxed);
            while (!atomic_compare_exchange_weak_explicit(&local, &old, old + 1, memory_order_seq_cst,
                                                          memory_order_relaxed)) {}
        }
        v[r] = (now_ns() - t0) / (double)n;
    }
    report("atomic_cas", "ns/op", v, repeats);
    pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
    for (int r = 0; r < repeats; r++) {
        double t0 = now_ns();
        for (long i = 0; i < n / 2; i++) { pthread_mutex_lock(&m); sink = (uint64_t)i; pthread_mutex_unlock(&m); }
        v[r] = (now_ns() - t0) / (double)(n / 2);
    }
    report("mutex_uncontended", "ns/op", v, repeats);
    contend_iters = 5000000;
    for (int r = 0; r < repeats; r++) {
        pthread_t t;
        atomic_store(&shared_ctr, 0);
        double t0 = now_ns();
        pthread_create(&t, NULL, contend_thread, NULL);
        contend_thread(NULL);
        pthread_join(t, NULL);
        v[r] = (now_ns() - t0) / (double)(2 * contend_iters);
    }
    report("atomic_contended2", "ns/op", v, repeats);
    pingpong_iters = 500000;
    for (int r = 0; r < repeats; r++) {
        pthread_t t;
        atomic_store(&ping, 0);
        pthread_create(&t, NULL, pong_thread, NULL);
        double t0 = now_ns();
        for (long i = 0; i < pingpong_iters; i++) {
            atomic_store_explicit(&ping, 1, memory_order_release);
            while (atomic_load_explicit(&ping, memory_order_acquire) != 0) {}
        }
        v[r] = (now_ns() - t0) / (double)pingpong_iters;
        pthread_join(t, NULL);
    }
    report("pingpong_rtt", "ns/rt", v, repeats);
}

/* ---- the clock ---- */
static void phase_timer(void)
{
    double v[MAXR];
    const long n = 5000000;
    for (int r = 0; r < repeats; r++) {
        uint64_t s = 0;
        double t0 = now_ns();
        for (long i = 0; i < n; i++) {
            uint64_t c;
            __asm__ volatile("mrs %0, cntvct_el0" : "=r"(c));
            s += c;
        }
        v[r] = (now_ns() - t0) / (double)n;
        sink = s;
    }
    report("cntvct_read", "ns/op", v, repeats);
    for (int r = 0; r < repeats; r++) {
        uint64_t s = 0;
        double t0 = now_ns();
        for (long i = 0; i < n; i++) {
#ifdef __APPLE__
            s += mach_absolute_time();
#else
            struct timespec t;
            clock_gettime(CLOCK_MONOTONIC, &t);
            s += (uint64_t)t.tv_nsec;
#endif
        }
        v[r] = (now_ns() - t0) / (double)n;
        sink = s;
    }
    report("clock_call", "ns/op", v, repeats);
}

/* ---- a real trap (no fast path): the VM exit round trip in the guest ---- */
static void phase_trap(void)
{
    double v[MAXR];
    const long n = 100000;
    for (int r = 0; r < repeats; r++) {
        uint64_t s = 0;
        double t0 = now_ns();
        for (long i = 0; i < n; i++) s += (uint64_t)getppid();
        v[r] = (now_ns() - t0) / (double)n / 1000.0;
        sink = s;
    }
    report("trap_getppid", "us/op", v, repeats);
}

/* ---- page-table churn by another thread while this one walks 2,048 pages ---- */
static _Atomic int churn_stop;
static _Atomic long churn_ops;
static void *churn_thread(void *arg)
{
    (void)arg;
    while (!atomic_load(&churn_stop)) {
        char *p = mmap(NULL, 16384, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) break;
        p[0] = 1;
        munmap(p, 16384);
        atomic_fetch_add(&churn_ops, 1);
    }
    return NULL;
}

static void phase_churn(void)
{
    const size_t n = 2048, stride = 16384;
    size_t bytes = n * stride + 4096;
    char *mem = big_alloc(bytes);
    void **p = make_chain(mem, n, stride, 64, stride);
    run_chase(p, n);
    double quiet[MAXR], busy[MAXR], rate[MAXR];
    for (int r = 0; r < repeats; r++) quiet[r] = run_chase(p, 5000000);
    for (int r = 0; r < repeats; r++) {
        pthread_t t;
        atomic_store(&churn_stop, 0);
        atomic_store(&churn_ops, 0);
        pthread_create(&t, NULL, churn_thread, NULL);
        while (atomic_load(&churn_ops) < 10) {}
        long ops0 = atomic_load(&churn_ops);
        double t0 = now_ns();
        busy[r] = run_chase(p, 5000000);
        double dt = now_ns() - t0;
        long ops1 = atomic_load(&churn_ops);
        atomic_store(&churn_stop, 1);
        pthread_join(t, NULL);
        rate[r] = (double)(ops1 - ops0) / (dt / 1e9) / 1000.0;
    }
    report("churn_quiet", "ns/hop", quiet, repeats);
    report("churn_busy", "ns/hop", busy, repeats);
    report("churn_rate", "k/s", rate, repeats);
    munmap(mem, bytes);
}

/* ---- thread switches: a 2,048-page chase in slices, another thread runs
 * between slices (alternating through a mutex and condition variable). With
 * the process on one host core this shows what a switch to another thread of
 * the same process costs the chase afterwards (TLB contents). ---- */
static pthread_mutex_t sw_m = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sw_c = PTHREAD_COND_INITIALIZER;
static int sw_turn, sw_stop;
static void *switch_thread(void *arg)
{
    char *own = arg; /* touches its own 64 pages between slices */
    pthread_mutex_lock(&sw_m);
    while (!sw_stop) {
        while (sw_turn != 1 && !sw_stop) pthread_cond_wait(&sw_c, &sw_m);
        if (sw_stop) break;
        for (size_t o = 0; o < 64 * 16384; o += 16384) own[o]++;
        sw_turn = 0;
        pthread_cond_broadcast(&sw_c);
    }
    pthread_mutex_unlock(&sw_m);
    return NULL;
}

static void phase_switch(void)
{
    const size_t n = 2048, stride = 16384, slice = 4096, slices = 2000;
    size_t bytes = n * stride + 4096;
    char *mem = big_alloc(bytes), *own = big_alloc(64 * 16384);
    void **p = make_chain(mem, n, stride, 64, stride);
    run_chase(p, n);
    double alone[MAXR], after[MAXR], rtt[MAXR];
    for (int r = 0; r < repeats; r++) {
        double t = 0;
        for (size_t k = 0; k < slices; k++) {
            double a = now_ns();
            for (size_t i = 0; i < slice; i++) p = (void **)*p;
            t += now_ns() - a;
        }
        alone[r] = t / (double)(slice * slices);
    }
    pthread_t th;
    sw_turn = 0;
    sw_stop = 0;
    pthread_create(&th, NULL, switch_thread, own);
    for (int r = 0; r < repeats; r++) {
        double t = 0, w = 0;
        for (size_t k = 0; k < slices; k++) {
            double a = now_ns();
            pthread_mutex_lock(&sw_m);
            sw_turn = 1;
            pthread_cond_broadcast(&sw_c);
            while (sw_turn != 0) pthread_cond_wait(&sw_c, &sw_m);
            pthread_mutex_unlock(&sw_m);
            double b = now_ns();
            for (size_t i = 0; i < slice; i++) p = (void **)*p;
            t += now_ns() - b;
            w += b - a;
        }
        after[r] = t / (double)(slice * slices);
        rtt[r] = w / (double)slices / 1000.0;
    }
    pthread_mutex_lock(&sw_m);
    sw_stop = 1;
    pthread_cond_broadcast(&sw_c);
    pthread_mutex_unlock(&sw_m);
    pthread_join(th, NULL);
    sink = (uint64_t)(uintptr_t)p;
    report("switch_alone", "ns/hop", alone, repeats);
    report("switch_after", "ns/hop", after, repeats);
    report("switch_handoff", "us/rt", rtt, repeats);
    munmap(mem, bytes);
    munmap(own, 64 * 16384);
}

struct phase { const char *name; void (*fn)(void); int needs; };
static void phase_tlb16(void) { phase_tlb(16384, "tlb16k"); }
static void phase_tlb4(void) { phase_tlb(4096, "tlb4k"); }
static void phase_null(void) {}
static const struct phase phases[] = {
    {"alu", phase_alu, 0}, {"chase", phase_chase, 0}, {"tlb16k", phase_tlb16, 0}, {"tlb4k", phase_tlb4, 0},
    {"hash", phase_hash, 0}, {"copy", phase_copy, 0}, {"touch", phase_touch, 0}, {"branch", phase_branch, 0},
    {"str", phase_str, 0}, {"files", phase_files, 1}, {"file", phase_file, 2}, {"atomic", phase_atomic, 0},
    {"timer", phase_timer, 0}, {"trap", phase_trap, 0}, {"churn", phase_churn, 0}, {"switch", phase_switch, 3},
    {"null", phase_null, 3},
};

int main(int argc, char **argv)
{
    int i = 1;
    for (; i < argc && argv[i][0] == '-'; i += 2) {
        if (i + 1 >= argc) break;
        if (strcmp(argv[i], "-r") == 0) { repeats = atoi(argv[i + 1]); if (repeats < 1) repeats = 1; if (repeats > MAXR) repeats = MAXR; }
        else if (strcmp(argv[i], "-d") == 0) dir_arg = argv[i + 1];
        else if (strcmp(argv[i], "-f") == 0) file_arg = argv[i + 1];
        else { fprintf(stderr, "unknown option %s\n", argv[i]); return 64; }
    }
#ifdef __linux__
    const char *nothp = getenv("GCPU_NO_THP");
    if (nothp && strcmp(nothp, "1") == 0 && prctl(PR_SET_THP_DISABLE, 1, 0, 0, 0) != 0) perror("PR_SET_THP_DISABLE");
#endif
    double t0 = now_ns();
    size_t np = sizeof phases / sizeof phases[0];
    if (i >= argc) {
        for (size_t k = 0; k < np; k++) {
            if (phases[k].needs == 3) continue;
            if (phases[k].needs == 1 && !dir_arg) continue;
            if (phases[k].needs == 2 && !file_arg) continue;
            phases[k].fn();
        }
    } else {
        for (; i < argc; i++) {
            size_t k = 0;
            while (k < np && strcmp(phases[k].name, argv[i]) != 0) k++;
            if (k == np) { fprintf(stderr, "unknown phase %s\n", argv[i]); return 64; }
            phases[k].fn();
        }
    }
    printf("gcpu done %.1f s\n", (now_ns() - t0) / 1e9);
    return 0;
}
