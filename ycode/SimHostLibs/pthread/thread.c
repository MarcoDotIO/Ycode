/*
 * thread.c - thread identity, stacks, names, cancellation, exit, signals,
 * and scheduling functions of Ycode's libsystem_pthread.
 *
 * Clean-room Ycode code, from the public pthread(3) man pages, POSIX
 * threads, the Darwin _np function documentation, and
 * host-library-init.md sections 3 and 5.
 *
 * Thread creation, exit, join and detach are in create.c; the per-thread
 * queries here accept any thread on the library's thread list (the main
 * thread, pthread_create threads, and workqueue threads).
 */
#include "yc_pthread.h"

typedef yc_pthread_t pthread_t;

/* ---- identity ----------------------------------------------------------- */

YC_EXPORT pthread_t YC_FN(pthread_self)(void)
{
    return __yc_self();
}

YC_EXPORT pthread_t YC_FN(_pthread_self)(void)
{
    return __yc_self();
}

YC_EXPORT int YC_FN(pthread_equal)(pthread_t a, pthread_t b)
{
    return a == b;
}

YC_EXPORT int YC_FN(pthread_main_np)(void)
{
    return __yc_self() == __yc_main_thread();
}

YC_EXPORT pthread_t YC_FN(pthread_main_thread_np)(void)
{
    return __yc_main_thread();
}

YC_EXPORT int YC_FN(pthread_is_threaded_np)(void)
{
    return YC_LOAD(&YC_FN(__is_threaded));
}

YC_EXPORT int YC_FN(_pthread_is_threaded)(void)
{
    return YC_LOAD(&YC_FN(__is_threaded));
}

YC_EXPORT int YC_FN(pthread_threadid_np)(pthread_t t, yc_u64 *out)
{
    if (out == YC_NULL)
        return YC_EINVAL;
    if (t == YC_NULL)
        t = __yc_self();
    else if (!__yc_thread_valid(t))
        return YC_ESRCH;
    yc_u64 id = YC_LOAD(&t->thread_id);
    if (id == 0 && t == __yc_self()) {
        id = YC_KFN(__thread_selfid)();
        if (id == 0 || id == ~0ull)
            id = 1;
        YC_STORE(&t->thread_id, id);
    }
    /* A new thread records its ID first thing; wait for that (a thread
     * created suspended has none until it is resumed). */
    while (id == 0) {
        if (YC_LOAD(&t->flags) & YC_TF_SUSPENDED)
            return YC_ESRCH;
        YC_FN(sched_yield)();
        id = YC_LOAD(&t->thread_id);
    }
    *out = id;
    return 0;
}

YC_EXPORT yc_u32 YC_FN(pthread_mach_thread_np)(pthread_t t)
{
    if (t == YC_NULL || !__yc_thread_valid(t))
        return 0;
    yc_u32 port = (yc_u32)YC_LOAD(&t->tsd[YC_TSD_MACH_THREAD_SELF]);
    if (port == 0 && t == __yc_self()) {
        port = YC_KFN(mach_thread_self)();
        YC_STORE(&t->tsd[YC_TSD_MACH_THREAD_SELF], port);
    }
    return port;
}

YC_EXPORT pthread_t YC_FN(pthread_from_mach_thread_np)(yc_u32 port)
{
    if (port == 0)
        return YC_NULL;
    yc_pthread_t m = __yc_main_thread();
    if ((yc_u32)m->tsd[YC_TSD_MACH_THREAD_SELF] == port)
        return m;
    yc_pthread_t found = YC_NULL;
    __yc_lock(&__yc_pt.list_lock);
    for (yc_pthread_t p = m->next; p; p = p->next)
        if ((yc_u32)p->tsd[YC_TSD_MACH_THREAD_SELF] == port) {
            found = p;
            break;
        }
    __yc_unlock(&__yc_pt.list_lock);
    return found;
}

YC_EXPORT int YC_FN(pthread_cpu_number_np)(yc_size_t *cpu)
{
    if (cpu == YC_NULL)
        return YC_EINVAL;
#if defined(__aarch64__) && !defined(YC_HOST_TEST)
    yc_uintptr_t v;
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(v));
    *cpu = v & 0xFFF;
#else
    *cpu = 0;
#endif
    return 0;
}

/* ---- stacks ------------------------------------------------------------- */

YC_EXPORT void *YC_FN(pthread_get_stackaddr_np)(pthread_t t)
{
    if (!__yc_thread_valid(t))
        return YC_NULL;
    __yc_thread_defaults(t);
    return (void *)t->stackaddr;
}

