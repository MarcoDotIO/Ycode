/*
 * create.c - thread creation, the thread entry, exit, join and detach of
 * Ycode's libsystem_pthread.
 *
 * Clean-room Ycode code, from specs/simulator/threads-and-events.md
 * sections 1.1-1.2 (bsdthread_create / bsdthread_terminate, the join
 * gate), host-library-init.md sections 5-6 (the pthread_t layout, the
 * thread_start register contract), stage4a-contract.md sections 5 and 7,
 * and POSIX pthread_create(3), pthread_exit(3), pthread_join(3) and
 * pthread_detach(3).
 *
 * Memory of a library-allocated thread (one anonymous mapping):
 *
 *   base                     guard page(s), PROT_NONE
 *   base + guard             stack bottom
 *   base + guard + stack     the pthread_t = the initial SP = the stack top
 *   ... + YC_PTHREAD_SIZE    end
 *
 * For a caller-supplied stack only the pthread_t page is allocated.
 *
 * The kernel is asked to start the thread with PTHREAD_START_CUSTOM: it
 * allocates nothing, sets TPIDRRO_EL0 = pthread + 224, stores the new
 * thread port in TSD slot 3, and enters thread_start (entry.S) with
 * x0 = pthread, x1 = port, x2 = func, x3 = arg, x4 = stack, x5 = flags.
 *
 * Join gate (threads-and-events.md 1.2 step 7): while a thread runs, its
 * exit_gate word (+52) holds its thread port name. A joinable thread
 * terminates with __bsdthread_terminate(0, 0, port, &exit_gate); once the
 * thread is completely gone the kernel stores port & ~3 there and wakes
 * every waiter with ulock_wake(UL_UNFAIR_LOCK | WAKE_ALL |
 * ALLOW_NON_OWNER). A joiner sleeps with __ulock_wait(UL_UNFAIR_LOCK,
 * &exit_gate, port) and frees the thread's memory only after the value
 * changed, so nothing is freed while the thread could still touch it. A
 * detached thread instead asks the kernel to free its memory in the same
 * call. The per-thread lock (+72) orders exit against detach and join.
 */
#include "yc_pthread.h"

typedef yc_pthread_t pthread_t;
typedef void *(*yc_start_fn)(void *);

/* ---- the thread list ---------------------------------------------------- */

YC_HIDDEN void __yc_list_add(yc_pthread_t t)
{
    yc_pthread_t m = __yc_main_thread();
    __yc_lock(&__yc_pt.list_lock);
    if (!(t->flags & YC_TF_ON_LIST) && t != m) {
        t->prev = m;
        t->next = m->next;
        if (m->next)
            m->next->prev = t;
        m->next = t;
        __atomic_fetch_or(&t->flags, YC_TF_ON_LIST, __ATOMIC_RELAXED);
    }
    __yc_unlock(&__yc_pt.list_lock);
}

YC_HIDDEN void __yc_list_remove(yc_pthread_t t)
{
    __yc_lock(&__yc_pt.list_lock);
    if (t->flags & YC_TF_ON_LIST) {
        if (t->prev)
            t->prev->next = t->next;
        if (t->next)
            t->next->prev = t->prev;
        t->next = t->prev = YC_NULL;
        __atomic_fetch_and(&t->flags, (yc_u16)~YC_TF_ON_LIST, __ATOMIC_RELAXED);
    }
    __yc_unlock(&__yc_pt.list_lock);
}

/* ---- creation ----------------------------------------------------------- */

static yc_size_t round_page(yc_size_t n)
{
    return (n + YC_PAGE_SIZE - 1) & ~(YC_PAGE_SIZE - 1);
}

static void *map_anon(yc_size_t size)
{
    void *p = YC_KFN(mmap)(YC_NULL, size, YC_PROT_READ | YC_PROT_WRITE, YC_MAP_PRIVATE | YC_MAP_ANON, -1, 0);
    return (p == YC_MAP_FAILED || p == YC_NULL) ? YC_NULL : p;
}

