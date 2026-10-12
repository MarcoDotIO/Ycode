/*
 * yc_pthread.h - internal declarations of Ycode's libsystem_pthread.
 *
 * Clean-room Ycode code, written from specs/simulator/host-libraries.md
 * (sections 7-8), specs/simulator/host-library-init.md (sections 1-7 and
 * 9.4), specs/simulator/host-library-surface.md, and the public POSIX
 * threads and Darwin pthread API documentation (man pages, the public
 * <pthread.h>, <pthread/qos.h> and <sys/qos.h> constants).
 *
 * Design rule (host-libraries.md section 7.1): nothing here depends on
 * __pthread_init having run. Every function works from the main-thread
 * block that the VMM builds before boot (section 8.3): TPIDRRO_EL0 points at
 * TSD slot 0, and the pthread_t is that address minus 224. libc takes its
 * stdio locks (pthread_mutex_lock/unlock) before __pthread_init runs
 * (section 8.2), so the lock and identity paths never require it.
 */
#ifndef YC_PTHREAD_H
#define YC_PTHREAD_H

#include "yc_base.h"
#include "yc_kernel_api.h"

/* ---- Darwin errno values not in yc_base.h ---------------------------- */
#define YC_ESRCH 3
#define YC_EDEADLK 11
#define YC_ENAMETOOLONG 63

/* ---- public constants (Darwin <pthread.h>, <sched.h>, <sys/qos.h>) ---- */
#define YC_PTHREAD_CREATE_JOINABLE 1
#define YC_PTHREAD_CREATE_DETACHED 2
#define YC_PTHREAD_INHERIT_SCHED 1
#define YC_PTHREAD_EXPLICIT_SCHED 2
#define YC_PTHREAD_CANCEL_ENABLE 0x01
#define YC_PTHREAD_CANCEL_DISABLE 0x00
#define YC_PTHREAD_CANCEL_DEFERRED 0x02
#define YC_PTHREAD_CANCEL_ASYNCHRONOUS 0x00
#define YC_PTHREAD_CANCELED ((void *)1)
#define YC_PTHREAD_SCOPE_SYSTEM 1
#define YC_PTHREAD_SCOPE_PROCESS 2
#define YC_PTHREAD_PROCESS_SHARED 1
#define YC_PTHREAD_PROCESS_PRIVATE 2
#define YC_PTHREAD_MUTEX_NORMAL 0
#define YC_PTHREAD_MUTEX_ERRORCHECK 1
#define YC_PTHREAD_MUTEX_RECURSIVE 2
#define YC_PTHREAD_PRIO_NONE 0
#define YC_PTHREAD_PRIO_INHERIT 1
#define YC_PTHREAD_PRIO_PROTECT 2
#define YC_PTHREAD_MUTEX_POLICY_FAIRSHARE_NP 1
#define YC_PTHREAD_MUTEX_POLICY_FIRSTFIT_NP 3
#define YC_PTHREAD_STACK_MIN 16384ul
#define YC_PTHREAD_DESTRUCTOR_ITERATIONS 4
#define YC_SCHED_OTHER 1
#define YC_SCHED_RR 2
#define YC_SCHED_FIFO 4
#define YC_NSIG 32

/* qos_class_t values. */
#define YC_QOS_CLASS_USER_INTERACTIVE 0x21
#define YC_QOS_CLASS_USER_INITIATED 0x19
#define YC_QOS_CLASS_DEFAULT 0x15
#define YC_QOS_CLASS_UTILITY 0x11
#define YC_QOS_CLASS_BACKGROUND 0x09
#define YC_QOS_CLASS_MAINTENANCE 0x05
#define YC_QOS_CLASS_UNSPECIFIED 0x00
#define YC_QOS_MIN_RELATIVE_PRIORITY (-15)

