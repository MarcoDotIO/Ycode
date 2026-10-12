/*
 * mslog: XPC-level recorder for the simulator Metal driver's host connection
 * (original Ycode code, R7). Inserted with DYLD_INSERT_LIBRARIES into our own
 * test programs (simctl spawn) or into every job of a throwaway boot
 * (simctl boot with SIMCTL_CHILD_ variables).
 *
 * It interposes public and exported libxpc calls and records, for every
 * connection whose service name starts with a target prefix, the messages the
 * client sends, the replies it gets, and the events the connection delivers.
 * XPC objects are printed with our own walker (public xpc_* getters); data
 * objects can also be written whole to files. It never reads executable
 * memory: data and shared-memory objects are the client's own message
 * payloads.
 *
 * Env: YC_MS_DIR=<dir>     log to <dir>/<process>-<pid>.log (required)
 *      YC_MS_ONLY=a,b      only these process names (default: all)
 *      YC_MS_PREFIX=p      target name prefix (default com.apple.metal.simulator)
 *      YC_MS_DUMP=1        write every data object to <dir>/<process>-<pid>-<seq>.bin
 *      YC_MS_SHMEM=1       map shared-memory objects read-only and record size and a prefix
 *      YC_MS_LIGHT=1       with YC_MS_DUMP: write segments only up to their used length and skip
 *                          other data objects of 16 KiB or more (keeps a whole boot fast)
 *      YC_MS_HEX=n         bytes of each data object shown inline (default 128)
 *      YC_MS_DENY=a,b      names that fail (bootstrap_look_up 1102), '*' suffix = prefix
 *      YC_MS_SFB=1         (build with -DMS_SFB) also record SimFramebuffer swap calls (SwapBegin, SwapAddSurface,
 *                          SwapSubmit) by wrapping the pointers the client gets from dlsym,
 *                          so their order relative to Metal messages is visible
 *      YC_MS_FAKE=1        instead of the host service, connect the client to an in-process test
 *                          server (anonymous XPC listener) that answers from what the captures
 *                          showed; YC_FAKE_VERSION, YC_FAKE_PROFILE (handshake reply values),
 *                          YC_FAKE_LIMITS=a,b,c,d (op 37 reply, four u64), YC_FAKE_NOREPLY=list of
 *                          "mt" or "mt:op" items answered with an empty dictionary,
 *                          YC_FAKE_NOEVENTS=1 (never send events 100/101), YC_FAKE_ONLY101=1,
 *                          YC_FAKE_ERROR=n and YC_FAKE_STATUS=n (values in the events)
 *      YC_MS_REGIONS=n     at each command-buffer submission (messageType 6), print the
 *                          non-zero 16-byte lines of the first n bytes of every region the
 *                          driver shared with xpc_shmem_create (the client's own memory)
 */
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <Block.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

extern const char *getprogname(void);
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
extern void xpc_connection_enable_sim2host_4sim(xpc_connection_t c);
extern pid_t ms_conn_pid(xpc_connection_t c) __asm__("_xpc_connection_get_pid"); /* exported libxpc name */
extern const struct _xpc_type_s _xpc_type_mach_send;
#define YC_TYPE_MACH_SEND (&_xpc_type_mach_send)
extern size_t xpc_shmem_map(xpc_object_t xshmem, void **region);
extern xpc_object_t xpc_shmem_create(void *region, size_t length);
extern xpc_connection_t ms_real_create(const char *name, dispatch_queue_t q, uint64_t flags)
    __asm__("_xpc_connection_create_mach_service");

#define INTERPOSE(repl, orig) \
    __attribute__((used)) static struct { const void *r; const void *o; } \
    _interpose_##orig __attribute__((section("__DATA,__interpose"))) = { (const void *)repl, (const void *)orig };

static int g_on = -1, g_dump, g_shmem, g_hex = 128, g_seq, g_dseq;
static FILE *g_log;
static char g_dir[512];
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_t0;
static mach_timebase_info_data_t g_tb;

