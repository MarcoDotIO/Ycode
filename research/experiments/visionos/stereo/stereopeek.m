// stereopeek (our own code, OBS-VISION-STEREO, dirty room): how many views backboardd renders.
// Inserted with SIMCTL_CHILD_DYLD_INSERT_LIBRARIES; inert outside backboardd and wakeboardd.
// backboardd: logs textures made with arrayLength >= 2 (device and heap), the shared layer textures
// it opens, render passes whose colour 0 is an array texture (renderTargetArrayLength, sizes) and,
// in those passes, viewport, amplification, vertex-bytes and draw instance-count calls; after such a
// pass ends it appends a blit of every slice into a shared buffer of its own (SP_CAPTURES times per
// texture size) and writes the slices and their comparison (per-slice means, mean |a-b|, best
// horizontal shift of slice 1 against slice 0).
// wakeboardd: logs shared-texture descriptors and the rects of SFBSwapchainSwapAddSurface.
// Output: $SP_DIR/sp.<process>.<pid>, raw slices $SP_DIR/<process>-<w>x<h>-c<n>-s<i>.rgba16f
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/time.h>
#include <unistd.h>
#include <math.h>

static FILE *g_out; static int g_proc; static double g_t0; static char g_dir[512];
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;
static double wall(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec + tv.tv_usec / 1e6; }
static void sp(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void sp(const char *fmt, ...) {
    if (!g_out) return; char line[4096]; va_list ap; va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
    double w = wall(); pthread_mutex_lock(&g_mx); fprintf(g_out, "%.3f +%.3f %s\n", w, w - g_t0, line); fflush(g_out); pthread_mutex_unlock(&g_mx);
}
static const char *texs(id<MTLTexture> t, char *b, size_t n) {
    if (!t) { snprintf(b, n, "nil"); return b; }
    snprintf(b, n, "%p %lux%lux%lu type %lu fmt %lu array %lu mips %lu samples %lu usage 0x%lx storage %lu label \"%s\"", t,
             (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.depth, (unsigned long)t.textureType, (unsigned long)t.pixelFormat,
             (unsigned long)t.arrayLength, (unsigned long)t.mipmapLevelCount, (unsigned long)t.sampleCount, (unsigned long)t.usage,
             (unsigned long)t.storageMode, t.label ? t.label.UTF8String : "");
    return b;
}
static void hook(Class c, SEL s, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) { sp("no %s on %s", sel_getName(s), class_getName(c)); return; }
    *orig = method_setImplementation(m, imp);
    sp("hooked %s %s", class_getName(c), sel_getName(s));
}

// ------------------------------------------------------------ texture creation
static IMP o_devTex, o_heapTex, o_heapTexOff, o_open, o_sharedDesc;
static void noteDesc(const char *who, MTLTextureDescriptor *d, id t) {
    if (d.arrayLength < 2 && d.textureType != MTLTextureType2DArray) return;
    char b[512]; sp("%s desc %lux%lu type %lu fmt %lu array %lu usage 0x%lx -> %s", who, (unsigned long)d.width, (unsigned long)d.height,
                    (unsigned long)d.textureType, (unsigned long)d.pixelFormat, (unsigned long)d.arrayLength, (unsigned long)d.usage, texs(t, b, sizeof b));
}
static id h_devTex(id self, SEL _c, MTLTextureDescriptor *d) { id t = ((id(*)(id, SEL, id))o_devTex)(self, _c, d); noteDesc("device newTexture", d, t); return t; }
static id h_heapTex(id self, SEL _c, MTLTextureDescriptor *d) { id t = ((id(*)(id, SEL, id))o_heapTex)(self, _c, d); noteDesc("heap newTexture", d, t); return t; }
static id h_heapTexOff(id self, SEL _c, MTLTextureDescriptor *d, NSUInteger off) { id t = ((id(*)(id, SEL, id, NSUInteger))o_heapTexOff)(self, _c, d, off); noteDesc("heap newTexture@off", d, t); return t; }
static id h_sharedDesc(id self, SEL _c, MTLTextureDescriptor *d) {
    id t = ((id(*)(id, SEL, id))o_sharedDesc)(self, _c, d);
    char b[512]; sp("newSharedTextureWithDescriptor %lux%lu type %lu fmt %lu array %lu usage 0x%lx -> %s", (unsigned long)d.width, (unsigned long)d.height,
                    (unsigned long)d.textureType, (unsigned long)d.pixelFormat, (unsigned long)d.arrayLength, (unsigned long)d.usage, texs(t, b, sizeof b));
    return t;
}
static NSMutableSet *g_layerTex;
static id h_open(id self, SEL _c, id handle) {
    id t = ((id(*)(id, SEL, id))o_open)(self, _c, handle);
    char b[512]; NSString *l = [handle respondsToSelector:@selector(label)] ? [handle label] : @"?";
    sp("newSharedTextureWithHandle \"%s\" -> %s", l.UTF8String, texs(t, b, sizeof b));
    if (t) @synchronized(g_layerTex) { [g_layerTex addObject:[NSValue valueWithPointer:(__bridge void *)t]]; }
    return t;
}

// ------------------------------------------------------------ render passes
static IMP o_draw3, o_dix5, o_rce, o_end, o_vp, o_vps, o_amp, o_vbytes, o_vbuf, o_draw4, o_draw5, o_dix6, o_dix8;
static const void *kTag = &kTag;
static NSMutableDictionary *g_sigCount;   // signature -> passes logged
static NSMutableDictionary *g_capCount;   // size -> captures made
static int g_maxPasses = 6, g_maxCaps = 3;
@interface SPTag : NSObject
@property(strong) id cb; @property(strong) id tex; @property int calls; @property(copy) NSString *sig; @property BOOL layer;
@end
@implementation SPTag
@end
static SPTag *tagOf(id enc) { return objc_getAssociatedObject(enc, kTag); }

static id h_rce(id self, SEL _c, MTLRenderPassDescriptor *rp) {
    id enc = ((id(*)(id, SEL, id))o_rce)(self, _c, rp);
    id<MTLTexture> t0 = rp.colorAttachments[0].texture; id<MTLTexture> dt = rp.depthAttachment.texture;
    id<MTLTexture> ref = t0 ? t0 : dt;
    BOOL isLayer = NO;
    if (ref) @synchronized(g_layerTex) { isLayer = [g_layerTex containsObject:[NSValue valueWithPointer:(__bridge void *)ref]] ||
                                                   (rp.colorAttachments[0].resolveTexture && [g_layerTex containsObject:[NSValue valueWithPointer:(__bridge void *)rp.colorAttachments[0].resolveTexture]]); }
    BOOL arr = ref && (ref.arrayLength >= 2 || rp.renderTargetArrayLength >= 2);
    if (!enc || (!arr && !isLayer)) return enc;
    NSString *sig = [NSString stringWithFormat:@"%lux%lu a%lu f%lu L%d", (unsigned long)ref.width, (unsigned long)ref.height, (unsigned long)ref.arrayLength, (unsigned long)ref.pixelFormat, isLayer];
    int n; @synchronized(g_sigCount) { n = [g_sigCount[sig] intValue]; g_sigCount[sig] = @(n + 1); }
    BOOL logIt = n < g_maxPasses || n % 600 == 0;
    if (logIt) {
        char b0[512], b1[512], b2[512];
        sp("pass #%d [%s] rtArrayLength %lu rtW %lu rtH %lu c0 slice %lu depthPlane %lu load %lu store %lu %s | resolve %s | depth slice %lu %s | label \"%s\"", n, sig.UTF8String,
           (unsigned long)rp.renderTargetArrayLength, (unsigned long)rp.renderTargetWidth, (unsigned long)rp.renderTargetHeight,
           (unsigned long)rp.colorAttachments[0].slice, (unsigned long)rp.colorAttachments[0].depthPlane, (unsigned long)rp.colorAttachments[0].loadAction,
           (unsigned long)rp.colorAttachments[0].storeAction, texs(t0, b0, sizeof b0), texs(rp.colorAttachments[0].resolveTexture, b1, sizeof b1),
           (unsigned long)rp.depthAttachment.slice, texs(dt, b2, sizeof b2), [enc label] ? [[enc label] UTF8String] : "");
        for (int i = 1; i < 8; i++) if (rp.colorAttachments[i].texture) { char b[512]; sp("   c%d %s", i, texs(rp.colorAttachments[i].texture, b, sizeof b)); }
    }
    SPTag *tg = [SPTag new]; tg.cb = self; tg.tex = t0; tg.sig = sig; tg.layer = isLayer; tg.calls = logIt ? 0 : 1000000;
    objc_setAssociatedObject(enc, kTag, tg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return enc;
}
#define TAGLOG(...) do { SPTag *tg = tagOf(self); if (tg && tg.calls < 400) { tg.calls++; sp(__VA_ARGS__); } } while (0)
static void h_vp(id self, SEL _c, MTLViewport v) { TAGLOG("   setViewport (%.1f %.1f %.1f %.1f %.2f %.2f)", v.originX, v.originY, v.width, v.height, v.znear, v.zfar); ((void(*)(id, SEL, MTLViewport))o_vp)(self, _c, v); }
static void h_vps(id self, SEL _c, const MTLViewport *v, NSUInteger n) {
    SPTag *tg = tagOf(self);
    if (tg && tg.calls < 40) { tg.calls++; for (NSUInteger i = 0; i < n; i++) sp("   setViewports[%lu/%lu] (%.1f %.1f %.1f %.1f)", (unsigned long)i, (unsigned long)n, v[i].originX, v[i].originY, v[i].width, v[i].height); }
    ((void(*)(id, SEL, const MTLViewport *, NSUInteger))o_vps)(self, _c, v, n);
}
static void h_amp(id self, SEL _c, NSUInteger cnt, const MTLVertexAmplificationViewMapping *m) {
    sp("   setVertexAmplificationCount %lu (tagged %d)", (unsigned long)cnt, tagOf(self) != nil);
    ((void(*)(id, SEL, NSUInteger, const void *))o_amp)(self, _c, cnt, m);
}
static void dumpFloats(const char *what, const void *p, size_t len, NSUInteger idx) {
    size_t nf = len / 4; if (nf > 96) nf = 96;
    char b[2048]; size_t o = 0; const float *f = p;
    for (size_t i = 0; i < nf && o < sizeof b - 16; i++) o += snprintf(b + o, sizeof b - o, "%s%.4g", i ? " " : "", f[i]);
    sp("   %s idx %lu len %zu: %s", what, (unsigned long)idx, len, b);
}
static void h_vbytes(id self, SEL _c, const void *p, NSUInteger len, NSUInteger idx) {
    SPTag *tg = tagOf(self); if (tg && tg.calls < 40) { tg.calls++; dumpFloats("setVertexBytes", p, len, idx); }
    ((void(*)(id, SEL, const void *, NSUInteger, NSUInteger))o_vbytes)(self, _c, p, len, idx);
}
static void h_vbuf(id self, SEL _c, id<MTLBuffer> b, NSUInteger off, NSUInteger idx) {
    SPTag *tg = tagOf(self);
    if (tg && tg.calls < 12 && b) { tg.calls++;
        if (b.storageMode == MTLStorageModeShared && off + 64 <= b.length) dumpFloats([NSString stringWithFormat:@"setVertexBuffer len %lu off %lu", (unsigned long)b.length, (unsigned long)off].UTF8String, (const char *)b.contents + off, MIN(384, b.length - off), idx);
        else sp("   setVertexBuffer idx %lu len %lu off %lu storage %lu", (unsigned long)idx, (unsigned long)b.length, (unsigned long)off, (unsigned long)b.storageMode); }
    ((void(*)(id, SEL, id, NSUInteger, NSUInteger))o_vbuf)(self, _c, b, off, idx);
}
static void h_draw4(id self, SEL _c, NSUInteger pt, NSUInteger vs, NSUInteger vc, NSUInteger ic) { TAGLOG("   draw prim %lu vertices %lu instances %lu", (unsigned long)pt, (unsigned long)vc, (unsigned long)ic); ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, NSUInteger))o_draw4)(self, _c, pt, vs, vc, ic); }
static void h_draw5(id self, SEL _c, NSUInteger pt, NSUInteger vs, NSUInteger vc, NSUInteger ic, NSUInteger bi) { TAGLOG("   draw prim %lu vertices %lu instances %lu base %lu", (unsigned long)pt, (unsigned long)vc, (unsigned long)ic, (unsigned long)bi); ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, NSUInteger, NSUInteger))o_draw5)(self, _c, pt, vs, vc, ic, bi); }
static void h_dix6(id self, SEL _c, NSUInteger pt, NSUInteger n, NSUInteger it, id ib, NSUInteger off, NSUInteger ic) { TAGLOG("   drawIndexed prim %lu indices %lu instances %lu", (unsigned long)pt, (unsigned long)n, (unsigned long)ic); ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, id, NSUInteger, NSUInteger))o_dix6)(self, _c, pt, n, it, ib, off, ic); }
static void h_dix8(id self, SEL _c, NSUInteger pt, NSUInteger n, NSUInteger it, id ib, NSUInteger off, NSUInteger ic, NSInteger bv, NSUInteger bi) { TAGLOG("   drawIndexed prim %lu indices %lu instances %lu baseVertex %ld baseInstance %lu", (unsigned long)pt, (unsigned long)n, (unsigned long)ic, (long)bv, (unsigned long)bi); ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, id, NSUInteger, NSUInteger, NSInteger, NSUInteger))o_dix8)(self, _c, pt, n, it, ib, off, ic, bv, bi); }

