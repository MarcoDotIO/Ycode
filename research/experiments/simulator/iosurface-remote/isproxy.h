/*
 * isproxy.h: a recording Mach-message relay (original Ycode code, R5).
 *
 * The relay owns a port set. Each member ("proxy port") has a destination
 * send right. Every message that arrives on a proxy port is recorded (header,
 * descriptors, inline body, our own decoding of XPC-serialized payloads) and
 * sent on to the destination:
 *   - the message's reply right (header) is replaced by a new proxy port whose
 *     destination is that reply right, so the answer is recorded too;
 *   - in a connection hand-shake message (id 0x77303074) every port
 *     descriptor is replaced the same way (a receive right is kept and a new
 *     receive right goes on; a send right gets a proxy), so later traffic on
 *     the new connection also passes through the relay;
 *   - all other descriptors (ports, OOL memory) are passed through unchanged.
 * Nothing is ever read from executable memory: OOL regions are fresh copies
 * made by the kernel in this process, and the optional memory-entry test maps
 * a received send right read-only and records only its size and protection.
 *
 * Include once, then call isp_start(log FILE*), isp_add(proxy, dest, label).
 */
#ifndef ISPROXY_H
#define ISPROXY_H
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define ISP_MAX 4096
#define ISP_BUF (1024 * 1024)
#define ISP_HANDSHAKE 0x77303074

typedef struct {
    mach_port_t rcv;   /* proxy receive right (member of the set) */
    mach_port_t dst;   /* destination send / send-once right */
    int once;          /* destination is a send-once right */
    int dir;           /* 0: client->server, 1: server->client */
    int conn;          /* connection number for the log */
} isp_entry;

static isp_entry g_isp[ISP_MAX];
static int g_isp_n;
static mach_port_t g_isp_set;
static FILE *g_isp_out;
static pthread_mutex_t g_isp_mtx = PTHREAD_MUTEX_INITIALIZER;
static int g_isp_seq, g_isp_conn;
static uint64_t g_isp_t0;
static int g_isp_maptest;

static uint64_t isp_now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000 + (uint64_t)ts.tv_nsec / 1000;
}

static uint32_t isp_rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t isp_rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static size_t isp_al4(size_t x) { return (x + 3) & ~(size_t)3; }

static void isp_hex(const uint8_t *p, size_t n, size_t base)
{
    FILE *o = g_isp_out;
    for (size_t i = 0; i < n; i += 16) {
        fprintf(o, "    %06zx:", base + i);
        for (size_t j = 0; j < 16; j++) {
            if (i + j < n) fprintf(o, " %02x", p[i + j]);
            else fprintf(o, "   ");
        }
        fprintf(o, "  |");
        for (size_t j = 0; j < 16 && i + j < n; j++) fputc((p[i + j] >= 32 && p[i + j] < 127) ? p[i + j] : '.', o);
        fprintf(o, "|\n");
    }
}

static void isp_ind(int d);
/* Magics: "?cpx"/"@cpx" (bootstrap-wire.md §3.1) and "!CPX" (seen on this service). */
static int isp_magic(uint32_t m) { return m == 0x7870633f || m == 0x78706340 || m == 0x58504321; }