#define MAXR 256
static struct { void *a; size_t n; } g_regs[MAXR];
static int g_nregs;

#define MAXC 64
static struct { xpc_connection_t c; char name[128]; int id; } g_conns[MAXC];
static int g_nconn;

static int listed(const char *list, const char *name)
{
    size_t n = strlen(name);
    while (list && *list) {
        const char *e = strchr(list, ',');
        size_t l = e ? (size_t)(e - list) : strlen(list);
        if (l && list[l - 1] == '*' ? !strncmp(list, name, l - 1) : (l == n && !strncmp(list, name, n))) return 1;
        list = e ? e + 1 : NULL;
    }
    return 0;
}

static FILE *lg(void)
{
    if (g_on < 0) {
        pthread_mutex_lock(&g_mx);
        if (g_on < 0) {
            const char *dir = getenv("YC_MS_DIR"), *only = getenv("YC_MS_ONLY");
            int on = dir && (!only || listed(only, getprogname()));
            if (on) {
                snprintf(g_dir, sizeof g_dir, "%s", dir);
                char path[1024];
                snprintf(path, sizeof path, "%s/%s-%d.log", dir, getprogname(), getpid());
                g_log = fopen(path, "a");
                if (g_log) setvbuf(g_log, NULL, _IOFBF, 1 << 16);
                else on = 0;
                g_dump = getenv("YC_MS_DUMP") != NULL;
                g_shmem = getenv("YC_MS_SHMEM") != NULL;
                if (getenv("YC_MS_HEX")) g_hex = atoi(getenv("YC_MS_HEX"));
                mach_timebase_info(&g_tb);
                g_t0 = mach_absolute_time();
            }
            g_on = on;
        }
        pthread_mutex_unlock(&g_mx);
    }
    return g_on ? g_log : NULL;
}

static double ms_now(void)
{
    return (double)(mach_absolute_time() - g_t0) * g_tb.numer / g_tb.denom / 1e6;
}

static const char *prefix(void)
{
    const char *p = getenv("YC_MS_PREFIX");
    return p ? p : "com.apple.metal.simulator";
}

static int conn_id(xpc_connection_t c)
{
    for (int i = 0; i < g_nconn; i++) if (g_conns[i].c == c) return g_conns[i].id;
    return 0;
}

static void ind(int d) { for (int i = 0; i < d; i++) fputs("  ", g_log); }

static void hexdump(const uint8_t *p, size_t n, int d)
{
    for (size_t i = 0; i < n; i += 16) {
        ind(d);
        fprintf(g_log, "%06zx:", i);
        for (size_t j = 0; j < 16; j++) {
            if (i + j < n) fprintf(g_log, " %02x", p[i + j]);
            else fputs("   ", g_log);
        }
        fputs("  |", g_log);
        for (size_t j = 0; j < 16 && i + j < n; j++) fputc(p[i + j] >= 32 && p[i + j] < 127 ? p[i + j] : '.', g_log);
        fputs("|\n", g_log);
    }
}

static void dumpfile(const void *p, size_t n, const char *kind)
{
    if (!g_dump || !n) return;
    if (getenv("YC_MS_LIGHT")) {
        /* Light mode: command-buffer segments trimmed to their used length; other data only below 16 KiB. */
        if (n == 65536) { uint32_t used; memcpy(&used, p, 4); if (used >= 8 && used <= n) n = used; }
        else if (n >= 16384) return;
    }
    char path[1024];
    int s = ++g_dseq;
    snprintf(path, sizeof path, "%s/%s-%d-%05d.%s", g_dir, getprogname(), getpid(), s, kind);
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fwrite(p, 1, n, f);
    fclose(f);
    fprintf(g_log, " -> %s-%d-%05d.%s", getprogname(), getpid(), s, kind);
}