YC_EXPORT yc_size_t YC_FN(pthread_get_stacksize_np)(pthread_t t)
{
    if (!__yc_thread_valid(t))
        return 0;
    __yc_thread_defaults(t);
    return t->stackaddr - t->stackbottom;
}

YC_EXPORT int YC_FN(pthread_current_stack_contains_np)(const void *addr, yc_size_t len)
{
    yc_pthread_t self = __yc_self_ready();
    yc_uintptr_t a = (yc_uintptr_t)addr;
    if (a + len < a)
        return -YC_EINVAL;
    if (self->stackaddr == 0)
        return 0;
    return a >= self->stackbottom && a + len <= self->stackaddr;
}

YC_EXPORT yc_uintptr_t YC_FN(pthread_stack_frame_decode_np)(yc_uintptr_t frame, yc_uintptr_t *return_addr)
{
    const yc_uintptr_t *fp = (const yc_uintptr_t *)frame;
    if (return_addr)
        *return_addr = fp[1];
    return fp[0];
}

/* ---- names -------------------------------------------------------------- */

YC_EXPORT int YC_FN(pthread_setname_np)(const char *name)
{
    yc_pthread_t self = __yc_self();
    yc_size_t n = name ? __yc_strlen(name) : 0;
    if (n >= sizeof self->name)
        return YC_ENAMETOOLONG;
    for (yc_size_t i = 0; i < n; i++)
        self->name[i] = name[i];
    self->name[n] = 0;
    return 0;
}

YC_EXPORT int YC_FN(pthread_getname_np)(pthread_t t, char *buf, yc_size_t len)
{
    if (!__yc_thread_valid(t))
        return YC_ESRCH;
    if (buf == YC_NULL || len == 0)
        return len == 0 ? YC_ERANGE : YC_EINVAL;
    yc_size_t i = 0;
    for (; i + 1 < len && i < sizeof t->name && t->name[i]; i++)
        buf[i] = t->name[i];
    buf[i] = 0;
    return 0;
}

/* ---- cancellation ------------------------------------------------------- */

static void act_on_cancel(yc_pthread_t self)
{
    if ((self->cancel_state & YC_PTHREAD_CANCEL_ENABLE) && YC_LOAD(&self->canceled) &&
        !(self->flags & YC_TF_EXITING))
        YC_FN(pthread_exit)(YC_PTHREAD_CANCELED);
}

YC_EXPORT int YC_FN(pthread_setcancelstate)(int state, int *old)
{
    if (state != YC_PTHREAD_CANCEL_ENABLE && state != YC_PTHREAD_CANCEL_DISABLE)
        return YC_EINVAL;
    yc_pthread_t self = __yc_self_ready();
    if (old)
        *old = self->cancel_state & YC_PTHREAD_CANCEL_ENABLE;
    self->cancel_state = (yc_u16)((self->cancel_state & ~YC_PTHREAD_CANCEL_ENABLE) | state);
    return 0;
}

YC_EXPORT int YC_FN(pthread_setcanceltype)(int type, int *old)
{
    if (type != YC_PTHREAD_CANCEL_DEFERRED && type != YC_PTHREAD_CANCEL_ASYNCHRONOUS)
        return YC_EINVAL;
    yc_pthread_t self = __yc_self_ready();
    if (old)
        *old = self->cancel_state & YC_PTHREAD_CANCEL_DEFERRED;
    self->cancel_state = (yc_u16)((self->cancel_state & ~YC_PTHREAD_CANCEL_DEFERRED) | type);
    if (type == YC_PTHREAD_CANCEL_ASYNCHRONOUS)
        act_on_cancel(self);
    return 0;
}

YC_EXPORT void YC_FN(pthread_testcancel)(void)
{
    act_on_cancel(__yc_self_ready());
}

YC_EXPORT int YC_FN(pthread_cancel)(pthread_t t)
{
    if (!__yc_thread_valid(t))
        return YC_ESRCH;
    __yc_thread_defaults(t);
    YC_STORE(&t->canceled, 1);
    if (t == __yc_self() && !(t->cancel_state & YC_PTHREAD_CANCEL_DEFERRED))
        act_on_cancel(t);
    return 0;
}

/* Called from libsystem_kernel's cerror (through libSystem's table) after
 * a failed system call: an interrupted cancellation point acts on a
 * pending cancellation. */