static void h_draw3(id self, SEL _c, NSUInteger pt, NSUInteger vs, NSUInteger vc) { TAGLOG("   draw prim %lu vertices %lu (no instance count)", (unsigned long)pt, (unsigned long)vc); ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger))o_draw3)(self, _c, pt, vs, vc); }
static void h_dix5(id self, SEL _c, NSUInteger pt, NSUInteger n, NSUInteger it, id ib, NSUInteger off) { TAGLOG("   drawIndexed prim %lu indices %lu (no instance count)", (unsigned long)pt, (unsigned long)n); ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, id, NSUInteger))o_dix5)(self, _c, pt, n, it, ib, off); }
static float h2f(uint16_t h) { __fp16 v; memcpy(&v, &h, 2); return (float)v; }
static void compare(const char *tag, const uint8_t *p, size_t w, size_t h, size_t slices, size_t bpp, MTLPixelFormat fmt) {
    size_t img = w * h * bpp;
    for (size_t s = 0; s < slices; s++) {
        char path[1024]; snprintf(path, sizeof path, "%s/%s-%s-s%zu.raw", g_dir, getprogname(), tag, s);
        FILE *f = fopen(path, "wb"); if (f) { fwrite(p + s * img, 1, img, f); fclose(f); }
    }
    // channel values as float
    size_t n = w * h * 4; float *v = malloc(slices * n * sizeof(float));
    for (size_t s = 0; s < slices; s++) for (size_t i = 0; i < n; i++) {
        const uint8_t *q = p + s * img;
        v[s * n + i] = fmt == MTLPixelFormatRGBA16Float ? h2f(((const uint16_t *)q)[i]) : q[i] / 255.0f;
    }
    for (size_t s = 0; s < slices; s++) { double m[4] = {0}; for (size_t i = 0; i < n; i++) m[i % 4] += v[s * n + i]; sp("   %s slice %zu means %.4f %.4f %.4f %.4f", tag, s, m[0] / (w * h), m[1] / (w * h), m[2] / (w * h), m[3] / (w * h)); }
    if (slices >= 2) {
        double best = 1e30; int bx = 0, by = 0; double d0 = 0;
        for (int dy = -4; dy <= 4; dy++) for (int dx = -24; dx <= 24; dx++) {
            double acc = 0; size_t cnt = 0;
            for (size_t y = 8; y + 8 < h; y++) for (size_t x = 30; x + 30 < w; x++) for (int c = 0; c < 3; c++)
                { acc += fabs(v[((y) * w + x) * 4 + c] - v[n + ((y + dy) * w + (x + dx)) * 4 + c]); cnt++; }
            acc /= cnt; if (dx == 0 && dy == 0) d0 = acc; if (acc < best) { best = acc; bx = dx; by = dy; }
        }
        sp("   %s slice0 vs slice1: mean|diff| at (0,0) %.5f; best shift of slice 1 (%d, %d) px with mean|diff| %.5f", tag, d0, bx, by, best);
    }
    free(v);
}
static void h_end(id self, SEL _c) {
    ((void(*)(id, SEL))o_end)(self, _c);
    SPTag *tg = tagOf(self); if (!tg || tg.layer || !tg.tex) return;
    id<MTLTexture> t = tg.tex; if (t.arrayLength < 2) return;
    if (t.pixelFormat != MTLPixelFormatRGBA16Float && t.pixelFormat != MTLPixelFormatBGRA8Unorm && t.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB && t.pixelFormat != MTLPixelFormatRGBA8Unorm) return;
    if (t.width * t.height > 1024 * 1024) return;
    int c; NSString *key = tg.sig;
    @synchronized(g_capCount) { c = [g_capCount[key] intValue]; double now = wall() - g_t0; if (c >= g_maxCaps && !(c < g_maxCaps + 6 && fmod(now, 20) < 0.5)) return; g_capCount[key] = @(c + 1); }
    size_t bpp = t.pixelFormat == MTLPixelFormatRGBA16Float ? 8 : 4, img = t.width * t.height * bpp, sl = t.arrayLength;
    id<MTLBuffer> buf = [t.device newBufferWithLength:img * sl options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> be = [tg.cb blitCommandEncoder];
    for (size_t s = 0; s < sl; s++)
        [be copyFromTexture:t sourceSlice:s sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1)
                   toBuffer:buf destinationOffset:s * img destinationBytesPerRow:t.width * bpp destinationBytesPerImage:img];
    [be endEncoding];
    size_t w = t.width, h = t.height; MTLPixelFormat fmt = t.pixelFormat;
    char tag[128]; snprintf(tag, sizeof tag, "%zux%zux%zu-f%lu-c%d", w, h, sl, (unsigned long)fmt, c);
    NSString *ts = @(tag);
    [tg.cb addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        sp("capture %s done status %lu", ts.UTF8String, (unsigned long)cb.status);
        compare(ts.UTF8String, buf.contents, w, h, sl, bpp, fmt);
    }];
}