static void walk(xpc_object_t o, int d)
{
    xpc_type_t t = xpc_get_type(o);
    if (t == XPC_TYPE_DICTIONARY) {
        fprintf(g_log, "dict(%zu)\n", xpc_dictionary_get_count(o));
        xpc_dictionary_apply(o, ^bool(const char *k, xpc_object_t v) {
            ind(d + 1);
            fprintf(g_log, "\"%s\" = ", k);
            walk(v, d + 1);
            return true;
        });
    } else if (t == XPC_TYPE_ARRAY) {
        fprintf(g_log, "array(%zu)\n", xpc_array_get_count(o));
        xpc_array_apply(o, ^bool(size_t i, xpc_object_t v) {
            ind(d + 1);
            fprintf(g_log, "[%zu] ", i);
            walk(v, d + 1);
            return true;
        });
    } else if (t == XPC_TYPE_UINT64) {
        uint64_t v = xpc_uint64_get_value(o);
        fprintf(g_log, "u64 %llu (0x%llx)\n", (unsigned long long)v, (unsigned long long)v);
    } else if (t == XPC_TYPE_INT64) {
        fprintf(g_log, "i64 %lld\n", (long long)xpc_int64_get_value(o));
    } else if (t == XPC_TYPE_BOOL) {
        fprintf(g_log, "bool %d\n", xpc_bool_get_value(o));
    } else if (t == XPC_TYPE_DOUBLE) {
        fprintf(g_log, "double %.17g\n", xpc_double_get_value(o));
    } else if (t == XPC_TYPE_STRING) {
        fprintf(g_log, "string \"%s\"\n", xpc_string_get_string_ptr(o));
    } else if (t == XPC_TYPE_DATA) {
        size_t n = xpc_data_get_length(o);
        const uint8_t *p = xpc_data_get_bytes_ptr(o);
        fprintf(g_log, "data len=%zu", n);
        if (p) dumpfile(p, n, "bin");
        fputc('\n', g_log);
        if (p) hexdump(p, n < (size_t)g_hex ? n : (size_t)g_hex, d + 1);
    } else if (t == XPC_TYPE_SHMEM) {
        fprintf(g_log, "shmem");
        if (g_shmem) {
            void *r = NULL;
            size_t n = xpc_shmem_map(o, &r);
            fprintf(g_log, " size=%zu", n);
            if (r && n) {
                const uint8_t *p = r;
                size_t nz = 0;
                for (size_t i = 0; i < n; i++) if (p[i]) { nz = i + 1; }
                fprintf(g_log, " nonzero-end=%zu", nz);
                dumpfile(r, nz, "shm");
                fputc('\n', g_log);
                hexdump(p, nz < (size_t)g_hex ? nz : (size_t)g_hex, d + 1);
                munmap(r, n);
            } else fputc('\n', g_log);
        } else fputc('\n', g_log);
    } else if (t == YC_TYPE_MACH_SEND) {
        fprintf(g_log, "mach_send\n");
    } else if (t == XPC_TYPE_FD) {
        fprintf(g_log, "fd\n");
    } else if (t == XPC_TYPE_NULL) {
        fprintf(g_log, "null\n");
    } else if (t == XPC_TYPE_UUID) {
        const uint8_t *u = xpc_uuid_get_bytes(o);
        fprintf(g_log, "uuid ");
        for (int i = 0; i < 16; i++) fprintf(g_log, "%02x", u[i]);
        fputc('\n', g_log);
    } else if (t == XPC_TYPE_ERROR) {
        const char *s = xpc_dictionary_get_string(o, XPC_ERROR_KEY_DESCRIPTION);
        fprintf(g_log, "error \"%s\"\n", s ? s : "?");
    } else {
        char *s = xpc_copy_description(o);
        fprintf(g_log, "other %s\n", s ? s : "?");
        free(s);
    }
}

static const char *caller_image(void *ra)
{
    Dl_info di;
    if (dladdr(ra, &di) && di.dli_fname) {
        const char *b = strrchr(di.dli_fname, '/');
        return b ? b + 1 : di.dli_fname;
    }
    return "?";
}

