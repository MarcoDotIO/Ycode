/*
 * cond.c - condition variables and their attributes of Ycode's
 * libsystem_pthread.
 *
 * Clean-room Ycode code, from POSIX pthread_cond_wait(3) and friends, the
 * Darwin pthread_cond_timedwait_relative_np and pthread_cond_signal_thread_np
 * documentation, and the static-initializer signature in
 * host-library-init.md section 5.3.
 *
 * Design: a sequence counter. A waiter registers, samples the counter,
 * releases the mutex, and sleeps in the kernel while the counter is
 * unchanged (UL_COMPARE_AND_WAIT); signal and broadcast bump the counter
 * and wake one or all sleepers. Spurious wake-ups are allowed by POSIX.
 *
 * Single-threaded processes (stage 3a): an untimed wait can never be
 * satisfied, because nothing else could signal. Instead of sleeping
 * forever, the library prints a diagnostic and crashes. A timed wait
 * sleeps until its deadline and returns ETIMEDOUT.
 *
 * Layout of pthread_cond_t (48 bytes; Ycode's own after the signature):
 *   +0 sig ('COND' or the static initializer), +8 sequence, +12 waiters,
 *   +16 the mutex last used, +24 pshared.
 */
#include "yc_pthread.h"

YC_HIDDEN int __yc_mutex_release_all(void *m);
YC_HIDDEN void __yc_mutex_reacquire(void *m, int depth);

struct yc_cond {
    long sig;
    yc_u32 seq;
    yc_u32 waiters;
    void *mutex;
    yc_u32 pshared;
    yc_u8 reserved[20];
};
_Static_assert(sizeof(struct yc_cond) == 48, "pthread_cond_t is 48 bytes");

struct yc_condattr {
    long sig;
    yc_u32 pshared;
    yc_u32 reserved;
};
_Static_assert(sizeof(struct yc_condattr) == 16, "pthread_condattr_t is 16 bytes");

struct yc_timespec {
    long tv_sec;
    long tv_nsec;
};

static yc_bool cond_valid(const struct yc_cond *c)
{
    long s = YC_LOAD_ACQ(&c->sig);
    return s == YC_SIG_COND || s == YC_SIG_COND_INIT;
}

/* ---- attributes --------------------------------------------------------- */

YC_EXPORT int YC_FN(pthread_condattr_init)(struct yc_condattr *a)
{
    a->pshared = YC_PTHREAD_PROCESS_PRIVATE;
    a->reserved = 0;
    a->sig = YC_SIG_CONDATTR;
    return 0;
}

YC_EXPORT int YC_FN(pthread_condattr_destroy)(struct yc_condattr *a)
{
    if (a->sig != YC_SIG_CONDATTR)
        return YC_EINVAL;
    a->sig = 0;
    return 0;
}

YC_EXPORT int YC_FN(pthread_condattr_getpshared)(const struct yc_condattr *a, int *pshared)
{
    if (a->sig != YC_SIG_CONDATTR)
        return YC_EINVAL;
    *pshared = (int)a->pshared;
    return 0;
}

YC_EXPORT int YC_FN(pthread_condattr_setpshared)(struct yc_condattr *a, int pshared)
{
    if (a->sig != YC_SIG_CONDATTR)
        return YC_EINVAL;
    if (pshared != YC_PTHREAD_PROCESS_PRIVATE && pshared != YC_PTHREAD_PROCESS_SHARED)
        return YC_EINVAL;
    a->pshared = (yc_u32)pshared;
    return 0;
}

/* ---- condition variables ------------------------------------------------ */

YC_EXPORT int YC_FN(pthread_cond_init)(struct yc_cond *c, const struct yc_condattr *a)
{
    if (c == YC_NULL || (a != YC_NULL && a->sig != YC_SIG_CONDATTR))
        return YC_EINVAL;
    c->seq = 0;
    c->waiters = 0;
    c->mutex = YC_NULL;
    c->pshared = a ? a->pshared : YC_PTHREAD_PROCESS_PRIVATE;
    YC_STORE_REL(&c->sig, YC_SIG_COND);
    return 0;
}

YC_EXPORT int YC_FN(pthread_cond_destroy)(struct yc_cond *c)
{
    if (!cond_valid(c))
        return YC_EINVAL;
    if (YC_LOAD(&c->waiters) != 0)
        return YC_EBUSY;
    YC_STORE_REL(&c->sig, 0);
    return 0;
}

static int cond_wake(struct yc_cond *c, yc_bool all)
{
    if (!cond_valid(c))
        return YC_EINVAL;
    __atomic_fetch_add(&c->seq, 1, __ATOMIC_SEQ_CST);
    if (__atomic_load_n(&c->waiters, __ATOMIC_SEQ_CST) != 0)
        __yc_wake32(&c->seq, all);
    return 0;
}