/* Decoder of the OSSerialize binary format (xnu libkern OSSerializeBinary.h, level 1). */
static void isp_osser(const uint8_t *p, size_t n, int depth)
{
    FILE *o = g_isp_out;
    size_t q = 4;
    int stack[16], sp = 0;
    stack[0] = 1 << 30;
    int pending_key = 0;
    while (q + 4 <= n) {
        uint32_t k = isp_rd32(p + q);
        q += 4;
        uint32_t ty = k & 0x7F000000u, len = k & 0x00FFFFFFu, last = k >> 31;
        int d = depth + sp;
        int is_dict = sp > 0 && stack[sp] < 0;
        if (!(is_dict && pending_key)) isp_ind(d);
        switch (ty) {
        case 0x01000000: fprintf(o, "osdict count=%u\n", len); break;
        case 0x02000000: fprintf(o, "osarray count=%u\n", len); break;
        case 0x03000000: fprintf(o, "osset count=%u\n", len); break;
        case 0x04000000: fprintf(o, "osnumber bits=%u value=%llu (0x%llx)\n", len, (unsigned long long)isp_rd64(p + q), (unsigned long long)isp_rd64(p + q)); q += 8; break;
        case 0x08000000: fprintf(o, "ossymbol \"%.*s\"", (int)len, (const char *)p + q); q += isp_al4(len); break;
        case 0x09000000: fprintf(o, "osstring \"%.*s\"\n", (int)len, (const char *)p + q); q += isp_al4(len); break;
        case 0x0a000000: fprintf(o, "osdata len=%u\n", len); if (len <= 256) isp_hex(p + q, len, q); q += isp_al4(len); break;
        case 0x0b000000: fprintf(o, "osbool %u\n", len); break;
        case 0x0c000000: fprintf(o, "osref %u\n", len); break;
        default: fprintf(o, "os? 0x%08x\n", k); return;
        }
        if (ty == 0x08000000) {
            if (is_dict && !pending_key) { fprintf(o, " => "); pending_key = 1; continue; }
            fprintf(o, "\n");
        }
        pending_key = 0;
        if ((ty == 0x01000000 || ty == 0x02000000 || ty == 0x03000000) && len && sp < 15) {
            stack[++sp] = ty == 0x01000000 ? -1 : 1;
            continue;
        }
        while (last && sp > 0) { sp--; last = 0; }
        (void)last;
    }
}

static void isp_ind(int d) { for (int i = 0; i < d; i++) fprintf(g_isp_out, "  "); }

/* Our decoder of the XPC object stream (format: bootstrap-wire.md §3). */
static size_t isp_xpc(const uint8_t *p, size_t n, size_t off, int depth, int *ports)
{
    FILE *o = g_isp_out;
    if (off + 4 > n) { fprintf(o, "<truncated>\n"); return n; }
    uint32_t t = isp_rd32(p + off);
    off += 4;
    switch (t) {
    case 0x1000: fprintf(o, "null\n"); return off;
    case 0x2000: fprintf(o, "bool %u\n", isp_rd32(p + off)); return off + 4;
    case 0x3000: fprintf(o, "int64 %lld (0x%llx)\n", (long long)isp_rd64(p + off), (unsigned long long)isp_rd64(p + off)); return off + 8;
    case 0x4000: fprintf(o, "uint64 %llu (0x%llx)\n", (unsigned long long)isp_rd64(p + off), (unsigned long long)isp_rd64(p + off)); return off + 8;
    case 0x5000: { double d; memcpy(&d, p + off, 8); fprintf(o, "double %g\n", d); return off + 8; }
    case 0x7000: fprintf(o, "date %lld\n", (long long)isp_rd64(p + off)); return off + 8;
    case 0x8000: {
        uint32_t l = isp_rd32(p + off);
        if (l > 16384 || off + 4 + l > n) { fprintf(o, "data len=%u (not inline; port #%d)\n", l, (*ports)++); return off + 4; }
        fprintf(o, "data len=%u\n", l);
        if (l >= 8 && isp_rd32(p + off + 4) == 0xd3) isp_osser(p + off + 4, l, depth + 1);
        else if (l % 4 == 0 && l <= 256) {
            isp_ind(depth + 1); fprintf(o, "u32:");
            for (uint32_t w = 0; w < l / 4; w++) fprintf(o, "%s0x%x", w % 8 ? " " : (w ? "\n" : " "), isp_rd32(p + off + 4 + 4 * w));
            fprintf(o, "\n");
        } else isp_hex(p + off + 4, l > 512 ? 512 : l, off + 4);
        return isp_al4(off + 4 + l);
    }
    case 0x9000: { uint32_t l = isp_rd32(p + off); fprintf(o, "string \"%.*s\"\n", (int)(l ? l - 1 : 0), (const char *)p + off + 4);
                   return isp_al4(off + 4 + l); }
    case 0xa000: fprintf(o, "uuid "); for (int i = 0; i < 16; i++) fprintf(o, "%02x", p[off + i]); fprintf(o, "\n"); return off + 16;
    case 0xb000: fprintf(o, "fd (port #%d)\n", (*ports)++); return off;
    case 0xc000: fprintf(o, "shmem size=%u word2=%u (port #%d)\n", isp_rd32(p + off), isp_rd32(p + off + 4), (*ports)++); return off + 8;
    case 0xd000: fprintf(o, "mach_send (port #%d)\n", (*ports)++); return off;
    case 0x15000: fprintf(o, "mach_recv (port #%d)\n", (*ports)++); return off;
    case 0xe000: {
        uint32_t len = isp_rd32(p + off), cnt = isp_rd32(p + off + 4);
        fprintf(o, "array bytes=%u count=%u\n", len, cnt);
        size_t q = off + 8;
        for (uint32_t i = 0; i < cnt && q < n; i++) { isp_ind(depth + 1); fprintf(o, "[%u] ", i); q = isp_xpc(p, n, q, depth + 1, ports); }
        return q;
    }
    case 0xf000: {
        uint32_t len = isp_rd32(p + off), cnt = isp_rd32(p + off + 4);
        fprintf(o, "dictionary bytes=%u count=%u\n", len, cnt);
        size_t q = off + 8;
        for (uint32_t i = 0; i < cnt && q < n; i++) {
            const char *k = (const char *)p + q;
            size_t kl = strnlen(k, n - q);
            isp_ind(depth + 1); fprintf(o, "\"%s\" = ", k);
            q = isp_al4(q + kl + 1);
            q = isp_xpc(p, n, q, depth + 1, ports);
        }
        return q;
    }
    default:
        fprintf(o, "UNKNOWN type 0x%x at 0x%zx\n", t, off - 4);
        return n;
    }
}


