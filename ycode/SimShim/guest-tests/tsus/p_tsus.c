// Guest probe: Mach thread and task suspension through public API only
// (specs/simulator/threads-and-events.md §1.6).
//   p_tsus            the checks below
//   p_tsus child      (internal) prints a counter every 10 ms until killed
//
// Checks: a spinning thread stops before thread_suspend returns and stays
// stopped (its counter does not move for 100 ms); thread_get_state gives its
// registers (SP inside its stack); resume restarts it; counted suspends;
// resume at count 0 fails; a thread that suspends itself waits for another
// thread's resume; a thread blocked in semaphore_wait counts as suspended
// and does not return to user code while suspended even when signalled;
// thread_info reports the stop; thread_set_state redirects a suspended
// thread; task_suspend/task_resume of a child (which sends its task port
// to its bootstrap port, ours), and a child spawned with
// POSIX_SPAWN_START_SUSPENDED that runs after SIGCONT resumes its task.
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static int failures;
static void check(int ok, const char *what) {
    printf("%s %s\n", ok ? "ok" : "FAIL", what);
    fflush(stdout);
    if (!ok) failures++;
}

static void sleep_ms(int ms) {
    struct timespec t = {ms / 1000, (long)(ms % 1000) * 1000000L};
    while (nanosleep(&t, &t) != 0 && errno == EINTR) {}
}

static uint64_t now_us(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000u + (uint64_t)t.tv_nsec / 1000u;
}

// MARK: spinning thread

static _Atomic uint64_t spin_counter;
static _Atomic int spin_stop;
static _Atomic int redirected;
static mach_port_t spin_port;
static void *spin_stack_lo, *spin_stack_hi;

__attribute__((noinline)) static void spin_loop(void) {
    while (!atomic_load_explicit(&spin_stop, memory_order_relaxed))
        atomic_fetch_add_explicit(&spin_counter, 1, memory_order_relaxed);
}

// Where thread_set_state sends the spinning thread: it marks the flag and
// spins on until told to stop, then ends the thread.
__attribute__((noinline)) static void redirect_target(void) {
    atomic_store(&redirected, 1);
    while (!atomic_load_explicit(&spin_stop, memory_order_relaxed))
        atomic_fetch_add_explicit(&spin_counter, 1, memory_order_relaxed);
    pthread_exit(NULL);
}

static void *spin_main(void *arg) {
    (void)arg;
    pthread_t self = pthread_self();
    spin_stack_hi = pthread_get_stackaddr_np(self);
    spin_stack_lo = (char *)spin_stack_hi - pthread_get_stacksize_np(self);
    spin_port = pthread_mach_thread_np(self);
    spin_loop();
    return NULL;
}

static int stays_still(int ms) {
    uint64_t a = atomic_load(&spin_counter);
    sleep_ms(ms);
    return atomic_load(&spin_counter) == a;
}

static int moves(int ms) {
    uint64_t a = atomic_load(&spin_counter);
    for (int i = 0; i < ms / 5; i++) {
        sleep_ms(5);
        if (atomic_load(&spin_counter) != a) return 1;
    }
    return 0;
}

