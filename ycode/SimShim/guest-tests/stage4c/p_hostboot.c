/* Ycode stage-4c probe: the host bootstrap server (stage4c-contract.md §8,
 * bootstrap-wire.md §5.2 and §7). Original Ycode code.
 * Run with `ycode-simd --exec p_hostboot --host-bootstrap` (or as a device job).
 *   1. A bare 24-byte request with msgh_id 708 to the bootstrap port gets the
 *      808 reply: complex, 40 bytes, one port descriptor with a receive right.
 *   2. Pipe routine 207 (look-up) of an unknown name answers {error: 1102},
 *      804 (XPC look-up) {error: 3}.
 *   3. Pipe routine 206 (check-in) answers {port: receive right}.
 *   4. Pipe routine 204 (register) answers {error: 45}.
 * The pipe requests are written by hand; argv[1] "libxpc" sends them through
 * the runtime's bootstrap_* functions instead.
 * Prints "hostboot ok". */
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

/* The bootstrap API (the iOS SDK has no servers/bootstrap.h). */
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t, const char *, mach_port_t *);
extern kern_return_t bootstrap_check_in(mach_port_t, const char *, mach_port_t *);
extern kern_return_t bootstrap_register(mach_port_t, const char *, mach_port_t);
#define BOOTSTRAP_UNKNOWN_SERVICE 1102

static void fail(const char *what, long value)
{
    fprintf(stderr, "p_hostboot[%d]: FAIL: %s (%ld / %#lx)\n", (int)getpid(), what, value, (unsigned long)value);
    fflush(stderr);
    exit(1);
}

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port;
    mach_msg_trailer_t trailer;
    char slack[256];
} reply_708_t;

static int has_receive(mach_port_t name)
{
    mach_port_type_t type = 0;
    if (mach_port_type(mach_task_self(), name, &type) != KERN_SUCCESS)
        return 0;
    return (type & MACH_PORT_TYPE_RECEIVE) != 0;
}

/* Appends a NUL-terminated key, padded to 4 bytes. */
static size_t put_key(unsigned char *p, const char *key)
{
    size_t n = strlen(key) + 1, padded = (n + 3) & ~(size_t)3;
    memset(p, 0, padded);
    memcpy(p, key, n);
    return padded;
}

static size_t put_u32(unsigned char *p, uint32_t v) { memcpy(p, &v, 4); return 4; }
static size_t put_u64(unsigned char *p, uint64_t v) { memcpy(p, &v, 8); return 8; }

/* Sends pipe routine `routine` with {handle: 0, flags: 0, name, type: 7}
 * and decodes the reply: `error` (0 if absent) and a received port. */
