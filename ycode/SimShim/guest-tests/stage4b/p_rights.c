/* Ycode stage-4b probe: rights between tasks (processes.md sections 4.1,
 * 4.2, 4.6). Original Ycode code.
 *   1. The parent's port P is the child's bootstrap port. The child sends
 *      "hello" to it with a send right to its own port C as the reply port.
 *   2. The parent makes port Q, keeps a send right, and moves Q's receive
 *      right to the child in a message on C. It arms a dead-name request on
 *      its send right to Q, then sends a message to Q.
 *   3. The child receives Q's receive right and the queued message on it,
 *      then sends back on P a message whose reply port is a send right to
 *      Q: in the parent it must merge into the parent's existing name.
 *      The child then waits for the parent's acknowledgement on C: if it
 *      exited first, Q would die while that send right is still in
 *      transit and the parent would correctly receive MACH_PORT_DEAD.
 *   4. After the acknowledgement the child exits. Q dies with the child's space: the parent gets a
 *      MACH_NOTIFY_DEAD_NAME for its name of Q, and the name is a dead name.
 * Prints: rights ok */
#include <mach/mach.h>

#include "probe_util.h"

enum { ID_HELLO = 0x4b10, ID_GIVE = 0x4b11, ID_ON_Q = 0x4b12, ID_BACK = 0x4b13, ID_ACK = 0x4b14 };
#define VALUE_ON_Q 0x5eed1234

typedef struct {
    mach_msg_header_t h;
    int value;
} simple_msg_t;

typedef struct {
    mach_msg_header_t h;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port;
} give_msg_t;

typedef union {
    simple_msg_t simple;
    give_msg_t give;
    mach_dead_name_notification_t dead;
    char buf[512];
} rcv_buf_t;

static mach_port_t new_receive_right(void)
{
    mach_port_t p = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &p);
    if (kr != KERN_SUCCESS)
        probe_fail("mach_port_allocate: %#x", kr);
    return p;
}

static void receive(mach_port_t port, rcv_buf_t *r, const char *what)
{
    memset(r, 0, sizeof *r);
    kern_return_t kr = mach_msg(&r->simple.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof *r, port,
                                PROBE_TIMEOUT_MS, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS)
        probe_fail("receive %s on %#x: %#x", what, port, kr);
}

static void send_simple(mach_port_t dest, mach_msg_type_name_t dest_disp, mach_port_t reply,
                        mach_msg_type_name_t reply_disp, int id, int value, const char *what)
{
    simple_msg_t m;
    memset(&m, 0, sizeof m);
    m.h.msgh_bits = MACH_MSGH_BITS(dest_disp, reply_disp);
    m.h.msgh_size = sizeof m;
    m.h.msgh_remote_port = dest;
    m.h.msgh_local_port = reply;
    m.h.msgh_id = id;
    m.value = value;
    kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL,
                                PROBE_TIMEOUT_MS, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS)
        probe_fail("send %s to %#x: %#x", what, dest, kr);
}

