/* p_ca_render: Ycode stage-8 test probe (original Ycode code).
 *
 * Renders a fixed Core Animation layer tree with the public CARenderer API
 * into a Metal texture, reads it back and writes a PNG. It exercises the
 * same QuartzCore Metal renderer that backboardd uses for compositing
 * (rounded corners, borders, gradients, shadows, images, masks, shapes,
 * text, transforms, group opacity), but in a process we control, so the
 * result can be compared pixel by pixel between the Mac's simulator (the
 * Mac GPU) and Ycode on Linux (Metal on Vulkan).
 *
 * Usage: p_ca_render [OUT.png [SCALE [SCENE]]]   (default /tmp/p_ca_render.png, 1, basic)
 * SCENE "fx" renders effects instead: Core Animation filters, backdrop
 * layers (blur and saturation, what system materials are made of), blend
 * modes, conic gradients, rasterization, nine-part stretching, image masks.
 * Those filter and backdrop classes are not public API; the probe finds
 * them by name at run time (level 4) and skips a cell when one is missing.
 * Prints one line per step and "ca ok" at the end, or "ca FAIL: ...".
 * Public APIs only: QuartzCore (CARenderer, CALayer and subclasses),
 * CoreGraphics, CoreText, Metal.
 */
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define CELL_W 150
#define CELL_H 200
#define COLS 4
#define ROWS 4

static void step(const char *s) {
    printf("p_ca_render: %s\n", s);
    fflush(stdout);
}

/* ---- PNG (zlib from libz) ---- */

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

/* ---- Layer tree ---- */

static CGColorRef rgb(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    static CGColorSpaceRef cs;
    if (!cs) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat c[4] = {r, g, b, a};
    return (CGColorRef)CFAutorelease(CGColorCreate(cs, c));
}

