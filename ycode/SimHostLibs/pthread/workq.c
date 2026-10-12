/*
 * workq.c - the workqueue side of Ycode's libsystem_pthread: the worker
 * entry (_pthread_wqthread, called by start_wqthread in entry.S), the
 * callback registration that libdispatch calls (pthread_workqueue_setup and
 * the older _pthread_workqueue_init* forms), thread requests, and
 * workloops with scheduling parameters.
 *
 * Clean-room Ycode code, from specs/simulator/threads-and-events.md
 * sections 2.1-2.9 (workq_kernreturn operations, the SETUP_DISPATCH
 * record, the priority encoding, the worker memory layout, the
 * start_wqthread register state and upcall flags, the return/reuse/exit
 * rules, kqueue_workloop_ctl), host-library-init.md section 6.3, and
 * stage4a-contract.md sections 5 and 7.
 *
 * Worker lifecycle. The kernel creates every worker and enters
 * start_wqthread with x0 = self, x1 = port, x2 = stack bottom, x3 = event
 * list or 0, x4 = upcall flags, x5 = event count or -1. On the first run
 * (no REUSE flag) this library builds the pthread_t in place at self; on
 * every run it sets TSD slot 4 from the flags and calls one libdispatch
 * callback:
 *
 *   WORKLOOP: workloop_cb(&id, &events, &n), id from x3 - 8, then
 *             workq_kernreturn(THREAD_WORKLOOP_RETURN, events, n);
 *   KEVENT:   kevent_cb(&events, &n), then THREAD_KEVENT_RETURN;
 *   plain:    workq_cb(pthread_priority_t), then THREAD_RETURN.
 *
 * The *_RETURN calls do not return on success: the kernel restarts the
 * thread at start_wqthread for the next piece of work, or parks it. x5 = -1
 * asks the thread to exit; it then leaves through bsdthread_terminate like
 * any detached thread, giving the kernel back its 560 KiB region.
 *
 * Interface note: the layout of the configuration record that
 * pthread_workqueue_setup receives is not in the specs yet. Ycode reads it
 * as { u32 version; u32 flags; workq_cb; kevent_cb; workloop_cb;
 * u64 queue_serialno_offset; u64 queue_label_offset (version >= 2) }, and
 * also accepts version and flags in the opposite order (flags must be 0).
 */
#include "yc_pthread.h"

typedef void (*yc_workq_fn)(yc_u64 priority);
typedef void (*yc_kevent_fn)(void **events, int *nevents);
typedef void (*yc_workloop_fn)(yc_u64 *workloop_id, void **events, int *nevents);

static int errno_or(int fallback)
{
    int e = *YC_KFN(__error)();
    return e ? e : fallback;
}

/* ---- the worker entry ---------------------------------------------------- */

/* The pthread_priority_t of an upcall (threads-and-events.md 2.6). */
static yc_u64 upcall_priority(yc_u32 flags)
{
    yc_u64 pp = 0;
    yc_u32 prio = flags & YC_WQ_FLAG_THREAD_PRIO_MASK;
    if (flags & YC_WQ_FLAG_THREAD_EVENT_MANAGER)
        return YC_PP_EVENT_MANAGER;
    if (flags & YC_WQ_FLAG_THREAD_PRIO_QOS) {
        if (prio == YC_WQ_EVENT_MANAGER_QOS)
            return YC_PP_EVENT_MANAGER;
        if (prio >= 1 && prio <= 6)
            pp = (1ul << (8 + prio - 1)) | YC_PP_RELPRI_MASK;
    } else if (flags & YC_WQ_FLAG_THREAD_PRIO_SCHED) {
        pp = YC_PP_SCHED_PRI | prio;
    }
    if (flags & YC_WQ_FLAG_THREAD_OVERCOMMIT)
        pp |= YC_PP_OVERCOMMIT;
    if (flags & YC_WQ_FLAG_THREAD_KEVENT)
        pp |= YC_PP_NEEDS_UNBIND;
    if (flags & YC_WQ_FLAG_THREAD_COOPERATIVE)
        pp |= YC_PP_COOPERATIVE;
    return pp;
}

