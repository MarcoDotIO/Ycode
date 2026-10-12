/* Ycode stage-4 probe: Mach IPC within one task: a port right, a complex message, receive. Original Ycode code. */
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    mach_msg_header_t h;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port;
    mach_msg_ool_descriptor_t ool;
    int value;
} msg_t;

typedef struct { msg_t m; mach_msg_trailer_t trailer; } rcv_t;

int main(void)
{
    mach_port_t rcv, extra;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rcv);
    if (kr) { printf("allocate %d\n", kr); return 2; }
    kr = mach_port_insert_right(mach_task_self(), rcv, rcv, MACH_MSG_TYPE_MAKE_SEND);
    if (kr) { printf("insert_right %d\n", kr); return 2; }
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &extra);
    static char payload[40000];
    memset(payload, 'x', sizeof payload);
    msg_t m = {0};
    m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    m.h.msgh_size = sizeof m;
    m.h.msgh_remote_port = rcv;
    m.h.msgh_id = 4242;
    m.body.msgh_descriptor_count = 2;
    m.port.name = extra; m.port.disposition = MACH_MSG_TYPE_MAKE_SEND; m.port.type = MACH_MSG_PORT_DESCRIPTOR;
    m.ool.address = payload; m.ool.size = sizeof payload; m.ool.copy = MACH_MSG_VIRTUAL_COPY;
    m.ool.deallocate = 0; m.ool.type = MACH_MSG_OOL_DESCRIPTOR;
    m.value = 7;
    kr = mach_msg(&m.h, MACH_SEND_MSG, sizeof m, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
    if (kr) { printf("send %#x\n", kr); return 2; }
    rcv_t r = {0};
    kr = mach_msg(&r.m.h, MACH_RCV_MSG, 0, sizeof r, rcv, 0, MACH_PORT_NULL);
    if (kr) { printf("receive %#x\n", kr); return 2; }
    printf("machmsg ok id=%d value=%d ool=%u port=%#x\n", r.m.h.msgh_id, r.m.value, r.m.ool.size, r.m.port.name);
    return 0;
}
