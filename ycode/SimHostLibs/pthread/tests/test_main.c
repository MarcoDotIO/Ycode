/*
 * Host-side unit tests for Ycode's libsystem_pthread sources.
 *
 * Clean-room Ycode code. The pthread C sources are compiled for the host
 * with -DYC_HOST_TEST: every exported function becomes yc_test_<name>,
 * every libsystem_kernel function it calls becomes yc_testk_<name>, and
 * the TSD base comes from yc_testk_tsd_base(). This file supplies a fake
 * VMM-built main-thread block per host thread (host-libraries.md section
 * 8.3) and fake kernel calls, then checks the library's behavior. The
 * tests that run before the __pthread_init test check that the library
 * works without it (section 8.2). Run with tests/run.sh.
 *
 * Stage 4a: the fake kernel also creates threads (bsdthread_create starts
 * a host thread at the library's _pthread_start with the spec's argument
 * registers), terminates them (frees what it is asked to, performs the
 * join-gate store and wake), implements compare-and-wait for real, and
 * plays the workqueue (requests start host threads at _pthread_wqthread
 * with the spec's memory layout, upcall flags, event list and workloop ID;
 * the *_RETURN operations rerun or retire the worker). The library code is
 * the real code; only the kernel side is simulated.
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define T(name) yc_test_##name

static int checks, failures;
#define CHECK(cond)                                                              \
    do {                                                                         \
        checks++;                                                                \
        if (!(cond)) {                                                           \
            failures++;                                                          \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);      \
        }                                                                        \
    } while (0)

/* ---- opaque client types (sizes from host-library-init.md 5.3) -------- */
typedef struct { long sig; char opaque[56]; } ymutex_t;
typedef struct { long sig; char opaque[8]; } ymutexattr_t;
typedef struct { long sig; char opaque[40]; } ycond_t;
typedef struct { long sig; char opaque[8]; } ycondattr_t;
typedef struct { long sig; char opaque[8]; } yonce_t;
typedef struct { long sig; char opaque[192]; } yrwlock_t;
typedef struct { long sig; char opaque[16]; } yrwlockattr_t;
typedef struct { long sig; char opaque[56]; } yattr_t;
struct yts { long tv_sec; long tv_nsec; };
struct ysp { int sched_priority; char opaque[4]; };
#define YMUTEX_INIT { 0x32AAABA7, { 0 } }
#define YMUTEX_ERRCHK_INIT { 0x32AAABA1, { 0 } }
#define YMUTEX_RECURSIVE_INIT { 0x32AAABA2, { 0 } }
#define YCOND_INIT { 0x3CB0B1BB, { 0 } }
#define YONCE_INIT { 0x30B1BCBA, { 0 } }
#define YRWLOCK_INIT { 0x2DA8B3B4, { 0 } }

/* ---- declarations of the code under test ------------------------------ */
typedef void *ypthread_t;
ypthread_t T(pthread_self)(void);
ypthread_t T(_pthread_self)(void);
int T(pthread_equal)(ypthread_t, ypthread_t);
int T(pthread_main_np)(void);
ypthread_t T(pthread_main_thread_np)(void);
int T(pthread_threadid_np)(ypthread_t, uint64_t *);
uint32_t T(pthread_mach_thread_np)(ypthread_t);
ypthread_t T(pthread_from_mach_thread_np)(uint32_t);
void *T(pthread_get_stackaddr_np)(ypthread_t);
size_t T(pthread_get_stacksize_np)(ypthread_t);
int T(pthread_current_stack_contains_np)(const void *, size_t);
uintptr_t T(pthread_stack_frame_decode_np)(uintptr_t, uintptr_t *);
int T(pthread_setname_np)(const char *);
int T(pthread_getname_np)(ypthread_t, char *, size_t);
int T(pthread_setcancelstate)(int, int *);
int T(pthread_setcanceltype)(int, int *);
int T(pthread_cancel)(ypthread_t);
void T(pthread_testcancel)(void);
void T(pthread_exit)(void *) __attribute__((noreturn));
int T(pthread_join)(ypthread_t, void **);
int T(pthread_detach)(ypthread_t);
int T(pthread_kill)(ypthread_t, int);
int T(pthread_sigmask)(int, const uint32_t *, uint32_t *);
int T(sched_yield)(void);
int T(sched_get_priority_min)(int);
int T(sched_get_priority_max)(int);
int T(pthread_getschedparam)(ypthread_t, int *, struct ysp *);
int T(pthread_setschedparam)(ypthread_t, int, const struct ysp *);
int T(pthread_setconcurrency)(int);
int T(pthread_getconcurrency)(void);
int T(pthread_is_threaded_np)(void);
void *T(pthread_introspection_hook_install)(void *);
void *T(pthread_introspection_getspecific_np)(ypthread_t, unsigned long);

int T(__pthread_init)(const void *, const char **, const char **, const void *);
void T(__pthread_late_init)(const char **, const char **, const void *);
int T(pthread_atfork)(void (*)(void), void (*)(void), void (*)(void));
void T(_pthread_atfork_prepare_handlers)(void);
void T(_pthread_atfork_parent_handlers)(void);
void T(_pthread_atfork_child_handlers)(void);

void *T(pthread_getspecific)(unsigned long);
int T(pthread_setspecific)(unsigned long, const void *);
int T(_pthread_setspecific_static)(unsigned long, const void *);
int T(pthread_key_init_np)(int, void (*)(void *));
int T(pthread_key_create)(unsigned long *, void (*)(void *));
int T(pthread_key_delete)(unsigned long);
void T(_pthread_clear_qos_tsd)(uint32_t);

int T(pthread_once)(yonce_t *, void (*)(void));

int T(pthread_mutexattr_init)(ymutexattr_t *);
int T(pthread_mutexattr_destroy)(ymutexattr_t *);
int T(pthread_mutexattr_settype)(ymutexattr_t *, int);
int T(pthread_mutexattr_gettype)(const ymutexattr_t *, int *);
int T(pthread_mutexattr_setpshared)(ymutexattr_t *, int);
int T(pthread_mutexattr_getpshared)(const ymutexattr_t *, int *);
int T(pthread_mutexattr_setprotocol)(ymutexattr_t *, int);
int T(pthread_mutexattr_getprotocol)(const ymutexattr_t *, int *);
int T(pthread_mutexattr_setpolicy_np)(ymutexattr_t *, int);
int T(pthread_mutexattr_getpolicy_np)(const ymutexattr_t *, int *);
int T(pthread_mutexattr_setprioceiling)(ymutexattr_t *, int);
int T(pthread_mutexattr_getprioceiling)(const ymutexattr_t *, int *);
int T(pthread_mutex_init)(ymutex_t *, const ymutexattr_t *);
int T(pthread_mutex_destroy)(ymutex_t *);
int T(pthread_mutex_lock)(ymutex_t *);
int T(pthread_mutex_trylock)(ymutex_t *);
int T(pthread_mutex_unlock)(ymutex_t *);
int T(pthread_mutex_getprioceiling)(const ymutex_t *, int *);
int T(pthread_mutex_setprioceiling)(ymutex_t *, int, int *);

int T(pthread_condattr_init)(ycondattr_t *);
int T(pthread_condattr_destroy)(ycondattr_t *);
int T(pthread_condattr_setpshared)(ycondattr_t *, int);
int T(pthread_condattr_getpshared)(const ycondattr_t *, int *);
int T(pthread_cond_init)(ycond_t *, const ycondattr_t *);
int T(pthread_cond_destroy)(ycond_t *);
int T(pthread_cond_signal)(ycond_t *);
int T(pthread_cond_broadcast)(ycond_t *);
int T(pthread_cond_wait)(ycond_t *, ymutex_t *);
int T(pthread_cond_timedwait)(ycond_t *, ymutex_t *, const struct yts *);
int T(pthread_cond_timedwait_relative_np)(ycond_t *, ymutex_t *, const struct yts *);
int yc_cond_wait_nocancel_test(ycond_t *, ymutex_t *) __asm__("yc_test_pthread_cond_wait_nocancel");

int T(pthread_rwlockattr_init)(yrwlockattr_t *);
int T(pthread_rwlockattr_destroy)(yrwlockattr_t *);
int T(pthread_rwlockattr_setpshared)(yrwlockattr_t *, int);
int T(pthread_rwlockattr_getpshared)(const yrwlockattr_t *, int *);
int T(pthread_rwlock_init)(yrwlock_t *, const yrwlockattr_t *);
int T(pthread_rwlock_destroy)(yrwlock_t *);
int T(pthread_rwlock_rdlock)(yrwlock_t *);
int T(pthread_rwlock_tryrdlock)(yrwlock_t *);
int T(pthread_rwlock_wrlock)(yrwlock_t *);
int T(pthread_rwlock_trywrlock)(yrwlock_t *);
int T(pthread_rwlock_unlock)(yrwlock_t *);

int T(pthread_attr_init)(yattr_t *);
int T(pthread_attr_destroy)(yattr_t *);
int T(pthread_attr_setdetachstate)(yattr_t *, int);
int T(pthread_attr_getdetachstate)(const yattr_t *, int *);
int T(pthread_attr_setstacksize)(yattr_t *, size_t);
int T(pthread_attr_getstacksize)(const yattr_t *, size_t *);
int T(pthread_attr_setstack)(yattr_t *, void *, size_t);
int T(pthread_attr_getstack)(const yattr_t *, void **, size_t *);
int T(pthread_attr_getguardsize)(const yattr_t *, size_t *);
int T(pthread_attr_setguardsize)(yattr_t *, size_t);
int T(pthread_attr_setscope)(yattr_t *, int);
int T(pthread_attr_getschedparam)(const yattr_t *, struct ysp *);
int T(pthread_attr_setschedpolicy)(yattr_t *, int);
int T(pthread_attr_set_qos_class_np)(yattr_t *, unsigned, int);
int T(pthread_attr_get_qos_class_np)(const yattr_t *, unsigned *, int *);

unsigned T(qos_class_self)(void);
unsigned T(qos_class_main)(void);
int T(pthread_set_qos_class_self_np)(unsigned, int);
int T(pthread_get_qos_class_np)(ypthread_t, unsigned *, int *);
uint64_t T(_pthread_qos_class_encode)(unsigned, int, unsigned long);
unsigned T(_pthread_qos_class_decode)(uint64_t, int *, unsigned long *);
int T(_pthread_set_properties_self)(unsigned, uint64_t, uint32_t);
int T(_pthread_workqueue_supported)(void);
int T(pthread_workqueue_setup)(const void *, size_t);

struct ydep { uint32_t owner, state; void *value; };
void T(pthread_dependency_init_np)(struct ydep *, ypthread_t, void *);
void T(pthread_dependency_fulfill_np)(struct ydep *, void *);
void *T(pthread_dependency_wait_np)(struct ydep *);

extern int T(__is_threaded);
extern const uint16_t T(pthread_layout_offsets)[4];

/* ---- the fake VMM-built thread block ---------------------------------- */
#define TSD_OFF 224
#define BLOCK_SIZE 8192
static uint32_t next_port = 0x203;
static uint64_t next_tid = 1;
static __thread unsigned char *my_block;

