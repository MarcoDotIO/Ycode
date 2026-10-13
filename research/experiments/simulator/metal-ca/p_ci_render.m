/* p_ci_render: Ycode stage-8 test probe (original Ycode code).
 *
 * Renders a fixed grid of Core Image filter results with a Metal-backed
 * CIContext into a Metal texture, reads it back and writes a PNG. Core
 * Image builds its GPU kernels at run time (stitched from its own
 * libraries), which is the path iconservicesagent and the wallpaper
 * extensions use, so this checks that Ycode's Metal host translates and
 * runs those kernels like the Mac's GPU does.
 *
 * Usage: p_ci_render [OUT.png]   (default /tmp/p_ci_render.png)
 * Prints one line per step and "ci ok" at the end, or "ci FAIL: ...".
 * Public APIs only: CoreImage (built-in filters by name), Metal.
 */
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define CELL_W 150
#define CELL_H 200
#define COLS 4
#define ROWS 4

static void step(const char *s) {
    printf("p_ci_render: %s\n", s);
    fflush(stdout);
}

static void be32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

static void chunk(FILE *f, const char *type, const uint8_t *data, uint32_t n) {
    uint8_t h[8];
    be32(h, n);
    memcpy(h + 4, type, 4);
    fwrite(h, 1, 8, f);
    if (n) fwrite(data, 1, n, f);
    uLong c = crc32(0, (const Bytef *)type, 4);
    c = crc32(c, data, n);
    uint8_t t[4];
    be32(t, (uint32_t)c);
    fwrite(t, 1, 4, f);
}

static int write_png(const char *path, const uint8_t *rgba, int w, int h) {
    size_t raw_n = (size_t)h * (1 + (size_t)w * 4);
    uint8_t *raw = malloc(raw_n);
    for (int y = 0; y < h; y++) {
        raw[y * (1 + w * 4)] = 0;
        memcpy(raw + y * (1 + w * 4) + 1, rgba + (size_t)y * w * 4, (size_t)w * 4);
    }
    uLongf z_n = compressBound(raw_n);
    uint8_t *z = malloc(z_n);
    if (compress2(z, &z_n, raw, raw_n, 6) != Z_OK) { free(raw); free(z); return -1; }
    FILE *f = fopen(path, "wb");
    if (!f) { free(raw); free(z); return -1; }
    static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    fwrite(sig, 1, 8, f);
    uint8_t ihdr[13];
    be32(ihdr, (uint32_t)w);
    be32(ihdr + 4, (uint32_t)h);
    ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
    chunk(f, "IHDR", ihdr, 13);
    chunk(f, "IDAT", z, (uint32_t)z_n);
    chunk(f, "IEND", NULL, 0);
    fclose(f);
    free(raw);
    free(z);
    return 0;
}

static CIImage *apply(NSString *name, NSDictionary *params) {
    CIFilter *f = [CIFilter filterWithName:name];
    if (!f) { printf("p_ci_render: no filter %s\n", name.UTF8String); return nil; }
    for (NSString *k in params) [f setValue:params[k] forKey:k];
    return f.outputImage;
}

static CIVector *vec2(CGFloat x, CGFloat y) { return [CIVector vectorWithX:x Y:y]; }