static const char *isp_disp(unsigned d)
{
    switch (d) {
    case 0: return "none"; case 16: return "RECEIVE"; case 17: return "SEND"; case 18: return "SEND_ONCE";
    case 19: return "COPY_SEND"; case 20: return "MAKE_SEND"; case 21: return "MAKE_SEND_ONCE";
    default: return "?";
    }
}

/* Optional: is a received send right a memory entry? Map it read-only. */
static void isp_maptest(mach_port_t p)
{
    if (!g_isp_maptest || !MACH_PORT_VALID(p)) return;
    mach_port_type_t ty = 0;
    mach_port_type(mach_task_self(), p, &ty);
    static const vm_size_t sizes[] = { 0x4000, 0x1000 };
    for (int i = 0; i < 2; i++) {
        vm_address_t a = 0;
        kern_return_t kr = vm_map(mach_task_self(), &a, sizes[i], 0, VM_FLAGS_ANYWHERE, p, 0, FALSE,
                                  VM_PROT_READ, VM_PROT_READ, VM_INHERIT_NONE);
        fprintf(g_isp_out, "      maptest port 0x%x type 0x%x size 0x%lx: kr=0x%x\n", p, ty, (unsigned long)sizes[i], kr);
        if (kr == KERN_SUCCESS) {
            vm_address_t ra = a; vm_size_t rs = 0; natural_t depth = 0;
            vm_region_submap_info_data_64_t info;
            mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
            if (!vm_region_recurse_64(mach_task_self(), &ra, &rs, &depth, (vm_region_recurse_info_t)&info, &cnt))
                fprintf(g_isp_out, "      mapped: size 0x%lx prot %d max %d share_mode %d user_tag %d obj 0x%x\n",
                        (unsigned long)rs, info.protection, info.max_protection, info.share_mode, info.user_tag, info.object_id);
            vm_deallocate(mach_task_self(), a, sizes[i]);
            return;
        }
    }
}