// ------------------------------------------------------------ wakeboardd: NSUserDefaults reads
static IMP o_ud_obj, o_ud_bool, o_ud_int, o_ud_dbl, o_ud_flt, o_ud_str, o_ud_init;
static NSMutableDictionary *g_udSeen;
static void udNote(id self, const char *how, NSString *key, NSString *val) {
    if (![key isKindOfClass:[NSString class]]) return;
    NSString *k = [NSString stringWithFormat:@"%s|%@", how, key];
    @synchronized(g_udSeen) { int n = [g_udSeen[k] intValue]; g_udSeen[k] = @(n + 1); if (n >= 2) return; }
    NSString *suite = nil; @try { suite = [self valueForKey:@"_identifier"]; } @catch (id e) {}
    sp("UD %s(%s) suite %s -> %s", how, key.UTF8String, suite ? [suite description].UTF8String : "?", val.UTF8String);
}
static id h_ud_obj(id self, SEL c, NSString *k) { id v = ((id(*)(id, SEL, id))o_ud_obj)(self, c, k); udNote(self, "objectForKey", k, v ? [NSString stringWithFormat:@"%@ (%@)", v, [v class]] : @"nil"); return v; }
static BOOL h_ud_bool(id self, SEL c, NSString *k) { BOOL v = ((BOOL(*)(id, SEL, id))o_ud_bool)(self, c, k); udNote(self, "boolForKey", k, v ? @"YES" : @"NO"); return v; }
static NSInteger h_ud_int(id self, SEL c, NSString *k) { NSInteger v = ((NSInteger(*)(id, SEL, id))o_ud_int)(self, c, k); udNote(self, "integerForKey", k, [NSString stringWithFormat:@"%ld", (long)v]); return v; }
static double h_ud_dbl(id self, SEL c, NSString *k) { double v = ((double(*)(id, SEL, id))o_ud_dbl)(self, c, k); udNote(self, "doubleForKey", k, [NSString stringWithFormat:@"%g", v]); return v; }
static float h_ud_flt(id self, SEL c, NSString *k) { float v = ((float(*)(id, SEL, id))o_ud_flt)(self, c, k); udNote(self, "floatForKey", k, [NSString stringWithFormat:@"%g", v]); return v; }
static id h_ud_str(id self, SEL c, NSString *k) { id v = ((id(*)(id, SEL, id))o_ud_str)(self, c, k); udNote(self, "stringForKey", k, v ? v : @"nil"); return v; }
static id h_ud_init(id self, SEL c, NSString *suite) { sp("UD initWithSuiteName(%s)", suite ? suite.UTF8String : "nil"); return ((id(*)(id, SEL, id))o_ud_init)(self, c, suite); }
static void hookDefaults(void) {
    g_udSeen = [NSMutableDictionary dictionary];
    Class u = [NSUserDefaults class];
    hook(u, @selector(objectForKey:), (IMP)h_ud_obj, &o_ud_obj);
    hook(u, @selector(boolForKey:), (IMP)h_ud_bool, &o_ud_bool);
    hook(u, @selector(integerForKey:), (IMP)h_ud_int, &o_ud_int);
    hook(u, @selector(doubleForKey:), (IMP)h_ud_dbl, &o_ud_dbl);
    hook(u, @selector(floatForKey:), (IMP)h_ud_flt, &o_ud_flt);
    hook(u, @selector(stringForKey:), (IMP)h_ud_str, &o_ud_str);
    hook(u, @selector(initWithSuiteName:), (IMP)h_ud_init, &o_ud_init);
}