static void record(const char *tag, int id, xpc_object_t m, void *ra, double dt)
{
    FILE *f = lg();
    if (!f) return;
    pthread_mutex_lock(&g_mx);
    fprintf(f, "== #%d t=%.3fms conn %d %s from %s", ++g_seq, ms_now(), id, tag, ra ? caller_image(ra) : "-");
    if (dt >= 0) fprintf(f, " (%.3fms)", dt);
    fputs(": ", f);
    if (m) walk(m, 0);
    else fputs("(null)\n", f);
    fflush(f);
    pthread_mutex_unlock(&g_mx);
}

/* Our test programs call this through dlsym to put markers into the log. */
__attribute__((visibility("default"))) void mslog_mark(const char *text)
{
    FILE *f = lg();
    if (!f) return;
    pthread_mutex_lock(&g_mx);
    fprintf(f, "## t=%.3fms MARK %s\n", ms_now(), text);
    fflush(f);
    pthread_mutex_unlock(&g_mx);
}

static kern_return_t my_look_up(mach_port_t bp, const char *name, mach_port_t *sp)
{
    const char *deny = getenv("YC_MS_DENY");
    if (name && deny && listed(deny, name)) { if (sp) *sp = MACH_PORT_NULL; return 1102; }
    kern_return_t kr = bootstrap_look_up(bp, name, sp);
    FILE *f = lg();
    if (f && name && (!strncmp(name, prefix(), strlen(prefix())) || strstr(name, "gputools"))) {
        pthread_mutex_lock(&g_mx);
        fprintf(f, "## t=%.3fms bootstrap_look_up(%s) = %d port 0x%x from %s\n", ms_now(), name, kr,
                sp ? *sp : 0, caller_image(__builtin_return_address(0)));
        fflush(f);
        pthread_mutex_unlock(&g_mx);
    }
    return kr;
}
INTERPOSE(my_look_up, bootstrap_look_up)

/* ---- in-process test server (YC_MS_FAKE) ---- */
static uint64_t g_fref = 0x100;

static int fake_noreply(uint64_t mt, uint32_t op)
{
    const char *l = getenv("YC_FAKE_NOREPLY");
    char a[32], b[32];
    snprintf(a, sizeof a, "%llu", (unsigned long long)mt);
    snprintf(b, sizeof b, "%llu:%u", (unsigned long long)mt, op);
    return l && (listed(l, a) || listed(l, b));
}

static void fake_reply_data(xpc_object_t r, const void *p, size_t n) { xpc_dictionary_set_data(r, "replyData", p, n); }

static void fake_event(xpc_connection_t peer, uint64_t mt, uint64_t cb, uint64_t status)
{
    xpc_object_t e = xpc_dictionary_create(NULL, NULL, 0);
    if (mt == 101 && getenv("YC_FAKE_STATUS")) status = strtoull(getenv("YC_FAKE_STATUS"), 0, 0);
    xpc_dictionary_set_uint64(e, "messageType", mt);
    xpc_dictionary_set_uint64(e, "commandBufferRef", cb);
    xpc_dictionary_set_uint64(e, "status", status);
    xpc_dictionary_set_uint64(e, "error", getenv("YC_FAKE_ERROR") ? strtoull(getenv("YC_FAKE_ERROR"), 0, 0) : 1);
    xpc_dictionary_set_double(e, "startTime", 1.0);
    xpc_dictionary_set_double(e, "endTime", 1.5);
    xpc_connection_send_message(peer, e);
    xpc_release(e);
}