static void isp_dump(const char *tag, int conn, mach_msg_header_t *h, int with_trailer)
{
    FILE *o = g_isp_out;
    const uint8_t *b = (const uint8_t *)h;
    uint32_t bits = h->msgh_bits;
    fprintf(o, "== #%d t=%.3fms conn %d %s on=0x%x: bits=0x%08x (remote=%s local=%s voucher=%s%s) size=%u id=%d (0x%x)\n",
            ++g_isp_seq, (isp_now_us() - g_isp_t0) / 1000.0, conn, tag, h->msgh_local_port, bits, isp_disp(bits & 0x1f),
            isp_disp((bits >> 8) & 0x1f), isp_disp((bits >> 16) & 0x1f),
            (bits & MACH_MSGH_BITS_COMPLEX) ? " COMPLEX" : "", h->msgh_size, h->msgh_id, h->msgh_id);
    size_t off = sizeof(mach_msg_header_t);
    int ports = 0;
    if (bits & MACH_MSGH_BITS_COMPLEX) {
        uint32_t cnt = isp_rd32(b + off);
        fprintf(o, "  descriptors: %u\n", cnt);
        off += 4;
        for (uint32_t i = 0; i < cnt && off < h->msgh_size; i++) {
            uint8_t type = b[off + 11];
            if (type == MACH_MSG_PORT_DESCRIPTOR) {
                mach_port_t pn = isp_rd32(b + off);
                fprintf(o, "  [%u] PORT name=0x%x disp=%s\n", i, pn, isp_disp(b[off + 10]));
                if (b[off + 10] == 17) isp_maptest(pn);
                off += 12;
            } else if (type == MACH_MSG_OOL_DESCRIPTOR || type == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) {
                uint64_t a = isp_rd64(b + off);
                uint32_t sz = isp_rd32(b + off + 12);
                fprintf(o, "  [%u] OOL size=%u dealloc=%u copy=%u\n", i, sz, b[off + 8], b[off + 9]);
                if (a && sz >= 8 && isp_magic(isp_rd32((const uint8_t *)(uintptr_t)a))) {
                    fprintf(o, "  OOL XPC payload: version=%u root=", isp_rd32((const uint8_t *)(uintptr_t)a + 4));
                    int pp = 0;
                    isp_xpc((const uint8_t *)(uintptr_t)a, sz, 8, 1, &pp);
                } else if (a && sz) {
                    isp_hex((const uint8_t *)(uintptr_t)a, sz > 256 ? 256 : sz, 0);
                }
                off += 16;
            } else if (type == MACH_MSG_OOL_PORTS_DESCRIPTOR) {
                fprintf(o, "  [%u] OOL_PORTS count=%u disp=%s\n", i, isp_rd32(b + off + 12), isp_disp(b[off + 10]));
                off += 16;
            } else {
                fprintf(o, "  [%u] descriptor type %u\n", i, type);
                off += 16;
            }
        }
    }
    size_t end = h->msgh_size;
    fprintf(o, "  inline body: offset %zu, %zu bytes\n", off, end > off ? end - off : 0);
    int found = 0;
    for (size_t q = off; q + 8 <= end; q += 4)
        if (isp_magic(isp_rd32(b + q))) {
            if (q > off) isp_hex(b + off, q - off, off);
            fprintf(o, "  XPC @%zu version=%u root=", q, isp_rd32(b + q + 4));
            isp_xpc(b, end, q + 8, 1, &ports);
            found = 1;
            break;
        }
    if (!found && end > off) isp_hex(b + off, end - off > 1024 ? 1024 : end - off, off);
    if (with_trailer) {
        mach_msg_audit_trailer_t *t = (mach_msg_audit_trailer_t *)(b + isp_al4(end));
        if (t->msgh_trailer_size >= sizeof(mach_msg_audit_trailer_t))
            fprintf(o, "  sender pid %d\n", (int)t->msgh_audit.val[5]);
    }
    fflush(o);
}

static int isp_find(mach_port_t rcv)
{
    for (int i = 0; i < g_isp_n; i++) if (g_isp[i].rcv == rcv) return i;
    return -1;
}

