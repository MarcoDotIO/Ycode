/* Ycode guest probe: CPU feature publication (specs/simulator/cpu-features.md
 * §5 and §7.1). Original Ycode code; the instruction encodings come from the
 * public Arm Architecture Reference Manual (assembled by clang).
 *
 *   1. prints the CPU sysctls and the commpage capability words;
 *   2. checks the §5 invariants (names = caps bits, commpage = caps bits,
 *      legacy names, cache line, CPU counts, deny list, timebase);
 *   3. runs one instruction per feature in a child process (re-executing
 *      itself: "p_cpufeat insn <name>") and records executed / SIGILL; a
 *      published feature must execute, a hidden one should SIGILL cleanly
 *      (a hidden one that executes is reported, not failed: the hardware
 *      has it and the guest was simply not told);
 *   4. DIT, SSBS and FPCR (FZ, DN, and AH/FIZ/NEP when AFP is published)
 *      survive a BSD trap, a Mach trap, a page fault, a yield, a sleep and
 *      another thread's run; a new thread starts with DIT = 0 and FPCR = 0
 *      even after an earlier thread changed them;
 *   5. bzero/memset at many alignments and lengths keep guard bytes intact,
 *      and DC ZVA zeroes exactly the DCZID_EL0 block.
 * Prints "cpufeat ok ..." or "cpufeat FAIL <n> ..." as its last line. */
#include <mach/mach_time.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/sysctl.h>

#include "../stage4b/probe_util.h"

#define ARCH ".arch armv9.4-a+crypto+sha3+sha2+aes+fp16fml+rcpc+bf16+i8mm+sve+sme+mte+predres+flagm+ssbs+sb+pauth+lse+rdm+dotprod\n"
#define COMMPAGE_RW 0xFFFFFC000ull

static int failures;
static void fail(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void fail(const char *fmt, ...)
{
    va_list ap;
    printf("FAIL: ");
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    failures++;
}

/* ---- sysctl helpers ---- */

static long sys_int(const char *name, int *ok)
{
    uint64_t v = 0;
    size_t len = sizeof v;
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) { if (ok) *ok = 0; return -1; }
    if (ok) *ok = 1;
    return len == 4 ? (long)(int32_t)(uint32_t)v : (long)v;
}

static int caps_bit(const uint8_t *caps, int bit) { return (caps[bit / 8] >> (bit % 8)) & 1; }

/* ---- the caps names (§2.3) ---- */

struct named { int bit; const char *name; };
static const struct named names[] = {
    {0, "FEAT_FlagM"}, {1, "FEAT_FlagM2"}, {2, "FEAT_FHM"}, {3, "FEAT_DotProd"}, {4, "FEAT_SHA3"}, {5, "FEAT_RDM"},
    {6, "FEAT_LSE"}, {7, "FEAT_SHA256"}, {8, "FEAT_SHA512"}, {9, "FEAT_SHA1"}, {10, "FEAT_AES"}, {11, "FEAT_PMULL"},
    {12, "FEAT_SPECRES"}, {13, "FEAT_SB"}, {14, "FEAT_FRINTTS"}, {15, "FEAT_LRCPC"}, {16, "FEAT_LRCPC2"},
    {17, "FEAT_FCMA"}, {18, "FEAT_JSCVT"}, {19, "FEAT_PAuth"}, {20, "FEAT_PAuth2"}, {21, "FEAT_FPAC"},
    {22, "FEAT_DPB"}, {23, "FEAT_DPB2"}, {24, "FEAT_BF16"}, {25, "FEAT_I8MM"}, {26, "FEAT_WFxT"},
    {27, "FEAT_RPRES"}, {28, "FEAT_ECV"}, {29, "FEAT_AFP"}, {30, "FEAT_LSE2"}, {31, "FEAT_CSV2"},
    {32, "FEAT_CSV3"}, {33, "FEAT_DIT"}, {34, "FEAT_FP16"}, {35, "FEAT_SSBS"}, {36, "FEAT_BTI"},
    {40, "FEAT_SME"}, {41, "FEAT_SME2"}, {49, "AdvSIMD"}, {50, "AdvSIMD_HPFPCvt"}, {51, "FEAT_CRC32"},
    {58, "FEAT_PACIMP"}, {60, "FEAT_MTE"}, {61, "FEAT_MTE2"}, {64, "FEAT_HBC"}, {65, "FEAT_EBF16"},
    {66, "FEAT_SPECRES2"}, {67, "FEAT_CSSC"}, {68, "FEAT_FPACCOMBINE"}, {73, "FP_SyncExceptions"},
    {91, "FEAT_SVE_B16B16"},
};
#define NNAMES (int)(sizeof names / sizeof names[0])

