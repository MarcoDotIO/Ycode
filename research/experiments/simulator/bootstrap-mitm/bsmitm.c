/*
 * Ycode research probe: a man-in-the-middle on this process's OWN bootstrap
 * traffic (or on the traffic of a child it spawns). Original Ycode code,
 * written for specs/simulator/bootstrap-wire.md. Contains no Apple code.
 *
 * Modes:
 *   bsmitm self  <tests>   swap our own bootstrap port for a port we own, run
 *                          the tests on the main thread, relay on a 2nd thread.
 *   bsmitm spawn <tests>   make a port, posix_spawn ourselves ("child <tests>")
 *                          with that port as the child's TASK_BOOTSTRAP_PORT and
 *                          relay everything the child sends, from its start.
 *   bsmitm exec <path> [args...]   like spawn, but the child runs <path>.
 *   bsmitm serve <path> [args...]  like exec, but we do NOT forward: we answer
 *                          nothing and only record what arrives (for programs
 *                          that expect to own their bootstrap, e.g. an init).
 *   bsmitm host <path> [args...]   like serve, but we answer as a minimal host
 *                          bootstrap: check-in (206/805) gets a fresh receive
 *                          right, look-up gets 1102 (207) or 3 (804), anything
 *                          else gets error 45. Encodes replies in the format
 *                          observed in the relay captures.
 *   bsmitm hostfork <path> [args...]  like host, but the program gets a child
 *                          process of its own first (see fork_chain).
 * Environment knobs: YC_ENVFILE (KEY=VALUE lines for the child), YC_EXE (the
 * executable path when argv[0] differs), YC_SECONDS (serve/host run time).
 *
 * Every message received on the fake bootstrap port is dumped (header,
 * dispositions as received, descriptors, body hex), forwarded to the real
 * bootstrap port with our own reply port, the reply is dumped, and the reply
 * is sent back to the original reply right.
 */
#include <mach/mach.h>
#include <mach/message.h>
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <spawn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <stdint.h>

extern char **environ;

/* Public bootstrap API (declared in the macOS SDK's servers/bootstrap.h; the
 * iOS simulator SDK does not ship that header, the functions exist). */
typedef char ycode_name_t[128];
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
extern kern_return_t bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *sp);
extern kern_return_t bootstrap_register(mach_port_t bp, const char *name, mach_port_t sp);
extern kern_return_t bootstrap_create_service(mach_port_t bp, const char *name, mach_port_t *sp);
extern kern_return_t bootstrap_parent(mach_port_t bp, mach_port_t *pp);
/* The SDK marks this unavailable on iOS; the symbol exists in the simulator's
 * libxpc. We bind to it under our own name. */
extern xpc_connection_t ycode_xpc_create_mach_service(const char *name, dispatch_queue_t q,
                                                     uint64_t flags)
    __asm__("_xpc_connection_create_mach_service");
#define YC_LISTENER   (1ULL << 0)
#define YC_PRIVILEGED (1ULL << 1)
/* audit_token_t: val[5] is the pid (public BSM layout). */
static pid_t token_pid(audit_token_t t) { return (pid_t)t.val[5]; }

/* Private SPI, declared from the old open-source launchd headers
 * (liblaunch/bootstrap_priv.h, launchd-842.92.1). */
extern kern_return_t bootstrap_look_up2(mach_port_t bp, const char *name,
                                        mach_port_t *sp, pid_t pid, uint64_t flags);
extern kern_return_t bootstrap_check_in2(mach_port_t bp, const char *name,
                                         mach_port_t *sp, uint64_t flags);
extern kern_return_t bootstrap_look_up3(mach_port_t bp, const char *name,
                                        mach_port_t *sp, pid_t pid,
                                        const unsigned char *uuid, uint64_t flags);

static mach_port_t g_real_bs = MACH_PORT_NULL;
static mach_port_t g_fake_bs = MACH_PORT_NULL;
static int g_serve_only = 0;
static int g_seq = 0;
static FILE *g_out;

#define BUFSZ (256 * 1024)

/* ------------------------------------------------------------------ dump */

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

static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }

/* Our own decoder of the XPC object stream, written from captures. */
static size_t xpc_decode(const uint8_t *p, size_t n, size_t off, int depth, int *ports);

/* Observed magic: the bytes "?cpx" or "@cpx" (little-endian u32). */
static int is_xpc_magic(uint32_t m) { return m == 0x7870633f || m == 0x78706340; }

static size_t al4(size_t x) { return (x + 3) & ~(size_t)3; }

static void ind(int d) { for (int i = 0; i < d; i++) fprintf(g_out, "  "); }

