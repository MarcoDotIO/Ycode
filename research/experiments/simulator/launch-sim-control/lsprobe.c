/*
 * Ycode research probe (macOS, arm64): black-box capture of the messages that
 * the runtime's host library liblaunch_sim.dylib sends on the simulator
 * control channel. Original Ycode code, written for
 * specs/simulator/launch-sim-control.md. Contains no Apple code. The library
 * is only dlopen'ed and its exported functions are called; nothing in it is
 * read or disassembled.
 *
 * Modes:
 *   lsprobe call <fn> [arg...]
 *       dlopen the library (path in YC_LIB), make a port P that this process
 *       serves on a thread, call <fn> with the arguments given (up to 12, each a
 *       token, see make_arg), dump every message that arrives on P (and on P2)
 *       and answer it as YC_REPLY says (see answer()). After the call, print
 *       the return value and the contents of every out-buffer argument.
 *   lsprobe host <launchd_sim> <plist>
 *       Host mode: act as launchd_sim's host bootstrap (answer its 708 startup
 *       request with a fresh receive right, as in bootstrap-wire.md §5.2),
 *       give it a holding-tank child (§5.4), keep the send right S to its
 *       service port, then put a relay port M in front of S, and run the
 *       script in YC_SCRIPT (lines "fn arg..."; P = M) against it. Every
 *       request and every reply that passes the relay is dumped.
 *   Script lines may also be pseudo-calls: "raw*" (messages built by our own
 *   writer from the spec, sent straight to the service port: rawbind, rawreg,
 *   rawfind, rawgetenv, rawunreg, rawwait, rawdeath, rawspawn, rawid),
 *   "sleep <s>", "sh <cmd>", "echo <text>", "destroyP", "destroyB",
 *   "destroyRecv".
 * lsinterpose.dylib (DYLD_INSERT_LIBRARIES) logs the library's libSystem calls
 * and resolves names with YC_NAME_PREFIX to P.
 * Environment: YC_LIB, YC_REPLY, YC_TIMEOUT (seconds), YC_ENVFILE, YC_SCRIPT,
 *   YC_PREQUEUE (host: queue a 701 before the 808 reply), YC_TANK_SLEEP,
 *   YC_PRE_SLEEP_MS, YC_W24, YC_TRACE_MSG, YC_SIM_STDERR,
 *   YC_SECONDS (how long host mode keeps launchd_sim alive after the script),
 *   YC_SETBS=1 (call mode: point our own bootstrap_port global at P2 too).
 */
#include <mach/mach.h>
#include <mach/message.h>
#include <servers/bootstrap.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <stdint.h>
#include <errno.h>
#include <Block.h>
extern int fileport_makeport(int, mach_port_t *);

extern char **environ;

#define BUFSZ (256 * 1024)
static FILE *g_out;
static int g_seq;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static mach_port_t g_P, g_P2, g_pset, g_B;

/* ------------------------------------------------------------------ dump */

static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static size_t al4(size_t x) { return (x + 3) & ~(size_t)3; }

static void hexdump(const uint8_t *p, size_t n, size_t base)
{
    for (size_t i = 0; i < n; i += 16) {
        fprintf(g_out, "    %06zx:", base + i);
        for (size_t j = 0; j < 16; j++) {
            if (i + j < n) fprintf(g_out, " %02x", p[i + j]);
            else fprintf(g_out, "   ");
        }
        fprintf(g_out, "  |");
        for (size_t j = 0; j < 16 && i + j < n; j++) {
            uint8_t c = p[i + j];
            fputc((c >= 32 && c < 127) ? c : '.', g_out);
        }
        fprintf(g_out, "|\n");
    }
}

static int is_xpc_magic(uint32_t m) { return m == 0x7870633f || m == 0x78706340; }
static void ind(int d) { for (int i = 0; i < d; i++) fprintf(g_out, "  "); }

/* Our decoder of the serialized object format of bootstrap-wire.md §3. */
static size_t xpc_decode(const uint8_t *p, size_t n, size_t off, int depth, int *ports)
{
    if (off + 4 > n) { fprintf(g_out, "<truncated>\n"); return n; }
    uint32_t t = rd32(p + off);
    off += 4;
    switch (t) {
    case 0x1000: fprintf(g_out, "null\n"); return off;
    case 0x2000: fprintf(g_out, "bool %u\n", rd32(p + off)); return off + 4;
    case 0x3000: fprintf(g_out, "int64 %lld\n", (long long)rd64(p + off)); return off + 8;
    case 0x4000: fprintf(g_out, "uint64 %llu (0x%llx)\n", (unsigned long long)rd64(p + off),
                         (unsigned long long)rd64(p + off)); return off + 8;
    case 0x5000: { double d; memcpy(&d, p + off, 8); fprintf(g_out, "double %g\n", d); return off + 8; }
    case 0x7000: fprintf(g_out, "date %lld\n", (long long)rd64(p + off)); return off + 8;
    case 0x8000: { uint32_t l = rd32(p + off);
                   if (off + 4 + l > n) { fprintf(g_out, "data len=%u (port #%d)\n", l, (*ports)++); return off + 4; }
                   fprintf(g_out, "data len=%u\n", l);
                   hexdump(p + off + 4, l > 512 ? 512 : l, off + 4); return al4(off + 4 + l); }
    case 0xb000: fprintf(g_out, "fd (port #%d)\n", (*ports)++); return off;
    case 0xc000: fprintf(g_out, "shmem size=%u word2=%u (port #%d)\n", rd32(p + off), rd32(p + off + 4), (*ports)++);
                 return off + 8;
    case 0x9000: { uint32_t l = rd32(p + off); fprintf(g_out, "string len=%u \"%.*s\"\n", l,
                   (int)(l ? l - 1 : 0), (const char *)p + off + 4); return al4(off + 4 + l); }
    case 0xa000: { fprintf(g_out, "uuid "); for (int i = 0; i < 16; i++) fprintf(g_out, "%02x", p[off + i]);
                   fprintf(g_out, "\n"); return off + 16; }
    case 0xd000: fprintf(g_out, "mach_send (port #%d)\n", (*ports)++); return off;
    case 0x15000: fprintf(g_out, "mach_recv (port #%d)\n", (*ports)++); return off;
    case 0xe000: {
        uint32_t len = rd32(p + off), cnt = rd32(p + off + 4);
        fprintf(g_out, "array bytes=%u count=%u\n", len, cnt);
        size_t o = off + 8;
        for (uint32_t i = 0; i < cnt && o < n; i++) { ind(depth + 1); fprintf(g_out, "[%u] ", i);
            o = xpc_decode(p, n, o, depth + 1, ports); }
        return o;
    }
    case 0xf000: {
        uint32_t len = rd32(p + off), cnt = rd32(p + off + 4);
        fprintf(g_out, "dictionary bytes=%u count=%u\n", len, cnt);
        size_t o = off + 8;
        for (uint32_t i = 0; i < cnt && o < n; i++) {
            const char *k = (const char *)p + o;
            size_t kl = strnlen(k, n - o);
            ind(depth + 1); fprintf(g_out, "\"%s\" = ", k);
            o = al4(o + kl + 1);
            o = xpc_decode(p, n, o, depth + 1, ports);
        }
        return o;
    }
    default:
        fprintf(g_out, "UNKNOWN type 0x%x at 0x%zx\n", t, off - 4);
        return n;
    }
}