static void fake_msg(xpc_connection_t peer, xpc_object_t m)
{
    if (xpc_get_type(m) != XPC_TYPE_DICTIONARY) return;
    uint64_t mt = xpc_dictionary_get_uint64(m, "messageType");
    size_t cl = 0;
    const uint8_t *cmd = xpc_dictionary_get_data(m, "command", &cl);
    uint32_t op = cmd && cl >= 4 ? *(const uint32_t *)cmd : 0;
    xpc_object_t r = xpc_dictionary_create_reply(m);
    if (r && fake_noreply(mt, op)) { xpc_connection_send_message(peer, r); xpc_release(r); return; }
    uint64_t ref = ++g_fref;
    switch (mt) {
    case 0:
        xpc_dictionary_set_uint64(r, "version", getenv("YC_FAKE_VERSION") ? strtoull(getenv("YC_FAKE_VERSION"), 0, 0) : 10);
        xpc_dictionary_set_uint64(r, "processRef", 1);
        xpc_dictionary_set_uint64(r, "registryID", 0x100000473ull);
        xpc_dictionary_set_uint64(r, "hostFeatureProfile", getenv("YC_FAKE_PROFILE") ? strtoull(getenv("YC_FAKE_PROFILE"), 0, 0) : 10);
        break;
    case 1: xpc_dictionary_set_uint64(r, "bufferRef", ref); break;
    case 7: xpc_dictionary_set_uint64(r, "commandQueueRef", ref); break;
    case 6:
        if (!getenv("YC_FAKE_NOEVENTS")) {
            uint64_t cb = xpc_dictionary_get_uint64(m, "commandBufferRef");
            if (!getenv("YC_FAKE_ONLY101")) fake_event(peer, 100, cb, 3);
            fake_event(peer, 101, cb, 4);
        }
        break;
    case 8: { uint32_t v = (uint32_t)ref; if (r) fake_reply_data(r, &v, 4); break; }
    case 13: case 15: { uint64_t v = ref; if (r) fake_reply_data(r, &v, 8); break; }
    case 12: {
        if (!r) break;
        if (op == 37) {
            uint64_t l[4] = { 0x400, 0x400, 0x400, 0x8000 };
            const char *e = getenv("YC_FAKE_LIMITS");
            if (e) sscanf(e, "%llx,%llx,%llx,%llx", (unsigned long long *)&l[0], (unsigned long long *)&l[1],
                          (unsigned long long *)&l[2], (unsigned long long *)&l[3]);
            fake_reply_data(r, l, sizeof l);
        } else if (op == 11) {
            uint32_t v[6] = { (uint32_t)ref, 0, 0x200400, 0, 0, 0 };
            fake_reply_data(r, v, sizeof v);
        } else if (op == 38) {
            uint32_t v[2] = { (uint32_t)(ref << 12), 0x100 };
            fake_reply_data(r, v, sizeof v);
        } else {
            uint64_t v = ref;
            fake_reply_data(r, &v, 8);
        }
        break;
    }
    default: break;
    }
    if (r) { xpc_connection_send_message(peer, r); xpc_release(r); }
}

static xpc_connection_t fake_connect(dispatch_queue_t q)
{
    static xpc_connection_t listener;
    static dispatch_queue_t fq;
    if (!listener) {
        fq = dispatch_queue_create("dev.ycode.R7.fake", NULL);
        listener = xpc_connection_create(NULL, fq);
        xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
            if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
            xpc_connection_set_target_queue(peer, fq);
            xpc_connection_set_event_handler(peer, ^(xpc_object_t m) { fake_msg(peer, m); });
            xpc_connection_resume(peer);
        });
        xpc_connection_resume(listener);
    }
    xpc_connection_t c = xpc_connection_create_from_endpoint(xpc_endpoint_create(listener));
    if (q) xpc_connection_set_target_queue(c, q);
    return c;
}

static xpc_connection_t my_create(const char *name, dispatch_queue_t q, uint64_t flags)
{
    const char *deny = getenv("YC_MS_DENY");
    if (name && deny && listed(deny, name)) return ms_real_create("dev.ycode.denied", q, flags);
    int fake = getenv("YC_MS_FAKE") && name && !strncmp(name, prefix(), strlen(prefix()));
    xpc_connection_t c = fake ? fake_connect(q) : ms_real_create(name, q, flags);
    FILE *f = lg();
    if (f && name && (!strncmp(name, prefix(), strlen(prefix())) || strstr(name, "gputools"))) {
        pthread_mutex_lock(&g_mx);
        int id = 0;
        if (g_nconn < MAXC) {
            id = g_nconn + 1;
            g_conns[g_nconn].c = c;
            g_conns[g_nconn].id = id;
            snprintf(g_conns[g_nconn].name, sizeof g_conns[0].name, "%s", name);
            g_nconn++;
        }
        fprintf(f, "## t=%.3fms conn %d = xpc_connection_create_mach_service(%s, flags 0x%llx) from %s%s\n", ms_now(), id,
                name, (unsigned long long)flags, caller_image(__builtin_return_address(0)), fake ? " [TEST SERVER]" : "");
        fflush(f);
        pthread_mutex_unlock(&g_mx);
    }
    return c;
}
INTERPOSE(my_create, ms_real_create)

