/*
 * dlsymtrace: Ycode research interposer (original Ycode code). Inserted with
 * DYLD_INSERT_LIBRARIES into OUR OWN probe process only. Logs to stderr every
 * dlopen and dlsym call (with the calling image's file name) and every
 * bootstrap_look_up / XPC Mach-service connection, so we can see which names
 * a client library resolves from the framebuffer library it loads and which
 * Mach services are contacted.
 * Lines: "YCODE-DL <api> <arg> -> <result> [from <image>]".
 * YCODE_DL_DIR=<dir>: write to <dir>/<process>-<pid>.log instead of stderr;
 * YCODE_DL_ONLY=<name>: stay silent in every process except that one (for a
 * whole-device boot where the library is inserted into every job).
 * YCODE_DL_DENY=<name>[,<name>...]: in every process, bootstrap_look_up of
 * those names fails with 1102 (unknown service) and XPC connections to them
 * are made to a name that does not exist, imitating a host without them.
 */
#include <mach/mach.h>
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

extern const char *getprogname(void);
static FILE *g_out;
static int g_off;
__attribute__((constructor)) static void dl_init(void)
{
    const char *only = getenv("YCODE_DL_ONLY");
    if (only && strcmp(only, getprogname())) { g_off = 1; return; }
    const char *dir = getenv("YCODE_DL_DIR");
    if (dir) {
        char path[1024];
        snprintf(path, sizeof path, "%s/%s-%d.log", dir, getprogname(), getpid());
        g_out = fopen(path, "a");
        if (g_out) setvbuf(g_out, NULL, _IOLBF, 0);
    }
}
static int denied(const char *name)
{
    const char *list = getenv("YCODE_DL_DENY");
    size_t n = name ? strlen(name) : 0;
    while (list && *list && n) {
        const char *end = strchr(list, ',');
        size_t len = end ? (size_t)(end - list) : strlen(list);
        if (len == n && !strncmp(list, name, n)) return 1;
        list = end ? end + 1 : NULL;
    }
    return 0;
}
#define LOGF(...) do { if (!g_off) fprintf(g_out ? g_out : stderr, __VA_ARGS__); } while (0)

extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
extern xpc_connection_t ycode_xpc_mach(const char *name, dispatch_queue_t q, uint64_t flags)
    __asm__("_xpc_connection_create_mach_service");

#define INTERPOSE(repl, orig) \
    __attribute__((used)) static struct { const void *r; const void *o; } \
    _interpose_##orig __attribute__((section("__DATA,__interpose"))) = { (const void *)repl, (const void *)orig };

static const char *img(const void *addr)
{
    Dl_info di;
    if (!dladdr(addr, &di) || !di.dli_fname) return "?";
    const char *s = strrchr(di.dli_fname, '/');
    return s ? s + 1 : di.dli_fname;
}

static void *my_dlopen(const char *path, int mode)
{
    void *h = dlopen(path, mode);
    LOGF("YCODE-DL dlopen %s mode=0x%x -> %p [from %s]\n", path ? path : "(null)", mode, h,
            img(__builtin_return_address(0)));
    return h;
}
INTERPOSE(my_dlopen, dlopen)

static void *my_dlsym(void *h, const char *name)
{
    void *p = dlsym(h, name);
    LOGF("YCODE-DL dlsym %p %s -> %s [from %s]\n", h, name ? name : "(null)", p ? "found" : "MISSING",
            img(__builtin_return_address(0)));
    return p;
}
INTERPOSE(my_dlsym, dlsym)

static kern_return_t my_look_up(mach_port_t bp, const char *name, mach_port_t *sp)
{
    if (denied(name)) {
        if (sp) *sp = MACH_PORT_NULL;
        LOGF("YCODE-DL bootstrap_look_up %s -> 1102 (denied) [from %s]\n", name, img(__builtin_return_address(0)));
        return 1102;
    }
    kern_return_t kr = bootstrap_look_up(bp, name, sp);
    LOGF("YCODE-DL bootstrap_look_up %s -> %d port=0x%x [from %s]\n", name ? name : "(null)", kr,
            sp ? *sp : 0, img(__builtin_return_address(0)));
    return kr;
}
INTERPOSE(my_look_up, bootstrap_look_up)

static xpc_connection_t my_xpc_mach(const char *name, dispatch_queue_t q, uint64_t flags)
{
    LOGF("YCODE-DL xpc_connection_create_mach_service %s flags=0x%llx [from %s]\n", name,
            (unsigned long long)flags, img(__builtin_return_address(0)));
    if (denied(name)) {
        LOGF("YCODE-DL   (denied: connecting to dev.ycode.denied instead)\n");
        return ycode_xpc_mach("dev.ycode.denied", q, flags);
    }
    return ycode_xpc_mach(name, q, flags);
}
INTERPOSE(my_xpc_mach, ycode_xpc_mach)
