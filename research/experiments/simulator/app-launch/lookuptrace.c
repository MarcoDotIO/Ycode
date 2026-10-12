// lookuptrace: a tiny interposer (our own code) that logs every Mach service
// lookup and XPC Mach-service connection a process makes, to stderr, so the
// lines interleave with the probe app's report. Loaded into the probe app with
// DYLD_INSERT_LIBRARIES passed through the launch request's environment.
//
// Output lines: "YCODE-LOOKUP <api> <name> -> <result>".
// YCODE_DENY=<name>[,<name>...] makes bootstrap_look_up of those names fail with
// 1102 (unknown service), to imitate a guest where that service does not exist.
// Only calls that cross an image boundary (through a stub) are seen.
#include <mach/mach.h>
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

// The iOS SDK has no <servers/bootstrap.h> and marks the XPC Mach-service
// constructor unavailable; these are the macOS public prototypes.
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);
extern xpc_connection_t ycode_xpc_mach(const char *name, dispatch_queue_t q, uint64_t flags)
    __asm__("_xpc_connection_create_mach_service");

#define INTERPOSE(repl, orig) \
    __attribute__((used)) static struct { const void *r; const void *o; } \
    _interpose_##orig __attribute__((section("__DATA,__interpose"))) = { (const void *)repl, (const void *)orig };

static void say(const char *api, const char *name, long rc) {
    char buf[512];
    int n = snprintf(buf, sizeof buf, "YCODE-LOOKUP %s %s -> %ld\n", api, name ? name : "(null)", rc);
    if (n > 0) write(2, buf, (size_t)n < sizeof buf ? (size_t)n : sizeof buf - 1);
}

static int denied(const char *name) {
    const char *list = getenv("YCODE_DENY");
    size_t n = name ? strlen(name) : 0;
    while (list && *list && n) {
        const char *end = strchr(list, ',');
        size_t len = end ? (size_t)(end - list) : strlen(list);
        if (len == n && !strncmp(list, name, n)) return 1;
        list = end ? end + 1 : NULL;
    }
    return 0;
}

static kern_return_t my_look_up(mach_port_t bp, const char *name, mach_port_t *sp) {
    if (denied(name)) { *sp = MACH_PORT_NULL; say("bootstrap_look_up(denied)", name, 1102); return 1102; }
    kern_return_t kr = bootstrap_look_up(bp, name, sp);
    say("bootstrap_look_up", name, kr);
    return kr;
}
INTERPOSE(my_look_up, bootstrap_look_up)

static xpc_connection_t my_xpc_mach(const char *name, dispatch_queue_t q, uint64_t flags) {
    say("xpc_connection_create_mach_service", name, (long)flags);
    return ycode_xpc_mach(name, q, flags);
}
INTERPOSE(my_xpc_mach, ycode_xpc_mach)

__attribute__((constructor)) static void hello(void) { say("loaded", "lookuptrace", 0); }
