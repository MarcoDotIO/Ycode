/* Ycode stage-8 probe p_metal_triangle (original Ycode code;
 * specs/simulator/stage8-contract.md §8, milestone 8a-T).
 *
 * Draws the hello triangle with Metal: red at the top, green bottom left,
 * blue bottom right, on a dark background, into a 512x512 BGRA8 texture;
 * reads it back with getBytes and writes /tmp/p_metal_triangle.png.
 * Loads the precompiled p_metal_triangle.metallib next to the executable
 * (newLibraryWithURL:), so the guest's shader compiler is not needed.
 *
 * Usage: p_metal_triangle [METALLIB [OUT.png]]
 * Prints "triangle ok" when the sampled pixels are right, else
 * "triangle FAIL" (exit 1). Every step prints a line, so a hang shows where.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 512
#define H 512

static void step(const char *s) {
    printf("p_metal_triangle: %s\n", s);
    fflush(stdout);
}

/* ---- A minimal PNG writer (stored deflate blocks, no compression). ---- */

static uint32_t crc_table[256];

static void crc_init(void) {
    for (uint32_t n = 0; n < 256; n++) {
        uint32_t c = n;
        for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crc_table[n] = c;
    }
}

static uint32_t crc(uint32_t c, const uint8_t *p, size_t n) {
    c = ~c;
    while (n--) c = crc_table[(c ^ *p++) & 0xFF] ^ (c >> 8);
    return ~c;
}

static void put32(FILE *f, uint32_t v) {
    uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    fwrite(b, 1, 4, f);
}

static void chunk(FILE *f, const char *type, const uint8_t *data, size_t n) {
    put32(f, (uint32_t)n);
    fwrite(type, 1, 4, f);
    if (n) fwrite(data, 1, n, f);
    uint32_t c = crc(0, (const uint8_t *)type, 4);
    c = crc(c, data, n);
    put32(f, c);
}

/* rgb: H rows of W*3 bytes. */
static int write_png(const char *path, const uint8_t *rgb) {
    crc_init();
    size_t raw_len = (size_t)H * (1 + W * 3);
    uint8_t *raw = malloc(raw_len);
    for (int y = 0; y < H; y++) {
        raw[y * (1 + W * 3)] = 0;
        memcpy(raw + y * (1 + W * 3) + 1, rgb + (size_t)y * W * 3, W * 3);
    }
    size_t blocks = (raw_len + 65534) / 65535;
    size_t z_len = 2 + raw_len + blocks * 5 + 4;
    uint8_t *z = malloc(z_len), *o = z;
    *o++ = 0x78;
    *o++ = 0x01;
    uint32_t a = 1, b = 0;
    for (size_t i = 0; i < raw_len; i++) {
        a = (a + raw[i]) % 65521;
        b = (b + a) % 65521;
    }
    for (size_t off = 0; off < raw_len; off += 65535) {
        size_t n = raw_len - off < 65535 ? raw_len - off : 65535;
        *o++ = off + n == raw_len ? 1 : 0;
        *o++ = (uint8_t)n;
        *o++ = (uint8_t)(n >> 8);
        *o++ = (uint8_t)~n;
        *o++ = (uint8_t)(~n >> 8);
        memcpy(o, raw + off, n);
        o += n;
    }
    uint32_t adler = (b << 16) | a;
    *o++ = (uint8_t)(adler >> 24);
    *o++ = (uint8_t)(adler >> 16);
    *o++ = (uint8_t)(adler >> 8);
    *o++ = (uint8_t)adler;
    FILE *f = fopen(path, "wb");
    if (!f) { free(raw); free(z); return -1; }
    static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    fwrite(sig, 1, 8, f);
    uint8_t ihdr[13] = {0, 0, W >> 8, W & 0xFF, 0, 0, H >> 8, H & 0xFF, 8, 2, 0, 0, 0};
    chunk(f, "IHDR", ihdr, 13);
    chunk(f, "IDAT", z, (size_t)(o - z));
    chunk(f, "IEND", NULL, 0);
    fclose(f);
    free(raw);
    free(z);
    return 0;
}

/* ---- The triangle. ---- */

typedef struct {
    float position[2];
    float pad[2];
    float color[4];
} Vertex;