static size_t xpc_decode(const uint8_t *p, size_t n, size_t off, int depth, int *ports)
{
    if (off + 4 > n) { ind(depth); fprintf(g_out, "<truncated>\n"); return n; }
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
                   if (off + 4 + l > n) { /* large data: no inline bytes, carried by a port */
                       fprintf(g_out, "data len=%u (not inline; port #%d)\n", l, (*ports)++); return off + 4; }
                   fprintf(g_out, "data len=%u\n", l);
                   hexdump(p + off + 4, l > 256 ? 256 : l, off + 4); return al4(off + 4 + l); }
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
            ind(depth + 1); fprintf(g_out, "\"%s\" (key@0x%zx) = ", k, o);
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
        for (uint32_t i = 0; i < cnt; i++) {
            uint8_t type = b[off + 11];
            if (type == MACH_MSG_PORT_DESCRIPTOR) {
                fprintf(g_out, "  [%u] @%zu PORT name=0x%x disp=%s\n", i, off, rd32(b + off), dispname(b[off + 10]));
                off += 12;
            } else if (type == MACH_MSG_OOL_DESCRIPTOR || type == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) {
                uint64_t a = rd64(b + off);
                uint32_t sz = rd32(b + off + 12);
                fprintf(g_out, "  [%u] @%zu OOL addr=0x%llx size=%u dealloc=%u copy=%u type=%u\n", i, off,
                        (unsigned long long)a, sz, b[off + 8], b[off + 9], type);
                if (a && sz) {
                    hexdump((const uint8_t *)(uintptr_t)a, sz > 4096 ? 4096 : sz, 0);
                    if (sz >= 8 && is_xpc_magic(rd32((const uint8_t *)(uintptr_t)a))) {
                        fprintf(g_out, "  OOL XPC payload: magic=0x%x version=%u root=",
                                rd32((const uint8_t *)(uintptr_t)a), rd32((const uint8_t *)(uintptr_t)a + 4));
                        int pp = 0;
                        xpc_decode((const uint8_t *)(uintptr_t)a, sz, 8, 1, &pp);
                    }
                }
                off += 16;
            } else if (type == MACH_MSG_OOL_PORTS_DESCRIPTOR) {
                fprintf(g_out, "  [%u] @%zu OOL_PORTS addr=0x%llx count=%u disp=%s\n", i, off,
                        (unsigned long long)rd64(b + off), rd32(b + off + 12), dispname(b[off + 10]));
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
        nports = 0;
    }
    size_t end = h->msgh_size;
    fprintf(g_out, "  inline body: offset %zu, %zu bytes\n", off, end > off ? end - off : 0);
    if (end > off) hexdump(b + off, end - off, off);
    /* Look for the XPC magic in the inline body. */
    for (size_t o = off; o + 8 <= end; o += 4) {
        if (is_xpc_magic(rd32(b + o))) {
            fprintf(g_out, "  XPC payload @%zu: magic=0x%x version=%u root=", o, rd32(b + o), rd32(b + o + 4));
            xpc_decode(b, end, o + 8, 1, &nports);
            break;
        }
    }
    if (with_trailer) {
        mach_msg_audit_trailer_t *t = (mach_msg_audit_trailer_t *)(b + al4(end));
        if (t->msgh_trailer_size >= sizeof(mach_msg_audit_trailer_t)) {
            fprintf(g_out, "  trailer: type=%u size=%u seqno=%u sender-pid=%d\n", t->msgh_trailer_type,
                    t->msgh_trailer_size, t->msgh_seqno, token_pid(t->msgh_audit));
        }
    }
    fflush(g_out);
}

/* ------------------------------------------------- XPC writer (host mode) */

typedef struct { uint8_t *b; size_t n; } wbuf;
static void w32(wbuf *w, uint32_t v) { memcpy(w->b + w->n, &v, 4); w->n += 4; }
static void w64(wbuf *w, uint64_t v) { memcpy(w->b + w->n, &v, 8); w->n += 8; }
static void wkey(wbuf *w, const char *k)
{
    size_t l = strlen(k) + 1;
    memcpy(w->b + w->n, k, l);
    w->n += l;
    while (w->n & 3) w->b[w->n++] = 0;
}
/* Starts "?cpx", version 5, an empty root dictionary; returns the offset of
 * the dictionary's length word. */
static size_t wdict_begin(wbuf *w)
{
    w32(w, 0x7870633f); w32(w, 5); w32(w, 0xf000);
    size_t lenoff = w->n; w32(w, 0); w32(w, 0);
    return lenoff;
}
static void wdict_end(wbuf *w, size_t lenoff, uint32_t count)
{
    uint32_t len = (uint32_t)(w->n - lenoff - 4);
    memcpy(w->b + lenoff, &len, 4);
    memcpy(w->b + lenoff + 4, &count, 4);
}

static int g_host_mode = 0;
static mach_port_t g_checked_in[64];
static int g_ncheckedin = 0;

