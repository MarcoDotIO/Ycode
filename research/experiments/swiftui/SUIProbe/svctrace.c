/*
 * svctrace: Ycode research tool (original Ycode code, no Apple code).
 * Inserted into our own probe app only (SIMCTL_CHILD_DYLD_INSERT_LIBRARIES).
 * It records, by name, the system services our process asks for: Mach
 * services looked up through the bootstrap server or opened as XPC
 * connections, named XPC services, remote CFMessagePorts, and Darwin
 * notification names registered or posted. One stderr line per call:
 *   SUPX <seconds since load> <kind> <name>
 * Declarations below are our own prototypes for exported C functions whose
 * names and roles are public (bootstrap.h, xpc/connection.h, notify.h,
 * CFMessagePort.h).
 */
#include <stdio.h>
#include <stdint.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>

typedef void *xpc_connection_t;
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
extern kern_return_t bootstrap_look_up2(mach_port_t bp, const char *name, mach_port_t *sp, pid_t pid, uint64_t flags);
extern xpc_connection_t xpc_connection_create_mach_service(const char *name, dispatch_queue_t q, uint64_t flags);
extern xpc_connection_t xpc_connection_create(const char *name, dispatch_queue_t q);
extern uint32_t notify_register_dispatch(const char *name, int *token, dispatch_queue_t q, void (^handler)(int));
extern uint32_t notify_register_check(const char *name, int *token);
extern uint32_t notify_register_mach_port(const char *name, mach_port_t *port, int flags, int *token);
extern uint32_t notify_register_file_descriptor(const char *name, int *fd, int flags, int *token);
extern uint32_t notify_post(const char *name);

#define INTERPOSE(rep, orig) \
    __attribute__((used)) static struct { const void *r; const void *o; } _interpose_##orig \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(rep), (const void *)(orig) };

static uint64_t t0;
static mach_timebase_info_data_t tb;
__attribute__((constructor)) static void init(void) { t0 = mach_absolute_time(); mach_timebase_info(&tb); }
static double secs(void) { return (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e9; }
static void rec(const char *kind, const char *name) { fprintf(stderr, "SUPX %.3f %s %s\n", secs(), kind, name ? name : "(null)"); }

static kern_return_t my_bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp)
{ kern_return_t r = bootstrap_look_up(bp, name, sp); char b[300]; snprintf(b, sizeof b, "%s kr=%d", name, r); rec("lookup", b); return r; }
INTERPOSE(my_bootstrap_look_up, bootstrap_look_up)

static kern_return_t my_bootstrap_look_up2(mach_port_t bp, const char *name, mach_port_t *sp, pid_t pid, uint64_t flags)
{ kern_return_t r = bootstrap_look_up2(bp, name, sp, pid, flags); char b[300]; snprintf(b, sizeof b, "%s kr=%d", name, r); rec("lookup2", b); return r; }
INTERPOSE(my_bootstrap_look_up2, bootstrap_look_up2)

static xpc_connection_t my_xpc_mach(const char *name, dispatch_queue_t q, uint64_t flags)
{ rec("xpc-mach", name); return xpc_connection_create_mach_service(name, q, flags); }
INTERPOSE(my_xpc_mach, xpc_connection_create_mach_service)

static xpc_connection_t my_xpc(const char *name, dispatch_queue_t q)
{ if (name) rec("xpc-service", name); return xpc_connection_create(name, q); }
INTERPOSE(my_xpc, xpc_connection_create)

static CFMessagePortRef my_cfmp(CFAllocatorRef a, CFStringRef name)
{
    char b[300] = "(null)";
    if (name) CFStringGetCString(name, b, sizeof b, kCFStringEncodingUTF8);
    rec("cfmessageport", b);
    return CFMessagePortCreateRemote(a, name);
}
INTERPOSE(my_cfmp, CFMessagePortCreateRemote)

static uint32_t my_nrd(const char *name, int *token, dispatch_queue_t q, void (^h)(int))
{ rec("notify-register", name); return notify_register_dispatch(name, token, q, h); }
INTERPOSE(my_nrd, notify_register_dispatch)
static uint32_t my_nrc(const char *name, int *token)
{ rec("notify-register", name); return notify_register_check(name, token); }
INTERPOSE(my_nrc, notify_register_check)
static uint32_t my_nrm(const char *name, mach_port_t *p, int flags, int *token)
{ rec("notify-register", name); return notify_register_mach_port(name, p, flags, token); }
INTERPOSE(my_nrm, notify_register_mach_port)
static uint32_t my_nrf(const char *name, int *fd, int flags, int *token)
{ rec("notify-register", name); return notify_register_file_descriptor(name, fd, flags, token); }
INTERPOSE(my_nrf, notify_register_file_descriptor)
static uint32_t my_np(const char *name)
{ rec("notify-post", name); return notify_post(name); }
INTERPOSE(my_np, notify_post)
