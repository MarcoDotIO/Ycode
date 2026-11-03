// Gauge's in-process sampler for Linux processes (cycodegaugeagent.h;
// specs/ide/profiler.md §3.2). Original Ycode code.
//
// Loaded with LD_PRELOAD when perf_event_open is refused. With
// YCODE_GAUGE_SAMPLES=<file> it arms ITIMER_PROF (process CPU time) at
// YCODE_GAUGE_RATE Hz (default 1000); the kernel sends SIGPROF to the
// thread that was running, whose handler records the interrupted PC and
// the frame-pointer chain and appends one record to the file:
//   u32 magic "YGA1", u16 size, u16 frames, u32 pid, u32 tid,
//   u64 CLOCK_MONOTONIC ns, u64 pc, u64 return addresses[frames]
// Memory is read with process_vm_readv on the own process, so a bad
// frame pointer ends the walk instead of faulting. Only async-signal-safe
// calls run in the handler.
#if defined(__linux__)
#define _GNU_SOURCE
#endif
#include "cycodegaugeagent.h"

int ycode_gauge_agent_version(void) { return 1; }

#if defined(__linux__)
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

#define MAX_FRAMES 128

static int out_fd = -1;
static pid_t self_pid;

static int read_self(uint64_t address, void *buffer, size_t size) {
    struct iovec local = {buffer, size};
    struct iovec remote = {(void *)(uintptr_t)address, size};
    // Every argument as a full long: syscall() is variadic, and a narrower
    // value leaves the upper half of its register or stack slot undefined
    // (the flags word must be exactly 0).
    return syscall(SYS_process_vm_readv, (long)self_pid, (long)&local, 1L, (long)&remote, 1L, 0L) == (long)size ? 0 : -1;
}

static void on_sigprof(int sig, siginfo_t *info, void *context) {
    (void)sig;
    (void)info;
    int saved = errno;
    ucontext_t *uc = context;
    uint64_t pc, fp, sp;
#if defined(__x86_64__)
    pc = (uint64_t)uc->uc_mcontext.gregs[REG_RIP];
    fp = (uint64_t)uc->uc_mcontext.gregs[REG_RBP];
    sp = (uint64_t)uc->uc_mcontext.gregs[REG_RSP];
#elif defined(__aarch64__)
    pc = (uint64_t)uc->uc_mcontext.pc;
    fp = (uint64_t)uc->uc_mcontext.regs[29];
    sp = (uint64_t)uc->uc_mcontext.sp;
#else
    errno = saved;
    return;
#endif
    struct {
        uint32_t magic;
        uint16_t size, frames;
        uint32_t pid, tid;
        uint64_t time, pc;
        uint64_t ra[MAX_FRAMES];
    } r;
    int n = 0;
#if defined(__aarch64__)
    // A leaf that has not stored its frame yet returns through LR; it is
    // read like the next frame (it may duplicate the caller's return address).
#endif
    while (n < MAX_FRAMES && fp != 0 && (fp & 7) == 0 && fp >= sp && fp - sp < (64u << 20)) {
        uint64_t pair[2];
        if (read_self(fp, pair, sizeof(pair)) != 0) break;
        if (pair[1] == 0) break;
        r.ra[n++] = pair[1];
        if (pair[0] <= fp) break;
        fp = pair[0];
    }
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    r.magic = YCODE_GAUGE_AGENT_MAGIC;
    r.frames = (uint16_t)n;
    r.size = (uint16_t)(32 + 8 * n);
    r.pid = (uint32_t)self_pid;
    r.tid = (uint32_t)syscall((long)SYS_gettid);
    r.time = (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
    r.pc = pc;
    ssize_t w;
    do { w = write(out_fd, &r, r.size); } while (w < 0 && errno == EINTR);
    errno = saved;
}

__attribute__((constructor)) static void ycode_gauge_agent_start(void) {
    const char *path = getenv("YCODE_GAUGE_SAMPLES");
    if (!path || !*path) return;
    self_pid = getpid();
    out_fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (out_fd < 0) return;
    const char *rate = getenv("YCODE_GAUGE_RATE");
    long hz = rate ? strtol(rate, NULL, 10) : 1000;
    if (hz < 10) hz = 10;
    if (hz > 10000) hz = 10000;
    // Child processes started by the program are not sampled into this file.
    unsetenv("YCODE_GAUGE_SAMPLES");
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = on_sigprof;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGPROF, &sa, NULL);
    struct itimerval it;
    it.it_interval.tv_sec = 0;
    it.it_interval.tv_usec = 1000000 / hz;
    it.it_value = it.it_interval;
    setitimer(ITIMER_PROF, &it, NULL);
}
#endif
