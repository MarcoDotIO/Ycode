// stdlib.c - environment, number conversion, sorting, random numbers,
// time and sleep for Ycode's libSystem (specs/macos/libsystem.md §6).
// Clean-room Ycode code from the C standard and POSIX descriptions.
#include "ycl.h"

// --- environment ---

YCL_EXPORT char *getenv(const char *name) {
    size_t n = strlen(name);
    for (char **e = *_NSGetEnviron(); e && *e; e++)
        if (strncmp(*e, name, n) == 0 && (*e)[n] == '=') return *e + n + 1;
    return 0;
}

static os_unfair_lock env_lock;
static char **owned_environ;  // the array setenv allocated, if any

YCL_EXPORT int unsetenv(const char *name) {
    if (!name || !*name || strchr(name, '=')) {
        ycl_errno = YCL_EINVAL;
        return -1;
    }
    size_t n = strlen(name);
    os_unfair_lock_lock(&env_lock);
    char **e = *_NSGetEnviron();
    for (size_t i = 0; e && e[i];) {
        if (strncmp(e[i], name, n) == 0 && e[i][n] == '=') {
            for (size_t j = i; e[j]; j++) e[j] = e[j + 1];
        } else {
            i++;
        }
    }
    os_unfair_lock_unlock(&env_lock);
    return 0;
}

YCL_EXPORT int setenv(const char *name, const char *value, int overwrite) {
    if (!name || !*name || strchr(name, '=')) {
        ycl_errno = YCL_EINVAL;
        return -1;
    }
    if (!overwrite && getenv(name)) return 0;
    size_t n = strlen(name), v = strlen(value);
    char *entry = malloc(n + v + 2);
    if (!entry) return -1;
    memcpy(entry, name, n);
    entry[n] = '=';
    memcpy(entry + n + 1, value, v + 1);
    unsetenv(name);
    os_unfair_lock_lock(&env_lock);
    char **old = *_NSGetEnviron();
    size_t count = 0;
    while (old && old[count]) count++;
    char **grown = malloc((count + 2) * sizeof *grown);
    if (!grown) {
        os_unfair_lock_unlock(&env_lock);
        free(entry);
        return -1;
    }
    for (size_t i = 0; i < count; i++) grown[i] = old[i];
    grown[count] = entry;
    grown[count + 1] = 0;
    *_NSGetEnviron() = grown;
    free(owned_environ);
    owned_environ = grown;
    os_unfair_lock_unlock(&env_lock);
    return 0;
}

// --- number conversion ---

static int is_space(int c) { return c == ' ' || (c >= '\t' && c <= '\r'); }

static int digit_value(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'z') return c - 'a' + 10;
    if (c >= 'A' && c <= 'Z') return c - 'A' + 10;
    return 99;
}

// Parses an integer; `*negative` tells the sign, the magnitude saturates at
// `limit` (ERANGE).
static uint64_t parse_integer(const char *s, char **end, int base, int *negative, uint64_t limit) {
    const char *p = s;
    while (is_space((unsigned char)*p)) p++;
    *negative = 0;
    if (*p == '+' || *p == '-') *negative = *p++ == '-';
    if ((base == 0 || base == 16) && p[0] == '0' && (p[1] | 0x20) == 'x' && digit_value((unsigned char)p[2]) < 16) {
        p += 2;
        base = 16;
    } else if (base == 0) {
        base = *p == '0' ? 8 : 10;
    }
    if (base < 2 || base > 36) {
        ycl_errno = YCL_EINVAL;
        if (end) *end = (char *)s;
        return 0;
    }
    uint64_t v = 0;
    int any = 0, over = 0;
    for (;; p++) {
        int d = digit_value((unsigned char)*p);
        if (d >= base) break;
        any = 1;
        if (v > (limit - (uint64_t)d) / (uint64_t)base) over = 1;
        else v = v * (uint64_t)base + (uint64_t)d;
    }
    if (end) *end = (char *)(any ? p : s);
    if (over) {
        ycl_errno = YCL_ERANGE;
        return limit;
    }
    return v;
}