static void spinning_checks(void) {
    pthread_t t;
    pthread_create(&t, NULL, spin_main, NULL);
    while (atomic_load(&spin_counter) < 1000) sleep_ms(1);

    uint64_t t0 = now_us();
    kern_return_t kr = thread_suspend(spin_port);
    uint64_t took = now_us() - t0;
    check(kr == KERN_SUCCESS, "thread_suspend of a spinning thread");
    printf("  thread_suspend took %llu us\n", (unsigned long long)took);
    check(stays_still(100), "its counter stays still for 100 ms");

    arm_thread_state64_t st;
    mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
    kr = thread_get_state(spin_port, ARM_THREAD_STATE64, (thread_state_t)&st, &n);
    check(kr == KERN_SUCCESS && n == ARM_THREAD_STATE64_COUNT, "thread_get_state(ARM_THREAD_STATE64) of it");
    uint64_t sp = arm_thread_state64_get_sp(st), pc = arm_thread_state64_get_pc(st), fp = arm_thread_state64_get_fp(st);
    printf("  pc 0x%llx sp 0x%llx fp 0x%llx lr 0x%llx; stack %p-%p; spin_loop %p\n", (unsigned long long)pc,
           (unsigned long long)sp, (unsigned long long)fp, (unsigned long long)arm_thread_state64_get_lr(st),
           spin_stack_lo, spin_stack_hi, (void *)spin_loop);
    check(sp >= (uint64_t)spin_stack_lo && sp < (uint64_t)spin_stack_hi, "its SP is inside its stack");
    check(fp >= sp && fp < (uint64_t)spin_stack_hi, "its FP is above SP inside its stack");
    check(pc >= (uint64_t)spin_loop && pc < (uint64_t)spin_loop + 256, "its PC is in the spin loop");

    thread_basic_info_data_t bi;
    n = THREAD_BASIC_INFO_COUNT;
    kr = thread_info(spin_port, THREAD_BASIC_INFO, (thread_info_t)&bi, &n);
    check(kr == KERN_SUCCESS && bi.suspend_count == 1 && bi.run_state == TH_STATE_STOPPED,
          "thread_info: suspend count 1, TH_STATE_STOPPED");

    check(thread_suspend(spin_port) == KERN_SUCCESS, "a second thread_suspend");
    check(thread_resume(spin_port) == KERN_SUCCESS, "one thread_resume");
    check(stays_still(50), "still stopped at count 1");
    check(thread_resume(spin_port) == KERN_SUCCESS, "the second thread_resume");
    check(moves(500), "its counter moves again");
    check(thread_resume(spin_port) == KERN_FAILURE, "thread_resume at count 0: KERN_FAILURE");

    // Many short suspensions in a row (a collector's pattern).
    int bad = 0;
    uint64_t total = 0;
    for (int i = 0; i < 2000; i++) {
        t0 = now_us();
        if (thread_suspend(spin_port) != KERN_SUCCESS) bad++;
        total += now_us() - t0;
        uint64_t a = atomic_load(&spin_counter);
        n = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(spin_port, ARM_THREAD_STATE64, (thread_state_t)&st, &n) != KERN_SUCCESS) bad++;
        if (atomic_load(&spin_counter) != a) bad++;
        if (thread_resume(spin_port) != KERN_SUCCESS) bad++;
    }
    printf("  2000 suspend/get_state/resume rounds: mean suspend %llu us\n", (unsigned long long)(total / 2000));
    check(bad == 0, "2000 suspend/get_state/resume rounds, each stopped");

    // thread_set_state: send it to redirect_target.
    check(thread_suspend(spin_port) == KERN_SUCCESS, "suspend before thread_set_state");
    n = ARM_THREAD_STATE64_COUNT;
    kr = thread_get_state(spin_port, ARM_THREAD_STATE64, (thread_state_t)&st, &n);
    arm_thread_state64_set_pc_fptr(st, redirect_target);
    // A 16-byte aligned SP below the current one.
    arm_thread_state64_set_sp(st, (arm_thread_state64_get_sp(st) - 256) & ~15ull);
    kr = thread_set_state(spin_port, ARM_THREAD_STATE64, (thread_state_t)&st, ARM_THREAD_STATE64_COUNT);
    check(kr == KERN_SUCCESS, "thread_set_state(ARM_THREAD_STATE64)");
    arm_thread_state64_t back;
    n = ARM_THREAD_STATE64_COUNT;
    thread_get_state(spin_port, ARM_THREAD_STATE64, (thread_state_t)&back, &n);
    check(arm_thread_state64_get_pc(back) == (uint64_t)redirect_target, "thread_get_state shows the new PC");
    check(thread_resume(spin_port) == KERN_SUCCESS, "resume after thread_set_state");
    for (int i = 0; i < 100 && !atomic_load(&redirected); i++) sleep_ms(5);
    check(atomic_load(&redirected), "the thread continues at the new PC");

    atomic_store(&spin_stop, 1);
    pthread_join(t, NULL);
}

// MARK: self-suspension

static _Atomic int self_after;
static mach_port_t self_port;
static _Atomic int self_ready;

