/*
 * yc_platform.h - internal declarations of Ycode's libsystem_platform.
 *
 * Clean-room Ycode code, written from specs/simulator/host-libraries.md,
 * specs/simulator/host-library-surface.md, and the public C/POSIX and
 * Darwin API documentation (man pages for the string functions, OSAtomic,
 * spinlock, os_unfair_lock, os_once, os_sync_wait_on_address, setjmp,
 * ffs/fls, sys_icache_invalidate).
 */
#ifndef YC_PLATFORM_H
#define YC_PLATFORM_H

#include "yc_base.h"
#include "yc_kernel_api.h"

/*
 * The lock-owner identity of the calling thread: its Mach thread port name
 * from TSD slot 3 (host-libraries.md section 8.1). TPIDRRO_EL0 points at
 * slot 0. Thread port names have bit 0 set and are never 0
 * (host-library-init.md section 7.2). When there is no TSD base yet, or
 * the slot is still 0, the main thread's agreed name 0x203 is used
 * (section 8.3/8.4). The host tests supply their own per-thread version.
 */
YC_HIDDEN yc_u32 __yc_lock_owner_id(void);
#define YC_TSD_SLOT_MACH_THREAD_SELF 3
#define YC_FALLBACK_OWNER_ID 0x203u

/* Internal lock primitives shared by the lock, atomic and os_lock code. */
YC_HIDDEN void __yc_unfair_lock(yc_u32 *word, yc_u32 self);
YC_HIDDEN yc_bool __yc_unfair_trylock(yc_u32 *word, yc_u32 self);
YC_HIDDEN void __yc_unfair_unlock(yc_u32 *word, yc_u32 self);
YC_HIDDEN void __yc_futex_lock(yc_i32 *word);
YC_HIDDEN yc_bool __yc_futex_trylock(yc_i32 *word);
YC_HIDDEN void __yc_futex_unlock(yc_i32 *word);

/* CPU relax hint while spinning. */
#if defined(__aarch64__)
#define YC_CPU_RELAX() __asm__ volatile("yield" ::: "memory")
#elif defined(__x86_64__)
#define YC_CPU_RELAX() __asm__ volatile("pause" ::: "memory")
#else
#define YC_CPU_RELAX() do { } while (0)
#endif

/* Small string helpers for the _simple_ printer (hidden). */
YC_HIDDEN yc_size_t __yc_strlen(const char *s);

#endif /* YC_PLATFORM_H */
