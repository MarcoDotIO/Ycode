/*
 * isserver.h: a minimal com.apple.IOSurface.Remote server written from the
 * R5 captures (original Ycode code). It speaks the wire format described in
 * specs/simulator/iosurface-remote.md with raw Mach messages: the connection
 * hand-shake, "!CPX" request/reply dictionaries, OSSerialize-binary property
 * blobs, shared memory as memory-entry send rights, and per-surface ports.
 * It is a test double used to check which parts of the protocol clients need;
 * it is not Ycode's implementation.
 *
 * Switches (environment):
 *   YC_SRV_MAGIC=cpx      reply with "?cpx" instead of "!CPX"
 *   YC_SRV_NOSTATE=1      omit SurfaceState from every reply except create/lookup
 *   YC_SRV_NOLIMITS=1     omit Limits from the Method 0 reply
 *   YC_SRV_LOG=<file>     log one line per request
 *   YC_SRV_REFUSE=a,b     answer these Method numbers with ErrorCode kIOReturnUnsupported only
 *   YC_SRV_FREEZESEED=1   (R6) never increment the seed on lock (SurfaceState still sent)
 * R6 copy of R5's ../iosurface-remote/isserver.h; the only change is the switch above.
 * Call srv_start() once; srv_port() returns a send right to the service port.
 */
#ifndef ISSERVER_H
#define ISSERVER_H
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SRV_BUF (256 * 1024)
#define SRV_PAGE 16384u
#define SRV_ERR_BADARG 0xffffffffe00002c2ull
#define SRV_ERR_NOTFOUND 0xffffffffe00002f0ull
#define SRV_ERR_UNSUPPORTED 0xffffffffe00002c7ull

/* ------------------------------------------------------------ surfaces */

typedef struct srv_surface {
    uint32_t id, width, height, bpr, bpe, ew, eh, fmt, cache, planes, seed, casting, counter;
    uint64_t alloc, mapsize;
    int purge, use, refs, locks;
    vm_address_t mem;
    mach_port_t entry, port;
    CFMutableDictionaryRef values;    /* IOSurfaceSetValue values, plus CreationProperties */
    CFMutableDictionaryRef attach;    /* bulk attachments (Method 20/21) */
    CFArrayRef planeinfo;
    struct srv_surface *next;
} srv_surface;

typedef struct srv_ref { srv_surface *s; int n; struct srv_ref *next; } srv_ref;
typedef struct srv_conn { mach_port_t rcv, client; int pid; srv_ref *refs; struct srv_conn *next; } srv_conn;

static srv_surface *g_srv_surfaces;
static srv_conn *g_srv_conns;
static uint32_t g_srv_nextid = 0x100, g_srv_counter = 0x10000;
static mach_port_t g_srv_service, g_srv_set;
static FILE *g_srv_log;

static srv_surface *srv_find_id(uint32_t id)
{
    for (srv_surface *s = g_srv_surfaces; s; s = s->next) if (s->id == id) return s;
    return NULL;
}
static srv_surface *srv_find_port(mach_port_t p)
{
    for (srv_surface *s = g_srv_surfaces; s; s = s->next) if (s->port == p) return s;
    return NULL;
}
static void srv_addref(srv_conn *c, srv_surface *s, int d)
{
    for (srv_ref **pp = &c->refs; *pp; pp = &(*pp)->next) {
        srv_ref *r = *pp;
        if (r->s != s) continue;
        if (d < 0 && r->n <= 0) return;
        r->n += d; s->refs += d;
        if (r->n <= 0) { *pp = r->next; free(r); }
        return;
    }
    if (d <= 0) return;
    srv_ref *r = calloc(1, sizeof *r);
    r->s = s; r->n = d; r->next = c->refs; c->refs = r; s->refs += d;
}
static void srv_free_if_unused(srv_surface *s)
{
    if (s->refs > 0) return;
    srv_surface **pp = &g_srv_surfaces;
    while (*pp && *pp != s) pp = &(*pp)->next;
    if (*pp) *pp = s->next;
    vm_deallocate(mach_task_self(), s->mem, s->mapsize);
    mach_port_deallocate(mach_task_self(), s->entry);
    if (s->port) mach_port_mod_refs(mach_task_self(), s->port, MACH_PORT_RIGHT_RECEIVE, -1);
    if (s->values) CFRelease(s->values);
    if (s->attach) CFRelease(s->attach);
    if (s->planeinfo) CFRelease(s->planeinfo);
    free(s);
}

