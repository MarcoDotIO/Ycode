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
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
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
int T(pthread_workqueue_setup)(void *, size_t);

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

int yc_testk___ulock_wait(uint32_t op, void *addr, uint64_t value, uint32_t timeout)
{
    (void)op; (void)addr; (void)value; (void)timeout;
    sched_yield();
    return 0;
}

int yc_testk___ulock_wait2(uint32_t op, void *addr, uint64_t value, uint64_t timeout, uint64_t v2)
{
    (void)op; (void)v2;
    if (__atomic_load_n((uint32_t *)addr, __ATOMIC_ACQUIRE) != (uint32_t)value)
        return 0;
    if (timeout != 0)
        return -60; /* the deadline passes at once: ETIMEDOUT */
    sched_yield(); /* a spurious wake-up is always allowed */
    return 0;
}

static long wake_calls;
int yc_testk___ulock_wake(uint32_t op, void *addr, uint64_t v)
{
    (void)op; (void)addr; (void)v;
    __atomic_fetch_add(&wake_calls, 1, __ATOMIC_RELAXED);
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

uint64_t yc_testk___thread_selfid(void) { return 4242; }
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

static void cond_wait_alone(void)
{
    ycond_t c = YCOND_INIT;
    ymutex_t m = YMUTEX_INIT;
    T(pthread_mutex_lock)(&m);
    T(pthread_cond_wait)(&c, &m);
}

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
    CHECK(crashes(cond_wait_alone));

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
    CHECK(T(pthread_rwlock_wrlock)(&l) == 11); /* single thread: would wait forever */
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
    CHECK(T(pthread_workqueue_setup)(cfg, sizeof cfg) == 0);
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
    test_misc();
    printf("pthread host tests: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
