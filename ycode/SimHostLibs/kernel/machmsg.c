/*
 * machmsg.c - libsystem_kernel's Mach message routines: mach_msg2_internal
 * over Mach trap -47, mach_msg / mach_msg_overwrite and their send/receive
 * shorthands, mach_msg_destroy, mach_msg_server / mach_msg_server_once, and
 * mach_msg_priority_encode.
 *
 * Clean-room Ycode code. Facts used:
 *  - mach-ipc.md section 2.7: the mach_msg2 register packing (eight 64-bit
 *    words, "low 32 | high 32 << 32"), the option bits, the library-only
 *    SEND_INTERRUPT / RCV_INTERRUPT bits and the retry rules, MQ_CALL for
 *    mach_msg(), the legacy trap -32 layout;
 *  - mach-ipc.md sections 2.1-2.3: header, body word, descriptor layouts;
 *  - mach-ipc.md section 4.4: mach_msg_destroy semantics;
 *  - mach-ipc.md sections 2.8, 2.10, 5.1, 5.2: the MIG server conventions
 *    (reply header, mig_reply_error_t, MIG_NO_REPLY, MOVE_SEND replies
 *    sent with MACH_SEND_TIMEOUT 0, the send errors that leave a message
 *    intact) and RCV_LARGE, for mach_msg_server and mach_msg_server_once
 *    (device-pairing.md section 10: ids_simd serves its transport port with
 *    mach_msg_server_once);
 *  - the public Mach C API (xnu's open-source <mach/message.h>): routine
 *    signatures, mach_msg2_internal's eight packed arguments, and the
 *    mach_msg_priority_t field layout (relative priority bits 8-15, QoS
 *    bits 16-19, override QoS bits 20-23). The kernel ignores message
 *    priorities (mach-ipc.md section 2.7, MACH_SEND_OVERRIDE).
 */
#include "yc_kernel.h"

#define YC_MACH_SEND_MSG 0x00000001ull
#define YC_MACH_RCV_MSG 0x00000002ull
#define YC_MACH_SEND_INTERRUPT 0x00000040ull
#define YC_MACH_RCV_INTERRUPT 0x00000400ull
#define YC_MACH_RCV_SYNC_WAIT 0x00004000ull
#define YC_MACH64_MSG_VECTOR (1ull << 32)
#define YC_MACH64_SEND_MQ_CALL (1ull << 34)
#define YC_LIBRARY_ONLY_OPTIONS (YC_MACH_SEND_INTERRUPT | YC_MACH_RCV_INTERRUPT)

#define YC_MACH_SEND_INTERRUPTED 0x10000007
#define YC_MACH_RCV_INTERRUPTED 0x10004005

#define YC_MACH_MSGH_BITS_COMPLEX 0x80000000u
#define YC_HEADER_SIZE 24u
#define YC_BASE_SIZE 28u /* header + descriptor count */

#define YC_LOW32 0x00000000FFFFFFFFull
#define YC_PACK(lo, hi) ((yc_u64)(yc_u32)(lo) | ((yc_u64)(yc_u32)(hi) << 32))

struct yc_mach_msg_header {
    yc_u32 msgh_bits;
    yc_u32 msgh_size;
    yc_port_t msgh_remote_port;
    yc_port_t msgh_local_port;
    yc_port_t msgh_voucher_port;
    int msgh_id;
};

/* ------------------------------------------------------------- mach_msg2 */

static inline int mach_msg2_trap_raw(yc_uintptr_t data, yc_u64 options, yc_u64 bits_send, yc_u64 remote_local,
                                     yc_u64 voucher_id, yc_u64 desc_rcvname, yc_u64 rcvsize_prio, yc_u64 timeout)
{
    register yc_uintptr_t x0 __asm__("x0") = data;
    register yc_u64 x1 __asm__("x1") = options;
    register yc_u64 x2 __asm__("x2") = bits_send;
    register yc_u64 x3 __asm__("x3") = remote_local;
    register yc_u64 x4 __asm__("x4") = voucher_id;
    register yc_u64 x5 __asm__("x5") = desc_rcvname;
    register yc_u64 x6 __asm__("x6") = rcvsize_prio;
    register yc_u64 x7 __asm__("x7") = timeout;
    register long x16 __asm__("x16") = YC_TRAP_MACH_MSG2;
    __asm__ volatile("svc #0x80"
                     : "+r"(x0), "+r"(x1)
                     : "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x6), "r"(x7), "r"(x16)
                     : "memory", "cc");
    return (int)x0;
}

