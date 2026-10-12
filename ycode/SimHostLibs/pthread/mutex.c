/*
 * mutex.c - pthread mutexes and mutex attributes of Ycode's
 * libsystem_pthread.
 *
 * Clean-room Ycode code, from POSIX pthread_mutex_lock(3) and friends,
 * the Darwin <pthread.h> constants, and the static-initializer signatures
 * that clients compile into their data (host-library-init.md section 5.3).
 *
 * These are the first pthread functions libc calls, before __pthread_init
 * runs (host-libraries.md section 8.2). They need nothing but the calling
 * thread's identity (TPIDRRO_EL0 - 224) and never enter the kernel unless
 * the mutex is contended.
 *
 * Layout of pthread_mutex_t (64 bytes; Ycode's own after the signature):
 *   +0  sig: 'MUTX' once initialized, or one of the static-initializer
 *       values (the rest is then zero, which is the unlocked state)
 *   +8  lock word (0 free, 1 held, 2 held and contended)
 *   +12 type, protocol, policy, pshared (bytes)
 *   +16 owner (pthread_t)
 *   +24 recursion count
 *   +28 priority ceiling
 */
#include "yc_pthread.h"

struct yc_mutex {
    long sig;
    yc_u32 word;
    yc_u8 type, protocol, policy, pshared;
    yc_pthread_t owner;
    yc_u32 count;
    yc_i32 prioceiling;
    yc_u8 reserved[32];
};
_Static_assert(sizeof(struct yc_mutex) == 64, "pthread_mutex_t is 64 bytes");

struct yc_mutexattr {
    long sig;
    yc_i32 prioceiling;
    yc_u8 type, protocol, pshared, policy;
};
_Static_assert(sizeof(struct yc_mutexattr) == 16, "pthread_mutexattr_t is 16 bytes");

/* The type a mutex behaves as, or -1 if it is not a valid mutex. */
static int mutex_type(const struct yc_mutex *m)
{
    switch (YC_LOAD_ACQ(&m->sig)) {
    case YC_SIG_MUTEX: return m->type;
    case YC_SIG_MUTEX_INIT: return YC_PTHREAD_MUTEX_NORMAL;
    case YC_SIG_FIRSTFIT_MUTEX_INIT: return YC_PTHREAD_MUTEX_NORMAL;
    case YC_SIG_ERRORCHECK_MUTEX_INIT: return YC_PTHREAD_MUTEX_ERRORCHECK;
    case YC_SIG_RECURSIVE_MUTEX_INIT: return YC_PTHREAD_MUTEX_RECURSIVE;
    default: return -1;
    }
}

/* ---- attributes --------------------------------------------------------- */

YC_EXPORT int YC_FN(pthread_mutexattr_init)(struct yc_mutexattr *a)
{
    a->prioceiling = 0;
    a->type = YC_PTHREAD_MUTEX_NORMAL;
    a->protocol = YC_PTHREAD_PRIO_NONE;
    a->pshared = YC_PTHREAD_PROCESS_PRIVATE;
    a->policy = YC_PTHREAD_MUTEX_POLICY_FIRSTFIT_NP;
    a->sig = YC_SIG_MUTEXATTR;
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutexattr_destroy)(struct yc_mutexattr *a)
{
    if (a->sig != YC_SIG_MUTEXATTR)
        return YC_EINVAL;
    a->sig = 0;
    return 0;
}

#define CHECK_ATTR(a) do { if ((a) == YC_NULL || (a)->sig != YC_SIG_MUTEXATTR) return YC_EINVAL; } while (0)

YC_EXPORT int YC_FN(pthread_mutexattr_settype)(struct yc_mutexattr *a, int type)
{
    CHECK_ATTR(a);
    if (type != YC_PTHREAD_MUTEX_NORMAL && type != YC_PTHREAD_MUTEX_ERRORCHECK &&
        type != YC_PTHREAD_MUTEX_RECURSIVE)
        return YC_EINVAL;
    a->type = (yc_u8)type;
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutexattr_gettype)(const struct yc_mutexattr *a, int *type)
{
    CHECK_ATTR(a);
    *type = a->type;
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutexattr_setprotocol)(struct yc_mutexattr *a, int protocol)
{
    CHECK_ATTR(a);
    if (protocol != YC_PTHREAD_PRIO_NONE && protocol != YC_PTHREAD_PRIO_INHERIT &&
        protocol != YC_PTHREAD_PRIO_PROTECT)
        return YC_EINVAL;
    a->protocol = (yc_u8)protocol;
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutexattr_getprotocol)(const struct yc_mutexattr *a, int *protocol)
{
    CHECK_ATTR(a);
    *protocol = a->protocol;
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutexattr_setpshared)(struct yc_mutexattr *a, int pshared)
{
    CHECK_ATTR(a);
    if (pshared != YC_PTHREAD_PROCESS_PRIVATE && pshared != YC_PTHREAD_PROCESS_SHARED)
        return YC_EINVAL;
    a->pshared = (yc_u8)pshared;
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutexattr_getpshared)(const struct yc_mutexattr *a, int *pshared)
{
    CHECK_ATTR(a);
    *pshared = a->pshared;
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutexattr_setprioceiling)(struct yc_mutexattr *a, int ceiling)
{
    CHECK_ATTR(a);
    if (ceiling < -999 || ceiling > 999)
        return YC_EINVAL;
    a->prioceiling = ceiling;
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutexattr_getprioceiling)(const struct yc_mutexattr *a, int *ceiling)
{
    CHECK_ATTR(a);
    *ceiling = a->prioceiling;
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutexattr_setpolicy_np)(struct yc_mutexattr *a, int policy)
{
    CHECK_ATTR(a);
    if (policy != YC_PTHREAD_MUTEX_POLICY_FAIRSHARE_NP && policy != YC_PTHREAD_MUTEX_POLICY_FIRSTFIT_NP)
        return YC_EINVAL;
    a->policy = (yc_u8)policy;
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutexattr_getpolicy_np)(const struct yc_mutexattr *a, int *policy)
{
    CHECK_ATTR(a);
    *policy = a->policy;
    return 0;
}

