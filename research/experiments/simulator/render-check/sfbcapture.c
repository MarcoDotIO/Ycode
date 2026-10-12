/*
 * sfbcapture: Ycode research prototype R6 (original Ycode code, no Apple code).
 * R4's headless stand-in for the simulator framebuffer library
 * (../simframebuffer/sfbheadless.c, written from specs/simulator/simframebuffer.md)
 * plus frame capture: it records the IOSurface of every submitted swap and can
 * save the pixels of the last presented surface. It contacts no Mach service.
 *
 * Env (all optional):
 *   SFBH_LOG=<file>        log calls (as sfbheadless)
 *   SFBH_NO_CALLBACK=1     never complete a swap (as sfbheadless)
 *   SFBH_NO_SWAPCHAIN=1    refuse swapchains (as sfbheadless)
 *   SFBC_DIR=<dir>         capture directory. Writes <dir>/frames.log, one line per
 *                          submitted swap: seq, ticks, surface id, size, bytes per row,
 *                          format, seed, and (every SFBC_STATS-th frame, default 1) a
 *                          sampled pixel summary. A capture thread polls
 *                          <dir>/snap every 250 ms; when it exists, its first line is a
 *                          name N, and the last presented surface is saved as
 *                          <dir>/N.raw (rows of bytes-per-row bytes, height rows) and
 *                          <dir>/N.txt (key=value header); then snap is removed.
 *   SFBC_NO_LOCK=1         read surfaces without IOSurfaceLock (default: read-only lock)
 *   SFBC_DELAY_CB=<ms>     complete each swap after this delay (default 0)
 *   <SFBC_DIR>/opts        optional file of K=V lines, read when the library loads and
 *                          applied with setenv in this process only (lets a restarted
 *                          backboardd get different switches without a new boot)
 *
 * CF object model: three CF runtime classes (declarations below follow the
 * public CF open-source CFRuntime.h). IOSurface calls are the public API
 * (IOSurfaceRef.h).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <sys/stat.h>
#include <unistd.h>
#include <Block.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))

/* ---- CF runtime declarations (CF open source, CFRuntime.h) ---- */
typedef struct {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef);
    CFTypeRef (*copy)(CFAllocatorRef, CFTypeRef);
    void (*finalize)(CFTypeRef);
    Boolean (*equal)(CFTypeRef, CFTypeRef);
    CFHashCode (*hash)(CFTypeRef);
    CFStringRef (*copyFormattingDesc)(CFTypeRef, CFDictionaryRef);
    CFStringRef (*copyDebugDesc)(CFTypeRef);
    void (*reclaim)(CFTypeRef);
    uint32_t (*refcount)(intptr_t, CFTypeRef);
    uintptr_t requiredAlignment;
} ycode_CFRuntimeClass;
extern CFTypeID _CFRuntimeRegisterClass(const ycode_CFRuntimeClass *cls);
extern CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef a, CFTypeID t, CFIndex extra, unsigned char *cat);
typedef struct { uintptr_t isa; uint64_t info; } ycode_CFRuntimeBase;

/* ---- logging ---- */
static FILE *g_log;
static void logf_(const char *fmt, ...)
{
    if (!g_log) return;
    va_list ap; va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap);
    fputc('\n', g_log); fflush(g_log);
}

/* ---- objects ---- */
typedef struct { double width, height; } SizeD;

struct mode_record {           /* 35 bytes written, layout as observed */
    uint32_t mode_id, width, height, scale, field16, pixel_format, field24, refresh_x100;
    uint8_t b32, b33, b34;
} __attribute__((packed));

struct conn {
    ycode_CFRuntimeBase base;
    uint32_t id;
    CFStringRef name;
    dispatch_queue_t queues[3];
    void *handlers[3];      /* connected, updated, disconnected (block copies) */
};
struct display {
    ycode_CFRuntimeBase base;
    uint32_t id, connection_id, width, height, scale, pitch;
    CFStringRef name, device_name, uid;
    bool has_swapchain;
};
struct swapchain {
    ycode_CFRuntimeBase base;
    uint32_t id;
    struct display *display;
    uint64_t presentation_mode;
    uint64_t begin_time;
    void *ctx;
    void (^callback)(CFErrorRef, struct swapchain *, uint64_t, uint64_t, void *);
    dispatch_queue_t queue;
    IOSurfaceRef pending;      /* added in the current swap (retained) */
    uint32_t pending_count;
};