static void my_sim2host(xpc_connection_t c)
{
    int id = conn_id(c);
    if (id && lg()) {
        pthread_mutex_lock(&g_mx);
        fprintf(g_log, "## t=%.3fms conn %d enable_sim2host_4sim%s\n", ms_now(), id,
                getenv("YC_MS_FAKE") ? " (not passed on: test server)" : "");
        pthread_mutex_unlock(&g_mx);
    }
    if (id && getenv("YC_MS_FAKE")) return;
    xpc_connection_enable_sim2host_4sim(c);
}
INTERPOSE(my_sim2host, xpc_connection_enable_sim2host_4sim)

static void dump_regions(void)
{
    const char *e = getenv("YC_MS_REGIONS");
    if (!e || !lg()) return;
    size_t lim = (size_t)strtoul(e, NULL, 0);
    pthread_mutex_lock(&g_mx);
    for (int i = 0; i < g_nregs; i++) {
        size_t n = g_regs[i].n < lim ? g_regs[i].n : lim;
        const uint8_t *p = g_regs[i].a;
        fprintf(g_log, "## region %p len %zu (first %zu bytes, non-zero lines):\n", g_regs[i].a, g_regs[i].n, n);
        for (size_t o = 0; o + 16 <= n; o += 16) {
            int nz = 0;
            for (int j = 0; j < 16; j++) nz |= p[o + j];
            if (!nz) continue;
            fprintf(g_log, "   %06zx:", o);
            for (int j = 0; j < 16; j++) fprintf(g_log, " %02x", p[o + j]);
            fputc('\n', g_log);
        }
    }
    fflush(g_log);
    pthread_mutex_unlock(&g_mx);
}

static void my_send(xpc_connection_t c, xpc_object_t m)
{
    int id = conn_id(c);
    if (id && xpc_get_type(m) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_uint64(m, "messageType") == 6) dump_regions();
    if (id) record("C>S send", id, m, __builtin_return_address(0), -1);
    xpc_connection_send_message(c, m);
}
INTERPOSE(my_send, xpc_connection_send_message)

static xpc_object_t my_sync(xpc_connection_t c, xpc_object_t m)
{
    int id = conn_id(c);
    if (!id) return xpc_connection_send_message_with_reply_sync(c, m);
    void *ra = __builtin_return_address(0);
    record("C>S sync", id, m, ra, -1);
    uint64_t a = mach_absolute_time();
    xpc_object_t r = xpc_connection_send_message_with_reply_sync(c, m);
    double dt = (double)(mach_absolute_time() - a) * g_tb.numer / g_tb.denom / 1e6;
    record("S>C reply", id, r, NULL, dt);
    static int pid_logged[MAXC + 1];
    if (id <= MAXC && !pid_logged[id] && lg()) {
        pid_logged[id] = 1;
        pthread_mutex_lock(&g_mx);
        fprintf(g_log, "## conn %d server pid %d\n", id, (int)ms_conn_pid(c));
        pthread_mutex_unlock(&g_mx);
    }
    return r;
}
INTERPOSE(my_sync, xpc_connection_send_message_with_reply_sync)

