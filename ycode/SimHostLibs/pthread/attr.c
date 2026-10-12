/*
 * attr.c - thread attributes (pthread_attr_*) of Ycode's libsystem_pthread.
 *
 * Clean-room Ycode code, from POSIX pthread_attr_init(3) and friends, the
 * Darwin pthread_attr_set_qos_class_np(3) documentation, and the default
 * values in host-library-init.md section 5.3 (512 KiB stacks, one guard
 * page, QoS default).
 *
 * Layout of pthread_attr_t (64 bytes; Ycode's own after the signature):
 *   +8 stack size, +16 stack address (top), +24 guard size,
 *   +32 scheduling priority, +36 QoS (pthread_priority_t, low 32 bits),
 *   +40 detach state, +41 inherit, +42 policy, +43 flags, +44 cpu percent,
 *   +48 cpu refill ms, +56 work interval.
 */
#include "yc_pthread.h"

#define ATTR_STACKADDR_SET 0x01
#define ATTR_SCHED_SET 0x02
#define ATTR_QOS_SET 0x04
#define ATTR_CPUPERCENT_SET 0x08

#define DEFAULT_STACK_SIZE 0x80000ul

struct yc_attr {
    long sig;
    yc_size_t stacksize;
    yc_uintptr_t stackaddr;
    yc_size_t guardsize;
    yc_i32 sched_priority;
    yc_u32 qos;
    yc_u8 detach, inherit, policy, flags;
    yc_u8 cpupercent;
    yc_u8 pad[3];
    yc_u64 refillms;
    void *workinterval;
};
_Static_assert(sizeof(struct yc_attr) == 64, "pthread_attr_t is 64 bytes");

struct yc_sched_param {
    int sched_priority;
    char opaque[4];
};

#define CHECK(a) do { if ((a) == YC_NULL || (a)->sig != YC_SIG_ATTR) return YC_EINVAL; } while (0)

YC_EXPORT int YC_FN(pthread_attr_init)(struct yc_attr *a)
{
    a->stacksize = DEFAULT_STACK_SIZE;
    a->stackaddr = 0;
    a->guardsize = YC_PAGE_SIZE;
    a->sched_priority = __yc_pt.user_priority;
    a->qos = (yc_u32)YC_PP_DEFAULT;
    a->detach = YC_PTHREAD_CREATE_JOINABLE;
    a->inherit = YC_PTHREAD_INHERIT_SCHED;
    a->policy = YC_SCHED_OTHER;
    a->flags = 0;
    a->cpupercent = 0;
    a->pad[0] = a->pad[1] = a->pad[2] = 0;
    a->refillms = 0;
    a->workinterval = YC_NULL;
    a->sig = YC_SIG_ATTR;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_destroy)(struct yc_attr *a)
{
    CHECK(a);
    a->sig = 0;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_setdetachstate)(struct yc_attr *a, int state)
{
    CHECK(a);
    if (state != YC_PTHREAD_CREATE_JOINABLE && state != YC_PTHREAD_CREATE_DETACHED)
        return YC_EINVAL;
    a->detach = (yc_u8)state;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_getdetachstate)(const struct yc_attr *a, int *state)
{
    CHECK(a);
    *state = a->detach;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_setinheritsched)(struct yc_attr *a, int inherit)
{
    CHECK(a);
    if (inherit != YC_PTHREAD_INHERIT_SCHED && inherit != YC_PTHREAD_EXPLICIT_SCHED)
        return YC_EINVAL;
    a->inherit = (yc_u8)inherit;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_getinheritsched)(const struct yc_attr *a, int *inherit)
{
    CHECK(a);
    *inherit = a->inherit;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_setschedpolicy)(struct yc_attr *a, int policy)
{
    CHECK(a);
    if (policy != YC_SCHED_OTHER && policy != YC_SCHED_RR && policy != YC_SCHED_FIFO)
        return YC_EINVAL;
    a->policy = (yc_u8)policy;
    a->flags |= ATTR_SCHED_SET;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_getschedpolicy)(const struct yc_attr *a, int *policy)
{
    CHECK(a);
    *policy = a->policy;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_setschedparam)(struct yc_attr *a, const struct yc_sched_param *p)
{
    CHECK(a);
    if (p == YC_NULL)
        return YC_EINVAL;
    a->sched_priority = p->sched_priority;
    a->flags |= ATTR_SCHED_SET;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_getschedparam)(const struct yc_attr *a, struct yc_sched_param *p)
{
    CHECK(a);
    if (p == YC_NULL)
        return YC_EINVAL;
    p->sched_priority = a->sched_priority;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_setscope)(struct yc_attr *a, int scope)
{
    CHECK(a);
    if (scope == YC_PTHREAD_SCOPE_SYSTEM)
        return 0;
    return scope == YC_PTHREAD_SCOPE_PROCESS ? YC_ENOTSUP : YC_EINVAL;
}

