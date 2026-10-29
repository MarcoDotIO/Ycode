/*
 * Host-side unit tests for Ycode's libsystem_platform sources.
 *
 * Clean-room Ycode code. The platform C (and, on arm64 hosts, assembly)
 * sources are compiled for the host with -DYC_HOST_TEST, which renames
 * every exported function to yc_test_<name> and every libsystem_kernel
 * function it calls to yc_testk_<name>. This file supplies those kernel
 * functions as fakes and checks the results against the host C library or
 * against expected values. Run it with `sh build.sh test`.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef _Bool yc_bool;

/* ---- declarations of the code under test ---------------------------- */

#define T(name) yc_test_##name
void *T(_platform_memmove)(void *, const void *, size_t);
void *T(_platform_memccpy)(void *, const void *, int, size_t);
void *T(_platform_memchr)(const void *, int, size_t);
int T(_platform_memcmp)(const void *, const void *, size_t);
int T(_platform_memcmp_zero_aligned8)(const void *, size_t);
void *T(_platform_memset)(void *, int, size_t);
void T(_platform_bzero)(void *, size_t);
void T(__bzero)(void *, size_t);
void T(_platform_memset_pattern4)(void *, const void *, size_t);
void T(_platform_memset_pattern8)(void *, const void *, size_t);
void T(_platform_memset_pattern16)(void *, const void *, size_t);
size_t T(_platform_strlen)(const char *);
size_t T(_platform_strnlen)(const char *, size_t);
char *T(_platform_strchr)(const char *, int);
int T(_platform_strcmp)(const char *, const char *);
int T(_platform_strncmp)(const char *, const char *, size_t);
char *T(_platform_strcpy)(char *, const char *);
char *T(_platform_strncpy)(char *, const char *, size_t);
size_t T(_platform_strlcpy)(char *, const char *, size_t);
size_t T(_platform_strlcat)(char *, const char *, size_t);
char *T(_platform_strstr)(const char *, const char *);

int32_t T(OSAtomicAdd32)(int32_t, volatile int32_t *);
int64_t T(OSAtomicAdd64Barrier)(int64_t, volatile int64_t *);
int32_t T(OSAtomicIncrement32Barrier)(volatile int32_t *);
int32_t T(OSAtomicDecrement32)(volatile int32_t *);
int64_t T(OSAtomicIncrement64)(volatile int64_t *);
int64_t T(OSAtomicDecrement64Barrier)(volatile int64_t *);
int32_t T(OSAtomicOr32)(uint32_t, volatile uint32_t *);
int32_t T(OSAtomicOr32Orig)(uint32_t, volatile uint32_t *);
int32_t T(OSAtomicAnd32Barrier)(uint32_t, volatile uint32_t *);
int32_t T(OSAtomicAnd32OrigBarrier)(uint32_t, volatile uint32_t *);
int32_t T(OSAtomicXor32)(uint32_t, volatile uint32_t *);
int32_t T(OSAtomicXor32Orig)(uint32_t, volatile uint32_t *);
yc_bool T(OSAtomicCompareAndSwap32)(int32_t, int32_t, volatile int32_t *);
yc_bool T(OSAtomicCompareAndSwap64Barrier)(int64_t, int64_t, volatile int64_t *);
yc_bool T(OSAtomicCompareAndSwapPtr)(void *, void *, void *volatile *);
yc_bool T(OSAtomicCompareAndSwapLong)(long, long, volatile long *);
yc_bool T(OSAtomicTestAndSet)(uint32_t, volatile void *);
yc_bool T(OSAtomicTestAndClearBarrier)(uint32_t, volatile void *);
void T(OSMemoryBarrier)(void);
typedef struct { void *opaque1; long opaque2; } __attribute__((aligned(16))) OSQueueHead;
void T(OSAtomicEnqueue)(OSQueueHead *, void *, size_t);
void *T(OSAtomicDequeue)(OSQueueHead *, size_t);
typedef struct { void *opaque1; void *opaque2; int opaque3; } OSFifoQueueHead;
void T(OSAtomicFifoEnqueue)(OSFifoQueueHead *, void *, size_t);
void *T(OSAtomicFifoDequeue)(OSFifoQueueHead *, size_t);

typedef struct { uint32_t v; } os_unfair_lock;
void T(os_unfair_lock_lock)(os_unfair_lock *);
void T(os_unfair_lock_lock_with_options)(os_unfair_lock *, uint32_t);
yc_bool T(os_unfair_lock_trylock)(os_unfair_lock *);
void T(os_unfair_lock_unlock)(os_unfair_lock *);
void T(os_unfair_lock_assert_owner)(const os_unfair_lock *);
void T(os_unfair_lock_assert_not_owner)(const os_unfair_lock *);
void T(os_unfair_lock_lock_no_tsd)(os_unfair_lock *, uint32_t, uint32_t);
void T(os_unfair_lock_unlock_no_tsd)(os_unfair_lock *, uint32_t);
typedef struct { uint32_t lock; uint32_t count; } os_unfair_recursive_lock;
void T(os_unfair_recursive_lock_lock_with_options)(os_unfair_recursive_lock *, uint32_t);
yc_bool T(os_unfair_recursive_lock_trylock)(os_unfair_recursive_lock *);
void T(os_unfair_recursive_lock_unlock)(os_unfair_recursive_lock *);
yc_bool T(os_unfair_recursive_lock_tryunlock4objc)(os_unfair_recursive_lock *);
yc_bool T(os_unfair_recursive_lock_owned)(os_unfair_recursive_lock *);
void T(os_unfair_recursive_lock_unlock_forked_child)(os_unfair_recursive_lock *);
void T(_os_nospin_lock_lock)(int32_t *);
yc_bool T(_os_nospin_lock_trylock)(int32_t *);
void T(_os_nospin_lock_unlock)(int32_t *);
void T(OSSpinLockLock)(volatile int32_t *);
yc_bool T(OSSpinLockTry)(volatile int32_t *);
void T(OSSpinLockUnlock)(volatile int32_t *);
void T(spin_lock)(volatile int32_t *);
void T(spin_unlock)(volatile int32_t *);
struct os_lock_type { uintptr_t kind; void *f[3]; };
extern const struct os_lock_type T(_os_lock_type_unfair), T(_os_lock_type_spin), T(_os_lock_type_handoff);
void T(os_lock_lock)(void *);
yc_bool T(os_lock_trylock)(void *);
void T(os_lock_unlock)(void *);

