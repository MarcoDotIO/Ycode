/*
 * nt_probe: the native-mode guest probe (specs/simulator/native-mode.md
 * section 8). Original Ycode code.
 *
 * A Darwin arm64 (iOS simulator platform) program that links only Ycode's
 * libsystem_kernel. It is built on macOS by build.sh in this directory and
 * run on arm64 Linux by ycnative (ycode/Native/runtime). It checks the
 * native-mode process contract (TSD base, errno through the TSD, the
 * commpage, the CPU-number register, library calls and raw svc #0x80
 * calls) and then times three kinds of call:
 *
 *   lib    getppid() through libsystem_kernel: its svc #0x80 was rewritten
 *          by the loader into a branch to the runtime (a function call);
 *   raw    an svc #0x80 in this program's own text, which the loader does
 *          not rewrite (as for code outside Ycode's libraries); it reaches
 *          the runtime through seccomp-bpf (SIGSYS) when that is enabled;
 *   clock  mach_absolute_time(), a Mach fast trap (-3) in the library.
 *
 * Exit status: 0 when every check passes, otherwise the number of the
 * first failed check (10..29).
 */
#include <stdint.h>

/* libsystem_kernel (Darwin names; no SDK headers are needed). */
extern long write(int fd, const void *buf, unsigned long n);
extern int getpid(void);
extern int getppid(void);
extern int close(int fd);
extern int *__error(void);
extern uint64_t mach_absolute_time(void);
struct nt_timebase { uint32_t numer, denom; };
extern int mach_timebase_info(struct nt_timebase *info);

/* ---- output without libc ------------------------------------------- */
static char obuf[512];
static unsigned olen;

static void put_s(const char *s)
{
    while (*s && olen < sizeof obuf)
        obuf[olen++] = *s++;
}

static void put_u(uint64_t v)
{
    char t[24];
    int n = 0;
    do {
        t[n++] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    while (n && olen < sizeof obuf)
        obuf[olen++] = t[--n];
}

static void put_x(uint64_t v)
{
    static const char hex[] = "0123456789abcdef";
    put_s("0x");
    int started = 0;
    for (int i = 60; i >= 0; i -= 4) {
        unsigned d = (unsigned)(v >> i) & 15;
        if (d || started || i == 0) {
            if (olen < sizeof obuf)
                obuf[olen++] = hex[d];
            started = 1;
        }
    }
}

/* v is in tenths: prints "12.3". */
static void put_d1(uint64_t v)
{
    put_u(v / 10);
    put_s(".");
    put_u(v % 10);
}

static void flush(void)
{
    write(1, obuf, olen);
    olen = 0;
}

/* ---- direct register and trap access ------------------------------- */
static inline uint64_t read_tpidrro(void)
{
    uint64_t v;
    __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(v));
    return v;
}

static inline uint64_t read_tpidr(void)
{
    uint64_t v;
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(v));
    return v;
}

/* BSD 39 (getppid) issued from this program's own text. */
static inline long raw_getppid(void)
{
    register long x16 __asm__("x16") = 39;
    register long x0 __asm__("x0");
    __asm__ volatile("svc #0x80" : "=r"(x0) : "r"(x16) : "memory", "cc", "x1");
    return x0;
}

/* BSD 9999 from this program's own text: carry set, x0 = ENOSYS (78). */
static inline int raw_enosys(long *err)
{
    register long x16 __asm__("x16") = 9999;
    register long x0 __asm__("x0") = 0;
    long carry;
    __asm__ volatile("svc #0x80\n\tcset %1, cs" : "+r"(x0), "=r"(carry) : "r"(x16) : "memory", "cc", "x1");
    *err = x0;
    return (int)carry;
}

static uint64_t ns(uint64_t ticks, struct nt_timebase tb)
{
    return ticks * tb.numer / tb.denom;
}

#define CHECK(cond, code)                                                     \
    do {                                                                      \
        if (!(cond)) {                                                        \
            put_s("nt_probe: check ");                                        \
            put_u(code);                                                      \
            put_s(" failed\n");                                               \
            flush();                                                          \
            return code;                                                      \
        }                                                                     \
    } while (0)