/* mach_msg_return_t mach_msg2_internal(void *data,
 *     mach_msg_option64_t option64, uint64_t msgh_bits_and_send_size,
 *     uint64_t msgh_remote_and_local_port, uint64_t msgh_voucher_and_id,
 *     uint64_t desc_count_and_rcv_name, uint64_t rcv_size_and_priority,
 *     uint64_t timeout)
 * The arguments are already packed as trap -47 takes them. The library-only
 * interrupt bits are stripped before the trap. MACH_SEND_INTERRUPTED
 * retries the same call unless SEND_INTERRUPT was given;
 * MACH_RCV_INTERRUPTED retries as a receive-only call (SEND_MSG and
 * RCV_SYNC_WAIT cleared, send size and descriptor count 0) unless
 * RCV_INTERRUPT was given. */
YC_EXPORT int mach_msg2_internal(void *data, yc_u64 option64, yc_u64 msgh_bits_and_send_size,
                                 yc_u64 msgh_remote_and_local_port, yc_u64 msgh_voucher_and_id,
                                 yc_u64 desc_count_and_rcv_name, yc_u64 rcv_size_and_priority, yc_u64 timeout)
{
    yc_u64 trap_options = option64 & ~YC_LIBRARY_ONLY_OPTIONS;
    for (;;) {
        int mr = mach_msg2_trap_raw((yc_uintptr_t)data, trap_options, msgh_bits_and_send_size,
                                    msgh_remote_and_local_port, msgh_voucher_and_id, desc_count_and_rcv_name,
                                    rcv_size_and_priority, timeout);
        if (mr == YC_MACH_SEND_INTERRUPTED && !(option64 & YC_MACH_SEND_INTERRUPT))
            continue;
        if (mr == YC_MACH_RCV_INTERRUPTED && !(option64 & YC_MACH_RCV_INTERRUPT)) {
            trap_options &= ~(YC_MACH_SEND_MSG | YC_MACH_RCV_SYNC_WAIT);
            if (!(trap_options & YC_MACH64_MSG_VECTOR))
                msgh_bits_and_send_size &= YC_LOW32; /* send size 0 */
            desc_count_and_rcv_name &= ~YC_LOW32;   /* descriptor count 0 */
            continue;
        }
        return mr;
    }
}

/* Packs a scalar mach_msg call (msg, option, send_size, rcv_size,
 * rcv_name, timeout, priority) for trap -47 with MQ_CALL. The header
 * words are read from memory only when sending; on a receive-only call
 * with RCV_SYNC_WAIT the priority argument is the sync-wait destination
 * name and goes into the low half of x3. */
static int mach_msg_scalar(struct yc_mach_msg_header *msg, yc_u32 option, yc_u32 send_size, yc_u32 rcv_size,
                           yc_port_t rcv_name, yc_u32 timeout, yc_u32 priority)
{
    yc_u64 bits_send = 0, remote_local = 0, voucher_id = 0;
    yc_u32 desc_count = 0;
    if (option & YC_MACH_SEND_MSG) {
        yc_u32 bits = msg->msgh_bits;
        bits_send = YC_PACK(bits, send_size);
        remote_local = YC_PACK(msg->msgh_remote_port, msg->msgh_local_port);
        voucher_id = YC_PACK(msg->msgh_voucher_port, msg->msgh_id);
        if ((bits & YC_MACH_MSGH_BITS_COMPLEX) && send_size >= YC_BASE_SIZE)
            desc_count = *(const volatile yc_u32 *)((const char *)msg + YC_HEADER_SIZE);
    } else if (option & YC_MACH_RCV_SYNC_WAIT) {
        remote_local = YC_PACK(priority, 0);
    }
    return mach_msg2_internal(msg, (yc_u64)option | YC_MACH64_SEND_MQ_CALL, bits_send, remote_local, voucher_id,
                              YC_PACK(desc_count, rcv_name), YC_PACK(rcv_size, priority), timeout);
}