/* Deny list (§4.3). */
static int denied(int bit)
{
    if (bit >= 40 && bit <= 48) return 1;
    if (bit >= 52 && bit <= 57) return 1;
    if (bit >= 60 && bit <= 63) return 1;
    if (bit >= 69 && bit <= 72) return 1;
    switch (bit) {
    case 12: case 19: case 20: case 21: case 26: case 28: case 37: case 38: case 39: case 58: case 59:
    case 66: case 68: case 91: return 1;
    }
    return (bit >= 74 && bit <= 90) || (bit >= 92 && bit <= 96);
}

/* Commpage masks and their caps bits (§2.5). */
struct pair { int bit; uint64_t mask; };
static const struct pair pairs[] = {
    {34, 0x8}, {49, 0x100}, {50, 0x200}, {2, 0x4000}, {6, 0x02000000}, {51, 0x04000000}, {8, 0x80000000},
    {4, 1ull << 32}, {17, 1ull << 33}, {29, 1ull << 34}, {0, 1ull << 40}, {1, 1ull << 41}, {3, 1ull << 42},
    {5, 1ull << 43}, {12, 1ull << 44}, {13, 1ull << 45}, {14, 1ull << 46}, {58, 1ull << 47}, {15, 1ull << 48},
    {16, 1ull << 49}, {18, 1ull << 50}, {19, 1ull << 51}, {22, 1ull << 52}, {23, 1ull << 53}, {30, 1ull << 54},
    {31, 1ull << 55}, {32, 1ull << 56}, {33, 1ull << 57}, {73, 1ull << 58}, {40, 1ull << 59}, {41, 1ull << 60},
};
#define NPAIRS (int)(sizeof pairs / sizeof pairs[0])

/* ---- instructions (one per feature) ---- */

static uint64_t scratch[64] __attribute__((aligned(256)));

#define INSN(fname, body, ...) \
    static void fname(void) { __asm__ volatile(ARCH body ::__VA_ARGS__); }