/* Answer one request like a minimal host bootstrap. */
static void host_answer(mach_msg_header_t *h)
{
    uint8_t buf[512];
    memset(buf, 0, sizeof buf);
    mach_msg_header_t *r = (mach_msg_header_t *)buf;
    unsigned routine = h->msgh_id & 0xffff;
    if (h->msgh_remote_port == MACH_PORT_NULL) { fprintf(g_out, "  (host) no reply port\n"); return; }
    wbuf w;
    if (h->msgh_id == 708) {
        /* Black-box test of what the requester accepts as an answer to 708.
         * YC_708 = A: complex, one port descriptor (MOVE_RECEIVE), no NDR (40 bytes)
         *          B: complex, one port descriptor, then NDR (48 bytes)
         *          C: like A but MAKE_SEND
         *          E: simple 36-byte reply with RetCode = YC_708_CODE (default 1102) */
        const char *v = getenv("YC_708"); char variant = v ? v[0] : 'A';
        mach_port_t rp;
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rp);
        mach_port_insert_right(mach_task_self(), rp, rp, MACH_MSG_TYPE_MAKE_SEND);
        if (g_ncheckedin < 64) g_checked_in[g_ncheckedin++] = rp;
        if (variant == 'E') {
            r->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSGH_BITS_REMOTE(h->msgh_bits), 0, 0, 0);
            const char *c = getenv("YC_708_CODE");
            uint32_t ndr[2] = { 0, 1 }; memcpy(buf + 24, ndr, 8);
            int32_t code = c ? atoi(c) : 1102; memcpy(buf + 32, &code, 4);
            w.n = 36;
        } else {
            mach_msg_port_descriptor_t *pd = (mach_msg_port_descriptor_t *)(buf + 28);
            r->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSGH_BITS_REMOTE(h->msgh_bits), 0, 0, MACH_MSGH_BITS_COMPLEX);
            *(uint32_t *)(buf + 24) = 1;
            pd->name = rp; pd->type = MACH_MSG_PORT_DESCRIPTOR;
            pd->disposition = (variant == 'C') ? MACH_MSG_TYPE_MAKE_SEND : MACH_MSG_TYPE_MOVE_RECEIVE;
            w.n = 40;
            if (variant == 'B') { uint32_t ndr[2] = { 0, 1 }; memcpy(buf + 40, ndr, 8); w.n = 48; }
        }
        r->msgh_size = (mach_msg_size_t)w.n;
        r->msgh_remote_port = h->msgh_remote_port;
        r->msgh_local_port = MACH_PORT_NULL;
        r->msgh_id = h->msgh_id + 100;
        dump_msg("HOST-REPLY", r, 0);
        kern_return_t kr = mach_msg(r, MACH_SEND_MSG | MACH_SEND_TIMEOUT, r->msgh_size, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
        fprintf(g_out, "  (host) 708 answered with variant %c, port 0x%x, kr=0x%x\n", variant, rp, kr);
        return;
    }
    if (routine == 206 || routine == 805) {
        /* check-in: return a fresh receive right */
        mach_port_t rp;
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rp);
        mach_port_insert_right(mach_task_self(), rp, rp, MACH_MSG_TYPE_MAKE_SEND);
        if (g_ncheckedin < 64) g_checked_in[g_ncheckedin++] = rp;
        mach_port_t keep = rp; /* we keep a send right under the same name */
        mach_msg_port_descriptor_t *pd = (mach_msg_port_descriptor_t *)(buf + 28);
        r->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSGH_BITS_REMOTE(h->msgh_bits), 0, 0, MACH_MSGH_BITS_COMPLEX);
        *(uint32_t *)(buf + 24) = 1;
        pd->name = keep; pd->disposition = MACH_MSG_TYPE_MOVE_RECEIVE; pd->type = MACH_MSG_PORT_DESCRIPTOR;
        w.b = buf; w.n = 40;
        size_t lo = wdict_begin(&w);
        wkey(&w, "port"); w32(&w, 0x15000);
        wdict_end(&w, lo, 1);
        fprintf(g_out, "  (host) check-in answered with receive right 0x%x (we keep send)\n", rp);
    } else if ((routine == 207 || routine == 804) && memmem((uint8_t *)h + 24, h->msgh_size - 24,
                                                             "com.ycode.host.found", 21)) {
        /* found: return a send right made from a fresh port; no other keys */
        mach_port_t sp;
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &sp);
        mach_msg_port_descriptor_t *pd = (mach_msg_port_descriptor_t *)(buf + 28);
        r->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSGH_BITS_REMOTE(h->msgh_bits), 0, 0, MACH_MSGH_BITS_COMPLEX);
        *(uint32_t *)(buf + 24) = 1;
        pd->name = sp; pd->disposition = MACH_MSG_TYPE_MAKE_SEND; pd->type = MACH_MSG_PORT_DESCRIPTOR;
        w.b = buf; w.n = 40;
        size_t lo = wdict_begin(&w);
        wkey(&w, "port"); w32(&w, 0xd000);
        wdict_end(&w, lo, 1);
        fprintf(g_out, "  (host) look-up answered with a send right to new port 0x%x\n", sp);
    } else {
        int64_t err = (routine == 207) ? 1102 : (routine == 804 ? 3 : 45);
        r->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSGH_BITS_REMOTE(h->msgh_bits), 0, 0, 0);
        w.b = buf; w.n = 24;
        size_t lo = wdict_begin(&w);
        wkey(&w, "error"); w32(&w, 0x3000); w64(&w, (uint64_t)err);
        wdict_end(&w, lo, 1);
        fprintf(g_out, "  (host) answered error %lld\n", (long long)err);
    }
    r->msgh_size = (mach_msg_size_t)w.n;
    r->msgh_remote_port = h->msgh_remote_port;
    r->msgh_local_port = MACH_PORT_NULL;
    r->msgh_id = 0x20000000;
    dump_msg("HOST-REPLY", r, 0);
    kern_return_t kr = mach_msg(r, MACH_SEND_MSG | MACH_SEND_TIMEOUT, r->msgh_size, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
    if (kr) fprintf(g_out, "  (host) reply send failed 0x%x\n", kr);
}

/* The server rejects (EPERM) pid-domain requests whose "handle" is not the
 * sender's pid. Because we relay from our own pid, optionally rewrite a
 * "handle" equal to the child's pid into ours (same size, in place). */
static pid_t g_child_pid = 0;
static void rewrite_handle(mach_msg_header_t *h)
{
    uint8_t *b = (uint8_t *)h;
    for (size_t o = 24; o + 20 <= h->msgh_size; o += 4) {
        if (!memcmp(b + o, "handle\0\0", 8) && rd32(b + o + 8) == 0x4000 &&
            rd64(b + o + 12) == (uint64_t)g_child_pid && g_child_pid) {
            uint64_t me = (uint64_t)getpid();
            memcpy(b + o + 12, &me, 8);
            fprintf(g_out, "  (rewrote handle %d -> %d before forwarding)\n", g_child_pid, getpid());
        }
    }
}

/* --------------------------------------------------------------- relay */