/* ------------------------------------------- OSSerialize binary (level 1) */

typedef struct { const uint8_t *p; size_t n, q; CFTypeRef objs[1024]; int nobj; } osr;

static uint32_t srv_rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t srv_rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static size_t srv_al4(size_t x) { return (x + 3) & ~(size_t)3; }

static CFTypeRef os_read(osr *r, int *last)
{
    if (r->q + 4 > r->n) return NULL;
    uint32_t k = srv_rd32(r->p + r->q);
    r->q += 4;
    uint32_t ty = k & 0x7F000000u, len = k & 0x00FFFFFFu;
    *last = (int)(k >> 31);
    CFTypeRef o = NULL;
    int slot = r->nobj < 1024 ? r->nobj++ : -1;
    switch (ty) {
    case 0x01000000: {
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (slot >= 0) r->objs[slot] = d;
        for (uint32_t i = 0; i < len; i++) {
            int l1 = 0, l2 = 0;
            CFTypeRef key = os_read(r, &l1), val = os_read(r, &l2);
            if (key && val) CFDictionarySetValue(d, key, val);
            if (key) CFRelease(key);
            if (val) CFRelease(val);
        }
        return d;
    }
    case 0x02000000: case 0x03000000: {
        CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        if (slot >= 0) r->objs[slot] = a;
        for (uint32_t i = 0; i < len; i++) {
            int l = 0;
            CFTypeRef v = os_read(r, &l);
            if (v) { CFArrayAppendValue(a, v); CFRelease(v); }
        }
        return a;
    }
    case 0x04000000: {
        long long v = (long long)srv_rd64(r->p + r->q);
        r->q += 8;
        o = CFNumberCreate(NULL, kCFNumberLongLongType, &v);
        break;
    }
    case 0x08000000: case 0x09000000: {
        size_t l = len;
        if (ty == 0x08000000 && l) l--; /* symbol length includes the NUL */
        o = CFStringCreateWithBytes(NULL, r->p + r->q, (CFIndex)l, kCFStringEncodingUTF8, false);
        r->q += srv_al4(len);
        break;
    }
    case 0x0a000000: o = CFDataCreate(NULL, r->p + r->q, len); r->q += srv_al4(len); break;
    case 0x0b000000: o = CFRetain(len ? kCFBooleanTrue : kCFBooleanFalse); break;
    case 0x0c000000:
        if (slot >= 0) r->nobj--; /* references are not added to the table */
        return len < (uint32_t)r->nobj && r->objs[len] ? CFRetain(r->objs[len]) : NULL;
    default: return NULL;
    }
    if (slot >= 0) r->objs[slot] = o;
    return o;
}

static CFTypeRef os_parse(const uint8_t *p, size_t n)
{
    if (n < 8 || srv_rd32(p) != 0xd3) return NULL;
    osr *r = calloc(1, sizeof *r);
    r->p = p; r->n = n; r->q = 4;
    int last = 0;
    CFTypeRef o = os_read(r, &last);
    free(r);
    return o;
}

typedef struct { uint8_t *b; size_t n, cap; } wb;
static void wb_put(wb *w, const void *d, size_t l)
{
    if (w->n + l + 8 > w->cap) { w->cap = (w->n + l + 8) * 2; w->b = realloc(w->b, w->cap); }
    memcpy(w->b + w->n, d, l); w->n += l;
}
static void wb_32(wb *w, uint32_t v) { wb_put(w, &v, 4); }
static void wb_64(wb *w, uint64_t v) { wb_put(w, &v, 8); }
static void wb_pad(wb *w) { while (w->n & 3) { uint8_t z = 0; wb_put(w, &z, 1); } }

