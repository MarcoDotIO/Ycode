/* Ycode stage-4b probe: posix_spawn + waitpid. Child 1 checks getppid() and
 * exits 42 (WIFEXITED, status 42); child 2 is killed with SIGTERM
 * (WIFSIGNALED, signal 15). Original Ycode code.
 * Prints: spawn_wait ok status=42 sig=15 */
#include <signal.h>

#include "probe_util.h"

int main(int argc, char **argv)
{
    probe_name = "p_spawn_wait";
    if (argc >= 3 && strcmp(argv[1], "exit42") == 0) {
        pid_t parent = (pid_t)atoi(argv[2]);
        if (getppid() != parent)
            probe_fail("child: getppid() = %d, expected %d", (int)getppid(), (int)parent);
        return 42;
    }
    if (argc >= 2 && strcmp(argv[1], "sleeper") == 0) {
        /* Waits to be killed; gives up after 30 s with a distinct status. */
        for (int i = 0; i < 3000; i++)
            probe_sleep_ms(10);
        return 4;
    }

    const char *self = probe_self_path(argv[0]);
    char parent[16];
    snprintf(parent, sizeof parent, "%d", (int)getpid());

    /* Child 1: exit(42). */
    pid_t c1 = -1;
    const char *extra1[] = {parent, NULL};
    int err = probe_spawn(&c1, self, NULL, NULL, "exit42", extra1);
    if (err != 0)
        probe_fail("posix_spawn(exit42): %d (%s)", err, strerror(err));
    if (c1 <= 0 || c1 == getpid())
        probe_fail("posix_spawn returned pid %d", (int)c1);
    int st1 = 0;
    pid_t r = probe_wait(c1, &st1, PROBE_TIMEOUT_MS);
    if (r != c1)
        probe_fail("waitpid(child 1 = %d) = %d (%s)", (int)c1, (int)r, r < 0 ? strerror(errno) : "timeout");
    if (!WIFEXITED(st1) || WEXITSTATUS(st1) != 42)
        probe_fail("child 1 wait status %#x, expected exit 42", st1);

    /* Child 2: killed by SIGTERM. */
    pid_t c2 = -1;
    err = probe_spawn(&c2, self, NULL, NULL, "sleeper", NULL);
    if (err != 0)
        probe_fail("posix_spawn(sleeper): %d (%s)", err, strerror(err));
    if (c2 <= 0 || c2 == c1)
        probe_fail("second posix_spawn returned pid %d", (int)c2);
    probe_sleep_ms(50); /* let it start; the kill must work either way */
    if (kill(c2, SIGTERM) != 0)
        probe_fail("kill(%d, SIGTERM): %s", (int)c2, strerror(errno));
    int st2 = 0;
    r = probe_wait(c2, &st2, PROBE_TIMEOUT_MS);
    if (r != c2)
        probe_fail("waitpid(child 2 = %d) = %d (%s)", (int)c2, (int)r, r < 0 ? strerror(errno) : "timeout");
    if (!WIFSIGNALED(st2) || WTERMSIG(st2) != SIGTERM)
        probe_fail("child 2 wait status %#x, expected killed by signal 15", st2);

    /* Nothing is left to wait for. */
    if (waitpid(-1, NULL, WNOHANG) != -1 || errno != ECHILD)
        probe_fail("waitpid(-1) after reaping both children did not fail with ECHILD");

    printf("spawn_wait ok status=%d sig=%d\n", WEXITSTATUS(st1), WTERMSIG(st2));
    return 0;
}
