/* Ycode stage-4c probe: re-opening the standard descriptors on /dev/null, as
 * a daemon does at start, keeps fds 0-2 open. Original Ycode code.
 * Prints "stdfds ok" to the original stdout (kept on a dup made first), so
 * the probe works whatever the descriptor table holds at start (device mode:
 * fd 3 is /dev/console; --exec: fds 0-2 are the console only). */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* The lowest descriptor that is not open (what open() must return). */
static int lowest_free(void)
{
    for (int fd = 0; fd < 1024; fd++)
        if (fcntl(fd, F_GETFD) == -1)
            return fd;
    return -1;
}

int main(void)
{
    int out = dup(1);
    if (out < 0)
        return 2;
    static const int modes[3] = {O_RDONLY, O_WRONLY, O_RDWR};
    int seen[3][2];
    for (int i = 0; i < 3; i++) {
        int fd = open("/dev/null", modes[i] | O_NOCTTY, 0666);
        int r = -2;
        if (fd != i) {
            r = dup2(fd, i);
            close(fd);
        }
        seen[i][0] = fd;
        seen[i][1] = r;
    }
    int bad = 0;
    for (int i = 0; i < 3; i++)
        if (fcntl(i, F_GETFL) == -1)
            bad = 1;
    /* fd 1 is /dev/null now: a write succeeds and goes nowhere. */
    if (write(1, "x", 1) != 1)
        bad = 1;
    int expected = lowest_free();
    int log = open("/tmp/stdfds.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    dprintf(out, "open/dup2: %d/%d %d/%d %d/%d; saved stdout %d; next fd %d (expected %d)\n", seen[0][0], seen[0][1],
            seen[1][0], seen[1][1], seen[2][0], seen[2][1], out, log, expected);
    if (bad || log < 0 || log != expected) {
        dprintf(out, "stdfds FAIL\n");
        return 1;
    }
    close(log);
    dprintf(out, "stdfds ok\n");
    return 0;
}