static void os_write(wb *w, CFTypeRef o, int last, int as_symbol)
{
    uint32_t e = last ? 0x80000000u : 0;
    CFTypeID t = CFGetTypeID(o);
    if (t == CFDictionaryGetTypeID()) {
        CFIndex n = CFDictionaryGetCount(o);
        wb_32(w, e | 0x01000000u | (uint32_t)n);
        const void **k = malloc(sizeof(void *) * (n + 1)), **v = malloc(sizeof(void *) * (n + 1));
        CFDictionaryGetKeysAndValues(o, k, v);
        for (CFIndex i = 0; i < n; i++) { os_write(w, k[i], 0, 1); os_write(w, v[i], i == n - 1, 0); }
        free(k); free(v);
    } else if (t == CFArrayGetTypeID()) {
        CFIndex n = CFArrayGetCount(o);
        wb_32(w, e | 0x02000000u | (uint32_t)n);
        for (CFIndex i = 0; i < n; i++) os_write(w, CFArrayGetValueAtIndex(o, i), i == n - 1, 0);
    } else if (t == CFNumberGetTypeID()) {
        long long v = 0;
        CFNumberGetValue(o, kCFNumberLongLongType, &v);
        wb_32(w, e | 0x04000000u | 64);
        wb_64(w, (uint64_t)v);
    } else if (t == CFStringGetTypeID()) {
        char buf[4096];
        CFStringGetCString(o, buf, sizeof buf, kCFStringEncodingUTF8);
        size_t l = strlen(buf);
        if (as_symbol) { wb_32(w, e | 0x08000000u | (uint32_t)(l + 1)); wb_put(w, buf, l + 1); }
        else { wb_32(w, e | 0x09000000u | (uint32_t)l); wb_put(w, buf, l); }
        wb_pad(w);
    } else if (t == CFDataGetTypeID()) {
        wb_32(w, e | 0x0a000000u | (uint32_t)CFDataGetLength(o));
        wb_put(w, CFDataGetBytePtr(o), (size_t)CFDataGetLength(o));
        wb_pad(w);
    } else if (t == CFBooleanGetTypeID()) {
        wb_32(w, e | 0x0b000000u | (CFBooleanGetValue(o) ? 1 : 0));
    } else {
        wb_32(w, e | 0x0b000000u);
    }
}

/* ------------------------------------------------------- XPC payload I/O */

typedef struct { const uint8_t *p; size_t n; } xin;

/* Find a top-level key; returns offset of its value object or 0. Counts the
 * port-bearing objects before it (descriptor index) in *portidx. */
static size_t x_skip(const uint8_t *p, size_t n, size_t off, int *ports)
{
    if (off + 4 > n) return n;
    uint32_t t = srv_rd32(p + off);
    off += 4;
    switch (t) {
    case 0x1000: return off;
    case 0x2000: return off + 4;
    case 0x3000: case 0x4000: case 0x5000: case 0x7000: return off + 8;
    case 0x8000: { uint32_t l = srv_rd32(p + off); if (l > 16384) { (*ports)++; return off + 4; } return srv_al4(off + 4 + l); }
    case 0x9000: return srv_al4(off + 4 + srv_rd32(p + off));
    case 0xa000: return off + 16;
    case 0xb000: case 0xd000: case 0x15000: (*ports)++; return off;
    case 0xc000: (*ports)++; return off + 8;
    case 0xe000: case 0xf000: {
        uint32_t cnt = srv_rd32(p + off + 4);
        size_t q = off + 8;
        for (uint32_t i = 0; i < cnt && q < n; i++) {
            if (t == 0xf000) q = srv_al4(q + strnlen((const char *)p + q, n - q) + 1);
            q = x_skip(p, n, q, ports);
        }
        return q;
    }
    default: return n;
    }
}
static size_t x_find(xin *x, const char *key, int *portidx)
{
    /* magic, version, dictionary tag, byte length, count, entries */
    if (x->n < 20) return 0;
    uint32_t cnt = srv_rd32(x->p + 16);
    size_t q = 20;
    int ports = 0;
    for (uint32_t i = 0; i < cnt && q < x->n; i++) {
        const char *k = (const char *)x->p + q;
        q = srv_al4(q + strnlen(k, x->n - q) + 1);
        if (!strcmp(k, key)) { if (portidx) *portidx = ports; return q; }
        q = x_skip(x->p, x->n, q, &ports);
    }
    return 0;
}
static int x_u64(xin *x, const char *key, uint64_t *v)
{
    size_t o = x_find(x, key, NULL);
    if (!o) return 0;
    uint32_t t = srv_rd32(x->p + o);
    if (t == 0x4000 || t == 0x3000) { *v = srv_rd64(x->p + o + 4); return 1; }
    if (t == 0x2000) { *v = srv_rd32(x->p + o + 4); return 1; }
    return 0;
}

