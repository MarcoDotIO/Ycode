/*
 * Fallback errno for libsystem_kernel, following host-libraries.md
 * section 8.5, until agent K writes the real one in SimHostLibs/kernel/.
 *
 * Clean-room Ycode code.
 * - __error() returns TSD slot 1 (TPIDRRO_EL0 points at slot 0) when the
 *   TSD base and the slot are non-zero, otherwise the global errno.
 * - cerror / cerror_nocancel store their argument into both locations and
 *   return -1 in x0 and x1.
 * Defining __error, cerror or cerror_nocancel in SimHostLibs/kernel/
 * suppresses this whole file (see ../../../README.md, "Fallbacks").
 */
#include "yc_base.h"

extern int errno; /* libsystem_kernel's exported global (generated data) */

static int **tsd_errno_slot(void)
{
    yc_uintptr_t tsd;
    __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(tsd));
    return tsd ? (int **)(tsd + 8) : YC_NULL;
}

YC_EXPORT int *__error(void)
{
    int **slot = tsd_errno_slot();
    if (slot && *slot)
        return *slot;
    return &errno;
}

static __int128 store_errno(int value)
{
    int **slot = tsd_errno_slot();
    if (slot && *slot)
        **slot = value;
    errno = value;
    return -1; /* all ones: x0 = x1 = -1 */
}

YC_EXPORT __int128 cerror(int value)
{
    return store_errno(value);
}

YC_EXPORT __int128 cerror_nocancel(int value)
{
    return store_errno(value);
}