YC_EXPORT void YC_FN(_pthread_exit_if_canceled)(int error)
{
    if ((error & 0xff) != YC_EINTR)
        return;
    yc_pthread_t self = __yc_self();
    if (!YC_LOAD(&self->canceled))
        return;
    __yc_thread_defaults(self);
    if (self->cancel_state & YC_PTHREAD_CANCEL_ENABLE) {
        self->cancel_error = error;
        YC_FN(pthread_exit)(YC_PTHREAD_CANCELED);
    }
}

YC_EXPORT int YC_FN(pthread_self_is_exiting_np)(void)
{
    return (__yc_self()->flags & YC_TF_EXITING) != 0;
}

/* ---- exit, join, detach: create.c ---------------------------------------- */

/* ---- signals ------------------------------------------------------------ */

static int errno_value(void)
{
    int e = *YC_KFN(__error)();
    return e ? e : YC_EINVAL;
}

YC_EXPORT int YC_FN(pthread_kill)(pthread_t t, int sig)
{
    if (sig < 0 || sig >= YC_NSIG)
        return YC_EINVAL;
    if (!__yc_thread_valid(t))
        return YC_ESRCH;
    yc_u32 port = YC_FN(pthread_mach_thread_np)(t);
    if (YC_KFN(__pthread_kill)(port, sig) == -1)
        return errno_value();
    return 0;
}

/* Stage 3a has one thread, so the process mask is the thread's mask
 * (sigprocmask, which libsystem_platform also relies on). */
YC_EXPORT int YC_FN(pthread_sigmask)(int how, const yc_u32 *set, yc_u32 *oset)
{
    if (YC_KFN(sigprocmask)(how, set, oset) == -1)
        return errno_value();
    return 0;
}

static int do_sigwait(const yc_u32 *set, int *sig)
{
    for (;;) {
        if (YC_KFN(__sigwait)(set, sig) != -1)
            return 0;
        int e = errno_value();
        if (e != YC_EINTR)
            return e;
    }
}

YC_EXPORT int YC_FN(sigwait)(const yc_u32 *set, int *sig)
{
    YC_FN(pthread_testcancel)();
    int r = do_sigwait(set, sig);
    YC_FN(pthread_testcancel)();
    return r;
}

YC_EXPORT int yc_sigwait_nocancel(const yc_u32 *set, int *sig) YC_NOCANCEL_NAME(sigwait);
YC_EXPORT int yc_sigwait_nocancel(const yc_u32 *set, int *sig)
{
    return do_sigwait(set, sig);
}

/* ---- scheduling --------------------------------------------------------- */

struct yc_sched_param {
    int sched_priority;
    char opaque[4];
};

static yc_bool valid_policy(int policy)
{
    return policy == YC_SCHED_OTHER || policy == YC_SCHED_RR || policy == YC_SCHED_FIFO;
}

/* A real yield: swtch_pri (Mach trap -59) gives up the CPU. */
YC_EXPORT int YC_FN(sched_yield)(void)
{
    YC_CPU_YIELD();
    (void)YC_KFN(swtch_pri)(0);
    return 0;
}

YC_EXPORT void YC_FN(pthread_yield_np)(void)
{
    YC_FN(sched_yield)();
}

YC_EXPORT void YC_FN(cthread_yield)(void)
{
    YC_FN(sched_yield)();
}

YC_EXPORT void YC_FN(_pthread_yield_to_enqueuer_4dispatch)(void)
{
    YC_FN(sched_yield)();
}

YC_EXPORT int YC_FN(sched_get_priority_min)(int policy)
{
    (void)policy;
    return __yc_pt.user_priority - 16;
}

YC_EXPORT int YC_FN(sched_get_priority_max)(int policy)
{
    (void)policy;
    return __yc_pt.user_priority + 16;
}

YC_EXPORT int YC_FN(pthread_getschedparam)(pthread_t t, int *policy, struct yc_sched_param *param)
{
    if (!__yc_thread_valid(t))
        return YC_ESRCH;
    __yc_thread_defaults(t);
    if (policy)
        *policy = t->policy;
    if (param)
        param->sched_priority = t->sched_priority;
    return 0;
}

YC_EXPORT int YC_FN(pthread_setschedparam)(pthread_t t, int policy, const struct yc_sched_param *param)
{
    if (!__yc_thread_valid(t))
        return YC_ESRCH;
    if (!valid_policy(policy) || param == YC_NULL)
        return YC_EINVAL;
    __yc_thread_defaults(t);
    t->policy = (yc_u8)policy;
    t->sched_priority = param->sched_priority;
    return 0;
}