/* ---- capture state ---- */
static const char *g_cap_dir;
static FILE *g_frames;
static pthread_mutex_t g_cap_mu = PTHREAD_MUTEX_INITIALIZER;
static IOSurfaceRef g_last;          /* last presented surface (retained) */
static uint64_t g_seq, g_last_seq, g_last_ticks;
static long g_stats_every = 1;

/* Sampled summary of a BGRA surface: a 64x64 grid; counts non-zero colour and
 * distinct-looking samples, and the mean B,G,R,A. Reads through the client mapping. */
static void summarize(IOSurfaceRef s, char *out, size_t n)
{
    uint32_t fmt = IOSurfaceGetPixelFormat(s);
    size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s);
    if (fmt != 0x42475241 || !w || !h) { snprintf(out, n, "nosummary fmt=0x%x", fmt); return; }
    bool lock = !getenv("SFBC_NO_LOCK");
    uint32_t seed0 = 0;
    kern_return_t lk = lock ? IOSurfaceLock(s, kIOSurfaceLockReadOnly, &seed0) : 0;
    const uint8_t *base = IOSurfaceGetBaseAddress(s);
    unsigned long long sum[4] = { 0 };
    unsigned nonzero = 0, total = 0, changes = 0;
    uint32_t prev = 0;
    for (int gy = 0; gy < 64; gy++) {
        size_t y = (h - 1) * gy / 63;
        for (int gx = 0; gx < 64; gx++) {
            size_t x = (w - 1) * gx / 63;
            uint32_t px; memcpy(&px, base + y * bpr + x * 4, 4);
            for (int c = 0; c < 4; c++) sum[c] += (px >> (8 * c)) & 0xff;
            if (px & 0x00ffffff) nonzero++;
            if (total && px != prev) changes++;
            prev = px; total++;
        }
    }
    if (lock) IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    snprintf(out, n, "lock=%d samples=%u nonblack=%u changes=%u meanBGRA=%llu,%llu,%llu,%llu",
             lk, total, nonzero, changes, sum[0] / total, sum[1] / total, sum[2] / total, sum[3] / total);
}

static void dump_last(const char *name)
{
    pthread_mutex_lock(&g_cap_mu);
    IOSurfaceRef s = g_last ? (IOSurfaceRef)CFRetain(g_last) : NULL;
    uint64_t seq = g_last_seq, ticks = g_last_ticks;
    pthread_mutex_unlock(&g_cap_mu);
    char path[1024];
    snprintf(path, sizeof path, "%s/%s.txt", g_cap_dir, name);
    FILE *t = fopen(path, "w");
    if (!s) { if (t) { fprintf(t, "error=no frame presented yet\n"); fclose(t); } return; }
    size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s);
    bool lock = !getenv("SFBC_NO_LOCK");
    uint32_t seed = 0;
    if (lock) IOSurfaceLock(s, kIOSurfaceLockReadOnly, &seed); else seed = IOSurfaceGetSeed(s);
    const uint8_t *base = IOSurfaceGetBaseAddress(s);
    snprintf(path, sizeof path, "%s/%s.raw", g_cap_dir, name);
    FILE *r = fopen(path, "wb");
    if (r) { fwrite(base, 1, bpr * h, r); fclose(r); }
    if (lock) IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    if (t) {
        fprintf(t, "surface_id=%u\nwidth=%zu\nheight=%zu\nbytes_per_row=%zu\npixel_format=0x%08x\n"
                   "bytes_per_element=%zu\nalloc_size=%zu\nseed=%u\nframe_seq=%llu\nframe_ticks=%llu\n"
                   "dump_ticks=%llu\n",
                IOSurfaceGetID(s), w, h, bpr, IOSurfaceGetPixelFormat(s), IOSurfaceGetBytesPerElement(s),
                IOSurfaceGetAllocSize(s), seed, (unsigned long long)seq, (unsigned long long)ticks,
                (unsigned long long)mach_absolute_time());
        fclose(t);
    }
    CFRelease(s);
    logf_("dumped %s (frame %llu)", name, (unsigned long long)seq);
}

static void *capture_thread(void *arg)
{
    char snap[1024];
    snprintf(snap, sizeof snap, "%s/snap", g_cap_dir);
    for (;;) {
        usleep(250000);
        FILE *f = fopen(snap, "r");
        if (!f) continue;
        char name[256] = "";
        if (!fgets(name, sizeof name, f)) strcpy(name, "snap");
        fclose(f);
        name[strcspn(name, "\r\n/ ")] = 0;
        if (!*name) strcpy(name, "snap");
        dump_last(name);
        unlink(snap);
    }
    return NULL;
}