// ------------------------------------------------------------ wakeboardd: swaps
typedef struct { double x, y, w, h; } sprect_t;
extern bool SFBSwapchainSwapAddSurface(void *sc, void *surf, sprect_t src, sprect_t dst, long a, long b) __attribute__((weak_import));
static unsigned long g_adds;
static bool sp_add(void *sc, void *surf, sprect_t src, sprect_t dst, long a, long b) {
    bool r = SFBSwapchainSwapAddSurface(sc, surf, src, dst, a, b);
    if (g_proc == 2) { unsigned long n = __atomic_add_fetch(&g_adds, 1, __ATOMIC_RELAXED);
        if (n <= 6 || n % 600 == 0) sp("SwapAddSurface #%lu sc %p surf id %u %zux%zu src (%.0f %.0f %.0f %.0f) dst (%.0f %.0f %.0f %.0f) %ld %ld -> %d", n, sc,
                                     surf ? IOSurfaceGetID(surf) : 0, surf ? IOSurfaceGetWidth(surf) : 0, surf ? IOSurfaceGetHeight(surf) : 0,
                                     src.x, src.y, src.w, src.h, dst.x, dst.y, dst.w, dst.h, a, b, r); }
    return r;
}
__attribute__((used)) static struct { const void *r; const void *o; } sp_ip __attribute__((section("__DATA,__interpose"))) = {(const void *)sp_add, (const void *)SFBSwapchainSwapAddSurface};