INSN(t_flagm, "cfinv\n", "r"(0) : "cc")
INSN(t_flagm2, "axflag\n", "r"(0) : "cc")
INSN(t_fhm, "fmlal v0.2s, v1.2h, v2.2h\n", "r"(0) : "v0")
INSN(t_dotprod, "sdot v0.4s, v1.16b, v2.16b\n", "r"(0) : "v0")
INSN(t_sha3, "eor3 v0.16b, v1.16b, v2.16b, v3.16b\n", "r"(0) : "v0")
INSN(t_rdm, "sqrdmlah v0.4s, v1.4s, v2.4s\n", "r"(0) : "v0")
INSN(t_lse, "mov x0, #0\n mov x1, #1\n cas x0, x1, [%0]\n ldadd x1, x0, [%0]\n", "r"(scratch) : "x0", "x1", "memory")
INSN(t_sha256, "sha256h q0, q1, v2.4s\n", "r"(0) : "v0")
INSN(t_sha512, "sha512h q0, q1, v2.2d\n", "r"(0) : "v0")
INSN(t_sha1, "sha1c q0, s1, v2.4s\n", "r"(0) : "v0")
INSN(t_aes, "aese v0.16b, v1.16b\n", "r"(0) : "v0")
INSN(t_pmull, "pmull v0.1q, v1.1d, v2.1d\n", "r"(0) : "v0")
INSN(t_sb, "sb\n", "r"(0) : "memory")
INSN(t_frintts, "frint32z v0.2s, v1.2s\n", "r"(0) : "v0")
INSN(t_lrcpc, "ldapr x0, [%0]\n", "r"(scratch) : "x0", "memory")
INSN(t_lrcpc2, "ldapur x0, [%0, #8]\n", "r"(scratch) : "x0", "memory")
INSN(t_fcma, "fcmla v0.4s, v1.4s, v2.4s, #0\n", "r"(0) : "v0")
INSN(t_jscvt, "fmov d1, #1.5\n fjcvtzs w0, d1\n", "r"(0) : "x0", "v1", "cc")
INSN(t_dpb, "dc cvap, %0\n", "r"(scratch) : "memory")
INSN(t_dpb2, "dc cvadp, %0\n", "r"(scratch) : "memory")
INSN(t_bf16, "bfdot v0.4s, v1.8h, v2.8h\n", "r"(0) : "v0")
INSN(t_i8mm, "smmla v0.4s, v1.16b, v2.16b\n", "r"(0) : "v0")
INSN(t_fp16, "fadd h0, h1, h2\n", "r"(0) : "v0")
INSN(t_hpfpcvt, "fcvtl v0.4s, v1.4h\n", "r"(0) : "v0")
INSN(t_advsimd, "add v0.4s, v1.4s, v2.4s\n", "r"(0) : "v0")
INSN(t_crc32, "crc32cx w0, w0, x1\n", "r"(0) : "x0")
INSN(t_dit, "msr dit, #1\n mrs x0, dit\n msr dit, #0\n", "r"(0) : "x0")
INSN(t_ssbs, "msr ssbs, #1\n mrs x0, ssbs\n msr ssbs, #0\n", "r"(0) : "x0")
INSN(t_pacga, "pacga x0, x1, x2\n", "r"(0) : "x0")
INSN(t_autia, "mov x0, #0\n autia x0, x1\n", "r"(0) : "x0")
INSN(t_sme, "smstart\n smstop\n", "r"(0) : "memory")
INSN(t_sve, "rdvl x0, #1\n", "r"(0) : "x0")
INSN(t_mte, "irg x0, sp\n", "r"(0) : "x0")
INSN(t_specres, "cfp rctx, %0\n", "r"(0ull) : "memory")
INSN(t_wfxt, "mov x0, #0\n .inst 0xd5031000\n", "r"(0) : "x0")       /* WFET x0 (deadline 0: returns at once) */
INSN(t_ecv, "mrs x0, cntvctss_el0\n", "r"(0) : "x0")

/* FPCR.AH (bit 1) reads back as written. Exit 3 when it does not. */
static void t_afp(void)
{
    uint64_t old, v;
    __asm__ volatile("mrs %0, fpcr" : "=r"(old));
    __asm__ volatile("msr fpcr, %0\n isb" ::"r"(old | 2));
    __asm__ volatile("mrs %0, fpcr" : "=r"(v));
    __asm__ volatile("msr fpcr, %0\n isb" ::"r"(old));
    if (!(v & 2)) exit(3);
}

/* FP_SyncExceptions: the six trap-enable bits read back as 1. */
static void t_fpsync(void)
{
    uint64_t old, v;
    __asm__ volatile("mrs %0, fpcr" : "=r"(old));
    __asm__ volatile("msr fpcr, %0\n isb" ::"r"(old | 0x9F00));
    __asm__ volatile("mrs %0, fpcr" : "=r"(v));
    __asm__ volatile("msr fpcr, %0\n isb" ::"r"(old));
    if ((v & 0x9F00) != 0x9F00) exit(3);
}

struct insn { const char *name; int bit; void (*fn)(void); };
static const struct insn insns[] = {
    {"FlagM:cfinv", 0, t_flagm}, {"FlagM2:axflag", 1, t_flagm2}, {"FHM:fmlal", 2, t_fhm}, {"DotProd:sdot", 3, t_dotprod},
    {"SHA3:eor3", 4, t_sha3}, {"RDM:sqrdmlah", 5, t_rdm}, {"LSE:cas+ldadd", 6, t_lse}, {"SHA256:sha256h", 7, t_sha256},
    {"SHA512:sha512h", 8, t_sha512}, {"SHA1:sha1c", 9, t_sha1}, {"AES:aese", 10, t_aes}, {"PMULL:pmull.1q", 11, t_pmull},
    {"SPECRES:cfp_rctx", 12, t_specres}, {"SB:sb", 13, t_sb}, {"FRINTTS:frint32z", 14, t_frintts}, {"LRCPC:ldapr", 15, t_lrcpc},
    {"LRCPC2:ldapur", 16, t_lrcpc2}, {"FCMA:fcmla", 17, t_fcma}, {"JSCVT:fjcvtzs", 18, t_jscvt},
    {"PAuth:pacga", 19, t_pacga}, {"PAuth:autia", 19, t_autia},
    {"DPB:dc_cvap", 22, t_dpb}, {"DPB2:dc_cvadp", 23, t_dpb2}, {"BF16:bfdot", 24, t_bf16}, {"I8MM:smmla", 25, t_i8mm},
    {"WFxT:wfet", 26, t_wfxt}, {"ECV:mrs_cntvctss", 28, t_ecv}, {"AFP:fpcr.ah", 29, t_afp}, {"DIT:msr_dit", 33, t_dit},
    {"FP16:fadd_h", 34, t_fp16}, {"SSBS:msr_ssbs", 35, t_ssbs}, {"SME:smstart", 40, t_sme},
    {"AdvSIMD:add", 49, t_advsimd}, {"HPFPCvt:fcvtl", 50, t_hpfpcvt}, {"CRC32:crc32cx", 51, t_crc32},
    {"MTE:irg", 60, t_mte}, {"FP_SyncExceptions:fpcr", 73, t_fpsync}, {"SVE:rdvl", -1, t_sve},
};
#define NINSNS (int)(sizeof insns / sizeof insns[0])