static void *relay_thread(void *arg)
{
    (void)arg;
    uint8_t *req = malloc(BUFSZ), *rep = malloc(BUFSZ);
    mach_port_t myreply;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &myreply);
    for (;;) {
        mach_msg_header_t *h = (mach_msg_header_t *)req;
        memset(req, 0, 64);
        kern_return_t kr = mach_msg(h, MACH_RCV_MSG | MACH_RCV_VOUCHER |
                                    MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                                    MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                                    0, BUFSZ, g_fake_bs, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) { fprintf(g_out, "relay: receive failed 0x%x\n", kr); break; }
        g_seq++;
        dump_msg("REQUEST", h, 1);
        if (h->msgh_id == 0x7777) { fprintf(g_out, "  (identity message from the child: kept, not forwarded)\n"); continue; }
        if (g_host_mode) { host_answer(h); continue; }
        if (getenv("YC_REWRITE_HANDLE")) rewrite_handle(h);
        if (g_serve_only) {
            /* Keep the rights alive (do not reply); record only. */
            continue;
        }
        mach_port_t orig_reply = h->msgh_remote_port;
        unsigned orig_reply_type = MACH_MSGH_BITS_REMOTE(h->msgh_bits);
        mach_port_t voucher = h->msgh_voucher_port;
        unsigned vt = MACH_MSGH_BITS_VOUCHER(h->msgh_bits);
        unsigned complex = h->msgh_bits & MACH_MSGH_BITS_COMPLEX;
        int want_reply = (orig_reply != MACH_PORT_NULL);
        h->msgh_remote_port = g_real_bs;
        h->msgh_local_port = want_reply ? myreply : MACH_PORT_NULL;
        h->msgh_voucher_port = vt ? voucher : MACH_PORT_NULL;
        h->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND,
                                          want_reply ? MACH_MSG_TYPE_MAKE_SEND_ONCE : 0,
                                          vt ? MACH_MSG_TYPE_MOVE_SEND : 0, complex);
        /* Received OOL descriptors: send them on as virtual copies. */
        if (complex) {
            uint8_t *b = req;
            size_t off = 28;
            uint32_t cnt = rd32(b + 24);
            for (uint32_t i = 0; i < cnt; i++) {
                uint8_t type = b[off + 11];
                if (type == MACH_MSG_PORT_DESCRIPTOR) { off += 12; continue; }
                if (type == MACH_MSG_OOL_DESCRIPTOR || type == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) {
                    b[off + 8] = 1; b[off + 9] = MACH_MSG_VIRTUAL_COPY;
                }
                off += 16;
            }
        }
        mach_msg_header_t *r = (mach_msg_header_t *)rep;
        memset(rep, 0, 64);
        if (!want_reply) {
            kr = mach_msg(h, MACH_SEND_MSG, h->msgh_size, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
            fprintf(g_out, "  (one-way) forwarded kr=0x%x\n", kr);
            continue;
        }
        kr = mach_msg(h, MACH_SEND_MSG, h->msgh_size, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) { fprintf(g_out, "  forward send failed 0x%x\n", kr); continue; }
        kr = mach_msg(r, MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_VOUCHER, 0, BUFSZ, myreply,
                      20000, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) { fprintf(g_out, "  reply receive failed 0x%x\n", kr); continue; }
        dump_msg("REPLY", r, 0);
        unsigned rvt = MACH_MSGH_BITS_VOUCHER(r->msgh_bits);
        unsigned rcomplex = r->msgh_bits & MACH_MSGH_BITS_COMPLEX;
        r->msgh_remote_port = orig_reply;
        r->msgh_local_port = MACH_PORT_NULL;
        r->msgh_bits = MACH_MSGH_BITS_SET(orig_reply_type, 0, rvt ? MACH_MSG_TYPE_MOVE_SEND : 0, rcomplex);
        if (!rvt) r->msgh_voucher_port = MACH_PORT_NULL;
        if (rcomplex) {
            uint8_t *b = rep;
            size_t off = 28;
            uint32_t cnt = rd32(b + 24);
            for (uint32_t i = 0; i < cnt; i++) {
                uint8_t type = b[off + 11];
                if (type == MACH_MSG_PORT_DESCRIPTOR) { off += 12; continue; }
                if (type == MACH_MSG_OOL_DESCRIPTOR || type == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) {
                    b[off + 8] = 1; b[off + 9] = MACH_MSG_VIRTUAL_COPY;
                }
                off += 16;
            }
        }
        kr = mach_msg(r, MACH_SEND_MSG, r->msgh_size, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) fprintf(g_out, "  reply return failed 0x%x\n", kr);
        fflush(g_out);
    }
    return NULL;
}

/* ---------------------------------------------------------------- tests */

/* Private libxpc pipe SPI (signatures as commonly documented publicly). */
extern xpc_object_t xpc_pipe_create_from_port(mach_port_t port, uint64_t flags);
extern int xpc_pipe_routine(xpc_object_t pipe, xpc_object_t msg, xpc_object_t *reply);
extern int xpc_pipe_simpleroutine(xpc_object_t pipe, xpc_object_t msg);

static mach_port_t g_sink = MACH_PORT_NULL;

/* Receive raw messages on g_sink, dump them, optionally answer. */
static void *sink_thread(void *arg)
{
    (void)arg;
    uint8_t *buf = malloc(BUFSZ);
    for (;;) {
        mach_msg_header_t *h = (mach_msg_header_t *)buf;
        kern_return_t kr = mach_msg(h, MACH_RCV_MSG | MACH_RCV_VOUCHER | MACH_RCV_TIMEOUT |
                                    MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                                    MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                                    0, BUFSZ, g_sink, 3000, MACH_PORT_NULL);
        if (kr == MACH_RCV_TIMED_OUT) continue;
        if (kr) { fprintf(g_out, "sink: receive 0x%x\n", kr); return NULL; }
        g_seq++;
        dump_msg("SINK", h, 1);
        if (h->msgh_remote_port && (h->msgh_id == 0x10000000 || (h->msgh_id & 0xf0000000) == 0x40000000)) {
            uint8_t rb[256]; memset(rb, 0, sizeof rb);
            mach_msg_header_t *r = (mach_msg_header_t *)rb;
            wbuf w = { rb, 24 };
            size_t lo = wdict_begin(&w);
            wkey(&w, "echo"); w32(&w, 0x4000); w64(&w, 1);
            wdict_end(&w, lo, 1);
            r->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSGH_BITS_REMOTE(h->msgh_bits), 0, 0, 0);
            r->msgh_size = (mach_msg_size_t)w.n;
            r->msgh_remote_port = h->msgh_remote_port;
            r->msgh_id = getenv("YC_REPLY_ID") ? (int)strtol(getenv("YC_REPLY_ID"), NULL, 0) : 0x20000000;
            dump_msg("SINK-REPLY", r, 0);
            kr = mach_msg(r, MACH_SEND_MSG | MACH_SEND_TIMEOUT, r->msgh_size, 0, 0, 1000, 0);
            if (kr) fprintf(g_out, "sink: reply send 0x%x\n", kr);
        }
    }
}

