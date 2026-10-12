/* Ycode stage-4b probe: posix_spawn with POSIX_SPAWN_SETEXEC keeps the pid
 * and the parent (processes.md sections 1.3 and 1.11). The parent spawns
 * A; A replaces itself with mode B, passing its pid; B checks getpid() and
 * getppid() and exits 5; the parent sees status 5. Original Ycode code.
 * Prints: setexec ok */
#include "probe_util.h"

int main(int argc, char **argv)
{
    probe_name = "p_setexec";
    if (argc >= 3 && strcmp(argv[1], "A") == 0) {
        pid_t parent = (pid_t)atoi(argv[2]);
        if (getppid() != parent)
            probe_fail("A: getppid() = %d, expected %d", (int)getppid(), (int)parent);
        const char *self = probe_self_path(argv[0]);
        char me[16];
        snprintf(me, sizeof me, "%d", (int)getpid());
        posix_spawnattr_t attr;
        int err = posix_spawnattr_init(&attr);
        if (err != 0)
            probe_fail("A: posix_spawnattr_init: %d", err);
        err = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC);
        if (err != 0)
            probe_fail("A: posix_spawnattr_setflags: %d", err);
        short flags = 0;
        if (posix_spawnattr_getflags(&attr, &flags) != 0 || flags != POSIX_SPAWN_SETEXEC)
            probe_fail("A: getflags read back %#x", flags);
        const char *extra[] = {me, argv[2], NULL};
        err = probe_spawn(NULL, self, NULL, &attr, "B", extra);
        /* Only a failure returns. */
        probe_fail("A: posix_spawn(SETEXEC) returned %d (%s)", err, strerror(err));
    }
    if (argc >= 4 && strcmp(argv[1], "B") == 0) {
        pid_t a = (pid_t)atoi(argv[2]);
        pid_t parent = (pid_t)atoi(argv[3]);
        if (getpid() != a)
            probe_fail("B: getpid() = %d, expected A's pid %d", (int)getpid(), (int)a);
        if (getppid() != parent)
            probe_fail("B: getppid() = %d, expected %d", (int)getppid(), (int)parent);
        return 5;
    }

    const char *self = probe_self_path(argv[0]);
    char parent[16];
    snprintf(parent, sizeof parent, "%d", (int)getpid());
    const char *extra[] = {parent, NULL};
    pid_t pid = -1;
    int err = probe_spawn(&pid, self, NULL, NULL, "A", extra);
    if (err != 0)
        probe_fail("posix_spawn(A): %d (%s)", err, strerror(err));
    probe_expect_exit(pid, 5, "A (as B)");
    printf("setexec ok\n");
    return 0;
}