static const char *dispname(unsigned d)
{
    switch (d) {
    case 0: return "none";
    case 16: return "RECEIVE(16)";
    case 17: return "SEND(17)";
    case 18: return "SEND_ONCE(18)";
    case 19: return "COPY_SEND(19)";
    case 20: return "MAKE_SEND(20)";
    case 21: return "MAKE_SEND_ONCE(21)";
    default: return "?";
    }
}

static mach_port_t g_recvd[32];
static int g_nrecvd;

static void describe_right(mach_port_t name)
{
    mach_port_type_t ty = 0;
    if (!name) return;
    if (mach_port_type(mach_task_self(), name, &ty) == KERN_SUCCESS)
        fprintf(g_out, " [in our space: recv=%d send=%d sendonce=%d dead=%d]",
                !!(ty & MACH_PORT_TYPE_RECEIVE), !!(ty & MACH_PORT_TYPE_SEND),
                !!(ty & MACH_PORT_TYPE_SEND_ONCE), !!(ty & MACH_PORT_TYPE_DEAD_NAME));
}

static void dump_msg(const char *tag, mach_msg_header_t *h, int with_trailer)
{
    const uint8_t *b = (const uint8_t *)h;
    uint32_t bits = h->msgh_bits;
    fprintf(g_out, "== %s #%d: bits=0x%08x (remote=%s local=%s voucher=%s%s) size=%u remote=0x%x local=0x%x voucher=0x%x id=%d (0x%x)\n",
            tag, g_seq, bits, dispname(bits & 0x1f), dispname((bits >> 8) & 0x1f),
            dispname((bits >> 16) & 0x1f), (bits & MACH_MSGH_BITS_COMPLEX) ? " COMPLEX" : "",
            h->msgh_size, h->msgh_remote_port, h->msgh_local_port, h->msgh_voucher_port,
            h->msgh_id, h->msgh_id);
    size_t off = sizeof(mach_msg_header_t);
    int nports = 0;
    if (bits & MACH_MSGH_BITS_COMPLEX) {
        uint32_t cnt = rd32(b + off);
        fprintf(g_out, "  descriptors: %u\n", cnt);
        off += 4;
        for (uint32_t i = 0; i < cnt && off < h->msgh_size; i++) {
            uint8_t type = b[off + 11];
            if (type == MACH_MSG_PORT_DESCRIPTOR) {
                fprintf(g_out, "  [%u] @%zu PORT name=0x%x disp=%s", i, off, rd32(b + off), dispname(b[off + 10]));
                if (with_trailer && b[off + 10] == MACH_MSG_TYPE_PORT_RECEIVE && g_nrecvd < 32) g_recvd[g_nrecvd++] = rd32(b + off);
                describe_right(rd32(b + off));
                fprintf(g_out, "\n");
                off += 12;
            } else if (type == MACH_MSG_OOL_DESCRIPTOR || type == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) {
                uint64_t a = rd64(b + off);
                uint32_t sz = rd32(b + off + 12);
                fprintf(g_out, "  [%u] @%zu OOL addr=0x%llx size=%u dealloc=%u copy=%u type=%u\n", i, off,
                        (unsigned long long)a, sz, b[off + 8], b[off + 9], type);
                if (a && sz && with_trailer) {
                    hexdump((const uint8_t *)(uintptr_t)a, sz > 2048 ? 2048 : sz, 0);
                    if (sz >= 8 && is_xpc_magic(rd32((const uint8_t *)(uintptr_t)a))) {
                        fprintf(g_out, "  OOL XPC payload: root=");
                        int pp = 0;
                        xpc_decode((const uint8_t *)(uintptr_t)a, sz, 8, 1, &pp);
                    }
                }
                off += 16;
            } else if (type == MACH_MSG_OOL_PORTS_DESCRIPTOR) {
                fprintf(g_out, "  [%u] @%zu OOL_PORTS addr=0x%llx count=%u disp=%s\n", i, off,
                        (unsigned long long)rd64(b + off), rd32(b + off + 12), dispname(b[off + 10]));
                if (with_trailer && rd64(b + off)) {
                    const uint32_t *pn = (const uint32_t *)(uintptr_t)rd64(b + off);
                    for (uint32_t k = 0; k < rd32(b + off + 12) && k < 16; k++) {
                        fprintf(g_out, "      port[%u]=0x%x", k, pn[k]); describe_right(pn[k]); fprintf(g_out, "\n");
                    }
                }
                off += 16;
            } else if (type == MACH_MSG_GUARDED_PORT_DESCRIPTOR) {
                fprintf(g_out, "  [%u] @%zu GUARDED_PORT name=0x%x ctx=0x%llx flags=0x%x disp=%s\n", i, off,
                        rd32(b + off + 12), (unsigned long long)rd64(b + off), b[off + 8] | (b[off + 9] << 8),
                        dispname(b[off + 10]));
                off += 16;
            } else {
                fprintf(g_out, "  [%u] @%zu unknown descriptor type %u\n", i, off, type);
                off += 16;
            }
        }
    }
    size_t end = h->msgh_size;
    if (end > off) {
        fprintf(g_out, "  body @%zu, %zu bytes:\n", off, end - off);
        hexdump(b + off, end - off, off);
    }
    for (size_t o = off; o + 8 <= end; o += 4) {
        if (is_xpc_magic(rd32(b + o))) {
            fprintf(g_out, "  XPC payload @%zu: root=", o);
            xpc_decode(b, end, o + 8, 1, &nports);
            break;
        }
    }
    if (with_trailer) {
        mach_msg_audit_trailer_t *t = (mach_msg_audit_trailer_t *)(b + al4(end));
        if (t->msgh_trailer_size >= sizeof(mach_msg_audit_trailer_t))
            fprintf(g_out, "  trailer: size=%u seqno=%u sender pid=%d\n", t->msgh_trailer_size,
                    t->msgh_seqno, (int)t->msgh_audit.val[5]);
    }
    fflush(g_out);
}

/* ------------------------------------------------------------- answering */

