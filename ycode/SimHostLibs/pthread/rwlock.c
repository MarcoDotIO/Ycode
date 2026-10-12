/*
 * rwlock.c - read-write locks and their attributes of Ycode's
 * libsystem_pthread.
 *
 * Clean-room Ycode code, from POSIX pthread_rwlock_rdlock(3) and friends
 * and the static-initializer signature in host-library-init.md section 5.3.
 *
 * Design: one 32-bit state word. Bit 31 = held for writing, bit 30 =
 * there may be sleepers, bits 0-29 = the number of readers. Sleepers wait
 * in the kernel while the word is unchanged; whoever releases the lock
 * with the sleeper bit set wakes them all, and they compete again.
 *
 * Deadlock detection that POSIX allows: a write lock by the holder of the
 * write lock, or a read lock by the writer, returns EDEADLK; and in a
 * single-threaded process any lock that would have to wait returns
 * EDEADLK (nothing could ever release it).
 *
 * Layout of pthread_rwlock_t (200 bytes; Ycode's own after the
 * signature): +0 sig, +8 state, +12 pshared, +16 writer (pthread_t).
 */
#include "yc_pthread.h"

#define RW_WRITER 0x80000000u
#define RW_WAITERS 0x40000000u
#define RW_READERS 0x3FFFFFFFu

struct yc_rwlock {
    long sig;
    yc_u32 state;
    yc_u32 pshared;
    yc_pthread_t writer;
    yc_u8 reserved[176];
};
_Static_assert(sizeof(struct yc_rwlock) == 200, "pthread_rwlock_t is 200 bytes");

struct yc_rwlockattr {
    long sig;
    yc_u32 pshared;
    yc_u8 reserved[12];
};
_Static_assert(sizeof(struct yc_rwlockattr) == 24, "pthread_rwlockattr_t is 24 bytes");

static yc_bool rw_valid(const struct yc_rwlock *l)
{
    long s = YC_LOAD_ACQ(&l->sig);
    return s == YC_SIG_RWLOCK || s == YC_SIG_RWLOCK_INIT;
}

/* ---- attributes --------------------------------------------------------- */

YC_EXPORT int YC_FN(pthread_rwlockattr_init)(struct yc_rwlockattr *a)
{
    a->pshared = YC_PTHREAD_PROCESS_PRIVATE;
    a->sig = YC_SIG_RWLOCKATTR;
    return 0;
}

YC_EXPORT int YC_FN(pthread_rwlockattr_destroy)(struct yc_rwlockattr *a)
{
    if (a->sig != YC_SIG_RWLOCKATTR)
        return YC_EINVAL;
    a->sig = 0;
    return 0;
}

YC_EXPORT int YC_FN(pthread_rwlockattr_getpshared)(const struct yc_rwlockattr *a, int *pshared)
{
    if (a->sig != YC_SIG_RWLOCKATTR)
        return YC_EINVAL;
    *pshared = (int)a->pshared;
    return 0;
}

YC_EXPORT int YC_FN(pthread_rwlockattr_setpshared)(struct yc_rwlockattr *a, int pshared)
{
    if (a->sig != YC_SIG_RWLOCKATTR)
        return YC_EINVAL;
    if (pshared != YC_PTHREAD_PROCESS_PRIVATE && pshared != YC_PTHREAD_PROCESS_SHARED)
        return YC_EINVAL;
    a->pshared = (yc_u32)pshared;
    return 0;
}

/* ---- locks -------------------------------------------------------------- */

YC_EXPORT int YC_FN(pthread_rwlock_init)(struct yc_rwlock *l, const struct yc_rwlockattr *a)
{
    if (l == YC_NULL || (a != YC_NULL && a->sig != YC_SIG_RWLOCKATTR))
        return YC_EINVAL;
    l->state = 0;
    l->writer = YC_NULL;
    l->pshared = a ? a->pshared : YC_PTHREAD_PROCESS_PRIVATE;
    YC_STORE_REL(&l->sig, YC_SIG_RWLOCK);
    return 0;
}