/* ---- DIT / SSBS / FPCR round trips ---- */

static uint64_t rd_dit(void) { uint64_t v; __asm__ volatile(ARCH "mrs %0, dit" : "=r"(v)); return v; }
static uint64_t rd_ssbs(void) { uint64_t v; __asm__ volatile(ARCH "mrs %0, ssbs" : "=r"(v)); return v; }
static uint64_t rd_fpcr(void) { uint64_t v; __asm__ volatile("mrs %0, fpcr" : "=r"(v)); return v; }
static void wr_fpcr(uint64_t v) { __asm__ volatile("msr fpcr, %0\n isb" ::"r"(v)); }

static uint64_t svc_bsd(long n)
{
    register uint64_t x0 __asm__("x0") = 0;
    register long x16 __asm__("x16") = n;
    __asm__ volatile("svc #0x80" : "+r"(x0), "+r"(x16) : : "x1", "memory", "cc");
    return x0;
}

static void *spin_thread(void *arg)
{
    volatile uint64_t x = 0;
    for (int i = 0; i < 2000000; i++) x += (uint64_t)i;
    return arg;
}

struct state { uint64_t dit, ssbs, fpcr; };
static struct state now_state(void) { struct state s = {rd_dit(), rd_ssbs(), rd_fpcr()}; return s; }

static void check_state(const char *after, struct state want)
{
    struct state s = now_state();
    if (s.dit != want.dit || s.ssbs != want.ssbs || s.fpcr != want.fpcr)
        fail("state after %s: DIT %#llx SSBS %#llx FPCR %#llx, expected %#llx %#llx %#llx", after,
             (unsigned long long)s.dit, (unsigned long long)s.ssbs, (unsigned long long)s.fpcr,
             (unsigned long long)want.dit, (unsigned long long)want.ssbs, (unsigned long long)want.fpcr);
}

static void *dirty_thread(void *arg)
{
    (void)arg;
    __asm__ volatile(ARCH "msr dit, #1\n msr ssbs, #1");
    wr_fpcr((1u << 24) | (3u << 22) | (1u << 25));    /* FZ, RMode RZ, DN */
    return NULL;
}

static void *fresh_thread(void *arg)
{
    struct state *out = arg;
    *out = now_state();
    return NULL;
}