static mach_port_t new_port(int with_send)
{
    mach_port_t p = MACH_PORT_NULL;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &p);
    if (with_send) mach_port_insert_right(mach_task_self(), p, p, MACH_MSG_TYPE_MAKE_SEND);
    return p;
}

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/*
 * YC_REPLY grammar (a ';'-separated list of per-msgh_id rules, first match
 * wins; "*" matches any id):
 *   <id|*>=none            do not answer (keep the reply right)
 *   <id|*>=err:<n>         simple reply, msgh_id = id+100, NDR, RetCode n (36 bytes)
 *   <id|*>=body:<hex>      simple reply, msgh_id = id+100, then these bytes after the header
 *   <id|*>=ports:<k>:<disp>:<hex>  complex reply, k port descriptors (fresh ports,
 *                          disposition MS=make-send, MR=move-receive, MSO=make-send-once),
 *                          then <hex> after the descriptors
 *   <id|*>=id:<n>:...      as above but force msgh_id n (prefix to any form)
 * Default: "*=err:0".
 */
static void answer(mach_msg_header_t *h, const char *spec)
{
    if (h->msgh_remote_port == MACH_PORT_NULL) { fprintf(g_out, "  (no reply port)\n"); return; }
    char rule[2048] = "err:0";
    if (spec) {
        char tmp[8192]; strlcpy(tmp, spec, sizeof tmp);
        char *save = NULL;
        for (char *r = strtok_r(tmp, ";", &save); r; r = strtok_r(NULL, ";", &save)) {
            char *eq = strchr(r, '=');
            if (!eq) continue;
            *eq = 0;
            if (!strcmp(r, "*") || atoi(r) == h->msgh_id) { strlcpy(rule, eq + 1, sizeof rule); break; }
        }
    }
    int rid = h->msgh_id + 100;
    char *rp = rule;
    if (!strncmp(rp, "id:", 3)) { rid = (int)strtol(rp + 3, &rp, 0); if (*rp == ':') rp++; }
    if (!strcmp(rp, "none")) { fprintf(g_out, "  (not answered)\n"); return; }
    uint8_t buf[4096];
    memset(buf, 0, sizeof buf);
    mach_msg_header_t *r = (mach_msg_header_t *)buf;
    size_t n = 24;
    unsigned complex = 0;
    const char *hex = NULL;
    if (!strncmp(rp, "err:", 4)) {
        uint32_t ndr[2] = { 0, 1 }; memcpy(buf + 24, ndr, 8);
        int32_t code = (int32_t)strtol(rp + 4, NULL, 0); memcpy(buf + 32, &code, 4);
        n = 36;
    } else if (!strncmp(rp, "body:", 5)) {
        hex = rp + 5;
    } else if (!strncmp(rp, "ports:", 6)) {
        char *q;
        int k = (int)strtol(rp + 6, &q, 0);
        if (*q == ':') q++;
        unsigned disp = MACH_MSG_TYPE_MAKE_SEND;
        if (!strncmp(q, "MR", 2) && q[2] == ':') { disp = MACH_MSG_TYPE_MOVE_RECEIVE; q += 3; }
        else if (!strncmp(q, "MSO", 3)) { disp = MACH_MSG_TYPE_MAKE_SEND_ONCE; q += 4; }
        else if (!strncmp(q, "MS", 2)) { disp = MACH_MSG_TYPE_MAKE_SEND; q += 3; }
        complex = MACH_MSGH_BITS_COMPLEX;
        *(uint32_t *)(buf + 24) = (uint32_t)k;
        n = 28;
        for (int i = 0; i < k; i++) {
            mach_msg_port_descriptor_t *pd = (mach_msg_port_descriptor_t *)(buf + n);
            pd->name = new_port(0);
            pd->disposition = disp;
            pd->type = MACH_MSG_PORT_DESCRIPTOR;
            fprintf(g_out, "  (reply port descriptor %d = our port 0x%x)\n", i, pd->name);
            n += 12;
        }
        hex = q;
    }
    if (hex) {
        for (const char *c = hex; c[0] && c[1] && n < sizeof buf; c += 2) {
            if (c[0] == ' ' || c[0] == '.') { c--; continue; }
            int a = hexval(c[0]), b = hexval(c[1]);
            if (a < 0 || b < 0) break;
            buf[n++] = (uint8_t)(a * 16 + b);
        }
    }
    r->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSGH_BITS_REMOTE(h->msgh_bits), 0, 0, complex);
    r->msgh_size = (mach_msg_size_t)n;
    r->msgh_remote_port = h->msgh_remote_port;
    r->msgh_local_port = MACH_PORT_NULL;
    r->msgh_id = rid;
    dump_msg("OUR-REPLY", r, 0);
    kern_return_t kr = mach_msg(r, MACH_SEND_MSG | MACH_SEND_TIMEOUT, r->msgh_size, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
    if (kr) fprintf(g_out, "  reply send failed 0x%x\n", kr);
    h->msgh_remote_port = MACH_PORT_NULL; /* consumed */
}

/* --------------------------------------------------------- serve (call mode) */


static void *serve_thread(void *arg)
{
    (void)arg;
    uint8_t *buf = malloc(BUFSZ);
    for (;;) {
        mach_msg_header_t *h = (mach_msg_header_t *)buf;
        kern_return_t kr = mach_msg(h, MACH_RCV_MSG | MACH_RCV_VOUCHER |
                                    MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                                    MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                                    0, BUFSZ, g_pset, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr) { fprintf(g_out, "serve: receive 0x%x\n", kr); return NULL; }
        pthread_mutex_lock(&g_lock);
        g_seq++;
        fprintf(g_out, "-- arrived on %s\n", h->msgh_local_port == g_P ? "P" :
                (h->msgh_local_port == g_P2 ? "P2" : "?"));
        dump_msg("REQUEST", h, 1);
        if (h->msgh_id == MACH_NOTIFY_DEAD_NAME || h->msgh_id == MACH_NOTIFY_NO_SENDERS ||
            h->msgh_id == MACH_NOTIFY_SEND_ONCE || h->msgh_id == MACH_NOTIFY_PORT_DESTROYED) {
            fprintf(g_out, "  (a kernel notification)\n");
        } else {
            answer(h, getenv("YC_REPLY"));
        }
        pthread_mutex_unlock(&g_lock);
    }
}

/* Interposition lives in lsinterpose.c (loaded with DYLD_INSERT_LIBRARIES).
 * It resolves names with our prefix to the port we publish here. */
__attribute__((visibility("default"))) mach_port_t yc_interpose_port;
__attribute__((visibility("default"))) FILE *yc_interpose_out;

/* ------------------------------------------------------------- arguments */

typedef uint64_t (*fn8)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t,
                        uint64_t, uint64_t, uint64_t, uint64_t);

#define MAXOUT 12
static struct { uint8_t *p; size_t n; int idx; } g_outbufs[MAXOUT];
static int g_nout;
static uint32_t g_lastpid;