typedef struct { wb w; size_t lenoff; uint32_t count; mach_port_t ports[8]; int disp[8]; int nports; } xout;
static void xo_begin(xout *o)
{
    memset(o, 0, sizeof *o);
    const char *m = getenv("YC_SRV_MAGIC");
    wb_32(&o->w, m && !strcmp(m, "cpx") ? 0x7870633fu : 0x58504321u); /* "?cpx" or "!CPX" */
    wb_32(&o->w, 5);
    wb_32(&o->w, 0xf000);
    o->lenoff = o->w.n;
    wb_32(&o->w, 0);
    wb_32(&o->w, 0);
}
static void xo_key(xout *o, const char *k) { wb_put(&o->w, k, strlen(k) + 1); wb_pad(&o->w); o->count++; }
static void xo_u64(xout *o, const char *k, uint64_t v) { xo_key(o, k); wb_32(&o->w, 0x4000); wb_64(&o->w, v); }
static void xo_bool(xout *o, const char *k, int v) { xo_key(o, k); wb_32(&o->w, 0x2000); wb_32(&o->w, v ? 1 : 0); }
static void xo_data(xout *o, const char *k, const void *d, uint32_t l)
{ xo_key(o, k); wb_32(&o->w, 0x8000); wb_32(&o->w, l); wb_put(&o->w, d, l); wb_pad(&o->w); }
static void xo_port(xout *o, const char *k, uint32_t tag, mach_port_t p, int disp, uint32_t size)
{
    xo_key(o, k);
    wb_32(&o->w, tag);
    if (tag == 0xc000) { wb_32(&o->w, size); wb_32(&o->w, 0); }
    o->ports[o->nports] = p; o->disp[o->nports++] = disp;
}
static void xo_end(xout *o)
{
    uint32_t len = (uint32_t)(o->w.n - o->lenoff - 4);
    memcpy(o->w.b + o->lenoff, &len, 4);
    memcpy(o->w.b + o->lenoff + 4, &o->count, 4);
}

static void srv_state(xout *o, srv_surface *s)
{
    uint32_t st[18] = { 0, s->id, (uint32_t)s->alloc, s->width, s->height, s->bpr, 0, s->fmt, s->cache, s->planes,
                        s->bpe, s->ew, s->eh, s->seed, 0, (s->counter << 8) | (s->casting & 0xff), 1, 1 };
    xo_data(o, "SurfaceState", st, sizeof st);
}

static void srv_send_reply(mach_port_t reply, xout *o)
{
    xo_end(o);
    size_t hdr = sizeof(mach_msg_header_t) + (o->nports ? 4 + 12 * (size_t)o->nports : 0);
    size_t total = hdr + o->w.n;
    uint8_t *m = calloc(1, total + 64);
    mach_msg_header_t *h = (mach_msg_header_t *)m;
    h->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0, 0, o->nports ? MACH_MSGH_BITS_COMPLEX : 0);
    h->msgh_size = (mach_msg_size_t)total;
    h->msgh_remote_port = reply;
    h->msgh_id = 0x20000000;
    if (o->nports) {
        uint32_t c = (uint32_t)o->nports;
        memcpy(m + sizeof *h, &c, 4);
        for (int i = 0; i < o->nports; i++) {
            mach_msg_port_descriptor_t *d = (void *)(m + sizeof *h + 4 + 12 * i);
            d->name = o->ports[i];
            d->disposition = (mach_msg_type_name_t)o->disp[i];
            d->type = MACH_MSG_PORT_DESCRIPTOR;
        }
    }
    memcpy(m + hdr, o->w.b, o->w.n);
    kern_return_t kr = mach_msg(h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, (mach_msg_size_t)total, 0, MACH_PORT_NULL, 2000, MACH_PORT_NULL);
    if (kr && g_srv_log) fprintf(g_srv_log, "srv: reply send 0x%x\n", kr);
    free(m);
    free(o->w.b);
}

static uint32_t num_of(CFDictionaryRef d, const char *key, uint32_t def)
{
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = CFDictionaryGetValue(d, k);
    CFRelease(k);
    long long x = def;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongLongType, &x);
    if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) x = CFBooleanGetValue(v);
    return (uint32_t)x;
}

