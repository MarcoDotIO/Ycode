/* Ycode stage-4b probe: EVFILT_PROC NOTE_EXIT|NOTE_EXITSTATUS with SIGCHLD
 * ignored (processes.md sections 2.4 and 2.8). The child waits on an
 * inherited pipe until the parent has attached the knote, then exits 7.
 * The event carries data 7 << 8; with SIGCHLD ignored there is no zombie,
 * so waitpid fails with ECHILD. Original Ycode code.
 * Prints: procevent ok status=0x700 */
#include <signal.h>
#include <sys/event.h>

#include "probe_util.h"

int main(int argc, char **argv)
{
    probe_name = "p_procevent";
    if (argc >= 3 && strcmp(argv[1], "child") == 0) {
        int fd = atoi(argv[2]);
        char c;
        ssize_t n;
        while ((n = read(fd, &c, 1)) == -1 && errno == EINTR) {
        }
        if (n != 1)
            probe_fail("child: read(%d) = %zd (%s)", fd, n, n < 0 ? strerror(errno) : "EOF");
        return 7;
    }

    const char *self = probe_self_path(argv[0]);
    if (signal(SIGCHLD, SIG_IGN) == SIG_ERR)
        probe_fail("signal(SIGCHLD, SIG_IGN): %s", strerror(errno));
    int fds[2];
    if (pipe(fds) != 0)
        probe_fail("pipe: %s", strerror(errno));

    /* The child keeps only the read end. */
    posix_spawn_file_actions_t fa;
    if (posix_spawn_file_actions_init(&fa) != 0 || posix_spawn_file_actions_addclose(&fa, fds[1]) != 0)
        probe_fail("file actions");
    char fdarg[16];
    snprintf(fdarg, sizeof fdarg, "%d", fds[0]);
    const char *extra[] = {fdarg, NULL};
    pid_t pid = -1;
    int err = probe_spawn(&pid, self, &fa, NULL, "child", extra);
    if (err != 0)
        probe_fail("posix_spawn: %d (%s)", err, strerror(err));
    posix_spawn_file_actions_destroy(&fa);
    close(fds[0]);

    int kq = kqueue();
    if (kq < 0)
        probe_fail("kqueue: %s", strerror(errno));
    struct kevent ev;
    EV_SET(&ev, pid, EVFILT_PROC, EV_ADD, NOTE_EXIT | NOTE_EXITSTATUS, 0, NULL);
    if (kevent(kq, &ev, 1, NULL, 0, NULL) != 0)
        probe_fail("kevent(EV_ADD EVFILT_PROC %d): %s", (int)pid, strerror(errno));

    /* Release the child. */
    if (write(fds[1], "x", 1) != 1)
        probe_fail("write to the child: %s", strerror(errno));
    close(fds[1]);

    struct kevent out;
    memset(&out, 0, sizeof out);
    struct timespec timeout = {PROBE_TIMEOUT_MS / 1000, 0};
    int n = kevent(kq, NULL, 0, &out, 1, &timeout);
    if (n < 0)
        probe_fail("kevent wait: %s", strerror(errno));
    if (n == 0)
        probe_fail("no EVFILT_PROC event within %d ms", PROBE_TIMEOUT_MS);
    if (out.filter != EVFILT_PROC || (pid_t)out.ident != pid)
        probe_fail("event filter %d ident %lu, expected EVFILT_PROC for %d", out.filter, (unsigned long)out.ident,
                   (int)pid);
    if (out.flags & EV_ERROR)
        probe_fail("EV_ERROR, data %ld", (long)out.data);
    if (!(out.fflags & NOTE_EXIT))
        probe_fail("fflags %#x without NOTE_EXIT", out.fflags);
    if (out.data != (7 << 8))
        probe_fail("event data %#lx, expected 0x700", (long)out.data);

    /* SIGCHLD ignored: reaped at once, nothing to wait for. */
    int st = 0;
    pid_t r = waitpid(pid, &st, WNOHANG);
    if (r != -1 || errno != ECHILD)
        probe_fail("waitpid(%d, WNOHANG) = %d (status %#x, errno %d), expected -1/ECHILD", (int)pid, (int)r, st,
                   r == -1 ? errno : 0);

    printf("procevent ok status=%#lx\n", (long)out.data);
    return 0;
}