static void *self_main(void *arg) {
    (void)arg;
    self_port = mach_thread_self();
    atomic_store(&self_ready, 1);
    kern_return_t kr = thread_suspend(mach_thread_self());
    atomic_store(&self_after, kr == KERN_SUCCESS ? 1 : 2);
    return NULL;
}

static void self_checks(void) {
    pthread_t t;
    pthread_create(&t, NULL, self_main, NULL);
    while (!atomic_load(&self_ready)) sleep_ms(1);
    sleep_ms(100);
    check(atomic_load(&self_after) == 0, "a thread that suspended itself does not run on");
    thread_basic_info_data_t bi;
    mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT;
    thread_info(self_port, THREAD_BASIC_INFO, (thread_info_t)&bi, &n);
    check(bi.suspend_count == 1, "its suspend count is 1");
    check(thread_resume(self_port) == KERN_SUCCESS, "another thread resumes it");
    pthread_join(t, NULL);
    check(atomic_load(&self_after) == 1, "its thread_suspend returned KERN_SUCCESS");
}

// MARK: a thread blocked in the kernel

static semaphore_t blocked_sem;
static _Atomic int blocked_after;
static mach_port_t blocked_port;
static _Atomic int blocked_ready;

static void *blocked_main(void *arg) {
    (void)arg;
    blocked_port = mach_thread_self();
    atomic_store(&blocked_ready, 1);
    semaphore_wait(blocked_sem);
    atomic_store(&blocked_after, 1);
    return NULL;
}

static void blocked_checks(void) {
    semaphore_create(mach_task_self(), &blocked_sem, SYNC_POLICY_FIFO, 0);
    pthread_t t;
    pthread_create(&t, NULL, blocked_main, NULL);
    while (!atomic_load(&blocked_ready)) sleep_ms(1);
    sleep_ms(50);
    uint64_t t0 = now_us();
    check(thread_suspend(blocked_port) == KERN_SUCCESS, "thread_suspend of a thread blocked in semaphore_wait");
    printf("  took %llu us\n", (unsigned long long)(now_us() - t0));
    arm_thread_state64_t st;
    mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
    check(thread_get_state(blocked_port, ARM_THREAD_STATE64, (thread_state_t)&st, &n) == KERN_SUCCESS,
          "thread_get_state of the blocked thread");
    semaphore_signal(blocked_sem);
    sleep_ms(100);
    check(atomic_load(&blocked_after) == 0, "signalled while suspended: it does not return to user code");
    n = ARM_THREAD_STATE64_COUNT;
    check(thread_get_state(blocked_port, ARM_THREAD_STATE64, (thread_state_t)&st, &n) == KERN_SUCCESS,
          "thread_get_state after its call completed");
    check(thread_resume(blocked_port) == KERN_SUCCESS, "resume");
    pthread_join(t, NULL);
    check(atomic_load(&blocked_after) == 1, "it returns from semaphore_wait after the resume");
    semaphore_destroy(mach_task_self(), blocked_sem);
}

// MARK: task suspension of a child

// Reads what is available on `fd` without waiting; returns the byte count.
static long drain(int fd) {
    char buf[4096];
    long total = 0;
    for (;;) {
        ssize_t r = read(fd, buf, sizeof buf);
        if (r <= 0) return total;
        total += r;
    }
}

// Spawns `self child` with stdout on a pipe (*out_fd, non-blocking). With
// `port`, the child's bootstrap port is a send right to it: the child sends
// its task port there first.
static pid_t spawn_child(const char *self, int start_suspended, mach_port_t port, int *out_fd) {
    int p[2];
    pipe(p);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, p[1], 1);
    posix_spawn_file_actions_addclose(&fa, p[0]);
    posix_spawnattr_t at;
    posix_spawnattr_init(&at);
    if (start_suspended) posix_spawnattr_setflags(&at, POSIX_SPAWN_START_SUSPENDED);
    if (port != MACH_PORT_NULL) posix_spawnattr_setspecialport_np(&at, port, TASK_BOOTSTRAP_PORT);
    char *argv[] = {(char *)self, "child", NULL};
    pid_t pid = -1;
    int rc = posix_spawn(&pid, self, &fa, &at, argv, environ);
    close(p[1]);
    fcntl(p[0], F_SETFL, O_NONBLOCK);
    *out_fd = p[0];
    if (rc != 0) printf("  posix_spawn: %d\n", rc);
    return rc == 0 ? pid : -1;
}

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t task;
} task_msg_t;