/*
 * Argument tokens:
 *   P, P2       our ports (send right names in our space)
 *   port:<n>    a raw integer used as a port name
 *   i:<n>       integer
 *   s:<text>    pointer to a NUL-terminated string
 *   v:<a,b,..>  pointer to a NULL-terminated array of strings
 *   b[:<n>]     pointer to an out-buffer of n bytes (default 64), filled with 0xA5
 *   z[:<n>]     like b but zero-filled
 *   n           NULL
 *   q           a global dispatch queue
 *   blk         a block that prints its first four arguments
 *   fd:<n>      the integer n (an fd number)
 */
static uint64_t make_arg(const char *t, int idx)
{
    if (!strcmp(t, "P")) return g_P;
    if (!strcmp(t, "P2")) return g_P2;
    if (!strcmp(t, "B")) { if (!g_B) g_B = new_port(1); fprintf(g_out, "-- B = 0x%x\n", g_B); return g_B; }
    if (!strcmp(t, "LP")) return g_lastpid; /* the pid from the last spawn's out-parameter */
    if (!strcmp(t, "R")) { mach_port_t r = new_port(0); fprintf(g_out, "-- R = 0x%x (receive right only)\n", r); return r; }
    if (!strncmp(t, "port:", 5)) return strtoull(t + 5, NULL, 0);
    if (!strncmp(t, "i:", 2)) return (uint64_t)strtoll(t + 2, NULL, 0);
    if (!strncmp(t, "fd:", 3)) return (uint64_t)strtoll(t + 3, NULL, 0);
    if (!strncmp(t, "s:", 2)) return (uint64_t)(uintptr_t)strdup(t + 2);
    if (!strncmp(t, "v:", 2)) {
        char *c = strdup(t + 2);
        char **v = calloc(64, sizeof(char *));
        int k = 0;
        char *save = NULL;
        for (char *s = strtok_r(c, ",", &save); s && k < 63; s = strtok_r(NULL, ",", &save)) v[k++] = s;
        return (uint64_t)(uintptr_t)v;
    }
    if (t[0] == 'b' || t[0] == 'z') {
        if (!strcmp(t, "blk")) {
            void (^b)(uint64_t, uint64_t, uint64_t, uint64_t) = ^(uint64_t a, uint64_t b2, uint64_t c, uint64_t d) {
                fprintf(g_out, "-- BLOCK called: 0x%llx 0x%llx 0x%llx 0x%llx\n", (unsigned long long)a,
                        (unsigned long long)b2, (unsigned long long)c, (unsigned long long)d);
                fflush(g_out);
            };
            return (uint64_t)(uintptr_t)Block_copy(b);
        }
        size_t n = 64;
        if (t[1] == ':') n = strtoul(t + 2, NULL, 0);
        uint8_t *p = malloc(n);
        memset(p, t[0] == 'b' ? 0xA5 : 0, n);
        if (g_nout < MAXOUT) { g_outbufs[g_nout].p = p; g_outbufs[g_nout].n = n; g_outbufs[g_nout].idx = idx; g_nout++; }
        return (uint64_t)(uintptr_t)p;
    }
    if (!strcmp(t, "n")) return 0;
    if (!strcmp(t, "q")) return (uint64_t)(uintptr_t)dispatch_get_global_queue(0, 0);
    fprintf(g_out, "unknown argument token %s\n", t);
    exit(2);
}

static void *g_lib;

static fn8 get_fn(const char *name)
{
    void *f = dlsym(g_lib, name);
    if (!f) { fprintf(g_out, "dlsym %s: %s\n", name, dlerror()); exit(2); }
    return (fn8)f;
}

static void open_lib(void)
{
    const char *lib = getenv("YC_LIB");
    if (!lib) { fprintf(stderr, "set YC_LIB to the liblaunch_sim.dylib path\n"); exit(2); }
    g_lib = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    if (!g_lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); exit(2); }
}


/* ------------------------------------------- our own control-channel writer */

/* Messages built by our code from specs/simulator/launch-sim-control.md (no
 * library involved), sent straight to launchd_sim's service port, to check
 * that the spec is sufficient. */
static mach_port_t g_service_send;

static void raw_put_name(uint8_t *b, size_t *n, const char *name)
{
    uint32_t ndr[2] = { 0, 1 };
    memcpy(b + *n, ndr, 8); *n += 8;
    memset(b + *n, 0, 128);
    strncpy((char *)b + *n, name, 127);
    *n += 128;
}

static void raw_send(uint8_t *b, size_t n, int id, int complex, const char *what)
{
    mach_msg_header_t *h = (mach_msg_header_t *)b;
    mach_port_t reply = mig_get_reply_port();
    h->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE, 0,
                                      complex ? MACH_MSGH_BITS_COMPLEX : 0);
    h->msgh_size = (mach_msg_size_t)n;
    h->msgh_remote_port = g_service_send;
    h->msgh_local_port = reply;
    h->msgh_voucher_port = 0;
    h->msgh_id = id;
    pthread_mutex_lock(&g_lock);
    fprintf(g_out, "-- RAW %s: sending our own %d (%zu bytes)\n", what, id, n);
    dump_msg("RAW-REQUEST", h, 0);
    pthread_mutex_unlock(&g_lock);
    uint8_t rb[1024];
    mach_msg_header_t *r = (mach_msg_header_t *)rb;
    memcpy(rb, b, 24);
    kern_return_t kr = mach_msg(h, MACH_SEND_MSG | MACH_RCV_MSG, (mach_msg_size_t)n, sizeof rb, reply,
                                MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    pthread_mutex_lock(&g_lock);
    if (kr) fprintf(g_out, "-- RAW %s: mach_msg 0x%x\n", what, kr);
    else dump_msg("RAW-REPLY", h, 0);
    pthread_mutex_unlock(&g_lock);
    (void)r;
}

static uint32_t g_rawpid;