static void *hooker(void *arg) {
    (void)arg;
    for (int i = 0; i < 6000; i++) {
        Class d = objc_getClass("MTLSimDevice"), cb = objc_getClass("MTLSimCommandBuffer"), re = objc_getClass("MTLSimRenderCommandEncoder"), hp = objc_getClass("MTLSimHeap");
        if (d && cb && re) {
            sp("classes after %d polls (heap %p)", i, hp);
            if (g_proc == 2) { hook(d, @selector(newSharedTextureWithDescriptor:), (IMP)h_sharedDesc, &o_sharedDesc); hook(d, @selector(newTextureWithDescriptor:), (IMP)h_devTex, &o_devTex); return NULL; }
            hook(d, @selector(newTextureWithDescriptor:), (IMP)h_devTex, &o_devTex);
            hook(d, @selector(newSharedTextureWithHandle:), (IMP)h_open, &o_open);
            if (hp) { hook(hp, @selector(newTextureWithDescriptor:), (IMP)h_heapTex, &o_heapTex); hook(hp, @selector(newTextureWithDescriptor:offset:), (IMP)h_heapTexOff, &o_heapTexOff); }
            hook(cb, @selector(renderCommandEncoderWithDescriptor:), (IMP)h_rce, &o_rce);
            hook(re, @selector(endEncoding), (IMP)h_end, &o_end);
            hook(re, @selector(setViewport:), (IMP)h_vp, &o_vp);
            hook(re, @selector(setViewports:count:), (IMP)h_vps, &o_vps);
            hook(re, @selector(setVertexAmplificationCount:viewMappings:), (IMP)h_amp, &o_amp);
            hook(re, @selector(setVertexBytes:length:atIndex:), (IMP)h_vbytes, &o_vbytes);
            hook(re, @selector(setVertexBuffer:offset:atIndex:), (IMP)h_vbuf, &o_vbuf);
            hook(re, @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:), (IMP)h_draw4, &o_draw4);
            hook(re, @selector(drawPrimitives:vertexStart:vertexCount:), (IMP)h_draw3, &o_draw3);
            hook(re, @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:), (IMP)h_dix5, &o_dix5);
            hook(re, @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:), (IMP)h_draw5, &o_draw5);
            hook(re, @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:), (IMP)h_dix6, &o_dix6);
            hook(re, @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:), (IMP)h_dix8, &o_dix8);
            return NULL;
        }
        usleep(5000);
    }
    sp("classes never appeared");
    return NULL;
}