YC_EXPORT int YC_FN(pthread_attr_getscope)(const struct yc_attr *a, int *scope)
{
    CHECK(a);
    *scope = YC_PTHREAD_SCOPE_SYSTEM;
    return 0;
}

static yc_bool page_multiple(yc_size_t n)
{
    return (n & (YC_PAGE_SIZE - 1)) == 0;
}

YC_EXPORT int YC_FN(pthread_attr_setstacksize)(struct yc_attr *a, yc_size_t size)
{
    CHECK(a);
    if (size < YC_PTHREAD_STACK_MIN || !page_multiple(size))
        return YC_EINVAL;
    a->stacksize = size;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_getstacksize)(const struct yc_attr *a, yc_size_t *size)
{
    CHECK(a);
    *size = a->stacksize;
    return 0;
}

/* Darwin keeps the stack *top*: stacks grow down. */
YC_EXPORT int YC_FN(pthread_attr_setstackaddr)(struct yc_attr *a, void *addr)
{
    CHECK(a);
    if (!page_multiple((yc_uintptr_t)addr))
        return YC_EINVAL;
    a->stackaddr = (yc_uintptr_t)addr;
    a->flags |= ATTR_STACKADDR_SET;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_getstackaddr)(const struct yc_attr *a, void **addr)
{
    CHECK(a);
    *addr = (void *)a->stackaddr;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_setstack)(struct yc_attr *a, void *addr, yc_size_t size)
{
    CHECK(a);
    if (!page_multiple((yc_uintptr_t)addr) || size < YC_PTHREAD_STACK_MIN || !page_multiple(size))
        return YC_EINVAL;
    a->stackaddr = (yc_uintptr_t)addr + size;
    a->stacksize = size;
    a->flags |= ATTR_STACKADDR_SET;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_getstack)(const struct yc_attr *a, void **addr, yc_size_t *size)
{
    CHECK(a);
    *addr = (void *)(a->stackaddr - a->stacksize);
    *size = a->stacksize;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_setguardsize)(struct yc_attr *a, yc_size_t size)
{
    CHECK(a);
    a->guardsize = (size + YC_PAGE_SIZE - 1) & ~(YC_PAGE_SIZE - 1);
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_getguardsize)(const struct yc_attr *a, yc_size_t *size)
{
    CHECK(a);
    *size = a->guardsize;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_set_qos_class_np)(struct yc_attr *a, unsigned qos, int relpri)
{
    CHECK(a);
    int idx = __yc_qos_index(qos);
    if (idx < 0 || relpri > 0 || relpri < YC_QOS_MIN_RELATIVE_PRIORITY)
        return YC_EINVAL;
    a->qos = (yc_u32)__yc_pp_make(idx, relpri, 0);
    a->flags |= ATTR_QOS_SET;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_get_qos_class_np)(const struct yc_attr *a, unsigned *qos, int *relpri)
{
    CHECK(a);
    int rp = 0;
    unsigned q = __yc_pp_decode(a->qos, &rp, YC_NULL);
    if (qos)
        *qos = q;
    if (relpri)
        *relpri = rp;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_setcpupercent_np)(struct yc_attr *a, int percent, unsigned long refillms)
{
    CHECK(a);
    if (percent < 0 || percent > 100)
        return YC_EINVAL;
    a->cpupercent = (yc_u8)percent;
    a->refillms = refillms;
    a->flags |= ATTR_CPUPERCENT_SET;
    return 0;
}

YC_EXPORT int YC_FN(pthread_attr_setworkinterval_np)(struct yc_attr *a, void *work_interval)
{
    CHECK(a);
    a->workinterval = work_interval;
    return 0;
}