static CIColor *col(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    static CGColorSpaceRef cs;
    if (!cs) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    return [CIColor colorWithRed:r green:g blue:b alpha:a colorSpace:cs];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *outPath = argc > 1 ? argv[1] : "/tmp/p_ci_render.png";
        const int w = CELL_W * COLS, h = CELL_H * ROWS;
        step("start");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { printf("ci FAIL: no Metal device\n"); return 1; }
        printf("p_ci_render: device \"%s\"\n", device.name.UTF8String);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        CIContext *ctx = [CIContext contextWithMTLCommandQueue:queue
                                                       options:@{kCIContextWorkingFormat: @(kCIFormatRGBAh),
                                                                 kCIContextCacheIntermediates: @NO}];
        step("context created");

        CGRect cellRect = CGRectMake(0, 0, CELL_W, CELL_H);
        CIImage *checker = apply(@"CICheckerboardGenerator", @{@"inputCenter": vec2(0, 0), @"inputColor0": col(0.9, 0.2, 0.1, 1),
                                                                @"inputColor1": col(0.1, 0.3, 0.9, 1), @"inputWidth": @20, @"inputSharpness": @1});
        CIImage *gradient = apply(@"CILinearGradient", @{@"inputPoint0": vec2(0, 0), @"inputPoint1": vec2(CELL_W, CELL_H),
                                                         @"inputColor0": col(1, 0.9, 0, 1), @"inputColor1": col(0, 0.6, 0.4, 1)});
        NSMutableArray<CIImage *> *cells = [NSMutableArray array];
        /* 0 checkerboard */
        [cells addObject:checker];
        /* 1 linear gradient */
        [cells addObject:gradient];
        /* 2 radial gradient */
        [cells addObject:apply(@"CIRadialGradient", @{@"inputCenter": vec2(75, 100), @"inputRadius0": @10, @"inputRadius1": @90,
                                                      @"inputColor0": col(1, 1, 1, 1), @"inputColor1": col(0.4, 0, 0.6, 1)})];
        /* 3 gaussian blur of the checkerboard */
        [cells addObject:apply(@"CIGaussianBlur", @{kCIInputImageKey: [checker imageByCroppingToRect:cellRect], kCIInputRadiusKey: @8})];
        /* 4 colour controls (desaturate, brighten) */
        [cells addObject:apply(@"CIColorControls", @{kCIInputImageKey: checker, kCIInputSaturationKey: @0.2,
                                                     kCIInputBrightnessKey: @0.1, kCIInputContrastKey: @1.3})];
        /* 5 colour matrix (swap red and blue) */
        [cells addObject:apply(@"CIColorMatrix", @{kCIInputImageKey: gradient, @"inputRVector": [CIVector vectorWithX:0 Y:0 Z:1 W:0],
                                                   @"inputBVector": [CIVector vectorWithX:1 Y:0 Z:0 W:0]})];
        /* 6 vignette */
        [cells addObject:apply(@"CIVignette", @{kCIInputImageKey: [gradient imageByCroppingToRect:cellRect], kCIInputIntensityKey: @1.5,
                                                kCIInputRadiusKey: @1.5})];
        /* 7 sepia */
        [cells addObject:apply(@"CISepiaTone", @{kCIInputImageKey: checker, kCIInputIntensityKey: @0.9})];
        /* 8 affine scale with linear sampling (magnified checkerboard) */
        [cells addObject:[[checker imageByCroppingToRect:CGRectMake(0, 0, 40, 40)] imageByApplyingTransform:CGAffineTransformMakeScale(3.3, 3.3)]];
        /* 9 source-over of a translucent gradient over the checkerboard */
        [cells addObject:apply(@"CISourceOverCompositing", @{kCIInputImageKey: [apply(@"CIColorMatrix", @{kCIInputImageKey: gradient,
                                                            @"inputAVector": [CIVector vectorWithX:0 Y:0 Z:0 W:0.5]}) imageByCroppingToRect:CGRectMake(20, 20, 110, 160)],
                                                            kCIInputBackgroundImageKey: checker})];
        /* 10 multiply blend */
        [cells addObject:apply(@"CIMultiplyBlendMode", @{kCIInputImageKey: gradient, kCIInputBackgroundImageKey: checker})];
        /* 11 exposure plus gamma */
        [cells addObject:apply(@"CIGammaAdjust", @{kCIInputImageKey: apply(@"CIExposureAdjust", @{kCIInputImageKey: gradient, kCIInputEVKey: @0.7}),
                                                   @"inputPower": @1.8})];
        /* 12 box blur */
        [cells addObject:apply(@"CIBoxBlur", @{kCIInputImageKey: [checker imageByCroppingToRect:cellRect], kCIInputRadiusKey: @12})];
        /* 13 invert */
        [cells addObject:apply(@"CIColorInvert", @{kCIInputImageKey: gradient})];
        /* 14 pixellate */
        [cells addObject:apply(@"CIPixellate", @{kCIInputImageKey: gradient, kCIInputCenterKey: vec2(0, 0), kCIInputScaleKey: @15})];
        /* 15 stripes generator */
        [cells addObject:apply(@"CIStripesGenerator", @{@"inputCenter": vec2(0, 0), @"inputColor0": col(0, 0, 0, 1),
                                                        @"inputColor1": col(1, 1, 1, 1), @"inputWidth": @10, @"inputSharpness": @1})];

        CIImage *out = [[CIImage imageWithColor:col(1, 1, 1, 1)] imageByCroppingToRect:CGRectMake(0, 0, w, h)];
        for (NSUInteger i = 0; i < cells.count; i++) {
            CIImage *c = cells[i];
            if (!c) continue;
            c = [c imageByCroppingToRect:CGRectInset(cellRect, 4, 4)];
            CGFloat x = (i % COLS) * CELL_W, y = (i / COLS) * CELL_H;
            c = [c imageByApplyingTransform:CGAffineTransformMakeTranslation(x, y)];
            out = [c imageByCompositingOverImage:out];
        }
        step("filter graph built");

        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:w height:h mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> target = [device newTextureWithDescriptor:td];
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        [ctx render:out toMTLTexture:target commandBuffer:cb bounds:CGRectMake(0, 0, w, h) colorSpace:srgb];
        [cb commit];
        [cb waitUntilCompleted];
        printf("p_ci_render: command buffer status %ld%s\n", (long)cb.status, cb.error ? " (error)" : "");
        step("rendered");

        uint8_t *bgra = malloc((size_t)w * h * 4);
        [target getBytes:bgra bytesPerRow:(NSUInteger)w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
        uint8_t *rgba = malloc((size_t)w * h * 4);
        uint64_t hash = 1469598103934665603ull;
        size_t nonwhite = 0;
        for (size_t i = 0; i < (size_t)w * h; i++) {
            rgba[i * 4 + 0] = bgra[i * 4 + 2];
            rgba[i * 4 + 1] = bgra[i * 4 + 1];
            rgba[i * 4 + 2] = bgra[i * 4 + 0];
            rgba[i * 4 + 3] = bgra[i * 4 + 3];
            for (int k = 0; k < 4; k++) hash = (hash ^ rgba[i * 4 + k]) * 1099511628211ull;
            if (bgra[i * 4] != 255 || bgra[i * 4 + 1] != 255 || bgra[i * 4 + 2] != 255) nonwhite++;
        }
        printf("p_ci_render: %dx%d, fnv1a64 %016llx, non-white pixels %zu\n", w, h, (unsigned long long)hash, nonwhite);
        for (int c = 0; c < COLS * ROWS; c++) {
            int x = (c % COLS) * CELL_W + CELL_W / 2, y = (c / COLS) * CELL_H + CELL_H / 2;
            const uint8_t *p = rgba + ((size_t)y * w + x) * 4;
            printf("p_ci_render: cell %2d centre (%4d,%4d) = rgba(%3d,%3d,%3d,%3d)\n", c, x, y, p[0], p[1], p[2], p[3]);
        }
        if (write_png(outPath, rgba, w, h) != 0) { printf("ci FAIL: cannot write %s\n", outPath); return 1; }
        printf("p_ci_render: wrote %s\n", outPath);
        CGColorSpaceRelease(srgb);
        free(bgra);
        free(rgba);
        if (nonwhite < (size_t)w * h / 4) { printf("ci FAIL: almost nothing drawn\n"); return 1; }
        printf("ci ok\n");
        return 0;
    }
}
