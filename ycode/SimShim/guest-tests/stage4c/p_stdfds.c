/* Ycode stage-4c probe: re-opening the standard descriptors on /dev/null, as
 * a daemon does at start, keeps fds 0-2 open. Original Ycode code.
 * Prints "stdfds ok". */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(void)
{
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
    int log = open("/tmp/stdfds.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    dprintf(log, "open/dup2: %d/%d %d/%d %d/%d; next fd %d\n", seen[0][0], seen[0][1], seen[1][0], seen[1][1],
            seen[2][0], seen[2][1], log);
    if (bad || log != 3) {
        dprintf(log, "stdfds FAIL\n");
        return 1;
    }
    dprintf(log, "stdfds ok\n");
    return 0;
}
