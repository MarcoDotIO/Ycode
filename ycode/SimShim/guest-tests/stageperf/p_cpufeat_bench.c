/* Ycode guest probe: micro-benchmarks for the CPU-feature A/B
 * (specs/simulator/cpu-features.md §7.3). Original Ycode code over public
 * SDK APIs. Each benchmark runs once to warm up, then REPS times; the probe
 * prints the median and the min/max of the timed runs:
 *   bench <name> median <v> min <v> max <v> <unit>
 * Benchmarks: JavaScriptCore (double->int32 conversions, Atomics on an
 * Int32Array, a mixed object/array workload), cblas_sgemm 512x512, a BNNS
 * 3x3 convolution, CommonCrypto SHA-256 and AES-128-CBC, timingsafe_bcmp,
 * libcompression (LZFSE and zlib, encode and decode), ImageIO JPEG decode.
 * Argument: a comma-separated list of benchmark names (default: all). */
#define ACCELERATE_NEW_LAPACK 1
#include <Accelerate/Accelerate.h>
#include <CommonCrypto/CommonCrypto.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <JavaScriptCore/JavaScriptCore.h>
#include <compression.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#define REPS 7

static double now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e9 + (double)t.tv_nsec;
}

static int cmp_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static const char *only;
static int wanted(const char *name)
{
    if (!only) return 1;
    size_t n = strlen(name);
    for (const char *p = only; (p = strstr(p, name)) != NULL; p += n)
        if ((p == only || p[-1] == ',') && (p[n] == 0 || p[n] == ',')) return 1;
    return 0;
}

/* Runs fn REPS+1 times (the first is a warm-up); each run returns its own
 * figure (a time or a rate). */
static void report(const char *name, const char *unit, double (*fn)(void *), void *ctx)
{
    if (!wanted(name)) return;
    double v[REPS];
    (void)fn(ctx);
    for (int i = 0; i < REPS; i++) v[i] = fn(ctx);
    qsort(v, REPS, sizeof v[0], cmp_double);
    printf("bench %s median %.3f min %.3f max %.3f %s\n", name, v[REPS / 2], v[0], v[REPS - 1], unit);
    fflush(stdout);
}

/* ---- JavaScriptCore ---- */

struct js { JSGlobalContextRef ctx; JSStringRef call; };

static double js_run(void *p)
{
    struct js *j = p;
    JSValueRef exc = NULL;
    double t0 = now_ns();
    JSValueRef r = JSEvaluateScript(j->ctx, j->call, NULL, NULL, 0, &exc);
    double t = (now_ns() - t0) / 1e6;
    if (exc || !r) { printf("js: exception\n"); return -1; }
    return t;
}

static void js_bench(const char *name, const char *define, const char *call)
{
    if (!wanted(name)) return;
    struct js j;
    j.ctx = JSGlobalContextCreate(NULL);
    JSStringRef def = JSStringCreateWithUTF8CString(define);
    JSValueRef exc = NULL;
    JSEvaluateScript(j.ctx, def, NULL, NULL, 0, &exc);
    JSStringRelease(def);
    if (exc) { printf("bench %s: definition failed\n", name); return; }
    j.call = JSStringCreateWithUTF8CString(call);
    (void)js_run(&j);  /* extra warm-up: tier up */
    report(name, "ms", js_run, &j);
    JSStringRelease(j.call);
    JSGlobalContextRelease(j.ctx);
}

/* ---- Accelerate ---- */

struct gemm { float *a, *b, *c; int n; };
static double sgemm_run(void *p)
{
    struct gemm *g = p;
    double t0 = now_ns();
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, g->n, g->n, g->n, 1.0f, g->a, g->n, g->b, g->n, 0.0f, g->c, g->n);
    double t = now_ns() - t0;
    return 2.0 * g->n * g->n * g->n / t;   /* GFLOP/s */
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
struct conv { BNNSFilter f; float *in, *out; };
static double conv_run(void *p)
{
    struct conv *c = p;
    double t0 = now_ns();
    if (BNNSFilterApply(c->f, c->in, c->out) != 0) return -1;
    return (now_ns() - t0) / 1e6;
}