static srv_surface *srv_create(CFDictionaryRef p)
{
    srv_surface *s = calloc(1, sizeof *s);
    s->width = num_of(p, "IOSurfaceWidth", 0);
    s->height = num_of(p, "IOSurfaceHeight", 0);
    if (!s->width || !s->height || s->width > 0x4000 || s->height > 0x4000) { free(s); return NULL; }
    s->bpe = num_of(p, "IOSurfaceBytesPerElement", 1);
    if (!s->bpe) s->bpe = 1;
    s->ew = num_of(p, "IOSurfaceElementWidth", 1);
    s->eh = num_of(p, "IOSurfaceElementHeight", 1);
    if (!s->ew) s->ew = 1;
    if (!s->eh) s->eh = 1;
    s->fmt = num_of(p, "IOSurfacePixelFormat", 0);
    s->cache = num_of(p, "IOSurfaceCacheMode", 0);
    s->casting = num_of(p, "IOSurfacePixelSizeCastingAllowed", 1);
    uint32_t rowel = (s->width + s->ew - 1) / s->ew;
    s->bpr = num_of(p, "IOSurfaceBytesPerRow", 0);
    if (!s->bpr) s->bpr = (rowel * s->bpe + 127) & ~127u;
    s->alloc = num_of(p, "IOSurfaceAllocSize", 0);
    CFTypeRef pi = CFDictionaryGetValue(p, CFSTR("IOSurfacePlaneInfo"));
    if (pi && CFGetTypeID(pi) == CFArrayGetTypeID()) { s->planeinfo = CFRetain(pi); s->planes = (uint32_t)CFArrayGetCount(pi); }
    if (!s->alloc) s->alloc = ((uint64_t)s->bpr * ((s->height + s->eh - 1) / s->eh) + SRV_PAGE - 1) & ~(uint64_t)(SRV_PAGE - 1);
    s->mapsize = (s->alloc + SRV_PAGE - 1) & ~(uint64_t)(SRV_PAGE - 1);
    if (vm_allocate(mach_task_self(), &s->mem, s->mapsize, VM_FLAGS_ANYWHERE)) { free(s); return NULL; }
    memory_object_size_t sz = s->mapsize;
    if (mach_make_memory_entry_64(mach_task_self(), &sz, s->mem, VM_PROT_READ | VM_PROT_WRITE, &s->entry, MACH_PORT_NULL)) {
        vm_deallocate(mach_task_self(), s->mem, s->mapsize); free(s); return NULL;
    }
    s->id = g_srv_nextid++;
    s->counter = g_srv_counter++;
    s->values = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    s->attach = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFTypeRef nm = CFDictionaryGetValue(p, CFSTR("IOSurfaceName"));
    if (nm) CFDictionarySetValue(s->values, CFSTR("IOSurfaceName"), nm);
    CFDictionarySetValue(s->values, CFSTR("CreationProperties"), p);
    s->next = g_srv_surfaces;
    g_srv_surfaces = s;
    return s;
}

static const char *g_attach_u64[] = { "ChromaLocationTopField", "ChromaLocationBottomField", "FieldCount", "FieldDetail",
    "ChromaSubsampling", "PremultipliedAlpha", "TransferFunctionIndex", "ColorPrimariesIndex", "YCbCrMatrixIndex", NULL };
static const struct { const char *k; uint32_t len; } g_attach_data[] = { { "GammaLevel", 8 }, { "PixelAspectRatio", 24 },
    { "ContentLightLevelInfo", 8 }, { "EDRFactor", 8 }, { "MasteringDisplayColorVolume", 32 }, { "CleanAperture", 40 }, { NULL, 0 } };