/* The pthread_priority_t a new thread starts with: the attribute's QoS,
 * else the creator's QoS (flags and override bits dropped), else default. */
static yc_u64 initial_priority(const struct yc_attr *a)
{
    yc_u64 pp;
    if (a && (a->flags & YC_ATTR_QOS_SET))
        pp = a->qos;
    else
        pp = __yc_tsd()[YC_TSD_QOS];
    pp &= YC_PP_QOS_MASK | YC_PP_RELPRI_MASK;
    if ((pp & YC_PP_QOS_MASK) == 0)
        pp = YC_PP_DEFAULT;
    return pp;
}

enum { CREATE_PLAIN = 0, CREATE_SUSPENDED = 1 };

static int create_thread(pthread_t *out, const struct yc_attr *a, yc_start_fn fn, void *arg, int mode)
{
    if (out == YC_NULL || fn == YC_NULL)
        return YC_EINVAL;
    if (a != YC_NULL && a->sig != YC_SIG_ATTR)
        return YC_EINVAL;
    yc_pthread_t self = __yc_self_ready();
    (void)self;

    yc_bool custom = a && (a->flags & YC_ATTR_STACKADDR_SET) && a->stackaddr != 0;
    yc_size_t stacksize = a ? a->stacksize : YC_DEFAULT_STACK_SIZE;
    yc_size_t guard = a ? round_page(a->guardsize) : YC_PAGE_SIZE;
    if (stacksize < YC_PTHREAD_STACK_MIN)
        stacksize = YC_PTHREAD_STACK_MIN;
    stacksize = round_page(stacksize);

    /* 1. Memory: guard + stack + pthread_t, or the pthread_t alone. */
    yc_pthread_t t;
    yc_uintptr_t base, top, bottom;
    yc_size_t total;
    if (custom) {
        total = YC_PTHREAD_SIZE;
        base = (yc_uintptr_t)map_anon(total);
        if (base == 0)
            return YC_EAGAIN;
        t = (yc_pthread_t)base;
        top = a->stackaddr & ~(yc_uintptr_t)15;
        bottom = a->stackaddr - stacksize;
        guard = 0;
    } else {
        total = guard + stacksize + YC_PTHREAD_SIZE;
        base = (yc_uintptr_t)map_anon(total);
        if (base == 0)
            return YC_EAGAIN;
        if (guard)
            (void)YC_KFN(mprotect)((void *)base, guard, YC_PROT_NONE);
        t = (yc_pthread_t)(base + guard + stacksize);
        top = (yc_uintptr_t)t;
        bottom = base + guard;
    }

    /* 2. The pthread_t (fresh anonymous memory is zero-filled). */
    yc_u64 pp = initial_priority(a);
    yc_bool detached = a && a->detach == YC_PTHREAD_CREATE_DETACHED;
    t->tsd[YC_TSD_SELF] = (yc_uintptr_t)t;
    t->tsd[YC_TSD_ERRNO] = (yc_uintptr_t)&t->err_no;
    t->tsd[YC_TSD_QOS] = pp;
    t->tsd[YC_TSD_PTR_MUNGE] = __yc_pt.munge_token;
    t->sig = (long)((yc_uintptr_t)t ^ __yc_pt.munge_token);
    t->stackaddr = top;
    t->stackbottom = bottom;
    t->freeaddr = base;
    t->freesize = total;
    t->guardsize = guard;
    t->policy = (a && (a->flags & YC_ATTR_SCHED_SET)) ? a->policy : YC_SCHED_OTHER;
    t->sched_priority = (a && (a->flags & YC_ATTR_SCHED_SET)) ? a->sched_priority : __yc_pt.user_priority;
    t->cancel_state = YC_PTHREAD_CANCEL_ENABLE | YC_PTHREAD_CANCEL_DEFERRED;
    t->detach_flags = (yc_u8)((detached ? 0 : YC_DF_JOINABLE) | (custom ? YC_DF_CUSTOM_STACK : 0));
    t->start_routine = (void *)fn;
    t->start_arg = arg;
    yc_u16 fl = YC_TF_DEFAULTS_SET;
    if (detached)
        fl |= YC_TF_DETACHED;
    if (custom)
        fl |= YC_TF_CUSTOM_STACK;
    if (mode == CREATE_SUSPENDED)
        fl |= YC_TF_SUSPENDED;
    t->flags = fl;

    /* 3. Kernel flags: QoS from the attribute (or inherited), or an
     *    explicit scheduling policy and priority. */
    yc_u32 kflags = YC_PTHREAD_START_CUSTOM;
    if (a && (a->flags & YC_ATTR_SCHED_SET) && !(a->flags & YC_ATTR_QOS_SET))
        kflags |= YC_PTHREAD_START_SETSCHED | ((yc_u32)a->policy << YC_PTHREAD_START_POLICY_SHIFT) |
                  ((yc_u32)a->sched_priority & YC_PTHREAD_START_IMPORTANCE_MASK);
    else
        kflags |= YC_PTHREAD_START_QOSCLASS | ((yc_u32)pp & YC_PTHREAD_START_QOS_MASK);
    if (mode == CREATE_SUSPENDED)
        kflags |= YC_PTHREAD_START_SUSPENDED;

    /* 4. Publish, then start. The thread may run (and even exit) before
     *    the kernel call returns. */
    YC_STORE(&YC_FN(__is_threaded), 1);
    __atomic_fetch_add(&__yc_pt.thread_count, 1, __ATOMIC_RELAXED);
    __yc_list_add(t);
    *out = t;
    void *r = YC_KFN(__bsdthread_create)((void *)fn, arg, (void *)top, t, kflags);
    if (r == (void *)-1 || r == YC_NULL) {
        __yc_list_remove(t);
        __atomic_fetch_sub(&__yc_pt.thread_count, 1, __ATOMIC_RELAXED);
        YC_KFN(munmap)((void *)base, total);
        return YC_EAGAIN;
    }
    /* The kernel wrote the port into slot 3 before returning. Arm the
     * join gate unless the thread already did (or already exited). */
    yc_u32 port = (yc_u32)YC_LOAD(&t->tsd[YC_TSD_MACH_THREAD_SELF]);
    yc_u32 zero = 0;
    if (port != 0)
        __atomic_compare_exchange_n(&t->exit_gate, &zero, port, 0, __ATOMIC_RELEASE, __ATOMIC_RELAXED);
    return 0;
}