static void pipe_call(uint32_t routine, const char *name, long *error, mach_port_t *port)
{
    struct {
        mach_msg_header_t header;
        unsigned char payload[512];
    } request;
    struct {
        mach_msg_header_t header;
        unsigned char rest[1024];
    } reply;
    memset(&request, 0, sizeof request);
    unsigned char *p = request.payload;
    p += put_u32(p, 0x7870633Fu); /* "?cpx" */
    p += put_u32(p, 5);
    p += put_u32(p, 0xF000);
    unsigned char *length = p;
    p += 4;
    unsigned char *start = p;
    p += put_u32(p, 4);
    p += put_key(p, "handle");
    p += put_u32(p, 0x4000);
    p += put_u64(p, 0);
    p += put_key(p, "flags");
    p += put_u32(p, 0x4000);
    p += put_u64(p, 0);
    p += put_key(p, "name");
    p += put_u32(p, 0x9000);
    size_t n = strlen(name) + 1;
    p += put_u32(p, (uint32_t)n);
    memcpy(p, name, n);
    p += (n + 3) & ~(size_t)3;
    p += put_key(p, "type");
    p += put_u32(p, 0x4000);
    p += put_u64(p, 7);
    put_u32(length, (uint32_t)(p - start));

    mach_port_t reply_port = mig_get_reply_port();
    request.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    request.header.msgh_size = (mach_msg_size_t)(sizeof(mach_msg_header_t) + (size_t)(p - request.payload));
    request.header.msgh_remote_port = bootstrap_port;
    request.header.msgh_local_port = reply_port;
    request.header.msgh_id = (mach_msg_id_t)(0x40000000u | routine);
    kern_return_t kr = mach_msg(&request.header, MACH_SEND_MSG, request.header.msgh_size, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
    if (kr != MACH_MSG_SUCCESS)
        fail("pipe send", kr);
    memset(&reply, 0, sizeof reply);
    kr = mach_msg(&reply.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof reply, reply_port, 10000, MACH_PORT_NULL);
    if (kr != MACH_MSG_SUCCESS)
        fail("pipe receive", kr);
    if ((uint32_t)reply.header.msgh_id != 0x20000000u)
        fail("pipe reply id", reply.header.msgh_id);
    unsigned char *q = reply.rest;
    *port = MACH_PORT_NULL;
    if (reply.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) {
        uint32_t count;
        memcpy(&count, q, 4);
        q += 4;
        for (uint32_t i = 0; i < count; i++) {
            mach_msg_port_descriptor_t d;
            memcpy(&d, q, sizeof d);
            if (d.type != MACH_MSG_PORT_DESCRIPTOR)
                fail("pipe reply descriptor type", d.type);
            if (i == 0)
                *port = d.name;
            q += sizeof d;
        }
    }
    /* Header, then the dictionary; find "error" (int64) if present. */
    uint32_t magic, count;
    memcpy(&magic, q, 4);
    if (magic != 0x7870633Fu)
        fail("pipe reply magic", magic);
    memcpy(&count, q + 16, 4);
    q += 20;
    *error = 0;
    for (uint32_t i = 0; i < count; i++) {
        const char *key = (const char *)q;
        q += (strlen(key) + 1 + 3) & ~(size_t)3;
        uint32_t tag;
        memcpy(&tag, q, 4);
        q += 4;
        if (tag == 0x3000 || tag == 0x4000) {
            int64_t v;
            memcpy(&v, q, 8);
            q += 8;
            if (strcmp(key, "error") == 0)
                *error = (long)v;
        } else if (tag != 0xD000 && tag != 0x15000) {
            fail("pipe reply: unexpected tag", tag);
        }
    }
}

int main(int argc, char **argv)
{
    int use_libxpc = argc >= 2 && strcmp(argv[1], "libxpc") == 0;
    /* 1. The startup request of launchd_sim. */
    mach_port_t reply = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply);
    if (kr != KERN_SUCCESS)
        fail("mach_port_allocate", kr);
    reply_708_t msg;
    memset(&msg, 0, sizeof msg);
    msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    msg.header.msgh_size = sizeof(mach_msg_header_t);
    msg.header.msgh_remote_port = bootstrap_port;
    msg.header.msgh_local_port = reply;
    msg.header.msgh_id = 708;
    kr = mach_msg(&msg.header, MACH_SEND_MSG | MACH_RCV_MSG | MACH_RCV_TIMEOUT, sizeof(mach_msg_header_t),
                  sizeof msg, reply, 10000, MACH_PORT_NULL);
    if (kr != MACH_MSG_SUCCESS)
        fail("708: mach_msg", kr);
    if (msg.header.msgh_id != 808)
        fail("708: reply id", msg.header.msgh_id);
    if (!(msg.header.msgh_bits & MACH_MSGH_BITS_COMPLEX))
        fail("708: reply not complex, bits", msg.header.msgh_bits);
    if (msg.header.msgh_size != 40)
        fail("708: reply size", msg.header.msgh_size);
    if (msg.body.msgh_descriptor_count != 1 || msg.port.type != MACH_MSG_PORT_DESCRIPTOR)
        fail("708: descriptors", msg.body.msgh_descriptor_count);
    if (msg.port.disposition != MACH_MSG_TYPE_PORT_RECEIVE)
        fail("708: descriptor disposition", msg.port.disposition);
    if (!MACH_PORT_VALID(msg.port.name) || !has_receive(msg.port.name))
        fail("708: no receive right at", msg.port.name);
    mach_port_t service = msg.port.name;

    /* 2-4. Pipe routines, written by hand (bootstrap-wire.md §2, §3), so
     * the test does not depend on the runtime's libxpc. With "libxpc" as
     * argv[1], the same calls go through bootstrap_look_up & co. */
    mach_port_t checked = MACH_PORT_NULL;
    if (use_libxpc) {
        mach_port_t found = MACH_PORT_NULL;
        kr = bootstrap_look_up(bootstrap_port, "com.ycode.probe.no-such-service", &found);
        if (kr != BOOTSTRAP_UNKNOWN_SERVICE)
            fail("bootstrap_look_up of an unknown name", kr);
        kr = bootstrap_check_in(bootstrap_port, "com.ycode.probe.checkin", &checked);
        if (kr != KERN_SUCCESS)
            fail("bootstrap_check_in", kr);
        kr = bootstrap_register(bootstrap_port, "com.ycode.probe.register", checked);
        if (kr != 45)
            fail("bootstrap_register", kr);
    } else {
        long error = 0;
        mach_port_t port = MACH_PORT_NULL;
        pipe_call(207, "com.ycode.probe.no-such-service", &error, &port);
        if (error != 1102 || port != MACH_PORT_NULL)
            fail("routine 207 (look-up of an unknown name): error", error);
        pipe_call(804, "com.ycode.probe.no-such-service", &error, &port);
        if (error != 3)
            fail("routine 804 (XPC look-up of an unknown name): error", error);
        pipe_call(206, "com.ycode.probe.checkin", &error, &port);
        if (error != 0 || !MACH_PORT_VALID(port))
            fail("routine 206 (check-in): error", error);
        checked = port;
        pipe_call(204, "com.ycode.probe.register", &error, &port);
        if (error != 45)
            fail("routine 204 (register): error", error);
    }
    if (!MACH_PORT_VALID(checked) || !has_receive(checked))
        fail("check-in: no receive right at", checked);

    printf("hostboot ok service=%#x checkin=%#x\n", service, checked);
    return 0;
}