/* ---- sizes and signatures (host-library-init.md section 5.3) ---------- */
#define YC_SIG_MUTEX_INIT 0x32AAABA7l
#define YC_SIG_ERRORCHECK_MUTEX_INIT 0x32AAABA1l
#define YC_SIG_RECURSIVE_MUTEX_INIT 0x32AAABA2l
#define YC_SIG_FIRSTFIT_MUTEX_INIT 0x32AAABA3l
#define YC_SIG_COND_INIT 0x3CB0B1BBl
#define YC_SIG_ONCE_INIT 0x30B1BCBAl
#define YC_SIG_RWLOCK_INIT 0x2DA8B3B4l
#define YC_SIG_ATTR 0x54484441l      /* 'THDA' */
#define YC_SIG_MUTEX 0x4D555458l     /* 'MUTX' */
#define YC_SIG_MUTEXATTR 0x4D545841l /* 'MTXA' */
#define YC_SIG_COND 0x434F4E44l      /* 'COND' */
#define YC_SIG_CONDATTR 0x434E4441l  /* 'CNDA' */
#define YC_SIG_ONCE 0x4F4E4345l      /* 'ONCE' */
#define YC_SIG_RWLOCK 0x52574C4Bl    /* 'RWLK' */
#define YC_SIG_RWLOCKATTR 0x52574C41l/* 'RWLA' */

/* ---- TSD (host-library-init.md section 3) ----------------------------- */
#define YC_TSD_SLOTS 768
#define YC_TSD_FIRST_STATIC_KEY 10
#define YC_TSD_FIRST_DYNAMIC_KEY 256
#define YC_TSD_SELF 0
#define YC_TSD_ERRNO 1
#define YC_TSD_MIG_REPLY 2
#define YC_TSD_MACH_THREAD_SELF 3
#define YC_TSD_QOS 4
#define YC_TSD_RETURN_TO_KERNEL 5
#define YC_TSD_PTR_MUNGE 7
#define YC_TSD_MACH_SPECIAL_REPLY 8
#define YC_TSD_SEMAPHORE_CACHE 9
#define YC_TSD_DISPATCH_QUEUE 20
#define YC_TSD_WQ_QUANTUM 120

/* ---- struct pthread_s (host-library-init.md section 5.1) -------------- */
struct yc_pthread {
    long sig;                    /*   0  self XOR munge token */
    void *cleanup_stack;         /*   8  read inline by clients */
    struct yc_pthread *next;     /*  16 */
    struct yc_pthread *prev;     /*  24 */
    void *join_ctx;              /*  32 */
    void *exit_value;            /*  40 */
    yc_u8 policy;                /*  48 */
    yc_u8 detach_flags;          /*  49  bit 0 joinable (kernel-visible bit 392) */
    yc_u16 introspection;        /*  50 */
    yc_u32 exit_gate;            /*  52 */
    yc_i32 sched_priority;       /*  56 */
    yc_i32 sched_pad;            /*  60 */
    void *unused;                /*  64 */
    yc_u32 lock;                 /*  72 */
    yc_u16 max_tsd_key;          /*  76 */
    yc_u16 flags;                /*  78  Ycode: YC_TF_* */
    char name[64];               /*  80 */
    void *start_routine;         /* 144 */
    void *start_arg;             /* 152 */
    yc_i32 wq_nevents;           /* 160 */
    yc_u8 wq_outsideqos;         /* 164 */
    yc_u8 canceled;              /* 165 */
    yc_u16 cancel_state;         /* 166 */
    yc_i32 cancel_error;         /* 168 */
    yc_i32 err_no;               /* 172  slot 1 points here */
    yc_uintptr_t stackaddr;      /* 176  top (TSD - 48) */
    yc_uintptr_t stackbottom;    /* 184  (TSD - 40) */
    yc_uintptr_t freeaddr;       /* 192 */
    yc_size_t freesize;          /* 200 */
    yc_size_t guardsize;         /* 208 */
    yc_u64 thread_id;            /* 216  (TSD - 8) */
    yc_uintptr_t tsd[YC_TSD_SLOTS] __attribute__((aligned(16))); /* 224 */
};
#define YC_PTHREAD_TSD_OFFSET 224
#define YC_PTHREAD_SIZE 16384 /* sizeof rounded up to a 16 KiB page */

_Static_assert(__builtin_offsetof(struct yc_pthread, cleanup_stack) == 8, "cleanup stack at +8");
_Static_assert(__builtin_offsetof(struct yc_pthread, detach_flags) == 49, "joinable byte at +49");
_Static_assert(__builtin_offsetof(struct yc_pthread, lock) == 72, "lock at +72");
_Static_assert(__builtin_offsetof(struct yc_pthread, name) == 80, "name at +80");
_Static_assert(__builtin_offsetof(struct yc_pthread, err_no) == 172, "err_no at +172");
_Static_assert(__builtin_offsetof(struct yc_pthread, stackaddr) == 176, "stackaddr at +176");
_Static_assert(__builtin_offsetof(struct yc_pthread, stackbottom) == 184, "stackbottom at +184");
_Static_assert(__builtin_offsetof(struct yc_pthread, thread_id) == 216, "thread_id at +216");
_Static_assert(__builtin_offsetof(struct yc_pthread, tsd) == 224, "tsd at +224");
_Static_assert(sizeof(struct yc_pthread) == 6368, "pthread_s is 6368 bytes");