static unsigned char *make_block(void)
{
    unsigned char *b = aligned_alloc(16, BLOCK_SIZE);
    memset(b, 0, BLOCK_SIZE);
    uintptr_t *tsd = (uintptr_t *)(b + TSD_OFF);
    *(uint64_t *)(b + 216) = __atomic_fetch_add(&next_tid, 1, __ATOMIC_RELAXED);
    tsd[0] = (uintptr_t)b;
    tsd[1] = (uintptr_t)(b + 172);
    tsd[3] = __atomic_fetch_add(&next_port, 0x100, __ATOMIC_RELAXED);
    uintptr_t top = (uintptr_t)__builtin_frame_address(0) + 65536;
    *(uintptr_t *)(b + 176) = top;
    *(uintptr_t *)(b + 184) = top - 8 * 1024 * 1024;
    return b;
}

uintptr_t *yc_testk_tsd_base(void)
{
    if (my_block == NULL)
        my_block = make_block();
    return (uintptr_t *)(my_block + TSD_OFF);
}

static uintptr_t *tsd(void) { return yc_testk_tsd_base(); }

/* ---- fake kernel ------------------------------------------------------- */
int *yc_testk___error(void) { yc_testk_tsd_base(); return (int *)(my_block + 172); }

/* A real (host) implementation of the compare-and-wait contract
 * (threads-and-events.md 4.1): the compare and the sleep are atomic with
 * respect to wakes, because both run under one host mutex and every wake
 * advances a generation counter. Timed waits are capped at 20 ms, so a test
 * never waits for a far deadline; an untimed wait returns spuriously after
 * 5 s at most (allowed by the contract), so a lost wake shows up as a slow
 * test, not a hang. */
static pthread_mutex_t ul_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ul_cv = PTHREAD_COND_INITIALIZER;
static unsigned long ul_gen;
static long wake_calls;

static int fake_ulock_wait(uint32_t op, void *addr, uint64_t value, uint64_t timeout_ns)
{
    if (addr == NULL)
        return -22;
    unsigned opcode = op & 0xff;
    pthread_mutex_lock(&ul_mx);
    uint64_t cur = (opcode == 5 || opcode == 6) ? __atomic_load_n((uint64_t *)addr, __ATOMIC_SEQ_CST)
                                                 : __atomic_load_n((uint32_t *)addr, __ATOMIC_SEQ_CST);
    if (cur != value) {
        pthread_mutex_unlock(&ul_mx);
        return 0;
    }
    uint64_t wait_ns = timeout_ns ? (timeout_ns < 20000000ull ? timeout_ns : 20000000ull) : 5000000000ull;
    struct timespec dl;
    clock_gettime(CLOCK_REALTIME, &dl);
    dl.tv_sec += (time_t)(wait_ns / 1000000000ull);
    dl.tv_nsec += (long)(wait_ns % 1000000000ull);
    if (dl.tv_nsec >= 1000000000l) { dl.tv_sec++; dl.tv_nsec -= 1000000000l; }
    unsigned long gen0 = ul_gen;
    int timedout = 0;
    while (ul_gen == gen0)
        if (pthread_cond_timedwait(&ul_cv, &ul_mx, &dl) == ETIMEDOUT) { timedout = 1; break; }
    pthread_mutex_unlock(&ul_mx);
    return (timedout && timeout_ns) ? -60 : 0;
}

int yc_testk___ulock_wait(uint32_t op, void *addr, uint64_t value, uint32_t timeout_us)
{
    return fake_ulock_wait(op, addr, value, (uint64_t)timeout_us * 1000);
}

int yc_testk___ulock_wait2(uint32_t op, void *addr, uint64_t value, uint64_t timeout, uint64_t v2)
{
    (void)v2;
    return fake_ulock_wait(op, addr, value, timeout);
}

int yc_testk___ulock_wake(uint32_t op, void *addr, uint64_t v)
{
    (void)op; (void)addr; (void)v;
    __atomic_fetch_add(&wake_calls, 1, __ATOMIC_RELAXED);
    pthread_mutex_lock(&ul_mx);
    ul_gen++;
    pthread_cond_broadcast(&ul_cv);
    pthread_mutex_unlock(&ul_mx);
    return 0;
}

ssize_t yc_testk_write(int fd, const void *buf, size_t len) { return write(fd, buf, len); }

static uint32_t fake_mask;
int yc_testk_sigprocmask(int how, const uint32_t *set, uint32_t *oset)
{
    if (oset) *oset = fake_mask;
    if (set) {
        if (how == 1) fake_mask |= *set;
        else if (how == 2) fake_mask &= ~*set;
        else if (how == 3) fake_mask = *set;
        else { *yc_testk___error() = 22; return -1; }
    }
    return 0;
}

static int reg_calls;
static unsigned char reg_record[56];
static long reg_args[6];
int yc_testk___bsdthread_register(void *ts, void *wq, int size, void *rec, int recsize, long dqoff)
{
    reg_calls++;
    reg_args[0] = (long)ts; reg_args[1] = (long)wq; reg_args[2] = size;
    reg_args[3] = (long)rec; reg_args[4] = recsize; reg_args[5] = dqoff;
    memcpy(reg_record, rec, 56);
    uint64_t qos = 0x8FF, hint = 0x16fe00000;
    memcpy((char *)rec + 16, &qos, 8);
    memcpy((char *)rec + 36, &hint, 8);
    return 0x4000001F;
}

static uint64_t next_selfid = 5000;
uint64_t yc_testk___thread_selfid(void) { return __atomic_fetch_add(&next_selfid, 1, __ATOMIC_RELAXED); }
void yc_testk__thread_set_tsd_base(void *b) { (void)b; abort(); }
uint32_t yc_testk_mach_thread_self(void) { return 0x203; }
uint32_t yc_testk_mach_reply_port(void) { return 0x407; }
static uint32_t killed_port; static int killed_sig;
int yc_testk___pthread_kill(uint32_t port, int sig) { killed_port = port; killed_sig = sig; return 0; }
int yc_testk___pthread_chdir(const char *p) { (void)p; return 0; }
int yc_testk___pthread_fchdir(int fd) { (void)fd; return 0; }
int yc_testk___sigwait(const uint32_t *set, int *sig) { (void)set; *sig = 2; return 0; }
struct ytv { long tv_sec; int tv_usec; };
int yc_testk___gettimeofday(struct ytv *tv, void *tz, uint64_t *mt)
{
    (void)tz; (void)mt;
    tv->tv_sec = 1700000000; tv->tv_usec = 0;
    return 0;
}
static jmp_buf exit_jb;
static int exit_status = -1;
void yc_testk__exit(int status) { exit_status = status; longjmp(exit_jb, 1); }
void yc_testk_thread_start(void) { abort(); }
void yc_testk_start_wqthread(void) { abort(); }

/* ---- fake kernel: threads (threads-and-events.md 1.1-1.2) -------------- *
 * __bsdthread_create starts a host thread that enters the library's
 * _pthread_start with the spec's register values (x0-x5) and the TSD base
 * at pthread + 224; __bsdthread_terminate frees what it is asked to free,
 * performs the join-gate store and wake, and ends the host thread. The
 * host thread runs on its host stack, not on the stack the library
 * allocated (the library's stack bounds are checked instead). */
void T(_pthread_start)(void *self, uint32_t port, void *(*fn)(void *), void *arg, void *stack, uint32_t flags)
    __attribute__((noreturn));
void T(_pthread_wqthread)(void *self, uint32_t port, void *bottom, void *list, uint32_t flags, int nevents)
    __attribute__((noreturn));

static long mapped_bytes, mprotect_none_calls;
void *yc_testk_mmap(void *addr, size_t len, int prot, int flags, int fd, int64_t off)
{
    (void)addr; (void)fd; (void)off;
    if (flags != (0x0002 | 0x1000) || prot != 3) /* Darwin MAP_PRIVATE|MAP_ANON, RW */
        return (void *)-1;
    void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED)
        return (void *)-1;
    __atomic_fetch_add(&mapped_bytes, (long)len, __ATOMIC_RELAXED);
    return p;
}
int yc_testk_munmap(void *addr, size_t len)
{
    __atomic_fetch_sub(&mapped_bytes, (long)len, __ATOMIC_RELAXED);
    return munmap(addr, len);
}
int yc_testk_mprotect(void *addr, size_t len, int prot)
{
    if (prot == 0)
        __atomic_fetch_add(&mprotect_none_calls, 1, __ATOMIC_RELAXED);
    return mprotect(addr, len, prot);
}
static long yields;
int yc_testk_swtch_pri(int pri) { (void)pri; __atomic_fetch_add(&yields, 1, __ATOMIC_RELAXED); sched_yield(); return 0; }

struct fake_start { void *pthread; uint32_t port; void *(*fn)(void *); void *arg; void *stack; uint32_t flags; };
static uint32_t next_kport = 0x1003;
static struct fake_start last_create, suspended_start;
static int suspended_pending;
static long creates, terminates, terminates_freeing, terminates_gate;

static void *fake_thread_main(void *p)
{
    struct fake_start s = *(struct fake_start *)p;
    free(p);
    my_block = (unsigned char *)s.pthread; /* TPIDRRO_EL0 = pthread + 224 */
    T(_pthread_start)(s.pthread, s.port, s.fn, s.arg, s.stack, s.flags);
}

static void fake_start_host_thread(const struct fake_start *s)
{
    struct fake_start *c = malloc(sizeof *c);
    *c = *s;
    pthread_t h;
    if (pthread_create(&h, NULL, fake_thread_main, c) != 0)
        abort();
    pthread_detach(h);
}

void *yc_testk___bsdthread_create(void *fn, void *arg, void *stack, void *pthread, uint32_t flags)
{
    if (reg_calls == 0 || !(flags & 0x01000000u)) {
        *yc_testk___error() = 22;
        return (void *)-1;
    }
    struct fake_start s = { pthread, __atomic_fetch_add(&next_kport, 0x100, __ATOMIC_RELAXED),
                            (void *(*)(void *))fn, arg, stack, 0 };
    s.flags = (flags | 0x10000000u) & ~0x20000000u; /* TSD_BASE_SET added, SUSPENDED cleared */
    ((uint64_t *)((char *)pthread + TSD_OFF))[3] = s.port; /* slot 3, before the thread runs */
    last_create = s;
    last_create.flags = flags;
    __atomic_fetch_add(&creates, 1, __ATOMIC_RELAXED);
    if (flags & 0x20000000u) {
        suspended_start = s;
        suspended_pending = 1;
    } else {
        fake_start_host_thread(&s);
    }
    return pthread;
}

/* thread_resume for the thread created suspended. */
static void fake_resume_suspended(void)
{
    if (suspended_pending) {
        suspended_pending = 0;
        fake_start_host_thread(&suspended_start);
    }
}