YC_EXPORT int YC_FN(pthread_set_fixedpriority_self)(void)
{
    return 0;
}

YC_EXPORT int YC_FN(pthread_set_timeshare_self)(void)
{
    return 0;
}

YC_EXPORT int YC_FN(pthread_getconcurrency)(void)
{
    return __yc_pt.concurrency;
}

YC_EXPORT int YC_FN(pthread_setconcurrency)(int level)
{
    if (level < 0)
        return YC_EINVAL;
    __yc_pt.concurrency = level;
    return 0;
}

/* Number of active CPUs from the commpage (ACTIVE_CPUS, RW page 0x034). */
static int active_cpus(void)
{
#if defined(YC_HOST_TEST)
    return 1;
#else
    int n = *(volatile const yc_u8 *)0xFFFFFC034ul;
    return n > 0 ? n : 1;
#endif
}

YC_EXPORT int YC_FN(pthread_qos_max_parallelism)(unsigned qos, unsigned long flags)
{
    (void)flags;
    if (__yc_qos_index(qos) <= 0) {
        *YC_KFN(__error)() = YC_EINVAL;
        return -1;
    }
    return active_cpus();
}

YC_EXPORT int YC_FN(pthread_time_constraint_max_parallelism)(unsigned long flags)
{
    (void)flags;
    return active_cpus();
}

/* ---- per-thread working directory (kernel calls) ------------------------ */

YC_EXPORT int YC_FN(pthread_chdir_np)(const char *path)
{
    return YC_KFN(__pthread_chdir)(path);
}

YC_EXPORT int YC_FN(pthread_fchdir_np)(int fd)
{
    return YC_KFN(__pthread_fchdir)(fd);
}

/* ---- introspection and miscellaneous SPI -------------------------------- */

YC_EXPORT void *YC_FN(pthread_introspection_hook_install)(void *hook)
{
    return __atomic_exchange_n(&__yc_pt.introspection_hook, hook, __ATOMIC_ACQ_REL);
}

YC_EXPORT void *YC_FN(pthread_introspection_getspecific_np)(pthread_t t, unsigned long key)
{
    if (!__yc_thread_valid(t) || key >= YC_TSD_SLOTS)
        return YC_NULL;
    return (void *)t->tsd[key];
}

YC_EXPORT void YC_FN(pthread_introspection_setspecific_np)(pthread_t t, unsigned long key, const void *value)
{
    if (!__yc_thread_valid(t) || key < YC_TSD_FIRST_STATIC_KEY || key >= YC_TSD_SLOTS)
        return;
    t->tsd[key] = (yc_uintptr_t)value;
}

YC_EXPORT int YC_FN(pthread_jit_write_protect_supported_np)(void)
{
    return 0;
}

YC_EXPORT void YC_FN(pthread_jit_write_protect_np)(int enable)
{
    (void)enable;
}

YC_EXPORT void YC_FN(pthread_jit_write_freeze_callbacks_np)(void)
{
}

YC_EXPORT void YC_FN(pthread_prefer_alternate_amx_self)(void)
{
}

YC_EXPORT void YC_FN(pthread_prefer_alternate_cluster_self)(void)
{
}

YC_EXPORT void YC_FN(pthread_install_workgroup_functions_np)(void *funcs)
{
    __yc_pt.workgroup_functions = funcs;
}

YC_EXPORT void YC_FN(_pthread_mutex_enable_legacy_mode)(void)
{
}

/* ---- dependencies (one-shot value hand-off to a waiting thread) --------- */

struct yc_dependency {
    yc_u32 owner;  /* the owner's thread port */
    yc_u32 state;  /* 0 pending, 1 fulfilled */
    void *value;
};

YC_EXPORT void YC_FN(pthread_dependency_init_np)(struct yc_dependency *d, pthread_t owner, void *reserved)
{
    (void)reserved;
    d->owner = owner ? YC_FN(pthread_mach_thread_np)(owner) : 0;
    d->value = YC_NULL;
    YC_STORE_REL(&d->state, 0);
}

YC_EXPORT void YC_FN(pthread_dependency_fulfill_np)(struct yc_dependency *d, void *value)
{
    d->value = value;
    YC_STORE_REL(&d->state, 1);
    __yc_wake32(&d->state, 1);
}

YC_EXPORT void *YC_FN(pthread_dependency_wait_np)(struct yc_dependency *d)
{
    while (YC_LOAD_ACQ(&d->state) == 0)
        __yc_wait32(&d->state, 0, 0); /* blocks in the kernel */
    return d->value;
}