int main(int argc, char **argv) {
    @autoreleasepool {
        step("start");
        NSString *libPath;
        if (argc > 1) {
            libPath = [NSString stringWithUTF8String:argv[1]];
        } else {
            char exe[4096];
            uint32_t n = sizeof exe;
            if (_NSGetExecutablePath(exe, &n) != 0) strcpy(exe, argv[0]);
            libPath = [[[NSString stringWithUTF8String:exe] stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:@"p_metal_triangle.metallib"];
        }
        const char *outPath = argc > 2 ? argv[2] : "/tmp/p_metal_triangle.png";

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { printf("triangle FAIL: no Metal device\n"); return 1; }
        printf("p_metal_triangle: device \"%s\"\n", device.name.UTF8String);
        fflush(stdout);

        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:libPath] error:&error];
        if (!library) { printf("triangle FAIL: library %s: %s\n", libPath.UTF8String, error.description.UTF8String); return 1; }
        id<MTLFunction> vfn = [library newFunctionWithName:@"triangle_vertex"];
        id<MTLFunction> ffn = [library newFunctionWithName:@"triangle_fragment"];
        if (!vfn || !ffn) { printf("triangle FAIL: functions missing in %s\n", libPath.UTF8String); return 1; }
        step("library loaded");

        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        vd.attributes[0].format = MTLVertexFormatFloat2;
        vd.attributes[0].offset = 0;
        vd.attributes[0].bufferIndex = 0;
        vd.attributes[1].format = MTLVertexFormatFloat4;
        vd.attributes[1].offset = 16;
        vd.attributes[1].bufferIndex = 0;
        vd.layouts[0].stride = sizeof(Vertex);

        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.label = @"hello triangle";
        pd.vertexFunction = vfn;
        pd.fragmentFunction = ffn;
        pd.vertexDescriptor = vd;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!pipeline) { printf("triangle FAIL: pipeline: %s\n", error.description.UTF8String); return 1; }
        step("pipeline created");

        static const Vertex vertices[3] = {
            {{0.0f, 0.8f}, {0, 0}, {1, 0, 0, 1}},
            {{-0.8f, -0.8f}, {0, 0}, {0, 1, 0, 1}},
            {{0.8f, -0.8f}, {0, 0}, {0, 0, 1, 1}},
        };
        id<MTLBuffer> vbuf = [device newBufferWithBytes:vertices length:sizeof vertices options:MTLResourceStorageModeShared];

        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                       width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> target = [device newTextureWithDescriptor:td];
        if (!vbuf || !target) { printf("triangle FAIL: buffer or texture\n"); return 1; }

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.10, 0.10, 0.15, 1.0);

        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pipeline];
        [enc setVertexBuffer:vbuf offset:0 atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        [cb commit];
        step("committed");
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) {
            printf("triangle FAIL: command buffer status %ld\n", (long)cb.status);
            return 1;
        }
        step("completed");

        uint8_t *bgra = malloc((size_t)W * H * 4);
        [target getBytes:bgra bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
        uint8_t *rgb = malloc((size_t)W * H * 3);
        for (size_t i = 0; i < (size_t)W * H; i++) {
            rgb[3 * i + 0] = bgra[4 * i + 2];
            rgb[3 * i + 1] = bgra[4 * i + 1];
            rgb[3 * i + 2] = bgra[4 * i + 0];
        }
        if (write_png(outPath, rgb) != 0) { printf("triangle FAIL: cannot write %s\n", outPath); return 1; }
        printf("p_metal_triangle: wrote %s\n", outPath);

        /* Samples: background corner, near each vertex, centre. */
        struct { const char *name; int x, y; } s[] = {
            {"corner", 8, 8}, {"top (red)", 256, 80}, {"bottom-left (green)", 70, 440},
            {"bottom-right (blue)", 440, 440}, {"centre", 256, 300},
        };
        int ok = 1;
        for (int i = 0; i < 5; i++) {
            const uint8_t *p = rgb + 3 * ((size_t)s[i].y * W + s[i].x);
            printf("p_metal_triangle: pixel %-20s (%3d,%3d) = rgb(%3u,%3u,%3u)\n", s[i].name, s[i].x, s[i].y, p[0], p[1], p[2]);
        }
        const uint8_t *c = rgb + 3 * (8 * W + 8), *r = rgb + 3 * (80 * W + 256), *g = rgb + 3 * (440 * W + 70),
                      *b = rgb + 3 * (440 * W + 440);
        if (!(c[0] < 40 && c[1] < 40 && c[2] > 25 && c[2] < 50)) ok = 0;   /* dark background */
        if (!(r[0] > 180 && r[1] < 60 && r[2] < 60)) ok = 0;                /* red at the top */
        if (!(g[1] > 180 && g[0] < 60 && g[2] < 60)) ok = 0;                /* green bottom left */
        if (!(b[2] > 180 && b[0] < 60 && b[1] < 60)) ok = 0;                /* blue bottom right */
        printf(ok ? "triangle ok\n" : "triangle FAIL: pixels\n");
        return ok ? 0 : 1;
    }
}