static int child(void)
{
    if (bootstrap_port == MACH_PORT_NULL)
        probe_fail("child: bootstrap_port is MACH_PORT_NULL");
    mach_port_t c = new_receive_right();
    send_simple(bootstrap_port, MACH_MSG_TYPE_COPY_SEND, c, MACH_MSG_TYPE_MAKE_SEND, ID_HELLO, getpid(),
                "hello");

    rcv_buf_t r;
    receive(c, &r, "the receive right");
    if (r.give.h.msgh_id != ID_GIVE || !(r.give.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
        r.give.body.msgh_descriptor_count != 1 || r.give.port.type != MACH_MSG_PORT_DESCRIPTOR ||
        r.give.port.disposition != MACH_MSG_TYPE_PORT_RECEIVE)
        probe_fail("child: unexpected message id %d bits %#x (want one moved receive right)", r.give.h.msgh_id,
                   r.give.h.msgh_bits);
    mach_port_t q = r.give.port.name;
    mach_port_type_t type = 0;
    if (mach_port_type(mach_task_self(), q, &type) != KERN_SUCCESS || !(type & MACH_PORT_TYPE_RECEIVE))
        probe_fail("child: name %#x does not hold a receive right (type %#x)", q, type);

    receive(q, &r, "the message queued on Q");
    if (r.simple.h.msgh_id != ID_ON_Q || r.simple.value != VALUE_ON_Q)
        probe_fail("child: message on Q has id %d value %#x", r.simple.h.msgh_id, r.simple.value);

    /* Back to the parent, carrying a new send right to Q as the reply port. */
    send_simple(bootstrap_port, MACH_MSG_TYPE_COPY_SEND, q, MACH_MSG_TYPE_MAKE_SEND, ID_BACK, 0, "back");

    /* Stay alive until the parent has received that right. */
    receive(c, &r, "the acknowledgement");
    if (r.simple.h.msgh_id != ID_ACK)
        probe_fail("child: expected the acknowledgement, got id %d", r.simple.h.msgh_id);
    return 0; /* exit: Q's receive right dies with this task */
}

int main(int argc, char **argv)
{
    probe_name = "p_rights";
    if (argc >= 2 && strcmp(argv[1], "child") == 0)
        return child();

    const char *self = probe_self_path(argv[0]);
    mach_port_t task = mach_task_self();
    mach_port_t p = new_receive_right();
    kern_return_t kr = mach_port_insert_right(task, p, p, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS)
        probe_fail("insert_right(P): %#x", kr);
    mach_port_t notify = new_receive_right();

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0 || posix_spawnattr_setspecialport_np(&attr, p, TASK_BOOTSTRAP_PORT) != 0)
        probe_fail("spawn attributes");
    pid_t pid = -1;
    int err = probe_spawn(&pid, self, NULL, &attr, "child", NULL);
    if (err != 0)
        probe_fail("posix_spawn: %d (%s)", err, strerror(err));
    posix_spawnattr_destroy(&attr);

    /* 1. hello, with a send right to the child's port C. */
    rcv_buf_t r;
    receive(p, &r, "hello");
    if (r.simple.h.msgh_id != ID_HELLO || r.simple.value != pid)
        probe_fail("hello: id %d value %d (child pid %d)", r.simple.h.msgh_id, r.simple.value, (int)pid);
    mach_port_t c = r.simple.h.msgh_remote_port;
    if (MACH_MSGH_BITS_REMOTE(r.simple.h.msgh_bits) != MACH_MSG_TYPE_PORT_SEND || !MACH_PORT_VALID(c))
        probe_fail("hello: no send right to the child's port (bits %#x name %#x)", r.simple.h.msgh_bits, c);

    /* 2. Q: keep a send right, move the receive right to the child. */
    mach_port_t q = new_receive_right();
    kr = mach_port_insert_right(task, q, q, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS)
        probe_fail("insert_right(Q): %#x", kr);
    give_msg_t g;
    memset(&g, 0, sizeof g);
    g.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    g.h.msgh_size = sizeof g;
    g.h.msgh_remote_port = c;
    g.h.msgh_id = ID_GIVE;
    g.body.msgh_descriptor_count = 1;
    g.port.name = q;
    g.port.disposition = MACH_MSG_TYPE_MOVE_RECEIVE;
    g.port.type = MACH_MSG_PORT_DESCRIPTOR;
    kr = mach_msg(&g.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof g, 0, MACH_PORT_NULL, PROBE_TIMEOUT_MS,
                  MACH_PORT_NULL);
    if (kr != KERN_SUCCESS)
        probe_fail("send Q's receive right: %#x", kr);
    mach_port_type_t type = 0;
    if (mach_port_type(task, q, &type) != KERN_SUCCESS || (type & MACH_PORT_TYPE_RECEIVE) ||
        !(type & MACH_PORT_TYPE_SEND))
        probe_fail("after the move, Q's name has type %#x (want send only)", type);

    mach_port_t previous = MACH_PORT_NULL;
    kr = mach_port_request_notification(task, q, MACH_NOTIFY_DEAD_NAME, 0, notify, MACH_MSG_TYPE_MAKE_SEND_ONCE,
                                        &previous);
    if (kr != KERN_SUCCESS)
        probe_fail("dead-name request on Q: %#x", kr);
    send_simple(q, MACH_MSG_TYPE_COPY_SEND, MACH_PORT_NULL, 0, ID_ON_Q, VALUE_ON_Q, "a message to Q");

    /* 3. The child answers with a send right to Q: same name as ours. */
    receive(p, &r, "the child's answer");
    if (r.simple.h.msgh_id != ID_BACK)
        probe_fail("answer: id %d", r.simple.h.msgh_id);
    if (r.simple.h.msgh_remote_port != q)
        probe_fail("the send right to Q arrived as %#x, expected it to merge into %#x", r.simple.h.msgh_remote_port,
                   q);

    /* Let the child exit now that the right has arrived. */
    send_simple(c, MACH_MSG_TYPE_COPY_SEND, MACH_PORT_NULL, 0, ID_ACK, 0, "the acknowledgement");

    /* 4. Child exit kills Q: dead-name notification and a dead name. */
    probe_expect_exit(pid, 0, "child");
    receive(notify, &r, "the dead-name notification");
    if (r.dead.not_header.msgh_id != MACH_NOTIFY_DEAD_NAME)
        probe_fail("notification id %d, expected MACH_NOTIFY_DEAD_NAME (%d)", r.dead.not_header.msgh_id,
                   MACH_NOTIFY_DEAD_NAME);
    if (r.dead.not_port != q)
        probe_fail("dead-name notification names %#x, expected %#x", r.dead.not_port, q);
    type = 0;
    if (mach_port_type(task, q, &type) != KERN_SUCCESS || !(type & MACH_PORT_TYPE_DEAD_NAME))
        probe_fail("Q's name has type %#x after the child exited (want a dead name)", type);
    type = 0;
    if (mach_port_type(task, c, &type) != KERN_SUCCESS || !(type & MACH_PORT_TYPE_DEAD_NAME))
        probe_fail("the child's port C has type %#x after the child exited (want a dead name)", type);

    printf("rights ok\n");
    return 0;
}
