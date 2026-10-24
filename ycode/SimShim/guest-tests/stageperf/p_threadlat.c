/* Ycode performance probe: guest thread start and wakeup latency
 * (specs/simulator/thread-latency.md section 5). Original Ycode code.
 *
 * Every latency is measured in the guest with mach_absolute_time (one
 * clock for every thread and process of the system):
 *   create   pthread_create to the new thread's first statement, one thread
 *            at a time (its vCPU is free again once the thread is joined);
 *   burst    in each of BURST_CHILDREN fresh processes, BURST_THREADS
 *            threads started back to back and kept alive (each needs a vCPU
 *            of its own: the creation path), then a second burst after
 *            they ended (parked vCPUs);
 *   dispatch dispatch_async_f on a global queue to the block's first
 *            statement, back to back and after 30 ms idle;
 *   sem      semaphore_signal to the waiting thread's return from
 *            semaphore_wait;
 *   cond     pthread_cond_signal to the waiting thread's return from
 *            pthread_cond_wait.
 * Prints one line per measure, "threadlat <name> n= p50= p90= p99= max=" in
 * microseconds, then "threadlat ok". */
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/semaphore.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>

#include "../stage4b/probe_util.h"

#define ROUNDS 300
#define BURST_CHILDREN 6
#define BURST_THREADS 12
#define MAX_SAMPLES 4096

static mach_timebase_info_data_t timebase;

static double to_us(uint64_t ticks) { return (double)ticks * timebase.numer / timebase.denom / 1000.0; }

static int compare_u64(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

static void report(const char *name, uint64_t *v, int n)
{
    if (n == 0) {
        printf("threadlat %s n=0\n", name);
        return;
    }
    qsort(v, (size_t)n, sizeof v[0], compare_u64);
    int p90 = (n * 9 + 9) / 10 - 1, p99 = (n * 99 + 99) / 100 - 1;
    printf("threadlat %s n=%d p50=%.0f p90=%.0f p99=%.0f max=%.0f us\n", name, n, to_us(v[n / 2]), to_us(v[p90]),
           to_us(v[p99]), to_us(v[n - 1]));
    fflush(stdout);
}

/* ---- create: one thread at a time ---- */

static _Atomic uint64_t started_at;

static void *note_start(void *arg)
{
    (void)arg;
    atomic_store(&started_at, mach_absolute_time());
    return NULL;
}

static void measure_create(void)
{
    static uint64_t v[ROUNDS];
    for (int i = 0; i < ROUNDS; i++) {
        pthread_t t;
        uint64_t t0 = mach_absolute_time();
        if (pthread_create(&t, NULL, note_start, NULL) != 0)
            probe_fail("pthread_create");
        pthread_join(t, NULL);
        v[i] = atomic_load(&started_at) - t0;
    }
    report("create", v, ROUNDS);
}

/* ---- burst: many live threads (child process) ---- */

struct burst_slot {
    uint64_t requested;
    _Atomic uint64_t started;
};
static struct burst_slot slots[BURST_THREADS];
static _Atomic int release_threads;

static void *burst_thread(void *arg)
{
    struct burst_slot *s = arg;
    atomic_store(&s->started, mach_absolute_time());
    while (!atomic_load(&release_threads))
        probe_sleep_ms(1);
    return NULL;
}

static void run_burst(const char *name)
{
    pthread_t t[BURST_THREADS];
    uint64_t v[BURST_THREADS];
    atomic_store(&release_threads, 0);
    for (int i = 0; i < BURST_THREADS; i++) {
        atomic_store(&slots[i].started, 0);
        slots[i].requested = mach_absolute_time();
        if (pthread_create(&t[i], NULL, burst_thread, &slots[i]) != 0)
            probe_fail("pthread_create (burst %d)", i);
    }
    for (int i = 0; i < BURST_THREADS; i++) {
        for (int waited = 0; atomic_load(&slots[i].started) == 0; waited++) {
            if (waited > PROBE_TIMEOUT_MS)
                probe_fail("burst thread %d never started", i);
            probe_sleep_ms(1);
        }
        v[i] = atomic_load(&slots[i].started) - slots[i].requested;
    }
    atomic_store(&release_threads, 1);
    for (int i = 0; i < BURST_THREADS; i++)
        pthread_join(t[i], NULL);
    report(name, v, BURST_THREADS);
}

/* ---- dispatch ---- */

struct dispatch_probe {
    uint64_t queued;
    uint64_t ran;
    dispatch_semaphore_t done;
};

static void dispatch_note(void *arg)
{
    struct dispatch_probe *p = arg;
    p->ran = mach_absolute_time();
    dispatch_semaphore_signal(p->done);
}

static void measure_dispatch(const char *name, int idle_ms)
{
    static uint64_t v[ROUNDS];
    int rounds = idle_ms > 0 ? 60 : ROUNDS;
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
    struct dispatch_probe p = {0, 0, dispatch_semaphore_create(0)};
    for (int i = 0; i < rounds; i++) {
        if (idle_ms > 0)
            probe_sleep_ms(idle_ms);
        p.queued = mach_absolute_time();
        dispatch_async_f(q, &p, dispatch_note);
        if (dispatch_semaphore_wait(p.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)PROBE_TIMEOUT_MS * 1000000)) != 0)
            probe_fail("dispatch round %d timed out", i);
        v[i] = p.ran - p.queued;
    }
    report(name, v, rounds);
}

