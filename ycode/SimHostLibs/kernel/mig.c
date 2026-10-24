/*
 * mig.c - Mach routines of libsystem_kernel that are MIG RPCs with no trap:
 * mach_port_get_refs, mach_port_set_mscount, mach_port_set_attributes and
 * mach_port_extract_right (to the task port), and host_get_special_port.
 *
 * Clean-room Ycode code. Facts used:
 *  - mach-ipc.md section 5 (MIG wire conventions: request/reply IDs, the
 *    request header, NDR_record, mig_reply_error_t, the client's reply
 *    checks and reply-port handling) and section 1.7 (the mach_port
 *    routine table, the attribute flavors, MIG subsystem mach_port = 3200,
 *    set_attributes = 3218). Ycode's VMM serves the mach_port subsystem on
 *    task ports (MachIPCKernelServer), so no private routine is needed.
 *  - Apple's open-source xnu (osfmk/kern/host.c, host_get_special_port and
 *    host_get_special_port_from_user; osfmk/mach/host_special_ports.h):
 *    the routine needs the host-privileged port and answers
 *    KERN_INVALID_ARGUMENT for the plain host port that an unprivileged
 *    task's mach_host_self() returns, and for an id outside
 *    HOST_MIN_SPECIAL_PORT (0, itself refused) .. HOST_MAX_SPECIAL_PORT.
 *    Ycode's guest processes never hold the privileged host port.
 */
#include "yc_kernel.h"

struct yc_mig_header {
    yc_u32 bits;
    yc_u32 size;
    yc_port_t remote;
    yc_port_t local;
    yc_port_t voucher;
    int id;
};
_Static_assert(sizeof(struct yc_mig_header) == 24, "mach_msg_header_t is 24 bytes");

int mach_msg(void *msg, yc_u32 option, yc_u32 send_size, yc_u32 rcv_size, yc_port_t rcv_name, yc_u32 timeout,
             yc_u32 notify);
yc_port_t mig_get_reply_port(void);
void mig_dealloc_reply_port(yc_port_t reply_port);
void mach_msg_destroy(void *msg);

#define YC_MACH_SEND_MSG 0x00000001u
#define YC_MACH_RCV_MSG 0x00000002u
#define YC_MACH_MSGH_BITS_COMPLEX 0x80000000u
#define YC_MACH_SEND_INVALID_DATA 0x10000002
#define YC_MACH_SEND_INVALID_HEADER 0x10000010
#define YC_MACH_NOTIFY_SEND_ONCE 71

#define YC_MIG_TYPE_ERROR (-300)
#define YC_MIG_REPLY_MISMATCH (-301)
#define YC_MIG_ARRAY_TOO_LARGE (-307)
#define YC_MIG_SERVER_DIED (-308)

/* NDR_record_t for arm64: int_rep 1 (little-endian), everything else 0. */
static const yc_u8 yc_ndr[8] = {0, 0, 0, 0, 1, 0, 0, 0};

/* mig_reply_error_t, plus room for the largest receive trailer. */
struct yc_mig_reply {
    struct yc_mig_header h;
    yc_u8 ndr[8];
    int ret_code;
    yc_u8 trailer[68];
};

/* One simple-reply RPC: `msg` holds the request (its header is filled
 * here) and has room for `rcv_size` bytes of reply (a mig_reply_error_t
 * and a trailer). Sends `send_size` bytes to `server` with the thread's
 * MIG reply port and returns the reply's RetCode, or the mach_msg / MIG
 * client error (mach-ipc.md section 5.1). */
static int mig_simple_rpc(void *msg, yc_u32 send_size, yc_u32 rcv_size, yc_port_t server, int id)
{
    struct yc_mig_header *h = msg;
    yc_port_t reply_port = mig_get_reply_port();
    h->bits = YC_MACH_MSG_TYPE_COPY_SEND | (YC_MACH_MSG_TYPE_MAKE_SEND_ONCE << 8);
    h->size = send_size;
    h->remote = server;
    h->local = reply_port;
    h->voucher = YC_MACH_PORT_NULL;
    h->id = id;
    int kr = mach_msg(h, YC_MACH_SEND_MSG | YC_MACH_RCV_MSG, send_size, rcv_size, reply_port, 0,
                      YC_MACH_PORT_NULL);
    if (kr != YC_KERN_SUCCESS) {
        if (kr != YC_MACH_SEND_INVALID_DATA && kr != YC_MACH_SEND_INVALID_DEST && kr != YC_MACH_SEND_INVALID_HEADER)
            mig_dealloc_reply_port(reply_port);
        return kr;
    }
    const struct yc_mig_reply *r = msg;
    if (r->h.id != id + 100) {
        int err = (r->h.id == YC_MACH_NOTIFY_SEND_ONCE) ? YC_MIG_SERVER_DIED : YC_MIG_REPLY_MISMATCH;
        mach_msg_destroy(msg);
        return err;
    }
    if ((r->h.bits & YC_MACH_MSGH_BITS_COMPLEX) || r->h.size != 36) {
        mach_msg_destroy(msg);
        return YC_MIG_TYPE_ERROR;
    }
    return r->ret_code;
}