static void raw_call(int argc, char **argv)
{
    uint8_t b[8192];
    memset(b, 0, sizeof b);
    size_t n = 24;
    if (!strcmp(argv[0], "rawbind") && argc > 1) {           /* 700: one port, no body */
        *(uint32_t *)(b + 24) = 1;
        mach_msg_port_descriptor_t *d = (mach_msg_port_descriptor_t *)(b + 28);
        d->name = (mach_port_t)make_arg(argv[1], 0); d->disposition = MACH_MSG_TYPE_COPY_SEND; d->type = MACH_MSG_PORT_DESCRIPTOR;
        n = 40;
        raw_send(b, n, 700, 1, "bind");
    } else if (!strcmp(argv[0], "rawreg") && argc > 2) {     /* 701: one port, NDR, name[128] */
        *(uint32_t *)(b + 24) = 1;
        mach_msg_port_descriptor_t *d = (mach_msg_port_descriptor_t *)(b + 28);
        d->name = (mach_port_t)make_arg(argv[2], 0); d->disposition = MACH_MSG_TYPE_COPY_SEND; d->type = MACH_MSG_PORT_DESCRIPTOR;
        n = 40;
        raw_put_name(b, &n, argv[1]);
        raw_send(b, n, 701, 1, "register");
    } else if ((!strcmp(argv[0], "rawfind") || !strcmp(argv[0], "rawgetenv") || !strcmp(argv[0], "rawunreg")) && argc > 1) {
        raw_put_name(b, &n, argv[1]);
        int id = !strcmp(argv[0], "rawfind") ? 702 : (!strcmp(argv[0], "rawgetenv") ? 703 : 709);
        raw_send(b, n, id, 0, argv[0] + 3);
    } else if (!strcmp(argv[0], "rawwait") && argc > 1) {    /* 705: NDR, pid */
        uint32_t ndr[2] = { 0, 1 }; memcpy(b + 24, ndr, 8);
        uint32_t pid = !strcmp(argv[1], "RP") ? g_rawpid : (uint32_t)strtoul(argv[1], NULL, 0);
        memcpy(b + 32, &pid, 4);
        raw_send(b, 36, 705, 0, "waitpid");
    } else if (!strcmp(argv[0], "rawdeath")) {               /* 706: one receive right */
        mach_port_t p = new_port(1);
        *(uint32_t *)(b + 24) = 1;
        mach_msg_port_descriptor_t *d = (mach_msg_port_descriptor_t *)(b + 28);
        d->name = p; d->disposition = MACH_MSG_TYPE_MOVE_RECEIVE; d->type = MACH_MSG_PORT_DESCRIPTOR;
        fprintf(g_out, "-- rawdeath: we keep send right 0x%x\n", p);
        raw_send(b, 40, 706, 1, "death");
        mach_port_type_t ty; mach_port_type(mach_task_self(), p, &ty);
        fprintf(g_out, "-- rawdeath: our name 0x%x now: send=%d dead=%d\n", p, !!(ty & MACH_PORT_TYPE_SEND), !!(ty & MACH_PORT_TYPE_DEAD_NAME));
    } else if (!strcmp(argv[0], "rawspawn") && argc > 7) {
        /* rawspawn <cwd|-> <suspend 0|1> <cputype|0> <stdin fd> <stdout fd> <path> <a,b,..|-> <K=V,..|->  */
        const char *cwd = strcmp(argv[1], "-") ? argv[1] : NULL;
        int susp = atoi(argv[2]);
        uint32_t cpu = (uint32_t)strtoul(argv[3], NULL, 0);
        int fin = atoi(argv[4]), fout = atoi(argv[5]);
        const char *path = argv[6];
        const char *av = argc > 7 ? argv[7] : "-";
        const char *ev = argc > 8 ? argv[8] : "-";
        uint8_t blob[4096]; memset(blob, 0, sizeof blob);
        uint32_t *w = (uint32_t *)blob;
        size_t r = 156; /* region start */
        size_t ro = 0;  /* region offset */
#define PUTS(str) do { size_t l_ = strlen(str) + 1; memcpy(blob + r + ro, (str), l_); ro += l_; } while (0)
        PUTS(path);
        if (strcmp(av, "-")) {
            char tmp[2048]; strlcpy(tmp, av, sizeof tmp);
            w[3] = (uint32_t)ro; uint32_t c = 0; char *sv = NULL;
            for (char *t = strtok_r(tmp, ",", &sv); t; t = strtok_r(NULL, ",", &sv)) { PUTS(t); c++; }
            w[2] = c;
        }
        if (strcmp(ev, "-")) {
            char tmp[2048]; strlcpy(tmp, ev, sizeof tmp);
            w[5] = (uint32_t)ro; uint32_t c = 0; char *sv = NULL;
            for (char *t = strtok_r(tmp, ",", &sv); t; t = strtok_r(NULL, ",", &sv)) { PUTS(t); c++; }
            w[4] = c;
        }
        if (cwd) { w[14] = (uint32_t)ro; PUTS(cwd); }
        if (cpu) { w[6] = 1; w[7] = (uint32_t)ro; memcpy(blob + r + ro, &cpu, 4); uint32_t any = 0xffffffff; memcpy(blob + r + ro + 4, &any, 4); ro += 8; }
#undef PUTS
        w[23] = susp ? 1 : 0;
        w[24] = getenv("YC_W24") ? (uint32_t)strtoul(getenv("YC_W24"), NULL, 0) : 0x400;
        w[0] = (uint32_t)(r + ro);
        uint32_t total = w[0];
        *(uint32_t *)(b + 24) = 4;
        mach_msg_ool_descriptor_t *o = (mach_msg_ool_descriptor_t *)(b + 28);
        o->address = blob; o->size = total; o->deallocate = 0; o->copy = MACH_MSG_VIRTUAL_COPY; o->type = MACH_MSG_OOL_DESCRIPTOR;
        int fds[3] = { fin, fout, fout };
        for (int i = 0; i < 3; i++) {
            mach_msg_port_descriptor_t *d = (mach_msg_port_descriptor_t *)(b + 44 + 12 * i);
            mach_port_t fp = MACH_PORT_NULL;
            if (fds[i] >= 0) fileport_makeport(fds[i], &fp);
            d->name = fp; d->disposition = MACH_MSG_TYPE_MOVE_SEND; d->type = MACH_MSG_PORT_DESCRIPTOR;
        }
        uint32_t ndr[2] = { 0, 1 }; memcpy(b + 80, ndr, 8);
        memcpy(b + 88, &total, 4);
        n = 92;
        fprintf(g_out, "-- rawspawn blob (%u bytes):\n", total);
        hexdump(blob, total, 0);
        raw_send(b, n, 704, 1, "spawn");
        mach_msg_header_t *h = (mach_msg_header_t *)b;
        if (h->msgh_size == 40) g_rawpid = *(uint32_t *)(b + 36);
    } else if (!strcmp(argv[0], "rawid") && argc > 1) {      /* an id with an NDR-only body */
        uint32_t ndr[2] = { 0, 1 }; memcpy(b + 24, ndr, 8);
        raw_send(b, 32, (int)strtol(argv[1], NULL, 0), 0, "unknown-id");
    } else {
        fprintf(g_out, "-- unknown raw call %s\n", argv[0]);
    }
    fflush(g_out);
}

