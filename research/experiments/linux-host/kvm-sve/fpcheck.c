// fpcheck: does the host kernel preserve a KVM vCPU thread's user-mode
// register state? Each thread creates a tiny arm64 guest that loops on an
// MMIO store (one KVM exit per store) and issues KVM_RUN with an inline
// `svc`, so the compiler cannot keep anything live across the call. Run with
// more threads than CPUs so that threads are preempted. This is the
// reproducer for docs/postmortem-kvm-sve.md (Ycode's own code).
//
// Build: cc -O2 -march=armv8.2-a+sve -o fpcheck fpcheck.c -lpthread
//        (add hostcopy.c from ycode/Sources/CKVM and -ldl to test that
//        memcpy/memmove; build with clang, which honours no_builtin)
// Run:   ./fpcheck <threads> <seconds> <kvm|nokvm> <kick|nokick> [mode] [args]
//   kvm/nokvm    KVM_RUN, or sched_yield as the control system call
//   kick         a helper thread sends SIGUSR2 to random workers every 50 us
//   modes (default: v0..v31 across KVM_RUN):
//     spin       v0..v31 across a busy loop (preemption only)
//     pred       p0..p15 across KVM_RUN (even threads) or a spin (odd)
//     gpr        x9..x28 across a spin
//     kvmpred    KVM_RUN, then set p0..p15, spin, store, compare
//                (the bug: set GUEST_NOFP=1)
//     allregs    x1..x30, SP and NZCV across a raw KVM_RUN
//     allspin    the same across a page fault and a spin
//     longguest  guest runs a long FP loop; then v and p across a host spin
//                (args: guest loop count / 65536, host spin iterations)
//     memcpy     after KVM_RUN, 400 glibc memcpy/memmove calls of 17..96
//                bytes, each checked (the bug: GUEST_NOFP=1)
//     bare       KVM_RUN only (cost measurements; pin with taskset)
//   environment:
//     GUEST_NOFP=1  the guest never touches FP/SIMD (triggers the kernel bug)
//     GUEST_FPCR=1  the guest reads FPCR once per run (the shim mitigation)
// The summary line counts runs with any changed register (or lost copy).
#include <errno.h>
#include <signal.h>
#include <stddef.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static int seconds = 10, noKVM = 0, spinMode = 0, predMode = 0, gprMode = 0, kvmPredMode = 0, allRegsMode = 0, allSpinMode = 0, longGuestMode = 0;
static int guestNoFP = 0, memcpyMode = 0, bareMode = 0;
static void *(*volatile memcpyVia)(void *, const void *, size_t) = memcpy;
static void *(*volatile memmoveVia)(void *, const void *, size_t) = memmove;
static uint32_t guestLoopInsn = 0xd2a00204; static long hostSpin = 200000;
static volatile int stop;
static unsigned long totalRuns, totalBad;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

#define CORE(field) (KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | (offsetof(struct kvm_regs, field) / sizeof(uint32_t)))

static void setReg(int fd, uint64_t id, uint64_t v) {
    struct kvm_one_reg r = { .id = id, .addr = (uint64_t)&v };
    if (ioctl(fd, KVM_SET_ONE_REG, &r) < 0) { perror("KVM_SET_ONE_REG"); exit(1); }
}

// KVM_RUN through a raw svc: x8 = __NR_ioctl, x0..x2 = fd, request, 0.
static long rawRun(int fd) {
    register long x0 asm("x0") = fd;
    register long x1 asm("x1") = KVM_RUN;
    register long x2 asm("x2") = 0;
    register long x8 asm("x8") = __NR_ioctl;
    asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
    return x0;
}