/* ---- wakeups: Mach semaphore and pthread condition ---- */

static semaphore_t sem_go, sem_back;
static _Atomic uint64_t signalled_at;
static uint64_t sem_v[ROUNDS];

static void *sem_waiter(void *arg)
{
    (void)arg;
    for (int i = 0; i < ROUNDS; i++) {
        if (semaphore_wait(sem_go) != KERN_SUCCESS)
            probe_fail("semaphore_wait");
        sem_v[i] = mach_absolute_time() - atomic_load(&signalled_at);
        semaphore_signal(sem_back);
    }
    return NULL;
}

static void measure_semaphore(void)
{
    if (semaphore_create(mach_task_self(), &sem_go, SYNC_POLICY_FIFO, 0) != KERN_SUCCESS ||
        semaphore_create(mach_task_self(), &sem_back, SYNC_POLICY_FIFO, 0) != KERN_SUCCESS)
        probe_fail("semaphore_create");
    pthread_t t;
    pthread_create(&t, NULL, sem_waiter, NULL);
    for (int i = 0; i < ROUNDS; i++) {
        probe_sleep_ms(1); /* let the waiter block */
        atomic_store(&signalled_at, mach_absolute_time());
        semaphore_signal(sem_go);
        if (semaphore_wait(sem_back) != KERN_SUCCESS)
            probe_fail("semaphore_wait (back)");
    }
    pthread_join(t, NULL);
    report("sem", sem_v, ROUNDS);
}

static pthread_mutex_t cm = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER, cv_back = PTHREAD_COND_INITIALIZER;
static int turn; /* 0: main's turn to signal, 1: the waiter's */
static uint64_t cond_v[ROUNDS];

static void *cond_waiter(void *arg)
{
    (void)arg;
    for (int i = 0; i < ROUNDS; i++) {
        pthread_mutex_lock(&cm);
        while (turn != 1)
            pthread_cond_wait(&cv, &cm);
        cond_v[i] = mach_absolute_time() - atomic_load(&signalled_at);
        turn = 0;
        pthread_cond_signal(&cv_back);
        pthread_mutex_unlock(&cm);
    }
    return NULL;
}

static void measure_cond(void)
{
    pthread_t t;
    pthread_create(&t, NULL, cond_waiter, NULL);
    for (int i = 0; i < ROUNDS; i++) {
        probe_sleep_ms(1);
        pthread_mutex_lock(&cm);
        turn = 1;
        atomic_store(&signalled_at, mach_absolute_time());
        pthread_cond_signal(&cv);
        while (turn != 0)
            pthread_cond_wait(&cv_back, &cm);
        pthread_mutex_unlock(&cm);
    }
    pthread_join(t, NULL);
    report("cond", cond_v, ROUNDS);
}

int main(int argc, char **argv)
{
    probe_name = "threadlat";
    mach_timebase_info(&timebase);
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc > 1 && strcmp(argv[1], "burst") == 0) {
        run_burst("burst.fresh");
        run_burst("burst.parked");
        return 0;
    }
    const char *self = probe_self_path(argv[0]);
    measure_create();
    for (int c = 0; c < BURST_CHILDREN; c++) {
        pid_t pid;
        if (probe_spawn(&pid, self, NULL, NULL, "burst", NULL) != 0)
            probe_fail("posix_spawn (burst child %d)", c);
        probe_expect_exit(pid, 0, "burst child");
    }
    measure_dispatch("dispatch", 0);
    measure_dispatch("dispatch.idle30ms", 30);
    measure_semaphore();
    measure_cond();
    printf("threadlat ok\n");
    return 0;
}