/* First run: builds the pthread_t of a kernel-created worker in place. */
static void worker_setup(yc_pthread_t self, yc_u32 port, yc_uintptr_t stackbottom)
{
    /* Zero the whole block by hand: a memset here becomes a call to bzero,
     * which this library does not import. */
    volatile yc_u64 *w = (volatile yc_u64 *)self;
    for (yc_size_t i = 0; i < sizeof *self / 8; i++)
        w[i] = 0;
    self->tsd[YC_TSD_SELF] = (yc_uintptr_t)self;
    self->tsd[YC_TSD_ERRNO] = (yc_uintptr_t)&self->err_no;
    self->tsd[YC_TSD_MACH_THREAD_SELF] = port;
    self->tsd[YC_TSD_PTR_MUNGE] = __yc_pt.munge_token;
    self->sig = (long)((yc_uintptr_t)self ^ __yc_pt.munge_token);
    self->stackaddr = (yc_uintptr_t)self;
    self->stackbottom = stackbottom;
    /* The kernel's region: guard page below the stack, the pthread_t at
     * the top; given back to the kernel when the worker exits. */
    self->freeaddr = stackbottom - YC_WQ_GUARD_SIZE;
    self->freesize = (((yc_uintptr_t)self + YC_PTHREAD_SIZE + YC_PAGE_SIZE - 1) & ~(YC_PAGE_SIZE - 1)) -
                     self->freeaddr;
    self->guardsize = YC_WQ_GUARD_SIZE;
    self->policy = YC_SCHED_OTHER;
    self->sched_priority = __yc_pt.user_priority;
    self->cancel_state = YC_PTHREAD_CANCEL_ENABLE | YC_PTHREAD_CANCEL_DEFERRED;
    self->exit_gate = port;
    yc_u64 id = YC_KFN(__thread_selfid)();
    self->thread_id = (id == 0 || id == ~0ull) ? (yc_u64)port : id;
    self->flags = YC_TF_DEFAULTS_SET | YC_TF_DETACHED | YC_TF_WORKQ;
    YC_STORE(&YC_FN(__is_threaded), 1);
    __atomic_fetch_add(&__yc_pt.thread_count, 1, __ATOMIC_RELAXED);
    __yc_list_add(self);
}

/* A later run: state that must not leak from the previous work item. */
static void worker_reuse(yc_pthread_t self)
{
    self->cleanup_stack = YC_NULL;
    self->exit_value = YC_NULL;
    self->canceled = 0;
    self->cancel_state = YC_PTHREAD_CANCEL_ENABLE | YC_PTHREAD_CANCEL_DEFERRED;
    self->name[0] = 0;
}

/* Takes one pending cooperative request at this QoS (see addthreads). */
static yc_bool take_cooperative(yc_u32 qos)
{
    if (qos < 1 || qos > 6)
        return 0;
    yc_u32 n = YC_LOAD(&__yc_pt.coop_pending[qos]);
    while (n != 0)
        if (__atomic_compare_exchange_n(&__yc_pt.coop_pending[qos], &n, n - 1, 0, __ATOMIC_ACQ_REL,
                                        __ATOMIC_RELAXED))
            return 1;
    return 0;
}

static YC_NORETURN void worker_return(int op, void *events, int nevents)
{
    YC_KFN(__workq_kernreturn)(op, events, nevents, 0);
    /* The kernel refused the change list: give the thread back without it
     * (the events stay registered), then as a plain worker. */
    if (op != YC_WQOPS_THREAD_RETURN) {
        YC_KFN(__workq_kernreturn)(op, YC_NULL, 0, 0);
        YC_KFN(__workq_kernreturn)(YC_WQOPS_THREAD_RETURN, YC_NULL, 0, 0);
    }
    __yc_fatal("workq_kernreturn returned to a workqueue thread");
}

YC_EXPORT YC_NORETURN void YC_FN(_pthread_wqthread)(yc_pthread_t self, yc_u32 kport, void *stackbottom,
                                                    void *keventlist, yc_u32 flags, int nevents)
{
#ifndef YC_HOST_TEST
    yc_uintptr_t base;
    __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(base));
    if (base != (yc_uintptr_t)&self->tsd[0])
        YC_KFN(_thread_set_tsd_base)(&self->tsd[0]);
