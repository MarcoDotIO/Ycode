/*
 * rcenv: Ycode research interposer R6 (original Ycode code, no Apple code).
 * Inserted with DYLD_INSERT_LIBRARIES into the jobs of a throwaway simulator
 * boot (simctl boot with SIMCTL_CHILD_ variables). Black-box only: it records
 * NAMES the runtime asks for, never code.
 *
 *  - getenv(name): logs each distinct (name, calling image) pair once, with
 *    whether the variable was set. Shows which environment switches the render
 *    server reads.
 *  - dlopen(path): logs paths (shows which drivers/bundles are loaded).
 *  - bootstrap_look_up / xpc_connection_create_mach_service: names in
 *    RC_DENY (comma list, '*' suffix = prefix) fail (1102 / a connection to a
 *    name that does not exist), imitating a host without them (as R4/R5).
 *    Denied look-ups are counted, not logged one by one.
 *
 * Env: RC_DIR=<dir>  log to <dir>/<process>-<pid>.env.log
 *      RC_ONLY=a,b   log only in these process names (deny applies everywhere)
 *      RC_DENY=a,b*  names to deny
 */
#include <mach/mach.h>
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern const char *getprogname(void);
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
extern xpc_connection_t rc_xpc_mach(const char *name, dispatch_queue_t q, uint64_t flags)
    __asm__("_xpc_connection_create_mach_service");

#define INTERPOSE(repl, orig) \
    __attribute__((used)) static struct { const void *r; const void *o; } \
    _interpose_##orig __attribute__((section("__DATA,__interpose"))) = { (const void *)repl, (const void *)orig };

static FILE *g_log;
static int g_logging = -1;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
/* No thread-local storage: getenv is called by libmalloc before libSystem has
 * initialized TLS. Before our constructor runs we pass through; afterwards a
 * global owner thread id guards against re-entry while we hold the lock. */
static volatile int g_ready;
static pthread_t g_owner;
__attribute__((constructor)) static void rc_init(void) { g_ready = 1; }
static int rc_enter(void)
{
    if (!g_ready || pthread_equal(g_owner, pthread_self())) return 0;
    pthread_mutex_lock(&g_mu);
    g_owner = pthread_self();
    return 1;
}
static void rc_leave(void) { g_owner = (pthread_t)0; pthread_mutex_unlock(&g_mu); }
static unsigned long g_denied;

static int listed(const char *list, const char *name)
{
    if (!list || !name) return 0;
    size_t n = strlen(name);
    while (*list) {
        const char *e = strchr(list, ',');
        size_t l = e ? (size_t)(e - list) : strlen(list);
        if (l && list[l - 1] == '*' ? !strncmp(list, name, l - 1) : (l == n && !strncmp(list, name, n))) return 1;
        if (!e) break;
        list = e + 1;
    }
    return 0;
}

/* Our own reads of the environment use environ directly so they are not logged. */
extern char **environ;
static const char *raw_env(const char *k)
{
    size_t n = strlen(k);
    for (char **e = environ; e && *e; e++) if (!strncmp(*e, k, n) && (*e)[n] == '=') return *e + n + 1;
    return NULL;
}

static FILE *rc_log(void)
{
    if (g_logging < 0) {
        const char *dir = raw_env("RC_DIR"), *only = raw_env("RC_ONLY");
        int on = dir && (!only || listed(only, getprogname()));
        if (on) {
            char path[1024];
            snprintf(path, sizeof path, "%s/%s-%d.env.log", dir, getprogname(), getpid());
            g_log = fopen(path, "a");
            if (g_log) setvbuf(g_log, NULL, _IOLBF, 0);
        }
        g_logging = g_log != NULL;
    }
    return g_logging ? g_log : NULL;
}

static const char *image_of(const void *addr)
{
    Dl_info di;
    if (!dladdr(addr, &di) || !di.dli_fname) return "?";
    const char *s = strrchr(di.dli_fname, '/');
    return s ? s + 1 : di.dli_fname;
}

/* distinct (name, image) pairs */
#define SEEN_MAX 4096
static struct { char name[96]; char img[64]; } g_seen[SEEN_MAX];
static int g_nseen;

static char *my_getenv(const char *name)
{
    char *v = getenv(name);
    if (!name || !rc_enter()) return v;
    FILE *f = rc_log();
    if (f) {
        const char *img = image_of(__builtin_return_address(0));
        int dup = 0;
        for (int i = 0; i < g_nseen && !dup; i++)
            dup = !strncmp(g_seen[i].name, name, 95) && !strncmp(g_seen[i].img, img, 63);
        if (!dup && g_nseen < SEEN_MAX) {
            snprintf(g_seen[g_nseen].name, 96, "%s", name);
            snprintf(g_seen[g_nseen].img, 64, "%s", img);
            g_nseen++;
            fprintf(f, "getenv %s from %s -> %s\n", name, img, v ? v : "(unset)");
        }
    }
    rc_leave();
    return v;
}
INTERPOSE(my_getenv, getenv)

static void *my_dlopen(const char *path, int mode)
{
    void *h = dlopen(path, mode);
    if (rc_enter()) {
        FILE *f = rc_log();
        if (f) fprintf(f, "dlopen %s mode 0x%x from %s -> %s\n", path ? path : "(null)", mode,
                       image_of(__builtin_return_address(0)), h ? "ok" : "fail");
        rc_leave();
    }
    return h;
}
INTERPOSE(my_dlopen, dlopen)


static kern_return_t my_look_up(mach_port_t bp, const char *name, mach_port_t *sp)
{
    if (listed(raw_env("RC_DENY"), name)) {
        if (sp) *sp = MACH_PORT_NULL;
        if (__sync_add_and_fetch(&g_denied, 1) == 1 && rc_enter()) {
            FILE *f = rc_log();
            if (f) fprintf(f, "deny first look-up %s from %s\n", name, image_of(__builtin_return_address(0)));
            rc_leave();
        }
        return 1102;
    }
    return bootstrap_look_up(bp, name, sp);
}
INTERPOSE(my_look_up, bootstrap_look_up)

static xpc_connection_t my_xpc(const char *name, dispatch_queue_t q, uint64_t flags)
{
    if (listed(raw_env("RC_DENY"), name)) {
        __sync_add_and_fetch(&g_denied, 1);
        if (rc_enter()) {
            FILE *f = rc_log();
            if (f) fprintf(f, "deny xpc %s from %s\n", name, image_of(__builtin_return_address(0)));
            rc_leave();
        }
        return rc_xpc_mach("dev.ycode.denied", q, flags);
    }
    return rc_xpc_mach(name, q, flags);
}
INTERPOSE(my_xpc, rc_xpc_mach)

__attribute__((destructor)) static void rc_fini(void)
{
    FILE *f = g_logging > 0 ? g_log : NULL;
    if (f) fprintf(f, "exit: denied look-ups %lu\n", g_denied);
}