static void srv_request(srv_conn *c, mach_msg_header_t *h)
{
    uint8_t *b = (uint8_t *)h;
    size_t off = sizeof *h;
    mach_port_t ports[16] = { 0 };
    int np = 0;
    if (h->msgh_bits & MACH_MSGH_BITS_COMPLEX) {
        uint32_t cnt = srv_rd32(b + off);
        off += 4;
        for (uint32_t i = 0; i < cnt; i++) {
            if (b[off + 11] == MACH_MSG_PORT_DESCRIPTOR) { if (np < 16) ports[np++] = srv_rd32(b + off); off += 12; }
            else off += 16;
        }
    }
    xin x = { b + off, h->msgh_size > off ? h->msgh_size - off : 0 };
    mach_port_t reply = h->msgh_remote_port;
    uint64_t method = 999, sid = 0, v = 0;
    x_u64(&x, "Method", &method);
    x_u64(&x, "SurfaceID", &sid);
    srv_surface *s = sid ? srv_find_id((uint32_t)sid) : NULL;
    xout o;
    xo_begin(&o);
    uint64_t err = 0;
    if (g_srv_log) fprintf(g_srv_log, "srv: pid %d method %llu surface %llu\n", c->pid, (unsigned long long)method, (unsigned long long)sid);
    const char *refuse = getenv("YC_SRV_REFUSE");
    if (refuse) {
        char want[16];
        snprintf(want, sizeof want, ",%llu,", (unsigned long long)method);
        char list[256];
        snprintf(list, sizeof list, ",%s,", refuse);
        if (strstr(list, want)) method = 1000 + method;
    }
    switch (method) {
    case 0: {
        uint32_t lim[10] = { 1, 0x3fff, 0x7f, 0x8000, 0x4000, 0x4000, 1, 0, 1, 0 };
        if (!getenv("YC_SRV_NOLIMITS")) xo_data(&o, "Limits", lim, sizeof lim);
        xo_u64(&o, "ErrorCode", 0);
        xo_u64(&o, "ProtocolVersion", 1);
        break;
    }
    case 2: {
        int pidx = -1;
        size_t po = x_find(&x, "PropertiesDictionary", NULL);
        if (po && srv_rd32(x.p + po) == 0x8000) {
            CFTypeRef props = os_parse(x.p + po + 8, srv_rd32(x.p + po + 4));
            s = props && CFGetTypeID(props) == CFDictionaryGetTypeID() ? srv_create(props) : NULL;
            if (props) CFRelease(props);
            if (!s) err = SRV_ERR_BADARG;
        } else if (x_u64(&x, "LookupID", &v)) {
            s = srv_find_id((uint32_t)v);
            if (!s) err = SRV_ERR_NOTFOUND;
        } else if (x_find(&x, "MachPort", &pidx) && pidx < np) {
            s = srv_find_port(ports[pidx]);
            if (!s) err = SRV_ERR_NOTFOUND;
        } else err = SRV_ERR_BADARG;
        if (s) {
            srv_addref(c, s, 1);
            xo_port(&o, "MemoryObject", 0xc000, s->entry, MACH_MSG_TYPE_COPY_SEND, (uint32_t)s->mapsize);
            xo_u64(&o, "ErrorCode", 0);
            srv_state(&o, s);
        } else xo_u64(&o, "ErrorCode", err);
        break;
    }
    case 1000: case 1002: case 1003:
        xo_u64(&o, "ErrorCode", SRV_ERR_UNSUPPORTED);
        break;
    case 3:
        if (s) { srv_addref(c, s, -1); xo_u64(&o, "ErrorCode", 0); srv_free_if_unused(s); s = NULL; }
        else xo_u64(&o, "ErrorCode", SRV_ERR_NOTFOUND);
        break;
    default:
        if (!s) { xo_u64(&o, "ErrorCode", SRV_ERR_NOTFOUND); break; }
        switch (method) {
        case 4: x_u64(&x, "Options", &v); if (!(v & 1) && !getenv("YC_SRV_FREEZESEED")) s->seed++; s->locks++; break;
        case 5: x_u64(&x, "Options", &v); if (s->locks > 0) s->locks--; else err = SRV_ERR_BADARG; break;
        case 9: {
            size_t po = x_find(&x, "PropertiesDictionary", NULL);
            CFTypeRef d = po ? os_parse(x.p + po + 8, srv_rd32(x.p + po + 4)) : NULL;
            if (d && CFGetTypeID(d) == CFDictionaryGetTypeID()) {
                CFTypeRef key = CFDictionaryGetValue(d, CFSTR("key")), val = CFDictionaryGetValue(d, CFSTR("value"));
                if (CFDictionaryGetValue(d, CFSTR("isSetValues")) && val && CFGetTypeID(val) == CFDictionaryGetTypeID()) {
                    CFIndex n = CFDictionaryGetCount(val);
                    const void **k = malloc(sizeof(void *) * (n + 1)), **vv = malloc(sizeof(void *) * (n + 1));
                    CFDictionaryGetKeysAndValues(val, k, vv);
                    for (CFIndex i = 0; i < n; i++) CFDictionarySetValue(s->values, k[i], vv[i]);
                    free(k); free(vv);
                } else if (key && val) CFDictionarySetValue(s->values, key, val);
                else err = SRV_ERR_BADARG;
            } else err = SRV_ERR_BADARG;
            if (d) CFRelease(d);
            break;
        }
        case 10: {
            wb w = { 0 };
            wb_32(&w, 0xd3);
            os_write(&w, s->values, 1, 0);
            xo_data(&o, "PropertiesDictionary", w.b, (uint32_t)w.n);
            free(w.b);
            break;
        }
        case 11: {
            size_t ko = x_find(&x, "PropertyKey", NULL);
            if (ko && srv_rd32(x.p + ko) == 0x9000) {
                CFStringRef k = CFStringCreateWithCString(NULL, (const char *)x.p + ko + 8, kCFStringEncodingUTF8);
                CFDictionaryRemoveValue(s->values, k);
                CFRelease(k);
            }
            break;
        }
        case 12: {
            CFTypeRef cp = CFDictionaryGetValue(s->values, CFSTR("CreationProperties"));
            if (cp) CFRetain(cp);
            CFDictionaryRemoveAllValues(s->values);
            if (cp) { CFDictionarySetValue(s->values, CFSTR("CreationProperties"), cp); CFRelease(cp); }
            break;
        }
        case 13: {
            x_u64(&x, "NewState", &v);
            xo_u64(&o, "OldState", (uint64_t)s->purge);
            if ((v & 0xff) != 3) s->purge = (int)(v & 0xff);
            break;
        }
        case 14:
            if (!s->port) mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &s->port);
            xo_port(&o, "MachPort", 0xd000, s->port, MACH_MSG_TYPE_MAKE_SEND, 0);
            break;
        case 15: s->use++; break;
        case 16: if (s->use > 0) s->use--; break;
        case 17: xo_bool(&o, "IsInUse", s->use > 0); break;
        case 20:
            for (int i = 0; g_attach_u64[i]; i++)
                if (x_u64(&x, g_attach_u64[i], &v)) {
                    CFStringRef k = CFStringCreateWithCString(NULL, g_attach_u64[i], kCFStringEncodingUTF8);
                    CFNumberRef n = CFNumberCreate(NULL, kCFNumberLongLongType, &v);
                    CFDictionarySetValue(s->attach, k, n);
                    CFRelease(k); CFRelease(n);
                }
            for (int i = 0; g_attach_data[i].k; i++) {
                size_t d = x_find(&x, g_attach_data[i].k, NULL);
                if (d && srv_rd32(x.p + d) == 0x8000) {
                    CFStringRef k = CFStringCreateWithCString(NULL, g_attach_data[i].k, kCFStringEncodingUTF8);
                    CFDataRef dd = CFDataCreate(NULL, x.p + d + 8, srv_rd32(x.p + d + 4));
                    CFDictionarySetValue(s->attach, k, dd);
                    CFRelease(k); CFRelease(dd);
                }
            }
            break;
        case 21:
            for (int i = 0; g_attach_u64[i]; i++) {
                CFStringRef k = CFStringCreateWithCString(NULL, g_attach_u64[i], kCFStringEncodingUTF8);
                CFNumberRef n = CFDictionaryGetValue(s->attach, k);
                long long val = !strcmp(g_attach_u64[i], "ChromaSubsampling") ? 0x80 : 0;
                if (n) CFNumberGetValue(n, kCFNumberLongLongType, &val);
                xo_u64(&o, g_attach_u64[i], (uint64_t)val);
                CFRelease(k);
            }
            for (int i = 0; g_attach_data[i].k; i++) {
                CFStringRef k = CFStringCreateWithCString(NULL, g_attach_data[i].k, kCFStringEncodingUTF8);
                CFDataRef d = CFDictionaryGetValue(s->attach, k);
                uint8_t zero[64] = { 0 };
                if (d) xo_data(&o, g_attach_data[i].k, CFDataGetBytePtr(d), (uint32_t)CFDataGetLength(d));
                else xo_data(&o, g_attach_data[i].k, zero, g_attach_data[i].len);
                CFRelease(k);
            }
            break;
        default:
            if (method >= 1000) { /* refused on purpose: ErrorCode only */
                xo_u64(&o, "ErrorCode", SRV_ERR_UNSUPPORTED);
                goto send;
            }
            err = SRV_ERR_UNSUPPORTED;
            if (g_srv_log) fprintf(g_srv_log, "srv: UNHANDLED method %llu\n", (unsigned long long)method);
        }
        xo_u64(&o, "ErrorCode", err);
        if (!getenv("YC_SRV_NOSTATE")) srv_state(&o, s);
        xo_u64(&o, "SurfaceID", s->id);
    }