#endif
    if (!(flags & YC_WQ_FLAG_THREAD_REUSE) || self->tsd[YC_TSD_SELF] != (yc_uintptr_t)self)
        worker_setup(self, kport, (yc_uintptr_t)stackbottom);
    else
        worker_reuse(self);

    if (nevents == -1) /* the kernel retires this worker */
        __yc_thread_exit(self, YC_NULL);

    yc_u64 pp = upcall_priority(flags);
    yc_bool plain = !(flags & (YC_WQ_FLAG_THREAD_KEVENT | YC_WQ_FLAG_THREAD_WORKLOOP |
                               YC_WQ_FLAG_THREAD_OVERCOMMIT | YC_WQ_FLAG_THREAD_COOPERATIVE |
                               YC_WQ_FLAG_THREAD_EVENT_MANAGER));
    if (plain && (flags & YC_WQ_FLAG_THREAD_PRIO_QOS) &&
        take_cooperative(flags & YC_WQ_FLAG_THREAD_PRIO_MASK))
        pp |= YC_PP_COOPERATIVE;
    self->tsd[YC_TSD_QOS] = pp;
    self->wq_outsideqos = (flags & YC_WQ_FLAG_THREAD_OUTSIDEQOS) != 0;
    self->wq_nevents = nevents;

    if (flags & YC_WQ_FLAG_THREAD_WORKLOOP) {
        yc_workloop_fn cb = (yc_workloop_fn)YC_LOAD_ACQ(&__yc_pt.workq_funcs[2]);
        void *events = keventlist;
        int n = nevents;
        if (cb == YC_NULL)
            __yc_fatal("workloop upcall without a registered workloop callback");
        if (events != YC_NULL) {
            yc_u64 id = *(const yc_u64 *)((const char *)events - 8);
            cb(&id, &events, &n);
        } else {
            n = 0; /* the kernel's scan failed: nothing to run */
        }
        worker_return(YC_WQOPS_THREAD_WORKLOOP_RETURN, events, n);
    }
    if (flags & YC_WQ_FLAG_THREAD_KEVENT) {
        yc_kevent_fn cb = (yc_kevent_fn)YC_LOAD_ACQ(&__yc_pt.workq_funcs[1]);
        void *events = keventlist;
        int n = events ? nevents : 0;
        if (cb == YC_NULL)
            __yc_fatal("kevent upcall without a registered kevent callback");
        cb(&events, &n);
        worker_return(YC_WQOPS_THREAD_KEVENT_RETURN, events, n);
    }
    yc_workq_fn cb = (yc_workq_fn)YC_LOAD_ACQ(&__yc_pt.workq_funcs[0]);
    if (cb == YC_NULL)
        __yc_fatal("workqueue upcall without a registered worker callback");
    cb(pp);
    worker_return(YC_WQOPS_THREAD_RETURN, YC_NULL, 0);
}

/* ---- registration --------------------------------------------------------- */

/* The SETUP_DISPATCH record (threads-and-events.md 2.3, 24 bytes). */
struct __attribute__((packed, aligned(4))) yc_wq_dispatch_config {
    yc_u32 version;
    yc_u32 flags;
    yc_u64 queue_serialno_offset;
    yc_u64 queue_label_offset;
};
_Static_assert(sizeof(struct yc_wq_dispatch_config) == 24, "SETUP_DISPATCH record is 24 bytes");
#define YC_WQ_DISPATCH_CONFIG_VERSION 2

/* Registers the callbacks once. A second registration with the same
 * callbacks succeeds; different ones get EBUSY. `newapi` selects the
 * SETUP_DISPATCH record; otherwise the legacy NEWSPISUPP form is used. */
static int register_callbacks(void *workq, void *kevent, void *workloop, yc_bool newapi, yc_u64 serialno,
                              yc_u64 label)
{
    __yc_self_ready();
    __yc_lock(&__yc_pt.workq_lock);
    if (__yc_pt.workq_ready) {
        int same = __yc_pt.workq_funcs[0] == workq && __yc_pt.workq_funcs[1] == kevent &&
                   __yc_pt.workq_funcs[2] == workloop;
        __yc_unlock(&__yc_pt.workq_lock);
        return same ? 0 : YC_EBUSY;
    }
    int r;
    if (newapi) {
        struct yc_wq_dispatch_config rec = { YC_WQ_DISPATCH_CONFIG_VERSION, 0, serialno, label };
        r = YC_KFN(__workq_kernreturn)(YC_WQOPS_SETUP_DISPATCH, &rec, (int)sizeof rec, 0);
    } else {
        r = YC_KFN(__workq_kernreturn)(YC_WQOPS_QUEUE_NEWSPISUPP, YC_NULL, (int)serialno, kevent ? 1 : 0);
    }
    if (r == -1) {
        int e = errno_or(YC_EINVAL);
        /* A kernel without the workqueue still lets programs that never
         * request a worker run; anything else is a real refusal. */
        if (e != YC_ENOSYS) {
            __yc_unlock(&__yc_pt.workq_lock);
            return e;
        }
    }
    __yc_pt.workq_serialno_offset = serialno;
    __yc_pt.workq_label_offset = label;
    __yc_pt.workq_funcs[1] = kevent;
    __yc_pt.workq_funcs[2] = workloop;
    __atomic_store_n(&__yc_pt.workq_funcs[0], workq, __ATOMIC_RELEASE);
    __yc_pt.workq_ready = 1;
    (void)YC_KFN(__workq_open)();
    YC_STORE(&YC_FN(__is_threaded), 1);
    __yc_unlock(&__yc_pt.workq_lock);
    return 0;
}