/* mach_msg_return_t mach_msg(mach_msg_header_t *msg, mach_msg_option_t
 *     option, mach_msg_size_t send_size, mach_msg_size_t rcv_size,
 *     mach_port_name_t rcv_name, mach_msg_timeout_t timeout,
 *     mach_msg_priority_t priority) */
YC_EXPORT int mach_msg(struct yc_mach_msg_header *msg, yc_u32 option, yc_u32 send_size, yc_u32 rcv_size,
                       yc_port_t rcv_name, yc_u32 timeout, yc_u32 priority)
{
    return mach_msg_scalar(msg, option, send_size, rcv_size, rcv_name, timeout, priority);
}

/* mach_msg_overwrite(msg, option, send_size, rcv_size, rcv_name, timeout,
 *     priority, rcv_msg, rcv_limit): with no separate receive buffer this
 * is mach_msg. A separate buffer uses the legacy trap -32 (x7 = rcv_msg),
 * which Ycode's kernel accepts (mach-ipc.md section 6, item 4). The ninth
 * argument (rcv_limit, on the stack) is not passed to any trap and is not
 * read. */
YC_EXPORT int mach_msg_overwrite(struct yc_mach_msg_header *msg, yc_u32 option, yc_u32 send_size, yc_u32 rcv_size,
                                 yc_port_t rcv_name, yc_u32 timeout, yc_u32 priority,
                                 struct yc_mach_msg_header *rcv_msg)
{
    if (rcv_msg == YC_NULL || rcv_msg == msg)
        return mach_msg_scalar(msg, option, send_size, rcv_size, rcv_name, timeout, priority);
    yc_u32 trap_option = option & ~(yc_u32)YC_LIBRARY_ONLY_OPTIONS;
    for (;;) {
        register yc_uintptr_t x0 __asm__("x0") = (yc_uintptr_t)msg;
        register yc_uintptr_t x1 __asm__("x1") = trap_option;
        register yc_uintptr_t x2 __asm__("x2") = send_size;
        register yc_uintptr_t x3 __asm__("x3") = rcv_size;
        register yc_uintptr_t x4 __asm__("x4") = rcv_name;
        register yc_uintptr_t x5 __asm__("x5") = timeout;
        register yc_uintptr_t x6 __asm__("x6") = priority;
        register yc_uintptr_t x7 __asm__("x7") = (yc_uintptr_t)rcv_msg;
        register long x16 __asm__("x16") = YC_TRAP_MACH_MSG_OVERWRITE;
        __asm__ volatile("svc #0x80"
                         : "+r"(x0), "+r"(x1)
                         : "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x6), "r"(x7), "r"(x16)
                         : "memory", "cc");
        int mr = (int)x0;
        if (mr == YC_MACH_SEND_INTERRUPTED && !(option & YC_MACH_SEND_INTERRUPT))
            continue;
        if (mr == YC_MACH_RCV_INTERRUPTED && !(option & YC_MACH_RCV_INTERRUPT)) {
            trap_option &= ~(yc_u32)(YC_MACH_SEND_MSG | YC_MACH_RCV_SYNC_WAIT);
            send_size = 0;
            continue;
        }
        return mr;
    }
}

YC_EXPORT int mach_msg_send(struct yc_mach_msg_header *msg)
{
    return mach_msg(msg, YC_MACH_SEND_MSG, msg->msgh_size, 0, YC_MACH_PORT_NULL, 0, 0);
}

YC_EXPORT int mach_msg_receive(struct yc_mach_msg_header *msg)
{
    return mach_msg(msg, YC_MACH_RCV_MSG, 0, msg->msgh_size, msg->msgh_local_port, 0, 0);
}

/* ----------------------------------------------------- mach_msg_destroy */