static void state_round_trip(int afp, int dit, int ssbs)
{
    if (!dit || !ssbs) printf("state: DIT published %d, SSBS published %d (checking what is published)\n", dit, ssbs);
    int before = failures;
    struct state saved = now_state();
    printf("state: main thread starts with DIT %#llx SSBS %#llx FPCR %#llx\n", (unsigned long long)saved.dit,
           (unsigned long long)saved.ssbs, (unsigned long long)saved.fpcr);
    if (dit) __asm__ volatile(ARCH "msr dit, #1");
    if (ssbs) __asm__ volatile(ARCH "msr ssbs, #1");
    uint64_t fpcr = (1u << 24) | (1u << 25);           /* FZ, DN */
    if (afp) fpcr |= 1u | 2u | 4u;                     /* FIZ, AH, NEP */
    wr_fpcr(fpcr);
    struct state want = now_state();
    if (dit && !(want.dit & (1u << 24))) fail("DIT did not read back as set (%#llx)", (unsigned long long)want.dit);
    if (ssbs && !(want.ssbs & (1u << 12))) fail("SSBS did not read back as set (%#llx)", (unsigned long long)want.ssbs);
    if (want.fpcr != fpcr) fail("FPCR read back %#llx, wrote %#llx", (unsigned long long)want.fpcr, (unsigned long long)fpcr);

    (void)svc_bsd(20);                                  /* getpid: a BSD trap */
    check_state("a BSD trap", want);
    (void)svc_bsd(-3);                                  /* mach_absolute_time: a Mach trap */
    check_state("a Mach trap", want);
    (void)mach_absolute_time();                         /* the in-place (fast) path */
    check_state("mach_absolute_time()", want);
    size_t big = 64u << 20;
    char *p = mmap(NULL, big, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) fail("mmap: %s", strerror(errno));
    else {
        p[big / 2] = 1;                                 /* first touch: a page fault */
        check_state("a page fault", want);
        munmap(p, big);
    }
    sched_yield();
    check_state("sched_yield", want);
    probe_sleep_ms(20);
    check_state("a 20 ms sleep", want);
    pthread_t t;
    pthread_create(&t, NULL, spin_thread, NULL);
    pthread_join(t, NULL);
    check_state("another thread's run and a join", want);

    /* New threads: start clean even after a thread that set everything. */
    int dirty_new = 0;
    for (int round = 0; round < 4; round++) {
        pthread_create(&t, NULL, dirty_thread, NULL);
        pthread_join(t, NULL);
        struct state fresh = {~0ull, ~0ull, ~0ull};
        pthread_create(&t, NULL, fresh_thread, &fresh);
        pthread_join(t, NULL);
        if (fresh.dit != 0 || fresh.fpcr != 0) {
            fail("new thread (round %d) starts with DIT %#llx FPCR %#llx", round, (unsigned long long)fresh.dit,
                 (unsigned long long)fresh.fpcr);
            dirty_new++;
        }
        if (round == 0) printf("state: a new thread starts with DIT %#llx SSBS %#llx FPCR %#llx\n",
                               (unsigned long long)fresh.dit, (unsigned long long)fresh.ssbs, (unsigned long long)fresh.fpcr);
    }
    check_state("other threads' starts", want);
    __asm__ volatile(ARCH "msr dit, #0\n msr ssbs, #0");
    wr_fpcr(saved.fpcr);
    printf("state: round trips %s; new threads clean in %d/4 rounds\n", failures > before ? "FAILED (see FAIL lines)" : "ok", 4 - dirty_new);
}

/* ---- ZVA safety (§6, §7.1) ---- */

static void zva_safety(long line)
{
    uint64_t dczid;
    __asm__ volatile("mrs %0, dczid_el0" : "=r"(dczid));
    size_t block = (size_t)4 << (dczid & 0xF);
    int prohibited = (int)((dczid >> 4) & 1);
    printf("zva: DCZID_EL0 %#llx (block %zu bytes, %s); hw.cachelinesize %ld\n", (unsigned long long)dczid, block,
           prohibited ? "prohibited" : "allowed", line);
    const size_t guard = 256, area = 70000;
    uint8_t *buf = malloc(area + 2 * guard + 512);
    int checked = 0, bad = 0;
    static const size_t lens[] = {0, 1, 7, 8, 15, 16, 31, 32, 63, 64, 65, 127, 128, 129, 191, 255, 256, 257, 511, 512, 1000,
                                  4095, 4096, 4097, 16384, 65536, 65537};
    for (size_t li = 0; li < sizeof lens / sizeof lens[0]; li++) {
        for (size_t off = 0; off < 160; off += (off < 70 ? 1 : 13)) {
            for (int which = 0; which < 2; which++) {
                size_t len = lens[li];
                memset(buf, 0xA5, area + 2 * guard + 512);
                uint8_t *dst = buf + guard + off;
                if (which == 0) bzero(dst, len); else memset(dst, 0, len);
                for (size_t i = 0; i < guard + off; i++) if (buf[i] != 0xA5) { bad++; break; }
                for (size_t i = 0; i < len; i++) if (dst[i] != 0) { bad++; break; }
                for (size_t i = 0; i < guard; i++) if (dst[len + i] != 0xA5) { bad++; break; }
                checked++;
            }
        }
    }
    if (bad) fail("bzero/memset guard check: %d of %d cases wrong", bad, checked);
    if (!prohibited) {
        memset(buf, 0xA5, area + 2 * guard + 512);
        uint8_t *aligned = (uint8_t *)(((uintptr_t)buf + guard + block - 1) & ~(uintptr_t)(block - 1));
        __asm__ volatile("dc zva, %0" ::"r"(aligned) : "memory");
        size_t zeros = 0;
        for (size_t i = 0; i < block; i++) zeros += aligned[i] == 0;
        if (zeros != block || aligned[-1] != 0xA5 || aligned[block] != 0xA5)
            fail("DC ZVA zeroed %zu of %zu block bytes (before %#x after %#x)", zeros, block, aligned[-1], aligned[block]);
    }
    printf("zva: %d bzero/memset cases, %d wrong; DC ZVA %s\n", checked, bad, prohibited ? "not tried" : "checked");
    free(buf);
}

