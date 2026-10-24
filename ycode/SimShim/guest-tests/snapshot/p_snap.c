/* Ycode snapshot probe (specs/simulator/snapshot.md §9): state that must
 * survive a snapshot taken while the program sleeps, and a restore in a new
 * host process. Original Ycode code.
 *
 *   p_snap          one process: four threads (a Mach receiver, a pipe
 *                   reader, a condition-variable waiter, an FP spinner),
 *                   three queued messages (inline, OOL + port right), a pipe,
 *                   a semaphore, an 8 MiB heap pattern.
 *   p_snap multi    two processes: the child gets the parent's port as its
 *                   bootstrap port and serves requests on its own port;
 *                   replies queue up in the parent across the snapshot.
 *
 * Before its long sleep the program creates /tmp/ycode-snap-ready (the
 * VMM's YCODE_SNAPSHOT_WHEN_FILE trigger) and prints "snap: ready".
 * Prints "snap ok ..." / "snap2 ok ..." and exits 0 when everything checks. */
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/semaphore.h>
#include <math.h>
#include <pthread.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#define SLEEP_SECONDS 6
#define READY_FILE "/tmp/ycode-snap-ready"

static void fail(const char *what, long code)
{
    fprintf(stderr, "p_snap[%d]: FAIL: %s (%#lx)\n", getpid(), what, code);
    fflush(stderr);
    exit(1);
}

typedef struct {
    mach_msg_header_t h;
    int value;
} value_msg_t;

typedef struct {
    value_msg_t m;
    mach_msg_trailer_t t;
    char slack[64];
} value_rcv_t;

typedef struct {
    mach_msg_header_t h;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port;
    mach_msg_ool_descriptor_t ool;
    int value;
} complex_msg_t;

typedef struct {
    complex_msg_t m;
    mach_msg_trailer_t t;
    char slack[64];
} complex_rcv_t;

static uint64_t ticks_per_second(void)
{
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return 1000000000ull * tb.denom / tb.numer;
}

static void send_value(mach_port_t to, int value, mach_port_t reply, mach_msg_type_name_t reply_disposition)
{
    value_msg_t m;
    memset(&m, 0, sizeof m);
    m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, reply_disposition);
    m.h.msgh_size = sizeof m;
    m.h.msgh_remote_port = to;
    m.h.msgh_local_port = reply;
    m.h.msgh_id = 0x5aa0;
    m.value = value;
    kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG, sizeof m, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) fail("send", kr);
}

static int receive_value(mach_port_t from, mach_port_t *reply, mach_msg_timeout_t timeout)
{
    value_rcv_t r;
    memset(&r, 0, sizeof r);
    mach_msg_option_t opt = MACH_RCV_MSG | (timeout ? MACH_RCV_TIMEOUT : 0);
    kern_return_t kr = mach_msg(&r.m.h, opt, 0, sizeof r, from, timeout, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) fail("receive", kr);
    if (reply) *reply = r.m.h.msgh_remote_port;
    return r.m.value;
}

static mach_port_t new_port(void)
{
    mach_port_t p = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &p);
    if (kr) fail("mach_port_allocate", kr);
    kr = mach_port_insert_right(mach_task_self(), p, p, MACH_MSG_TYPE_MAKE_SEND);
    if (kr) fail("mach_port_insert_right", kr);
    return p;
}

static void mark_ready(uint64_t *t0)
{
    *t0 = mach_absolute_time();
    int fd = open(READY_FILE, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) close(fd);
    printf("snap: ready (pid %d)\n", getpid());
    fflush(stdout);
}

static void sleep_and_check(uint64_t t0)
{
    uint64_t want = (uint64_t)SLEEP_SECONDS * ticks_per_second();
    mach_wait_until(t0 + want);
    uint64_t t1 = mach_absolute_time();
    if (t1 < t0 + want) fail("mach_absolute_time went backwards or the sleep was short", (long)(t0 + want - t1));
    printf("snap: awake after %.3f s of guest time\n", (double)(t1 - t0) / (double)ticks_per_second());
    fflush(stdout);
}

/* ---- one process ---- */

static mach_port_t P, Q;
static int pipefd[2];
static semaphore_t S;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int flag, c_done, b_sum;
static volatile int stop_spin;
static uint64_t spin_count;
static double spin_value;

static double spin_step(double acc, uint64_t i) { return acc * 1.0000001 + (double)(i & 7) * 0.25; }

static void *thread_a(void *arg)
{
    (void)arg;
    for (;;) {
        int v = receive_value(P, NULL, 0);
        if (v == 0) break;
        int out = v * 2;
        if (write(pipefd[1], &out, sizeof out) != sizeof out) fail("pipe write", errno);
    }
    return NULL;
}

static void *thread_b(void *arg)
{
    (void)arg;
    int sum = 0;
    for (int i = 0; i < 10; i++) {
        int x = 0;
        size_t got = 0;
        while (got < sizeof x) {
            ssize_t n = read(pipefd[0], (char *)&x + got, sizeof x - got);
            if (n <= 0) fail("pipe read", n < 0 ? errno : 0);
            got += (size_t)n;
        }
        sum += x;
    }
    b_sum = sum;
    semaphore_signal(S);
    return NULL;
}