/* Make a new proxy port whose messages go to dst. Returns the receive right name. */
static mach_port_t isp_new_proxy(mach_port_t dst, int once, int dir, int conn)
{
    mach_port_t p = MACH_PORT_NULL;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &p);
    mach_port_move_member(mach_task_self(), p, g_isp_set);
    pthread_mutex_lock(&g_isp_mtx);
    if (g_isp_n < ISP_MAX) g_isp[g_isp_n++] = (isp_entry){ p, dst, once, dir, conn };
    pthread_mutex_unlock(&g_isp_mtx);
    return p;
}

/* Add an existing receive right (kept by us) as a proxy for dst. */
static void isp_add_existing(mach_port_t rcv, mach_port_t dst, int once, int dir, int conn)
{
    mach_port_move_member(mach_task_self(), rcv, g_isp_set);
    pthread_mutex_lock(&g_isp_mtx);
    if (g_isp_n < ISP_MAX) g_isp[g_isp_n++] = (isp_entry){ rcv, dst, once, dir, conn };
    pthread_mutex_unlock(&g_isp_mtx);
}

static void isp_remove(int i)
{
    pthread_mutex_lock(&g_isp_mtx);
    mach_port_t r = g_isp[i].rcv;
    g_isp[i] = g_isp[--g_isp_n];
    pthread_mutex_unlock(&g_isp_mtx);
    mach_port_mod_refs(mach_task_self(), r, MACH_PORT_RIGHT_RECEIVE, -1);
}