static void do_call(int argc, char **argv)
{
    if (!strncmp(argv[0], "raw", 3)) { raw_call(argc, argv); return; }
    if (!strcmp(argv[0], "destroyP")) { /* pseudo-call: destroy P's receive right (a peer death) */
        kern_return_t kr = mach_port_mod_refs(mach_task_self(), g_P, MACH_PORT_RIGHT_RECEIVE, -1);
        fprintf(g_out, "-- destroyed receive right of P (0x%x): 0x%x\n", g_P, kr);
        fflush(g_out);
        return;
    }
    if (!strcmp(argv[0], "destroyB")) { /* pseudo-call: destroy B's receive right */
        kern_return_t kr = mach_port_mod_refs(mach_task_self(), g_B, MACH_PORT_RIGHT_RECEIVE, -1);
        fprintf(g_out, "-- destroyed receive right of B (0x%x): 0x%x\n", g_B, kr);
        fflush(g_out);
        return;
    }
    if (!strcmp(argv[0], "destroyRecv")) { /* pseudo-call: destroy every receive right we were sent */
        for (int i = 0; i < g_nrecvd; i++) {
            kern_return_t kr = mach_port_mod_refs(mach_task_self(), g_recvd[i], MACH_PORT_RIGHT_RECEIVE, -1);
            fprintf(g_out, "-- destroyed received receive right 0x%x: 0x%x\n", g_recvd[i], kr);
        }
        g_nrecvd = 0;
        fflush(g_out);
        return;
    }
    if (!strcmp(argv[0], "sh")) { /* pseudo-call: run a host shell command (observation only) */
        char cmd[4096] = "";
        for (int i = 1; i < argc; i++) { strlcat(cmd, argv[i], sizeof cmd); strlcat(cmd, " ", sizeof cmd); }
        fprintf(g_out, "-- sh: %s\n", cmd);
        fflush(g_out);
        system(cmd);
        return;
    }
    if (!strcmp(argv[0], "sleep") && argc > 1) { usleep((useconds_t)(atof(argv[1]) * 1e6)); return; }
    fn8 f = get_fn(argv[0]);
    uint64_t a[12] = { 0 };
    g_nout = 0;
    for (int i = 1; i < argc && i <= 12; i++) a[i - 1] = make_arg(argv[i], i - 1);
    fprintf(g_out, "-- CALL %s(", argv[0]);
    for (int i = 1; i < argc; i++) fprintf(g_out, "%s%s", i > 1 ? ", " : "", argv[i]);
    fprintf(g_out, ")  [P=0x%x P2=0x%x]\n", g_P, g_P2);
    mach_port_urefs_t before = 0;
    mach_port_get_refs(mach_task_self(), g_P2, MACH_PORT_RIGHT_SEND, &before);
    fflush(g_out);
    uint64_t r = f(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11]);
    pthread_mutex_lock(&g_lock);
    fprintf(g_out, "-- RETURN %s = %lld (0x%llx)\n", argv[0], (long long)r, (unsigned long long)r);
    mach_port_urefs_t after = 0;
    mach_port_get_refs(mach_task_self(), g_P2, MACH_PORT_RIGHT_SEND, &after);
    fprintf(g_out, "   P2 send urefs before=%u after=%u\n", before, after);
    if (r > 0x100000000ULL && r < 0x0000800000000000ULL)
        fprintf(g_out, "   return as char* -> \"%.300s\"\n", (const char *)(uintptr_t)r);
    for (int i = 0; i < g_nout; i++) {
        fprintf(g_out, "-- out-buffer arg%d after call:\n", g_outbufs[i].idx);
        hexdump(g_outbufs[i].p, g_outbufs[i].n > 64 ? 64 : g_outbufs[i].n, 0);
        uint64_t v = rd64(g_outbufs[i].p);
        if (v != 0xA5A5A5A5A5A5A5A5ULL && v > 0x100000000ULL && v < 0x0000800000000000ULL) {
            /* looks like a pointer: try it as a C string */
            const char *s = (const char *)(uintptr_t)v;
            fprintf(g_out, "   as char* -> \"%.200s\"\n", s);
        }
        uint32_t w = rd32(g_outbufs[i].p);
        if (!strcmp(argv[0], "launch_sim_spawn") && g_outbufs[i].idx == 10) g_lastpid = w;
        if (w != 0xA5A5A5A5 && w) { fprintf(g_out, "   first u32 0x%x", w); describe_right(w); fprintf(g_out, "\n"); }
    }
    fflush(g_out);
    pthread_mutex_unlock(&g_lock);
}

static void *watchdog(void *arg)
{
    int s = (int)(intptr_t)arg;
    sleep((unsigned)s);
    pthread_mutex_lock(&g_lock);
    fprintf(g_out, "-- TIMEOUT after %d s (call did not return)\n", s);
    fflush(g_out);
    _exit(3);
}

static int mode_call(int argc, char **argv)
{
    open_lib();
    g_P = new_port(1);
    g_P2 = new_port(1);
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_PORT_SET, &g_pset);
    mach_port_move_member(mach_task_self(), g_P, g_pset);
    mach_port_move_member(mach_task_self(), g_P2, g_pset);
    yc_interpose_port = g_P; yc_interpose_out = g_out;
    if (getenv("YC_SETBS")) {
        bootstrap_port = g_P2;
        task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, g_P2);
    }
    pthread_t t;
    pthread_create(&t, NULL, serve_thread, NULL);
    const char *to = getenv("YC_TIMEOUT");
    pthread_t w;
    pthread_create(&w, NULL, watchdog, (void *)(intptr_t)(to ? atoi(to) : 4));
    /* several calls separated by "--" */
    int start = 0;
    for (int i = 0; i <= argc; i++) {
        if (i == argc || !strcmp(argv[i], "--")) {
            if (i > start) do_call(i - start, argv + start);
            usleep(300000);
            start = i + 1;
        }
    }
    usleep(500000);
    return 0;
}

/* ------------------------------------------------------------- host mode */

static mach_port_t g_fake_bs, g_relay, g_prequeue_reply;