YC_EXPORT int YC_FN(pthread_create)(pthread_t *out, const struct yc_attr *a, yc_start_fn fn, void *arg)
{
    return create_thread(out, a, fn, arg, CREATE_PLAIN);
}

/* A raw Mach thread may call this; in Ycode every thread has a TSD (or the
 * library's fallback block), so it is pthread_create. */
YC_EXPORT int YC_FN(pthread_create_from_mach_thread)(pthread_t *out, const struct yc_attr *a, yc_start_fn fn,
                                                     void *arg)
{
    return create_thread(out, a, fn, arg, CREATE_PLAIN);
}

/* The thread is created but not started; the caller resumes it with
 * thread_resume(pthread_mach_thread_np(thread)). */
YC_EXPORT int YC_FN(pthread_create_suspended_np)(pthread_t *out, const struct yc_attr *a, yc_start_fn fn,
                                                 void *arg)
{
    return create_thread(out, a, fn, arg, CREATE_SUSPENDED);
}

/* Workgroups are scheduling hints (real-time and performance-control
 * groups). Ycode has no such scheduler, so the thread is created normally
 * and the workgroup is not joined. */
YC_EXPORT int YC_FN(pthread_create_with_workgroup_np)(pthread_t *out, void *workgroup, const struct yc_attr *a,
                                                      yc_start_fn fn, void *arg)
{
    (void)workgroup;
    return create_thread(out, a, fn, arg, CREATE_PLAIN);
}