static void start_sink(mach_port_t p)
{
    static int started = 0;
    g_sink = p;
    if (!started) { pthread_t t; pthread_create(&t, NULL, sink_thread, NULL); started = 1; }
}

static void note(const char *what, kern_return_t kr, mach_port_t p)
{
    fprintf(g_out, "-- TEST %s -> kr=%d (0x%x) port=0x%x\n", what, kr, kr, p);
    fflush(g_out);
    usleep(50000);
}

static void xpc_lookup(const char *name, uint64_t flags, int send)
{
    xpc_connection_t c = ycode_xpc_create_mach_service(name, NULL, flags);
    xpc_connection_set_event_handler(c, ^(xpc_object_t e) {
        char *d = xpc_copy_description(e);
        fprintf(g_out, "-- xpc event on %s: %s\n", name, d);
        free(d);
    });
    xpc_connection_resume(c);
    if (send) {
        xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(m, "ycode-probe", "hello");
        xpc_object_t r = xpc_connection_send_message_with_reply_sync(c, m);
        char *d = xpc_copy_description(r);
        fprintf(g_out, "-- TEST xpc %s flags=0x%llx reply: %s\n", name, (unsigned long long)flags, d);
        free(d);
    }
    usleep(200000);
    xpc_connection_cancel(c);
    usleep(50000);
}