/* ---- mutexes ------------------------------------------------------------ */

YC_EXPORT int YC_FN(pthread_mutex_init)(struct yc_mutex *m, const struct yc_mutexattr *a)
{
    if (m == YC_NULL)
        return YC_EINVAL;
    if (a != YC_NULL && a->sig != YC_SIG_MUTEXATTR)
        return YC_EINVAL;
    m->word = 0;
    m->owner = YC_NULL;
    m->count = 0;
    m->type = a ? a->type : YC_PTHREAD_MUTEX_NORMAL;
    m->protocol = a ? a->protocol : YC_PTHREAD_PRIO_NONE;
    m->policy = a ? a->policy : YC_PTHREAD_MUTEX_POLICY_FIRSTFIT_NP;
    m->pshared = a ? a->pshared : YC_PTHREAD_PROCESS_PRIVATE;
    m->prioceiling = a ? a->prioceiling : 0;
    YC_STORE_REL(&m->sig, YC_SIG_MUTEX);
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutex_destroy)(struct yc_mutex *m)
{
    if (mutex_type(m) < 0)
        return YC_EINVAL;
    if (YC_LOAD(&m->word) != 0)
        return YC_EBUSY;
    YC_STORE_REL(&m->sig, 0);
    return 0;
}

/* Already held by the caller: recursion or an error. */
static int relock(struct yc_mutex *m, int type, yc_bool try)
{
    if (type == YC_PTHREAD_MUTEX_RECURSIVE) {
        if (m->count == 0xFFFFFFFFu)
            return YC_EAGAIN;
        m->count++;
        return 0;
    }
    if (try)
        return YC_EBUSY;
    /* Errorcheck: EDEADLK by definition. Normal: relocking would deadlock
     * forever; Ycode reports EDEADLK instead of hanging. */
    return YC_EDEADLK;
}

YC_EXPORT int YC_FN(pthread_mutex_lock)(struct yc_mutex *m)
{
    int type = mutex_type(m);
    if (YC_UNLIKELY(type < 0))
        return YC_EINVAL;
    yc_pthread_t self = __yc_self();
    if (YC_UNLIKELY(YC_LOAD(&m->owner) == self))
        return relock(m, type, 0);
    __yc_lock(&m->word);
    YC_STORE(&m->owner, self);
    m->count = 1;
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutex_trylock)(struct yc_mutex *m)
{
    int type = mutex_type(m);
    if (YC_UNLIKELY(type < 0))
        return YC_EINVAL;
    yc_pthread_t self = __yc_self();
    if (YC_LOAD(&m->owner) == self)
        return relock(m, type, 1);
    if (!__yc_trylock(&m->word))
        return YC_EBUSY;
    YC_STORE(&m->owner, self);
    m->count = 1;
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutex_unlock)(struct yc_mutex *m)
{
    int type = mutex_type(m);
    if (YC_UNLIKELY(type < 0))
        return YC_EINVAL;
    if (YC_UNLIKELY(YC_LOAD(&m->owner) != __yc_self()))
        return YC_EPERM;
    if (type == YC_PTHREAD_MUTEX_RECURSIVE && m->count > 1) {
        m->count--;
        return 0;
    }
    m->count = 0;
    YC_STORE(&m->owner, YC_NULL);
    __yc_unlock(&m->word);
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutex_getprioceiling)(const struct yc_mutex *m, int *ceiling)
{
    if (mutex_type(m) < 0 || ceiling == YC_NULL)
        return YC_EINVAL;
    *ceiling = m->prioceiling;
    return 0;
}

YC_EXPORT int YC_FN(pthread_mutex_setprioceiling)(struct yc_mutex *m, int ceiling, int *old)
{
    if (mutex_type(m) < 0 || ceiling < -999 || ceiling > 999)
        return YC_EINVAL;
    if (old)
        *old = m->prioceiling;
    m->prioceiling = ceiling;
    return 0;
}

/* ---- helpers for condition variables (cond.c) -------------------------- */

/* Releases a mutex the caller holds completely, returning the recursion
 * depth to restore; -1 if the caller does not hold it. */
YC_HIDDEN int __yc_mutex_release_all(void *mp)
{
    struct yc_mutex *m = mp;
    if (mutex_type(m) < 0 || YC_LOAD(&m->owner) != __yc_self())
        return -1;
    int depth = (int)m->count;
    m->count = 0;
    YC_STORE(&m->owner, YC_NULL);
    __yc_unlock(&m->word);
    return depth;
}

YC_HIDDEN void __yc_mutex_reacquire(void *mp, int depth)
{
    struct yc_mutex *m = mp;
    __yc_lock(&m->word);
    YC_STORE(&m->owner, __yc_self());
    m->count = (yc_u32)depth;
}