/* ---- the thread entry (called by thread_start in entry.S) ---------------- */

YC_EXPORT YC_NORETURN void YC_FN(_pthread_start)(yc_pthread_t self, yc_u32 kport, yc_start_fn fn, void *arg,
                                                 void *stack, yc_u32 flags)
{
    (void)stack;
#ifndef YC_HOST_TEST
    /* The kernel sets TPIDRRO_EL0 = self + 224 and reports it with
     * TSD_BASE_SET; set it here if it did not. */
    if (!(flags & YC_PTHREAD_START_TSD_BASE_SET))
        YC_KFN(_thread_set_tsd_base)(&self->tsd[0]);
#else
    (void)flags;
#endif
    if (self->tsd[YC_TSD_MACH_THREAD_SELF] == 0)
        self->tsd[YC_TSD_MACH_THREAD_SELF] = kport;
    YC_STORE_REL(&self->exit_gate, kport);
    yc_u64 id = YC_KFN(__thread_selfid)();
    YC_STORE(&self->thread_id, (id == 0 || id == ~0ull) ? (yc_u64)kport : id);
    if (fn == YC_NULL)
        fn = (yc_start_fn)self->start_routine;
    void *result = fn(arg);
    __yc_thread_exit(self, result);
}

/* ---- exit ----------------------------------------------------------------- */

/* The public cleanup record (<pthread.h> __darwin_pthread_handler_rec). */
struct yc_cleanup_rec {
    void (*routine)(void *);
    void *arg;
    struct yc_cleanup_rec *next;
};