static void run_tests(const char *which)
{
    mach_port_t p;
    kern_return_t kr;
    int all = (strcmp(which, "all") == 0);
#define WANT(n) (all || strstr(which, n))
    fprintf(g_out, "-- tests start pid=%d bootstrap_port=0x%x\n", getpid(), bootstrap_port);
    if (WANT("lookup")) {
        p = 0; kr = bootstrap_look_up(bootstrap_port, "com.apple.cfprefsd.daemon", &p); note("look_up cfprefsd.daemon", kr, p);
        p = 0; kr = bootstrap_look_up(bootstrap_port, "com.ycode.probe.nonexistent", &p); note("look_up nonexistent", kr, p);
        p = 0; kr = bootstrap_look_up(bootstrap_port, "x", &p); note("look_up 'x'", kr, p);
        char longname[128]; memset(longname, 'a', 127); longname[127] = 0;
        p = 0; kr = bootstrap_look_up(bootstrap_port, longname, &p); note("look_up 127 a's", kr, p);
    }
    if (WANT("found")) {
        p = 0; kr = bootstrap_look_up(bootstrap_port, "com.ycode.host.found", &p); note("look_up com.ycode.host.found", kr, p);
        p = 0; kr = bootstrap_look_up(bootstrap_port, "com.ycode.host.missing", &p); note("look_up com.ycode.host.missing", kr, p);
        p = 0; kr = bootstrap_check_in(bootstrap_port, "com.ycode.host.mine", &p); note("check_in com.ycode.host.mine", kr, p);
        if (p) {
            mach_port_type_t ty = 0; mach_port_type(mach_task_self(), p, &ty);
            fprintf(g_out, "-- checked-in right type 0x%x (receive=%d send=%d)\n", ty,
                    !!(ty & MACH_PORT_TYPE_RECEIVE), !!(ty & MACH_PORT_TYPE_SEND));
        }
        xpc_lookup("com.ycode.host.found", 0, 0);
        xpc_lookup("com.ycode.host.missing", 0, 0);
        p = 0; kr = bootstrap_register(bootstrap_port, "com.ycode.host.reg", mach_task_self()); note("register (answered 45)", kr, p);
    }
    if (WANT("host")) {
        p = 0; kr = bootstrap_look_up(bootstrap_port, "com.apple.CoreSimulator.host.bootstrap_port", &p); note("look_up host.bootstrap_port", kr, p);
        p = 0; kr = bootstrap_look_up(bootstrap_port, "com.apple.CoreSimulator.SimFramebufferServer", &p); note("look_up SimFramebufferServer", kr, p);
    }
    if (WANT("lookup2")) {
        p = 0; kr = bootstrap_look_up2(bootstrap_port, "com.apple.cfprefsd.daemon", &p, 0, 0); note("look_up2 pid0 flags0", kr, p);
        p = 0; kr = bootstrap_look_up2(bootstrap_port, "com.apple.cfprefsd.daemon", &p, 0, 8); note("look_up2 pid0 flags8 (privileged)", kr, p);
        p = 0; kr = bootstrap_look_up2(bootstrap_port, "com.apple.cfprefsd.daemon", &p, getpid(), 1); note("look_up2 self pid flags1 (per-pid)", kr, p);
        unsigned char u[16]; for (int i = 0; i < 16; i++) u[i] = (unsigned char)(0x10 + i);
        p = 0; kr = bootstrap_look_up3(bootstrap_port, "com.apple.cfprefsd.daemon", &p, 0, u, 0); note("look_up3 with uuid", kr, p);
    }
    if (WANT("checkin")) {
        p = 0; kr = bootstrap_check_in(bootstrap_port, "com.ycode.probe.dyn1", &p); note("check_in dyn1 (unknown name)", kr, p);
        mach_port_t q = 0; kr = bootstrap_look_up(bootstrap_port, "com.ycode.probe.dyn1", &q); note("look_up dyn1 after check-in", kr, q);
        mach_port_t q2 = 0; kr = bootstrap_check_in(bootstrap_port, "com.ycode.probe.dyn1", &q2); note("check_in dyn1 again", kr, q2);
        p = 0; kr = bootstrap_check_in(bootstrap_port, "com.apple.cfprefsd.daemon", &p); note("check_in cfprefsd.daemon (not ours)", kr, p);
        p = 0; kr = bootstrap_check_in2(bootstrap_port, "com.ycode.probe.dyn2", &p, 1); note("check_in2 dyn2 flags1", kr, p);
    }
    if (WANT("register")) {
        mach_port_t s; mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &s);
        mach_port_insert_right(mach_task_self(), s, s, MACH_MSG_TYPE_MAKE_SEND);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        kr = bootstrap_register(bootstrap_port, "com.ycode.probe.reg1", s); note("register reg1", kr, s);
        p = 0; kr = bootstrap_look_up(bootstrap_port, "com.ycode.probe.reg1", &p); note("look_up reg1", kr, p);
        p = 0; kr = bootstrap_create_service(bootstrap_port, "com.ycode.probe.cs1", &p); note("create_service cs1", kr, p);
        p = 0; kr = bootstrap_parent(bootstrap_port, &p); note("parent", kr, p);
#pragma clang diagnostic pop
    }
    if (WANT("ident")) {
        /* Send our candidate rights to the relay so it can compare names. */
        struct { mach_msg_header_t h; mach_msg_body_t b; mach_msg_port_descriptor_t d[8]; } m;
        memset(&m, 0, sizeof m);
        mach_port_t *pl = NULL; mach_msg_type_number_t pn = 0;
        mach_ports_lookup(mach_task_self(), &pl, &pn);
        mach_port_t cand[8] = { mach_task_self(), bootstrap_port, mach_host_self(), mach_thread_self(),
                                pn > 0 ? pl[0] : 0, pn > 1 ? pl[1] : 0, pn > 2 ? pl[2] : 0, 0 };
        task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &cand[7]);
        const char *names[8] = { "task_self", "bootstrap_port", "host_self", "thread_self",
                                 "registered[0]", "registered[1]", "registered[2]", "special BOOTSTRAP" };
        for (int i = 0; i < 8; i++) {
            m.d[i].name = cand[i];
            m.d[i].disposition = cand[i] ? MACH_MSG_TYPE_COPY_SEND : 0;
            m.d[i].type = MACH_MSG_PORT_DESCRIPTOR;
            fprintf(g_out, "-- ident [%d] %s = 0x%x (child name)\n", i, names[i], cand[i]);
        }
        m.h.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, 0, 0, MACH_MSGH_BITS_COMPLEX);
        m.h.msgh_size = sizeof m;
        m.h.msgh_remote_port = bootstrap_port;
        m.h.msgh_id = 0x7777;
        m.b.msgh_descriptor_count = 8;
        kr = mach_msg(&m.h, MACH_SEND_MSG, sizeof m, 0, 0, 0, 0);
        fprintf(g_out, "-- ident sent kr=0x%x (registered count %u)\n", kr, pn);
        usleep(100000);
    }
    if (WANT("bundled")) {
        xpc_connection_t c = xpc_connection_create("com.ycode.probe.bundled-svc", NULL);
        xpc_connection_set_event_handler(c, ^(xpc_object_t e) {
            char *d = xpc_copy_description(e); fprintf(g_out, "-- bundled-svc event: %s\n", d); free(d); });
        xpc_connection_resume(c);
        xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(m, "ycode-probe", "hello");
        xpc_object_t r = xpc_connection_send_message_with_reply_sync(c, m);
        char *d = xpc_copy_description(r);
        fprintf(g_out, "-- TEST xpc_connection_create bundled-svc reply: %s\n", d);
        free(d);
        xpc_connection_cancel(c);
        usleep(100000);
    }
    if (WANT("pipe")) {
        /* Serialization of every common type, sent by libxpc's pipe to a port we own. */
        mach_port_t sp;
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &sp);
        mach_port_insert_right(mach_task_self(), sp, sp, MACH_MSG_TYPE_MAKE_SEND);
        start_sink(sp);
        xpc_object_t pipe = xpc_pipe_create_from_port(sp, 0);
        xpc_object_t d = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_bool(d, "bool-true", true);
        xpc_dictionary_set_bool(d, "bool-false", false);
        xpc_dictionary_set_int64(d, "int64", -2);
        xpc_dictionary_set_uint64(d, "uint64", 0x1122334455667788ULL);
        xpc_dictionary_set_double(d, "double", 1.5);
        xpc_dictionary_set_date(d, "date", 1000000000LL);
        xpc_dictionary_set_string(d, "str", "abc");
        xpc_dictionary_set_string(d, "empty", "");
        const uint8_t bytes[5] = { 1, 2, 3, 4, 5 };
        xpc_dictionary_set_data(d, "data5", bytes, 5);
        unsigned char u[16]; for (int i = 0; i < 16; i++) u[i] = (unsigned char)i;
        xpc_dictionary_set_uuid(d, "uuid", u);
        xpc_dictionary_set_value(d, "null", xpc_null_create());
        xpc_object_t a = xpc_array_create(NULL, 0);
        xpc_array_set_uint64(a, XPC_ARRAY_APPEND, 7);
        xpc_array_set_string(a, XPC_ARRAY_APPEND, "x");
        xpc_dictionary_set_value(d, "array", a);
        xpc_object_t sub = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_int64(sub, "k", 9);
        xpc_dictionary_set_value(d, "subdict", sub);
        xpc_dictionary_set_fd(d, "fd", 1);
        mach_port_t s1; mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &s1);
        mach_port_insert_right(mach_task_self(), s1, s1, MACH_MSG_TYPE_MAKE_SEND);
        extern void xpc_dictionary_set_mach_send(xpc_object_t, const char *, mach_port_t);
        extern void xpc_dictionary_set_mach_recv(xpc_object_t, const char *, mach_port_t);
        xpc_dictionary_set_mach_send(d, "msend", s1);
        mach_port_t r1; mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &r1);
        xpc_dictionary_set_mach_recv(d, "mrecv", r1);
        fprintf(g_out, "-- pipe test: sink 0x%x send 0x%x recv 0x%x\n", sp, s1, r1);
        xpc_object_t reply = NULL;
        int e = xpc_pipe_routine(pipe, d, &reply);
        char *desc = reply ? xpc_copy_description(reply) : strdup("(null)");
        fprintf(g_out, "-- TEST xpc_pipe_routine -> %d reply %s\n", e, desc);
        free(desc);
        xpc_object_t big = xpc_dictionary_create(NULL, NULL, 0);
        static uint8_t blob[40000]; memset(blob, 0xab, sizeof blob);
        xpc_dictionary_set_data(big, "blob", blob, sizeof blob);
        e = xpc_pipe_simpleroutine(pipe, big);
        fprintf(g_out, "-- TEST xpc_pipe_simpleroutine big -> %d\n", e);
        size_t sizes[] = { 4096, 8192, 16383, 16384, 16385, 32768, 12000, 14000, 15000, 16000, 16300, 16340 };
        for (unsigned i = 0; i < 12; i++) {
            xpc_object_t dd = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_data(dd, "blob", blob, sizes[i]);
            e = xpc_pipe_simpleroutine(pipe, dd);
            fprintf(g_out, "-- TEST simpleroutine data %zu -> %d\n", sizes[i], e);
            usleep(100000);
        }
        /* rights plus an out-of-line body: descriptor order */
        xpc_object_t mix = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_mach_send(mix, "a-send", s1);
        xpc_dictionary_set_data(mix, "b-blob", blob, 16000);
        xpc_dictionary_set_fd(mix, "c-fd", 2);
        e = xpc_pipe_simpleroutine(pipe, mix);
        fprintf(g_out, "-- TEST simpleroutine mix -> %d\n", e);
        usleep(200000);
        usleep(300000);
    }
    if (WANT("conn")) {
        /* A connection to a name we checked in ourselves: see the raw XPC
         * connection traffic (not bootstrap traffic). */
        mach_port_t rp = 0;
        kr = bootstrap_check_in(bootstrap_port, "com.ycode.probe.raw", &rp);
        note("check_in com.ycode.probe.raw", kr, rp);
        if (kr == 0) {
            start_sink(rp);
            xpc_connection_t c = ycode_xpc_create_mach_service("com.ycode.probe.raw", NULL, 0);
            xpc_connection_set_event_handler(c, ^(xpc_object_t e) {
                char *dd = xpc_copy_description(e); fprintf(g_out, "-- raw conn event: %s\n", dd); free(dd); });
            xpc_connection_resume(c);
            xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_string(m, "hello", "world");
            xpc_connection_send_message(c, m);
            xpc_object_t m2 = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_uint64(m2, "n", 2);
            xpc_connection_send_message_with_reply(c, m2, NULL, ^(xpc_object_t r) {
                char *dd = xpc_copy_description(r); fprintf(g_out, "-- raw conn reply: %s\n", dd); free(dd); });
            usleep(800000);
            xpc_connection_cancel(c);
            usleep(300000);
        }
    }
    if (WANT("misc")) {
        extern const char *bootstrap_strerror(kern_return_t r);
        int codes[] = { 1, 3, 37, 45, 113, 119, 122, 124, 125, 126, 1100, 1101, 1102, 1103, 1104 };
        for (unsigned i = 0; i < sizeof codes / sizeof codes[0]; i++)
            fprintf(g_out, "-- strerror %d: %s\n", codes[i], bootstrap_strerror(codes[i]));
        char n128[129]; memset(n128, 'b', 128); n128[128] = 0;
        p = 0; kr = bootstrap_look_up(bootstrap_port, n128, &p); note("look_up 128 b's", kr, p);
        char n200[201]; memset(n200, 'c', 200); n200[200] = 0;
        p = 0; kr = bootstrap_look_up(bootstrap_port, n200, &p); note("look_up 200 c's", kr, p);
        p = 0; kr = bootstrap_check_in(bootstrap_port, n200, &p); note("check_in 200 c's", kr, p);
        xpc_connection_t c = xpc_connection_create("com.ycode.probe.bundled-svc", NULL);
        xpc_connection_set_event_handler(c, ^(xpc_object_t e) {
            char *d = xpc_copy_description(e); fprintf(g_out, "-- bundled-svc event: %s\n", d); free(d); });
        xpc_connection_resume(c);
        xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(m, "ycode-probe", "hello");
        xpc_object_t r = xpc_connection_send_message_with_reply_sync(c, m);
        char *d = xpc_copy_description(r);
        fprintf(g_out, "-- TEST xpc_connection_create bundled-svc reply: %s\n", d);
        free(d);
        xpc_connection_cancel(c);
        usleep(100000);
    }
    if (WANT("xpc")) {
        xpc_lookup("com.apple.cfprefsd.daemon", 0, 1);
        xpc_lookup("com.ycode.probe.xpc-nonexistent", 0, 1);
        xpc_lookup("com.apple.cfprefsd.daemon", YC_PRIVILEGED, 1);
    }
    if (WANT("listen")) {
        xpc_connection_t l = ycode_xpc_create_mach_service("com.ycode.probe.listener", NULL,
                                                                YC_LISTENER);
        xpc_connection_set_event_handler(l, ^(xpc_object_t e) {
            char *d = xpc_copy_description(e);
            fprintf(g_out, "-- listener event: %s\n", d);
            free(d);
        });
        xpc_connection_resume(l);
        usleep(300000);
        fprintf(g_out, "-- TEST xpc listener com.ycode.probe.listener resumed\n");
        xpc_connection_cancel(l);
        usleep(50000);
    }
    fprintf(g_out, "-- tests end\n");
    fflush(g_out);
}