/* A 32x32 image: a 4x4 checkerboard with a red-to-blue ramp. */
static CGImageRef make_image(void) {
    const int n = 32;
    uint8_t *px = calloc(n * n, 4);
    for (int y = 0; y < n; y++) {
        for (int x = 0; x < n; x++) {
            uint8_t *p = px + (y * n + x) * 4;
            int check = ((x / 4) + (y / 4)) & 1;
            p[0] = (uint8_t)(255 * x / (n - 1));                    /* R */
            p[1] = check ? 200 : 40;                                 /* G */
            p[2] = (uint8_t)(255 - 255 * y / (n - 1));              /* B */
            p[3] = 255;
        }
    }
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(px, n, n, 8, n * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(px);
    return img;
}

static CGPathRef star_path(CGRect r) {
    CGMutablePathRef p = CGPathCreateMutable();
    CGFloat cx = CGRectGetMidX(r), cy = CGRectGetMidY(r), R = r.size.width * 0.45, rr = R * 0.45;
    for (int i = 0; i < 10; i++) {
        CGFloat a = M_PI / 2 + i * M_PI / 5, rad = (i & 1) ? rr : R;
        CGFloat x = cx + rad * cos(a), y = cy + rad * sin(a);
        if (i == 0) CGPathMoveToPoint(p, NULL, x, y); else CGPathAddLineToPoint(p, NULL, x, y);
    }
    CGPathCloseSubpath(p);
    return (CGPathRef)CFAutorelease(p);
}

static CALayer *cell(CALayer *root, int index) {
    CALayer *c = [CALayer layer];
    int col = index % COLS, row = index / COLS;
    c.frame = CGRectMake(col * CELL_W, row * CELL_H, CELL_W, CELL_H);
    c.backgroundColor = rgb(0.92, 0.92, 0.95, 1);
    c.borderColor = rgb(0.6, 0.6, 0.65, 1);
    c.borderWidth = 1;
    [root addSublayer:c];
    return c;
}

static CALayer *build_tree(CGImageRef image, CGFloat scale) {
    CALayer *root = [CALayer layer];
    root.frame = CGRectMake(0, 0, CELL_W * COLS, CELL_H * ROWS);
    root.backgroundColor = rgb(1, 1, 1, 1);
    CGRect inner = CGRectMake(25, 50, 100, 100);
    int i = 0;

    /* 0: solid rectangle */
    { CALayer *c = cell(root, i++); CALayer *l = [CALayer layer]; l.frame = inner; l.backgroundColor = rgb(0.9, 0.1, 0.1, 1); [c addSublayer:l]; }
    /* 1: rounded rectangle with a border */
    { CALayer *c = cell(root, i++); CALayer *l = [CALayer layer]; l.frame = inner; l.backgroundColor = rgb(0.1, 0.6, 0.2, 1);
      l.cornerRadius = 24; l.borderWidth = 6; l.borderColor = rgb(0.05, 0.05, 0.4, 1); [c addSublayer:l]; }
    /* 2: axial gradient */
    { CALayer *c = cell(root, i++); CAGradientLayer *l = [CAGradientLayer layer]; l.frame = inner;
      l.colors = @[(__bridge id)rgb(1, 0, 0, 1), (__bridge id)rgb(0, 1, 0, 1), (__bridge id)rgb(0, 0, 1, 1)];
      l.startPoint = CGPointMake(0, 0); l.endPoint = CGPointMake(1, 1); [c addSublayer:l]; }
    /* 3: radial gradient */
    { CALayer *c = cell(root, i++); CAGradientLayer *l = [CAGradientLayer layer]; l.frame = inner; l.type = kCAGradientLayerRadial;
      l.colors = @[(__bridge id)rgb(1, 1, 0, 1), (__bridge id)rgb(0.5, 0, 0.5, 1)];
      l.startPoint = CGPointMake(0.5, 0.5); l.endPoint = CGPointMake(1, 1); [c addSublayer:l]; }
    /* 4: shadow */
    { CALayer *c = cell(root, i++); CALayer *l = [CALayer layer]; l.frame = CGRectInset(inner, 10, 10); l.backgroundColor = rgb(0.2, 0.4, 0.9, 1);
      l.shadowOpacity = 0.8; l.shadowRadius = 10; l.shadowOffset = CGSizeMake(6, 8); l.shadowColor = rgb(0, 0, 0, 1); l.cornerRadius = 12; [c addSublayer:l]; }
    /* 5: image, linear filter, magnified */
    { CALayer *c = cell(root, i++); CALayer *l = [CALayer layer]; l.frame = inner; l.contents = (__bridge id)image;
      l.magnificationFilter = kCAFilterLinear; [c addSublayer:l]; }
    /* 6: image, nearest filter */
    { CALayer *c = cell(root, i++); CALayer *l = [CALayer layer]; l.frame = inner; l.contents = (__bridge id)image;
      l.magnificationFilter = kCAFilterNearest; [c addSublayer:l]; }
    /* 7: rotated, antialiased edges */
    { CALayer *c = cell(root, i++); CALayer *l = [CALayer layer]; l.frame = CGRectInset(inner, 15, 15); l.backgroundColor = rgb(0.95, 0.5, 0.0, 1);
      l.allowsEdgeAntialiasing = YES; l.affineTransform = CGAffineTransformMakeRotation(M_PI / 6); [c addSublayer:l]; }
    /* 8: group opacity over overlapping sublayers */
    { CALayer *c = cell(root, i++); CALayer *g = [CALayer layer]; g.frame = inner; g.opacity = 0.5; g.allowsGroupOpacity = YES;
      CALayer *a = [CALayer layer]; a.frame = CGRectMake(0, 0, 70, 70); a.backgroundColor = rgb(1, 0, 0, 1);
      CALayer *b = [CALayer layer]; b.frame = CGRectMake(30, 30, 70, 70); b.backgroundColor = rgb(0, 0, 1, 1);
      [g addSublayer:a]; [g addSublayer:b]; [c addSublayer:g]; }
    /* 9: shape layer: filled and stroked star */
    { CALayer *c = cell(root, i++); CAShapeLayer *l = [CAShapeLayer layer]; l.frame = inner; l.path = star_path(CGRectMake(0, 0, 100, 100));
      l.fillColor = rgb(1, 0.8, 0, 1); l.strokeColor = rgb(0.3, 0.1, 0, 1); l.lineWidth = 3; l.contentsScale = scale; [c addSublayer:l]; }
    /* 10: rounded clip of an image (masksToBounds) */
    { CALayer *c = cell(root, i++); CALayer *clip = [CALayer layer]; clip.frame = inner; clip.cornerRadius = 30; clip.masksToBounds = YES;
      CALayer *l = [CALayer layer]; l.frame = CGRectMake(-20, -20, 140, 140); l.contents = (__bridge id)image; [clip addSublayer:l]; [c addSublayer:clip]; }
    /* 11: text */
    { CALayer *c = cell(root, i++); CATextLayer *l = [CATextLayer layer]; l.frame = CGRectMake(5, 60, 140, 80);
      l.string = @"Ycode"; l.fontSize = 36; l.foregroundColor = rgb(0, 0, 0, 1); l.alignmentMode = kCAAlignmentCenter;
      l.contentsScale = scale; [c addSublayer:l]; }
    /* 12: mask layer (a star shape masks a gradient) */
    { CALayer *c = cell(root, i++); CAGradientLayer *l = [CAGradientLayer layer]; l.frame = inner;
      l.colors = @[(__bridge id)rgb(0, 0.7, 1, 1), (__bridge id)rgb(1, 0, 0.6, 1)];
      CAShapeLayer *m = [CAShapeLayer layer]; m.frame = l.bounds; m.path = star_path(CGRectMake(0, 0, 100, 100)); m.fillColor = rgb(0, 0, 0, 1);
      l.mask = m; [c addSublayer:l]; }
    /* 13: perspective 3D rotation */
    { CALayer *c = cell(root, i++); CALayer *l = [CALayer layer]; l.frame = inner; l.backgroundColor = rgb(0.5, 0.2, 0.8, 1);
      CATransform3D t = CATransform3DIdentity; t.m34 = -1.0 / 300; t = CATransform3DRotate(t, M_PI / 4, 0, 1, 0);
      l.transform = t; l.allowsEdgeAntialiasing = YES; [c addSublayer:l]; }
    /* 14: continuous corner curve, translucent fill over a stripe */
    { CALayer *c = cell(root, i++); CALayer *s = [CALayer layer]; s.frame = CGRectMake(0, 90, CELL_W, 20); s.backgroundColor = rgb(0, 0, 0, 1);
      CALayer *l = [CALayer layer]; l.frame = inner; l.backgroundColor = rgb(0.1, 0.5, 0.9, 0.6); l.cornerRadius = 30; l.cornerCurve = kCACornerCurveContinuous;
      [c addSublayer:s]; [c addSublayer:l]; }
    /* 15: replicator */
    { CALayer *c = cell(root, i++); CAReplicatorLayer *r = [CAReplicatorLayer layer]; r.frame = inner; r.instanceCount = 5;
      r.instanceTransform = CATransform3DMakeTranslation(18, 0, 0); r.instanceRedOffset = -0.2; r.instanceBlueOffset = 0.2;
      CALayer *l = [CALayer layer]; l.frame = CGRectMake(0, 20, 14, 60); l.backgroundColor = rgb(1, 1, 1, 1); [r addSublayer:l]; [c addSublayer:r]; }
    return root;
}

/* ---- The "fx" scene ---- */

static id filter(NSString *type) {
    Class c = NSClassFromString(@"CAFilter");
    if (!c) return nil;
    SEL sel = NSSelectorFromString(@"filterWithType:");
    if (![c respondsToSelector:sel]) return nil;
    id (*make)(id, SEL, NSString *) = (id (*)(id, SEL, NSString *))[c methodForSelector:sel];
    return make(c, sel, type);
}

static CALayer *stripes(CGRect frame) {
    CALayer *bg = [CALayer layer];
    bg.frame = frame;
    for (int i = 0; i < 6; i++) {
        CALayer *s = [CALayer layer];
        s.frame = CGRectMake(0, i * frame.size.height / 6, frame.size.width, frame.size.height / 12);
        static const CGFloat cols[6][3] = {{1, 0, 0}, {1, 0.6, 0}, {1, 1, 0}, {0, 0.8, 0}, {0, 0.4, 1}, {0.6, 0, 0.8}};
        s.backgroundColor = rgb(cols[i][0], cols[i][1], cols[i][2], 1);
        [bg addSublayer:s];
    }
    return bg;
}

static CALayer *backdrop(CGRect frame, NSArray *filters) {
    Class c = NSClassFromString(@"CABackdropLayer");
    if (!c) return nil;
    CALayer *l = [c layer];
    l.frame = frame;
    l.filters = filters;
    return l;
}

static CALayer *build_fx_tree(CGImageRef image, CGFloat scale) {
    CALayer *root = [CALayer layer];
    root.frame = CGRectMake(0, 0, CELL_W * COLS, CELL_H * ROWS);
    root.backgroundColor = rgb(1, 1, 1, 1);
    CGRect inner = CGRectMake(25, 50, 100, 100);
    int i = 0;
    id blur = filter(@"gaussianBlur");
    [blur setValue:@6 forKey:@"inputRadius"];

    /* 0: gaussian blur filter on an image layer */
    { CALayer *c = cell(root, i++); CALayer *l = [CALayer layer]; l.frame = inner; l.contents = (__bridge id)image;
      l.magnificationFilter = kCAFilterNearest; if (blur) l.filters = @[blur]; [c addSublayer:l]; }
    /* 1: backdrop blur over stripes (a material) */
    { CALayer *c = cell(root, i++); [c addSublayer:stripes(CGRectMake(0, 20, CELL_W, 160))];
      CALayer *b = backdrop(CGRectInset(inner, -10, -10), blur ? @[blur] : @[]); if (b) { b.cornerRadius = 20; b.masksToBounds = YES; [c addSublayer:b]; } }
    /* 2: backdrop blur plus saturation plus a translucent tint (like a dock) */
    { CALayer *c = cell(root, i++); [c addSublayer:stripes(CGRectMake(0, 20, CELL_W, 160))];
      id sat = filter(@"colorSaturate"); [sat setValue:@1.8 forKey:@"inputAmount"];
      NSMutableArray *fs = [NSMutableArray array]; if (blur) [fs addObject:blur]; if (sat) [fs addObject:sat];
      CALayer *b = backdrop(CGRectInset(inner, -10, -10), fs);
      if (b) { b.cornerRadius = 26; b.cornerCurve = kCACornerCurveContinuous; b.masksToBounds = YES; [c addSublayer:b];
               CALayer *tint = [CALayer layer]; tint.frame = b.frame; tint.cornerRadius = 26; tint.cornerCurve = kCACornerCurveContinuous;
               tint.backgroundColor = rgb(1, 1, 1, 0.3); [c addSublayer:tint]; } }
    /* 3: colour invert filter */
    { CALayer *c = cell(root, i++); CALayer *l = [CALayer layer]; l.frame = inner; l.contents = (__bridge id)image;
      id f = filter(@"colorInvert"); if (f) l.filters = @[f]; [c addSublayer:l]; }
    /* 4: desaturate (saturation 0) */
    { CALayer *c = cell(root, i++); CALayer *l = [CALayer layer]; l.frame = inner; l.contents = (__bridge id)image;
      id f = filter(@"colorSaturate"); [f setValue:@0 forKey:@"inputAmount"]; if (f) l.filters = @[f]; [c addSublayer:l]; }
    /* 5: multiply blend mode over a gradient */
    { CALayer *c = cell(root, i++); CAGradientLayer *g = [CAGradientLayer layer]; g.frame = inner;
      g.colors = @[(__bridge id)rgb(1, 1, 0, 1), (__bridge id)rgb(0, 1, 1, 1)]; [c addSublayer:g];
      CALayer *l = [CALayer layer]; l.frame = CGRectOffset(CGRectInset(inner, 20, 20), 15, 15); l.backgroundColor = rgb(0.9, 0.3, 0.5, 1);
      id f = filter(@"multiplyBlendMode"); if (f) l.compositingFilter = f; [c addSublayer:l]; }
    /* 6: screen blend mode */
    { CALayer *c = cell(root, i++); CAGradientLayer *g = [CAGradientLayer layer]; g.frame = inner;
      g.colors = @[(__bridge id)rgb(0.1, 0.1, 0.5, 1), (__bridge id)rgb(0.5, 0.1, 0.1, 1)]; [c addSublayer:g];
      CALayer *l = [CALayer layer]; l.frame = CGRectOffset(CGRectInset(inner, 20, 20), 15, 15); l.backgroundColor = rgb(0.2, 0.7, 0.3, 1);
      id f = filter(@"screenBlendMode"); if (f) l.compositingFilter = f; [c addSublayer:l]; }
    /* 7: conic gradient */
    { CALayer *c = cell(root, i++); CAGradientLayer *l = [CAGradientLayer layer]; l.frame = inner; l.type = kCAGradientLayerConic;
      l.colors = @[(__bridge id)rgb(1, 0, 0, 1), (__bridge id)rgb(0, 1, 0, 1), (__bridge id)rgb(0, 0, 1, 1), (__bridge id)rgb(1, 0, 0, 1)];
      l.startPoint = CGPointMake(0.5, 0.5); l.endPoint = CGPointMake(1, 0.5); l.cornerRadius = 50; l.masksToBounds = YES; [c addSublayer:l]; }
    /* 8: rasterized layer with a shadow */
    { CALayer *c = cell(root, i++); CALayer *l = [CALayer layer]; l.frame = CGRectInset(inner, 10, 10); l.backgroundColor = rgb(0.3, 0.8, 0.6, 1);
      l.cornerRadius = 16; l.shadowOpacity = 0.6; l.shadowRadius = 6; l.shadowOffset = CGSizeMake(0, 6); l.shouldRasterize = YES;
      l.rasterizationScale = scale; [c addSublayer:l]; }
    /* 9: shadow with a shadow path (no layer content) */
    { CALayer *c = cell(root, i++); CALayer *l = [CALayer layer]; l.frame = inner; l.shadowOpacity = 1; l.shadowRadius = 12;
      l.shadowColor = rgb(0.8, 0, 0, 1); l.shadowPath = (CGPathRef)CFAutorelease(CGPathCreateWithEllipseInRect(CGRectMake(10, 10, 80, 80), NULL));
      [c addSublayer:l]; }
    /* 10: nine-part stretch (contentsCenter) */
    { CALayer *c = cell(root, i++); CALayer *l = [CALayer layer]; l.frame = CGRectMake(10, 40, 130, 120); l.contents = (__bridge id)image;
      l.contentsCenter = CGRectMake(0.25, 0.25, 0.5, 0.5); l.magnificationFilter = kCAFilterNearest; [c addSublayer:l]; }
    /* 11: contentsRect (a quarter of the image) */
    { CALayer *c = cell(root, i++); CALayer *l = [CALayer layer]; l.frame = inner; l.contents = (__bridge id)image;
      l.contentsRect = CGRectMake(0.5, 0, 0.5, 0.5); l.magnificationFilter = kCAFilterNearest; [c addSublayer:l]; }
    /* 12: image used as a mask (its alpha) */
    { CALayer *c = cell(root, i++); CAGradientLayer *l = [CAGradientLayer layer]; l.frame = inner;
      l.colors = @[(__bridge id)rgb(1, 0.3, 0, 1), (__bridge id)rgb(0.2, 0, 1, 1)];
      CAGradientLayer *m = [CAGradientLayer layer]; m.frame = l.bounds; m.colors = @[(__bridge id)rgb(0, 0, 0, 1), (__bridge id)rgb(0, 0, 0, 0)];
      m.startPoint = CGPointMake(0, 0.5); m.endPoint = CGPointMake(1, 0.5); l.mask = m; [c addSublayer:l]; }
    /* 13: translucent image over stripes */
    { CALayer *c = cell(root, i++); [c addSublayer:stripes(CGRectMake(0, 20, CELL_W, 160))];
      CALayer *l = [CALayer layer]; l.frame = inner; l.contents = (__bridge id)image; l.opacity = 0.6; [c addSublayer:l]; }
    /* 14: backdrop blur with a large radius, rounded, over an image */
    { CALayer *c = cell(root, i++); CALayer *im = [CALayer layer]; im.frame = CGRectMake(5, 30, 140, 140); im.contents = (__bridge id)image;
      im.magnificationFilter = kCAFilterNearest; [c addSublayer:im];
      id big = filter(@"gaussianBlur"); [big setValue:@20 forKey:@"inputRadius"];
      CALayer *b = backdrop(CGRectMake(35, 60, 80, 80), big ? @[big] : @[]); if (b) { b.cornerRadius = 40; b.masksToBounds = YES; [c addSublayer:b]; } }
    /* 15: blur filter on a group of shapes (a filtered subtree) */
    { CALayer *c = cell(root, i++); CALayer *g = [CALayer layer]; g.frame = inner;
      CALayer *a = [CALayer layer]; a.frame = CGRectMake(10, 10, 40, 80); a.backgroundColor = rgb(0, 0, 0, 1);
      CALayer *b = [CALayer layer]; b.frame = CGRectMake(60, 30, 30, 30); b.backgroundColor = rgb(0.9, 0.1, 0.1, 1); b.cornerRadius = 15;
      [g addSublayer:a]; [g addSublayer:b]; if (blur) g.filters = @[blur]; [c addSublayer:g]; }
    return root;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *outPath = argc > 1 ? argv[1] : "/tmp/p_ca_render.png";
        CGFloat scale = argc > 2 ? atof(argv[2]) : 1;
        if (scale < 1) scale = 1;
        const char *scene = argc > 3 ? argv[3] : "basic";
        BOOL fx = strcmp(scene, "fx") == 0;
        printf("p_ca_render: scene %s, scale %g\n", fx ? "fx" : "basic", scale);
        int w = (int)(CELL_W * COLS * scale), h = (int)(CELL_H * ROWS * scale);
        step("start");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { printf("ca FAIL: no Metal device\n"); return 1; }
        printf("p_ca_render: device \"%s\"\n", device.name.UTF8String);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:w height:h mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> target = [device newTextureWithDescriptor:td];
        if (!target) { printf("ca FAIL: no texture\n"); return 1; }

        CGImageRef image = make_image();
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        CALayer *root = fx ? build_fx_tree(image, scale) : build_tree(image, scale);
        if (scale != 1) root.transform = CATransform3DMakeScale(scale, scale, 1);
        root.anchorPoint = CGPointZero;
        root.position = CGPointZero;
        [CATransaction commit];
        [CATransaction flush];
        step("layer tree built");

        CARenderer *renderer = [CARenderer rendererWithMTLTexture:target options:@{kCARendererMetalCommandQueue: queue}];
        renderer.layer = root;
        renderer.bounds = CGRectMake(0, 0, w, h);
        [CATransaction flush];
        step("renderer created");
        /* Two frames: the first may only prepare resources (images, text). */
        for (int frame = 0; frame < 2; frame++) {
            [renderer beginFrameAtTime:CACurrentMediaTime() + frame timeStamp:NULL];
            [renderer addUpdateRect:renderer.bounds];
            [renderer render];
            [renderer endFrame];
        }
        id<MTLCommandBuffer> fence = [queue commandBuffer];
        [fence commit];
        [fence waitUntilCompleted];
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
        printf("p_ca_render: %dx%d, fnv1a64 %016llx, non-white pixels %zu\n", w, h, (unsigned long long)hash, nonwhite);
        for (int c = 0; c < COLS * ROWS; c++) {
            int x = (int)(((c % COLS) * CELL_W + CELL_W / 2) * scale), y = (int)(((c / COLS) * CELL_H + CELL_H / 2) * scale);
            const uint8_t *p = rgba + ((size_t)y * w + x) * 4;
            printf("p_ca_render: cell %2d centre (%4d,%4d) = rgba(%3d,%3d,%3d,%3d)\n", c, x, y, p[0], p[1], p[2], p[3]);
        }
        if (write_png(outPath, rgba, w, h) != 0) { printf("ca FAIL: cannot write %s\n", outPath); return 1; }
        printf("p_ca_render: wrote %s\n", outPath);
        CGImageRelease(image);
        free(bgra);
        free(rgba);
        if (nonwhite < (size_t)w * h / 20) { printf("ca FAIL: almost nothing drawn\n"); return 1; }
        printf("ca ok\n");
        return 0;
    }
}
