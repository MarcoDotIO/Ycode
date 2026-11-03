// Gauge's Linux recording helpers (cycodegauge.h). Original Ycode code.
#if defined(__linux__)
#define _GNU_SOURCE
#endif
#include "cycodegauge.h"
#include <errno.h>

#if defined(__linux__)
#include <dirent.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

int ycg_spawn_held(const char *path, char *const argv[], char *const envp[], int *gate) {
    int fds[2];
    if (pipe2(fds, O_CLOEXEC) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) {
        int e = errno;
        close(fds[0]);
        close(fds[1]);
        errno = e;
        return -1;
    }
    if (pid == 0) {
        // Child: only async-signal-safe calls until exec.
        close(fds[1]);
        char c;
        ssize_t n;
        do { n = read(fds[0], &c, 1); } while (n < 0 && errno == EINTR);
        if (n != 1) _exit(126);
        if (envp) environ = (char **)envp;
        execvp(path, argv);
        _exit(127);
    }
    close(fds[0]);
    *gate = fds[1];
    return pid;
}

int ycg_release(int gate) {
    char c = 1;
    ssize_t n;
    do { n = write(gate, &c, 1); } while (n < 0 && errno == EINTR);
    close(gate);
    return n == 1 ? 0 : -1;
}

int ycg_wait(int pid, int nohang, int *exitStatus) {
    int status = 0;
    pid_t r;
    do { r = waitpid(pid, &status, nohang ? WNOHANG : 0); } while (r < 0 && errno == EINTR);
    if (r > 0 && exitStatus) *exitStatus = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
    return r;
}

int ycg_perf_paranoid(void) {
    FILE *f = fopen("/proc/sys/kernel/perf_event_paranoid", "r");
    if (!f) return 99;
    int v = 99;
    if (fscanf(f, "%d", &v) != 1) v = 99;
    fclose(f);
    return v;
}

int ycg_cpu_count(void) {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int)n : 1;
}

int ycg_perf_open(ycg_perf *p, int tid, int cpu, uint64_t periodNs, int inheritOnExec, int kernel, int ringPages) {
    memset(p, 0, sizeof(*p));
    p->fd = -1;
    struct perf_event_attr a;
    memset(&a, 0, sizeof(a));
    a.size = sizeof(a);
    a.type = PERF_TYPE_SOFTWARE;
    a.config = PERF_COUNT_SW_TASK_CLOCK;
    a.sample_period = periodNs;
    a.sample_type = PERF_SAMPLE_IP | PERF_SAMPLE_TID | PERF_SAMPLE_TIME | PERF_SAMPLE_CALLCHAIN;
    a.exclude_kernel = kernel ? 0 : 1;
    a.exclude_hv = 1;
    a.exclude_callchain_kernel = kernel ? 0 : 1;
    a.use_clockid = 1;
    a.clockid = CLOCK_MONOTONIC;
    a.wakeup_events = 1;
    if (inheritOnExec) {
        a.disabled = 1;
        a.enable_on_exec = 1;
        a.inherit = 1;
    }
    int fd = (int)syscall(SYS_perf_event_open, (long)&a, (long)tid, (long)cpu, -1L, (long)PERF_FLAG_FD_CLOEXEC);
    if (fd < 0) return -1;
    long page = sysconf(_SC_PAGESIZE);
    if (ringPages < 1) ringPages = 64;
    // A power of two.
    int pages = 1;
    while (pages < ringPages) pages <<= 1;
    size_t size = (size_t)page * (size_t)(pages + 1);
    void *base = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        int e = errno;
        close(fd);
        errno = e;
        return -1;
    }
    p->fd = fd;
    p->base = base;
    p->size = size;
    p->dataSize = (size_t)page * (size_t)pages;
    return 0;
}

size_t ycg_perf_read(ycg_perf *p, uint64_t *out, size_t capacity) {
    if (!p->base) return 0;
    struct perf_event_mmap_page *meta = p->base;
    uint8_t *data = (uint8_t *)p->base + meta->data_offset;
    uint64_t dataSize = meta->data_size ? meta->data_size : p->dataSize;
    uint64_t head = __atomic_load_n(&meta->data_head, __ATOMIC_ACQUIRE);
    uint64_t tail = meta->data_tail;
    size_t n = 0;
    while (tail < head) {
        struct perf_event_header h;
        // Records may wrap around the ring's end: copy byte by byte.
        uint8_t tmp[sizeof(h)];
        for (size_t i = 0; i < sizeof(h); i++) tmp[i] = data[(tail + i) % dataSize];
        memcpy(&h, tmp, sizeof(h));
        if (h.size < sizeof(h)) break;
        if (h.type == PERF_RECORD_SAMPLE) {
            // ip, pid/tid, time, nr, ips[nr]
            uint64_t words[4];
            for (int w = 0; w < 4; w++) {
                uint64_t v = 0;
                for (int b = 0; b < 8; b++) v |= (uint64_t)data[(tail + sizeof(h) + w * 8 + b) % dataSize] << (8 * b);
                words[w] = v;
            }
            uint64_t tid = words[1] >> 32, time = words[2], nr = words[3];
            if (nr > 512) nr = 512;
            if (n + 3 + nr > capacity) break;
            out[n++] = tid;
            out[n++] = time;
            out[n++] = nr;
            for (uint64_t i = 0; i < nr; i++) {
                uint64_t v = 0;
                for (int b = 0; b < 8; b++) v |= (uint64_t)data[(tail + sizeof(h) + 32 + i * 8 + b) % dataSize] << (8 * b);
                out[n++] = v;
            }
        } else if (h.type == PERF_RECORD_LOST) {
            uint64_t lost = 0;
            for (int b = 0; b < 8; b++) lost |= (uint64_t)data[(tail + sizeof(h) + 8 + b) % dataSize] << (8 * b);
            p->lost += lost;
        }
        tail += h.size;
    }
    __atomic_store_n(&meta->data_tail, tail, __ATOMIC_RELEASE);
    return n;
}

void ycg_perf_close(ycg_perf *p) {
    if (p->base) munmap(p->base, p->size);
    if (p->fd >= 0) close(p->fd);
    p->base = NULL;
    p->fd = -1;
}

int ycg_threads(int pid, int *out, int capacity) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/task", pid);
    DIR *d = opendir(path);
    if (!d) return 0;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL && n < capacity) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        out[n++] = atoi(e->d_name);
    }
    closedir(d);
    return n;
}

#else

int ycg_spawn_held(const char *path, char *const argv[], char *const envp[], int *gate) { (void)path; (void)argv; (void)envp; (void)gate; errno = ENOSYS; return -1; }
int ycg_release(int gate) { (void)gate; errno = ENOSYS; return -1; }
int ycg_wait(int pid, int nohang, int *exitStatus) { (void)pid; (void)nohang; (void)exitStatus; errno = ENOSYS; return -1; }
int ycg_perf_paranoid(void) { return 99; }
int ycg_cpu_count(void) { return 1; }
int ycg_perf_open(ycg_perf *p, int tid, int cpu, uint64_t periodNs, int inheritOnExec, int kernel, int ringPages) {
    (void)p; (void)tid; (void)cpu; (void)periodNs; (void)inheritOnExec; (void)kernel; (void)ringPages;
    errno = ENOSYS;
    return -1;
}
size_t ycg_perf_read(ycg_perf *p, uint64_t *out, size_t capacity) { (void)p; (void)out; (void)capacity; return 0; }
void ycg_perf_close(ycg_perf *p) { (void)p; }
int ycg_threads(int pid, int *out, int capacity) { (void)pid; (void)out; (void)capacity; return 0; }

#endif