static void bnns_bench(void)
{
    if (!wanted("bnns_conv")) return;
    const size_t W = 64, H = 64, CI = 32, CO = 64, K = 3;
    float *in = calloc(W * H * CI, sizeof(float)), *out = calloc(W * H * CO, sizeof(float));
    float *w = calloc(K * K * CI * CO, sizeof(float)), *bias = calloc(CO, sizeof(float));
    for (size_t i = 0; i < W * H * CI; i++) in[i] = (float)(i % 17) * 0.1f;
    for (size_t i = 0; i < K * K * CI * CO; i++) w[i] = (float)(i % 7) * 0.01f;
    BNNSLayerParametersConvolution lp;
    memset(&lp, 0, sizeof lp);
    lp.i_desc.layout = BNNSDataLayoutImageCHW;
    lp.i_desc.size[0] = W; lp.i_desc.size[1] = H; lp.i_desc.size[2] = CI;
    lp.i_desc.data_type = BNNSDataTypeFloat32;
    lp.o_desc.layout = BNNSDataLayoutImageCHW;
    lp.o_desc.size[0] = W; lp.o_desc.size[1] = H; lp.o_desc.size[2] = CO;
    lp.o_desc.data_type = BNNSDataTypeFloat32;
    lp.w_desc.layout = BNNSDataLayoutConvolutionWeightsOIHW;
    lp.w_desc.size[0] = K; lp.w_desc.size[1] = K; lp.w_desc.size[2] = CI; lp.w_desc.size[3] = CO;
    lp.w_desc.data_type = BNNSDataTypeFloat32;
    lp.w_desc.data = w;
    lp.bias.layout = BNNSDataLayoutVector;
    lp.bias.size[0] = CO;
    lp.bias.data_type = BNNSDataTypeFloat32;
    lp.bias.data = bias;
    lp.activation.function = BNNSActivationFunctionIdentity;
    lp.x_stride = 1; lp.y_stride = 1; lp.x_padding = 1; lp.y_padding = 1;
    struct conv c = {BNNSFilterCreateLayerConvolution(&lp, NULL), in, out};
    if (!c.f) { printf("bench bnns_conv: filter creation failed\n"); return; }
    report("bnns_conv", "ms", conv_run, &c);
    BNNSFilterDestroy(c.f);
    free(in); free(out); free(w); free(bias);
}
#pragma clang diagnostic pop

/* ---- CommonCrypto, timingsafe ---- */

#define CRYPTO_BYTES (32u << 20)
struct buf { uint8_t *a, *b; size_t n; };

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static double sha_run(void *p)
{
    struct buf *b = p;
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    double t0 = now_ns();
    CC_SHA256(b->a, (CC_LONG)b->n, md);
    double t = now_ns() - t0;
    if (md[0] == 0x42 && md[1] == 0x42) printf("x");
    return b->n / t * 1e9 / (1 << 20);   /* MiB/s */
}
#pragma clang diagnostic pop

static double aes_run(void *p)
{
    struct buf *b = p;
    uint8_t key[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}, iv[16] = {0};
    size_t moved = 0;
    double t0 = now_ns();
    CCCryptorStatus s = CCCrypt(kCCEncrypt, kCCAlgorithmAES, 0, key, sizeof key, iv, b->a, b->n, b->b, b->n, &moved);
    double t = now_ns() - t0;
    if (s != kCCSuccess) return -1;
    return b->n / t * 1e9 / (1 << 20);
}

static double tsb_run(void *p)
{
    struct buf *b = p;
    const int calls = 2000000;
    int acc = 0;
    double t0 = now_ns();
    for (int i = 0; i < calls; i++) acc += timingsafe_bcmp(b->a + (i & 63), b->b + (i & 63), 64);
    double t = now_ns() - t0;
    if (acc == 42) printf("x");
    return t / calls;   /* ns per call */
}

/* ---- libcompression ---- */

struct comp { uint8_t *src, *enc, *dec; size_t n, encN; compression_algorithm alg; };
static double comp_enc(void *p)
{
    struct comp *c = p;
    double t0 = now_ns();
    c->encN = compression_encode_buffer(c->enc, c->n, c->src, c->n, NULL, c->alg);
    double t = now_ns() - t0;
    return c->encN ? c->n / t * 1e9 / (1 << 20) : -1;
}
static double comp_dec(void *p)
{
    struct comp *c = p;
    double t0 = now_ns();
    size_t n = compression_decode_buffer(c->dec, c->n, c->enc, c->encN, NULL, c->alg);
    double t = now_ns() - t0;
    return n == c->n ? c->n / t * 1e9 / (1 << 20) : -1;
}

static void compression_bench(void)
{
    if (!wanted("lzfse_enc") && !wanted("lzfse_dec") && !wanted("zlib_enc") && !wanted("zlib_dec")) return;
    struct comp c;
    c.n = 8u << 20;
    c.src = malloc(c.n); c.enc = malloc(c.n); c.dec = malloc(c.n);
    static const char *words[] = {"simulator ", "kernel ", "feature ", "vector ", "the ", "a ", "commpage ", "sysctl\n"};
    uint64_t r = 88172645463325252ull;
    for (size_t i = 0; i < c.n;) {
        r ^= r << 13; r ^= r >> 7; r ^= r << 17;
        const char *w = words[r % 8];
        for (; *w && i < c.n; w++) c.src[i++] = (uint8_t)*w;
        if ((r >> 20) % 5 == 0 && i < c.n) c.src[i++] = (uint8_t)(r >> 32);
    }
    c.alg = COMPRESSION_LZFSE;
    report("lzfse_enc", "MiB/s", comp_enc, &c);
    report("lzfse_dec", "MiB/s", comp_dec, &c);
    c.alg = COMPRESSION_ZLIB;
    report("zlib_enc", "MiB/s", comp_enc, &c);
    report("zlib_dec", "MiB/s", comp_dec, &c);
    free(c.src); free(c.enc); free(c.dec);
}