YC_EXPORT int YC_FN(pthread_workqueue_setup)(const void *config, yc_size_t size)
{
    if (config == YC_NULL || size < 8)
        return YC_EINVAL;
    const yc_u32 *hdr = config;
    yc_u32 version, flags;
    if (hdr[0] >= 1 && hdr[0] <= 2) {
        version = hdr[0];
        flags = hdr[1];
    } else if (hdr[0] == 0 && hdr[1] >= 1 && hdr[1] <= 2) {
        version = hdr[1];
        flags = hdr[0];
    } else {
        return YC_EINVAL;
    }
    yc_size_t need = version >= 2 ? 48 : 40;
    if (size < need)
        return YC_EINVAL;
    if (flags != 0)
        return YC_ENOTSUP;
    void *const *cbs = (void *const *)((const char *)config + 8);
    const yc_u64 *offs = (const yc_u64 *)((const char *)config + 32);
    return register_callbacks(cbs[0], cbs[1], cbs[2], 1, offs[0], version >= 2 ? offs[1] : 0);
}

YC_EXPORT int YC_FN(_pthread_workqueue_init_with_workloop)(void *queue_func, void *kevent_func, void *workloop_func,
                                                           int offset, int flags)
{
    if (flags != 0)
        return YC_ENOTSUP;
    return register_callbacks(queue_func, kevent_func, workloop_func, 0, (yc_u64)(yc_i64)offset, 0);
}

YC_EXPORT int YC_FN(_pthread_workqueue_init_with_kevent)(void *queue_func, void *kevent_func, int offset, int flags)
{
    return YC_FN(_pthread_workqueue_init_with_workloop)(queue_func, kevent_func, YC_NULL, offset, flags);
}

YC_EXPORT int YC_FN(_pthread_workqueue_init)(void *func, int offset, int flags)
{
    return YC_FN(_pthread_workqueue_init_with_workloop)(func, YC_NULL, YC_NULL, offset, flags);
}

YC_EXPORT int YC_FN(_pthread_workqueue_supported)(void)
{
    /* The Ycode baseline (host-library-init.md 6.4) if registration did
     * not happen, because libdispatch treats 0 as fatal. */
    yc_i64 f = YC_LOAD(&__yc_pt.features);
    return f > 0 ? (int)f : 0x4000001F;
}

YC_EXPORT int YC_FN(__pthread_workqueue_setkill)(int enable)
{
    __yc_pt.workq_setkill = enable != 0;
    return 0;
}

YC_EXPORT int YC_FN(_pthread_workqueue_allow_send_signals)(int sig)
{
    __yc_pt.workq_allowed_signal = sig;
    return 0;
}

/* ---- thread requests ------------------------------------------------------ */

/* Keeps what the kernel reads from a request priority: the QoS, the
 * relative priority, and the overcommit type (section 2.3, 2.4). */
static int request_priority(yc_u64 pp, yc_bool keep_overcommit)
{
    yc_u64 keep = YC_PP_QOS_MASK | YC_PP_RELPRI_MASK | (keep_overcommit ? YC_PP_OVERCOMMIT : 0);
    return (int)(yc_u32)(pp & keep);
}

YC_EXPORT int YC_FN(_pthread_workqueue_addthreads)(int numthreads, yc_u64 priority)
{
    if (!YC_LOAD_ACQ(&__yc_pt.workq_ready))
        return YC_EPERM;
    if (numthreads <= 0)
        return 0;
    if (YC_KFN(__workq_kernreturn)(YC_WQOPS_QUEUE_REQTHREADS, YC_NULL, numthreads,
                                   request_priority(priority, 1)) == -1)
        return errno_or(YC_EINVAL);
    return 0;
}

/* Cooperative requests (REQTHREADS2, one thread per call). A kernel without
 * the cooperative pool refuses them; Ycode then asks for a constrained
 * worker at that QoS and marks the next plain worker of that QoS
 * cooperative, so the cooperative root queue is still drained. */