static void capture_init(void)
{
    g_cap_dir = getenv("SFBC_DIR");
    if (!g_cap_dir || !*g_cap_dir) { g_cap_dir = NULL; return; }
    char path[1024];
    snprintf(path, sizeof path, "%s/opts", g_cap_dir);
    FILE *o = fopen(path, "r");
    char line[256];
    while (o && fgets(line, sizeof line, o)) {
        line[strcspn(line, "\r\n")] = 0;
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        setenv(line, eq + 1, 1);
        logf_("opts: %s=%s", line, eq + 1);
    }
    if (o) fclose(o);
    if (getenv("SFBC_STATS")) g_stats_every = atol(getenv("SFBC_STATS"));
    snprintf(path, sizeof path, "%s/frames.log", g_cap_dir);
    g_frames = fopen(path, "a");
    if (g_frames) setvbuf(g_frames, NULL, _IOLBF, 0);
    if (g_frames) fprintf(g_frames, "# pid %d loaded ticks %llu\n", getpid(), (unsigned long long)mach_absolute_time());
}

/* The capture thread starts with the first presented frame, so only the
 * presenting process (backboardd) answers snap requests; other processes that
 * load the library (CoreSimulator's bridge) never do. */
static void capture_start_thread(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (g_frames) fprintf(g_frames, "# pid %d presents; capture thread on\n", getpid());
        pthread_t th;
        pthread_create(&th, NULL, capture_thread, NULL);
        pthread_detach(th);
    });
}

static void capture_present(struct swapchain *s)
{
    IOSurfaceRef surf = s->pending;
    s->pending = NULL;
    if (!surf) return;
    if (g_cap_dir) capture_start_thread();
    uint64_t now = mach_absolute_time();
    pthread_mutex_lock(&g_cap_mu);
    IOSurfaceRef old = g_last;
    g_last = surf;           /* takes the pending reference */
    uint64_t seq = ++g_seq;
    g_last_seq = seq; g_last_ticks = now;
    pthread_mutex_unlock(&g_cap_mu);
    if (old) CFRelease(old);
    if (g_frames) {
        char sum[256] = "";
        if (g_stats_every > 0 && (seq % g_stats_every == 0 || seq <= 3)) summarize(surf, sum, sizeof sum);
        fprintf(g_frames, "frame %llu ticks %llu sc %u surf %u n %u %zux%zu bpr %zu fmt 0x%x seed %u use %d %s\n",
                (unsigned long long)seq, (unsigned long long)now, s->id, IOSurfaceGetID(surf), s->pending_count,
                IOSurfaceGetWidth(surf), IOSurfaceGetHeight(surf), IOSurfaceGetBytesPerRow(surf),
                IOSurfaceGetPixelFormat(surf), IOSurfaceGetSeed(surf), IOSurfaceIsInUse(surf), sum);
    }
}

static CFTypeID g_conn_t, g_disp_t, g_sc_t;
static struct display *g_display;
static uint32_t g_next_sc = 1;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

static CFStringRef desc_conn(CFTypeRef cf) { return CFStringCreateWithFormat(NULL, NULL, CFSTR("<SFBConnection %p headless>"), cf); }
static CFStringRef desc_disp(CFTypeRef cf) { return CFStringCreateWithFormat(NULL, NULL, CFSTR("<SFBDisplay %p headless>"), cf); }
static CFStringRef desc_sc(CFTypeRef cf) { return CFStringCreateWithFormat(NULL, NULL, CFSTR("<SFBSwapchain %p headless>"), cf); }

static void register_types(void)
{
    static ycode_CFRuntimeClass c = { 0, "SFBConnection", 0, 0, 0, 0, 0, 0, desc_conn, 0, 0, 0 };
    static ycode_CFRuntimeClass d = { 0, "SFBDisplay", 0, 0, 0, 0, 0, 0, desc_disp, 0, 0, 0 };
    static ycode_CFRuntimeClass s = { 0, "SFBSwapchain", 0, 0, 0, 0, 0, 0, desc_sc, 0, 0, 0 };
    g_conn_t = _CFRuntimeRegisterClass(&c);
    g_disp_t = _CFRuntimeRegisterClass(&d);
    g_sc_t = _CFRuntimeRegisterClass(&s);
}

