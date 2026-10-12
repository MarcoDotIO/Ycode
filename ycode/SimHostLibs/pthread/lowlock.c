/*
 * lowlock.c - the internal lock and wait primitives of Ycode's
 * libsystem_pthread.
 *
 * Clean-room Ycode code. A three-state lock word (0 free, 1 held, 2 held
 * with possible waiters) over the kernel's compare-and-wait user locks
 * (__ulock_wait2 / __ulock_wake with UL_COMPARE_AND_WAIT and ULF_NO_ERRNO,
 * host-library-init.md sections 4.3 and 6.4). The uncontended paths never
 * enter the kernel, so a single-threaded process makes no ulock calls.
 */
#include "yc_pthread.h"

YC_HIDDEN yc_bool __yc_trylock(yc_u32 *word)
{
    yc_u32 expected = 0;
    return __atomic_compare_exchange_n(word, &expected, 1, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED);
}

static YC_NOINLINE void lock_slow(yc_u32 *word)
{
    yc_u32 c = __atomic_exchange_n(word, 2, __ATOMIC_ACQUIRE);
    while (c != 0) {
        __yc_wait32(word, 2, 0);
        c = __atomic_exchange_n(word, 2, __ATOMIC_ACQUIRE);
    }
}

YC_HIDDEN void __yc_lock(yc_u32 *word)
{
    if (YC_LIKELY(__yc_trylock(word)))
        return;
    lock_slow(word);
}

YC_HIDDEN void __yc_unlock(yc_u32 *word)
{
    if (YC_UNLIKELY(__atomic_exchange_n(word, 0, __ATOMIC_RELEASE) == 2))
        __yc_wake32(word, 0);
}

YC_HIDDEN int __yc_wait32(yc_u32 *addr, yc_u32 value, yc_u64 timeout_ns)
{
    int r = YC_KFN(__ulock_wait2)(YC_UL_COMPARE_AND_WAIT | YC_ULF_NO_ERRNO, addr, value, timeout_ns, 0);
    if (r > 0)
        r = 0; /* the number of remaining waiters */
    if (r == -YC_ENOSYS || r == -1) {
        /* No kernel support yet: behave as a spurious wake-up. */
        YC_CPU_YIELD();
        return timeout_ns ? -YC_ETIMEDOUT : 0;
    }
    return r;
}

YC_HIDDEN void __yc_wake32(yc_u32 *addr, yc_bool all)
{
    yc_u32 op = YC_UL_COMPARE_AND_WAIT | YC_ULF_NO_ERRNO;
    if (all)
        op |= YC_ULF_WAKE_ALL;
    (void)YC_KFN(__ulock_wake)(op, addr, 0);
}

YC_HIDDEN yc_u64 __yc_realtime_ns(void)
{
    struct yc_timeval tv = { 0, 0 };
    int r = YC_KFN(__gettimeofday)(&tv, YC_NULL, YC_NULL);
    if (tv.tv_sec == 0 && r > 0)
        tv.tv_sec = r; /* the old convention returns the seconds in x0 */
    if (tv.tv_sec <= 0)
        return 0;
    return (yc_u64)tv.tv_sec * 1000000000ull + (yc_u64)tv.tv_usec * 1000ull;
}