/* Descriptor kinds and layouts (mach-ipc.md section 2.3). The type is the
 * byte at offset 11; port descriptors are 12 bytes, the others 16. Fields
 * are only 4-byte aligned. */
#define YC_DESC_PORT 0
#define YC_DESC_OOL 1
#define YC_DESC_OOL_PORTS 2
#define YC_DESC_OOL_VOLATILE 3
#define YC_DESC_GUARDED_PORT 4
#define YC_GUARD_UNGUARDED_ON_SEND 0x2u

typedef yc_u64 yc_u64_a4 __attribute__((aligned(4)));

static inline yc_u32 rd32(const char *p)
{
    return *(const yc_u32 *)p;
}
static inline yc_u64 rd64(const char *p)
{
    return *(const yc_u64_a4 *)p;
}

/* mach_port_extract_right (MIG only; a generated stub until the kernel
 * serves it). */
int mach_port_extract_right(yc_port_t task, yc_port_t name, yc_u32 msgt_name, yc_port_t *poly, yc_u32 *poly_poly);

/* Releases one right carried with disposition `disp` (section 4.4). */
static void destroy_right(yc_port_t name, yc_u32 disp)
{
    yc_port_t task = mach_task_self_;
    if (name == YC_MACH_PORT_NULL || name == YC_MACH_PORT_DEAD)
        return;
    switch (disp) {
    case YC_MACH_MSG_TYPE_MOVE_SEND:
    case YC_MACH_MSG_TYPE_MOVE_SEND_ONCE:
        (void)mach_port_deallocate(task, name);
        break;
    case YC_MACH_MSG_TYPE_MOVE_RECEIVE:
        (void)mach_port_mod_refs(task, name, YC_MACH_PORT_RIGHT_RECEIVE, -1);
        break;
    case YC_MACH_MSG_TYPE_MAKE_SEND:
        if (mach_port_insert_right(task, name, name, YC_MACH_MSG_TYPE_MAKE_SEND) == YC_KERN_SUCCESS)
            (void)mach_port_deallocate(task, name);
        break;
    case YC_MACH_MSG_TYPE_MAKE_SEND_ONCE: {
        yc_port_t so = YC_MACH_PORT_NULL;
        yc_u32 so_type = 0;
        if (mach_port_extract_right(task, name, YC_MACH_MSG_TYPE_MAKE_SEND_ONCE, &so, &so_type) == YC_KERN_SUCCESS)
            (void)mach_port_deallocate(task, so);
        break;
    }
    default:
        /* COPY_SEND and anything else: the message holds no right. */
        break;
    }
}

/* void mach_msg_destroy(mach_msg_header_t *msg): releases the rights and
 * memory recorded in a received (or pseudo-received) message
 * (mach-ipc.md section 4.4). msgh_local_port is not touched. The
 * descriptor walk stops at msgh_size or at an unknown descriptor type. */
YC_EXPORT void mach_msg_destroy(struct yc_mach_msg_header *msg)
{
    yc_port_t task = mach_task_self_;
    yc_u32 bits = msg->msgh_bits;
    destroy_right(msg->msgh_remote_port, bits & 0x1Fu);
    destroy_right(msg->msgh_voucher_port, (bits >> 16) & 0x1Fu);
    if (!(bits & YC_MACH_MSGH_BITS_COMPLEX) || msg->msgh_size < YC_BASE_SIZE)
        return;

    const char *base = (const char *)msg;
    const char *end = base + msg->msgh_size;
    const char *d = base + YC_BASE_SIZE;
    yc_u32 count = rd32(base + YC_HEADER_SIZE);
    for (yc_u32 i = 0; i < count; i++) {
        if (d + 12 > end)
            return;
        yc_u8 type = (yc_u8)d[11];
        yc_u32 disp = (yc_u8)d[10];
        if (type == YC_DESC_PORT) {
            destroy_right(rd32(d), disp);
            d += 12;
            continue;
        }
        if (d + 16 > end)
            return;
        switch (type) {
        case YC_DESC_OOL: {
            yc_u64 addr = rd64(d);
            yc_u32 size = rd32(d + 12);
            if (d[8] && size != 0)
                (void)vm_deallocate(task, (yc_uintptr_t)addr, size);
            break;
        }
        case YC_DESC_OOL_VOLATILE:
            break;
        case YC_DESC_OOL_PORTS: {
            yc_u64 addr = rd64(d);
            yc_u32 n = rd32(d + 12);
            const yc_port_t *names = (const yc_port_t *)(yc_uintptr_t)addr;
            if (names != YC_NULL)
                for (yc_u32 k = 0; k < n; k++)
                    destroy_right(names[k], disp);
            if (d[8] && addr != 0 && n != 0)
                (void)vm_deallocate(task, (yc_uintptr_t)addr, (yc_uintptr_t)n * 4u);
            break;
        }
        case YC_DESC_GUARDED_PORT: {
            yc_u64 context = rd64(d);
            yc_u32 flags = *(const yc_u16 *)(d + 8);
            yc_port_t name = rd32(d + 12);
            if (!(flags & YC_GUARD_UNGUARDED_ON_SEND) && name != YC_MACH_PORT_NULL && name != YC_MACH_PORT_DEAD)
                (void)mach_port_unguard(task, name, context);
            destroy_right(name, disp);
            break;
        }
        default:
            return;
        }
        d += 16;
    }
}

