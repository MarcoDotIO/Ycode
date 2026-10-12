/*
 * thread_id.c - the lock-owner identity used by the unfair locks
 * (guest build only; the host tests provide their own).
 *
 * Clean-room Ycode code. See yc_platform.h. TPIDRRO_EL0 = &tsd[0]
 * (host-libraries.md section 8.1), or 0 before a TSD base exists.
 */
#include "yc_platform.h"

YC_HIDDEN yc_u32 __yc_lock_owner_id(void)
{
    yc_uintptr_t tsd;
    __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(tsd));
    yc_u32 id = 0;
    if (tsd)
        id = (yc_u32)((volatile yc_uintptr_t *)tsd)[YC_TSD_SLOT_MACH_THREAD_SELF];
    if (id <= 1)
        id = YC_FALLBACK_OWNER_ID;
    return id | 1u;
}
