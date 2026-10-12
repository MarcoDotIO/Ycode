/*
 * isinterpose: in-process man-in-the-middle for com.apple.IOSurface.Remote
 * (original Ycode code, R5). Inserted with DYLD_INSERT_LIBRARIES into the jobs
 * of a throwaway simulator boot (simctl boot with SIMCTL_CHILD_ variables).
 *
 * It interposes xpc_connection_create_mach_service. For the target name it
 * looks the service up itself (bootstrap_look_up), makes a proxy port served
 * by the recording relay of isproxy.h, and returns a connection to the proxy
 * (xpc_endpoint_create_mach_port_4sim + xpc_connection_create_from_endpoint,
 * both exported libxpc names). Every other call is passed through unchanged.
 * It also logs calls of xpc_connection_enable_sim2host_4sim.
 *
 * Env: YC_IS_DIR=<dir>   log to <dir>/<process>-<pid>.log (required)
 *      YC_IS_ONLY=a,b    only these process names (default: all)
 *      YC_IS_NAME        target name (default com.apple.IOSurface.Remote)
 *      YC_IS_MAPTEST=1   see isproxy.h
 *      YC_IS_DENY=a,b    names that fail in every process (bootstrap_look_up 1102; XPC
 *                        connections go to a name that does not exist), as R4 did
 *      YC_IS_REDIRECT=n  relay to the service published as <n> (our isserve test
 *                        server) when that name can be looked up; otherwise to the real one
 */
#include "isproxy.h"
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>

extern const char *getprogname(void);
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
extern xpc_connection_t ycode_xpc_mach(const char *name, dispatch_queue_t q, uint64_t flags)
    __asm__("_xpc_connection_create_mach_service");
extern xpc_endpoint_t xpc_endpoint_create_mach_port_4sim(mach_port_t port);
extern void xpc_connection_enable_sim2host_4sim(xpc_connection_t c);

#define INTERPOSE(repl, orig) \
    __attribute__((used)) static struct { const void *r; const void *o; } \
    _interpose_##orig __attribute__((section("__DATA,__interpose"))) = { (const void *)repl, (const void *)orig };

static int g_on = -1;
static FILE *g_log;
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;

static int listed(const char *list, const char *name)
{
    size_t n = strlen(name);
    while (list && *list) {
        const char *e = strchr(list, ',');
        size_t l = e ? (size_t)(e - list) : strlen(list);
        if (l == n && !strncmp(list, name, n)) return 1;
        list = e ? e + 1 : NULL;
    }
    return 0;
}

static FILE *logf_open(void)
{
    pthread_mutex_lock(&g_mx);
    if (g_on < 0) {
        const char *dir = getenv("YC_IS_DIR"), *only = getenv("YC_IS_ONLY");
        g_on = dir && (!only || listed(only, getprogname()));
        if (g_on) {
            char path[1024];
            snprintf(path, sizeof path, "%s/%s-%d.log", dir, getprogname(), getpid());
            g_log = fopen(path, "a");
            if (g_log) setvbuf(g_log, NULL, _IOLBF, 0);
            else g_on = 0;
        }
    }
    pthread_mutex_unlock(&g_mx);
    return g_on ? g_log : NULL;
}

static int denied(const char *name)
{
    const char *list = getenv("YC_IS_DENY");
    if (!name || !list) return 0;
    size_t n = strlen(name);
    while (*list) {
        const char *e = strchr(list, ',');
        size_t l = e ? (size_t)(e - list) : strlen(list);
        /* An entry ending in '*' matches a prefix. */
        if (l && list[l - 1] == '*' ? !strncmp(list, name, l - 1) : (l == n && !strncmp(list, name, n))) return 1;
        if (!e) break;
        list = e + 1;
    }
    return 0;
}

static kern_return_t my_look_up(mach_port_t bp, const char *name, mach_port_t *sp)
{
    if (denied(name)) { if (sp) *sp = MACH_PORT_NULL; return 1102; }
    return bootstrap_look_up(bp, name, sp);
}
INTERPOSE(my_look_up, bootstrap_look_up)

static xpc_connection_t my_create(const char *name, dispatch_queue_t q, uint64_t flags)
{
    if (denied(name)) return ycode_xpc_mach("dev.ycode.denied", q, flags);
    const char *target = getenv("YC_IS_NAME") ? getenv("YC_IS_NAME") : "com.apple.IOSurface.Remote";
    if (!name || strcmp(name, target)) return ycode_xpc_mach(name, q, flags);
    FILE *f = logf_open();
    if (!f) return ycode_xpc_mach(name, q, flags);
    mach_port_t real = MACH_PORT_NULL;
    kern_return_t kr = 1;
    const char *redir = getenv("YC_IS_REDIRECT");
    if (redir && *redir) {
        kr = bootstrap_look_up(bootstrap_port, redir, &real);
        fprintf(f, "-- redirect look-up %s: kr=%d\n", redir, kr);
    }
    if (kr != KERN_SUCCESS) kr = bootstrap_look_up(bootstrap_port, name, &real);
    Dl_info di;
    const char *caller = dladdr(__builtin_return_address(0), &di) && di.dli_fname ? di.dli_fname : "?";
    fprintf(f, "-- %s[%d] xpc_connection_create_mach_service(%s, flags 0x%llx) from %s: look-up kr=%d\n",
            getprogname(), getpid(), name, (unsigned long long)flags, strrchr(caller, '/') ? strrchr(caller, '/') + 1 : caller, kr);
    if (kr != KERN_SUCCESS) return ycode_xpc_mach(name, q, flags);
    isp_start(f);
    mach_port_t px = isp_service_proxy(real);
    mach_port_insert_right(mach_task_self(), px, px, MACH_MSG_TYPE_MAKE_SEND);
    xpc_endpoint_t ep = xpc_endpoint_create_mach_port_4sim(px);
    xpc_connection_t c = ep ? xpc_connection_create_from_endpoint(ep) : NULL;
    if (!c) { fprintf(f, "-- endpoint path failed; passing through\n"); return ycode_xpc_mach(name, q, flags); }
    if (q) xpc_connection_set_target_queue(c, q);
    fprintf(f, "-- proxied through 0x%x\n", px);
    return c;
}
INTERPOSE(my_create, ycode_xpc_mach)

static void my_sim2host(xpc_connection_t c)
{
    FILE *f = logf_open();
    if (f) {
        char *d = xpc_copy_description(c);
        fprintf(f, "-- xpc_connection_enable_sim2host_4sim(%s)\n", d ? d : "?");
        free(d);
    }
    xpc_connection_enable_sim2host_4sim(c);
}
INTERPOSE(my_sim2host, xpc_connection_enable_sim2host_4sim)