static void my_async(xpc_connection_t c, xpc_object_t m, dispatch_queue_t q, xpc_handler_t h)
{
    int id = conn_id(c);
    if (!id) { xpc_connection_send_message_with_reply(c, m, q, h); return; }
    record("C>S async", id, m, __builtin_return_address(0), -1);
    xpc_handler_t hc = Block_copy(h);
    xpc_connection_send_message_with_reply(c, m, q, ^(xpc_object_t r) {
        record("S>C async-reply", id, r, NULL, -1);
        hc(r);
    });
}
INTERPOSE(my_async, xpc_connection_send_message_with_reply)

static void my_handler(xpc_connection_t c, xpc_handler_t h)
{
    int id = conn_id(c);
    if (!id) { xpc_connection_set_event_handler(c, h); return; }
    xpc_handler_t hc = Block_copy(h);
    xpc_connection_set_event_handler(c, ^(xpc_object_t ev) {
        record("S>C event", id, ev, NULL, -1);
        hc(ev);
    });
}
INTERPOSE(my_handler, xpc_connection_set_event_handler)

#ifdef MS_SFB
/* SimFramebuffer swap calls (signatures from simframebuffer.md section 3.6). Built only with
 * -DMS_SFB: interposing dlsym changes what RTLD_NEXT/RTLD_SELF/RTLD_DEFAULT look-ups see (they
 * are resolved relative to this image), which blanked the display in a whole-boot run. */
typedef struct { double x, y, w, h; } ms_rect;
static bool (*real_begin)(void *, uint64_t, void **);
static bool (*real_add)(void *, void *, ms_rect, ms_rect, long, long);
static bool (*real_submit)(void *, void **);
extern uint32_t IOSurfaceGetID(void *);

static void sfb_note(const char *what, uint64_t a, uint64_t b)
{
    if (!lg()) return;
    pthread_mutex_lock(&g_mx);
    fprintf(g_log, "## t=%.3fms SFB %s 0x%llx %llu\n", ms_now(), what, (unsigned long long)a, (unsigned long long)b);
    fflush(g_log);
    pthread_mutex_unlock(&g_mx);
}
static bool w_begin(void *sc, uint64_t t, void **e) { sfb_note("SwapBegin", (uint64_t)sc, t); return real_begin(sc, t, e); }
static bool w_add(void *sc, void *surf, ms_rect a, ms_rect b, long x, long y)
{
    sfb_note("SwapAddSurface (surface id)", (uint64_t)sc, surf ? IOSurfaceGetID(surf) : 0);
    return real_add(sc, surf, a, b, x, y);
}
static bool w_submit(void *sc, void **e)
{
    sfb_note("SwapSubmit begin", (uint64_t)sc, 0);
    bool r = real_submit(sc, e);
    sfb_note("SwapSubmit end", (uint64_t)sc, r);
    return r;
}

static void *my_dlsym(void *h, const char *name)
{
    void *p = dlsym(h, name);
    if (!p || !name || !getenv("YC_MS_SFB")) return p;
    if (!strcmp(name, "SFBSwapchainSwapBegin")) { real_begin = p; return (void *)w_begin; }
    if (!strcmp(name, "SFBSwapchainSwapAddSurface")) { real_add = p; return (void *)w_add; }
    if (!strcmp(name, "SFBSwapchainSwapSubmit")) { real_submit = p; return (void *)w_submit; }
    return p;
}
INTERPOSE(my_dlsym, dlsym)
#endif

/* Record which images create shared-memory objects, with address and length. */
static xpc_object_t my_shmem_create(void *region, size_t len)
{
    xpc_object_t o = xpc_shmem_create(region, len);
    void *ra = __builtin_return_address(0);
    const char *img = caller_image(ra);
    if (lg() && strstr(img, "MTLSim")) {
        pthread_mutex_lock(&g_mx);
        if (g_nregs < MAXR) { g_regs[g_nregs].a = region; g_regs[g_nregs].n = len; g_nregs++; }
        fprintf(g_log, "## t=%.3fms xpc_shmem_create(%p, %zu) from %s\n", ms_now(), region, len, img);
        fflush(g_log);
        pthread_mutex_unlock(&g_mx);
    }
    return o;
}
INTERPOSE(my_shmem_create, xpc_shmem_create)