/* The host bootstrap: answer 708 as in bootstrap-wire.md §5.2; log the rest. */
static void *bs_thread(void *arg)
{
    (void)arg;
    uint8_t *buf = malloc(BUFSZ);
    for (;;) {
        mach_msg_header_t *h = (mach_msg_header_t *)buf;
        kern_return_t kr = mach_msg(h, MACH_RCV_MSG | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                                    MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                                    0, BUFSZ, g_fake_bs, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr) { fprintf(g_out, "bs: receive 0x%x\n", kr); return NULL; }
        pthread_mutex_lock(&g_lock);
        g_seq++;
        dump_msg("HOST-BOOTSTRAP-REQUEST", h, 1);
        if (h->msgh_id == 708 && h->msgh_remote_port) {
            mach_port_t sp = new_port(1); /* receive right goes to launchd_sim, we keep send */
            const char *pq = getenv("YC_PREQUEUE");
            if (pq) {
                /* Queue a register request (701) on the port while we still hold its
                 * receive right; the message moves with the right in the 808 reply. */
                struct { mach_msg_header_t h; mach_msg_body_t b; mach_msg_port_descriptor_t d;
                         uint32_t ndr[2]; char name[128]; } q;
                memset(&q, 0, sizeof q);
                mach_port_t rp = new_port(0);
                q.h.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_MAKE_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE, 0, MACH_MSGH_BITS_COMPLEX);
                q.h.msgh_size = sizeof q;
                q.h.msgh_remote_port = sp;
                q.h.msgh_local_port = rp;
                q.h.msgh_id = 701;
                q.b.msgh_descriptor_count = 1;
                q.d.name = g_P2; q.d.disposition = MACH_MSG_TYPE_COPY_SEND; q.d.type = MACH_MSG_PORT_DESCRIPTOR;
                q.ndr[1] = 1;
                strlcpy(q.name, pq, sizeof q.name);
                kr = mach_msg(&q.h, MACH_SEND_MSG, sizeof q, 0, 0, 0, 0);
                fprintf(g_out, "  (host) pre-queued 701 for %s on the service port before 808: 0x%x (reply port 0x%x)\n", pq, kr, rp);
                g_prequeue_reply = rp;
            }
            struct { mach_msg_header_t h; mach_msg_body_t b; mach_msg_port_descriptor_t d; } r;
            memset(&r, 0, sizeof r);
            r.h.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSGH_BITS_REMOTE(h->msgh_bits), 0, 0, MACH_MSGH_BITS_COMPLEX);
            r.h.msgh_size = sizeof r;
            r.h.msgh_remote_port = h->msgh_remote_port;
            r.h.msgh_id = 808;
            r.b.msgh_descriptor_count = 1;
            r.d.name = sp; r.d.disposition = MACH_MSG_TYPE_MOVE_RECEIVE; r.d.type = MACH_MSG_PORT_DESCRIPTOR;
            kr = mach_msg(&r.h, MACH_SEND_MSG, sizeof r, 0, 0, 0, 0);
            fprintf(g_out, "  (host) 808 reply sent (0x%x); service port send right = 0x%x\n", kr, sp);
            g_service_send = sp;
        } else if (h->msgh_remote_port) {
            /* a pipe request: answer {error: 1102/3/45} as a minimal host */
            unsigned routine = h->msgh_id & 0xffff;
            int64_t err = (routine == 207) ? 1102 : (routine == 804 ? 3 : 45);
            uint8_t rb[128]; memset(rb, 0, sizeof rb);
            mach_msg_header_t *r = (mach_msg_header_t *)rb;
            size_t n = 24;
            uint32_t v;
            v = 0x7870633f; memcpy(rb + n, &v, 4); n += 4;
            v = 5; memcpy(rb + n, &v, 4); n += 4;
            v = 0xf000; memcpy(rb + n, &v, 4); n += 4;
            v = 4 + 8 + 4 + 8; memcpy(rb + n, &v, 4); n += 4;
            v = 1; memcpy(rb + n, &v, 4); n += 4;
            memcpy(rb + n, "error\0\0\0", 8); n += 8;
            v = 0x3000; memcpy(rb + n, &v, 4); n += 4;
            memcpy(rb + n, &err, 8); n += 8;
            r->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSGH_BITS_REMOTE(h->msgh_bits), 0, 0, 0);
            r->msgh_size = (mach_msg_size_t)n;
            r->msgh_remote_port = h->msgh_remote_port;
            r->msgh_id = 0x20000000;
            mach_msg(r, MACH_SEND_MSG | MACH_SEND_TIMEOUT, r->msgh_size, 0, 0, 1000, 0);
        }
        pthread_mutex_unlock(&g_lock);
    }
}

/* Relay: what the library sends to M goes to the real service port S, with
 * our own reply port; launchd_sim's reply is dumped and returned. Port-bearing
 * descriptors are moved on unchanged (we hold the rights in between). */
static void fix_ool_for_resend(uint8_t *b)
{
    mach_msg_header_t *h = (mach_msg_header_t *)b;
    if (!(h->msgh_bits & MACH_MSGH_BITS_COMPLEX)) return;
    size_t off = 28;
    uint32_t cnt = rd32(b + 24);
    for (uint32_t i = 0; i < cnt; i++) {
        uint8_t type = b[off + 11];
        if (type == MACH_MSG_PORT_DESCRIPTOR) {
            /* received dispositions: 16 recv -> move recv, 17 send -> move send, 18 so -> move so */
            off += 12; continue;
        }
        if (type == MACH_MSG_OOL_DESCRIPTOR || type == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) {
            b[off + 8] = 1; b[off + 9] = MACH_MSG_VIRTUAL_COPY;
        }
        if (type == MACH_MSG_OOL_PORTS_DESCRIPTOR) { b[off + 8] = 1; }
        off += 16;
    }
}

static void *relay_thread(void *arg)
{
    (void)arg;
    uint8_t *req = malloc(BUFSZ), *rep = malloc(BUFSZ);
    mach_port_t myreply = new_port(0);
    for (;;) {
        mach_msg_header_t *h = (mach_msg_header_t *)req;
        kern_return_t kr = mach_msg(h, MACH_RCV_MSG | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                                    MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                                    0, BUFSZ, g_relay, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr) { fprintf(g_out, "relay: receive 0x%x\n", kr); return NULL; }
        pthread_mutex_lock(&g_lock);
        g_seq++;
        dump_msg("CTL-REQUEST", h, 1);
        pthread_mutex_unlock(&g_lock);
        if (getenv("YC_RELAY_DROP") && atoi(getenv("YC_RELAY_DROP")) == h->msgh_id) {
            fprintf(g_out, "  (dropped by YC_RELAY_DROP)\n"); continue;
        }
        mach_port_t orig_reply = h->msgh_remote_port;
        unsigned orig_reply_type = MACH_MSGH_BITS_REMOTE(h->msgh_bits);
        unsigned complex = h->msgh_bits & MACH_MSGH_BITS_COMPLEX;
        int want_reply = (orig_reply != MACH_PORT_NULL);
        h->msgh_remote_port = g_service_send;
        h->msgh_local_port = want_reply ? myreply : MACH_PORT_NULL;
        h->msgh_voucher_port = MACH_PORT_NULL;
        h->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND,
                                          want_reply ? MACH_MSG_TYPE_MAKE_SEND_ONCE : 0, 0, complex);
        fix_ool_for_resend(req);
        kr = mach_msg(h, MACH_SEND_MSG, h->msgh_size, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
        if (kr) { fprintf(g_out, "  forward failed 0x%x\n", kr); continue; }
        if (!want_reply) continue;
        mach_msg_header_t *r = (mach_msg_header_t *)rep;
        const char *rt = getenv("YC_RELAY_TIMEOUT_MS");
        kr = mach_msg(r, MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                      MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT), 0, BUFSZ, myreply,
                      rt ? atoi(rt) : 30000, MACH_PORT_NULL);
        pthread_mutex_lock(&g_lock);
        if (kr) {
            fprintf(g_out, "  reply receive failed 0x%x (forwarding nothing; the caller's reply right is dropped)\n", kr);
            mach_port_deallocate(mach_task_self(), orig_reply);
            pthread_mutex_unlock(&g_lock);
            continue;
        }
        dump_msg("CTL-REPLY", r, 1);
        pthread_mutex_unlock(&g_lock);
        unsigned rcomplex = r->msgh_bits & MACH_MSGH_BITS_COMPLEX;
        r->msgh_remote_port = orig_reply;
        r->msgh_local_port = MACH_PORT_NULL;
        r->msgh_voucher_port = MACH_PORT_NULL;
        r->msgh_bits = MACH_MSGH_BITS_SET(orig_reply_type == MACH_MSG_TYPE_PORT_SEND_ONCE ?
                                          MACH_MSG_TYPE_MOVE_SEND_ONCE : MACH_MSG_TYPE_MOVE_SEND, 0, 0, rcomplex);
        fix_ool_for_resend(rep);
        kr = mach_msg(r, MACH_SEND_MSG, r->msgh_size, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
        if (kr) fprintf(g_out, "  reply return failed 0x%x\n", kr);
        fflush(g_out);
    }
}

