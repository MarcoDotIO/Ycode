// Gauge's Linux recording helpers (specs/ide/profiler.md §3.2): starting a
// command held before exec, and perf_event_open sampling into a ring buffer.
// Original Ycode code; the perf ABI is from linux/perf_event.h and the
// perf_event_open(2) man page. On other systems every call fails with -1.
#ifndef CYCODEGAUGE_H
#define CYCODEGAUGE_H
#include <stddef.h>
#include <stdint.h>

/// Forks a child that waits for `ycg_release` and then execvp(path, argv)
/// with `envp` (NULL: the current environment). Returns the child's pid
/// (and the release descriptor in *gate), or -1 with errno set.
int ycg_spawn_held(const char *path, char *const argv[], char *const envp[], int *gate);
/// Lets a held child exec. Closes `gate`.
int ycg_release(int gate);
/// waitpid(pid, &status, nohang ? WNOHANG : 0): pid, 0 (still running) or -1;
/// *exitStatus gets the exit status (or 128 + signal).
int ycg_wait(int pid, int nohang, int *exitStatus);

/// /proc/sys/kernel/perf_event_paranoid, or 99 when unreadable.
int ycg_perf_paranoid(void);

/// One task-clock sampling event with its ring buffer.
typedef struct ycg_perf {
    int fd;
    void *base;
    size_t size;      // mapped bytes (1 + 2^n pages)
    size_t dataSize;  // ring bytes
    uint64_t lost;
} ycg_perf;

/// perf_event_open(PERF_TYPE_SOFTWARE, PERF_COUNT_SW_TASK_CLOCK) on `tid`
/// and `cpu` (-1: any CPU), sampling every `periodNs` of task time with IP,
/// TID, TIME and CALLCHAIN; `inheritOnExec`: inherit to new threads and
/// enable at exec (a held child; the kernel refuses to map an inherited
/// event for any CPU, so the caller opens one per CPU); else enabled now.
/// `kernel`: include kernel frames. 0 or -1 with errno set.
int ycg_perf_open(ycg_perf *p, int tid, int cpu, uint64_t periodNs, int inheritOnExec, int kernel, int ringPages);
/// Online CPUs (sysconf), at least 1.
int ycg_cpu_count(void);
/// Copies samples out of the ring as u64 words: tid, time, n, ip[n]
/// (call chain leaf first, PERF_CONTEXT_* markers kept as is). Returns
/// the number of words written (stops early when `capacity` is reached;
/// the rest stays in the ring).
size_t ycg_perf_read(ycg_perf *p, uint64_t *out, size_t capacity);
void ycg_perf_close(ycg_perf *p);

/// Thread ids of a process (/proc/<pid>/task); returns the count (≤ capacity).
int ycg_threads(int pid, int *out, int capacity);
#endif