YCL_EXPORT long long strtoll(const char *s, char **end, int base) {
    int negative;
    uint64_t v = parse_integer(s, end, base, &negative, (uint64_t)INT64_MAX + 1);
    if (!negative && v > (uint64_t)INT64_MAX) {
        ycl_errno = YCL_ERANGE;
        return INT64_MAX;
    }
    return negative ? (long long)(0 - v) : (long long)v;
}
YCL_EXPORT long strtol(const char *s, char **end, int base) { return (long)strtoll(s, end, base); }

YCL_EXPORT unsigned long long strtoull(const char *s, char **end, int base) {
    int negative;
    uint64_t v = parse_integer(s, end, base, &negative, UINT64_MAX);
    return negative ? 0 - v : v;
}
YCL_EXPORT unsigned long strtoul(const char *s, char **end, int base) { return (unsigned long)strtoull(s, end, base); }

YCL_EXPORT int atoi(const char *s) { return (int)strtol(s, 0, 10); }
YCL_EXPORT long atol(const char *s) { return strtol(s, 0, 10); }
YCL_EXPORT long long atoll(const char *s) { return strtoll(s, 0, 10); }

// strtod, strtof, strtold and atof are LLVM libc's (llvm_libc.cpp).

YCL_EXPORT int abs(int v) { return v < 0 ? -v : v; }
YCL_EXPORT long labs(long v) { return v < 0 ? -v : v; }
YCL_EXPORT long long llabs(long long v) { return v < 0 ? -v : v; }

// --- sorting and searching ---

static void swap_bytes(char *a, char *b, size_t n) {
    while (n--) {
        char t = *a;
        *a++ = *b;
        *b++ = t;
    }
}

// An in-place heapsort: O(n log n), no allocation, no recursion.
static void sift(char *base, size_t root, size_t count, size_t size, int (*cmp)(const void *, const void *)) {
    for (;;) {
        size_t child = 2 * root + 1;
        if (child >= count) return;
        if (child + 1 < count && cmp(base + child * size, base + (child + 1) * size) < 0) child++;
        if (cmp(base + root * size, base + child * size) >= 0) return;
        swap_bytes(base + root * size, base + child * size, size);
        root = child;
    }
}

YCL_EXPORT void qsort(void *array, size_t count, size_t size, int (*cmp)(const void *, const void *)) {
    char *base = array;
    if (count < 2 || size == 0) return;
    for (size_t i = count / 2; i-- > 0;) sift(base, i, count, size, cmp);
    for (size_t end = count - 1; end > 0; end--) {
        swap_bytes(base, base + end * size, size);
        sift(base, 0, end, size, cmp);
    }
}

YCL_EXPORT void *bsearch(const void *key, const void *array, size_t count, size_t size,
                         int (*cmp)(const void *, const void *)) {
    const char *base = array;
    while (count) {
        size_t mid = count / 2;
        const char *at = base + mid * size;
        int c = cmp(key, at);
        if (c == 0) return (void *)at;
        if (c > 0) base = at + size, count -= mid + 1;
        else count = mid;
    }
    return 0;
}

// --- random numbers ---

static uint64_t rand_state = 1;
YCL_EXPORT void srand(unsigned seed) { rand_state = seed; }
YCL_EXPORT int rand(void) {
    rand_state = rand_state * 6364136223846793005ull + 1442695040888963407ull;
    return (int)((rand_state >> 33) & 0x7FFFFFFF);
}
YCL_EXPORT long random(void) { return rand(); }
YCL_EXPORT void srandom(unsigned seed) { srand(seed); }

YCL_EXPORT void arc4random_buf(void *buf, size_t n) {
    uint8_t *p = buf;
    while (n) {
        size_t k = n > 256 ? 256 : n;
        if (getentropy(p, k) != 0) abort();
        p += k;
        n -= k;
    }
}
YCL_EXPORT uint32_t arc4random(void) {
    uint32_t v;
    arc4random_buf(&v, sizeof v);
    return v;
}
YCL_EXPORT uint32_t arc4random_uniform(uint32_t bound) {
    if (bound < 2) return 0;
    uint32_t floor = (uint32_t)(0 - bound) % bound;  // reject the biased low range
    for (;;) {
        uint32_t v = arc4random();
        if (v >= floor) return v % bound;
    }
}

// --- time and sleep ---

static uint32_t timebase_numer, timebase_denom;