/* ------------------------------------------------------- MIG servers */

#define YC_MACH_RCV_LARGE 0x00000004u
#define YC_MACH_SEND_TIMEOUT 0x00000010u
#define YC_MACH_RCV_TIMEOUT 0x00000100u
#define YC_MACH_RCV_TOO_LARGE 0x10004004
#define YC_MACH_SEND_TIMED_OUT 0x10000004
#define YC_MACH_MSG_SUCCESS 0
#define YC_MIG_NO_REPLY (-305)
#define YC_MAX_TRAILER 68u /* mach_msg_max_trailer_t (mach-ipc.md section 2.6) */
#define YC_SERVER_STACK_BUFFER 8192u
/* The receive-side bits of a server's options: RCV_LARGE, LARGE_IDENTITY,
 * RCV_TIMEOUT, RCV_INTERRUPT, RCV_VOUCHER and the trailer request (bits
 * 24-31). The send-side bits: SEND_TIMEOUT, SEND_INTERRUPT, the send
 * notification bit and SEND_NOIMPORTANCE. */
#define YC_SERVER_RCV_BITS 0xFF000D0Cu
#define YC_SERVER_SEND_BITS 0x000400F0u

int mach_vm_allocate(yc_port_t task, yc_u64 *address, yc_u64 size, int flags);

/* mig_reply_error_t (mach-ipc.md section 5.2): header, NDR, RetCode. */
struct yc_mig_reply_error {
    struct yc_mach_msg_header head;
    yc_u8 ndr[8];
    int ret_code;
} __attribute__((packed, aligned(4)));

typedef int (*yc_mig_demux_t)(struct yc_mach_msg_header *request, struct yc_mach_msg_header *reply);

/* A buffer for one message: on the caller's stack when it fits, else
 * fresh pages. */
struct yc_server_buffer {
    struct yc_mach_msg_header *msg;
    yc_u64 size;
    int allocated;
};

static int server_buffer_get(struct yc_server_buffer *b, void *stack, yc_u64 size)
{
    if (size <= YC_SERVER_STACK_BUFFER) {
        b->msg = (struct yc_mach_msg_header *)stack;
        b->size = YC_SERVER_STACK_BUFFER;
        b->allocated = 0;
        return YC_MACH_MSG_SUCCESS;
    }
    yc_u64 address = 0;
    int kr = mach_vm_allocate(mach_task_self_, &address, size, 1 /* VM_FLAGS_ANYWHERE */);
    if (kr != 0)
        return kr;
    b->msg = (struct yc_mach_msg_header *)(yc_uintptr_t)address;
    b->size = size;
    b->allocated = 1;
    return YC_MACH_MSG_SUCCESS;
}

static void server_buffer_put(struct yc_server_buffer *b)
{
    if (b->allocated)
        (void)vm_deallocate(mach_task_self_, (yc_uintptr_t)b->msg, (yc_uintptr_t)b->size);
    b->allocated = 0;
}

