// mtl-oracle.m: runs our test shaders (tests/shaders/*.metal) on the Mac's
// Metal device to produce the expected outputs of tests/gpu/tests.txt
// (black-box runs of our own programs). The Thor runner (airc-gpu.c) sets
// up the same inputs for the translated SPIR-V.
//
// Build: clang -fobjc-arc -O2 -framework Metal -framework Foundation mtl-oracle.m -o mtl-oracle
// Usage: mtl-oracle SHADER_DIR TESTS.txt OUT_DIR
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "gpu-data.h"

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static NSMutableDictionary<NSString *, id<MTLLibrary>> *libs;

static id<MTLLibrary> library(NSString *dir, NSString *name) {
    id<MTLLibrary> l = libs[name];
    if (l) return l;
    NSString *src = [NSString stringWithContentsOfFile:[dir stringByAppendingFormat:@"/%@.metal", name] encoding:NSUTF8StringEncoding error:nil];
    MTLCompileOptions *o = [MTLCompileOptions new];
    o.languageVersion = MTLLanguageVersion3_1;
    NSError *err = nil;
    l = [dev newLibraryWithSource:src options:o error:&err];
    if (!l) { fprintf(stderr, "compile %s: %s\n", name.UTF8String, err.description.UTF8String); exit(1); }
    libs[name] = l;
    return l;
}

static id<MTLBuffer> buffer(const void *data, size_t n) {
    id<MTLBuffer> b = [dev newBufferWithLength:n ? n : 16 options:MTLResourceStorageModeShared];
    if (data) memcpy(b.contents, data, n);
    else memset(b.contents, 0xCD, b.length);
    return b;
}

static id<MTLTexture> texture2d(MTLPixelFormat f, int w, int h, const void *data, size_t bpr, BOOL write) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | (write ? MTLTextureUsageShaderWrite : 0) | MTLTextureUsageRenderTarget;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    if (data) [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:data bytesPerRow:bpr];
    return t;
}

static void writeOut(NSString *dir, NSString *name, NSData *data) {
    [data writeToFile:[dir stringByAppendingFormat:@"/%@.bin", name] atomically:YES];
}

static NSData *readTexture(id<MTLTexture> t, size_t bpp, int depth) {
    size_t bpr = t.width * bpp;
    NSMutableData *d = [NSMutableData dataWithLength:bpr * t.height * depth];
    [t getBytes:d.mutableBytes bytesPerRow:bpr bytesPerImage:bpr * t.height fromRegion:MTLRegionMake3D(0, 0, 0, t.width, t.height, depth) mipmapLevel:0 slice:0];
    return d;
}