// v * numer / denom without a 128-bit division (no compiler runtime here).
static uint64_t scale(uint64_t v, uint32_t numer, uint32_t denom) {
    return v / denom * numer + v % denom * numer / denom;
}

uint64_t ycl_now_ns(void) {
    if (!timebase_denom) {
        uint32_t tb[2] = {1, 1};
        mach_timebase_info(tb);
        timebase_numer = tb[0];
        timebase_denom = tb[1] ? tb[1] : 1;
    }
    return scale(mach_absolute_time(), timebase_numer, timebase_denom);
}

static uint64_t ns_to_ticks(uint64_t ns) {
    ycl_now_ns();
    return scale(ns, timebase_denom, timebase_numer ? timebase_numer : 1);
}

YCL_EXPORT int nanosleep(const struct ycl_timespec *want, struct ycl_timespec *left) {
    if (!want || want->tv_nsec < 0 || want->tv_nsec >= 1000000000 || want->tv_sec < 0) {
        ycl_errno = YCL_EINVAL;
        return -1;
    }
    uint64_t ns = (uint64_t)want->tv_sec * 1000000000ull + (uint64_t)want->tv_nsec;
    mach_wait_until(mach_absolute_time() + ns_to_ticks(ns));
    if (left) left->tv_sec = 0, left->tv_nsec = 0;
    return 0;
}
YCL_EXPORT int usleep(unsigned us) {
    struct ycl_timespec t = {us / 1000000, (long)(us % 1000000) * 1000};
    return nanosleep(&t, 0);
}
YCL_EXPORT unsigned sleep(unsigned s) {
    struct ycl_timespec t = {s, 0};
    nanosleep(&t, 0);
    return 0;
}

YCL_EXPORT int gettimeofday(struct ycl_timeval *tv, void *tz) {
    (void)tz;
    struct ycl_timeval t = {0, 0};
    if (__gettimeofday(&t, 0, 0) < 0) return -1;
    if (tv) *tv = t;
    return 0;
}

YCL_EXPORT long time(long *out) {
    struct ycl_timeval t;
    long v = gettimeofday(&t, 0) == 0 ? t.tv_sec : -1;
    if (out) *out = v;
    return v;
}

enum { CLOCK_REALTIME = 0, CLOCK_MONOTONIC_RAW = 4, CLOCK_MONOTONIC = 6, CLOCK_UPTIME_RAW = 8 };
YCL_EXPORT int clock_gettime(int clock, struct ycl_timespec *ts) {
    if (clock == CLOCK_REALTIME) {
        struct ycl_timeval t;
        if (gettimeofday(&t, 0)) return -1;
        ts->tv_sec = t.tv_sec;
        ts->tv_nsec = (long)t.tv_usec * 1000;
        return 0;
    }
    if (clock == CLOCK_MONOTONIC || clock == CLOCK_MONOTONIC_RAW || clock == CLOCK_UPTIME_RAW) {
        uint64_t ns = ycl_now_ns();
        ts->tv_sec = (long)(ns / 1000000000ull);
        ts->tv_nsec = (long)(ns % 1000000000ull);
        return 0;
    }
    ycl_errno = YCL_EINVAL;
    return -1;
}

// --- small POSIX helpers ---

YCL_EXPORT int isatty(int fd) {
    char termios[72];
    if (ioctl(fd, 0x40487413ul /* TIOCGETA */, termios) == 0) return 1;
    ycl_errno = YCL_ENOTTY;
    return 0;
}

YCL_EXPORT int getpagesize(void) { return 16384; }

enum { SC_PAGESIZE = 29, SC_NPROCESSORS_CONF = 57, SC_NPROCESSORS_ONLN = 58 };
YCL_EXPORT long sysconf(int name) {
    if (name == SC_PAGESIZE) return 16384;
    if (name == SC_NPROCESSORS_CONF || name == SC_NPROCESSORS_ONLN) {
        int mib[2] = {6 /* CTL_HW */, 3 /* HW_NCPU */}, n = 0;
        size_t size = sizeof n;
        return __sysctl(mib, 2, &n, &size, 0, 0) == 0 && n > 0 ? n : 1;
    }
    ycl_errno = YCL_EINVAL;
    return -1;
}
