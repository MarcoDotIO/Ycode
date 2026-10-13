// memcpy and memmove for the ycode-simd process on arm64 Linux, written
// without SVE instructions.
//
// Why: on hosts whose kernel keeps a KVM vCPU thread's SVE access enabled
// after KVM_RUN while recording its state as FPSIMD-only (the vCPU did not
// use FP/SIMD during that run), the thread's SVE predicate registers are
// lost at its next context switch. glibc's SVE memcpy/memmove (selected by
// IFUNC on SVE hosts) then store nothing, or only part, of a copy: lost
// writes on vCPU host threads. Plain AdvSIMD/GPR code is unaffected, so
// these definitions, which the executable exports and the dynamic linker
// binds ahead of libc's, keep every memcpy/memmove call in the process
// (Swift runtime included) off SVE. Measured with qtest/fpcheck on the
// Thor (kernel 6.8.12-tegra): 4038 lost glibc copies in 30 s on 48 vCPU
// threads whose guest never touched FP; 0 when the guest used FP.
// Upstream Linux fixed this in commit fbc7e61195e2 ("KVM: arm64:
// Unconditionally save+flush host FPSIMD/SVE/SME state"), backported to the
// 5.15, 6.1, 6.6, 6.12 and 6.13 stable series but not to 6.8. The EL1 shim's
// FP touch (resumeFlags bit 1, VCPUPool.shimFPTouch) is the second
// mitigation: it also covers SVE in code other than memcpy/memmove.
//
// `YCODE_LIBC_MEMCPY=1` uses libc's versions again (A/B diagnostics).
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

#if defined(__linux__) && defined(__aarch64__)

#include <arm_neon.h>
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

typedef void *(*copy_fn)(void *, const void *, size_t);
static copy_fn libc_memcpy, libc_memmove;
static int use_libc;

__attribute__((no_builtin("memcpy", "memmove")))
static void copy_forward(unsigned char *d, const unsigned char *s, size_t n) {
    while (n >= 64) {
        uint8x16_t a = vld1q_u8(s), b = vld1q_u8(s + 16), c = vld1q_u8(s + 32), e = vld1q_u8(s + 48);
        vst1q_u8(d, a); vst1q_u8(d + 16, b); vst1q_u8(d + 32, c); vst1q_u8(d + 48, e);
        d += 64; s += 64; n -= 64;
    }
    while (n >= 16) {
        vst1q_u8(d, vld1q_u8(s));
        d += 16; s += 16; n -= 16;
    }
    while (n >= 8) {
        vst1_u8(d, vld1_u8(s));
        d += 8; s += 8; n -= 8;
    }
    while (n--) *d++ = *s++;
}

__attribute__((no_builtin("memcpy", "memmove")))
static void copy_backward(unsigned char *d, const unsigned char *s, size_t n) {
    d += n; s += n;
    while (n >= 64) {
        d -= 64; s -= 64; n -= 64;
        uint8x16_t a = vld1q_u8(s), b = vld1q_u8(s + 16), c = vld1q_u8(s + 32), e = vld1q_u8(s + 48);
        vst1q_u8(d + 48, e); vst1q_u8(d + 32, c); vst1q_u8(d + 16, b); vst1q_u8(d, a);
    }
    while (n >= 16) {
        d -= 16; s -= 16; n -= 16;
        vst1q_u8(d, vld1q_u8(s));
    }
    while (n >= 8) {
        d -= 8; s -= 8; n -= 8;
        vst1_u8(d, vld1_u8(s));
    }
    while (n--) *--d = *--s;
}

__attribute__((no_builtin("memcpy", "memmove")))
void *memmove(void *dest, const void *src, size_t n) {
    if (use_libc) return libc_memmove(dest, src, n);
    unsigned char *d = dest;
    const unsigned char *s = src;
    if (d == s || n == 0) return dest;
    // Forward is safe when the destination starts below the source (each
    // chunk is read before anything at or above it is written) or when the
    // ranges do not overlap.
    if (d < s || d >= s + n) copy_forward(d, s, n);
    else copy_backward(d, s, n);
    return dest;
}

__attribute__((no_builtin("memcpy", "memmove")))
void *memcpy(void *restrict dest, const void *restrict src, size_t n) {
    if (use_libc) return libc_memcpy(dest, src, n);
    // Callers that overlap by mistake still get memmove's result.
    return memmove(dest, src, n);
}

__attribute__((constructor)) static void hostcopy_init(void) {
    const char *e = getenv("YCODE_LIBC_MEMCPY");
    if (!(e && e[0] == '1')) return;
    libc_memcpy = (copy_fn)dlsym(RTLD_NEXT, "memcpy");
    libc_memmove = (copy_fn)dlsym(RTLD_NEXT, "memmove");
    if (libc_memcpy && libc_memmove) use_libc = 1;
}

#endif

typedef int ckvm_hostcopy_unit; // keeps the file a non-empty unit elsewhere