static uint32_t env_u32(const char *k, uint32_t dflt)
{
    const char *v = getenv(k);
    return v && *v ? (uint32_t)strtod(v, NULL) : dflt;
}

__attribute__((constructor)) static void init(void)
{
    const char *lp = getenv("SFBH_LOG");
    if (lp) g_log = fopen(lp, "a");
    register_types();
    struct display *d = (struct display *)_CFRuntimeCreateInstance(NULL, g_disp_t,
        sizeof(struct display) - sizeof(ycode_CFRuntimeBase), NULL);
    d->id = 1;
    d->connection_id = 1;
    d->width = env_u32("SIMULATOR_MAINSCREEN_WIDTH", 1206);
    d->height = env_u32("SIMULATOR_MAINSCREEN_HEIGHT", 2622);
    d->scale = env_u32("SIMULATOR_MAINSCREEN_SCALE", 3);
    d->pitch = env_u32("SIMULATOR_MAINSCREEN_PITCH", 460);
    d->name = CFSTR("LCD");
    d->device_name = CFSTR("primary");
    d->uid = CFSTR("00000000-5943-4F44-4500-000000000001");
    g_display = d;
    capture_init();
    logf_("sfbheadless loaded: %ux%u scale %u pitch %u", d->width, d->height, d->scale, d->pitch);
}

/* ---- type IDs ---- */
EXPORT CFTypeID SFBConnectionGetTypeID(void) { return g_conn_t; }
EXPORT CFTypeID SFBDisplayGetTypeID(void) { return g_disp_t; }
EXPORT CFTypeID SFBSwapchainGetTypeID(void) { return g_sc_t; }
EXPORT const char *simFramebufferGetStructName(uint64_t v) { logf_("simFramebufferGetStructName(%llu)", v); return "unknown"; }

/* ---- connection ---- */
EXPORT struct conn *SFBConnectionCreate(CFAllocatorRef a, CFStringRef name)
{
    struct conn *c = (struct conn *)_CFRuntimeCreateInstance(a, g_conn_t, sizeof(struct conn) - sizeof(ycode_CFRuntimeBase), NULL);
    c->id = 1;
    c->name = name ? CFStringCreateCopy(NULL, name) : NULL;
    char buf[128] = ""; if (name) CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8);
    logf_("SFBConnectionCreate(%s) -> %p", buf, c);
    return c;
}
EXPORT bool SFBConnectionConnect(struct conn *c, CFErrorRef *err) { logf_("SFBConnectionConnect(%p)", c); return true; }
EXPORT uint32_t SFBConnectionGetID(struct conn *c) { return c ? c->id : 0; }
static void set_handler(struct conn *c, int i, dispatch_queue_t q, void *blk, const char *what)
{
    logf_("%s(%p, queue %p, block %p)", what, c, q, blk);
    if (!c) return;
    if (q) dispatch_retain(q);
    c->queues[i] = q;
    c->handlers[i] = blk ? (void *)_Block_copy(blk) : NULL;
}
EXPORT void SFBConnectionSetDisplayConnectedHandler(struct conn *c, dispatch_queue_t q, void *b) { set_handler(c, 0, q, b, "SetDisplayConnectedHandler"); }
EXPORT void SFBConnectionSetDisplayUpdatedHandler(struct conn *c, dispatch_queue_t q, void *b) { set_handler(c, 1, q, b, "SetDisplayUpdatedHandler"); }
EXPORT void SFBConnectionSetDisplayDisconnectedHandler(struct conn *c, dispatch_queue_t q, void *b) { set_handler(c, 2, q, b, "SetDisplayDisconnectedHandler"); }
EXPORT CFArrayRef SFBConnectionCopyDisplays(struct conn *c, CFErrorRef *err)
{
    const void *v[1] = { g_display };
    logf_("SFBConnectionCopyDisplays(%p)", c);
    return CFArrayCreate(NULL, v, 1, &kCFTypeArrayCallBacks);
}
EXPORT struct display *SFBConnectionCopyDisplay(struct conn *c, uint32_t id, CFErrorRef *err)
{
    logf_("SFBConnectionCopyDisplay(%p, %u)", c, id);
    return id == g_display->id ? (struct display *)CFRetain(g_display) : NULL;
}
EXPORT struct display *SFBConnectionCopyDisplayByUID(struct conn *c, CFStringRef uid)
{
    logf_("SFBConnectionCopyDisplayByUID(%p)", c);
    if (uid && (CFEqual(uid, g_display->uid) || CFEqual(uid, g_display->device_name)))
        return (struct display *)CFRetain(g_display);
    return NULL;
}
EXPORT void *SFBConnectionCreateDisplay(struct conn *c, ...) { logf_("SFBConnectionCreateDisplay"); return NULL; }
EXPORT bool SFBConnectionUpdateDisplay(struct conn *c, ...) { logf_("SFBConnectionUpdateDisplay"); return false; }
EXPORT bool SFBConnectionRemoveDisplay(struct conn *c, ...) { logf_("SFBConnectionRemoveDisplay"); return false; }