static void *thread_c(void *arg)
{
    (void)arg;
    pthread_mutex_lock(&mu);
    while (!flag) pthread_cond_wait(&cv, &mu);
    pthread_mutex_unlock(&mu);
    c_done = 1;
    return NULL;
}

/* A sender that blocks on a full queue (qlimit 1): its second message
 * waits in the kernel across the snapshot. */
static mach_port_t F;
static void *thread_e(void *arg)
{
    (void)arg;
    send_value(F, 501, MACH_PORT_NULL, 0);
    send_value(F, 502, MACH_PORT_NULL, 0);
    return NULL;
}

static void *thread_d(void *arg)
{
    (void)arg;
    double acc = 1.0;
    uint64_t i = 0;
    while (!stop_spin) {
        acc = spin_step(acc, i);
        if (acc > 1e12) acc = acc / 1e12;
        i++;
    }
    spin_count = i;
    spin_value = acc;
    return NULL;
}

static int single(void)
{
    /* Heap pattern. */
    size_t heap_words = (8u << 20) / 8;
    uint64_t *heap = malloc(heap_words * 8);
    if (!heap) fail("malloc", 0);
    uint64_t sum0 = 0;
    for (size_t i = 0; i < heap_words; i++) {
        heap[i] = (uint64_t)i * 0x9E3779B97F4A7C15ull;
        sum0 += heap[i] ^ i;
    }

    P = new_port();
    Q = new_port();
    if (pipe(pipefd) != 0) fail("pipe", errno);
    if (semaphore_create(mach_task_self(), &S, SYNC_POLICY_FIFO, 0)) fail("semaphore_create", 0);

    /* Three messages queued on Q, received only after the sleep. */
    send_value(Q, 11, MACH_PORT_NULL, 0);
    static char payload[40000];
    for (size_t i = 0; i < sizeof payload; i++) payload[i] = (char)(i * 7 + 3);
    complex_msg_t cm;
    memset(&cm, 0, sizeof cm);
    cm.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    cm.h.msgh_size = sizeof cm;
    cm.h.msgh_remote_port = Q;
    cm.h.msgh_id = 0x5aa1;
    cm.body.msgh_descriptor_count = 2;
    cm.port.name = P;
    cm.port.disposition = MACH_MSG_TYPE_MAKE_SEND;
    cm.port.type = MACH_MSG_PORT_DESCRIPTOR;
    cm.ool.address = payload;
    cm.ool.size = sizeof payload;
    cm.ool.copy = MACH_MSG_VIRTUAL_COPY;
    cm.ool.type = MACH_MSG_OOL_DESCRIPTOR;
    cm.value = 22;
    kern_return_t kr = mach_msg(&cm.h, MACH_SEND_MSG, sizeof cm, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
    if (kr) fail("send complex", kr);
    send_value(Q, 33, MACH_PORT_NULL, 0);

    mach_port_options_t fo;
    memset(&fo, 0, sizeof fo);
    fo.flags = MPO_INSERT_SEND_RIGHT | MPO_QLIMIT;
    fo.mpl.mpl_qlimit = 1;
    kr = mach_port_construct(mach_task_self(), &fo, 0, &F);
    if (kr) fail("mach_port_construct", kr);
    pthread_t a, b, c, d, e;
    pthread_create(&e, NULL, thread_e, NULL);
    pthread_create(&a, NULL, thread_a, NULL);
    pthread_create(&b, NULL, thread_b, NULL);
    pthread_create(&c, NULL, thread_c, NULL);
    pthread_create(&d, NULL, thread_d, NULL);
    usleep(300000);

    /* Shared memory: a memory entry for 32 KiB of our memory, mapped a
     * second time; the two views must still share pages after a restore. */
    vm_address_t shared_a = 0;
    if (vm_allocate(mach_task_self(), &shared_a, 0x8000, VM_FLAGS_ANYWHERE)) fail("vm_allocate", 0);
    volatile uint32_t *va_a = (volatile uint32_t *)shared_a;
    va_a[0] = 0x51ab0001;
    memory_object_size_t entry_size = 0x8000;
    mach_port_t entry = MACH_PORT_NULL;
    kr = mach_make_memory_entry_64(mach_task_self(), &entry_size, shared_a, VM_PROT_READ | VM_PROT_WRITE, &entry,
                                   MACH_PORT_NULL);
    if (kr) fail("mach_make_memory_entry_64", kr);
    vm_address_t shared_b = 0;
    kr = vm_map(mach_task_self(), &shared_b, 0x8000, 0, VM_FLAGS_ANYWHERE, entry, 0, FALSE,
                     VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
    if (kr) fail("mach_vm_map", kr);
    volatile uint32_t *va_b = (volatile uint32_t *)shared_b;
    if (va_b[0] != 0x51ab0001) fail("second view before the snapshot", va_b[0]);

    uint64_t t0;
    mark_ready(&t0);
    sleep_and_check(t0);

    va_b[1] = 0x51ab0002;
    if (va_a[1] != 0x51ab0002 || va_a[0] != 0x51ab0001) fail("shared views after the snapshot", va_a[1]);
    vm_address_t shared_c = 0;
    kr = vm_map(mach_task_self(), &shared_c, 0x8000, 0, VM_FLAGS_ANYWHERE, entry, 0, FALSE,
                     VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
    if (kr || ((volatile uint32_t *)shared_c)[1] != 0x51ab0002) fail("mapping the memory entry after the snapshot", kr);

    for (int v = 1; v <= 10; v++) send_value(P, v, MACH_PORT_NULL, 0);
    send_value(P, 0, MACH_PORT_NULL, 0);
    kr = semaphore_wait(S);
    if (kr) fail("semaphore_wait", kr);
    if (b_sum != 110) fail("pipe sum", b_sum);

    pthread_mutex_lock(&mu);
    flag = 1;
    pthread_cond_signal(&cv);
    pthread_mutex_unlock(&mu);
    pthread_join(c, NULL);
    if (!c_done) fail("condition waiter", 0);

    stop_spin = 1;
    pthread_join(d, NULL);
    double check = 1.0;
    for (uint64_t i = 0; i < spin_count; i++) {
        check = spin_step(check, i);
        if (check > 1e12) check = check / 1e12;
    }
    if (check != spin_value) fail("FP spinner result", (long)spin_count);
    if (receive_value(F, NULL, 5000) != 501 || receive_value(F, NULL, 5000) != 502) fail("blocked sender's messages", 0);
    pthread_join(e, NULL);
    pthread_join(a, NULL);
    pthread_join(b, NULL);

    /* The queued messages. */
    if (receive_value(Q, NULL, 5000) != 11) fail("queued message 1", 0);
    complex_rcv_t r;
    memset(&r, 0, sizeof r);
    kr = mach_msg(&r.m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof r, Q, 5000, MACH_PORT_NULL);
    if (kr) fail("receive complex", kr);
    if (r.m.value != 22 || r.m.ool.size != sizeof payload) fail("complex message", r.m.value);
    const char *got = r.m.ool.address;
    for (size_t i = 0; i < sizeof payload; i++)
        if (got[i] != (char)(i * 7 + 3)) fail("OOL bytes", (long)i);
    mach_port_type_t type = 0;
    kr = mach_port_type(mach_task_self(), r.m.port.name, &type);
    if (kr || !(type & MACH_PORT_TYPE_SEND)) fail("port right in the message", kr);
    /* The right is a send right to P: a message through it arrives on P. */
    send_value(r.m.port.name, 44, MACH_PORT_NULL, 0);
    if (receive_value(P, NULL, 5000) != 44) fail("send through the carried right", 0);
    if (receive_value(Q, NULL, 5000) != 33) fail("queued message 3", 0);

    uint64_t sum1 = 0;
    for (size_t i = 0; i < heap_words; i++) sum1 += heap[i] ^ i;
    if (sum1 != sum0) fail("heap checksum", 0);

    printf("snap ok sum=%d queued=3 heap=ok fp=ok shared=ok spins=%llu\n", b_sum, (unsigned long long)spin_count);
    return 0;
}

/* ---- two processes ---- */

static int child(void)
{
    mach_port_t r = new_port();
    send_value(bootstrap_port, -1, r, MACH_MSG_TYPE_MAKE_SEND);
    for (int i = 0; i < 5; i++) {
        int v = receive_value(r, NULL, 0);
        send_value(bootstrap_port, v * 3, MACH_PORT_NULL, 0);
    }
    return 0;
}

static int multi(const char *self)
{
    mach_port_t p = new_port();
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    if (posix_spawnattr_setspecialport_np(&attr, p, TASK_BOOTSTRAP_PORT)) fail("setspecialport", 0);
    pid_t pid = -1;
    char *args[] = {(char *)self, "child", NULL};
    int err = posix_spawn(&pid, self, NULL, &attr, args, environ);
    if (err) fail("posix_spawn", err);
    mach_port_t reply = MACH_PORT_NULL;
    if (receive_value(p, &reply, 20000) != -1) fail("hello", 0);
    send_value(reply, 1, MACH_PORT_NULL, 0);
    send_value(reply, 2, MACH_PORT_NULL, 0);
    usleep(300000); /* the child answers both: two replies wait on p */

    uint64_t t0;
    mark_ready(&t0);
    sleep_and_check(t0);

    send_value(reply, 3, MACH_PORT_NULL, 0);
    send_value(reply, 4, MACH_PORT_NULL, 0);
    send_value(reply, 5, MACH_PORT_NULL, 0);
    int sum = 0;
    for (int i = 0; i < 5; i++) sum += receive_value(p, NULL, 10000);
    int status = 0;
    if (waitpid(pid, &status, 0) != pid) fail("waitpid", errno);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) fail("child status", status);
    if (sum != 45) fail("sum", sum);
    printf("snap2 ok sum=%d child=%d\n", sum, (int)pid);
    return 0;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc >= 2 && strcmp(argv[1], "child") == 0) return child();
    if (argc >= 2 && strcmp(argv[1], "multi") == 0) return multi(argv[0]);
    return single();
}