int main(int argc, char **argv, char **envp, char **apple)
{
    (void)argc;
    (void)argv;
    (void)envp;
    int quick = 0;
    long rawIters = 100000;
    for (char **a = apple; a && *a; a++) {
        const char *s = *a;
        /* "ycn_raw=0": the runtime has no seccomp path; skip raw calls. */
        if (s[0] == 'y' && s[1] == 'c' && s[2] == 'n' && s[3] == '_' && s[4] == 'r' && s[5] == 'a' &&
            s[6] == 'w' && s[7] == '=' && s[8] == '0')
            rawIters = 0;
        if (s[0] == 'y' && s[1] == 'c' && s[2] == 'n' && s[3] == '_' && s[4] == 'q')
            quick = 1;
    }

    /* 10: TSD base (TPIDRRO_EL0 as Darwin code reads it) points at slot 0,
     * and slot 0 holds the pthread_t, which is the base minus 224. */
    uint64_t tsd = read_tpidrro();
    CHECK(tsd != 0 && (tsd & 15) == 0, 10);
    CHECK(((uint64_t *)tsd)[0] == tsd - 224, 11);

    /* 12: the CPU-number register reads as a small CPU index. */
    CHECK((read_tpidr() & 0xFFF) < 256, 12);

    /* 13: the commpage signature at 0xF_FFFF_C000. */
    const char *cp = (const char *)0xFFFFFC000ull;
    CHECK(cp[0] == 'c' && cp[1] == 'o' && cp[8] == '6' && cp[9] == '4', 13);
    /* 14: the page shift fields say 16 KiB. */
    CHECK(cp[0x25] == 14, 14);

    /* 15-16: library calls. */
    int pid = getpid();
    CHECK(pid > 0, 15);
    int ppid = getppid();
    CHECK(ppid > 0, 16);

    /* 17-18: errno through TSD slot 1 (close(-1) is EBADF = 9). */
    CHECK(close(-1) == -1, 17);
    CHECK(*__error() == 9, 18);
    CHECK(__error() == (int *)((uint64_t *)tsd)[1], 19);

    /* 20-21: time. */
    struct nt_timebase tb = { 0, 0 };
    CHECK(mach_timebase_info(&tb) == 0 && tb.numer && tb.denom, 20);
    uint64_t t0 = mach_absolute_time();
    uint64_t t1 = mach_absolute_time();
    CHECK(t0 && t1 >= t0, 21);

    /* 22-23: raw svc from this program's text. */
    if (rawIters) {
        CHECK(raw_getppid() == ppid, 22);
        long err = 0;
        CHECK(raw_enosys(&err) == 1 && err == 78, 23);
    }

    put_s("nt_probe: checks ok (tsd ");
    put_x(tsd);
    put_s(", pid ");
    put_u((uint64_t)pid);
    put_s(", ppid ");
    put_u((uint64_t)ppid);
    put_s(", timebase ");
    put_u(tb.numer);
    put_s("/");
    put_u(tb.denom);
    put_s(")\n");
    flush();

    /* ---- timing ---- */
    long libIters = quick ? 100000 : 2000000;
    long clockIters = quick ? 100000 : 2000000;
    if (quick && rawIters)
        rawIters = 20000;

    uint64_t a = mach_absolute_time();
    for (long i = 0; i < libIters; i++)
        (void)getppid();
    uint64_t b = mach_absolute_time();
    for (long i = 0; i < clockIters; i++)
        (void)mach_absolute_time();
    uint64_t c = mach_absolute_time();
    for (long i = 0; i < rawIters; i++)
        (void)raw_getppid();
    uint64_t d = mach_absolute_time();

    put_s("nt_probe: lib getppid ");
    put_d1(ns(b - a, tb) * 10 / (uint64_t)libIters);
    put_s(" ns, mach_absolute_time ");
    put_d1(ns(c - b, tb) * 10 / (uint64_t)clockIters);
    put_s(" ns");
    if (rawIters) {
        put_s(", raw svc getppid ");
        put_d1(ns(d - c, tb) * 10 / (uint64_t)rawIters);
        put_s(" ns");
    }
    put_s(" per call\n");
    flush();
    return 0;
}