/* ---- main ---- */

static int run_child(const char *self, const char *name)
{
    pid_t pid;
    const char *extra[] = {name, NULL};
    int rc = probe_spawn(&pid, self, NULL, NULL, "insn", extra);
    if (rc != 0) return -1000 - rc;
    int st = 0;
    pid_t r = probe_wait(pid, &st, PROBE_TIMEOUT_MS);
    if (r != pid) return -2000;
    return st;
}

int main(int argc, char **argv)
{
    probe_name = "p_cpufeat";
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc >= 3 && strcmp(argv[1], "insn") == 0) {
        for (int i = 0; i < NINSNS; i++)
            if (strcmp(insns[i].name, argv[2]) == 0) { insns[i].fn(); return 0; }
        return 2;
    }
    const char *self = probe_self_path(argv[0]);
    int only_insn = argc >= 2 && strcmp(argv[1], "--insn-only") == 0;

    /* 1. sysctls and commpage. */
    uint8_t caps[16];
    memset(caps, 0xEE, sizeof caps);
    size_t clen = 0;
    if (sysctlbyname("hw.optional.arm.caps", NULL, &clen, NULL, 0) != 0) fail("caps size query: %s", strerror(errno));
    if (clen != 13) fail("caps size %zu, expected 13", clen);
    clen = sizeof caps;
    if (sysctlbyname("hw.optional.arm.caps", caps, &clen, NULL, 0) != 0) fail("caps read: %s", strerror(errno));
    printf("hw.optional.arm.caps (%zu bytes):", clen);
    for (size_t i = 0; i < 13; i++) printf(" %02x", caps[i]);
    printf("\n");
    uint8_t shortbuf[8];
    size_t slen = sizeof shortbuf;
    errno = 0;
    if (sysctlbyname("hw.optional.arm.caps", shortbuf, &slen, NULL, 0) == 0 || errno != ENOMEM)
        fail("caps into 8 bytes: expected ENOMEM, got errno %d", errno);
    else if (memcmp(shortbuf, caps, 8) != 0) fail("caps into 8 bytes: the first 8 bytes differ");

    static const char *ints[] = {"hw.ncpu", "hw.activecpu", "hw.logicalcpu", "hw.logicalcpu_max", "hw.physicalcpu",
        "hw.physicalcpu_max", "hw.perflevel0.logicalcpu", "hw.perflevel0.physicalcpu", "machdep.cpu.core_count",
        "machdep.cpu.thread_count", "machdep.cpu.cores_per_package", "machdep.cpu.logical_per_package", NULL};
    static const char *others[] = {"hw.cputype", "hw.cpusubtype", "hw.cpufamily", "hw.cpusubfamily", "hw.nperflevels",
        "hw.cachelinesize", "hw.l1icachesize", "hw.l1dcachesize", "hw.l2cachesize", "hw.perflevel0.l1icachesize",
        "hw.perflevel0.l1dcachesize", "hw.perflevel0.l2cachesize", "hw.perflevel0.cpusperl2", "hw.tbfrequency",
        "hw.pagesize", "hw.memsize", "machdep.virtual_address_size", "machdep.ptrauth_enabled", "kern.grade_cputype",
        "hw.optional.floatingpoint", "hw.optional.neon", "hw.optional.neon_hpfp", "hw.optional.neon_fp16",
        "hw.optional.armv8_crc32", "hw.optional.armv8_gpi", "hw.optional.armv8_1_atomics", "hw.optional.armv8_2_fhm",
        "hw.optional.armv8_2_sha512", "hw.optional.armv8_2_sha3", "hw.optional.armv8_3_compnum",
        "hw.optional.ucnormal_mem", "hw.optional.arm64", "hw.optional.watchpoint", "hw.optional.breakpoint",
        "hw.optional.arm.FEAT_FP8", "hw.optional.arm.sme_max_svl_b", NULL};
    for (int i = 0; others[i]; i++) {
        int ok = 0;
        long v = sys_int(others[i], &ok);
        if (ok) printf("%s = %ld\n", others[i], v); else printf("%s: errno %d\n", others[i], errno);
    }
    char brand[128] = "";
    size_t blen = sizeof brand;
    if (sysctlbyname("machdep.cpu.brand_string", brand, &blen, NULL, 0) != 0) fail("brand_string: %s", strerror(errno));
    char plname[64] = "";
    size_t plen = sizeof plname;
    sysctlbyname("hw.perflevel0.name", plname, &plen, NULL, 0);
    printf("machdep.cpu.brand_string = \"%s\"; hw.perflevel0.name = \"%s\"\n", brand, plname);
    if (strstr(brand, "Apple")) fail("brand string names Apple");

    volatile uint8_t *cp = (volatile uint8_t *)COMMPAGE_RW;
    uint64_t cap64 = *(volatile uint64_t *)(cp + 0x010);
    uint32_t cap32 = *(volatile uint32_t *)(cp + 0x020);
    uint8_t ncpus = cp[0x022];
    uint16_t cline = *(volatile uint16_t *)(cp + 0x026);
    uint32_t family = *(volatile uint32_t *)(cp + 0x080);
    printf("commpage: capabilities64 %#llx capabilities %#x ncpus %u cache line %u cpufamily %#x\n",
           (unsigned long long)cap64, cap32, ncpus, cline, family);

    /* 2. Invariants (§5). */
    for (int i = 0; i < NNAMES; i++) {
        char full[96];
        snprintf(full, sizeof full, "hw.optional.arm.%s", names[i].name);
        int ok = 0;
        long v = sys_int(full, &ok);
        if (!ok) v = 0;
        if (v != caps_bit(caps, names[i].bit)) fail("inv1: %s = %ld, caps bit %d = %d", full, v, names[i].bit, caps_bit(caps, names[i].bit));
    }
    for (int i = 0; i < NPAIRS; i++)
        if (!!(cap64 & pairs[i].mask) != caps_bit(caps, pairs[i].bit))
            fail("inv2: commpage mask %#llx vs caps bit %d", (unsigned long long)pairs[i].mask, pairs[i].bit);
    int crypto = caps_bit(caps, 10) && caps_bit(caps, 11) && caps_bit(caps, 9) && caps_bit(caps, 7);
    if (!!(cap64 & 0x01000000) != crypto) fail("inv2: kHasARMv8Crypto %d vs AES/PMULL/SHA1/SHA256 %d", !!(cap64 & 0x01000000), crypto);
    if ((uint32_t)cap64 != cap32) fail("inv2: capabilities %#x is not the low half of capabilities64", cap32);
    struct { const char *name; int bit; } legacy[] = {
        {"hw.optional.neon", 49}, {"hw.optional.neon_hpfp", 50}, {"hw.optional.neon_fp16", 34}, {"hw.optional.armv8_crc32", 51},
        {"hw.optional.armv8_gpi", 58}, {"hw.optional.armv8_1_atomics", 6}, {"hw.optional.armv8_2_fhm", 2},
        {"hw.optional.armv8_2_sha512", 8}, {"hw.optional.armv8_2_sha3", 4}, {"hw.optional.armv8_3_compnum", 17}};
    for (size_t i = 0; i < sizeof legacy / sizeof legacy[0]; i++) {
        long v = sys_int(legacy[i].name, NULL);
        if (v < 0) v = 0;
        if (v != caps_bit(caps, legacy[i].bit)) fail("inv3: %s = %ld, caps bit %d", legacy[i].name, v, legacy[i].bit);
    }
    long line = sys_int("hw.cachelinesize", NULL);
    uint64_t cbits = cap64 & 0x70;
    if (line != cline || !((line == 32 && cbits == 0x10) || (line == 64 && cbits == 0x20) || (line == 128 && cbits == 0x40)))
        fail("inv4: hw.cachelinesize %ld, commpage line %u, kCache bits %#llx", line, cline, (unsigned long long)cbits);
    long n = sys_int("hw.ncpu", NULL);
    if (ncpus != n || ((cap64 >> 16) & 0xFF) != (uint64_t)n || !!(cap64 & 0x8000) != (n == 1))
        fail("inv5: commpage CPUs %u / %llu, kUP %d, hw.ncpu %ld", ncpus, (unsigned long long)((cap64 >> 16) & 0xFF), !!(cap64 & 0x8000), n);
    for (int i = 0; ints[i]; i++) {
        long v = sys_int(ints[i], NULL);
        if (v != n) fail("inv5: %s = %ld, hw.ncpu %ld", ints[i], v, n);
    }
    for (int b = 0; b < 97; b++) if (caps_bit(caps, b) && denied(b)) fail("inv6: denied caps bit %d is set", b);
    for (int b = 0; b < 64; b++)
        if ((cap64 >> b) & 1)
            if (b == 29 || (b >= 35 && b <= 39) || b == 44 || b == 47 || b == 51 || b >= 59)
                fail("inv6: commpage bit %d is set", b);
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    long tbf = sys_int("hw.tbfrequency", NULL);
    if ((unsigned long long)tbf * tb.numer / tb.denom != 1000000000ull)
        fail("inv8: hw.tbfrequency %ld x %u / %u is not 10^9", tbf, tb.numer, tb.denom);
    printf("invariants 1-6, 8: %s\n", failures ? "see FAIL lines" : "ok");

    /* 3. Instructions. */
    int published_ok = 0, published_bad = 0, hidden_sigill = 0, hidden_exec = 0;
    for (int i = 0; i < NINSNS; i++) {
        int pub = insns[i].bit >= 0 && caps_bit(caps, insns[i].bit);
        int st = run_child(self, insns[i].name);
        const char *what;
        char buf[48];
        if (st < 0) { snprintf(buf, sizeof buf, "spawn/wait failed (%d)", st); what = buf; }
        else if (WIFEXITED(st) && WEXITSTATUS(st) == 0) what = "executed";
        else if (WIFEXITED(st) && WEXITSTATUS(st) == 3) what = "executed, read back differs";
        else if (WIFSIGNALED(st) && WTERMSIG(st) == SIGILL) what = "SIGILL";
        else { snprintf(buf, sizeof buf, "status %#x", st); what = buf; }
        int executed = st >= 0 && WIFEXITED(st) && WEXITSTATUS(st) == 0;
        int sigill = st >= 0 && WIFSIGNALED(st) && WTERMSIG(st) == SIGILL;
        const char *verdict;
        if (pub) {
            if (executed) { verdict = "ok"; published_ok++; }
            else { verdict = "FAIL (published)"; published_bad++; fail("published %s: %s", insns[i].name, what); }
        } else if (sigill) { verdict = "ok (hidden)"; hidden_sigill++; }
        else if (executed || (st >= 0 && WIFEXITED(st) && WEXITSTATUS(st) == 3)) { verdict = "hidden, executes"; hidden_exec++; }
        else { verdict = "FAIL (not a clean SIGILL)"; fail("hidden %s: %s", insns[i].name, what); }
        printf("insn %-24s published %d: %-28s %s\n", insns[i].name, pub, what, verdict);
    }
    printf("instructions: %d published executed, %d published failed, %d hidden SIGILL, %d hidden but executable\n",
           published_ok, published_bad, hidden_sigill, hidden_exec);

    if (!only_insn) {
        /* 4. State. */
        state_round_trip(caps_bit(caps, 29), caps_bit(caps, 33), caps_bit(caps, 35));
        /* 5. ZVA. */
        zva_safety(line);
    }

    if (failures) printf("cpufeat FAIL %d\n", failures);
    else printf("cpufeat ok caps %02x %02x %02x %02x %02x %02x %02x commpage %#llx\n", caps[0], caps[1], caps[2], caps[3],
                caps[4], caps[5], caps[6], (unsigned long long)cap64);
    return failures ? 1 : 0;
}