/* ---- display ---- */
static void fill_mode(struct display *d, void *out)
{
    struct mode_record m = { 1, d->width, d->height, d->scale, 1, 0x42475241 /* BGRA */, 2, 6000, 1, 1, 1 };
    if (out) memcpy(out, &m, sizeof m);
}
EXPORT CFStringRef SFBDisplayGetName(struct display *d) { return d->name; }
EXPORT CFStringRef SFBDisplayGetDisplayUID(struct display *d) { return d->uid; }
EXPORT CFStringRef SFBDisplayGetDeviceName(struct display *d) { return d->device_name; }
EXPORT uint32_t SFBDisplayGetConnectionID(struct display *d) { return d->connection_id; }
EXPORT uint32_t SFBDisplayGetID(struct display *d) { return d->id; }
EXPORT uint32_t SFBDisplayGetType(struct display *d) { return 0; }
EXPORT uint32_t SFBDisplayGetPowerState(struct display *d) { return 1; }
EXPORT uint32_t SFBDisplayGetFlags(struct display *d) { return 1; }
EXPORT uint32_t SFBDisplayGetModeCount(struct display *d) { return 1; }
EXPORT bool SFBDisplayGetMode(struct display *d, uint64_t i, void *out) { if (i) return false; fill_mode(d, out); return true; }
EXPORT bool SFBDisplayGetPreferredMode(struct display *d, void *out) { fill_mode(d, out); return true; }
EXPORT bool SFBDisplayGetCurrentMode(struct display *d, void *out) { fill_mode(d, out); return true; }
EXPORT bool SFBDisplaySetCurrentMode(struct display *d, ...) { logf_("SFBDisplaySetCurrentMode"); return true; }
EXPORT bool SFBDisplayGetExtendedProperties(struct display *d, void *out) { return false; }
EXPORT CFArrayRef SFBDisplayCopyExtendedPropertyProtocols(struct display *d) { return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks); }
EXPORT SizeD SFBDisplayGetDeviceSize(struct display *d) { return (SizeD){ d->width, d->height }; }
EXPORT SizeD SFBDisplayGetCurrentCanvasSize(struct display *d) { return (SizeD){ d->width, d->height }; }
EXPORT uint32_t SFBDisplayGetCanvasSizeCount(struct display *d) { return 0; }
EXPORT SizeD SFBDisplayGetCanvasSize(struct display *d, uint64_t i) { return (SizeD){ d->width, d->height }; }
EXPORT bool SFBDisplaySetCanvasSize(struct display *d, ...) { logf_("SFBDisplaySetCanvasSize"); return true; }
EXPORT bool SFBDisplaySetCurrentUIOrientation(struct display *d, uint64_t o, CFErrorRef *e) { logf_("SetCurrentUIOrientation %llu", o); return true; }
EXPORT uint32_t SFBDisplayGetSupportedSurfaceFlags(struct display *d) { return 0x38; }
EXPORT uint32_t SFBDisplayGetSupportedPresentationModes(struct display *d) { return 3; }
EXPORT uint32_t SFBDisplayGetDotPitch(struct display *d) { return d->pitch; }
EXPORT uint32_t SFBDisplayGetMaxLayerCount(struct display *d) { return 1; }
EXPORT uint32_t SFBDisplayGetMaxSwapchainCount(struct display *d) { return 1; }
EXPORT CFStringRef SFBDisplayGetMaskPath(struct display *d) { return NULL; }
EXPORT bool SFBDisplaySetBacklightState(struct display *d, uint64_t s, CFErrorRef *e) { logf_("SetBacklightState %llu", s); return true; }
EXPORT bool SFBDisplaySetBrightnessFactor(struct display *d, ...) { logf_("SetBrightnessFactor"); return true; }