void T(_os_once)(long *, void *, void (*)(void *));
void T(__os_once_reset)(long *);
struct alloc_once_slot { long once; void *ptr; };
void *T(_os_alloc_once)(struct alloc_once_slot *, size_t, void (*)(void *));

int T(ffs)(int);
int T(ffsl)(long);
int T(ffsll)(long long);
int T(fls)(int);
int T(flsl)(long);
int T(flsll)(long long);

void T(sys_icache_invalidate)(void *, size_t);
void T(sys_dcache_flush)(void *, size_t);
int T(sys_cache_control)(int, void *, size_t);

int T(os_sync_wait_on_address)(void *, uint64_t, size_t, uint32_t);
int T(os_sync_wait_on_address_with_timeout)(void *, uint64_t, size_t, uint32_t, uint32_t, uint64_t);
int T(os_sync_wait_on_address_with_deadline)(void *, uint64_t, size_t, uint32_t, uint32_t, uint64_t);
int T(os_sync_wake_by_address_any)(void *, size_t, uint32_t);
int T(os_sync_wake_by_address_all)(void *, size_t, uint32_t);

typedef void *SIMPLE;
void T(_simple_dprintf)(int, const char *, ...);
SIMPLE T(_simple_salloc)(void);
int T(_simple_sprintf)(SIMPLE, const char *, ...);
int T(_simple_sappend)(SIMPLE, const char *);
void T(_simple_sresize)(SIMPLE);
char *T(_simple_string)(SIMPLE);
void T(_simple_put)(SIMPLE, int);
void T(_simple_putline)(SIMPLE, int);
void T(_simple_sfree)(SIMPLE);
const char *T(_simple_getenv)(const char **, const char *);

void T(__libplatform_init)(void *, const char **, const char **, const void *);
uint64_t __yc_security_config(void);
void T(_simple_asl_log)(int, const char *, const char *);

#if defined(__aarch64__)
#define HAVE_SETJMP 1
typedef long yc_jmp_buf[24 + 1]; /* 192 bytes, + room for the sigjmp flag */
int T(setjmp)(yc_jmp_buf) __attribute__((returns_twice));
int T(_setjmp)(yc_jmp_buf) __attribute__((returns_twice));
int T(sigsetjmp)(yc_jmp_buf, int) __attribute__((returns_twice));
void T(longjmp)(yc_jmp_buf, int) __attribute__((noreturn));
void T(_longjmp)(yc_jmp_buf, int) __attribute__((noreturn));
void T(siglongjmp)(yc_jmp_buf, int) __attribute__((noreturn));
#endif

/* ---- fakes for libsystem_kernel and the hidden hooks ------------------ */

static __thread int fake_errno;
static __thread uint32_t thread_owner_id;
static uint32_t next_owner_id = 0x203;
static long ulock_wait_calls, ulock_wake_calls;
static int wake_result;
static uint32_t fake_sigmask;
static char captured[4096];
static size_t captured_len;
#define CAPTURE_FD 99

uint32_t __yc_lock_owner_id(void)
{
    if (thread_owner_id == 0)
        thread_owner_id = __atomic_fetch_add(&next_owner_id, 0x100, __ATOMIC_RELAXED) | 3;
    return thread_owner_id;
}

void __ycode_set_errno(int v) { fake_errno = v; }
long __ycode_stub_enosys(void) { fake_errno = 78; return -1; }
int *yc_testk___error(void) { return &fake_errno; }

int yc_testk___ulock_wait(uint32_t op, void *addr, uint64_t value, uint32_t timeout)
{
    (void)op; (void)timeout;
    __atomic_fetch_add(&ulock_wait_calls, 1, __ATOMIC_RELAXED);
    if (__atomic_load_n((uint32_t *)addr, __ATOMIC_RELAXED) == (uint32_t)value)
        sched_yield(); /* a spurious wake-up is always allowed */
    return 0;
}

int yc_testk___ulock_wait2(uint32_t op, void *addr, uint64_t value, uint64_t timeout, uint64_t v2)
{
    (void)v2;
    if (timeout == 12345)
        return -60; /* ETIMEDOUT */
    return yc_testk___ulock_wait(op, addr, value, 0);
}

int yc_testk___ulock_wake(uint32_t op, void *addr, uint64_t v)
{
    (void)op; (void)addr; (void)v;
    __atomic_fetch_add(&ulock_wake_calls, 1, __ATOMIC_RELAXED);
    return wake_result;
}

ssize_t yc_testk_write(int fd, const void *buf, size_t len)
{
    if (fd == CAPTURE_FD) {
        if (captured_len + len < sizeof captured) {
            memcpy(captured + captured_len, buf, len);
            captured_len += len;
            captured[captured_len] = 0;
        }
        return (ssize_t)len;
    }
    return write(fd, buf, len);
}

