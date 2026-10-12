// enttrace: interposer (our own code) that logs the code-signing and file calls a
// process makes while the simulator's Security framework reads entitlements.
// Used with `ylaunch entcheck`, which asks SecTask for an entitlement of itself by
// audit token (the same kind of lookup a daemon does for a peer).
// Output lines: "YCODE-ENT <call> <args> -> <result>".
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sys/types.h>
#include <mach/mach.h>
#include <bsm/audit.h>

extern int csops(pid_t pid, unsigned int ops, void *addr, size_t size);
extern int csops_audittoken(pid_t pid, unsigned int ops, void *addr, size_t size, audit_token_t *tok);
extern int proc_pidpath(int pid, void *buf, uint32_t size);

#define INTERPOSE(repl, orig) \
    __attribute__((used)) static struct { const void *r; const void *o; } \
    _interpose_##orig __attribute__((section("__DATA,__interpose"))) = { (const void *)repl, (const void *)orig };

static void say(const char *fmt, ...) {
    char buf[600]; va_list ap; va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    if (n > 0) write(2, buf, (size_t)n < sizeof buf ? (size_t)n : sizeof buf - 1);
}

static int my_csops(pid_t pid, unsigned int ops, void *addr, size_t size) {
    int r = csops(pid, ops, addr, size);
    say("YCODE-ENT csops pid=%d ops=%u size=%zu -> %d\n", pid, ops, size, r);
    return r;
}
INTERPOSE(my_csops, csops)

static int my_csops_at(pid_t pid, unsigned int ops, void *addr, size_t size, audit_token_t *tok) {
    int r = csops_audittoken(pid, ops, addr, size, tok);
    say("YCODE-ENT csops_audittoken pid=%d ops=%u size=%zu -> %d\n", pid, ops, size, r);
    return r;
}
INTERPOSE(my_csops_at, csops_audittoken)

static int my_pidpath(int pid, void *buf, uint32_t size) {
    int r = proc_pidpath(pid, buf, size);
    say("YCODE-ENT proc_pidpath pid=%d -> %d %s\n", pid, r, r > 0 ? (char *)buf : "");
    return r;
}
INTERPOSE(my_pidpath, proc_pidpath)

static int my_open(const char *path, int flags, ...) {
    va_list ap; va_start(ap, flags); int mode = va_arg(ap, int); va_end(ap);
    int r = open(path, flags, mode);
    say("YCODE-ENT open %s -> %d\n", path, r);
    return r;
}
INTERPOSE(my_open, open)