EXPORT struct swapchain *SFBDisplayCreateSwapchain(struct display *d, uint64_t mode, CFDictionaryRef opts, CFErrorRef *err)
{
    if (getenv("SFBH_NO_SWAPCHAIN")) {   /* experiment: refuse swapchains */
        logf_("SFBDisplayCreateSwapchain refused (SFBH_NO_SWAPCHAIN)");
        if (err) *err = CFErrorCreate(NULL, CFSTR("SimFramebufferClientErrorDomain"), 2, NULL);
        return NULL;
    }
    struct swapchain *s = (struct swapchain *)_CFRuntimeCreateInstance(NULL, g_sc_t,
        sizeof(struct swapchain) - sizeof(ycode_CFRuntimeBase), NULL);
    pthread_mutex_lock(&g_mu);
    s->id = g_next_sc++;
    pthread_mutex_unlock(&g_mu);
    s->display = (struct display *)CFRetain(d);
    s->presentation_mode = mode;
    s->queue = dispatch_queue_create("dev.ycode.sfbheadless.swap", NULL);
    logf_("SFBDisplayCreateSwapchain(%p, mode %llu, opts %p) -> %p id %u", d, mode, opts, s, s->id);
    return s;
}

/* ---- swapchain ---- */
EXPORT uint32_t SFBSwapchainGetID(struct swapchain *s) { return s->id; }
EXPORT uint32_t SFBSwapchainGetDisplayID(struct swapchain *s) { return s->display->id; }
EXPORT uint32_t SFBSwapchainGetConnectionID(struct swapchain *s) { return s->display->connection_id; }
EXPORT SizeD SFBSwapchainGetFramebufferSize(struct swapchain *s) { return (SizeD){ s->display->width, s->display->height }; }
EXPORT uint32_t SFBSwapchainGetPixelFormat(struct swapchain *s) { return 0x42475241; /* 'BGRA' */ }
EXPORT uint32_t SFBSwapchainGetColorspace(struct swapchain *s) { return 1; }
EXPORT uint32_t SFBSwapchainGetHDRMode(struct swapchain *s) { return 1; }
EXPORT uint32_t SFBSwapchainGetPresentationMode(struct swapchain *s) { return (uint32_t)s->presentation_mode; }
EXPORT uint32_t SFBSwapchainGetMaxSurfacesPerOperation(struct swapchain *s) { return 32; }
EXPORT void *SFBSwapchainAcquireSurfaceFence(struct swapchain *s, ...) { logf_("SFBSwapchainAcquireSurfaceFence"); return NULL; }
EXPORT bool SFBSwapchainSwapBegin(struct swapchain *s, uint64_t t, CFErrorRef *err)
{
    s->begin_time = t;
    if (s->pending) { CFRelease(s->pending); s->pending = NULL; }
    s->pending_count = 0;
    return true;
}
/* (swapchain, surface, source rect d0-d3, destination rect d4-d7, two integers) */
EXPORT bool SFBSwapchainSwapAddSurface(struct swapchain *s, IOSurfaceRef surface, uint64_t a, uint64_t b)
{
    s->pending_count++;
    if (surface && !s->pending) s->pending = (IOSurfaceRef)CFRetain(surface);
    return true;
}
EXPORT void SFBSwapchainSwapSetCallback(struct swapchain *s, void *ctx, void *x2, void *blk)
{
    s->ctx = ctx;
    s->callback = blk ? (void *)_Block_copy(blk) : NULL;
}
EXPORT bool SFBSwapchainSwapSubmit(struct swapchain *s, CFErrorRef *err)
{
    void (^cb)(CFErrorRef, struct swapchain *, uint64_t, uint64_t, void *) = s->callback;
    void *ctx = s->ctx;
    uint64_t t = s->begin_time;
    s->callback = NULL;
    static long submits;
    if (++submits % 100 == 1) logf_("SFBSwapchainSwapSubmit #%ld", submits);
    capture_present(s);
    if (getenv("SFBH_NO_CALLBACK")) return true;   /* experiment: never complete swaps */
    CFRetain(s);
    const char *dl = getenv("SFBC_DELAY_CB");
    long delay_ms = dl ? atol(dl) : 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay_ms * 1000000LL), s->queue, ^{
        if (cb) { cb(NULL, s, t, mach_absolute_time(), ctx); _Block_release(cb); }
        CFRelease(s);
    });
    return true;
}
EXPORT bool SFBSwapchainSwapCancel(struct swapchain *s, ...) { logf_("SFBSwapchainSwapCancel"); s->callback = NULL; return true; }