YC_EXPORT int YC_FN(pthread_cond_signal)(struct yc_cond *c)
{
    return cond_wake(c, 0);
}

YC_EXPORT int YC_FN(pthread_cond_broadcast)(struct yc_cond *c)
{
    return cond_wake(c, 1);
}

YC_EXPORT int YC_FN(pthread_cond_signal_thread_np)(struct yc_cond *c, yc_pthread_t t)
{
    (void)t; /* waking any waiter is a permitted (spurious) wake-up */
    return cond_wake(c, t != YC_NULL);
}

/* timeout_ns: 0 = no timeout; otherwise relative nanoseconds (>= 1). */
static int cond_wait(struct yc_cond *c, void *m, yc_u64 timeout_ns, yc_bool cancelable)
{
    if (!cond_valid(c) || m == YC_NULL)
        return YC_EINVAL;
    if (timeout_ns == 0 && !YC_LOAD(&YC_FN(__is_threaded)))
        __yc_fatal("pthread_cond_wait would wait forever (no other thread exists)");
    if (cancelable)
        YC_FN(pthread_testcancel)();
    __atomic_fetch_add(&c->waiters, 1, __ATOMIC_SEQ_CST);
    yc_u32 seq = __atomic_load_n(&c->seq, __ATOMIC_SEQ_CST);
    int depth = __yc_mutex_release_all(m);
    if (depth < 0) {
        __atomic_fetch_sub(&c->waiters, 1, __ATOMIC_SEQ_CST);
        return YC_EPERM;
    }
    c->mutex = m;
    int r = __yc_wait32(&c->seq, seq, timeout_ns);
    __yc_mutex_reacquire(m, depth);
    __atomic_fetch_sub(&c->waiters, 1, __ATOMIC_SEQ_CST);
    if (cancelable)
        YC_FN(pthread_testcancel)();
    if (r == -YC_ETIMEDOUT && __atomic_load_n(&c->seq, __ATOMIC_ACQUIRE) == seq)
        return YC_ETIMEDOUT;
    return 0;
}

/* Converts an absolute CLOCK_REALTIME deadline to a relative timeout.
 * Returns 0 and sets *ns (>= 1), or an error (EINVAL, ETIMEDOUT). */
static int deadline_to_relative(const struct yc_timespec *abs, yc_u64 *ns)
{
    if (abs == YC_NULL || abs->tv_nsec < 0 || abs->tv_nsec >= 1000000000l || abs->tv_sec < 0)
        return YC_EINVAL;
    yc_u64 when = (yc_u64)abs->tv_sec * 1000000000ull + (yc_u64)abs->tv_nsec;
    yc_u64 now = __yc_realtime_ns();
    if (now != 0 && when <= now)
        return YC_ETIMEDOUT;
    *ns = now ? when - now : when;
    if (*ns == 0)
        *ns = 1;
    return 0;
}

static int relative_ns(const struct yc_timespec *rel, yc_u64 *ns)
{
    if (rel == YC_NULL || rel->tv_nsec < 0 || rel->tv_nsec >= 1000000000l || rel->tv_sec < 0)
        return YC_EINVAL;
    *ns = (yc_u64)rel->tv_sec * 1000000000ull + (yc_u64)rel->tv_nsec;
    return *ns == 0 ? YC_ETIMEDOUT : 0;
}

YC_EXPORT int YC_FN(pthread_cond_wait)(struct yc_cond *c, void *m)
{
    return cond_wait(c, m, 0, 1);
}

YC_EXPORT int YC_FN(pthread_cond_timedwait)(struct yc_cond *c, void *m, const struct yc_timespec *abs)
{
    yc_u64 ns;
    int e = deadline_to_relative(abs, &ns);
    if (e)
        return e;
    return cond_wait(c, m, ns, 1);
}

YC_EXPORT int YC_FN(pthread_cond_timedwait_relative_np)(struct yc_cond *c, void *m, const struct yc_timespec *rel)
{
    yc_u64 ns;
    int e = relative_ns(rel, &ns);
    if (e)
        return e;
    return cond_wait(c, m, ns, 1);
}

YC_EXPORT int yc_cond_wait_nocancel(struct yc_cond *c, void *m) YC_NOCANCEL_NAME(pthread_cond_wait);
YC_EXPORT int yc_cond_wait_nocancel(struct yc_cond *c, void *m)
{
    return cond_wait(c, m, 0, 0);
}

YC_EXPORT int yc_cond_timedwait_nocancel(struct yc_cond *c, void *m, const struct yc_timespec *abs)
    YC_NOCANCEL_NAME(pthread_cond_timedwait);
YC_EXPORT int yc_cond_timedwait_nocancel(struct yc_cond *c, void *m, const struct yc_timespec *abs)
{
    yc_u64 ns;
    int e = deadline_to_relative(abs, &ns);
    if (e)
        return e;
    return cond_wait(c, m, ns, 0);
}