send:
    if (MACH_PORT_VALID(reply)) srv_send_reply(reply, &o);
    else free(o.w.b);
    /* Received rights that we do not keep. */
    for (int i = 0; i < np; i++) if (MACH_PORT_VALID(ports[i])) mach_port_deallocate(mach_task_self(), ports[i]);
    if (h->msgh_voucher_port) mach_port_deallocate(mach_task_self(), h->msgh_voucher_port);
}

static void srv_conn_dead(srv_conn *c)
{
    for (srv_ref *r = c->refs, *nx; r; r = nx) {
        nx = r->next;
        r->s->refs -= r->n;
        srv_free_if_unused(r->s);
        free(r);
    }
    c->refs = NULL;
    if (g_srv_log) fprintf(g_srv_log, "srv: connection of pid %d closed\n", c->pid);
}

static void *srv_thread(void *arg)
{
    (void)arg;
    uint8_t *buf = malloc(SRV_BUF);
    for (;;) {
        mach_msg_header_t *h = (mach_msg_header_t *)buf;
        kern_return_t kr = mach_msg(h, MACH_RCV_MSG | MACH_RCV_LARGE | MACH_RCV_VOUCHER |
                                    MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                                    MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                                    0, SRV_BUF, g_srv_set, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr) continue;
        mach_msg_audit_trailer_t *t = (void *)(buf + srv_al4(h->msgh_size));
        int pid = (int)t->msgh_audit.val[5];
        if (h->msgh_local_port == g_srv_service) {
            if (h->msgh_id == 0x77303074 && (h->msgh_bits & MACH_MSGH_BITS_COMPLEX)) {
                mach_msg_port_descriptor_t *d = (void *)(buf + sizeof *h + 4);
                srv_conn *c = calloc(1, sizeof *c);
                c->rcv = d[0].name; c->client = d[1].name; c->pid = pid;
                c->next = g_srv_conns; g_srv_conns = c;
                mach_port_move_member(mach_task_self(), c->rcv, g_srv_set);
                mach_port_t prev = MACH_PORT_NULL;
                mach_port_request_notification(mach_task_self(), c->rcv, MACH_NOTIFY_NO_SENDERS, 0, c->rcv,
                                               MACH_MSG_TYPE_MAKE_SEND_ONCE, &prev);
                if (g_srv_log) fprintf(g_srv_log, "srv: connection from pid %d\n", pid);
            } else if (g_srv_log) fprintf(g_srv_log, "srv: unexpected id 0x%x on service port\n", h->msgh_id);
            continue;
        }
        srv_conn *c = g_srv_conns;
        while (c && c->rcv != h->msgh_local_port) c = c->next;
        if (!c) { mach_msg_destroy(h); continue; }
        if (h->msgh_id == MACH_NOTIFY_NO_SENDERS) { srv_conn_dead(c); continue; }
        srv_request(c, h);
    }
    return NULL;
}

static mach_port_t srv_start_on(mach_port_t service);
static mach_port_t srv_start(void) { return srv_start_on(MACH_PORT_NULL); }

/* Start serving; with a receive right from bootstrap_check_in, serve on it. */
static mach_port_t srv_start_on(mach_port_t service)
{
    if (g_srv_service) return g_srv_service;
    const char *lf = getenv("YC_SRV_LOG");
    if (lf) { g_srv_log = fopen(lf, "a"); if (g_srv_log) setvbuf(g_srv_log, NULL, _IOLBF, 0); }
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_PORT_SET, &g_srv_set);
    if (MACH_PORT_VALID(service)) g_srv_service = service;
    else mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &g_srv_service);
    mach_port_insert_right(mach_task_self(), g_srv_service, g_srv_service, MACH_MSG_TYPE_MAKE_SEND);
    mach_port_move_member(mach_task_self(), g_srv_service, g_srv_set);
    pthread_t th;
    pthread_create(&th, NULL, srv_thread, NULL);
    pthread_detach(th);
    return g_srv_service;
}
#endif