/* ----------------------------------------------------------------- main */

static void make_fake(void)
{
    task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &g_real_bs);
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &g_fake_bs);
    mach_port_insert_right(mach_task_self(), g_fake_bs, g_fake_bs, MACH_MSG_TYPE_MAKE_SEND);
    fprintf(g_out, "real bootstrap=0x%x global=0x%x fake=0x%x\n", g_real_bs, bootstrap_port, g_fake_bs);
}

static char **g_child_env = NULL;

/* Environment for exec/serve/host modes: YC_ENVFILE names a file of
 * KEY=VALUE lines; without it the child inherits ours. */
static void load_envfile(void)
{
    const char *f = getenv("YC_ENVFILE");
    if (!f) return;
    FILE *fp = fopen(f, "r");
    if (!fp) { fprintf(g_out, "cannot open %s\n", f); return; }
    g_child_env = calloc(256, sizeof(char *));
    char line[8192];
    int n = 0;
    while (n < 255 && fgets(line, sizeof line, fp)) {
        line[strcspn(line, "\n")] = 0;
        if (line[0]) g_child_env[n++] = strdup(line);
    }
    fclose(fp);
    fprintf(g_out, "child environment: %d variables from %s\n", n, f);
}

/* "hostfork": make the program's process have a child of its own before it
 * starts (fork; the first child forks a second one, the "tank", then execs the
 * program). The tank's pid is put in the variable named by YC_TANK_VAR.
 * YC_TANK = exit (tank exits at once) | sleep:N (tank sleeps N s, then exits).
 * The fake bootstrap is passed by making it our own task bootstrap port
 * around the fork (special ports are inherited across fork and exec). */