YC_EXPORT int YC_FN(_pthread_workqueue_add_cooperativethreads)(int numthreads, yc_u64 priority)
{
    if (!YC_LOAD_ACQ(&__yc_pt.workq_ready))
        return YC_EPERM;
    int pp = request_priority(priority, 0);
    yc_u32 qos = 0;
    for (yc_u32 q = 1; q <= 6; q++)
        if ((yc_u32)pp & (1u << (8 + q - 1))) {
            qos = q;
            break;
        }
    for (int i = 0; i < numthreads; i++) {
        if (YC_KFN(__workq_kernreturn)(YC_WQOPS_QUEUE_REQTHREADS2, YC_NULL, 1, pp) == 0)
            continue;
        int e = errno_or(YC_EINVAL);
        if ((e != YC_ENOTSUP && e != YC_EINVAL && e != YC_ENOSYS) || qos == 0)
            return e;
        __atomic_fetch_add(&__yc_pt.coop_pending[qos], 1, __ATOMIC_RELEASE);
        if (YC_KFN(__workq_kernreturn)(YC_WQOPS_QUEUE_REQTHREADS, YC_NULL, 1, pp) == -1) {
            __atomic_fetch_sub(&__yc_pt.coop_pending[qos], 1, __ATOMIC_RELAXED);
            return errno_or(YC_EINVAL);
        }
    }
    return 0;
}

YC_EXPORT int YC_FN(_pthread_workqueue_should_narrow)(yc_u64 priority)
{
    /* Only a constrained workqueue thread may ask (section 2.3). */
    yc_pthread_t self = __yc_self();
    if (!(self->flags & YC_TF_WORKQ) || (self->tsd[YC_TSD_QOS] & YC_PP_OVERCOMMIT))
        return 0;
    int r = YC_KFN(__workq_kernreturn)(YC_WQOPS_SHOULD_NARROW, YC_NULL, request_priority(priority, 0), 0);
    return r == 1;
}

YC_EXPORT int YC_FN(_pthread_workqueue_set_event_manager_priority)(yc_u64 priority)
{
    if (YC_KFN(__workq_kernreturn)(YC_WQOPS_SET_EVENT_MANAGER_PRIORITY, YC_NULL, (int)(yc_u32)priority, 0) == -1)
        return errno_or(YC_EINVAL);
    return 0;
}

/* ---- workloops with fixed scheduling parameters (section 2.9) ------------- */

struct __attribute__((packed)) yc_workloop_params {
    yc_i32 version;
    yc_i32 flags;
    yc_u64 id;
    yc_i32 sched_pri;
    yc_i32 sched_pol;
    yc_i32 cpu_percent;
    yc_i32 cpu_refillms;
    yc_u32 work_interval_port;
};
_Static_assert(sizeof(struct yc_workloop_params) == 36, "kqueue_workloop_ctl params are 36 bytes");

YC_EXPORT int YC_FN(_pthread_workloop_create)(yc_u64 workloop_id, yc_u64 options, const struct yc_attr *a)
{
    (void)options;
    if (a != YC_NULL && a->sig != YC_SIG_ATTR)
        return YC_EINVAL;
    struct yc_workloop_params p;
    __builtin_memset(&p, 0, sizeof p);
    p.version = (yc_i32)sizeof p;
    p.id = workloop_id;
    if (a != YC_NULL && (a->flags & YC_ATTR_SCHED_SET)) {
        p.flags |= YC_KQ_WORKLOOP_SCHED_PRI | YC_KQ_WORKLOOP_SCHED_POL;
        p.sched_pri = a->sched_priority;
        p.sched_pol = a->policy;
    }
    if (a != YC_NULL && (a->flags & YC_ATTR_CPUPERCENT_SET)) {
        p.flags |= YC_KQ_WORKLOOP_CPU_PERCENT;
        p.cpu_percent = a->cpupercent;
        p.cpu_refillms = (yc_i32)a->refillms;
    }
    if (YC_KFN(__kqueue_workloop_ctl)(YC_KQ_WORKLOOP_CREATE, 0, &p, sizeof p) == -1)
        return errno_or(YC_EINVAL);
    return 0;
}

YC_EXPORT int YC_FN(_pthread_workloop_destroy)(yc_u64 workloop_id, yc_u64 options)
{
    (void)options;
    struct yc_workloop_params p;
    __builtin_memset(&p, 0, sizeof p);
    p.version = (yc_i32)sizeof p;
    p.id = workloop_id;
    if (YC_KFN(__kqueue_workloop_ctl)(YC_KQ_WORKLOOP_DESTROY, 0, &p, sizeof p) == -1)
        return errno_or(YC_EINVAL);
    return 0;
}