YC_EXPORT int YC_FN(pthread_rwlock_destroy)(struct yc_rwlock *l)
{
    if (!rw_valid(l))
        return YC_EINVAL;
    if ((YC_LOAD(&l->state) & (RW_WRITER | RW_READERS)) != 0)
        return YC_EBUSY;
    YC_STORE_REL(&l->sig, 0);
    return 0;
}

/* Marks the sleeper bit and sleeps while the state stays `s`. */
static void rw_sleep(struct yc_rwlock *l, yc_u32 s)
{
    if (!(s & RW_WAITERS)) {
        if (!__atomic_compare_exchange_n(&l->state, &s, s | RW_WAITERS, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED))
            return; /* changed: re-check */
        s |= RW_WAITERS;
    }
    __yc_wait32(&l->state, s, 0);
}

static int rw_rdlock(struct yc_rwlock *l, yc_bool try)
{
    if (!rw_valid(l))
        return YC_EINVAL;
    for (;;) {
        yc_u32 s = YC_LOAD(&l->state);
        if (!(s & RW_WRITER)) {
            if ((s & RW_READERS) == RW_READERS)
                return YC_EAGAIN;
            if (__atomic_compare_exchange_n(&l->state, &s, s + 1, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED))
                return 0;
            continue;
        }
        if (YC_LOAD(&l->writer) == __yc_self())
            return YC_EDEADLK;
        if (try)
            return YC_EBUSY;
        if (!YC_LOAD(&YC_FN(__is_threaded)))
            return YC_EDEADLK;
        rw_sleep(l, s);
    }
}

static int rw_wrlock(struct yc_rwlock *l, yc_bool try)
{
    if (!rw_valid(l))
        return YC_EINVAL;
    yc_pthread_t self = __yc_self();
    for (;;) {
        yc_u32 s = YC_LOAD(&l->state);
        if ((s & (RW_WRITER | RW_READERS)) == 0) {
            if (__atomic_compare_exchange_n(&l->state, &s, s | RW_WRITER, 0, __ATOMIC_ACQUIRE,
                                            __ATOMIC_RELAXED)) {
                YC_STORE(&l->writer, self);
                return 0;
            }
            continue;
        }
        if ((s & RW_WRITER) && YC_LOAD(&l->writer) == self)
            return YC_EDEADLK;
        if (try)
            return YC_EBUSY;
        if (!YC_LOAD(&YC_FN(__is_threaded)))
            return YC_EDEADLK;
        rw_sleep(l, s);
    }
}

YC_EXPORT int YC_FN(pthread_rwlock_rdlock)(struct yc_rwlock *l)
{
    return rw_rdlock(l, 0);
}

YC_EXPORT int YC_FN(pthread_rwlock_tryrdlock)(struct yc_rwlock *l)
{
    return rw_rdlock(l, 1);
}

YC_EXPORT int YC_FN(pthread_rwlock_wrlock)(struct yc_rwlock *l)
{
    return rw_wrlock(l, 0);
}

YC_EXPORT int YC_FN(pthread_rwlock_trywrlock)(struct yc_rwlock *l)
{
    return rw_wrlock(l, 1);
}

YC_EXPORT int YC_FN(pthread_rwlock_unlock)(struct yc_rwlock *l)
{
    if (!rw_valid(l))
        return YC_EINVAL;
    yc_u32 s = YC_LOAD(&l->state);
    if (s & RW_WRITER) {
        if (YC_LOAD(&l->writer) != __yc_self())
            return YC_EPERM;
        YC_STORE(&l->writer, YC_NULL);
        yc_u32 old = __atomic_exchange_n(&l->state, 0, __ATOMIC_RELEASE);
        if (old & RW_WAITERS)
            __yc_wake32(&l->state, 1);
        return 0;
    }
    for (;;) {
        if ((s & RW_READERS) == 0)
            return YC_EPERM;
        yc_u32 n = s - 1;
        if ((n & RW_READERS) == 0)
            n = 0; /* the last reader also clears the sleeper bit */
        if (__atomic_compare_exchange_n(&l->state, &s, n, 0, __ATOMIC_RELEASE, __ATOMIC_RELAXED)) {
            if (n == 0 && (s & RW_WAITERS))
                __yc_wake32(&l->state, 1);
            return 0;
        }
    }
}
