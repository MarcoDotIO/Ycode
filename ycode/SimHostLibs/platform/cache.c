/*
 * cache.c - sys_icache_invalidate, sys_dcache_flush and sys_cache_control
 * of Ycode's libsystem_platform.
 *
 * Clean-room Ycode code, from the public sys_icache_invalidate(3) man page
 * and the Arm Architecture Reference Manual (CTR_EL0, DC CVAU, DC CIVAC,
 * IC IVAU). Ycode's EL1 shim sets SCTLR_EL1.UCT and UCI
 * (specs/simulator/vm-shim-protocol.md), so EL0 may read CTR_EL0 and issue
 * these cache maintenance instructions.
 */
#include "yc_base.h"

/* macOS hosts trap EL0 reads of CTR_EL0, so the host tests there only
 * exercise the argument handling. */
#if defined(__aarch64__) && !(defined(YC_HOST_TEST) && defined(__APPLE__))
#define YC_HAVE_CACHE_OPS 1
#endif

#define YC_CACHE_PREPARE_FOR_EXECUTION 1
#define YC_CACHE_FLUSH_DCACHE 2

#if YC_HAVE_CACHE_OPS
static yc_u64 read_ctr(void)
{
    yc_u64 ctr;
    __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
    return ctr;
}
#endif

YC_EXPORT void YC_FN(sys_icache_invalidate)(void *start, yc_size_t len)
{
#if YC_HAVE_CACHE_OPS
    if (len == 0)
        return;
    yc_u64 ctr = read_ctr();
    yc_uintptr_t begin = (yc_uintptr_t)start, end = begin + len;
    /* CTR_EL0.IDC (bit 28): no D-cache clean needed for I/D coherence. */
    if (!(ctr & (1ull << 28))) {
        yc_uintptr_t line = 4ul << ((ctr >> 16) & 0xF);
        for (yc_uintptr_t a = begin & ~(line - 1); a < end; a += line)
            __asm__ volatile("dc cvau, %0" ::"r"(a) : "memory");
    }
    __asm__ volatile("dsb ish" ::: "memory");
    /* CTR_EL0.DIC (bit 29): no I-cache invalidation needed. */
    if (!(ctr & (1ull << 29))) {
        yc_uintptr_t line = 4ul << (ctr & 0xF);
        for (yc_uintptr_t a = begin & ~(line - 1); a < end; a += line)
            __asm__ volatile("ic ivau, %0" ::"r"(a) : "memory");
        __asm__ volatile("dsb ish" ::: "memory");
    }
    __asm__ volatile("isb" ::: "memory");
#else
    (void)start;
    (void)len;
#endif
}

YC_EXPORT void YC_FN(sys_dcache_flush)(void *start, yc_size_t len)
{
#if YC_HAVE_CACHE_OPS
    if (len == 0)
        return;
    yc_u64 ctr = read_ctr();
    yc_uintptr_t line = 4ul << ((ctr >> 16) & 0xF);
    yc_uintptr_t begin = (yc_uintptr_t)start, end = begin + len;
    for (yc_uintptr_t a = begin & ~(line - 1); a < end; a += line)
        __asm__ volatile("dc civac, %0" ::"r"(a) : "memory");
    __asm__ volatile("dsb sy" ::: "memory");
#else
    (void)start;
    (void)len;
#endif
}

YC_EXPORT int YC_FN(sys_cache_control)(int function, void *start, yc_size_t len)
{
    switch (function) {
    case YC_CACHE_PREPARE_FOR_EXECUTION:
        YC_FN(sys_icache_invalidate)(start, len);
        return 0;
    case YC_CACHE_FLUSH_DCACHE:
        YC_FN(sys_dcache_flush)(start, len);
        return 0;
    default:
        return YC_ENOTSUP;
    }
}