/* Receives one request on rcv_name, lets demux build the reply, and sends
 * it (the MIG server conventions of mach-ipc.md section 5.1):
 *  - the receive takes the caller's receive-side options (a RCV_TIMEOUT
 *    receive polls); with RCV_LARGE, a request larger than max_size is
 *    received into a buffer of its own size;
 *  - a simple reply whose RetCode is MIG_NO_REPLY is not sent and the
 *    request is left to the server; any other non-zero RetCode destroys the
 *    request's rights and memory (its reply right goes with the reply);
 *  - a reply with no destination is destroyed; one to a send right (not
 *    send-once) is sent with SEND_TIMEOUT 0; a reply the send leaves intact
 *    (INVALID_DEST, TIMED_OUT, INTERRUPTED) is destroyed.
 * Returns the receive error, else the reply's send result. */
static int server_once(yc_mig_demux_t demux, yc_u32 max_size, yc_port_t rcv_name, yc_u32 options,
                       void *request_stack, void *reply_stack)
{
    struct yc_server_buffer request, reply;
    yc_u32 rcv_options = (yc_u32)YC_MACH_RCV_MSG | (options & YC_SERVER_RCV_BITS);
    yc_u64 want = (yc_u64)max_size + YC_MAX_TRAILER;
    int mr = server_buffer_get(&request, request_stack, want);
    if (mr != YC_MACH_MSG_SUCCESS)
        return mr;
    for (;;) {
        mr = mach_msg(request.msg, rcv_options, 0, (yc_u32)request.size, rcv_name, 0, 0);
        if (mr != YC_MACH_RCV_TOO_LARGE || !(options & YC_MACH_RCV_LARGE))
            break;
        /* The request stays queued; its size is in msgh_size. */
        want = (yc_u64)request.msg->msgh_size + YC_MAX_TRAILER;
        server_buffer_put(&request);
        mr = server_buffer_get(&request, request_stack, want);
        if (mr != YC_MACH_MSG_SUCCESS)
            return mr;
    }
    if (mr != YC_MACH_MSG_SUCCESS) {
        server_buffer_put(&request);
        return mr;
    }
    mr = server_buffer_get(&reply, reply_stack, (yc_u64)max_size + YC_MAX_TRAILER);
    if (mr != YC_MACH_MSG_SUCCESS) {
        mach_msg_destroy(request.msg);
        server_buffer_put(&request);
        return mr;
    }
    /* A received voucher is not adopted: its right is released. */
    if (request.msg->msgh_voucher_port != YC_MACH_PORT_NULL) {
        (void)mach_port_deallocate(mach_task_self_, request.msg->msgh_voucher_port);
        request.msg->msgh_voucher_port = YC_MACH_PORT_NULL;
        request.msg->msgh_bits &= ~(0x1Fu << 16);
    }
    (void)demux(request.msg, reply.msg);
    struct yc_mig_reply_error *error = (struct yc_mig_reply_error *)reply.msg;
    if (!(reply.msg->msgh_bits & YC_MACH_MSGH_BITS_COMPLEX)) {
        if (error->ret_code == YC_MIG_NO_REPLY) {
            /* The server keeps the request (and answers later). */
            server_buffer_put(&reply);
            server_buffer_put(&request);
            return YC_MACH_MSG_SUCCESS;
        }
        if (error->ret_code != 0) {
            request.msg->msgh_remote_port = YC_MACH_PORT_NULL;
            mach_msg_destroy(request.msg);
        }
    }
    if (reply.msg->msgh_remote_port == YC_MACH_PORT_NULL) {
        if (reply.msg->msgh_bits & YC_MACH_MSGH_BITS_COMPLEX)
            mach_msg_destroy(reply.msg);
        mr = YC_MACH_MSG_SUCCESS;
    } else {
        yc_u32 send_options = (yc_u32)YC_MACH_SEND_MSG | (options & YC_SERVER_SEND_BITS);
        if ((reply.msg->msgh_bits & 0x1Fu) != YC_MACH_MSG_TYPE_MOVE_SEND_ONCE)
            send_options |= YC_MACH_SEND_TIMEOUT;
        else
            send_options &= ~YC_MACH_SEND_TIMEOUT;
        mr = mach_msg(reply.msg, send_options, reply.msg->msgh_size, 0, YC_MACH_PORT_NULL, 0, 0);
        if (mr == YC_MACH_SEND_INVALID_DEST || mr == YC_MACH_SEND_TIMED_OUT || mr == YC_MACH_SEND_INTERRUPTED)
            mach_msg_destroy(reply.msg);
    }
    server_buffer_put(&reply);
    server_buffer_put(&request);
    return mr;
}

