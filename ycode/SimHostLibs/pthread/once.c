/*
 * once.c - pthread_once of Ycode's libsystem_pthread.
 *
 * Clean-room Ycode code, from POSIX pthread_once(3) and the static
 * initializer PTHREAD_ONCE_INIT (signature 0x30B1BCBA, then zero;
 * host-library-init.md section 5.3). Like Darwin's libpthread, the
 * signature word is ignored: only the state word at +8 matters, so an
 * all-zero object (Libc's stdio __sdidinit) behaves as PTHREAD_ONCE_INIT.
 *
 * pthread_once_t is 16 bytes: the signature, then Ycode's state word at
 * +8 (0 not run, 1 running, 2 running with sleepers, 3 done). The routine
 * runs exactly once; concurrent callers sleep in the kernel until it has
 * finished. A recursive call from inside the routine (the running thread
 * is identified exactly, by its thread port) is a certain self-deadlock and
 * crashes with a diagnostic instead of hanging.
 */
#include "yc_pthread.h"

#define ONCE_NEW 0
#define ONCE_RUNNING 1
#define ONCE_SLEEPERS 2
#define ONCE_DONE 3

struct yc_once {
    long sig;
    yc_u32 state;
    yc_u32 runner; /* the running thread's port name (TSD slot 3) */
};
_Static_assert(sizeof(struct yc_once) == 16, "pthread_once_t is 16 bytes");

YC_EXPORT int YC_FN(pthread_once)(struct yc_once *o, void (*routine)(void))
{
    if (o == YC_NULL || routine == YC_NULL)
        return YC_EINVAL;
    if (YC_LIKELY(YC_LOAD_ACQ(&o->state) == ONCE_DONE))
        return 0;
    /* The signature is not checked: a zero-filled pthread_once_t (a static
     * without PTHREAD_ONCE_INIT, as libsystem_c's stdio __sdidinit) is a
     * valid "not yet run" object, as in Darwin's libpthread. */
    yc_u32 me = (yc_u32)__yc_tsd()[YC_TSD_MACH_THREAD_SELF];
    if (me == 0)
        me = (yc_u32)(yc_uintptr_t)__yc_self();
    for (;;) {
        yc_u32 s = YC_LOAD_ACQ(&o->state);
        if (s == ONCE_DONE)
            return 0;
        if (s == ONCE_NEW) {
            if (!__atomic_compare_exchange_n(&o->state, &s, ONCE_RUNNING, 0, __ATOMIC_ACQUIRE,
                                             __ATOMIC_RELAXED))
                continue;
            YC_STORE(&o->runner, me);
            routine();
            yc_u32 old = __atomic_exchange_n(&o->state, ONCE_DONE, __ATOMIC_RELEASE);
            if (old == ONCE_SLEEPERS)
                __yc_wake32(&o->state, 1);
            return 0;
        }
        if (YC_LOAD(&o->runner) == me && s != ONCE_NEW)
            __yc_fatal("pthread_once called recursively from its own init routine");
        if (s == ONCE_RUNNING &&
            !__atomic_compare_exchange_n(&o->state, &s, ONCE_SLEEPERS, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED))
            continue;
        __yc_wait32(&o->state, ONCE_SLEEPERS, 0);
    }
}