/* Ycode flags in yc_pthread.flags. */
#define YC_TF_DEFAULTS_SET 0x0001 /* default attributes applied */
#define YC_TF_EXITING 0x0002
#define YC_TF_DETACHED 0x0004
#define YC_TF_MAIN 0x0008

typedef struct yc_pthread *yc_pthread_t;

/*
 * The one accessor for the TSD base. In the guest it reads TPIDRRO_EL0; if
 * the VMM did not set it (base 0), a static fallback block inside this
 * library is used (host-library-init.md section 9.1 B), so no caller ever
 * dereferences address 0. The host tests supply a per-thread fake.
 */
#ifdef YC_HOST_TEST
yc_uintptr_t *yc_testk_tsd_base(void);
static inline yc_uintptr_t *__yc_tsd(void) { return yc_testk_tsd_base(); }
#else
YC_HIDDEN yc_uintptr_t *__yc_fallback_tsd(void);
static inline yc_uintptr_t *__yc_tsd(void)
{
    yc_uintptr_t v;
    __asm__("mrs %0, tpidrro_el0" : "=r"(v));
    if (YC_UNLIKELY(v == 0))
        return __yc_fallback_tsd();
    return (yc_uintptr_t *)v;
}
#endif

static inline yc_pthread_t __yc_self(void)
{
    return (yc_pthread_t)((char *)__yc_tsd() - YC_PTHREAD_TSD_OFFSET);
}

static inline yc_pthread_t __yc_from_tsd(yc_uintptr_t *tsd)
{
    return (yc_pthread_t)((char *)tsd - YC_PTHREAD_TSD_OFFSET);
}

/* ---- library state (init.c) ------------------------------------------- */
struct yc_pthread_globals {
    yc_pthread_t main_thread;    /* NULL until adopted */
    yc_u32 list_lock;            /* yc lock word */
    yc_u32 thread_count;
    yc_uintptr_t munge_token;
    yc_u64 main_qos;             /* pthread_priority_t of the main thread */
    yc_i64 features;             /* bsdthread_register result (0 = none) */
    yc_uintptr_t stack_addr_hint;
    yc_u32 mutex_default_policy;
    yc_i32 user_priority, min_priority, max_priority;
    void (*exit_fn)(int);
    void *(*malloc_fn)(yc_size_t);
    void (*free_fn)(void *);
    yc_bool registered;
    yc_bool init_done;
    yc_bool late_init_done;
    yc_bool yield_to_zero;
    void *introspection_hook;
    void *workq_config;          /* pthread_workqueue_setup record */
    yc_size_t workq_config_size;
    void *workq_funcs[3];
    yc_i32 workq_offset;
    yc_bool workq_setkill;
    yc_i32 workq_allowed_signal;
    void *workgroup_functions;
    yc_i32 concurrency;
};
YC_HIDDEN extern struct yc_pthread_globals __yc_pt;

/* is __is_threaded, an exported int (data.c). */
extern int YC_FN(__is_threaded);

/* The main thread (adopting the calling thread's block if nothing was
 * adopted yet: before __pthread_init only the main thread can run). */
YC_HIDDEN yc_pthread_t __yc_main_thread(void);
/* Applies the default attributes to a thread block once (idempotent). */
YC_HIDDEN void __yc_thread_defaults(yc_pthread_t t);
/* Self, with the default attributes applied. */
YC_HIDDEN yc_pthread_t __yc_self_ready(void);
/* Is t a live thread of this process? */
YC_HIDDEN yc_bool __yc_thread_valid(yc_pthread_t t);
/* Runs the TSD destructors of the calling thread (tsd.c). */
YC_HIDDEN void __yc_tsd_run_destructors(yc_pthread_t self);
/* Writes "libsystem_pthread: <msg>\n" to fd 2 and crashes. */
YC_HIDDEN YC_NORETURN void __yc_fatal(const char *msg);