static int fork_chain(char *const argv[])
{
    const char *exe = getenv("YC_EXE");
    const char *tank = getenv("YC_TANK"); if (!tank) tank = "exit";
    const char *var = getenv("YC_TANK_VAR"); if (!var) var = "XPC_SIMULATOR_HOLDING_TANK_HACK";
    int sleeps = 0;
    if (!strncmp(tank, "sleep:", 6)) sleeps = atoi(tank + 6);
    /* environment with one slot for the tank variable */
    char **env = calloc(300, sizeof(char *));
    int n = 0;
    char **src = g_child_env ? g_child_env : environ;
    for (; src[n] && n < 290; n++) env[n] = src[n];
    char *tankslot = malloc(256);
    env[n++] = tankslot; env[n] = NULL;
    int pfd[2]; pipe(pfd);
    task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, g_fake_bs);
    pid_t c1 = fork();
    if (c1 == 0) {
        pid_t c2 = fork();
        if (c2 == 0) {
            if (sleeps) sleep((unsigned)sleeps);
            _exit(0);
        }
        snprintf(tankslot, 256, "%s=%d", var, c2);
        execve(exe ? exe : argv[0], argv, env);
        _exit(127);
    }
    task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, g_real_bs);
    g_child_pid = c1;
    fprintf(g_out, "forked pid %d (program %s), its child (tank, %s) set in %s\n", c1, argv[0], tank, var);
    fflush(g_out);
    const char *ts = getenv("YC_SECONDS");
    sleep(ts ? (unsigned)atoi(ts) : 8);
    kill(c1, SIGKILL);
    int st = 0;
    waitpid(c1, &st, 0);
    usleep(200000);
    fprintf(g_out, "program exited status=0x%x\n", st);
    return 0;
}

static int spawn_child(char *const argv[])
{
    posix_spawnattr_t a;
    posix_spawnattr_init(&a);
    int e = posix_spawnattr_setspecialport_np(&a, g_fake_bs, TASK_BOOTSTRAP_PORT);
    if (e) fprintf(g_out, "setspecialport: %d\n", e);
    pid_t pid;
    const char *exe = getenv("YC_EXE");
    e = posix_spawn(&pid, exe ? exe : argv[0], NULL, &a, argv, g_child_env ? g_child_env : environ);
    if (e) { fprintf(g_out, "posix_spawn %s: %s\n", argv[0], strerror(e)); return 1; }
    g_child_pid = pid;
    fprintf(g_out, "spawned pid %d: %s\n", pid, argv[0]);
    fflush(g_out);
    int st = 0;
    if (g_serve_only || g_host_mode || getenv("YC_SECONDS")) {
        const char *ts = getenv("YC_SECONDS");
        sleep(ts ? (unsigned)atoi(ts) : 8);
        kill(pid, SIGKILL);
    }
    waitpid(pid, &st, 0);
    usleep(200000);
    fprintf(g_out, "child exited status=0x%x\n", st);
    return 0;
}

int main(int argc, char **argv)
{
    g_out = stdout;
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 2) { fprintf(stderr, "usage: bsmitm self|spawn|child|exec|serve ...\n"); return 2; }
    const char *mode = argv[1];
    const char *tests = argc > 2 ? argv[2] : "all";
    if (!strcmp(mode, "child")) { run_tests(tests); return 0; }
    make_fake();
    pthread_t t;
    if (!strcmp(mode, "self")) {
        pthread_create(&t, NULL, relay_thread, NULL);
        task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, g_fake_bs);
        bootstrap_port = g_fake_bs;
        run_tests(tests);
        usleep(300000);
        return 0;
    }
    if (!strcmp(mode, "serve")) g_serve_only = 1;
    if (!strcmp(mode, "host") || !strcmp(mode, "hostfork")) g_host_mode = 1;
    load_envfile();
    pthread_create(&t, NULL, relay_thread, NULL);
    if (!strcmp(mode, "spawn")) {
        char *cargv[] = { argv[0], "child", (char *)tests, NULL };
        return spawn_child(cargv);
    }
    if (!strcmp(mode, "hostfork")) {
        if (argc < 3) return 2;
        return fork_chain(argv + 2);
    }
    if (!strcmp(mode, "exec") || !strcmp(mode, "serve") || !strcmp(mode, "host")) {
        if (argc < 3) return 2;
        return spawn_child(argv + 2);
    }
    return 2;
}
