/* pmustat: count Arm PMU events of a command and all its threads (Linux arm64
 * host tool for specs/simulator/guest-cpu.md). Original Ycode code, written
 * from perf_event_open(2) and the Arm PMUv3 common event numbers (Arm
 * Architecture Reference Manual, D24.11). Works with perf_event_paranoid = 2:
 * user-mode events only (exclude_kernel), on our own child process.
 *
 *   cc -O2 -o pmustat pmustat.c
 *   pmustat [-g] [-s 1|2|3] -- command [args...]
 *     -g  count only while a vCPU of the command runs guest code
 *         (exclude_host); without it, guest EL0 and host EL0 are both counted
 *         (EL1, the guest's shim, and the host kernel are excluded)
 *     -s  event set (default 1)
 * Prints "pmu <event> <count>" lines (scaled when the kernel multiplexed),
 * then derived ratios and the child's user/system CPU seconds, to stderr.
 * SIGTERM, SIGINT and SIGHUP are passed on to the command. */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/perf_event.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

struct ev { const char *name; uint64_t code; };
static const struct ev set1[] = {
    {"cpu_cycles", 0x11}, {"inst_retired", 0x08}, {"l1d_tlb_refill", 0x05},
    {"l1i_tlb_refill", 0x02}, {"dtlb_walk", 0x34}, {"itlb_walk", 0x35}};
static const struct ev set2[] = {
    {"cpu_cycles", 0x11}, {"inst_retired", 0x08}, {"l2d_tlb_refill", 0x2D},
    {"l1d_cache_refill", 0x03}, {"l2d_cache_refill", 0x17}, {"stall_backend", 0x24}};
static const struct ev set3[] = {
    {"cpu_cycles", 0x11}, {"inst_retired", 0x08}, {"stall_frontend", 0x23},
    {"br_mis_pred_retired", 0x22}, {"l1i_cache_refill", 0x01}, {"exc_taken", 0x09}};

static volatile pid_t child_pid;
/* SIGTERM, SIGINT and SIGHUP go on to the command (a harness stops it through us). */
static void forward(int sig) { if (child_pid > 0) kill(child_pid, sig); }

static int pmu_type(void)
{
    FILE *f = fopen("/sys/bus/event_source/devices/armv8_pmuv3/type", "r");
    int t = -1;
    if (f) { if (fscanf(f, "%d", &t) != 1) t = -1; fclose(f); }
    return t;
}

int main(int argc, char **argv)
{
    int guest_only = 0, set = 1, i = 1;
    for (; i < argc; i++) {
        if (strcmp(argv[i], "-g") == 0) guest_only = 1;
        else if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) set = atoi(argv[++i]);
        else if (strcmp(argv[i], "--") == 0) { i++; break; }
        else break;
    }
    if (i >= argc) { fprintf(stderr, "usage: pmustat [-g] [-s 1|2|3] -- command [args...]\n"); return 64; }
    const struct ev *evs = set == 2 ? set2 : set == 3 ? set3 : set1;
    const int nev = 6;
    int type = pmu_type();
    if (type < 0) { fprintf(stderr, "pmustat: no armv8_pmuv3 PMU\n"); return 1; }

    int go[2];
    if (pipe(go) != 0) { perror("pipe"); return 1; }
    pid_t child = fork();
    if (child == 0) {
        char c;
        close(go[1]);
        if (read(go[0], &c, 1) != 1) _exit(127);
        close(go[0]);
        execvp(argv[i], argv + i);
        perror(argv[i]);
        _exit(127);
    }
    close(go[0]);
    int fds[6];
    for (int k = 0; k < nev; k++) {
        struct perf_event_attr a;
        memset(&a, 0, sizeof a);
        a.size = sizeof a;
        a.type = (uint32_t)type;
        a.config = evs[k].code;
        a.disabled = 1;
        a.enable_on_exec = 1;
        a.inherit = 1;
        a.exclude_kernel = 1;
        a.exclude_hv = 1;
        a.exclude_host = (unsigned)guest_only;
        a.read_format = PERF_FORMAT_TOTAL_TIME_ENABLED | PERF_FORMAT_TOTAL_TIME_RUNNING;
        fds[k] = (int)syscall(SYS_perf_event_open, &a, child, -1, -1, PERF_FLAG_FD_CLOEXEC);
        if (fds[k] < 0) fprintf(stderr, "pmustat: %s: %s\n", evs[k].name, strerror(errno));
    }
    child_pid = child;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = forward;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    struct timeval t0, t1;
    gettimeofday(&t0, NULL);
    if (write(go[1], "x", 1) != 1) { perror("write"); return 1; }
    close(go[1]);
    int status = 0;
    struct rusage ru;
    while (wait4(child, &status, 0, &ru) < 0 && errno == EINTR) {}
    gettimeofday(&t1, NULL);
    double v[6] = {0};
    for (int k = 0; k < nev; k++) {
        uint64_t r[3] = {0, 0, 0};
        if (fds[k] < 0 || read(fds[k], r, sizeof r) != (ssize_t)sizeof r) { v[k] = -1; continue; }
        v[k] = r[2] ? (double)r[0] * ((double)r[1] / (double)r[2]) : (double)r[0];
        fprintf(stderr, "pmu %-20s %16.0f%s\n", evs[k].name, v[k], r[2] < r[1] ? " (scaled)" : "");
    }
    double cyc = v[0], ins = v[1];
    if (cyc > 0 && ins > 0) {
        fprintf(stderr, "pmu ipc %.3f mode %s set %d\n", ins / cyc, guest_only ? "guest" : "all-el0", set);
        for (int k = 2; k < nev; k++)
            if (v[k] >= 0) fprintf(stderr, "pmu per-kilo-inst %-20s %10.3f\n", evs[k].name, v[k] * 1000.0 / ins);
    }
    fprintf(stderr, "pmu wall %.3f s user %.3f s sys %.3f s exit %d\n",
            (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_usec - t0.tv_usec) / 1e6,
            (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1e6,
            (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1e6,
            WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