static void runCompute(NSString *shaderDir, NSString *outDir, NSArray<NSString *> *f) {
    NSString *name = f[1];
    id<MTLFunction> fn = [library(shaderDir, f[2]) newFunctionWithName:f[3]];
    NSError *err = nil;
    id<MTLComputePipelineState> ps;
    if ([name isEqual:@"call_visible"]) {
        // Visible functions are linked at pipeline creation.
        MTLComputePipelineDescriptor *cd = [MTLComputePipelineDescriptor new];
        cd.computeFunction = fn;
        MTLLinkedFunctions *lf = [MTLLinkedFunctions new];
        lf.functions = @[[library(shaderDir, f[2]) newFunctionWithName:@"vis_twice"], [library(shaderDir, f[2]) newFunctionWithName:@"vis_scale"]];
        cd.linkedFunctions = lf;
        ps = [dev newComputePipelineStateWithDescriptor:cd options:0 reflection:nil error:&err];
    } else {
        ps = [dev newComputePipelineStateWithFunction:fn error:&err];
    }
    if (!ps) { fprintf(stderr, "%s: %s\n", name.UTF8String, err.description.UTF8String); exit(1); }
    MTLSize grid = MTLSizeMake(f[4].intValue, f[5].intValue, f[6].intValue), tg = MTLSizeMake(f[7].intValue, f[8].intValue, f[9].intValue);
    size_t outBytes = (size_t)f[10].longLongValue;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:ps];
    id<MTLBuffer> out = buffer(NULL, outBytes);
    id<MTLBuffer> extra = nil;
    id<MTLTexture> tex = nil;
    const char *n = name.UTF8String;
    if (!strncmp(n, "add_", 4)) {
        uint32_t count = (uint32_t)(outBytes / 4);
        float *a = malloc(count * 4), *b = malloc(count * 4);
        gd_add_inputs(a, b, count);
        [e setBuffer:buffer(a, count * 4) offset:0 atIndex:0];
        [e setBuffer:buffer(b, count * 4) offset:0 atIndex:1];
        [e setBuffer:out offset:0 atIndex:2];
        [e setBuffer:buffer(&count, 4) offset:0 atIndex:3];
    } else {
        [e setBuffer:out offset:0 atIndex:0];
    }
    if (!strcmp(n, "t_struct")) {
        uint32_t pairs[64 * 8];
        gd_pairs(pairs);
        float scale = 1.5f;
        [e setBuffer:buffer(pairs, sizeof pairs) offset:0 atIndex:1];
        [e setBuffer:buffer(&scale, 4) offset:0 atIndex:2];
    }
    if (!strcmp(n, "t_tg_dynamic")) {
        [e setThreadgroupMemoryLength:256 atIndex:0];
        [e setThreadgroupMemoryLength:128 atIndex:1];
    }
    if (!strcmp(n, "t_atomic")) {
        uint32_t z[4] = {0};
        extra = buffer(z, 16);
        [e setBuffer:extra offset:0 atIndex:1];
    }
    if (!strcmp(n, "t_device_barrier")) {
        uint32_t z[256] = {0};
        [e setBuffer:buffer(z, sizeof z) offset:0 atIndex:1];
    }
    if (!strncmp(n, "t_tex_", 6) && strcmp(n, "t_tex_3d")) {
        float t0[16 * 16 * 4];
        gd_tex0(t0);
        [e setTexture:texture2d(MTLPixelFormatRGBA32Float, 16, 16, t0, 16 * 16, NO) atIndex:0];
    }
    if (!strcmp(n, "t_argbuf")) {
        // Argument buffer: texture resource ID, sampler resource ID, buffer GPU address.
        float t0[16 * 16 * 4];
        gd_tex0(t0);
        id<MTLTexture> t = texture2d(MTLPixelFormatRGBA32Float, 16, 16, t0, 16 * 16, NO);
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.supportArgumentBuffers = YES;
        id<MTLSamplerState> ss = [dev newSamplerStateWithDescriptor:sd];
        float data[256];
        gd_argbuf_data(data);
        id<MTLBuffer> db = buffer(data, sizeof data);
        uint64_t ab[3];
        MTLResourceID tid = t.gpuResourceID, sid = ss.gpuResourceID;
        memcpy(&ab[0], &tid, 8);
        memcpy(&ab[1], &sid, 8);
        ab[2] = db.gpuAddress;
        [e setBuffer:buffer(ab, sizeof ab) offset:0 atIndex:1];
        [e useResource:t usage:MTLResourceUsageRead];
        [e useResource:db usage:MTLResourceUsageRead];
    }
    if (!strcmp(n, "t_tex_rw") || !strcmp(n, "t_imageblock_slice")) {
        tex = texture2d(MTLPixelFormatRGBA32Float, 16, 16, NULL, 0, YES);
        [e setTexture:tex atIndex:1];
    }
    if (!strncmp(n, "t_imageblock", 12)) [e setImageblockWidth:tg.width height:tg.height];
    if (!strcmp(n, "t_tex_sample")) {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        [e setSamplerState:[dev newSamplerStateWithDescriptor:sd] atIndex:0];
    }
    if (!strcmp(n, "t_tex_uint")) {
        uint32_t t2[256];
        gd_tex2(t2);
        tex = texture2d(MTLPixelFormatR32Uint, 16, 16, t2, 16 * 4, YES);
        [e setTexture:tex atIndex:2];
    }
    if (!strcmp(n, "t_tex_3d")) {
        uint8_t t3[4 * 4 * 4 * 4];
        gd_tex3(t3);
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.textureType = MTLTextureType3D;
        d.pixelFormat = MTLPixelFormatRGBA8Unorm;
        d.width = d.height = d.depth = 4;
        d.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> t = [dev newTextureWithDescriptor:d];
        [t replaceRegion:MTLRegionMake3D(0, 0, 0, 4, 4, 4) mipmapLevel:0 slice:0 withBytes:t3 bytesPerRow:16 bytesPerImage:64];
        [e setTexture:t atIndex:3];
    }
    [e dispatchThreads:grid threadsPerThreadgroup:tg];
    [e endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.error) { fprintf(stderr, "%s: %s\n", n, cb.error.description.UTF8String); exit(1); }
    NSMutableData *res = [NSMutableData dataWithBytes:out.contents length:outBytes];
    if (extra) [res appendBytes:extra.contents length:extra.length];
    if (!strcmp(n, "t_tex_rw") || !strcmp(n, "t_imageblock_slice")) [res appendData:readTexture(tex, 16, 1)];
    if (!strcmp(n, "t_tex_uint")) [res appendData:readTexture(tex, 4, 1)];
    writeOut(outDir, name, res);
    printf("%s: %lu bytes\n", n, (unsigned long)res.length);
}