static long mmap_calls;
void *yc_testk_mmap(void *addr, size_t len, int prot, int flags, int fd, int64_t off)
{
    mmap_calls++;
    if (flags != (0x0002 | 0x1000) || prot != 3 || fd != -1 || off != 0)
        abort();
    void *p = mmap(addr, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return p == MAP_FAILED ? (void *)-1 : p;
}

int yc_testk_munmap(void *addr, size_t len) { return munmap(addr, len); }

int yc_testk_sigprocmask(int how, const uint32_t *set, uint32_t *oset)
{
    if (oset) *oset = fake_sigmask;
    if (set) {
        if (how == 1) fake_sigmask |= *set;
        else if (how == 3) fake_sigmask = *set;
        else abort();
    }
    return 0;
}

static int sigaction_sig;
static uint64_t sigaction_in[3];
static int sigaction_had_new;
int yc_testk___sigaction(int sig, const void *nsa, void *osa)
{
    sigaction_sig = sig;
    sigaction_had_new = nsa != NULL;
    if (nsa) memcpy(sigaction_in, nsa, 24);
    if (osa) { uint64_t old[2] = {1, 0x0000000700000005ull}; memcpy(osa, old, 16); }
    return sig == 9 ? (fake_errno = 22, -1) : 0;
}

struct alloc_once_slot yc_testk__os_alloc_once_table[100];
static const unsigned long *kernel_string_table;
int yc_testk___libkernel_platform_init(const unsigned long *table)
{
    kernel_string_table = table;
    return 0;
}

uint64_t yc_testk_mach_absolute_time(void) { return 1000; }
struct tb { uint32_t numer, denom; };
int yc_testk_mach_timebase_info(struct tb *t) { t->numer = 125; t->denom = 3; return 0; }

/* ---- test harness ------------------------------------------------------ */

static int failures, checks;
#define CHECK(cond) do { checks++; if (!(cond)) { failures++; \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

static int sign(int v) { return (v > 0) - (v < 0); }
static uint32_t rng = 12345;
static uint32_t rnd(void) { rng = rng * 1103515245u + 12345u; return rng >> 8; }

static void test_memory(void)
{
    unsigned char a[512], b[512], c[512];
    for (int iter = 0; iter < 4000; iter++) {
        for (int i = 0; i < 512; i++) a[i] = b[i] = (unsigned char)rnd();
        size_t n = rnd() % 200, so = rnd() % 64, dof = rnd() % 64;
        /* overlapping move inside one buffer, both directions */
        memmove(b + dof + 100, b + so + 100, n);
        T(_platform_memmove)(a + dof + 100, a + so + 100, n);
        CHECK(memcmp(a, b, 512) == 0);
    }
    for (int iter = 0; iter < 2000; iter++) {
        size_t n = rnd() % 300, x = rnd() % 16, y = rnd() % 16;
        for (int i = 0; i < 512; i++) a[i] = b[i] = (unsigned char)(rnd() & 3);
        CHECK(sign(T(_platform_memcmp)(a + x, b + y, n)) == sign(memcmp(a + x, b + y, n)));
        int ch = (int)(rnd() % 4);
        CHECK(T(_platform_memchr)(a + x, ch + 256, n) == memchr(a + x, ch, n));
        memset(c, 0xEE, sizeof c);
        unsigned char d[512];
        memset(d, 0xEE, sizeof d);
        CHECK((T(_platform_memccpy)(c, a + x, ch, n) == NULL) == (memccpy(d, a + x, ch, n) == NULL));
        CHECK(memcmp(c, d, sizeof c) == 0);
        memset(c, 1, sizeof c);
        memset(d, 1, sizeof d);
        CHECK(T(_platform_memset)(c + x, 0x5A, n) == c + x);
        memset(d + x, 0x5A, n);
        CHECK(memcmp(c, d, sizeof c) == 0);
        T(_platform_bzero)(c + y, n);
        memset(d + y, 0, n);
        CHECK(memcmp(c, d, sizeof c) == 0);
    }
    unsigned char z[64] = {0};
    CHECK(T(_platform_memcmp_zero_aligned8)(z, 64) == 0);
    z[63] = 1;
    CHECK(T(_platform_memcmp_zero_aligned8)(z, 64) != 0);
    CHECK(T(_platform_memcmp_zero_aligned8)(z, 63) == 0);
    T(__bzero)(z, 64);
    CHECK(z[63] == 0);
    CHECK(T(_platform_memcmp)("a\x80", "a\x01", 2) > 0); /* unsigned compare */

    const unsigned char p4[4] = {1, 2, 3, 4}, p8[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    unsigned char p16[16];
    for (int i = 0; i < 16; i++) p16[i] = (unsigned char)(0xA0 + i);
    memset(c, 0, sizeof c);
    T(_platform_memset_pattern4)(c + 1, p4, 10);
    CHECK(c[0] == 0 && c[1] == 1 && c[4] == 4 && c[5] == 1 && c[10] == 2 && c[11] == 0);
    T(_platform_memset_pattern8)(c, p8, 13);
    CHECK(c[7] == 8 && c[8] == 1 && c[12] == 5 && c[13] == 0);
    T(_platform_memset_pattern16)(c, p16, 35);
    CHECK(c[15] == 0xAF && c[16] == 0xA0 && c[34] == 0xA2 && c[35] == 0);
}

/* Larger sizes, every alignment, both overlap directions, fills against a
 * reference (guest-cpu.md section 4.4). */
static void test_memory_large(void)
{
    static unsigned char a[8192], b[8192], c[8192], d[8192];
    for (int iter = 0; iter < 6000; iter++) {
        size_t n = (iter & 3) == 0 ? rnd() % 4000 : rnd() % 300;
        size_t so = rnd() % 64, dof = rnd() % 64, gap = rnd() % 40;
        for (int i = 0; i < 8192; i++) a[i] = b[i] = (unsigned char)rnd();
        /* overlapping, the source a little above or below the destination */
        size_t s0 = 1000 + so, d0 = (iter & 1) ? s0 + gap : (s0 > gap ? s0 - gap : 0) + dof % 2;
        memmove(b + d0, b + s0, n);
        CHECK(T(_platform_memmove)(a + d0, a + s0, n) == a + d0);
        CHECK(memcmp(a, b, sizeof a) == 0);
        /* disjoint */
        for (int i = 0; i < 8192; i++) c[i] = d[i] = 0x11;
        memcpy(d + dof, a + 4096 + so, n);
        T(_platform_memmove)(c + dof, a + 4096 + so, n);
        CHECK(memcmp(c, d, sizeof c) == 0);
        /* fills */
        int v = (int)(rnd() & 0xFF);
        memset(c + dof, v, n);
        T(_platform_memset)(d + dof, v, n);
        CHECK(memcmp(c, d, sizeof c) == 0);
        memset(c + so, 0, n + 600);
        T(_platform_bzero)(d + so, n + 600);
        CHECK(memcmp(c, d, sizeof c) == 0);
        unsigned char pat[16];
        for (int i = 0; i < 16; i++) pat[i] = (unsigned char)rnd();
        size_t plen = (size_t)4 << (rnd() % 3);
        for (size_t i = 0; i < n; i++) c[dof + i] = pat[i % plen];
        if (plen == 4) T(_platform_memset_pattern4)(d + dof, pat, n);
        else if (plen == 8) T(_platform_memset_pattern8)(d + dof, pat, n);
        else T(_platform_memset_pattern16)(d + dof, pat, n);
        CHECK(memcmp(c, d, sizeof c) == 0);
        int ch = (int)(rnd() & 3);
        for (size_t i = 0; i < 300; i++) a[so + i] = (unsigned char)(4 + (rnd() & 3));
        if (n < 300) a[so + n] = (unsigned char)ch;
        CHECK(T(_platform_memchr)(a + so, ch, 300) == memchr(a + so, ch, 300));
    }
    /* strings that end at a page boundary, before an inaccessible page */
    long page = sysconf(_SC_PAGESIZE);
    unsigned char *m = mmap(NULL, (size_t)page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(m != MAP_FAILED);
    if (m != MAP_FAILED) {
        CHECK(mprotect(m + page, (size_t)page, PROT_NONE) == 0);
        char *e = (char *)m + page;
        for (int len = 0; len < 40; len++) {
            for (int other = 0; other < 3; other++) {
                char *x = e - len - 1, *y = (char *)m + 64 + other;
                memset(x, 'p', (size_t)len);
                x[len] = 0;
                memset(y, 'p', (size_t)len);
                y[len] = 0;
                if (other == 1 && len > 0) y[len - 1] = 'q';
                if (other == 2) { y[len] = 'r'; y[len + 1] = 0; }
                CHECK(sign(T(_platform_strcmp)(x, y)) == sign(strcmp(x, y)));
                CHECK(sign(T(_platform_strcmp)(y, x)) == sign(strcmp(y, x)));
                CHECK(T(_platform_strnlen)(x, 100) == (size_t)len);
                CHECK(T(_platform_strlen)(x) == (size_t)len);
                CHECK(T(_platform_memchr)(x, 0, (size_t)len + 1) == x + len);
            }
        }
        munmap(m, (size_t)page * 2);
    }
    /* strcmp over random strings at every offset pair */
    char sx[96], sy[96];
    for (int iter = 0; iter < 20000; iter++) {
        size_t ox = rnd() % 16, oy = rnd() % 16, len = rnd() % 70;
        for (size_t i = 0; i < len; i++) sx[ox + i] = sy[oy + i] = (char)(1 + rnd() % 3);
        sx[ox + len] = sy[oy + len] = 0;
        if (rnd() & 1) { size_t at = len ? rnd() % (len + 1) : 0; sy[oy + at] = (char)(rnd() % 4); }
        CHECK(sign(T(_platform_strcmp)(sx + ox, sy + oy)) == sign(strcmp(sx + ox, sy + oy)));
        CHECK(T(_platform_strnlen)(sx + ox, len / 2) == strnlen(sx + ox, len / 2));
    }
}

static void test_strings(void)
{
    char buf[64], ref[64];
    const char *samples[] = {"", "a", "hello", "hello world, this is a longer string!", "abc\x80xyz"};
    for (size_t i = 0; i < sizeof samples / sizeof *samples; i++) {
        for (size_t off = 0; off < 8; off++) {
            char tmp[80];
            strcpy(tmp + off, samples[i]);
            CHECK(T(_platform_strlen)(tmp + off) == strlen(samples[i]));
        }
        for (size_t j = 0; j < sizeof samples / sizeof *samples; j++) {
            CHECK(sign(T(_platform_strcmp)(samples[i], samples[j])) == sign(strcmp(samples[i], samples[j])));
            for (size_t n = 0; n < 8; n++)
                CHECK(sign(T(_platform_strncmp)(samples[i], samples[j], n)) == sign(strncmp(samples[i], samples[j], n)));
        }
        CHECK(T(_platform_strnlen)(samples[i], 3) == strnlen(samples[i], 3));
    }
    CHECK(T(_platform_strchr)("hello", 'l') == strchr("hello", 'l') || 1);
    const char *h = "hello";
    CHECK(T(_platform_strchr)(h, 'l') == h + 2);
    CHECK(T(_platform_strchr)(h, 0) == h + 5);
    CHECK(T(_platform_strchr)(h, 'z') == NULL);
    CHECK(T(_platform_strchr)(h, 'h' + 256) == h); /* converted to char */
    CHECK(T(_platform_strstr)(h, "") == h);
    CHECK(T(_platform_strstr)(h, "llo") == h + 2);
    CHECK(T(_platform_strstr)(h, "lloo") == NULL);
    CHECK(T(_platform_strstr)("aaab", "aab") != NULL);
    CHECK(T(_platform_strcpy)(buf, "copy") == buf && strcmp(buf, "copy") == 0);
    memset(buf, 'X', sizeof buf);
    CHECK(T(_platform_strncpy)(buf, "ab", 6) == buf);
    CHECK(memcmp(buf, "ab\0\0\0\0X", 7) == 0);
    memset(buf, 'X', sizeof buf);
    T(_platform_strncpy)(buf, "abcdef", 3);
    CHECK(memcmp(buf, "abcX", 4) == 0);

    /* strlcpy / strlcat */
    memset(buf, 'X', sizeof buf);
    CHECK(T(_platform_strlcpy)(buf, "hello", 3) == 5 && strcmp(buf, "he") == 0);
    CHECK(T(_platform_strlcpy)(buf, "hello", 0) == 5 && buf[0] == 'h');
    CHECK(T(_platform_strlcpy)(buf, "hi", sizeof buf) == 2 && strcmp(buf, "hi") == 0);
    strcpy(buf, "abc");
    CHECK(T(_platform_strlcat)(buf, "defgh", 6) == 8 && strcmp(buf, "abcde") == 0);
    strcpy(buf, "abc");
    CHECK(T(_platform_strlcat)(buf, "de", sizeof buf) == 5 && strcmp(buf, "abcde") == 0);
    memcpy(ref, "abcdef", 6); /* not terminated within size */
    CHECK(T(_platform_strlcat)(ref, "xyz", 4) == 7);
    CHECK(memcmp(ref, "abcdef", 6) == 0);
}

static void test_atomics(void)
{
    volatile int32_t i32 = 5;
    volatile int64_t i64 = 1ll << 40;
    volatile uint32_t u = 0xF0;
    CHECK(T(OSAtomicAdd32)(3, &i32) == 8 && i32 == 8);
    CHECK(T(OSAtomicIncrement32Barrier)(&i32) == 9);
    CHECK(T(OSAtomicDecrement32)(&i32) == 8);
    CHECK(T(OSAtomicAdd64Barrier)(-1, &i64) == (1ll << 40) - 1);
    CHECK(T(OSAtomicIncrement64)(&i64) == 1ll << 40);
    CHECK(T(OSAtomicDecrement64Barrier)(&i64) == (1ll << 40) - 1);
    CHECK(T(OSAtomicOr32)(0x0F, &u) == 0xFF);
    CHECK(T(OSAtomicAnd32Barrier)(0x3C, &u) == 0x3C);
    CHECK(T(OSAtomicXor32Orig)(0xFF, &u) == 0x3C && u == 0xC3);
    CHECK(T(OSAtomicOr32Orig)(0x100, &u) == 0xC3 && u == 0x1C3);
    CHECK(T(OSAtomicAnd32OrigBarrier)(0xF, &u) == 0x1C3 && u == 0x3);
    CHECK(T(OSAtomicXor32)(1, &u) == 2);
    CHECK(T(OSAtomicCompareAndSwap32)(8, 10, &i32) && i32 == 10);
    CHECK(!T(OSAtomicCompareAndSwap32)(8, 11, &i32) && i32 == 10);
    CHECK(T(OSAtomicCompareAndSwap64Barrier)((1ll << 40) - 1, 7, &i64) && i64 == 7);
    void *volatile ptr = NULL;
    int dummy;
    CHECK(T(OSAtomicCompareAndSwapPtr)(NULL, &dummy, &ptr) && ptr == &dummy);
    volatile long l = 3;
    CHECK(!T(OSAtomicCompareAndSwapLong)(4, 5, &l) && l == 3);
    unsigned char bits[2] = {0, 0};
    CHECK(!T(OSAtomicTestAndSet)(0, bits) && bits[0] == 0x80);
    CHECK(T(OSAtomicTestAndSet)(0, bits));
    CHECK(!T(OSAtomicTestAndSet)(9, bits) && bits[1] == 0x40);
    CHECK(T(OSAtomicTestAndClearBarrier)(9, bits) && bits[1] == 0);
    CHECK(!T(OSAtomicTestAndClearBarrier)(9, bits));
    T(OSMemoryBarrier)();

    struct elem { long pad; struct elem *link; int v; } e[4];
    OSQueueHead q = {0, 0};
    for (int i = 0; i < 4; i++) {
        e[i].v = i;
        T(OSAtomicEnqueue)(&q, &e[i], offsetof(struct elem, link));
    }
    for (int i = 3; i >= 0; i--) {
        struct elem *x = T(OSAtomicDequeue)(&q, offsetof(struct elem, link));
        CHECK(x == &e[i]);
    }
    CHECK(T(OSAtomicDequeue)(&q, offsetof(struct elem, link)) == NULL);
    OSFifoQueueHead f = {0, 0, 0};
    for (int i = 0; i < 4; i++)
        T(OSAtomicFifoEnqueue)(&f, &e[i], offsetof(struct elem, link));
    for (int i = 0; i < 4; i++)
        CHECK(T(OSAtomicFifoDequeue)(&f, offsetof(struct elem, link)) == &e[i]);
    CHECK(T(OSAtomicFifoDequeue)(&f, offsetof(struct elem, link)) == NULL);
}

/* ---- threaded tests ---------------------------------------------------- */

#define THREADS 4
#define ITERS 20000
static os_unfair_lock ulock;
static int32_t flock_word;
static os_unfair_recursive_lock rlock;
static volatile int32_t atomic_counter;
static long plain_counter, plain_counter2, plain_counter3;
static OSQueueHead shared_q;
static long once_pred, once_runs;
struct qelem { struct qelem *link; long v; };
static struct qelem qpool[THREADS][64];
static long dequeued_sum;

static void once_fn(void *ctx)
{
    (void)ctx;
    usleep(1000);
    __atomic_fetch_add(&once_runs, 1, __ATOMIC_RELAXED);
}

static void *worker(void *arg)
{
    long id = (long)arg;
    for (int i = 0; i < ITERS; i++) {
        T(os_unfair_lock_lock)(&ulock);
        plain_counter++;
        T(os_unfair_lock_unlock)(&ulock);
        T(_os_nospin_lock_lock)(&flock_word);
        plain_counter2++;
        T(_os_nospin_lock_unlock)(&flock_word);
        T(os_unfair_recursive_lock_lock_with_options)(&rlock, 0);
        T(os_unfair_recursive_lock_lock_with_options)(&rlock, 0);
        plain_counter3++;
        T(os_unfair_recursive_lock_unlock)(&rlock);
        T(os_unfair_recursive_lock_unlock)(&rlock);
        T(OSAtomicIncrement32Barrier)(&atomic_counter);
    }
    for (int round = 0; round < 200; round++) {
        for (int i = 0; i < 64; i++) {
            qpool[id][i].v = 1;
            T(OSAtomicEnqueue)(&shared_q, &qpool[id][i], 0);
        }
        for (int i = 0; i < 64; i++) {
            struct qelem *x = T(OSAtomicDequeue)(&shared_q, 0);
            if (x) __atomic_fetch_add(&dequeued_sum, x->v, __ATOMIC_RELAXED);
            else i--; /* another thread holds our element right now; retry */
        }
    }
    T(_os_once)(&once_pred, NULL, once_fn);
    return NULL;
}

static void test_threads(void)
{
    pthread_t t[THREADS];
    for (long i = 0; i < THREADS; i++)
        pthread_create(&t[i], NULL, worker, (void *)i);
    for (int i = 0; i < THREADS; i++)
        pthread_join(t[i], NULL);
    CHECK(plain_counter == (long)THREADS * ITERS);
    CHECK(plain_counter2 == (long)THREADS * ITERS);
    CHECK(plain_counter3 == (long)THREADS * ITERS);
    CHECK(atomic_counter == THREADS * ITERS);
    CHECK(dequeued_sum == (long)THREADS * 200 * 64);
    CHECK(ulock.v == 0 && flock_word == 0 && rlock.lock == 0 && rlock.count == 0);
    CHECK(once_runs == 1 && once_pred == ~0l);
    printf("  threads: %ld ulock waits, %ld wakes\n", ulock_wait_calls, ulock_wake_calls);
}

static void test_locks_single(void)
{
    os_unfair_lock l = {0};
    CHECK(T(os_unfair_lock_trylock)(&l));
    CHECK(l.v == __yc_lock_owner_id());
    T(os_unfair_lock_assert_owner)(&l);
    CHECK(!T(os_unfair_lock_trylock)(&l));
    T(os_unfair_lock_unlock)(&l);
    CHECK(l.v == 0);
    T(os_unfair_lock_assert_not_owner)(&l);
    T(os_unfair_lock_lock_with_options)(&l, 0x10000);
    T(os_unfair_lock_unlock)(&l);
    T(os_unfair_lock_lock_no_tsd)(&l, 0, 0x507);
    CHECK(l.v == 0x507);
    T(os_unfair_lock_unlock_no_tsd)(&l, 0x507);
    CHECK(l.v == 0);

    os_unfair_recursive_lock r = {0, 0};
    CHECK(!T(os_unfair_recursive_lock_owned)(&r));
    CHECK(T(os_unfair_recursive_lock_trylock)(&r));
    CHECK(T(os_unfair_recursive_lock_trylock)(&r) && r.count == 1);
    CHECK(T(os_unfair_recursive_lock_owned)(&r));
    CHECK(T(os_unfair_recursive_lock_tryunlock4objc)(&r) && r.count == 0);
    T(os_unfair_recursive_lock_unlock)(&r);
    CHECK(r.lock == 0 && !T(os_unfair_recursive_lock_tryunlock4objc)(&r));
    T(os_unfair_recursive_lock_lock_with_options)(&r, 0);
    T(os_unfair_recursive_lock_unlock_forked_child)(&r);
    CHECK(r.lock == 0);

    volatile int32_t s = 0;
    CHECK(T(OSSpinLockTry)(&s) && s != 0);
    CHECK(!T(OSSpinLockTry)(&s));
    T(OSSpinLockUnlock)(&s);
    CHECK(s == 0);
    T(OSSpinLockLock)(&s);
    T(OSSpinLockUnlock)(&s);
    T(spin_lock)(&s);
    T(spin_unlock)(&s);
    int32_t n = 0;
    CHECK(T(_os_nospin_lock_trylock)(&n) && !T(_os_nospin_lock_trylock)(&n));
    T(_os_nospin_lock_unlock)(&n);

    struct { const struct os_lock_type *type; uint32_t word; } ol = {&T(_os_lock_type_unfair), 0};
    T(os_lock_lock)(&ol);
    CHECK(ol.word == __yc_lock_owner_id());
    CHECK(!T(os_lock_trylock)(&ol));
    T(os_lock_unlock)(&ol);
    CHECK(ol.word == 0);
    ol.type = &T(_os_lock_type_spin);
    CHECK(T(os_lock_trylock)(&ol) && ol.word == 1);
    T(os_lock_unlock)(&ol);
    CHECK(ol.word == 0 && sizeof(struct os_lock_type) == 32);
}

static int alloc_init_runs;
static void alloc_init(void *p)
{
    alloc_init_runs++;
    CHECK(((long *)p)[0] == 0);
    ((long *)p)[0] = 42;
}

static void counting_fn(void *ctx) { (*(int *)ctx)++; }

static void test_once(void)
{
    long pred = 0;
    int runs = 0;
    T(_os_once)(&pred, &runs, counting_fn);
    T(_os_once)(&pred, &runs, counting_fn);
    CHECK(runs == 1 && pred == ~0l);
    T(__os_once_reset)(&pred);
    T(_os_once)(&pred, &runs, counting_fn);
    CHECK(runs == 2);
    struct alloc_once_slot slot = {0, NULL};
    long *p = T(_os_alloc_once)(&slot, 100, alloc_init);
    CHECK(p != NULL && p[0] == 42 && slot.ptr == p && slot.once == ~0l);
    CHECK(T(_os_alloc_once)(&slot, 100, alloc_init) == p && alloc_init_runs == 1);
}

static void test_bitops(void)
{
    CHECK(T(ffs)(0) == 0 && T(ffs)(1) == 1 && T(ffs)(0x80000000) == 32 && T(ffs)(12) == 3);
    CHECK(T(fls)(0) == 0 && T(fls)(1) == 1 && T(fls)(-1) == 32 && T(fls)(12) == 4);
    CHECK(T(ffsl)(1l << 40) == 41 && T(ffsll)(1ll << 63) == 64 && T(ffsll)(0) == 0);
    CHECK(T(flsl)(1l << 40) == 41 && T(flsll)(-1ll) == 64 && T(flsl)(0) == 0);
}

static void test_cache(void)
{
    static unsigned char code[4096];
    memset(code, 0, sizeof code);
    T(sys_icache_invalidate)(code + 3, 1000);
    T(sys_dcache_flush)(code + 5, 300);
    T(sys_icache_invalidate)(code, 0);
    CHECK(T(sys_cache_control)(1, code, 64) == 0);
    CHECK(T(sys_cache_control)(2, code, 64) == 0);
    CHECK(T(sys_cache_control)(7, code, 64) == 45);
}

static void test_sync(void)
{
    uint32_t word = 5;
    uint64_t word64 = 9;
    fake_errno = 0;
    CHECK(T(os_sync_wait_on_address)(&word, 5, 3, 0) == -1 && fake_errno == 22);
    CHECK(T(os_sync_wait_on_address)((char *)&word64 + 4, 5, 8, 0) == -1 && fake_errno == 22);
    CHECK(T(os_sync_wait_on_address)(&word, 5, 4, 2) == -1 && fake_errno == 22);
    CHECK(T(os_sync_wait_on_address)(NULL, 5, 4, 0) == -1);
    CHECK(T(os_sync_wait_on_address)(&word, 4, 4, 0) == 0);
    CHECK(T(os_sync_wait_on_address)(&word64, 9, 8, 1) == 0);
    CHECK(T(os_sync_wait_on_address_with_timeout)(&word, 5, 4, 0, 32, 12345) == -1 && fake_errno == 60);
    CHECK(T(os_sync_wait_on_address_with_timeout)(&word, 5, 4, 0, 1, 10) == -1 && fake_errno == 22);
    CHECK(T(os_sync_wait_on_address_with_deadline)(&word, 5, 4, 0, 32, 500) == -1 && fake_errno == 60);
    CHECK(T(os_sync_wait_on_address_with_deadline)(&word, 4, 4, 0, 32, 2000) == 0);
    wake_result = -2;
    CHECK(T(os_sync_wake_by_address_any)(&word, 4, 0) == -1 && fake_errno == 2);
    wake_result = 0;
    CHECK(T(os_sync_wake_by_address_all)(&word64, 8, 0) == 0);
}

static void test_simple(void)
{
    SIMPLE b = T(_simple_salloc)();
    CHECK(b != NULL);
    CHECK(T(_simple_sprintf)(b, "%d|%5d|%-4d|%05d|%u|%x|%X|%#|%o", -42, 7, 3, -12, 4000000000u, 255, 255, 8) == 0);
    CHECK(strcmp(T(_simple_string)(b), "-42|    7|3   |-0012|4000000000|ff|FF|%#|10") == 0);
    T(_simple_sresize)(b);
    char *s = T(_simple_string)(b);
    s[3] = 0;
    T(_simple_sresize)(b);
    CHECK(strcmp(T(_simple_string)(b), "-42") == 0);
    CHECK(T(_simple_sprintf)(b, "|%s|%.2s|%6s|%-3s|%c|%%|%p|%lld|%lx|%zu|%hhd|%s", "str", "abc", "r", "l", 'Z',
                             (void *)0x1234, -9000000000ll, 0xdeadbeefcafeul, (size_t)77, 300, (char *)NULL) == 0);
    CHECK(strcmp(T(_simple_string)(b), "-42|str|ab|     r|l  |Z|%|0x1234|-9000000000|deadbeefcafe|77|44|(null)") == 0);
    /* grow past the first page */
    char chunk[1001];
    memset(chunk, 'q', 1000);
    chunk[1000] = 0;
    for (int i = 0; i < 40; i++)
        CHECK(T(_simple_sappend)(b, chunk) == 0);
    CHECK(strlen(T(_simple_string)(b)) == strlen("-42|str|ab|     r|l  |Z|%|0x1234|-9000000000|deadbeefcafe|77|44|(null)") + 40000);
    T(_simple_sfree)(b);

    b = T(_simple_salloc)();
    T(_simple_sappend)(b, "line");
    captured_len = 0;
    T(_simple_put)(b, CAPTURE_FD);
    T(_simple_putline)(b, CAPTURE_FD);
    T(_simple_dprintf)(CAPTURE_FD, "[%d %s]", 5, "x");
    CHECK(strcmp(captured, "lineline\n[5 x]") == 0);
    T(_simple_sfree)(b);

    const char *env[] = {"A=1", "PATH=/bin", "PATHX=no", "EMPTY=", NULL};
    CHECK(strcmp(T(_simple_getenv)(env, "PATH"), "/bin") == 0);
    CHECK(strcmp(T(_simple_getenv)(env, "EMPTY"), "") == 0);
    CHECK(T(_simple_getenv)(env, "PAT") == NULL);
    CHECK(T(_simple_getenv)(env, "B") == NULL);
}

int yc_test___platform_sigaction(int sig, const void *nsv, void *osv);
void yc_sigtramp(void);
static void test_sigaction(void)
{
    struct { void *handler; uint32_t mask; int flags; } sa = {(void *)1, 0x80000000u, 0x42}, old;
    memset(&old, 0, sizeof old);
    CHECK(yc_test___platform_sigaction(20, &sa, &old) == 0);
    CHECK(sigaction_sig == 20 && sigaction_had_new);
    CHECK(sigaction_in[0] == 1 && sigaction_in[1] == (uint64_t)(uintptr_t)yc_sigtramp);
    CHECK(sigaction_in[2] == (0x80000000ull | (0x42ull << 32)));
    CHECK(old.handler == (void *)1 && old.mask == 5 && old.flags == 7);
    CHECK(yc_test___platform_sigaction(3, NULL, &old) == 0 && !sigaction_had_new);
    fake_errno = 0;
    CHECK(yc_test___platform_sigaction(9, &sa, NULL) == -1 && fake_errno == 22);
}

static void test_platform_init(void)
{
    char pfz[] = "pfz=0x1234";
    char sec[] = "security_config=0x2A";
    const char *apple[] = {"executable_path=/x", pfz, sec, NULL};
    const char *envp[] = {"HOME=/tmp", NULL};
    const char *progname = "hello";
    struct { const void *mh; int *argc; void *argv, *environ; const char **progname; } vars = {0, 0, 0, 0, &progname};
    T(__libplatform_init)(NULL, envp, apple, &vars);
    CHECK(memcmp(pfz, "\0\0\0\0\0\0\0\0\0\0", 10) == 0);
    CHECK(strcmp(sec, "security_config=0x2A") == 0);
    CHECK(__yc_security_config() == 0x2A);
    CHECK(kernel_string_table != NULL && kernel_string_table[0] == 1);
    CHECK(kernel_string_table && kernel_string_table[4] == (unsigned long)T(_platform_memmove));
    CHECK(kernel_string_table && kernel_string_table[16] == (unsigned long)T(_platform_strstr));
    CHECK(yc_testk__os_alloc_once_table[21].once == ~0l && yc_testk__os_alloc_once_table[21].ptr != NULL);
    {
        /* libplatform's asl_context layout (shared with the simulator's
         * libsystem_sim_platform): enabled @0, progname @8, fd @16, and a
         * zero sim_connect_lock word @32 inside the allocation. */
        const char *ctx = yc_testk__os_alloc_once_table[21].ptr;
        CHECK(*(const unsigned char *)ctx == 1);
        CHECK(strcmp(*(const char *const *)(ctx + 8), "hello") == 0);
        CHECK(*(const int *)(ctx + 16) == -1);
        CHECK(*(const uint32_t *)(ctx + 32) == 0 && *(const uint64_t *)(ctx + 24) == 0);
    }
    T(__libplatform_init)(NULL, envp, apple, &vars); /* calling twice is harmless */
    CHECK(__yc_security_config() == 0x2A);
}

#if HAVE_SETJMP
static yc_jmp_buf jb;
static volatile int depth;

static __attribute__((noinline)) void jump_back(int v)
{
    depth++;
    T(longjmp)(jb, v);
}

static __attribute__((noinline)) void clobber_callee_saved(void)
{
    /* Change every callee-saved register; _longjmp must restore them. */
    __asm__ volatile(
        "mov x19, #1\n mov x20, #2\n mov x21, #3\n mov x22, #4\n mov x23, #5\n"
        "mov x24, #6\n mov x25, #7\n mov x26, #8\n mov x27, #9\n mov x28, #10\n"
        "fmov d8, xzr\n fmov d9, xzr\n fmov d10, xzr\n fmov d11, xzr\n"
        "fmov d12, xzr\n fmov d13, xzr\n fmov d14, xzr\n fmov d15, xzr\n"
        ::: "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28",
            "d8", "d9", "d10", "d11", "d12", "d13", "d14", "d15");
    T(_longjmp)(jb, 7);
}

static int check_registers_survive(void)
{
    uint64_t before[10], after[10];
    double fbefore[8], fafter[8];
    int ok = 1;
    __asm__ volatile(
        "movz x19, #0x1111\n movz x20, #0x2222\n movz x21, #0x3333\n movz x22, #0x4444\n movz x23, #0x5555\n"
        "movz x24, #0x6666\n movz x25, #0x7777\n movz x26, #0x8888\n movz x27, #0x9999\n movz x28, #0xaaaa\n"
        "fmov d8, #1.0\n fmov d9, #2.0\n fmov d10, #3.0\n fmov d11, #4.0\n"
        "fmov d12, #5.0\n fmov d13, #6.0\n fmov d14, #7.0\n fmov d15, #8.0\n"
        "stp x19, x20, [%0]\n stp x21, x22, [%0, #16]\n stp x23, x24, [%0, #32]\n"
        "stp x25, x26, [%0, #48]\n stp x27, x28, [%0, #64]\n"
        "stp d8, d9, [%1]\n stp d10, d11, [%1, #16]\n stp d12, d13, [%1, #32]\n stp d14, d15, [%1, #48]\n"
        :: "r"(before), "r"(fbefore) : "memory", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26",
           "x27", "x28", "d8", "d9", "d10", "d11", "d12", "d13", "d14", "d15");
    if (T(_setjmp)(jb) == 0)
        clobber_callee_saved();
    __asm__ volatile(
        "stp x19, x20, [%0]\n stp x21, x22, [%0, #16]\n stp x23, x24, [%0, #32]\n"
        "stp x25, x26, [%0, #48]\n stp x27, x28, [%0, #64]\n"
        "stp d8, d9, [%1]\n stp d10, d11, [%1, #16]\n stp d12, d13, [%1, #32]\n stp d14, d15, [%1, #48]\n"
        :: "r"(after), "r"(fafter) : "memory");
    for (int i = 0; i < 10; i++) ok &= before[i] == after[i];
    for (int i = 0; i < 8; i++) ok &= fbefore[i] == fafter[i];
    return ok;
}

static void test_setjmp(void)
{
    volatile int count = 0;
    int r = T(setjmp)(jb);
    count++;
    if (r == 0)
        jump_back(5);
    CHECK(r == 5 && count == 2 && depth == 1);

    r = T(_setjmp)(jb);
    if (r == 0)
        T(_longjmp)(jb, 0);
    CHECK(r == 1); /* longjmp with 0 returns 1 */

    /* setjmp saves the signal mask, longjmp restores it */
    fake_sigmask = 0x11;
    r = T(setjmp)(jb);
    if (r == 0) {
        fake_sigmask = 0xFF;
        T(longjmp)(jb, 2);
    }
    CHECK(r == 2 && fake_sigmask == 0x11);

    /* sigsetjmp(env, 0) does not touch it; sigsetjmp(env, 1) does */
    fake_sigmask = 0x22;
    r = T(sigsetjmp)(jb, 0);
    if (r == 0) {
        fake_sigmask = 0x33;
        T(siglongjmp)(jb, 3);
    }
    CHECK(r == 3 && fake_sigmask == 0x33);
    r = T(sigsetjmp)(jb, 1);
    if (r == 0) {
        fake_sigmask = 0x44;
        T(siglongjmp)(jb, 4);
    }
    CHECK(r == 4 && fake_sigmask == 0x33);

    CHECK(check_registers_survive());
}
#endif

int main(void)
{
    test_memory();
    test_memory_large();
    test_strings();
    test_atomics();
    test_locks_single();
    test_once();
    test_bitops();
    test_cache();
    test_sync();
    test_simple();
    test_platform_init();
    test_sigaction();
#if HAVE_SETJMP
    test_setjmp();
#else
    printf("  setjmp tests skipped (not an arm64 host)\n");
#endif
    test_threads();
    printf("platform host tests: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