/* One RPC whose success reply carries one 32-bit out argument after the
 * RetCode (40 bytes); a failure is a mig_reply_error_t (36 bytes) with a
 * non-zero RetCode (mach-ipc.md section 5.1). */
static int mig_out32_rpc(void *msg, yc_u32 send_size, yc_u32 rcv_size, yc_port_t server, int id, yc_u32 *out)
{
    struct yc_mig_header *h = msg;
    yc_port_t reply_port = mig_get_reply_port();
    h->bits = YC_MACH_MSG_TYPE_COPY_SEND | (YC_MACH_MSG_TYPE_MAKE_SEND_ONCE << 8);
    h->size = send_size;
    h->remote = server;
    h->local = reply_port;
    h->voucher = YC_MACH_PORT_NULL;
    h->id = id;
    int kr = mach_msg(h, YC_MACH_SEND_MSG | YC_MACH_RCV_MSG, send_size, rcv_size, reply_port, 0,
                      YC_MACH_PORT_NULL);
    if (kr != YC_KERN_SUCCESS) {
        if (kr != YC_MACH_SEND_INVALID_DATA && kr != YC_MACH_SEND_INVALID_DEST && kr != YC_MACH_SEND_INVALID_HEADER)
            mig_dealloc_reply_port(reply_port);
        return kr;
    }
    const struct yc_mig_reply *r = msg;
    if (r->h.id != id + 100) {
        int err = (r->h.id == YC_MACH_NOTIFY_SEND_ONCE) ? YC_MIG_SERVER_DIED : YC_MIG_REPLY_MISMATCH;
        mach_msg_destroy(msg);
        return err;
    }
    if (r->h.bits & YC_MACH_MSGH_BITS_COMPLEX) {
        mach_msg_destroy(msg);
        return YC_MIG_TYPE_ERROR;
    }
    if (r->h.size == 36 && r->ret_code != YC_KERN_SUCCESS)
        return r->ret_code;
    if (r->h.size != 40 || r->ret_code != YC_KERN_SUCCESS)
        return YC_MIG_TYPE_ERROR;
    const yc_u8 *b = (const yc_u8 *)msg + 36;
    *out = (yc_u32)b[0] | ((yc_u32)b[1] << 8) | ((yc_u32)b[2] << 16) | ((yc_u32)b[3] << 24);
    return YC_KERN_SUCCESS;
}

/* kern_return_t mach_port_get_refs(ipc_space_t task, mach_port_name_t name,
 *     mach_port_right_t right, mach_port_urefs_t *refs)
 * MIG 3207 on the task port (xnu osfmk/mach/mach_port.defs; level 1):
 * request NDR, name, right (40 bytes); reply RetCode and refs (40 bytes).
 * The VMM's task-port server answers it (MachIPCKernelServer). WebKit's
 * JavaScriptCore checks a send right's count with it at start and stops
 * the process when the call fails (app-launch.md section 3.1). */
#define YC_MACH_PORT_GET_REFS_ID 3207

YC_EXPORT int mach_port_get_refs(yc_port_t task, yc_port_t name, yc_u32 right, yc_u32 *refs)
{
    union {
        struct {
            struct yc_mig_header h;
            yc_u8 ndr[8];
            yc_port_t name;
            yc_u32 right;
        } req;
        struct yc_mig_reply reply;
    } m;
    for (int i = 0; i < 8; i++)
        m.req.ndr[i] = yc_ndr[i];
    m.req.name = name;
    m.req.right = right;
    yc_u32 value = 0;
    int kr = mig_out32_rpc(&m, 40, (yc_u32)sizeof m, task, YC_MACH_PORT_GET_REFS_ID, &value);
    if (kr == YC_KERN_SUCCESS)
        *refs = value;
    return kr;
}

/* The MIG-routine name of the same call. */
YC_EXPORT int _kernelrpc_mach_port_get_refs(yc_port_t task, yc_port_t name, yc_u32 right, yc_u32 *refs)
{
    return mach_port_get_refs(task, name, right, refs);
}

/* kern_return_t mach_port_set_mscount(ipc_space_t task, mach_port_name_t name,
 *     mach_port_mscount_t mscount)
 * MIG 3210 on the task port: request NDR, name, mscount (40 bytes); a
 * simple reply. Served by the VMM's task-port server. */
#define YC_MACH_PORT_SET_MSCOUNT_ID 3210