/* ---- ImageIO ---- */

static double jpeg_run(void *p)
{
    CFDataRef data = p;
    double t0 = now_ns();
    CGImageSourceRef src = CGImageSourceCreateWithData(data, NULL);
    const void *k[] = {kCGImageSourceShouldCacheImmediately};
    const void *v[] = {kCFBooleanTrue};
    CFDictionaryRef opts = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, opts) : NULL;
    double t = -1;
    if (img) {
        CFDataRef pixels = CGDataProviderCopyData(CGImageGetDataProvider(img));
        t = (now_ns() - t0) / 1e6;
        if (pixels) CFRelease(pixels); else t = -1;
        CGImageRelease(img);
    }
    CFRelease(opts);
    if (src) CFRelease(src);
    return t;
}

static void imageio_bench(void)
{
    if (!wanted("jpeg_decode")) return;
    const size_t W = 2048, H = 2048;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, W * 4, cs, kCGImageAlphaNoneSkipLast);
    if (!ctx) { printf("bench jpeg_decode: no bitmap context\n"); return; }
    uint8_t *px = CGBitmapContextGetData(ctx);
    uint64_t r = 1;
    for (size_t y = 0; y < H; y++)
        for (size_t x = 0; x < W; x++) {
            r ^= r << 13; r ^= r >> 7; r ^= r << 17;
            uint8_t *q = px + 4 * (y * W + x);
            q[0] = (uint8_t)(x / 8 + (r & 15)); q[1] = (uint8_t)(y / 8 + ((r >> 8) & 15)); q[2] = (uint8_t)((x + y) / 16); q[3] = 255;
        }
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
    CGImageDestinationRef dst = CGImageDestinationCreateWithData(data, CFSTR("public.jpeg"), 1, NULL);
    if (!dst || !img) { printf("bench jpeg_decode: no JPEG encoder\n"); return; }
    CGImageDestinationAddImage(dst, img, NULL);
    if (!CGImageDestinationFinalize(dst)) { printf("bench jpeg_decode: encode failed\n"); return; }
    printf("jpeg: %zux%zu, %ld bytes\n", W, H, (long)CFDataGetLength(data));
    report("jpeg_decode", "ms", jpeg_run, data);
    CFRelease(dst); CFRelease(data); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc > 1) only = argv[1];
    double t0 = now_ns();

    js_bench("js_int32",
             "function f(n){var s=0;for(var i=0;i<n;i++){var d=i*1.25+0.5;s=(s+(d|0)+(Math.trunc(d*3.5)|0))|0;}return s;}",
             "f(10000000)");
    js_bench("js_atomics",
             "var a=new Int32Array(new ArrayBuffer(64));function g(n){for(var i=0;i<n;i++){Atomics.add(a,i&7,1);Atomics.compareExchange(a,8,i,i+1);}return a[0];}",
             "g(5000000)");
    js_bench("js_mixed",
             "function h(n){var o=[];for(var i=0;i<n;i++){o.push({x:i,y:i*0.5,s:'k'+(i%100)});}var t=0;for(var j=0;j<o.length;j++){t+=o[j].y+o[j].s.length;}o.sort(function(a,b){return b.y-a.y;});return t+o[0].x;}",
             "h(300000)");

    if (wanted("sgemm512")) {
        struct gemm g = {malloc(512 * 512 * 4), malloc(512 * 512 * 4), malloc(512 * 512 * 4), 512};
        for (int i = 0; i < 512 * 512; i++) { g.a[i] = (float)(i % 13) * 0.25f; g.b[i] = (float)(i % 7) * 0.5f; }
        report("sgemm512", "GFLOP/s", sgemm_run, &g);
        free(g.a); free(g.b); free(g.c);
    }
    bnns_bench();

    struct buf b = {malloc(CRYPTO_BYTES + 128), malloc(CRYPTO_BYTES + 128), CRYPTO_BYTES};
    for (size_t i = 0; i < CRYPTO_BYTES + 128; i++) b.a[i] = b.b[i] = (uint8_t)(i * 31);
    report("sha256", "MiB/s", sha_run, &b);
    report("aes128cbc", "MiB/s", aes_run, &b);
    report("timingsafe_bcmp64", "ns/call", tsb_run, &b);
    free(b.a); free(b.b);

    compression_bench();
    imageio_bench();
    printf("bench done in %.1f s\n", (now_ns() - t0) / 1e9);
    return 0;
}
