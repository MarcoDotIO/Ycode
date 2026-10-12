/* Ycode stage-4b probe: a receive right of the parent becomes the child's
 * bootstrap port (posix_spawnattr_setspecialport_np, TASK_BOOTSTRAP_PORT);
 * the child sends to bootstrap_port and the parent finds the child's pid in
 * the audit-token trailer (val[5]). Original Ycode code.
 * Prints: spawn_port ok pid_match=1 */
#include <mach/mach.h>

#include "probe_util.h"

#define MSG_ID 0x4b01

typedef struct {
    mach_msg_header_t h;
    int pid;
} hello_msg_t;

typedef struct {
    hello_msg_t m;
    mach_msg_audit_trailer_t trailer;
    char slack[64];
} hello_rcv_t;

static int child(void)
{
    if (bootstrap_port == MACH_PORT_NULL)
        probe_fail("child: bootstrap_port is MACH_PORT_NULL");
    mach_port_t special = MACH_PORT_NULL;
    kern_return_t kr = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &special);
    if (kr != KERN_SUCCESS)
        probe_fail("child: task_get_special_port(BOOTSTRAP): %#x", kr);
    if (special != bootstrap_port)
        probe_fail("child: task_get_special_port gave %#x, bootstrap_port is %#x", special, bootstrap_port);

    hello_msg_t m;
    memset(&m, 0, sizeof m);
    m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    m.h.msgh_size = sizeof m;
    m.h.msgh_remote_port = bootstrap_port;
    m.h.msgh_id = MSG_ID;
    m.pid = getpid();
    kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, PROBE_TIMEOUT_MS,
                  MACH_PORT_NULL);
    if (kr != KERN_SUCCESS)
        probe_fail("child: send to bootstrap_port %#x: %#x", bootstrap_port, kr);
    return 0;
}

int main(int argc, char **argv)
{
    probe_name = "p_spawn_port";
    if (argc >= 2 && strcmp(argv[1], "child") == 0)
        return child();

    const char *self = probe_self_path(argv[0]);
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    if (kr != KERN_SUCCESS)
        probe_fail("mach_port_allocate: %#x", kr);
    kr = mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS)
        probe_fail("mach_port_insert_right: %#x", kr);

    posix_spawnattr_t attr;
    int err = posix_spawnattr_init(&attr);
    if (err != 0)
        probe_fail("posix_spawnattr_init: %d", err);
    err = posix_spawnattr_setspecialport_np(&attr, port, TASK_BOOTSTRAP_PORT);
    if (err != 0)
        probe_fail("posix_spawnattr_setspecialport_np: %d", err);
    pid_t pid = -1;
    err = probe_spawn(&pid, self, NULL, &attr, "child", NULL);
    if (err != 0)
        probe_fail("posix_spawn: %d (%s)", err, strerror(err));
    posix_spawnattr_destroy(&attr);

    hello_rcv_t r;
    memset(&r, 0, sizeof r);
    kr = mach_msg(&r.m.h,
                  MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                      MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                  0, sizeof r, port, PROBE_TIMEOUT_MS, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS)
        probe_fail("receive from the child: %#x", kr);
    if (r.m.h.msgh_id != MSG_ID)
        probe_fail("message id %d, expected %d", r.m.h.msgh_id, MSG_ID);
    const mach_msg_audit_trailer_t *t =
        (const mach_msg_audit_trailer_t *)((const char *)&r.m.h + round_msg(r.m.h.msgh_size));
    if (t->msgh_trailer_size < sizeof(mach_msg_audit_trailer_t))
        probe_fail("trailer size %u, expected at least %zu", t->msgh_trailer_size,
                   sizeof(mach_msg_audit_trailer_t));
    int token_pid = (int)t->msgh_audit.val[5];
    if (r.m.pid != pid)
        probe_fail("child says its pid is %d, posix_spawn said %d", r.m.pid, (int)pid);
    int pid_match = token_pid == pid;
    if (!pid_match)
        probe_fail("audit token pid %d, child pid %d", token_pid, (int)pid);

    probe_expect_exit(pid, 0, "child");
    printf("spawn_port ok pid_match=%d\n", pid_match);
    return 0;
}