YC_EXPORT int mach_port_set_mscount(yc_port_t task, yc_port_t name, yc_u32 mscount)
{
    union {
        struct {
            struct yc_mig_header h;
            yc_u8 ndr[8];
            yc_port_t name;
            yc_u32 mscount;
        } req;
        struct yc_mig_reply reply;
    } m;
    for (int i = 0; i < 8; i++)
        m.req.ndr[i] = yc_ndr[i];
    m.req.name = name;
    m.req.mscount = mscount;
    return mig_simple_rpc(&m, 40, (yc_u32)sizeof m, task, YC_MACH_PORT_SET_MSCOUNT_ID);
}

/* The MIG-routine name of the same call. */
YC_EXPORT int _kernelrpc_mach_port_set_mscount(yc_port_t task, yc_port_t name, yc_u32 mscount)
{
    return mach_port_set_mscount(task, name, mscount);
}

/* kern_return_t mach_port_set_attributes(ipc_space_t task,
 *     mach_port_name_t name, mach_port_flavor_t flavor,
 *     mach_port_info_t port_info, mach_msg_type_number_t port_infoCnt)
 * MIG 3218 on the task port: NDR, name, flavor, count, then `count`
 * 32-bit words (at most 17). The kernel answers per mach-ipc.md 1.7
 * (LIMITS_INFO sets the queue limit; DNREQUESTS_SIZE, TEMPOWNER,
 * IMPORTANCE_RECEIVER and DENAP_RECEIVER are accepted for a receive
 * right; anything else fails). */
#define YC_MACH_PORT_SET_ATTRIBUTES_ID 3218
#define YC_MACH_PORT_INFO_MAX 17u

YC_EXPORT int mach_port_set_attributes(yc_port_t task, yc_port_t name, int flavor, const int *info, yc_u32 count)
{
    union {
        struct {
            struct yc_mig_header h;
            yc_u8 ndr[8];
            yc_port_t name;
            int flavor;
            yc_u32 count;
            int info[YC_MACH_PORT_INFO_MAX];
        } req;
        struct yc_mig_reply reply;
    } m;
    _Static_assert(__builtin_offsetof(__typeof__(m.req), info) == 44, "info at 44");
    if (count > YC_MACH_PORT_INFO_MAX)
        return YC_MIG_ARRAY_TOO_LARGE;
    for (int i = 0; i < 8; i++)
        m.req.ndr[i] = yc_ndr[i];
    m.req.name = name;
    m.req.flavor = flavor;
    m.req.count = count;
    for (yc_u32 i = 0; i < count; i++)
        m.req.info[i] = info[i];
    return mig_simple_rpc(&m, 44 + 4 * count, (yc_u32)sizeof m, task, YC_MACH_PORT_SET_ATTRIBUTES_ID);
}

/* The MIG-routine name of the same call. */
YC_EXPORT int _kernelrpc_mach_port_set_attributes(yc_port_t task, yc_port_t name, int flavor, const int *info,
                                                  yc_u32 count)
{
    return mach_port_set_attributes(task, name, flavor, info, count);
}

/* kern_return_t host_get_special_port(host_priv_t host_priv, int node,
 *     int which, mach_port_t *port)
 * Guest processes hold only the plain host port, which xnu does not accept
 * as host_priv_t: the result is KERN_INVALID_ARGUMENT and *port is not
 * written. (libdispatch's host_get_host_port() probe, which is this
 * routine with HOST_PORT, uses that result to learn that mach_host_self()
 * is the unprivileged host port.) */
YC_EXPORT int host_get_special_port(yc_port_t host_priv, int node, int which, yc_port_t *port)
{
    (void)host_priv;
    (void)node;
    (void)which;
    (void)port;
    return YC_KERN_INVALID_ARGUMENT;
}

/* kern_return_t host_set_atm_diagnostic_flag(host_t host, uint32_t diagnostic_flag)
 * xnu (osfmk/kern/host.c): KERN_INVALID_ARGUMENT for a null host, else
 * KERN_NO_ACCESS without the private entitlement, which no simulator
 * process has (logd calls it at start and continues). */
YC_EXPORT int host_set_atm_diagnostic_flag(yc_port_t host, yc_u32 diagnostic_flag)
{
    (void)diagnostic_flag;
    return host == 0 ? YC_KERN_INVALID_ARGUMENT : 8 /* KERN_NO_ACCESS */;
}

/* kern_return_t host_request_notification(host_t host, host_flavor_t notify_type,
 *     mach_port_t notify_port)
 * xnu (osfmk/kern/host_notify.c): KERN_INVALID_ARGUMENT for a null host or a
 * type above HOST_NOTIFY_TYPE_MAX (1: CALENDAR_CHANGE 0, CALENDAR_SET 1),
 * KERN_INVALID_CAPABILITY for a null or dead port. Ycode's calendar is
 * never set, so a registration is accepted and never fires (libdispatch
 * registers its notify port at start). */