/* The workqueue thread running on this host thread, if any. */
struct fake_worker {
    unsigned char *base; /* B: the kernel's 560 KiB region */
    void *self;          /* B + 540 KiB */
    void *bottom;        /* B + 16 KiB */
    uint32_t port, qos;
    int reruns;          /* plain REUSE runs to give before retiring */
};
static __thread struct fake_worker *cur_worker;
static long wq_retired, wq_bad_region;

int yc_testk___bsdthread_terminate(void *stackaddr, size_t freesize, uint32_t port, uintptr_t gate)
{
    __atomic_fetch_add(&terminates, 1, __ATOMIC_RELAXED);
    (void)port;
    struct fake_worker *w = cur_worker;
    if (w != NULL) {
        /* A worker gives back exactly the kernel's region (section 2.6). */
        if (stackaddr != w->base || freesize != 560 * 1024 || gate != 0)
            __atomic_fetch_add(&wq_bad_region, 1, __ATOMIC_RELAXED);
        munmap(w->base, 560 * 1024);
        free(w);
        cur_worker = NULL;
        my_block = NULL;
        __atomic_fetch_add(&wq_retired, 1, __ATOMIC_RELEASE);
        pthread_exit(NULL);
    }
    if (stackaddr != NULL && freesize != 0) {
        __atomic_fetch_add(&terminates_freeing, 1, __ATOMIC_RELAXED);
        yc_testk_munmap(stackaddr, freesize);
    }
    my_block = NULL;
    if (gate != 0 && (gate | 3) != gate) {
        /* The join gate: store port & ~3, then wake every waiter. */
        __atomic_fetch_add(&terminates_gate, 1, __ATOMIC_RELAXED);
        __atomic_store_n((uint32_t *)gate, port & ~3u, __ATOMIC_SEQ_CST);
        yc_testk___ulock_wake(0x02 | 0x100 | 0x400 | 0x01000000, (void *)gate, 0);
    }
    pthread_exit(NULL);
}

/* ---- fake kernel: the workqueue (threads-and-events.md 2.3-2.7) -------- */
static unsigned char setup_record[24];
static int setup_calls, setup_size, workq_open_calls;
static int reqthreads_calls, reqthreads_count, reqthreads_pp, reqthreads2_calls;
static int last_return_op, last_return_n;
static void *last_return_item;
static uint64_t last_return_ident; /* the first change's ident (the region is gone later) */
static int mgr_prio;
static long ctl_cmd, ctl_flags;

static void *fake_worker_main(void *p);

/* Starts a worker the way the kernel does: a fresh 560 KiB region, self at
 * B + 540 KiB, the event list at self - 1152, the workloop ID at list - 8. */