/* mach_msg_return_t mach_msg_server_once(boolean_t (*demux)(mach_msg_header_t *,
 *     mach_msg_header_t *), mach_msg_size_t max_size, mach_port_t rcv_name,
 *     mach_msg_options_t options): one request and its reply. */
YC_EXPORT int mach_msg_server_once(yc_mig_demux_t demux, yc_u32 max_size, yc_port_t rcv_name, yc_u32 options)
{
    yc_u64 request_stack[YC_SERVER_STACK_BUFFER / 8], reply_stack[YC_SERVER_STACK_BUFFER / 8];
    return server_once(demux, max_size, rcv_name, options, request_stack, reply_stack);
}

/* mach_msg_return_t mach_msg_server(demux, max_size, rcv_name, options):
 * serves requests until a receive fails, and returns that error. A reply
 * that cannot be sent does not stop the loop. */
YC_EXPORT int mach_msg_server(yc_mig_demux_t demux, yc_u32 max_size, yc_port_t rcv_name, yc_u32 options)
{
    yc_u64 request_stack[YC_SERVER_STACK_BUFFER / 8], reply_stack[YC_SERVER_STACK_BUFFER / 8];
    for (;;) {
        int mr = server_once(demux, max_size, rcv_name, options, request_stack, reply_stack);
        yc_u32 code = (yc_u32)mr;
        if ((code & 0xFFFFC000u) == 0x10004000u)
            return mr; /* a receive error (MACH_RCV_*) */
        if (mr != YC_MACH_MSG_SUCCESS && (code & 0xFFFFC000u) != 0x10000000u)
            return mr; /* not a send error: an allocation failure */
    }
}

/* ------------------------------------------------------ message priority */

#define YC_MSG_PRIORITY_RELPRI_SHIFT 8
#define YC_MSG_PRIORITY_RELPRI_MASK (0xFFu << YC_MSG_PRIORITY_RELPRI_SHIFT)
#define YC_MSG_PRIORITY_QOS_SHIFT 16
#define YC_MSG_PRIORITY_QOS_MASK (0xFu << YC_MSG_PRIORITY_QOS_SHIFT)
#define YC_MSG_PRIORITY_OVERRIDE_SHIFT 20
#define YC_MSG_PRIORITY_OVERRIDE_MASK (0xFu << YC_MSG_PRIORITY_OVERRIDE_SHIFT)

/* mach_msg_priority_t mach_msg_priority_encode(mach_msg_qos_t override_qos,
 *     mach_msg_qos_t qos, int relpri): the QoS and relative priority are
 * encoded only for a QoS class in 1...15; the override QoS likewise. */
YC_EXPORT yc_u32 mach_msg_priority_encode(yc_u32 override_qos, yc_u32 qos, int relpri)
{
    yc_u32 pri = 0;
    if (qos > 0 && qos <= 0xFu) {
        pri |= (qos << YC_MSG_PRIORITY_QOS_SHIFT) & YC_MSG_PRIORITY_QOS_MASK;
        pri |= ((yc_u32)(yc_u8)relpri << YC_MSG_PRIORITY_RELPRI_SHIFT) & YC_MSG_PRIORITY_RELPRI_MASK;
    }
    if (override_qos > 0 && override_qos <= 0xFu)
        pri |= (override_qos << YC_MSG_PRIORITY_OVERRIDE_SHIFT) & YC_MSG_PRIORITY_OVERRIDE_MASK;
    return pri;
}