YC_EXPORT int host_request_notification(yc_port_t host, int notify_type, yc_port_t notify_port)
{
    if (host == 0 || notify_type < 0 || notify_type > 1)
        return YC_KERN_INVALID_ARGUMENT;
    if (notify_port == 0 || notify_port == 0xFFFFFFFFu)
        return 20; /* KERN_INVALID_CAPABILITY */
    return 0;
}

/* kern_return_t mach_port_extract_right(ipc_space_t task,
 *     mach_port_name_t name, mach_msg_type_name_t msgt_name,
 *     mach_port_poly_t *poly, mach_msg_type_name_t *polyPoly)
 * MIG 3215 on the task port (xnu osfmk/mach/mach_port.defs; level 1):
 * request NDR, name, msgt_name (40 bytes). Success is a complex reply with
 * one port descriptor (40 bytes): the right, received into the caller's
 * space, and its received type (PORT_RECEIVE, PORT_SEND, PORT_SEND_ONCE).
 * Failure is a mig_reply_error_t (36 bytes). The VMM's task-port server
 * (MachIPCKernelServer) copies the right in from the target task's space. */
#define YC_MACH_PORT_EXTRACT_RIGHT_ID 3215

YC_EXPORT int mach_port_extract_right(yc_port_t task, yc_port_t name, yc_u32 msgt_name, yc_port_t *poly,
                                      yc_u32 *poly_poly)
{
    union {
        struct {
            struct yc_mig_header h;
            yc_u8 ndr[8];
            yc_port_t name;
            yc_u32 msgt_name;
        } req;
        struct {
            struct yc_mig_header h;
            yc_u32 count;
            yc_port_t port;
            yc_u32 pad1;
            yc_u16 pad2;
            yc_u8 disposition;
            yc_u8 type;
            yc_u8 trailer[68];
        } ok;
        struct yc_mig_reply err;
    } m;
    _Static_assert(__builtin_offsetof(__typeof__(m.ok), trailer) == 40, "port reply is 40 bytes");
    for (int i = 0; i < 8; i++)
        m.req.ndr[i] = yc_ndr[i];
    m.req.name = name;
    m.req.msgt_name = msgt_name;
    struct yc_mig_header *h = &m.req.h;
    yc_port_t reply_port = mig_get_reply_port();
    h->bits = YC_MACH_MSG_TYPE_COPY_SEND | (YC_MACH_MSG_TYPE_MAKE_SEND_ONCE << 8);
    h->size = 40;
    h->remote = task;
    h->local = reply_port;
    h->voucher = YC_MACH_PORT_NULL;
    h->id = YC_MACH_PORT_EXTRACT_RIGHT_ID;
    int kr = mach_msg(h, YC_MACH_SEND_MSG | YC_MACH_RCV_MSG, 40, (yc_u32)sizeof m, reply_port, 0, YC_MACH_PORT_NULL);
    if (kr != YC_KERN_SUCCESS) {
        if (kr != YC_MACH_SEND_INVALID_DATA && kr != YC_MACH_SEND_INVALID_DEST && kr != YC_MACH_SEND_INVALID_HEADER)
            mig_dealloc_reply_port(reply_port);
        return kr;
    }
    if (m.ok.h.id != YC_MACH_PORT_EXTRACT_RIGHT_ID + 100) {
        int err = (m.ok.h.id == YC_MACH_NOTIFY_SEND_ONCE) ? YC_MIG_SERVER_DIED : YC_MIG_REPLY_MISMATCH;
        mach_msg_destroy(&m);
        return err;
    }
    if (!(m.ok.h.bits & YC_MACH_MSGH_BITS_COMPLEX)) {
        if (m.err.h.size == 36 && m.err.ret_code != YC_KERN_SUCCESS)
            return m.err.ret_code;
        mach_msg_destroy(&m);
        return YC_MIG_TYPE_ERROR;
    }
    if (m.ok.h.size != 40 || m.ok.count != 1 || m.ok.type != 0) {
        mach_msg_destroy(&m);
        return YC_MIG_TYPE_ERROR;
    }
    *poly = m.ok.port;
    *poly_poly = m.ok.disposition;
    return YC_KERN_SUCCESS;
}

/* The MIG-routine name of the same call. */
YC_EXPORT int _kernelrpc_mach_port_extract_right(yc_port_t task, yc_port_t name, yc_u32 msgt_name, yc_port_t *poly,
                                                 yc_u32 *poly_poly)
{
    return mach_port_extract_right(task, name, msgt_name, poly, poly_poly);
}