static void *isp_thread(void *arg)
{
    (void)arg;
    uint8_t *buf = malloc(ISP_BUF);
    for (;;) {
        mach_msg_header_t *h = (mach_msg_header_t *)buf;
        kern_return_t kr = mach_msg(h, MACH_RCV_MSG | MACH_RCV_LARGE | MACH_RCV_VOUCHER |
                                    MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                                    MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                                    0, ISP_BUF, g_isp_set, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) { fprintf(g_isp_out, "isp: receive 0x%x\n", kr); fflush(g_isp_out); usleep(1000); continue; }
        pthread_mutex_lock(&g_isp_mtx);
        int i = isp_find(h->msgh_local_port);
        isp_entry e = i >= 0 ? g_isp[i] : (isp_entry){ 0 };
        pthread_mutex_unlock(&g_isp_mtx);
        if (i < 0) { fprintf(g_isp_out, "isp: message on unknown port 0x%x\n", h->msgh_local_port); continue; }
        const char *tag = e.dir ? "S>C" : "C>S";
        char tagbuf[64];
        if (h->msgh_id == ISP_HANDSHAKE) {
            e.conn = ++g_isp_conn;
            snprintf(tagbuf, sizeof tagbuf, "%s HANDSHAKE", tag);
            tag = tagbuf;
        } else if (e.once) {
            snprintf(tagbuf, sizeof tagbuf, "%s (reply)", tag);
            tag = tagbuf;
        }
        if (h->msgh_bits & MACH_MSGH_BITS_COMPLEX) {
            /* Notifications (no-senders etc.) come from the kernel and carry no payload of interest. */
        }
        isp_dump(tag, e.conn, h, 1);
        unsigned rtype = MACH_MSGH_BITS_REMOTE(h->msgh_bits);  /* received reply right type */
        unsigned vtype = MACH_MSGH_BITS_VOUCHER(h->msgh_bits);
        unsigned complex = h->msgh_bits & MACH_MSGH_BITS_COMPLEX;
        mach_port_t reply = h->msgh_remote_port;
        unsigned newlocal = 0;
        mach_port_t local = MACH_PORT_NULL;
        if (MACH_PORT_VALID(reply) && (rtype == 17 || rtype == 18)) {
            local = isp_new_proxy(reply, rtype == 18, !e.dir, e.conn);
            newlocal = rtype == 18 ? MACH_MSG_TYPE_MAKE_SEND_ONCE : MACH_MSG_TYPE_MAKE_SEND;
            fprintf(g_isp_out, "  (relay: reply right %s proxied by 0x%x)\n", rtype == 18 ? "send-once" : "send", local);
        }
        if (complex) {
            uint8_t *b = buf;
            size_t off = 28;
            uint32_t cnt = isp_rd32(b + 24);
            for (uint32_t k = 0; k < cnt; k++) {
                uint8_t type = b[off + 11];
                if (type == MACH_MSG_PORT_DESCRIPTOR) {
                    mach_port_t pn = isp_rd32(b + off);
                    uint8_t d = b[off + 10];
                    if (h->msgh_id == ISP_HANDSHAKE && MACH_PORT_VALID(pn)) {
                        if (d == 16) {
                            /* Keep the sender's receive right; hand on a new one. */
                            mach_port_t fresh = MACH_PORT_NULL;
                            mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &fresh);
                            mach_port_insert_right(mach_task_self(), fresh, fresh, MACH_MSG_TYPE_MAKE_SEND);
                            isp_add_existing(pn, fresh, 0, e.dir, e.conn);
                            memcpy(b + off, &fresh, 4);
                            b[off + 10] = MACH_MSG_TYPE_MOVE_RECEIVE;
                            fprintf(g_isp_out, "  (relay: descriptor %u receive right kept as 0x%x, new 0x%x handed on)\n", k, pn, fresh);
                        } else if (d == 17 || d == 18) {
                            mach_port_t px = isp_new_proxy(pn, d == 18, !e.dir, e.conn);
                            memcpy(b + off, &px, 4);
                            b[off + 10] = d == 18 ? MACH_MSG_TYPE_MAKE_SEND_ONCE : MACH_MSG_TYPE_MAKE_SEND;
                            fprintf(g_isp_out, "  (relay: descriptor %u send right 0x%x proxied by 0x%x)\n", k, pn, px);
                        }
                    }
                    off += 12;
                    continue;
                }
                if (type == MACH_MSG_OOL_DESCRIPTOR || type == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) {
                    b[off + 8] = 1; b[off + 9] = MACH_MSG_VIRTUAL_COPY;
                } else if (type == MACH_MSG_OOL_PORTS_DESCRIPTOR) {
                    b[off + 8] = 1;
                }
                off += 16;
            }
        }
        h->msgh_remote_port = e.dst;
        h->msgh_local_port = local;
        if (!vtype) h->msgh_voucher_port = MACH_PORT_NULL;
        h->msgh_bits = MACH_MSGH_BITS_SET(e.once ? MACH_MSG_TYPE_MOVE_SEND_ONCE : MACH_MSG_TYPE_COPY_SEND,
                                          newlocal, vtype ? MACH_MSG_TYPE_MOVE_SEND : 0, complex);
        kr = mach_msg(h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, h->msgh_size, 0, MACH_PORT_NULL, 3000, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) {
            fprintf(g_isp_out, "  relay send failed 0x%x\n", kr);
            if (kr == MACH_SEND_INVALID_DEST && i >= 0) { /* destination gone */ }
            mach_msg_destroy(h);
        }
        if (e.once) {
            pthread_mutex_lock(&g_isp_mtx);
            int j = isp_find(e.rcv);
            pthread_mutex_unlock(&g_isp_mtx);
            if (j >= 0) isp_remove(j);
        }
        fflush(g_isp_out);
    }
    return NULL;
}

static void isp_start(FILE *out)
{
    static int started;
    if (started) return;
    started = 1;
    g_isp_out = out;
    g_isp_t0 = isp_now_us();
    g_isp_maptest = getenv("YC_IS_MAPTEST") != NULL;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_PORT_SET, &g_isp_set);
    pthread_t t;
    pthread_create(&t, NULL, isp_thread, NULL);
    pthread_detach(t);
}

/* Make the first-level proxy for a service send right. Returns a receive right
 * name; the caller hands out a send right made from it. */
static mach_port_t isp_service_proxy(mach_port_t service)
{
    return isp_new_proxy(service, 0, 0, 0);
}
#endif
