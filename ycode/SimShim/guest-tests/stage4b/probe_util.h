/* Ycode stage-4b probes: shared helpers (bounded waits, self re-execution).
 * Original Ycode code. Contract: specs/simulator/stage4b-contract.md section 1.
 * alarm() is not available in the guest, so every wait is a poll loop with
 * nanosleep or a kevent/mach_msg timeout. */
#ifndef YCODE_PROBE_UTIL_H
#define YCODE_PROBE_UTIL_H

#include <crt_externs.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define PROBE_TIMEOUT_MS 20000

static const char *probe_name = "probe";

static __attribute__((unused)) void probe_fail(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
static __attribute__((unused)) void probe_fail(const char *fmt, ...)
{
    va_list ap;
    fprintf(stderr, "%s[%d]: FAIL: ", probe_name, (int)getpid());
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
    exit(1);
}

static __attribute__((unused)) void probe_sleep_ms(long ms)
{
    struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {
    }
}

/* The path to re-execute: argv[0] if it is a path, else dyld's idea of
 * the executable path. */
static const char *probe_self_path(const char *argv0)
{
    static char buf[1024];
    if (argv0 != NULL && strchr(argv0, '/') != NULL)
        return argv0;
    uint32_t size = sizeof buf;
    if (_NSGetExecutablePath(buf, &size) != 0)
        probe_fail("cannot find my own path (argv[0] = %s)", argv0 ? argv0 : "(null)");
    return buf;
}

/* posix_spawn(self, mode, extra...) with optional file actions and
 * attributes. extra is a NULL-terminated list of at most 6 strings.
 * Returns the posix_spawn result; *pid gets the child's pid. */
static __attribute__((unused)) int probe_spawn(pid_t *pid, const char *self, const posix_spawn_file_actions_t *fa,
                       const posix_spawnattr_t *attr, const char *mode, const char *const *extra)
{
    char *args[10];
    int n = 0;
    args[n++] = (char *)self;
    args[n++] = (char *)mode;
    if (extra != NULL)
        for (int i = 0; extra[i] != NULL && n < 9; i++)
            args[n++] = (char *)extra[i];
    args[n] = NULL;
    return posix_spawn(pid, self, fa, attr, args, *_NSGetEnviron());
}

/* waitpid with a deadline: the reaped pid, or 0 on timeout, or -1 with
 * errno. */
static __attribute__((unused)) pid_t probe_wait(pid_t pid, int *status, long timeout_ms)
{
    for (long waited = 0;; waited += 5) {
        pid_t r = waitpid(pid, status, WNOHANG);
        if (r != 0)
            return r;
        if (waited >= timeout_ms)
            return 0;
        probe_sleep_ms(5);
    }
}

/* Wait for a child that must exit with `code`. */
static __attribute__((unused)) void probe_expect_exit(pid_t pid, int code, const char *what)
{
    int st = 0;
    pid_t r = probe_wait(pid, &st, PROBE_TIMEOUT_MS);
    if (r == 0)
        probe_fail("%s (pid %d) did not exit within %d ms", what, (int)pid, PROBE_TIMEOUT_MS);
    if (r < 0)
        probe_fail("waitpid(%s, pid %d): %s", what, (int)pid, strerror(errno));
    if (r != pid)
        probe_fail("waitpid(%s) returned pid %d, expected %d", what, (int)r, (int)pid);
    if (!WIFEXITED(st) || WEXITSTATUS(st) != code)
        probe_fail("%s: wait status %#x, expected exit %d", what, st, code);
}

#endif /* YCODE_PROBE_UTIL_H */