YC_HIDDEN YC_NORETURN void __yc_thread_exit(yc_pthread_t self, void *value)
{
    __atomic_fetch_or(&self->flags, YC_TF_EXITING, __ATOMIC_RELAXED);
    self->exit_value = value;
    /* 1. Cleanup handlers the client pushed inline, innermost first. */
    struct yc_cleanup_rec *rec;
    while ((rec = (struct yc_cleanup_rec *)self->cleanup_stack) != YC_NULL) {
        self->cleanup_stack = rec->next;
        if (rec->routine)
            rec->routine(rec->arg);
    }
    /* 2. TSD destructors (they may block forever, e.g. dispatch_main). */
    __yc_tsd_run_destructors(self);

    /* 3. The last thread to exit ends the process with status 0. */
    yc_u32 n = YC_LOAD(&__yc_pt.thread_count);
    for (;;) {
        yc_u32 next = n > 1 ? n - 1 : 0;
        if (__atomic_compare_exchange_n(&__yc_pt.thread_count, &n, next, 0, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
            break;
    }
    if (n <= 1) {
        if (__yc_pt.exit_fn)
            __yc_pt.exit_fn(0);
        YC_KFN(_exit)(0);
    }

    /* 4. Detached threads free themselves; joinable ones become zombies
     *    that the joiner (or a later detach) frees after the gate. */
    yc_u32 port = (yc_u32)self->tsd[YC_TSD_MACH_THREAD_SELF];
    __yc_lock(&self->lock);
    yc_bool detached = (self->flags & YC_TF_DETACHED) != 0;
    if (!detached)
        __atomic_fetch_or(&self->flags, YC_TF_EXITED, __ATOMIC_RELEASE);
    __yc_unlock(&self->lock);

    void *freeaddr = YC_NULL;
    yc_size_t freesize = 0;
    yc_uintptr_t gate = 0;
    if (detached) {
        __yc_list_remove(self);
        if (!(self->flags & YC_TF_MAIN)) {
            freeaddr = (void *)self->freeaddr;
            freesize = self->freesize;
        }
    } else {
        if (YC_LOAD(&self->exit_gate) == 0 && port != 0)
            YC_STORE_REL(&self->exit_gate, port);
        gate = (yc_uintptr_t)&self->exit_gate;
    }
    YC_KFN(__bsdthread_terminate)(freeaddr, freesize, port, gate);
    __yc_fatal("__bsdthread_terminate returned");
}

YC_EXPORT YC_NORETURN void YC_FN(pthread_exit)(void *value)
{
    __yc_thread_exit(__yc_self_ready(), value);
}

/* ---- join and detach ------------------------------------------------------ */

/* Sleeps until the kernel has stored port & ~3 in the thread's gate. */
static void wait_gate(yc_pthread_t t)
{
    for (;;) {
        yc_u32 port = (yc_u32)YC_LOAD(&t->tsd[YC_TSD_MACH_THREAD_SELF]);
        yc_u32 g = YC_LOAD_ACQ(&t->exit_gate);
        if (g != 0 && g != port)
            return; /* the thread is gone */
        if (g == 0) {
            /* Not armed yet: the thread is being started right now. */
            YC_FN(sched_yield)();
            continue;
        }
        int r = YC_KFN(__ulock_wait)(YC_UL_UNFAIR_LOCK | YC_ULF_NO_ERRNO, &t->exit_gate, g, 0);
        if (r < 0 && r != -YC_EINTR && r != -YC_EFAULT)
            YC_FN(sched_yield)(); /* no kernel support (or a racing exit): poll */
    }
}

/* Frees a terminated thread's memory and forgets it. */
static void reap(yc_pthread_t t)
{
    __yc_list_remove(t);
    if (t->flags & YC_TF_MAIN)
        return; /* the main stack belongs to the process */
    if (t->freesize != 0)
        YC_KFN(munmap)((void *)t->freeaddr, t->freesize);
}

YC_EXPORT int YC_FN(pthread_join)(pthread_t t, void **value);

static int join(pthread_t t, void **value, yc_bool cancelable)
{
    if (!__yc_thread_valid(t))
        return YC_ESRCH;
    yc_pthread_t self = __yc_self_ready();
    if (t == self)
        return YC_EDEADLK;
    if (cancelable)
        YC_FN(pthread_testcancel)();
    __yc_lock(&t->lock);
    if ((t->flags & (YC_TF_DETACHED | YC_TF_JOINER)) || (t->flags & YC_TF_WORKQ)) {
        __yc_unlock(&t->lock);
        return YC_EINVAL;
    }
    __atomic_fetch_or(&t->flags, YC_TF_JOINER, __ATOMIC_RELAXED);
    __yc_unlock(&t->lock);

    wait_gate(t);
    if (value)
        *value = t->exit_value;
    reap(t);
    return 0;
}

YC_EXPORT int YC_FN(pthread_join)(pthread_t t, void **value)
{
    return join(t, value, 1);
}

YC_EXPORT int yc_pthread_join_nocancel(pthread_t t, void **value) YC_NOCANCEL_NAME(pthread_join);
YC_EXPORT int yc_pthread_join_nocancel(pthread_t t, void **value)
{
    return join(t, value, 0);
}

YC_EXPORT int YC_FN(pthread_detach)(pthread_t t)
{
    if (!__yc_thread_valid(t))
        return YC_ESRCH;
    __yc_thread_defaults(t);
    __yc_lock(&t->lock);
    if (t->flags & (YC_TF_DETACHED | YC_TF_JOINER)) {
        __yc_unlock(&t->lock);
        return YC_EINVAL;
    }
    yc_bool zombie = (t->flags & YC_TF_EXITED) != 0;
    __atomic_fetch_or(&t->flags, zombie ? YC_TF_JOINER : YC_TF_DETACHED, __ATOMIC_RELAXED);
    t->detach_flags &= (yc_u8)~YC_DF_JOINABLE;
    __yc_unlock(&t->lock);
    if (zombie) {
        /* It already chose the joinable exit path: reap it here. */
        wait_gate(t);
        reap(t);
    }
    return 0;
}