__attribute__((constructor)) static void sp_init(void) {
    const char *me = getprogname();
    const char *only = getenv("SP_PROCS");
    if (strcmp(me, "backboardd") == 0) g_proc = 1; else if (strcmp(me, "wakeboardd") == 0) g_proc = 2; else return;
    if (only && !strstr(only, me)) return;
    const char *d = getenv("SP_DIR"); snprintf(g_dir, sizeof g_dir, "%s", d && *d ? d : "/tmp");
    if (getenv("SP_CAPTURES")) g_maxCaps = atoi(getenv("SP_CAPTURES"));
    if (getenv("SP_PASSES")) g_maxPasses = atoi(getenv("SP_PASSES"));
    char path[1024]; snprintf(path, sizeof path, "%s/sp.%s.%d", g_dir, me, getpid());
    g_out = fopen(path, "w"); g_t0 = wall();
    sp("loaded in %s pid %d", me, getpid());
    g_layerTex = [NSMutableSet set]; g_sigCount = [NSMutableDictionary dictionary]; g_capCount = [NSMutableDictionary dictionary];
    if ((g_proc == 2 && !getenv("SP_NO_UD")) || (g_proc == 1 && getenv("SP_UD_BB"))) hookDefaults();
    pthread_t th; pthread_create(&th, NULL, hooker, NULL); pthread_detach(th);
}