static void runRender(NSString *shaderDir, NSString *outDir, NSArray<NSString *> *f) {
    NSString *name = f[1];
    id<MTLLibrary> lib = library(shaderDir, f[2]);
    int w = f[5].intValue, h = f[6].intValue;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:f[3]];
    if ([name isEqual:@"draw_fconst"]) {
        MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
        bool useTint = true;
        int mode = 2;
        [cv setConstantValue:&useTint type:MTLDataTypeBool atIndex:0];
        [cv setConstantValue:&mode type:MTLDataTypeInt atIndex:1];
        NSError *ferr = nil;
        pd.fragmentFunction = [lib newFunctionWithName:f[4] constantValues:cv error:&ferr];
        if (!pd.fragmentFunction) { fprintf(stderr, "%s: %s\n", name.UTF8String, ferr.description.UTF8String); exit(1); }
    } else {
        pd.fragmentFunction = [lib newFunctionWithName:f[4]];
    }
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
    vd.attributes[0].format = MTLVertexFormatFloat2;
    vd.attributes[0].offset = 0;
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatHalf4;
    vd.attributes[1].offset = 8;
    vd.attributes[1].bufferIndex = 0;
    vd.layouts[0].stride = GD_VERTEX_STRIDE;
    pd.vertexDescriptor = vd;
    NSError *err = nil;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) { fprintf(stderr, "%s: %s\n", name.UTF8String, err.description.UTF8String); exit(1); }
    id<MTLTexture> target = texture2d(MTLPixelFormatRGBA8Unorm, w, h, NULL, 0, NO);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:ps];
    uint8_t verts[4 * GD_VERTEX_STRIDE];
    gd_vertices(verts);
    float xform[4] = {1.0f, 1.0f, 0.0f, 0.0f};
    [e setVertexBuffer:buffer(verts, sizeof verts) offset:0 atIndex:0];
    [e setVertexBuffer:buffer(xform, sizeof xform) offset:0 atIndex:1];
    uint8_t texel[8 * 8 * 4];
    gd_draw_texture(texel);
    [e setFragmentTexture:texture2d(MTLPixelFormatRGBA8Unorm, 8, 8, texel, 32, NO) atIndex:0];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    [e setFragmentSamplerState:[dev newSamplerStateWithDescriptor:sd] atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.error) { fprintf(stderr, "%s: %s\n", name.UTF8String, cb.error.description.UTF8String); exit(1); }
    writeOut(outDir, name, readTexture(target, 4, 1));
    printf("%s: %dx%d\n", name.UTF8String, w, h);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 4) { fprintf(stderr, "usage: mtl-oracle SHADER_DIR TESTS.txt OUT_DIR\n"); return 2; }
        dev = MTLCreateSystemDefaultDevice();
        queue = [dev newCommandQueue];
        libs = [NSMutableDictionary new];
        NSString *shaderDir = @(argv[1]), *outDir = @(argv[3]);
        NSString *list = [NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [list componentsSeparatedByString:@"\n"]) {
            if (line.length == 0 || [line hasPrefix:@"#"]) continue;
            NSMutableArray *f = [NSMutableArray new];
            for (NSString *t in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
                if (t.length) [f addObject:t];
            if (f.count < 12) continue;
            if ([f[0] isEqual:@"compute"]) runCompute(shaderDir, outDir, f);
            else runRender(shaderDir, outDir, f);
        }
    }
    return 0;
}