/* Cross-file exported functions. */
YC_EXPORT void YC_FN(pthread_testcancel)(void);

/* ---- internal futex-style lock (lowlock.c) ---------------------------- */
/* Word: 0 unlocked, 1 locked, 2 locked and contended. */
YC_HIDDEN void __yc_lock(yc_u32 *word);
YC_HIDDEN yc_bool __yc_trylock(yc_u32 *word);
YC_HIDDEN void __yc_unlock(yc_u32 *word);
/* Wait while *addr == value. timeout_ns 0 = forever. Returns 0, or a
 * negative errno (-ETIMEDOUT, -EINTR, -ENOSYS, ...). */
YC_HIDDEN int __yc_wait32(yc_u32 *addr, yc_u32 value, yc_u64 timeout_ns);
YC_HIDDEN void __yc_wake32(yc_u32 *addr, yc_bool all);
/* Real time in nanoseconds since the epoch (0 if unknown). */
YC_HIDDEN yc_u64 __yc_realtime_ns(void);

/* ---- QoS helpers (qos.c) ---------------------------------------------- */
YC_HIDDEN int __yc_qos_index(unsigned qos_class);   /* -1 if invalid */
YC_HIDDEN unsigned __yc_qos_class(int index);
YC_HIDDEN yc_u64 __yc_pp_make(int index, int relpri, yc_u64 flags);
YC_HIDDEN unsigned __yc_pp_decode(yc_u64 pp, int *relpri, yc_u64 *flags);
#define YC_PP_DEFAULT 0x8FFul /* LEGACY/default QoS, relpri 0 */
#define YC_PP_FLAGS_MASK 0xFF000000ul

/* ---- string helpers (init.c) ------------------------------------------ */
YC_HIDDEN yc_size_t __yc_strlen(const char *s);
YC_HIDDEN const char *__yc_getenv(const char **vec, const char *key);

/* ---- libsystem_kernel functions used by pthread ----------------------- */
int YC_KFN(__bsdthread_register)(void *thread_start, void *start_wqthread, int pthread_size,
                                 void *record, int record_size, long dispatch_queue_offset);
yc_u64 YC_KFN(__thread_selfid)(void);
void YC_KFN(_thread_set_tsd_base)(void *base);
yc_u32 YC_KFN(mach_thread_self)(void);
yc_u32 YC_KFN(mach_reply_port)(void);
int YC_KFN(__pthread_kill)(yc_u32 thread_port, int sig);
int YC_KFN(__pthread_chdir)(const char *path);
int YC_KFN(__pthread_fchdir)(int fd);
int YC_KFN(__sigwait)(const yc_u32 *set, int *sig);
struct yc_timeval { long tv_sec; yc_i32 tv_usec; };
int YC_KFN(__gettimeofday)(struct yc_timeval *tv, void *tz, yc_u64 *mach_time);
YC_NORETURN void YC_KFN(_exit)(int status);

/* Thread entry points registered with the kernel. They are generated
 * stubs until threads exist (they trap with their own name). */
void YC_KFN(thread_start)(void);
void YC_KFN(start_wqthread)(void);

/* The symbol name of a "$NOCANCEL" variant (C identifiers cannot hold
 * '$' portably, so the name is given as an assembler label). */
#ifdef YC_HOST_TEST
#define YC_NOCANCEL_NAME(name) __asm__("yc_test_" #name "_nocancel")
#else
#define YC_NOCANCEL_NAME(name) __asm__("_" #name "$NOCANCEL")
#endif

/* Atomics shorthands. */
#define YC_LOAD(p) __atomic_load_n((p), __ATOMIC_RELAXED)
#define YC_LOAD_ACQ(p) __atomic_load_n((p), __ATOMIC_ACQUIRE)
#define YC_STORE(p, v) __atomic_store_n((p), (v), __ATOMIC_RELAXED)
#define YC_STORE_REL(p, v) __atomic_store_n((p), (v), __ATOMIC_RELEASE)
#define YC_CAS(p, expp, des) \
    __atomic_compare_exchange_n((p), (expp), (des), 0, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)

#if defined(__aarch64__)
#define YC_CPU_YIELD() __asm__ volatile("yield" ::: "memory")
#else
#define YC_CPU_YIELD() __asm__ volatile("" ::: "memory")
#endif

#endif /* YC_PTHREAD_H */