static void *worker(void *arg) {
    long id = (long)arg;
    int vm = -1, vcpu = -1;
    struct kvm_run *run = NULL;
    if (!noKVM) {
        int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
        vm = ioctl(kvm, KVM_CREATE_VM, 0);
        if (vm < 0) { perror("KVM_CREATE_VM"); exit(1); }
        size_t memSize = 0x10000;
        uint32_t *mem = mmap(NULL, memSize, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
        // loop: fill d0..d31 and v0..v31.d[1] from x3 (guest FP use), then
        // str x1, [x2] (MMIO exit), x3 += 1; b loop
        int k = 0;
        if (longGuestMode) mem[k++] = guestLoopInsn;                // movz x4, #N, lsl #16
        if (!guestNoFP) {
            for (int i = 0; i < 32; i++) mem[k++] = 0x9e670060 + i;   // fmov d<i>, x3
            for (int i = 0; i < 32; i++) mem[k++] = 0x9eaf0060 + i;   // fmov v<i>.d[1], x3
        }
        if (longGuestMode) {
            mem[k++] = 0x9e670061;                                // 1: fmov d1, x3
            mem[k++] = 0x1e612820;                                // fadd d0, d1, d1
            mem[k++] = 0xf1000484;                                // subs x4, x4, #1
            mem[k++] = 0x54ffffa1;                                // b.ne 1b
        }
        if (getenv("GUEST_FPCR")) mem[k++] = 0xd53b4405;          // mrs x5, fpcr (FP access, no FP register written)
        mem[k++] = 0xf9000041;                                    // str x1, [x2]
        mem[k++] = 0x91000463;                                    // add x3, x3, #1
        mem[k] = 0x14000000 | ((uint32_t)(-k) & 0x03ffffff);      // b loop
        k++;
        struct kvm_userspace_memory_region region = { .slot = 0, .guest_phys_addr = 0x80000000, .memory_size = memSize, .userspace_addr = (uint64_t)mem };
        if (ioctl(vm, KVM_SET_USER_MEMORY_REGION, &region) < 0) { perror("KVM_SET_USER_MEMORY_REGION"); exit(1); }
        vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
        struct kvm_vcpu_init init;
        ioctl(vm, KVM_ARM_PREFERRED_TARGET, &init);
        if (ioctl(vcpu, KVM_ARM_VCPU_INIT, &init) < 0) { perror("KVM_ARM_VCPU_INIT"); exit(1); }
        int runSize = ioctl(kvm, KVM_GET_VCPU_MMAP_SIZE, 0);
        run = mmap(NULL, runSize, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu, 0);
        setReg(vcpu, CORE(regs.pc), 0x80000000);
        setReg(vcpu, CORE(regs.regs[2]), 0x10000000); // unmapped: MMIO exit
        setReg(vcpu, CORE(regs.pstate), 0x3c5);         // EL1h, interrupts masked
        setReg(vcpu, CORE(regs.regs[3]), 0x6775657374000000ull + (uint64_t)id); // "guest" pattern
        // CPACR_EL1.FPEN = 0b11: the guest may use FP/SIMD.
        setReg(vcpu, KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM64_SYSREG | (3ull << 14) | (0ull << 11) | (1ull << 7) | (0ull << 3) | 2ull, 0x300000);
    }
    unsigned long runs = 0, bad = 0;
    char *faultPage = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    uint64_t seed = 0x9E3779B97F4A7C15ull * (uint64_t)(id + 1);
    while (!stop) {
        uint64_t pattern[64], after[64];
        for (int i = 0; i < 64; i++) { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; pattern[i] = seed; }
        long r;
        if (bareMode) {
            register long x0 asm("x0") = vcpu; register long x1 asm("x1") = KVM_RUN; register long x2 asm("x2") = 0; register long x8 asm("x8") = __NR_ioctl;
            asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
            runs++;
            continue;
        }
        if (memcpyMode) {
            if (!noKVM) {
                register long x0 asm("x0") = vcpu; register long x1 asm("x1") = KVM_RUN; register long x2 asm("x2") = 0; register long x8 asm("x8") = __NR_ioctl;
                asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
            }
            // glibc memcpy/memmove of 17..96 bytes, many times, each checked.
            unsigned char src[128], dst[128];
            for (int rep = 0; rep < 400; rep++) {
                size_t n = 17 + (pattern[rep & 63] % 80);
                for (size_t b = 0; b < n; b++) src[b] = (unsigned char)(pattern[(b + rep) & 63] >> ((b & 7) * 8));
                memset(dst, 0xEE, sizeof dst);
                (rep & 1 ? memmoveVia : memcpyVia)(dst, src, n);
                runs++;
                if (memcmp(dst, src, n) != 0) {
                    bad++;
                    size_t b = 0;
                    while (dst[b] == src[b]) b++;
                    if (bad <= 10) fprintf(stderr, "memcpy thread %ld: %s of %zu bytes: byte %zu is %02x, expected %02x\n", id,
                                           rep & 1 ? "memmove" : "memcpy", n, b, dst[b], src[b]);
                    break;
                }
            }
            continue;
        }
        if (longGuestMode) {
            if (!noKVM) {
                register long x0 asm("x0") = vcpu; register long x1 asm("x1") = KVM_RUN; register long x2 asm("x2") = 0; register long x8 asm("x8") = __NR_ioctl;
                asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
            }
            uint64_t n[16];
            uint16_t gotp[16], wantp[16];
            for (int i = 0; i < 16; i++) { n[i] = pattern[i] % 17; wantp[i] = (uint16_t)((1u << n[i]) - 1); }
            uint64_t gotv[64];
#define W3(i) "whilelo p" #i ".b, xzr, %[n" #i "]\n"
#define S3(i) "str p" #i ", [%[g], #" #i ", mul vl]\n"
            asm volatile(
                "ldp q0, q1, [%[v], #0]\n ldp q2, q3, [%[v], #32]\n ldp q4, q5, [%[v], #64]\n ldp q6, q7, [%[v], #96]\n"
                "ldp q8, q9, [%[v], #128]\n ldp q10, q11, [%[v], #160]\n ldp q12, q13, [%[v], #192]\n ldp q14, q15, [%[v], #224]\n"
                "ldp q16, q17, [%[v], #256]\n ldp q18, q19, [%[v], #288]\n ldp q20, q21, [%[v], #320]\n ldp q22, q23, [%[v], #352]\n"
                "ldp q24, q25, [%[v], #384]\n ldp q26, q27, [%[v], #416]\n ldp q28, q29, [%[v], #448]\n ldp q30, q31, [%[v], #480]\n"
                W3(0) W3(1) W3(2) W3(3) W3(4) W3(5) W3(6) W3(7) W3(8) W3(9) W3(10) W3(11) W3(12) W3(13) W3(14) W3(15)
                "mov x9, %[loops]\n 3: subs x9, x9, #1\n b.ne 3b\n"
                S3(0) S3(1) S3(2) S3(3) S3(4) S3(5) S3(6) S3(7) S3(8) S3(9) S3(10) S3(11) S3(12) S3(13) S3(14) S3(15)
                "stp q0, q1, [%[o], #0]\n stp q2, q3, [%[o], #32]\n stp q4, q5, [%[o], #64]\n stp q6, q7, [%[o], #96]\n"
                "stp q8, q9, [%[o], #128]\n stp q10, q11, [%[o], #160]\n stp q12, q13, [%[o], #192]\n stp q14, q15, [%[o], #224]\n"
                "stp q16, q17, [%[o], #256]\n stp q18, q19, [%[o], #288]\n stp q20, q21, [%[o], #320]\n stp q22, q23, [%[o], #352]\n"
                "stp q24, q25, [%[o], #384]\n stp q26, q27, [%[o], #416]\n stp q28, q29, [%[o], #448]\n stp q30, q31, [%[o], #480]\n"
                : : [n0] "r"(n[0]), [n1] "r"(n[1]), [n2] "r"(n[2]), [n3] "r"(n[3]), [n4] "r"(n[4]), [n5] "r"(n[5]),
                  [n6] "r"(n[6]), [n7] "r"(n[7]), [n8] "r"(n[8]), [n9] "r"(n[9]), [n10] "r"(n[10]), [n11] "r"(n[11]),
                  [n12] "r"(n[12]), [n13] "r"(n[13]), [n14] "r"(n[14]), [n15] "r"(n[15]),
                  [g] "r"(gotp), [v] "r"(pattern), [o] "r"(gotv), [loops] "r"(hostSpin)
                : "x9", "memory", "cc",
                  "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15",
                  "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23", "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31",
                  "p0", "p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9", "p10", "p11", "p12", "p13", "p14", "p15");
            runs++;
            int wrongV = -1, wrongP = -1;
            for (int i = 0; i < 64; i++) if (gotv[i] != pattern[i]) { wrongV = i; break; }
            for (int i = 0; i < 16; i++) if (gotp[i] != wantp[i]) { wrongP = i; break; }
            if (wrongV >= 0 || wrongP >= 0) {
                bad++;
                if (bad <= 10) {
                    if (wrongV >= 0) fprintf(stderr, "longguest thread %ld iter %lu: v%d.d[%d] expected %016llx got %016llx\n", id, runs, wrongV / 2, wrongV % 2,
                                             (unsigned long long)pattern[wrongV], (unsigned long long)gotv[wrongV]);
                    if (wrongP >= 0) fprintf(stderr, "longguest thread %ld iter %lu: p%d expected %04x got %04x\n", id, runs, wrongP, wantp[wrongP], gotp[wrongP]);
                }
            }
            continue;
        }
        if (allSpinMode) {
            // x1..x30 (x0 = fd), NZCV and SP across a raw KVM_RUN.
            uint64_t rb[80];
            memset(rb, 0, sizeof rb);
            for (int i = 0; i < 31; i++) rb[i] = pattern[i];
            rb[0] = (uint64_t)vcpu; rb[1] = KVM_RUN; rb[2] = 0; rb[8] = __NR_ioctl;
            rb[70] = 0x60000000; rb[71] = 20000; madvise(faultPage, 4096, MADV_DONTNEED); rb[72] = (uint64_t)(uintptr_t)faultPage;
            register uint64_t *base asm("x28") = rb;
            asm volatile(
                "str x29, [x28, #512]\n str x30, [x28, #520]\n"
                "mov x9, sp\n str x9, [x28, #528]\n"
                "ldr x0, [x28, #560]\n msr nzcv, x0\n"
                "ldp x3, x4, [x28, #24]\n ldp x5, x6, [x28, #40]\n ldr x7, [x28, #56]\n ldr x8, [x28, #64]\n"
                "ldp x9, x10, [x28, #72]\n ldp x11, x12, [x28, #88]\n ldp x13, x14, [x28, #104]\n ldp x15, x16, [x28, #120]\n ldp x17, x18, [x28, #136]\n"
                "ldp x19, x20, [x28, #152]\n ldp x21, x22, [x28, #168]\n ldp x23, x24, [x28, #184]\n ldp x25, x26, [x28, #200]\n"
                "mov x27, x28\n"
                "ldp x29, x30, [x28, #232]\n"
                "ldp x0, x1, [x28, #0]\n ldr x2, [x28, #16]\n"
                "ldr x0, [x28, #576]\n ldr w0, [x0]\n"
                "ldr x0, [x28, #568]\n 7: subs x0, x0, #1\n b.ne 7b\n"
                "ldr x0, [x28, #0]\n"
                "stp x0, x1, [x28, #256]\n"
                "mrs x0, nzcv\n str x0, [x28, #544]\n"
                "mov x0, sp\n str x0, [x28, #552]\n"
                "stp x2, x3, [x28, #272]\n stp x4, x5, [x28, #288]\n stp x6, x7, [x28, #304]\n stp x8, x9, [x28, #320]\n"
                "stp x10, x11, [x28, #336]\n stp x12, x13, [x28, #352]\n stp x14, x15, [x28, #368]\n stp x16, x17, [x28, #384]\n"
                "stp x18, x19, [x28, #400]\n stp x20, x21, [x28, #416]\n stp x22, x23, [x28, #432]\n stp x24, x25, [x28, #448]\n"
                "str x26, [x28, #464]\n stp x27, x28, [x28, #472]\n stp x29, x30, [x28, #488]\n"
                "ldr x29, [x28, #512]\n ldr x30, [x28, #520]\n"
                : : [rb] "r"(base)
                : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17",
                  "x18", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x30", "memory", "cc");
            runs++;
            int wrong = -1;
            for (int i = 1; i < 31; i++) {
                uint64_t want = (i == 27 || i == 28) ? (uint64_t)(uintptr_t)rb : rb[i];
                if (rb[32 + i] != want) { wrong = i; break; }
            }
            if (wrong < 0 && rb[68] != 0x60000000) wrong = 100;
            if (wrong < 0 && rb[69] != rb[66]) wrong = 101;
            if (wrong >= 0) {
                bad++;
                if (bad <= 8) fprintf(stderr, "allspin thread %ld iter %lu: %s%d before %016llx after %016llx (result %lld)\n", id, runs,
                                      wrong == 100 ? "nzcv" : wrong == 101 ? "sp" : "x", wrong,
                                      (unsigned long long)(wrong == 100 ? 0x60000000 : wrong == 101 ? rb[66] : (wrong >= 27 && wrong <= 28) ? (uint64_t)(uintptr_t)rb : rb[wrong]),
                                      (unsigned long long)(wrong == 100 ? rb[68] : wrong == 101 ? rb[69] : rb[32 + wrong]), (long long)rb[32]);
            }
            continue;
        }
        if (allRegsMode) {
            // x1..x30 (x0 = fd), NZCV and SP across a raw KVM_RUN.
            uint64_t rb[80];
            memset(rb, 0, sizeof rb);
            for (int i = 0; i < 31; i++) rb[i] = pattern[i];
            rb[0] = (uint64_t)vcpu; rb[1] = KVM_RUN; rb[2] = 0; rb[8] = __NR_ioctl;
            rb[70] = 0x60000000;
            register uint64_t *base asm("x28") = rb;
            asm volatile(
                "str x29, [x28, #512]\n str x30, [x28, #520]\n"
                "mov x9, sp\n str x9, [x28, #528]\n"
                "ldr x0, [x28, #560]\n msr nzcv, x0\n"
                "ldp x3, x4, [x28, #24]\n ldp x5, x6, [x28, #40]\n ldr x7, [x28, #56]\n ldr x8, [x28, #64]\n"
                "ldp x9, x10, [x28, #72]\n ldp x11, x12, [x28, #88]\n ldp x13, x14, [x28, #104]\n ldp x15, x16, [x28, #120]\n ldp x17, x18, [x28, #136]\n"
                "ldp x19, x20, [x28, #152]\n ldp x21, x22, [x28, #168]\n ldp x23, x24, [x28, #184]\n ldp x25, x26, [x28, #200]\n"
                "mov x27, x28\n"
                "ldp x29, x30, [x28, #232]\n"
                "ldp x0, x1, [x28, #0]\n ldr x2, [x28, #16]\n"
                "svc #0\n"
                "stp x0, x1, [x28, #256]\n"
                "mrs x0, nzcv\n str x0, [x28, #544]\n"
                "mov x0, sp\n str x0, [x28, #552]\n"
                "stp x2, x3, [x28, #272]\n stp x4, x5, [x28, #288]\n stp x6, x7, [x28, #304]\n stp x8, x9, [x28, #320]\n"
                "stp x10, x11, [x28, #336]\n stp x12, x13, [x28, #352]\n stp x14, x15, [x28, #368]\n stp x16, x17, [x28, #384]\n"
                "stp x18, x19, [x28, #400]\n stp x20, x21, [x28, #416]\n stp x22, x23, [x28, #432]\n stp x24, x25, [x28, #448]\n"
                "str x26, [x28, #464]\n stp x27, x28, [x28, #472]\n stp x29, x30, [x28, #488]\n"
                "ldr x29, [x28, #512]\n ldr x30, [x28, #520]\n"
                : : [rb] "r"(base)
                : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17",
                  "x18", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x30", "memory", "cc");
            runs++;
            int wrong = -1;
            for (int i = 1; i < 31; i++) {
                uint64_t want = (i == 27 || i == 28) ? (uint64_t)(uintptr_t)rb : rb[i];
                if (rb[32 + i] != want) { wrong = i; break; }
            }
            if (wrong < 0 && rb[68] != 0x60000000) wrong = 100;
            if (wrong < 0 && rb[69] != rb[66]) wrong = 101;
            if (wrong >= 0) {
                bad++;
                if (bad <= 8) fprintf(stderr, "allregs thread %ld iter %lu: %s%d before %016llx after %016llx (result %lld)\n", id, runs,
                                      wrong == 100 ? "nzcv" : wrong == 101 ? "sp" : "x", wrong,
                                      (unsigned long long)(wrong == 100 ? 0x60000000 : wrong == 101 ? rb[66] : (wrong >= 27 && wrong <= 28) ? (uint64_t)(uintptr_t)rb : rb[wrong]),
                                      (unsigned long long)(wrong == 100 ? rb[68] : wrong == 101 ? rb[69] : rb[32 + wrong]), (long long)rb[32]);
            }
            continue;
        }
        if (kvmPredMode) {
            uint64_t n[16];
            uint16_t got[16], want[16];
            for (int i = 0; i < 16; i++) { n[i] = pattern[i] % 17; want[i] = (uint16_t)((1u << n[i]) - 1); }
            if (!noKVM) {
                register long x0 asm("x0") = vcpu; register long x1 asm("x1") = KVM_RUN; register long x2 asm("x2") = 0; register long x8 asm("x8") = __NR_ioctl;
                asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
            }
#define W2(i) "whilelo p" #i ".b, xzr, %[n" #i "]\n"
#define S2(i) "str p" #i ", [%[g], #" #i ", mul vl]\n"
            asm volatile(
                W2(0) W2(1) W2(2) W2(3) W2(4) W2(5) W2(6) W2(7) W2(8) W2(9) W2(10) W2(11) W2(12) W2(13) W2(14) W2(15)
                "mov x9, %[loops]\n 3: subs x9, x9, #1\n b.ne 3b\n"
                S2(0) S2(1) S2(2) S2(3) S2(4) S2(5) S2(6) S2(7) S2(8) S2(9) S2(10) S2(11) S2(12) S2(13) S2(14) S2(15)
                : : [n0] "r"(n[0]), [n1] "r"(n[1]), [n2] "r"(n[2]), [n3] "r"(n[3]), [n4] "r"(n[4]), [n5] "r"(n[5]),
                  [n6] "r"(n[6]), [n7] "r"(n[7]), [n8] "r"(n[8]), [n9] "r"(n[9]), [n10] "r"(n[10]), [n11] "r"(n[11]),
                  [n12] "r"(n[12]), [n13] "r"(n[13]), [n14] "r"(n[14]), [n15] "r"(n[15]),
                  [g] "r"(got), [loops] "r"(20000L)
                : "x9", "memory", "cc",
                  "p0", "p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9", "p10", "p11", "p12", "p13", "p14", "p15");
            runs++;
            for (int i = 0; i < 16; i++) if (got[i] != want[i]) {
                bad++;
                if (bad <= 8) fprintf(stderr, "thread %ld iter %lu: p%d expected %04x got %04x\n", id, runs, i, want[i], got[i]);
                break;
            }
            continue;
        }
        if (gprMode && (id & 1)) {
            // x10..x28 hold a pattern across a busy loop (preemption only).
            uint64_t gotg[19];
            asm volatile(
                "ldp x10, x11, [%[p], #0]\n ldp x12, x13, [%[p], #16]\n ldp x14, x15, [%[p], #32]\n ldp x16, x17, [%[p], #48]\n"
                "ldp x19, x20, [%[p], #64]\n ldp x21, x22, [%[p], #80]\n ldp x23, x24, [%[p], #96]\n ldp x25, x26, [%[p], #112]\n"
                "ldp x27, x28, [%[p], #128]\n ldr x9, [%[p], #144]\n"
                "mov x0, %[loops]\n 3: subs x0, x0, #1\n b.ne 3b\n"
                "stp x10, x11, [%[a], #0]\n stp x12, x13, [%[a], #16]\n stp x14, x15, [%[a], #32]\n stp x16, x17, [%[a], #48]\n"
                "stp x19, x20, [%[a], #64]\n stp x21, x22, [%[a], #80]\n stp x23, x24, [%[a], #96]\n stp x25, x26, [%[a], #112]\n"
                "stp x27, x28, [%[a], #128]\n str x9, [%[a], #144]\n"
                : : [p] "r"(pattern), [a] "r"(gotg), [loops] "r"(200000L)
                : "x0", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x19", "x20", "x21", "x22", "x23", "x24",
                  "x25", "x26", "x27", "x28", "memory", "cc");
            runs++;
            if (memcmp(pattern, gotg, sizeof gotg) != 0) {
                bad++;
                if (bad <= 5) for (int i = 0; i < 19; i++) if (pattern[i] != gotg[i]) {
                    fprintf(stderr, "gpr thread %ld iter %lu: word %d expected %016llx got %016llx\n", id, runs, i,
                            (unsigned long long)pattern[i], (unsigned long long)gotg[i]);
                    break;
                }
            }
            continue;
        }
        if (predMode) {
            // p0..p15 = whilelo(0, n_i) on bytes; spin (odd threads) or KVM_RUN
            // (even threads); store them back and compare.
            uint64_t n[16];
            uint16_t got[16], want[16];
            for (int i = 0; i < 16; i++) { n[i] = pattern[i] % 17; want[i] = (uint16_t)((1u << n[i]) - 1); }
            long rr;
#define W(i) "whilelo p" #i ".b, xzr, %[n" #i "]\n"
#define S(i) "str p" #i ", [%[g], #" #i ", mul vl]\n"
            asm volatile(
                W(0) W(1) W(2) W(3) W(4) W(5) W(6) W(7) W(8) W(9) W(10) W(11) W(12) W(13) W(14) W(15)
                "cbz %[spin], 1f\n mov x9, %[loops]\n 3: subs x9, x9, #1\n b.ne 3b\n b 2f\n"
                "1: mov x0, %[fd]\n mov x1, %[req]\n mov x2, #0\n mov x8, %[nr]\n svc #0\n"
                "2:\n"
                S(0) S(1) S(2) S(3) S(4) S(5) S(6) S(7) S(8) S(9) S(10) S(11) S(12) S(13) S(14) S(15)
                "mov %[r], x0\n"
                : [r] "=r"(rr)
                : [n0] "r"(n[0]), [n1] "r"(n[1]), [n2] "r"(n[2]), [n3] "r"(n[3]), [n4] "r"(n[4]), [n5] "r"(n[5]),
                  [n6] "r"(n[6]), [n7] "r"(n[7]), [n8] "r"(n[8]), [n9] "r"(n[9]), [n10] "r"(n[10]), [n11] "r"(n[11]),
                  [n12] "r"(n[12]), [n13] "r"(n[13]), [n14] "r"(n[14]), [n15] "r"(n[15]),
                  [g] "r"(got), [loops] "r"(200000L), [spin] "r"((long)(id & 1)), [fd] "r"((long)vcpu), [req] "r"((long)KVM_RUN), [nr] "r"((long)__NR_ioctl)
                : "x0", "x1", "x2", "x8", "x9", "memory", "cc",
                  "p0", "p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9", "p10", "p11", "p12", "p13", "p14", "p15");
            (void)rr;
            runs++;
            // Across a syscall the ABI lets the kernel zero P registers; check spin threads strictly,
            // and syscall threads only for values other than the original or zero.
            for (int i = 0; i < 16; i++) {
                int okv = got[i] == want[i] || (!(id & 1) && got[i] == 0);
                if (!okv) {
                    bad++;
                    if (bad <= 5) fprintf(stderr, "%s thread %ld iter %lu: p%d expected %04x got %04x\n", (id & 1) ? "spin" : "kvm", id, runs, i, want[i], got[i]);
                    break;
                }
            }
            continue;
        }
        if (spinMode && (id & 1)) {
            asm volatile(
                "ldp q0, q1, [%[p], #0]\n ldp q2, q3, [%[p], #32]\n ldp q4, q5, [%[p], #64]\n ldp q6, q7, [%[p], #96]\n"
                "ldp q8, q9, [%[p], #128]\n ldp q10, q11, [%[p], #160]\n ldp q12, q13, [%[p], #192]\n ldp q14, q15, [%[p], #224]\n"
                "ldp q16, q17, [%[p], #256]\n ldp q18, q19, [%[p], #288]\n ldp q20, q21, [%[p], #320]\n ldp q22, q23, [%[p], #352]\n"
                "ldp q24, q25, [%[p], #384]\n ldp q26, q27, [%[p], #416]\n ldp q28, q29, [%[p], #448]\n ldp q30, q31, [%[p], #480]\n"
                "mov x9, %[loops]\n 3: subs x9, x9, #1\n b.ne 3b\n"
                "stp q0, q1, [%[a], #0]\n stp q2, q3, [%[a], #32]\n stp q4, q5, [%[a], #64]\n stp q6, q7, [%[a], #96]\n"
                "stp q8, q9, [%[a], #128]\n stp q10, q11, [%[a], #160]\n stp q12, q13, [%[a], #192]\n stp q14, q15, [%[a], #224]\n"
                "stp q16, q17, [%[a], #256]\n stp q18, q19, [%[a], #288]\n stp q20, q21, [%[a], #320]\n stp q22, q23, [%[a], #352]\n"
                "stp q24, q25, [%[a], #384]\n stp q26, q27, [%[a], #416]\n stp q28, q29, [%[a], #448]\n stp q30, q31, [%[a], #480]\n"
                : : [p] "r"(pattern), [a] "r"(after), [loops] "r"(200000L)
                : "x9", "memory", "cc",
                  "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15",
                  "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23", "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31");
            runs++;
            if (memcmp(pattern, after, sizeof pattern) != 0) {
                bad++;
                if (bad <= 5) for (int i = 0; i < 64; i++) if (pattern[i] != after[i]) {
                    fprintf(stderr, "spin thread %ld iter %lu: v%d.d[%d] expected %016llx got %016llx\n", id, runs, i / 2, i % 2,
                            (unsigned long long)pattern[i], (unsigned long long)after[i]);
                    break;
                }
            }
            continue;
        }
        asm volatile(
            "ldp q0, q1, [%[p], #0]\n ldp q2, q3, [%[p], #32]\n ldp q4, q5, [%[p], #64]\n ldp q6, q7, [%[p], #96]\n"
            "ldp q8, q9, [%[p], #128]\n ldp q10, q11, [%[p], #160]\n ldp q12, q13, [%[p], #192]\n ldp q14, q15, [%[p], #224]\n"
            "ldp q16, q17, [%[p], #256]\n ldp q18, q19, [%[p], #288]\n ldp q20, q21, [%[p], #320]\n ldp q22, q23, [%[p], #352]\n"
            "ldp q24, q25, [%[p], #384]\n ldp q26, q27, [%[p], #416]\n ldp q28, q29, [%[p], #448]\n ldp q30, q31, [%[p], #480]\n"
            "mov x0, %[fd]\n mov x1, %[req]\n mov x2, #0\n mov x8, %[nr]\n"
            "cbz %[kvm], 1f\n svc #0\n b 2f\n"
            "1: mov x0, #0\n mov x8, %[yield]\n svc #0\n"   // control: sched_yield
            "2: mov %[r], x0\n"
            "stp q0, q1, [%[a], #0]\n stp q2, q3, [%[a], #32]\n stp q4, q5, [%[a], #64]\n stp q6, q7, [%[a], #96]\n"
            "stp q8, q9, [%[a], #128]\n stp q10, q11, [%[a], #160]\n stp q12, q13, [%[a], #192]\n stp q14, q15, [%[a], #224]\n"
            "stp q16, q17, [%[a], #256]\n stp q18, q19, [%[a], #288]\n stp q20, q21, [%[a], #320]\n stp q22, q23, [%[a], #352]\n"
            "stp q24, q25, [%[a], #384]\n stp q26, q27, [%[a], #416]\n stp q28, q29, [%[a], #448]\n stp q30, q31, [%[a], #480]\n"
            : [r] "=r"(r)
            : [p] "r"(pattern), [a] "r"(after), [fd] "r"((long)vcpu), [req] "r"((long)KVM_RUN), [nr] "r"((long)__NR_ioctl),
              [yield] "r"((long)__NR_sched_yield), [kvm] "r"((long)!noKVM)
            : "x0", "x1", "x2", "x8", "memory",
              "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15",
              "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23", "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31");
        (void)r;
        runs++;
        if (memcmp(pattern, after, sizeof pattern) != 0) {
            bad++;
            if (bad <= 3) {
                for (int i = 0; i < 64; i++) if (pattern[i] != after[i]) {
                    fprintf(stderr, "thread %ld run %lu: v%d.d[%d] expected %016llx got %016llx\n", id, runs, i / 2, i % 2,
                            (unsigned long long)pattern[i], (unsigned long long)after[i]);
                    break;
                }
            }
        }
    }
    pthread_mutex_lock(&lock);
    totalRuns += runs;
    totalBad += bad;
    pthread_mutex_unlock(&lock);
    return NULL;
}

static pthread_t threadsAll[512];
static int threadCount;
static int kick;
static void onKick(int sig) { (void)sig; }
static void *kicker(void *arg) {
    (void)arg;
    unsigned seed = 1;
    sleep(2);
    while (!stop) {
        usleep(50);
        pthread_kill(threadsAll[rand_r(&seed) % threadCount], SIGUSR2);
    }
    return NULL;
}

int main(int argc, char **argv) {
    int threads = argc > 1 ? atoi(argv[1]) : 32;
    seconds = argc > 2 ? atoi(argv[2]) : 10;
    noKVM = argc > 3 && strcmp(argv[3], "nokvm") == 0;
    kick = argc > 4 && strcmp(argv[4], "kick") == 0;
    spinMode = argc > 5 && strcmp(argv[5], "spin") == 0;
    predMode = argc > 5 && strcmp(argv[5], "pred") == 0;
    gprMode = argc > 5 && strcmp(argv[5], "gpr") == 0;
    kvmPredMode = argc > 5 && strcmp(argv[5], "kvmpred") == 0;
    guestNoFP = getenv("GUEST_NOFP") != NULL;
    memcpyMode = argc > 5 && strcmp(argv[5], "memcpy") == 0;
    bareMode = argc > 5 && strcmp(argv[5], "bare") == 0;
    allRegsMode = argc > 5 && strcmp(argv[5], "allregs") == 0;
    allSpinMode = argc > 5 && strcmp(argv[5], "allspin") == 0;
    longGuestMode = argc > 5 && strcmp(argv[5], "longguest") == 0;
    if (argc > 6) guestLoopInsn = 0xd2a00004u | ((uint32_t)atoi(argv[6]) << 5); // movz x4, #arg, lsl #16
    if (argc > 7) hostSpin = atol(argv[7]);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = onKick;
    sigaction(SIGUSR2, &sa, NULL);
    pthread_t *t = threadsAll;
    threadCount = threads;
    for (long i = 0; i < threads; i++) pthread_create(&t[i], NULL, worker, (void *)i);
    pthread_t k;
    if (kick) pthread_create(&k, NULL, kicker, NULL);
    sleep(seconds);
    stop = 1;
    for (int i = 0; i < threads; i++) pthread_join(t[i], NULL);
    if (kick) pthread_join(k, NULL);
    printf("%s: %d threads, %lu runs, %lu with changed FP/SIMD registers\n", noKVM ? "sched_yield" : "KVM_RUN", threads, totalRuns, totalBad);
    return 0;
}