typedef struct {
    task_msg_t m;
    mach_msg_trailer_t trailer;
} task_msg_rcv_t;

// The child: its task port to its bootstrap port, then a counter on stdout.
static void child_main(void) {
    mach_port_t bp = MACH_PORT_NULL;
    task_get_bootstrap_port(mach_task_self(), &bp);
    task_msg_t m;
    memset(&m, 0, sizeof m);
    m.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    m.header.msgh_size = sizeof m;
    m.header.msgh_remote_port = bp;
    m.header.msgh_id = 0x7375;
    m.body.msgh_descriptor_count = 1;
    m.task.name = mach_task_self();
    m.task.disposition = MACH_MSG_TYPE_COPY_SEND;
    m.task.type = MACH_MSG_PORT_DESCRIPTOR;
    if (bp != MACH_PORT_NULL) mach_msg(&m.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
    for (unsigned long i = 0;; i++) {
        printf("%lu\n", i);
        fflush(stdout);
        sleep_ms(10);
    }
}

static void task_checks(const char *self) {
    mach_port_t port = MACH_PORT_NULL;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    int fd;
    pid_t pid = spawn_child(self, 0, port, &fd);
    check(pid > 0, "spawn a child (its bootstrap port is ours)");
    if (pid <= 0) return;
    task_msg_rcv_t r;
    memset(&r, 0, sizeof r);
    kern_return_t kr = mach_msg(&r.m.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof r, port, 5000, MACH_PORT_NULL);
    mach_port_t task = kr == KERN_SUCCESS ? r.m.task.name : MACH_PORT_NULL;
    check(task != MACH_PORT_NULL, "the child sends its task port");
    sleep_ms(200);
    check(drain(fd) > 0, "the child writes");
    if (task != MACH_PORT_NULL) {
        check(task_resume(task) == KERN_FAILURE, "task_resume of a running task: KERN_FAILURE");
        check(task_suspend(task) == KERN_SUCCESS, "task_suspend(child)");
        sleep_ms(30);
        drain(fd);
        sleep_ms(200);
        check(drain(fd) == 0, "the suspended child writes nothing for 200 ms");
        check(task_suspend(task) == KERN_SUCCESS && task_resume(task) == KERN_SUCCESS, "suspend again, resume once");
        sleep_ms(30);
        drain(fd);
        sleep_ms(100);
        check(drain(fd) == 0, "still suspended at count 1");
        check(task_resume(task) == KERN_SUCCESS, "task_resume(child)");
        long got = 0;
        for (int i = 0; i < 50 && got == 0; i++) {
            sleep_ms(10);
            got = drain(fd);
        }
        check(got > 0, "the child writes again");
    }
    kill(pid, SIGKILL);
    int status;
    waitpid(pid, &status, 0);
    close(fd);

    // POSIX_SPAWN_START_SUSPENDED: nothing until SIGCONT resumes its task.
    pid = spawn_child(self, 1, MACH_PORT_NULL, &fd);
    check(pid > 0, "spawn a child with POSIX_SPAWN_START_SUSPENDED");
    if (pid <= 0) return;
    sleep_ms(200);
    check(drain(fd) == 0, "the start-suspended child does not run");
    kill(pid, SIGCONT);
    long got = 0;
    for (int i = 0; i < 100 && got == 0; i++) {
        sleep_ms(20);
        got = drain(fd);
    }
    check(got > 0, "it runs after SIGCONT");
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    close(fd);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc > 1 && strcmp(argv[1], "child") == 0) child_main();
    spinning_checks();
    self_checks();
    blocked_checks();
    // The executable's guest path (argv[0] is the path the launcher gave).
    char self[1024];
    uint32_t size = sizeof self;
    task_checks(_NSGetExecutablePath(self, &size) == 0 ? self : argv[0]);
    printf("p_tsus: %s (%d failures)\n", failures ? "FAILED" : "all ok", failures);
    return failures ? 1 : 0;
}
