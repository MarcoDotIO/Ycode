// cpubench: single-thread CPU speed of a host on loader-like work (string
// compares and sorting, hashing, a 1 MiB pointer chase, branches); ms per
// part (boot-profile.md §10). Build: cc -O2 -o cpubench cpubench.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static uint64_t rng = 88172645463325252ull;
static uint64_t xr(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }
static int cmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
int main(void) {
    enum { N = 200000 };
    static char buf[N][64]; static char *p[N];
    const char *pre[] = {"/System/Library/PrivateFrameworks/", "/System/Library/Frameworks/", "/usr/lib/system/", "/usr/lib/"};
    for (int i = 0; i < N; i++) { snprintf(buf[i], 64, "%s%08llx.framework/X", pre[xr() & 3], (unsigned long long)(xr() & 0xffffff)); p[i] = buf[i]; }
    double t0 = now();
    for (int r = 0; r < 5; r++) { for (int i = 0; i < N; i++) { int j = xr() % N; char *t = p[i]; p[i] = p[j]; p[j] = t; } qsort(p, N, sizeof p[0], cmp); }
    double t1 = now();
    enum { H = 1 << 22 }; uint64_t *h = calloc(H, 8); uint64_t s = 0;
    for (int r = 0; r < 20000000; r++) { if ((r & ((1 << 21) - 1)) == 0) memset(h, 0, H * 8); uint64_t k = xr() | 1, i = (k * 0x9E3779B97F4A7C15ull) >> 42; while (h[i] && h[i] != k) i = (i + 1) & (H - 1); h[i] = k; s += i; }
    double t2 = now();
    enum { C = 1 << 18 }; uint32_t *nx = malloc(C * 4); for (uint32_t i = 0; i < C; i++) nx[i] = i;
    for (uint32_t i = C - 1; i > 0; i--) { uint32_t j = xr() % (i + 1), t = nx[i]; nx[i] = nx[j]; nx[j] = t; }
    uint32_t c = 0; for (int r = 0; r < 100000000; r++) c = nx[c];
    double t3 = now();
    uint64_t a = 0; for (uint64_t i = 0; i < 400000000; i++) { uint64_t v = xr(); if (v & 1) a += v >> 3; else if (v & 2) a ^= v; else a -= v >> 5; }
    double t4 = now();
    printf("sort-strcmp %.0f ms, hash %.0f ms, chase-1MiB %.0f ms, branches %.0f ms, total %.0f ms (%llu %u %llu)\n",
           t1 - t0, t2 - t1, t3 - t2, t4 - t3, t4 - t0, (unsigned long long)s, c, (unsigned long long)a);
    return 0;
}