static char **load_env(void)
{
    const char *f = getenv("YC_ENVFILE");
    if (!f) return environ;
    FILE *fp = fopen(f, "r");
    if (!fp) { fprintf(g_out, "cannot open %s\n", f); exit(2); }
    char **env = calloc(300, sizeof(char *));
    char line[8192];
    int n = 0;
    while (n < 290 && fgets(line, sizeof line, fp)) {
        line[strcspn(line, "\n")] = 0;
        if (line[0]) env[n++] = strdup(line);
    }
    fclose(fp);
    return env;
}

/* Tokenize a script line in place (spaces separate; no quoting). */
static int split(char *line, char **av, int max)
{
    int n = 0;
    char *save = NULL;
    for (char *t = strtok_r(line, " \t", &save); t && n < max; t = strtok_r(NULL, " \t", &save)) av[n++] = t;
    return n;
}

static int mode_host(int argc, char **argv)
{
    if (argc < 2) return 2;
    open_lib();
    char **env = load_env();
    g_fake_bs = new_port(1);
    g_relay = new_port(1);
    g_P = g_relay;
    g_P2 = new_port(1);
    /* P2 is the "host-side endpoint" we register; serve it to see guest messages. */
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_PORT_SET, &g_pset);
    mach_port_move_member(mach_task_self(), g_P2, g_pset);
    pthread_t t1, t2, t3;
    pthread_create(&t1, NULL, bs_thread, NULL);
    pthread_create(&t2, NULL, relay_thread, NULL);
    pthread_create(&t3, NULL, serve_thread, NULL);

    /* environment plus the holding-tank variable */
    char **e2 = calloc(300, sizeof(char *));
    int n = 0;
    for (; env[n] && n < 290; n++) e2[n] = env[n];
    char *tankslot = malloc(256);
    e2[n++] = tankslot; e2[n] = NULL;

    mach_port_t real_bs = MACH_PORT_NULL;
    task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &real_bs);
    task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, g_fake_bs);
    pid_t c1 = fork();
    if (c1 == 0) {
        pid_t c2 = fork();
        if (c2 == 0) { if (getenv("YC_TANK_SLEEP")) sleep((unsigned)atoi(getenv("YC_TANK_SLEEP"))); _exit(0); }
        snprintf(tankslot, 256, "XPC_SIMULATOR_HOLDING_TANK_HACK=%d", c2);
        int nul = open("/dev/null", O_RDWR);
        dup2(nul, 0); dup2(nul, 1);
        const char *errf = getenv("YC_SIM_STDERR");
        if (errf) { int ef = open(errf, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (ef >= 0) dup2(ef, 2); }
        chdir("/");
        char *av[] = { "launchd_sim", argv[1], NULL };
        execve(argv[0], av, e2);
        _exit(127);
    }
    task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, real_bs);
    fprintf(g_out, "-- launchd_sim pid %d\n", c1);
    fflush(g_out);
    for (int i = 0; i < 100 && !g_service_send; i++) usleep(50000);
    if (!g_service_send) { fprintf(g_out, "-- no 708 from launchd_sim\n"); kill(c1, SIGKILL); return 1; }
    if (g_prequeue_reply) {
        uint8_t rb[256];
        mach_msg_header_t *r = (mach_msg_header_t *)rb;
        kern_return_t kr = mach_msg(r, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof rb, g_prequeue_reply, 10000, 0);
        pthread_mutex_lock(&g_lock);
        if (kr) fprintf(g_out, "-- pre-queued 701: no reply 0x%x\n", kr);
        else dump_msg("PREQUEUE-REPLY", r, 0);
        pthread_mutex_unlock(&g_lock);
    }
    const char *pre = getenv("YC_PRE_SLEEP_MS");
    usleep((useconds_t)(pre ? atoi(pre) : 1500) * 1000);

    if (getenv("YC_DIRECT")) g_P = g_service_send; /* no relay: the library talks to S */
    yc_interpose_port = g_P; yc_interpose_out = g_out;
    const char *script = getenv("YC_SCRIPT");
    if (script) {
        FILE *fp = fopen(script, "r");
        char line[4096];
        while (fp && fgets(line, sizeof line, fp)) {
            line[strcspn(line, "\n")] = 0;
            if (!line[0] || line[0] == '#') continue;
            if (!strncmp(line, "sleep ", 6)) { usleep((useconds_t)(atof(line + 6) * 1e6)); continue; }
            if (!strncmp(line, "echo ", 5)) { fprintf(g_out, "-- %s\n", line + 5); continue; }
            char *av[16];
            int ac = split(line, av, 16);
            do_call(ac, av);
            usleep(200000);
        }
        if (fp) fclose(fp);
    }
    const char *ts = getenv("YC_SECONDS");
    sleep(ts ? (unsigned)atoi(ts) : 3);
    kill(c1, SIGKILL);
    int st = 0;
    waitpid(c1, &st, 0);
    usleep(200000);
    fprintf(g_out, "-- launchd_sim exited status=0x%x\n", st);
    return 0;
}

int main(int argc, char **argv)
{
    g_out = stdout;
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 3) { fprintf(stderr, "usage: lsprobe call <fn> [args] | lsprobe host <launchd_sim> <plist>\n"); return 2; }
    if (!strcmp(argv[1], "call")) return mode_call(argc - 2, argv + 2);
    if (!strcmp(argv[1], "host")) return mode_host(argc - 2, argv + 2);
    return 2;
}