static void fake_spawn_worker(uint32_t flags, uint32_t qos, const void *events, int nevents, uint64_t wlid,
                              int reruns)
{
    size_t sz = 560 * 1024, align = 16384;
    unsigned char *raw = mmap(NULL, sz + align, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (raw == MAP_FAILED) abort();
    unsigned char *b = (unsigned char *)(((uintptr_t)raw + align - 1) & ~(uintptr_t)(align - 1));
    if (b > raw) munmap(raw, (size_t)(b - raw));
    if (b + sz < raw + sz + align) munmap(b + sz, (size_t)(raw + sz + align - (b + sz)));
    struct fake_worker *w = calloc(1, sizeof *w);
    w->base = b;
    w->self = b + 540 * 1024;
    w->bottom = b + 16 * 1024;
    w->port = __atomic_fetch_add(&next_kport, 0x100, __ATOMIC_RELAXED);
    w->qos = qos;
    w->reruns = reruns;
    unsigned char *list = (unsigned char *)w->self - 1152;
    if (nevents > 0)
        memcpy(list, events, (size_t)nevents * 72);
    if (flags & 0x00400000u)
        memcpy(list - 8, &wlid, 8);
    struct { struct fake_worker *w; uint32_t flags; int n; void *list; } *a = malloc(sizeof *a);
    a->w = w;
    a->flags = flags | 0x00040000u | 0x00200000u | 0x4000u | qos; /* NEWSPI, TSD_BASE_SET, PRIO_QOS */
    a->n = nevents;
    a->list = (flags & 0x00080000u) ? list : NULL;
    pthread_t h;
    if (pthread_create(&h, NULL, fake_worker_main, a) != 0) abort();
    pthread_detach(h);
}

static void *fake_worker_main(void *p)
{
    struct { struct fake_worker *w; uint32_t flags; int n; void *list; } a;
    memcpy(&a, p, sizeof a);
    free(p);
    cur_worker = a.w;
    my_block = a.w->self; /* TPIDRRO_EL0 = self + 224 */
    T(_pthread_wqthread)(a.w->self, a.w->port, a.w->bottom, a.list, a.flags, a.n);
}

/* *_RETURN: run the thread again (REUSE) as a plain worker, or retire it
 * with x5 = -1 (section 2.7). Never returns, like the kernel. */
static __attribute__((noreturn)) void fake_worker_next(void)
{
    struct fake_worker *w = cur_worker;
    if (w == NULL) abort();
    uint32_t q = w->qos < 4 ? w->qos : 4;
    if (w->reruns > 0) {
        w->reruns--;
        T(_pthread_wqthread)(w->self, w->port, w->bottom, NULL, 0x00040000u | 0x00020000u | 0x4000u | w->qos, 0);
    }
    T(_pthread_wqthread)(w->self, w->port, w->bottom, NULL, 0x00040000u | 0x00020000u | 0x4000u | q, -1);
}

int yc_testk___workq_open(void) { workq_open_calls++; return 0; }

int yc_testk___workq_kernreturn(int op, void *item, int arg2, int arg3)
{
    switch (op) {
    case 0x400:
        setup_calls++;
        setup_size = arg2;
        memcpy(setup_record, item, 24);
        return 0;
    case 0x010:
        return 0;
    case 0x020: {
        int qos = 0;
        for (int i = 0; i < 6; i++)
            if (arg3 & (1 << (8 + i))) { qos = i + 1; break; }
        if (arg2 <= 0 || qos == 0 || (arg3 & 0x20000000)) { *yc_testk___error() = 22; return -1; }
        reqthreads_calls++;
        reqthreads_count = arg2;
        reqthreads_pp = arg3;
        for (int i = 0; i < arg2; i++)
            fake_spawn_worker((uint32_t)arg3 & 0x80000000u ? 0x00010000u : 0, (uint32_t)qos, NULL, 0, 0, 0);
        return 0;
    }
    case 0x030:
        reqthreads2_calls++;
        *yc_testk___error() = 45; /* ENOTSUP: no cooperative pool (stage 4a) */
        return -1;
    case 0x004: case 0x040: case 0x100:
        last_return_op = op;
        last_return_item = item;
        last_return_n = arg2;
        last_return_ident = (item && arg2 > 0) ? *(uint64_t *)item : 0;
        fake_worker_next();
    case 0x080:
        mgr_prio = arg2;
        return 0;
    case 0x200:
        return 0;
    }
    *yc_testk___error() = 22;
    return -1;
}

int yc_testk___bsdthread_ctl(uintptr_t cmd, uintptr_t a1, uintptr_t a2, uintptr_t a3)
{
    (void)a1; (void)a2;
    ctl_cmd = (long)cmd;
    ctl_flags = (long)a3;
    return 0;
}

static unsigned char wl_params[36];
static long wl_cmd;
int yc_testk___kqueue_workloop_ctl(uintptr_t cmd, uint64_t options, void *params, size_t size)
{
    (void)options;
    wl_cmd = (long)cmd;
    if (size != 36) { *yc_testk___error() = 22; return -1; }
    memcpy(wl_params, params, 36);
    return 0;
}

static void wait_until(volatile long *counter, long value)
{
    for (int i = 0; i < 20000 && __atomic_load_n(counter, __ATOMIC_ACQUIRE) < value; i++)
        usleep(500);
}

/* Runs fn in a child process and reports whether it crashed. */
static int crashes(void (*fn)(void))
{
    fflush(stdout);
    fflush(stderr);
    pid_t pid = fork();
    if (pid == 0) {
        int fd = open("/dev/null", 1);
        if (fd >= 0) dup2(fd, 2);
        fn();
        _exit(0);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFSIGNALED(st);
}

/* ---- tests: before __pthread_init ------------------------------------- */

static void test_identity_before_init(void)
{
    unsigned char *b = (unsigned char *)tsd() - TSD_OFF;
    CHECK(T(pthread_self)() == b);
    CHECK(T(_pthread_self)() == b);
    CHECK(T(pthread_equal)(b, T(pthread_self)()));
    CHECK(!T(pthread_equal)(b, b + 1));
    CHECK(T(pthread_main_np)() == 1);
    CHECK(T(pthread_main_thread_np)() == b);
    uint64_t tid = 0;
    CHECK(T(pthread_threadid_np)(NULL, &tid) == 0 && tid == 1);
    CHECK(T(pthread_threadid_np)(b, &tid) == 0 && tid == 1);
    CHECK(T(pthread_threadid_np)(b + 64, &tid) == 3 /* ESRCH */);
    CHECK(T(pthread_threadid_np)(NULL, NULL) == 22);
    CHECK(T(pthread_mach_thread_np)(b) == 0x203);
    CHECK(T(pthread_from_mach_thread_np)(0x203) == b);
    CHECK(T(pthread_from_mach_thread_np)(0x999) == NULL);
    CHECK(T(pthread_get_stacksize_np)(b) == 8 * 1024 * 1024);
    CHECK(T(pthread_get_stackaddr_np)(b) == (void *)*(uintptr_t *)(b + 176));
    int local = 0;
    CHECK(T(pthread_current_stack_contains_np)(&local, sizeof local) == 1);
    CHECK(T(pthread_current_stack_contains_np)((void *)16, 4) == 0);
    CHECK(T(pthread_current_stack_contains_np)((void *)~(uintptr_t)0, 4) < 0);
    CHECK(T(qos_class_self)() == 0x15); /* QOS_CLASS_DEFAULT before init */
    CHECK(T(pthread_is_threaded_np)() == 0);
}

static void test_mutex_static(void)
{
    ymutex_t m = YMUTEX_INIT;
    CHECK(T(pthread_mutex_unlock)(&m) == 1 /* EPERM */);
    CHECK(T(pthread_mutex_lock)(&m) == 0);
    CHECK(T(pthread_mutex_lock)(&m) == 11 /* EDEADLK */);
    CHECK(T(pthread_mutex_trylock)(&m) == 16 /* EBUSY */);
    CHECK(T(pthread_mutex_destroy)(&m) == 16);
    CHECK(T(pthread_mutex_unlock)(&m) == 0);
    CHECK(T(pthread_mutex_trylock)(&m) == 0);
    CHECK(T(pthread_mutex_unlock)(&m) == 0);
    CHECK(m.sig == 0x32AAABA7); /* never rewritten */
    CHECK(T(pthread_mutex_destroy)(&m) == 0);
    CHECK(T(pthread_mutex_lock)(&m) == 22);

    ymutex_t e = YMUTEX_ERRCHK_INIT;
    CHECK(T(pthread_mutex_lock)(&e) == 0);
    CHECK(T(pthread_mutex_lock)(&e) == 11);
    CHECK(T(pthread_mutex_unlock)(&e) == 0);
    CHECK(T(pthread_mutex_unlock)(&e) == 1);

    ymutex_t r = YMUTEX_RECURSIVE_INIT;
    CHECK(T(pthread_mutex_lock)(&r) == 0);
    CHECK(T(pthread_mutex_lock)(&r) == 0);
    CHECK(T(pthread_mutex_trylock)(&r) == 0);
    CHECK(T(pthread_mutex_unlock)(&r) == 0);
    CHECK(T(pthread_mutex_unlock)(&r) == 0);
    CHECK(T(pthread_mutex_destroy)(&r) == 16);
    CHECK(T(pthread_mutex_unlock)(&r) == 0);
    CHECK(T(pthread_mutex_unlock)(&r) == 1);

    ymutex_t bad = { 0x12345678, { 0 } };
    CHECK(T(pthread_mutex_lock)(&bad) == 22);
    CHECK(T(pthread_mutex_unlock)(&bad) == 22);
}

static void test_mutex_attr(void)
{
    ymutexattr_t a;
    int v;
    CHECK(T(pthread_mutexattr_init)(&a) == 0);
    CHECK(a.sig == 0x4D545841);
    CHECK(T(pthread_mutexattr_gettype)(&a, &v) == 0 && v == 0);
    CHECK(T(pthread_mutexattr_settype)(&a, 7) == 22);
    CHECK(T(pthread_mutexattr_settype)(&a, 2) == 0);
    CHECK(T(pthread_mutexattr_gettype)(&a, &v) == 0 && v == 2);
    CHECK(T(pthread_mutexattr_getpshared)(&a, &v) == 0 && v == 2);
    CHECK(T(pthread_mutexattr_setpshared)(&a, 1) == 0);
    CHECK(T(pthread_mutexattr_setpshared)(&a, 5) == 22);
    CHECK(T(pthread_mutexattr_getprotocol)(&a, &v) == 0 && v == 0);
    CHECK(T(pthread_mutexattr_setprotocol)(&a, 2) == 0);
    CHECK(T(pthread_mutexattr_setprotocol)(&a, 3) == 22);
    CHECK(T(pthread_mutexattr_getpolicy_np)(&a, &v) == 0 && v == 3);
    CHECK(T(pthread_mutexattr_setpolicy_np)(&a, 1) == 0);
    CHECK(T(pthread_mutexattr_setpolicy_np)(&a, 2) == 22);
    CHECK(T(pthread_mutexattr_setprioceiling)(&a, 40) == 0);
    CHECK(T(pthread_mutexattr_getprioceiling)(&a, &v) == 0 && v == 40);

    ymutex_t m;
    CHECK(T(pthread_mutex_init)(&m, &a) == 0);
    CHECK(m.sig == 0x4D555458);
    CHECK(T(pthread_mutex_lock)(&m) == 0);
    CHECK(T(pthread_mutex_lock)(&m) == 0); /* recursive */
    CHECK(T(pthread_mutex_unlock)(&m) == 0);
    CHECK(T(pthread_mutex_unlock)(&m) == 0);
    CHECK(T(pthread_mutex_getprioceiling)(&m, &v) == 0 && v == 40);
    int old = 0;
    CHECK(T(pthread_mutex_setprioceiling)(&m, 50, &old) == 0 && old == 40);
    CHECK(T(pthread_mutex_destroy)(&m) == 0);
    CHECK(T(pthread_mutexattr_destroy)(&a) == 0);
    CHECK(T(pthread_mutexattr_settype)(&a, 0) == 22);
    CHECK(T(pthread_mutex_init)(&m, &a) == 22);
    CHECK(T(pthread_mutex_init)(&m, NULL) == 0);
    CHECK(T(pthread_mutex_lock)(&m) == 0 && T(pthread_mutex_lock)(&m) == 11);
    CHECK(T(pthread_mutex_unlock)(&m) == 0);
}

/* ---- tests: __pthread_init -------------------------------------------- */

static int exit_fn_status = -1;
static void fake_libc_exit(int status) { exit_fn_status = status; longjmp(exit_jb, 2); }
static int fake_malloc_calls;
static void *fake_malloc(size_t n) { fake_malloc_calls++; return malloc(n); }

struct ypfuncs { unsigned long version; void (*exit)(int); void *(*malloc)(size_t); void (*free)(void *); };

static void test_init(void)
{
    char ms[] = "main_stack=0x16fe00000,0x7fc000,0x16be00000,0x4000000";
    char pm[] = "ptr_munge=0x1234abcd5678";
    char tp[] = "th_port=0x303";
    char ep[] = "executable_path=/bin/hello";
    const char *apple[] = { ep, ms, pm, tp, NULL };
    const char *envp[] = { "HOME=/", NULL };
    struct ypfuncs f = { 2, fake_libc_exit, fake_malloc, free };
    unsigned char *b = (unsigned char *)tsd() - TSD_OFF;

    CHECK(T(__pthread_init)(&f, envp, apple, NULL) == 0);
    CHECK(strcmp(ms, "main_stack=") == 0 && ms[sizeof ms - 2] == 0);
    CHECK(strcmp(pm, "ptr_munge=") == 0);
    CHECK(strcmp(tp, "th_port=") == 0);
    CHECK(strcmp(ep, "executable_path=/bin/hello") == 0);
    CHECK(*(uintptr_t *)(b + 176) == 0x16fe00000);
    CHECK(*(uintptr_t *)(b + 184) == 0x16fe00000 - 0x7fc000);
    CHECK(*(uintptr_t *)(b + 192) == 0x16be00000);
    CHECK(*(uintptr_t *)(b + 200) == 0x4000000);
    CHECK(*(uintptr_t *)(b + 208) == 16384);
    CHECK(tsd()[0] == (uintptr_t)b);
    CHECK(tsd()[1] == (uintptr_t)(b + 172));
    CHECK(tsd()[2] == 0x407);
    CHECK(tsd()[3] == 0x303);
    CHECK(tsd()[4] == 0x8FF);
    CHECK(tsd()[7] == 0x1234abcd5678);
    CHECK(tsd()[8] == 0 && tsd()[9] == 0);
    CHECK(*(long *)b == (long)((uintptr_t)b ^ 0x1234abcd5678));
    CHECK(*(uint64_t *)(b + 216) == 1); /* the VMM's ID is kept */
    CHECK(b[49] & 1); /* joinable */
    CHECK(*(uint16_t *)(b + 166) == 3); /* cancel enabled + deferred */

    /* The registration record (host-library-init.md section 6.1). */
    CHECK(reg_calls == 1);
    CHECK(reg_args[0] == (long)yc_testk_thread_start && reg_args[1] == (long)yc_testk_start_wqthread);
    CHECK(reg_args[2] == 16384 && reg_args[4] == 56 && reg_args[5] == 160);
    uint64_t u64; uint32_t u32;
    memcpy(&u64, reg_record + 0, 8); CHECK(u64 == 56);
    memcpy(&u64, reg_record + 8, 8); CHECK(u64 == 160);
    memcpy(&u32, reg_record + 24, 4); CHECK(u32 == 224);
    memcpy(&u32, reg_record + 28, 4); CHECK(u32 == 40);
    memcpy(&u32, reg_record + 32, 4); CHECK(u32 == 24);
    memcpy(&u32, reg_record + 48, 4); CHECK(u32 == 392);
    memcpy(&u32, reg_record + 52, 4); CHECK(u32 == 960);
    CHECK(T(_pthread_workqueue_supported)() == 0x4000001F);
    CHECK(T(qos_class_main)() == 0x15);
    CHECK(T(qos_class_self)() == 0x15);
    CHECK(T(pthread_mach_thread_np)(b) == 0x303);

    /* A second call refreshes but does not register again. */
    const char *apple2[] = { NULL };
    CHECK(T(__pthread_init)(&f, envp, apple2, NULL) == 0);
    CHECK(reg_calls == 1);
    CHECK(tsd()[3] == 0x303 && tsd()[7] == 0x1234abcd5678);
    CHECK(*(uintptr_t *)(b + 176) == 0x16fe00000);
    T(__pthread_late_init)(envp, apple, NULL);
    /* NULL and old tables are accepted. */
    struct ypfuncs v1 = { 1, fake_libc_exit, NULL, NULL };
    CHECK(T(__pthread_init)(NULL, NULL, NULL, NULL) == 0);
    CHECK(T(__pthread_init)(&v1, NULL, NULL, NULL) == 0);
}

/* ---- tests: TSD -------------------------------------------------------- */

static int dtor_calls;
static void *dtor_last;
static void dtor(void *v) { dtor_calls++; dtor_last = v; }

static void test_tsd(void)
{
    unsigned long k1 = 0, k2 = 0, k3 = 0;
    CHECK(T(pthread_key_create)(&k1, dtor) == 0 && k1 == 256);
    CHECK(T(pthread_key_create)(&k2, NULL) == 0 && k2 == 257);
    CHECK(T(pthread_getspecific)(k1) == NULL);
    CHECK(T(pthread_setspecific)(k1, (void *)0x1111) == 0);
    CHECK(tsd()[256] == 0x1111);
    CHECK(T(pthread_getspecific)(k1) == (void *)0x1111);
    CHECK(T(pthread_setspecific)(300, (void *)1) == 22); /* not created */
    CHECK(T(pthread_setspecific)(768, (void *)1) == 22);
    CHECK(T(pthread_setspecific)(5, (void *)1) == 22);
    CHECK(T(pthread_getspecific)(3) == (void *)0x303); /* no range check */
    CHECK(T(pthread_key_init_np)(9, NULL) == 22);
    CHECK(T(pthread_key_init_np)(256, NULL) == 22);
    CHECK(T(pthread_key_init_np)(20, dtor) == 0);
    CHECK(T(pthread_setspecific)(20, (void *)0x2020) == 0 && tsd()[20] == 0x2020);
    CHECK(T(_pthread_setspecific_static)(21, (void *)0x2121) == 0 && tsd()[21] == 0x2121);
    CHECK(T(_pthread_setspecific_static)(256, (void *)1) == 22);
    CHECK(T(pthread_key_delete)(k2) == 0);
    CHECK(T(pthread_key_delete)(k2) == 22);
    CHECK(T(pthread_key_delete)(20) == 22);
    CHECK(T(pthread_key_create)(&k3, NULL) == 0 && k3 == 257);
    CHECK(T(pthread_setspecific)(k3, (void *)7) == 0);
    CHECK(T(pthread_key_delete)(k3) == 0 && tsd()[257] == 0);
    CHECK(T(pthread_key_create)(&k3, NULL) == 0 && k3 == 257 && T(pthread_getspecific)(k3) == NULL);
    CHECK(T(pthread_introspection_getspecific_np)(T(pthread_self)(), 256) == (void *)0x1111);
    tsd()[4] = 0x8FF;
    T(_pthread_clear_qos_tsd)(0);
    CHECK(tsd()[4] == 0);
    tsd()[4] = 0x8FF;
    (void)dtor_last;
}

/* ---- tests: once ------------------------------------------------------- */

static int once_count;
static void once_routine(void) { __atomic_fetch_add(&once_count, 1, __ATOMIC_RELAXED); }
static yonce_t shared_once = YONCE_INIT;
static void *once_thread(void *arg) { (void)arg; T(pthread_once)(&shared_once, once_routine); return NULL; }
static yonce_t rec_once = YONCE_INIT;
static void rec_routine(void) { T(pthread_once)(&rec_once, rec_routine); }
static void rec_once_child(void) { T(pthread_once)(&rec_once, rec_routine); }

static void test_once(void)
{
    yonce_t o = YONCE_INIT;
    once_count = 0;
    CHECK(T(pthread_once)(&o, once_routine) == 0);
    CHECK(T(pthread_once)(&o, once_routine) == 0);
    CHECK(once_count == 1);
    yonce_t bad = { 0x1234, { 0 } };
    CHECK(T(pthread_once)(&bad, once_routine) == 22);
    once_count = 0;
    pthread_t th[8];
    for (int i = 0; i < 8; i++) pthread_create(&th[i], NULL, once_thread, NULL);
    for (int i = 0; i < 8; i++) pthread_join(th[i], NULL);
    CHECK(once_count == 1);
    CHECK(crashes(rec_once_child));
}

/* ---- tests: condition variables --------------------------------------- */

static ycond_t pc_cond = YCOND_INIT;
static ymutex_t pc_mutex = YMUTEX_INIT;
static int pc_items, pc_consumed;
static void *producer(void *arg)
{
    (void)arg;
    for (int i = 0; i < 2000; i++) {
        T(pthread_mutex_lock)(&pc_mutex);
        pc_items++;
        T(pthread_cond_signal)(&pc_cond);
        T(pthread_mutex_unlock)(&pc_mutex);
    }
    return NULL;
}
static void *consumer(void *arg)
{
    (void)arg;
    for (int i = 0; i < 2000; i++) {
        T(pthread_mutex_lock)(&pc_mutex);
        while (pc_items == 0)
            CHECK(T(pthread_cond_wait)(&pc_cond, &pc_mutex) == 0);
        pc_items--;
        pc_consumed++;
        T(pthread_mutex_unlock)(&pc_mutex);
    }
    return NULL;
}

static void test_cond(void)
{
    ycond_t c = YCOND_INIT;
    ymutex_t m = YMUTEX_INIT;
    CHECK(T(pthread_cond_signal)(&c) == 0);
    CHECK(T(pthread_cond_broadcast)(&c) == 0);
    CHECK(T(pthread_mutex_lock)(&m) == 0);
    struct yts rel = { 0, 1000 };
    CHECK(T(pthread_cond_timedwait_relative_np)(&c, &m, &rel) == 60);
    struct yts past = { 1000, 0 };
    CHECK(T(pthread_cond_timedwait)(&c, &m, &past) == 60);
    struct yts future = { 1700000005, 0 };
    CHECK(T(pthread_cond_timedwait)(&c, &m, &future) == 60);
    struct yts bad = { 0, 2000000000 };
    CHECK(T(pthread_cond_timedwait)(&c, &m, &bad) == 22);
    CHECK(T(pthread_mutex_unlock)(&m) == 0); /* still held after the waits */
    CHECK(T(pthread_mutex_unlock)(&m) == 1);
    CHECK(T(pthread_cond_timedwait_relative_np)(&c, &m, &rel) == 1); /* not held: EPERM */

    ycondattr_t ca;
    int v;
    CHECK(T(pthread_condattr_init)(&ca) == 0);
    CHECK(T(pthread_condattr_getpshared)(&ca, &v) == 0 && v == 2);
    CHECK(T(pthread_condattr_setpshared)(&ca, 1) == 0);
    CHECK(T(pthread_condattr_setpshared)(&ca, 9) == 22);
    ycond_t c2;
    CHECK(T(pthread_cond_init)(&c2, &ca) == 0 && c2.sig == 0x434F4E44);
    CHECK(T(pthread_cond_destroy)(&c2) == 0);
    CHECK(T(pthread_cond_signal)(&c2) == 22);
    CHECK(T(pthread_condattr_destroy)(&ca) == 0);

    /* With threads: a producer/consumer pair. */
    T(__is_threaded) = 1;
    pthread_t p, q;
    pthread_create(&q, NULL, consumer, NULL);
    pthread_create(&p, NULL, producer, NULL);
    pthread_join(p, NULL);
    pthread_join(q, NULL);
    CHECK(pc_consumed == 2000 && pc_items == 0);
    T(__is_threaded) = 0;
}

/* ---- tests: rwlocks ---------------------------------------------------- */

static yrwlock_t stress_rw = YRWLOCK_INIT;
static long rw_value, rw_bad;
static void *rw_thread(void *arg)
{
    long id = (long)arg;
    for (int i = 0; i < 20000; i++) {
        if ((i + id) % 4 == 0) {
            T(pthread_rwlock_wrlock)(&stress_rw);
            long v = rw_value;
            rw_value = v + 1;
            T(pthread_rwlock_unlock)(&stress_rw);
        } else {
            T(pthread_rwlock_rdlock)(&stress_rw);
            long a = rw_value;
            sched_yield();
            if (rw_value != a) __atomic_fetch_add(&rw_bad, 1, __ATOMIC_RELAXED);
            T(pthread_rwlock_unlock)(&stress_rw);
        }
    }
    return NULL;
}

static void test_rwlock(void)
{
    yrwlock_t l = YRWLOCK_INIT;
    CHECK(T(pthread_rwlock_unlock)(&l) == 1);
    CHECK(T(pthread_rwlock_rdlock)(&l) == 0);
    CHECK(T(pthread_rwlock_tryrdlock)(&l) == 0);
    CHECK(T(pthread_rwlock_trywrlock)(&l) == 16);
    CHECK(T(pthread_rwlock_destroy)(&l) == 16);
    CHECK(T(pthread_rwlock_unlock)(&l) == 0);
    CHECK(T(pthread_rwlock_unlock)(&l) == 0);
    CHECK(T(pthread_rwlock_unlock)(&l) == 1);
    CHECK(T(pthread_rwlock_wrlock)(&l) == 0);
    CHECK(T(pthread_rwlock_wrlock)(&l) == 11);
    CHECK(T(pthread_rwlock_rdlock)(&l) == 11);
    CHECK(T(pthread_rwlock_tryrdlock)(&l) == 11);
    CHECK(T(pthread_rwlock_unlock)(&l) == 0);
    CHECK(T(pthread_rwlock_destroy)(&l) == 0);
    CHECK(T(pthread_rwlock_rdlock)(&l) == 22);

    yrwlockattr_t a;
    int v;
    CHECK(T(pthread_rwlockattr_init)(&a) == 0);
    CHECK(T(pthread_rwlockattr_getpshared)(&a, &v) == 0 && v == 2);
    CHECK(T(pthread_rwlockattr_setpshared)(&a, 3) == 22);
    CHECK(T(pthread_rwlock_init)(&l, &a) == 0 && l.sig == 0x52574C4B);
    CHECK(T(pthread_rwlockattr_destroy)(&a) == 0);

    T(__is_threaded) = 1;
    pthread_t th[4];
    for (long i = 0; i < 4; i++) pthread_create(&th[i], NULL, rw_thread, (void *)i);
    for (int i = 0; i < 4; i++) pthread_join(th[i], NULL);
    CHECK(rw_value == 4 * 5000 && rw_bad == 0);
    T(__is_threaded) = 0;
}

/* ---- tests: mutex under contention ------------------------------------ */

static ymutex_t stress_m = YMUTEX_INIT;
static long stress_counter;
static void *mutex_thread(void *arg)
{
    (void)arg;
    CHECK(T(pthread_main_np)() == 0);
    for (int i = 0; i < 100000; i++) {
        T(pthread_mutex_lock)(&stress_m);
        stress_counter++;
        T(pthread_mutex_unlock)(&stress_m);
    }
    return NULL;
}

static void test_mutex_threads(void)
{
    pthread_t th[4];
    for (int i = 0; i < 4; i++) pthread_create(&th[i], NULL, mutex_thread, NULL);
    for (int i = 0; i < 4; i++) pthread_join(th[i], NULL);
    CHECK(stress_counter == 400000);
}

/* ---- tests: attributes ------------------------------------------------- */

static void test_attr(void)
{
    yattr_t a;
    size_t sz;
    int v;
    void *addr;
    struct ysp sp;
    CHECK(T(pthread_attr_init)(&a) == 0 && a.sig == 0x54484441);
    CHECK(T(pthread_attr_getstacksize)(&a, &sz) == 0 && sz == 0x80000);
    CHECK(T(pthread_attr_getguardsize)(&a, &sz) == 0 && sz == 16384);
    CHECK(T(pthread_attr_getdetachstate)(&a, &v) == 0 && v == 1);
    CHECK(T(pthread_attr_getschedparam)(&a, &sp) == 0 && sp.sched_priority == 31);
    CHECK(T(pthread_attr_setdetachstate)(&a, 2) == 0);
    CHECK(T(pthread_attr_setdetachstate)(&a, 3) == 22);
    CHECK(T(pthread_attr_setstacksize)(&a, 1000) == 22);
    CHECK(T(pthread_attr_setstacksize)(&a, 20000) == 22);
    CHECK(T(pthread_attr_setstacksize)(&a, 65536) == 0);
    CHECK(T(pthread_attr_setstack)(&a, (void *)0x100000, 0x8000) == 0);
    CHECK(T(pthread_attr_getstack)(&a, &addr, &sz) == 0 && addr == (void *)0x100000 && sz == 0x8000);
    CHECK(T(pthread_attr_setstack)(&a, (void *)0x100001, 0x8000) == 22);
    CHECK(T(pthread_attr_setguardsize)(&a, 1) == 0);
    CHECK(T(pthread_attr_getguardsize)(&a, &sz) == 0 && sz == 16384);
    CHECK(T(pthread_attr_setscope)(&a, 1) == 0);
    CHECK(T(pthread_attr_setscope)(&a, 2) == 45);
    CHECK(T(pthread_attr_setschedpolicy)(&a, 3) == 22);
    unsigned q;
    CHECK(T(pthread_attr_get_qos_class_np)(&a, &q, &v) == 0 && q == 0x15 && v == 0);
    CHECK(T(pthread_attr_set_qos_class_np)(&a, 0x19, -2) == 0);
    CHECK(T(pthread_attr_get_qos_class_np)(&a, &q, &v) == 0 && q == 0x19 && v == -2);
    CHECK(T(pthread_attr_set_qos_class_np)(&a, 0x19, 1) == 22);
    CHECK(T(pthread_attr_set_qos_class_np)(&a, 0x16, 0) == 22);
    CHECK(T(pthread_attr_destroy)(&a) == 0);
    CHECK(T(pthread_attr_setdetachstate)(&a, 1) == 22);
}

/* ---- tests: QoS -------------------------------------------------------- */

static void test_qos(void)
{
    int rp;
    unsigned long fl;
    unsigned q;
    CHECK(T(_pthread_qos_class_encode)(0x15, 0, 0) == 0x8FF);
    CHECK(T(_pthread_qos_class_encode)(0x19, -1, 0) == 0x10FE);
    CHECK(T(_pthread_qos_class_encode)(0x05, 0, 0x80000000ul) == 0x800001FF);
    CHECK(T(_pthread_qos_class_encode)(0, 0, 0) == 0);
    CHECK(T(_pthread_qos_class_decode)(0x10FE, &rp, &fl) == 0x19 && rp == -1 && fl == 0);
    CHECK(T(_pthread_qos_class_decode)(0x800001FF, &rp, &fl) == 0x05 && rp == 0 && fl == 0x80000000ul);
    CHECK(T(_pthread_qos_class_decode)(0, &rp, &fl) == 0 && rp == 0);
    CHECK(T(pthread_set_qos_class_self_np)(0x11, -3) == 0);
    CHECK(T(qos_class_self)() == 0x11);
    CHECK(T(pthread_get_qos_class_np)(T(pthread_self)(), &q, &rp) == 0 && q == 0x11 && rp == -3);
    CHECK(T(pthread_set_qos_class_self_np)(0x11, -16) == 22);
    CHECK(T(pthread_set_qos_class_self_np)(0x12, 0) == 22);
    CHECK(T(_pthread_set_properties_self)(1, 0x8FF, 0) == 0 && T(qos_class_self)() == 0x15);
    CHECK(T(qos_class_main)() == 0x15);
    char cfg[16] = { 0 };
    CHECK(T(pthread_workqueue_setup)(cfg, sizeof cfg) == 22); /* version 0 */
    CHECK(T(pthread_workqueue_setup)(NULL, 0) == 22);
}

/* ---- tests: thread functions, exit, cleanup ---------------------------- */

struct ycleanup { void (*routine)(void *); void *arg; struct ycleanup *next; };
static int cleanup_order[4], cleanup_n;
static void cleanup_fn(void *arg) { cleanup_order[cleanup_n++] = (int)(long)arg; }

static int atfork_log[8], atfork_n;
static void af_p1(void) { atfork_log[atfork_n++] = 1; }
static void af_p2(void) { atfork_log[atfork_n++] = 2; }
static void af_c1(void) { atfork_log[atfork_n++] = 11; }
static void af_c2(void) { atfork_log[atfork_n++] = 12; }

static void test_misc(void)
{
    unsigned char *b = (unsigned char *)T(pthread_self)();
    int old;
    CHECK(T(pthread_setcancelstate)(0, &old) == 0 && old == 1);
    CHECK(T(pthread_setcancelstate)(1, &old) == 0 && old == 0);
    CHECK(T(pthread_setcancelstate)(5, &old) == 22);
    CHECK(T(pthread_setcanceltype)(2, &old) == 0 && old == 2);
    T(pthread_testcancel)();
    CHECK(T(pthread_join)(b, NULL) == 11);
    CHECK(T(pthread_join)(b + 16, NULL) == 3);
    CHECK(T(pthread_kill)(b, 99) == 22);
    CHECK(T(pthread_kill)(b, 0) == 0 && killed_port == 0x303 && killed_sig == 0);
    CHECK(T(sched_get_priority_min)(1) == 15 && T(sched_get_priority_max)(1) == 47);
    CHECK(T(sched_yield)() == 0);
    int pol;
    struct ysp sp;
    CHECK(T(pthread_getschedparam)(b, &pol, &sp) == 0 && pol == 1 && sp.sched_priority == 31);
    sp.sched_priority = 40;
    CHECK(T(pthread_setschedparam)(b, 4, &sp) == 0);
    CHECK(T(pthread_getschedparam)(b, &pol, &sp) == 0 && pol == 4 && sp.sched_priority == 40);
    CHECK(T(pthread_setschedparam)(b, 9, &sp) == 22);
    CHECK(T(pthread_setconcurrency)(3) == 0 && T(pthread_getconcurrency)() == 3);
    CHECK(T(pthread_setconcurrency)(-1) == 22);
    uint32_t set = 0x4, oset = 0;
    CHECK(T(pthread_sigmask)(1, &set, &oset) == 0 && fake_mask == 0x4);
    CHECK(T(pthread_sigmask)(9, &set, &oset) == 22);

    char name[64];
    CHECK(T(pthread_setname_np)("worker") == 0);
    CHECK(T(pthread_getname_np)(b, name, sizeof name) == 0 && strcmp(name, "worker") == 0);
    CHECK(T(pthread_getname_np)(b, name, 3) == 0 && strcmp(name, "wo") == 0);
    char longname[80];
    memset(longname, 'x', sizeof longname - 1);
    longname[79] = 0;
    CHECK(T(pthread_setname_np)(longname) == 63);

    uintptr_t frame[2] = { 0x1000, 0x2000 }, ret = 0;
    CHECK(T(pthread_stack_frame_decode_np)((uintptr_t)frame, &ret) == 0x1000 && ret == 0x2000);

    void *h = (void *)0x77;
    CHECK(T(pthread_introspection_hook_install)(h) == NULL);
    CHECK(T(pthread_introspection_hook_install)(NULL) == h);

    struct ydep d;
    T(pthread_dependency_init_np)(&d, b, NULL);
    CHECK(d.owner == 0x303);
    T(pthread_dependency_fulfill_np)(&d, (void *)0x55);
    CHECK(T(pthread_dependency_wait_np)(&d) == (void *)0x55);

    CHECK(T(pthread_layout_offsets)[0] == 1 && T(pthread_layout_offsets)[1] == 224 &&
          T(pthread_layout_offsets)[2] == 0 && T(pthread_layout_offsets)[3] == 8);

    /* atfork order: prepare in reverse, parent/child in order. */
    CHECK(T(pthread_atfork)(af_p1, af_c1, af_c1) == 0);
    CHECK(T(pthread_atfork)(af_p2, af_c2, af_c2) == 0);
    T(_pthread_atfork_prepare_handlers)();
    T(_pthread_atfork_parent_handlers)();
    CHECK(atfork_n == 4 && atfork_log[0] == 2 && atfork_log[1] == 1 && atfork_log[2] == 11 && atfork_log[3] == 12);
    atfork_n = 0;
    T(_pthread_atfork_child_handlers)();
    CHECK(atfork_n == 2 && atfork_log[0] == 11 && atfork_log[1] == 12);

    /* pthread_exit: cleanup handlers (innermost first), TSD destructors,
     * then libc's exit(0) from the _libpthread_functions table. */
    struct ycleanup c1 = { cleanup_fn, (void *)1, NULL };
    struct ycleanup c2 = { cleanup_fn, (void *)2, &c1 };
    *(void **)(b + 8) = &c2;
    dtor_calls = 0;
    T(pthread_setspecific)(20, NULL);
    T(pthread_setspecific)(256, (void *)0x9999);
    if (setjmp(exit_jb) == 0)
        T(pthread_exit)(NULL);
    CHECK(exit_fn_status == 0);
    CHECK(cleanup_n == 2 && cleanup_order[0] == 2 && cleanup_order[1] == 1);
    CHECK(*(void **)(b + 8) == NULL);
    CHECK(dtor_calls == 1 && dtor_last == (void *)0x9999 && tsd()[256] == 0);

    /* Cancellation of self acts at the next cancellation point. */
    exit_fn_status = -1;
    *(uint16_t *)(b + 78) &= (uint16_t)~2; /* clear "exiting" for the test */
    CHECK(T(pthread_cancel)(b) == 0);
    if (setjmp(exit_jb) == 0) {
        T(pthread_testcancel)();
        CHECK(0 && "testcancel returned");
    }
    CHECK(exit_fn_status == 0);
}

/* ---- tests: threads (create, start, exit, join, detach) ---------------- */

int T(pthread_create)(ypthread_t *, const yattr_t *, void *(*)(void *), void *);
int T(pthread_create_suspended_np)(ypthread_t *, const yattr_t *, void *(*)(void *), void *);
int T(pthread_create_from_mach_thread)(ypthread_t *, const yattr_t *, void *(*)(void *), void *);
int T(pthread_create_with_workgroup_np)(ypthread_t *, void *, const yattr_t *, void *(*)(void *), void *);
int T(pthread_attr_setschedparam)(yattr_t *, const struct ysp *);

struct tinfo {
    ypthread_t self;
    uint32_t port;
    uint64_t tid;
    int is_main, errno_ok, stack_ok;
    unsigned qos;
    void *stackaddr;
    size_t stacksize;
};

static void *probe_thread(void *arg)
{
    struct tinfo *ti = arg;
    ti->self = T(pthread_self)();
    ti->port = (uint32_t)tsd()[3];
    T(pthread_threadid_np)(NULL, &ti->tid);
    ti->is_main = T(pthread_main_np)();
    ti->errno_ok = tsd()[1] == (uintptr_t)((char *)ti->self + 172) && *yc_testk___error() == 0;
    ti->qos = T(qos_class_self)();
    ti->stackaddr = T(pthread_get_stackaddr_np)(ti->self);
    ti->stacksize = T(pthread_get_stacksize_np)(ti->self);
    return (void *)0x5151;
}

static int t_cleanups;
static void t_cleanup(void *a) { (void)a; __atomic_fetch_add(&t_cleanups, 1, __ATOMIC_RELAXED); }
static int t_dtors;
static void t_dtor(void *v) { if (v == (void *)0x77) __atomic_fetch_add(&t_dtors, 1, __ATOMIC_RELAXED); }
static unsigned long t_key;

static void *exit_thread(void *arg)
{
    (void)arg;
    struct ycleanup c = { t_cleanup, NULL, NULL };
    *(void **)((char *)T(pthread_self)() + 8) = &c; /* pthread_cleanup_push, inline */
    T(pthread_setspecific)(t_key, (void *)0x77);
    T(pthread_exit)((void *)0x6262);
}

static volatile int release_flag;
static void *wait_release_thread(void *arg)
{
    while (!__atomic_load_n(&release_flag, __ATOMIC_ACQUIRE))
        usleep(200);
    return arg;
}

static void *quick_thread(void *arg) { return arg; }

static ymutex_t st_m = YMUTEX_INIT;
static ycond_t st_c = YCOND_INIT;
static long st_counter;
static int st_ready;
static void *stress_thread(void *arg)
{
    (void)arg;
    T(pthread_mutex_lock)(&st_m);
    while (!st_ready)
        T(pthread_cond_wait)(&st_c, &st_m); /* blocks in the (fake) kernel */
    T(pthread_mutex_unlock)(&st_m);
    for (int i = 0; i < 2000; i++) {
        T(pthread_mutex_lock)(&st_m);
        st_counter++;
        T(pthread_mutex_unlock)(&st_m);
    }
    return NULL;
}

struct joinrace { ypthread_t t; int r; };
static void *join_racer(void *arg)
{
    struct joinrace *j = arg;
    j->r = T(pthread_join)(j->t, NULL);
    return NULL;
}

static void test_threads(void)
{
    long base_mapped = mapped_bytes;
    ypthread_t me = T(pthread_self)();
    CHECK(T(pthread_is_threaded_np)() == 0);

    /* 1. Basic create/join: the kernel call, the thread's identity, the
     *    return value, and the memory being given back. */
    struct tinfo ti;
    memset(&ti, 0, sizeof ti);
    ypthread_t t = NULL;
    long c0 = creates;
    CHECK(T(pthread_create)(&t, NULL, probe_thread, &ti) == 0 && t != NULL);
    CHECK(creates == c0 + 1);
    CHECK(T(pthread_is_threaded_np)() == 1);
    CHECK(last_create.pthread == t && last_create.stack == t && last_create.fn == probe_thread &&
          last_create.arg == &ti);
    CHECK(last_create.flags == (0x01000000u | 0x08000000u | 0x8FFu)); /* CUSTOM | QOSCLASS | default QoS */
    CHECK(mapped_bytes == base_mapped + 16384 + 0x80000 + 16384);
    CHECK(mprotect_none_calls >= 1);
    void *ret = NULL;
    CHECK(T(pthread_join)(t, &ret) == 0 && ret == (void *)0x5151);
    CHECK(ti.self == t && ti.port == last_create.port && (ti.port & 3) == 3);
    CHECK(ti.is_main == 0 && ti.errno_ok && ti.tid >= 5000);
    CHECK(ti.qos == 0x15);
    CHECK(ti.stackaddr == t && ti.stacksize == 0x80000);
    CHECK(mapped_bytes == base_mapped);
    CHECK(T(pthread_join)(t, NULL) == 3); /* reaped: ESRCH */

    /* 2. pthread_exit inside a thread: cleanup handlers and TSD destructors
     *    run on that thread, and the joiner gets the value. */
    CHECK(T(pthread_key_create)(&t_key, t_dtor) == 0);
    CHECK(T(pthread_create)(&t, NULL, exit_thread, NULL) == 0);
    CHECK(T(pthread_join)(t, &ret) == 0 && ret == (void *)0x6262);
    CHECK(t_cleanups == 1 && t_dtors == 1);
    CHECK(T(pthread_getspecific)(t_key) == NULL); /* the main thread's slot is its own */

    /* 3. Join waits on the gate: the thread is still running when join
     *    starts; the gate store comes from the kernel's terminate. */
    long g0 = terminates_gate;
    release_flag = 0;
    CHECK(T(pthread_create)(&t, NULL, wait_release_thread, (void *)7) == 0);
    struct joinrace j1 = { t, -1 }, j2 = { t, -1 };
    pthread_t h1, h2;
    pthread_create(&h1, NULL, join_racer, &j1);
    usleep(20000);
    pthread_create(&h2, NULL, join_racer, &j2);
    pthread_join(h2, NULL); /* the second joiner fails at once */
    CHECK(j2.r == 22);
    __atomic_store_n(&release_flag, 1, __ATOMIC_RELEASE);
    pthread_join(h1, NULL);
    CHECK(j1.r == 0 && terminates_gate == g0 + 1);
    CHECK(mapped_bytes == base_mapped);

    /* 4. Detached by attribute: the thread frees itself through the kernel
     *    (stack + guard + pthread_t), with no gate. */
    yattr_t a;
    T(pthread_attr_init)(&a);
    T(pthread_attr_setdetachstate)(&a, 2);
    long f0 = terminates_freeing;
    release_flag = 0;
    CHECK(T(pthread_create)(&t, &a, wait_release_thread, NULL) == 0);
    CHECK(T(pthread_join)(t, NULL) == 22);   /* detached: EINVAL */
    CHECK(T(pthread_detach)(t) == 22);
    __atomic_store_n(&release_flag, 1, __ATOMIC_RELEASE);
    wait_until(&terminates_freeing, f0 + 1);
    CHECK(terminates_freeing == f0 + 1 && mapped_bytes == base_mapped);
    CHECK(T(pthread_join)(t, NULL) == 3);    /* gone from the list */

    /* 5. pthread_detach of a running thread, then of an exited (zombie)
     *    thread: both end with the memory given back. */
    release_flag = 0;
    CHECK(T(pthread_create)(&t, NULL, wait_release_thread, NULL) == 0);
    CHECK(T(pthread_detach)(t) == 0);
    f0 = terminates_freeing;
    __atomic_store_n(&release_flag, 1, __ATOMIC_RELEASE);
    wait_until(&terminates_freeing, f0 + 1);
    CHECK(mapped_bytes == base_mapped);
    g0 = terminates_gate;
    CHECK(T(pthread_create)(&t, NULL, quick_thread, NULL) == 0);
    wait_until(&terminates_gate, g0 + 1);
    CHECK(T(pthread_detach)(t) == 0);        /* zombie: reaped here */
    CHECK(mapped_bytes == base_mapped);
    CHECK(T(pthread_detach)(t) == 3);

    /* 6. A caller-supplied stack: only the pthread_t page is mapped, the
     *    kernel gets the stack top, and join leaves the stack alone. */
    size_t ssz = 64 * 1024;
    unsigned char *stk = aligned_alloc(16384, ssz);
    memset(&ti, 0, sizeof ti);
    T(pthread_attr_init)(&a);
    CHECK(T(pthread_attr_setstack)(&a, stk, ssz) == 0);
    CHECK(T(pthread_create)(&t, &a, probe_thread, &ti) == 0);
    CHECK(last_create.stack == stk + ssz && mapped_bytes == base_mapped + 16384);
    CHECK(T(pthread_join)(t, NULL) == 0);
    CHECK(ti.stackaddr == stk + ssz && ti.stacksize == ssz && mapped_bytes == base_mapped);
    free(stk);

    /* 7. QoS and scheduling attributes reach the kernel flags. */
    T(pthread_attr_init)(&a);
    CHECK(T(pthread_attr_set_qos_class_np)(&a, 0x19, -2) == 0);
    memset(&ti, 0, sizeof ti);
    CHECK(T(pthread_create)(&t, &a, probe_thread, &ti) == 0);
    CHECK(last_create.flags == (0x01000000u | 0x08000000u | 0x10FDu));
    CHECK(T(pthread_join)(t, NULL) == 0 && ti.qos == 0x19);
    T(pthread_attr_init)(&a);
    struct ysp sp = { 40, { 0 } };
    CHECK(T(pthread_attr_setschedpolicy)(&a, 2) == 0 && T(pthread_attr_setschedparam)(&a, &sp) == 0);
    CHECK(T(pthread_create)(&t, &a, quick_thread, NULL) == 0);
    CHECK(last_create.flags == (0x01000000u | 0x02000000u | (2u << 16) | 40u));
    CHECK(T(pthread_join)(t, NULL) == 0);

    /* 8. Suspended creation: nothing runs until the thread is resumed. */
    memset(&ti, 0, sizeof ti);
    CHECK(T(pthread_create_suspended_np)(&t, NULL, probe_thread, &ti) == 0);
    CHECK((last_create.flags & 0x20000000u) && suspended_pending);
    uint64_t tid;
    CHECK(T(pthread_threadid_np)(t, &tid) == 3); /* no ID before it runs */
    usleep(5000);
    CHECK(ti.self == NULL);
    fake_resume_suspended();
    CHECK(T(pthread_join)(t, &ret) == 0 && ti.self == t && ret == (void *)0x5151);

    /* 9. The other creation entry points, and the error cases. */
    CHECK(T(pthread_create_from_mach_thread)(&t, NULL, quick_thread, (void *)3) == 0);
    CHECK(T(pthread_join)(t, &ret) == 0 && ret == (void *)3);
    CHECK(T(pthread_create_with_workgroup_np)(&t, (void *)0x1234, NULL, quick_thread, (void *)4) == 0);
    CHECK(T(pthread_join)(t, &ret) == 0 && ret == (void *)4);
    CHECK(T(pthread_create)(&t, NULL, NULL, NULL) == 22);
    yattr_t bad = { 0x1111, { 0 } };
    CHECK(T(pthread_create)(&t, &bad, quick_thread, NULL) == 22);
    CHECK(T(pthread_join)(me, NULL) == 11);

    /* 10. Many threads at once: a condition-variable start barrier, then
     *     mutex contention, all joined; nothing leaks. */
    enum { N = 24 };
    ypthread_t ts[N];
    st_ready = 0;
    st_counter = 0;
    for (int i = 0; i < N; i++)
        CHECK(T(pthread_create)(&ts[i], NULL, stress_thread, NULL) == 0);
    usleep(20000);
    T(pthread_mutex_lock)(&st_m);
    st_ready = 1;
    T(pthread_cond_broadcast)(&st_c);
    T(pthread_mutex_unlock)(&st_m);
    for (int i = 0; i < N; i++)
        CHECK(T(pthread_join)(ts[i], NULL) == 0);
    CHECK(st_counter == N * 2000);
    CHECK(mapped_bytes == base_mapped);
    CHECK(T(pthread_from_mach_thread_np)(last_create.port) == NULL);
}

/* The last thread to exit ends the process with status 0; a main thread
 * that calls pthread_exit does not, while another thread lives. */
static void last_exit_child_exit(int status) { _exit(40 + status); }
static void *last_exit_worker(void *arg) { (void)arg; usleep(30000); return NULL; }
static void last_exit_child(void)
{
    struct ypfuncs f = { 1, last_exit_child_exit, NULL, NULL };
    T(__pthread_init)(&f, NULL, NULL, NULL);
    ypthread_t t;
    if (T(pthread_create)(&t, NULL, last_exit_worker, NULL) != 0)
        _exit(1);
    T(pthread_exit)(NULL); /* the main thread leaves first */
}

static void test_last_thread_exit(void)
{
    fflush(stdout);
    fflush(stderr);
    pid_t pid = fork();
    if (pid == 0) {
        last_exit_child();
        _exit(2);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 40);
}

/* ---- tests: the workqueue ---------------------------------------------- */

int T(_pthread_workqueue_addthreads)(int, uint64_t);
int T(_pthread_workqueue_add_cooperativethreads)(int, uint64_t);
int T(_pthread_workqueue_should_narrow)(uint64_t);
int T(_pthread_workqueue_set_event_manager_priority)(uint64_t);
int T(_pthread_workloop_create)(uint64_t, uint64_t, const yattr_t *);
int T(_pthread_workloop_destroy)(uint64_t, uint64_t);
int T(_pthread_workqueue_init_with_workloop)(void *, void *, void *, int, int);

struct ykev { uint64_t ident; int16_t filter; uint16_t flags; int32_t qos; uint64_t udata;
              uint32_t fflags, xflags; int64_t data; uint64_t ext[4]; };

static long wq_calls, wq_bad;
static uint64_t wq_pp_seen[8];
static void wq_cb(uint64_t pp)
{
    unsigned char *self = (unsigned char *)T(pthread_self)();
    int ok = tsd()[0] == (uintptr_t)self && tsd()[4] == pp && T(pthread_main_np)() == 0 &&
             tsd()[3] != 0 && (tsd()[3] & 3) == 3 && T(pthread_is_threaded_np)() == 1 &&
             T(pthread_get_stacksize_np)(self) == (512 + 12) * 1024 && /* bottom .. self */
             T(pthread_detach)(self) == 22 && T(_pthread_workqueue_should_narrow)(0x8FF) == 0;
    if (!ok)
        __atomic_fetch_add(&wq_bad, 1, __ATOMIC_RELAXED);
    long i = __atomic_fetch_add(&wq_calls, 1, __ATOMIC_RELAXED);
    if (i < 8) wq_pp_seen[i] = pp;
}

static long kev_calls, kev_bad;
static void kev_cb(void **events, int *nevents)
{
    unsigned char *self = (unsigned char *)T(pthread_self)();
    struct ykev *ev = *events;
    long i = __atomic_fetch_add(&kev_calls, 1, __ATOMIC_RELAXED);
    if (i == 0) {
        /* The QoS bucket upcall: three events at self - 1152. */
        int ok = (unsigned char *)ev == self - 1152 && *nevents == 3 && ev[0].ident == 11 &&
                 ev[2].ident == 13 && tsd()[4] == (0x80000000ul | 0x01000000ul | 0x8FFul);
        /* Unbinding goes to the kernel and clears NEEDS_UNBIND. */
        T(_pthread_set_properties_self)(0x10, tsd()[4], 0);
        ok = ok && ctl_cmd == 0x100 && ctl_flags == 0x10 && !(tsd()[4] & 0x01000000ul);
        if (!ok) __atomic_fetch_add(&kev_bad, 1, __ATOMIC_RELAXED);
        *events = ev + 1; /* hand back a rewritten change list */
        *nevents = 1;
    } else {
        /* The manager upcall. */
        if (tsd()[4] != 0x02000000ul || *nevents != 0)
            __atomic_fetch_add(&kev_bad, 1, __ATOMIC_RELAXED);
    }
}

static long wl_calls, wl_bad;
static void wl_cb(uint64_t *id, void **events, int *nevents)
{
    unsigned char *self = (unsigned char *)T(pthread_self)();
    struct ykev *ev = *events;
    if (*id != 0xABCD00ull || (unsigned char *)ev != self - 1152 || *nevents != 2 || ev[1].ident == 0 ||
        tsd()[4] != (0x01000000ul | 0x10FFul))
        __atomic_fetch_add(&wl_bad, 1, __ATOMIC_RELAXED);
    *nevents = 0;
    __atomic_fetch_add(&wl_calls, 1, __ATOMIC_RELAXED);
}

/* The exact byte layout (threads-and-events.md addendum): flags @0,
 * version @4, kevent_cb @8, workloop_cb @16, workq_cb @24,
 * serialno_offs @32, label_offs @40; 48 bytes. */
struct ywqconfig { uint32_t flags, version; void *kevent_cb, *workloop_cb, *workq_cb;
                   uint64_t serialno_offs, label_offs; };
_Static_assert(sizeof(struct ywqconfig) == 48, "pthread_workqueue_config is 48 bytes");
_Static_assert(offsetof(struct ywqconfig, version) == 4 && offsetof(struct ywqconfig, kevent_cb) == 8 &&
               offsetof(struct ywqconfig, workloop_cb) == 16 && offsetof(struct ywqconfig, workq_cb) == 24 &&
               offsetof(struct ywqconfig, serialno_offs) == 32 && offsetof(struct ywqconfig, label_offs) == 40,
               "pthread_workqueue_config layout");

static void test_workqueue(void)
{
    CHECK(T(_pthread_workqueue_addthreads)(1, 0x8FF) == 1); /* EPERM before setup */
    /* Built byte by byte, so the test pins the layout, not a C struct. */
    unsigned char raw[48];
    memset(raw, 0, sizeof raw);
    uint32_t w32 = 2;
    memcpy(raw + 4, &w32, 4);                      /* version @4; flags @0 = 0 */
    void *fp = (void *)kev_cb;  memcpy(raw + 8, &fp, 8);
    fp = (void *)wl_cb;         memcpy(raw + 16, &fp, 8);
    fp = (void *)wq_cb;         memcpy(raw + 24, &fp, 8);
    uint64_t w64 = 0x30;        memcpy(raw + 32, &w64, 8);
    w64 = 0x48;                 memcpy(raw + 40, &w64, 8);
    CHECK(T(pthread_workqueue_setup)(raw, 40) == 22);  /* too short for version 2 */
    w32 = 3; memcpy(raw + 4, &w32, 4);
    CHECK(T(pthread_workqueue_setup)(raw, sizeof raw) == 22); /* version 3 */
    w32 = 0; memcpy(raw + 4, &w32, 4);
    CHECK(T(pthread_workqueue_setup)(raw, sizeof raw) == 22); /* version 0 */
    w32 = 2; memcpy(raw + 4, &w32, 4);
    w32 = 1; memcpy(raw, &w32, 4);
    CHECK(T(pthread_workqueue_setup)(raw, sizeof raw) == 45); /* flags 1: ENOTSUP */
    w32 = 0; memcpy(raw, &w32, 4);
    CHECK(T(pthread_workqueue_setup)(raw, sizeof raw) == 0);
    struct ywqconfig cfg;
    memcpy(&cfg, raw, sizeof cfg);
    uint32_t u32; uint64_t u64;
    CHECK(setup_calls == 1 && setup_size == 24);
    memcpy(&u32, setup_record, 4); CHECK(u32 == 2);
    memcpy(&u32, setup_record + 4, 4); CHECK(u32 == 0);
    memcpy(&u64, setup_record + 8, 8); CHECK(u64 == 0x30);
    memcpy(&u64, setup_record + 16, 8); CHECK(u64 == 0x48);
    CHECK(workq_open_calls == 1 && T(pthread_is_threaded_np)() == 1);
    CHECK(T(pthread_workqueue_setup)(&cfg, sizeof cfg) == 0);     /* same callbacks */
    struct ywqconfig other = cfg;
    other.workq_cb = (void *)kev_cb;
    CHECK(T(pthread_workqueue_setup)(&other, sizeof other) == 16); /* EBUSY */
    CHECK(T(_pthread_workqueue_init_with_workloop)((void *)wq_cb, (void *)kev_cb, (void *)wl_cb, 0, 0) == 0);
    CHECK(setup_calls == 1);

    /* Plain requests: the ROOTQUEUE bit is not passed to the kernel; each
     * worker builds its pthread_t in place and gets workq_cb(pp). */
    long r0 = wq_retired;
    CHECK(T(_pthread_workqueue_addthreads)(2, 0x20000000ul | 0x80000000ul | 0x10FFul) == 0);
    CHECK(reqthreads_count == 2 && (uint32_t)reqthreads_pp == 0x800010FFu);
    wait_until(&wq_retired, r0 + 2);
    CHECK(wq_calls == 2 && wq_bad == 0 && wq_retired == r0 + 2 && wq_bad_region == 0);
    CHECK(wq_pp_seen[0] == 0x800010FFul && wq_pp_seen[1] == 0x800010FFul);
    CHECK(last_return_op == 0x004);

    /* REUSE: the same worker runs three plain items, then retires. */
    r0 = wq_retired;
    fake_spawn_worker(0, 3, NULL, 0, 0, 2);
    wait_until(&wq_retired, r0 + 1);
    CHECK(wq_calls == 5 && wq_bad == 0 && wq_pp_seen[4] == 0x4FFul);

    /* A kevent upcall: the callback rewrites the list it hands back. */
    struct ykev evs[3];
    memset(evs, 0, sizeof evs);
    evs[0].ident = 11; evs[1].ident = 12; evs[2].ident = 13;
    r0 = wq_retired;
    fake_spawn_worker(0x00080000u | 0x00010000u, 4, evs, 3, 0, 0);
    wait_until(&wq_retired, r0 + 1);
    CHECK(kev_calls == 1 && kev_bad == 0 && last_return_op == 0x040 && last_return_n == 1);
    CHECK(last_return_item != NULL && last_return_ident == 12);

    /* The event manager (QoS 8): pp is EVENT_MANAGER alone. */
    r0 = wq_retired;
    fake_spawn_worker(0x00080000u | 0x00100000u, 8, NULL, 0, 0, 0);
    wait_until(&wq_retired, r0 + 1);
    CHECK(kev_calls == 2 && kev_bad == 0);

    /* A workloop upcall: the ID comes from the list - 8. */
    r0 = wq_retired;
    fake_spawn_worker(0x00080000u | 0x00400000u, 5, evs, 2, 0xABCD00ull, 0);
    wait_until(&wq_retired, r0 + 1);
    CHECK(wl_calls == 1 && wl_bad == 0 && last_return_op == 0x100 && last_return_n == 0);

    /* Cooperative requests without a cooperative pool: a constrained
     * request whose worker is marked cooperative. */
    r0 = wq_retired;
    long w0 = wq_calls;
    CHECK(T(_pthread_workqueue_add_cooperativethreads)(1, 0x4FF) == 0);
    CHECK(reqthreads2_calls == 1 && (uint32_t)reqthreads_pp == 0x4FFu);
    wait_until(&wq_retired, r0 + 1);
    CHECK(wq_calls == w0 + 1 && wq_pp_seen[5] == (0x08000000ul | 0x4FFul));

    CHECK(T(_pthread_workqueue_should_narrow)(0x8FF) == 0); /* not a workqueue thread */
    CHECK(T(_pthread_workqueue_set_event_manager_priority)(0x20FF) == 0 && mgr_prio == 0x20FF);

    /* Workloops with scheduling parameters (kqueue_workloop_ctl). */
    yattr_t a;
    T(pthread_attr_init)(&a);
    struct ysp sp = { 47, { 0 } };
    T(pthread_attr_setschedpolicy)(&a, 4);
    T(pthread_attr_setschedparam)(&a, &sp);
    CHECK(T(_pthread_workloop_create)(0x5000, 0, &a) == 0 && wl_cmd == 1);
    int32_t i32;
    memcpy(&i32, wl_params, 4); CHECK(i32 == 36);
    memcpy(&i32, wl_params + 4, 4); CHECK(i32 == 3);
    memcpy(&u64, wl_params + 8, 8); CHECK(u64 == 0x5000);
    memcpy(&i32, wl_params + 16, 4); CHECK(i32 == 47);
    memcpy(&i32, wl_params + 20, 4); CHECK(i32 == 4);
    CHECK(T(_pthread_workloop_destroy)(0x5000, 0) == 0 && wl_cmd == 2);
    memcpy(&u64, wl_params + 8, 8); CHECK(u64 == 0x5000);
}

int main(void)
{
    test_identity_before_init();
    test_mutex_static();
    test_mutex_attr();
    test_mutex_threads();
    test_init();
    test_tsd();
    test_once();
    test_cond();
    test_rwlock();
    test_attr();
    test_qos();
    test_threads();
    test_last_thread_exit();
    test_workqueue();
    test_misc();
    printf("pthread host tests: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
