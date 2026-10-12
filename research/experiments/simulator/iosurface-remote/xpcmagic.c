/*
 * xpcmagic: which serialization magic does libxpc use on a connection with
 * and without xpc_connection_enable_sim2host_4sim? (original Ycode code, R5)
 * It makes a raw receive right, wraps it in an endpoint
 * (xpc_endpoint_create_mach_port_4sim), connects, sends one dictionary with
 * a reply expected, and prints the first 8 payload bytes of what arrives.
 * Usage: xpcmagic [sim2host]
 */
#include <mach/mach.h>
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern xpc_endpoint_t xpc_endpoint_create_mach_port_4sim(mach_port_t port);
extern void xpc_connection_enable_sim2host_4sim(xpc_connection_t c);

int main(int argc, char **argv)
{
    int s2h = argc > 1 && !strcmp(argv[1], "sim2host");
    mach_port_t p;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &p);
    mach_port_insert_right(mach_task_self(), p, p, MACH_MSG_TYPE_MAKE_SEND);
    xpc_connection_t c = xpc_connection_create_from_endpoint(xpc_endpoint_create_mach_port_4sim(p));
    xpc_connection_set_event_handler(c, ^(xpc_object_t e) { (void)e; });
    if (s2h) xpc_connection_enable_sim2host_4sim(c);
    xpc_connection_resume(c);
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(m, "Method", 0);
    xpc_connection_send_message_with_reply(c, m, dispatch_get_global_queue(0, 0), ^(xpc_object_t r) { (void)r; });
    mach_port_t conn = MACH_PORT_NULL;
    for (int i = 0; i < 2; i++) {
        uint8_t buf[4096];
        mach_msg_header_t *h = (void *)buf;
        kern_return_t kr = mach_msg(h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof buf, i ? conn : p, 2000, MACH_PORT_NULL);
        if (kr) { printf("receive %d: 0x%x\n", i, kr); return 1; }
        printf("%s msg %d: id=0x%x size=%u bits=0x%x\n", s2h ? "sim2host" : "plain", i, h->msgh_id, h->msgh_size, h->msgh_bits);
        if (i == 0 && (h->msgh_bits & MACH_MSGH_BITS_COMPLEX)) {
            mach_msg_port_descriptor_t *d = (void *)(buf + sizeof *h + 4);
            conn = d[0].name; /* the receive right the client hands over */
        } else {
            size_t off = sizeof *h;
            printf("  payload starts: %02x %02x %02x %02x %02x %02x %02x %02x (\"%.4s\")\n", buf[off], buf[off + 1], buf[off + 2],
                   buf[off + 3], buf[off + 4], buf[off + 5], buf[off + 6], buf[off + 7], (char *)buf + off);
        }
    }
    return 0;
}
