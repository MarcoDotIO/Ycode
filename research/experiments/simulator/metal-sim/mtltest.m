/*
 * mtltest: our own Metal test program for the iOS simulator (original Ycode
 * code, R7). Written against the public Metal, IOSurface, and QuartzCore API.
 * Each test is a subcommand; several can be given in order. When run under
 * mslog.dylib, every test puts a marker into the recorder's log.
 *
 * Usage: mtltest <test> [<test> ...]
 *   info            device properties, families, limits, formats
 *   buffer          buffers in each storage mode, CPU write, no-copy buffer
 *   texture         textures (formats, storage modes, mipmaps), replace and get bytes
 *   clear           render pass that clears a 64x64 BGRA texture to (1,0,0,1), read back
 *   clear2          the same with (0,0.5,1,1) on 32x16 RGBA8 (field variation)
 *   triangle        source library, render pipeline, one draw, read back
 *   triangle2       the same pipeline, different vertex data and viewport
 *   compute         source library, compute pipeline, dispatch, read back
 *   fc              function constants and specialization
 *   blit            buffer and texture copies, fill, mipmap generation
 *   metallib <p>    library from a precompiled metallib file, compute dispatch
 *   iosurface       texture over an IOSurface, clear it, read the surface
 *   heap            heap, resources from it
 *   depth           depth-stencil state and a depth texture in a render pass
 *   sampler         sampler states
 *   event           shared event signal/wait, fence, completion handlers
 *   error           a source library with an error; a pipeline with a bad function
 *   layer           CAMetalLayer: next drawable, clear, present
 *   icb             indirect command buffer
 *   argbuf          argument buffer (argument encoder)
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <IOSurface/IOSurfaceObjC.h>
#include <xpc/xpc.h>
extern xpc_object_t IOSurfaceCreateXPCObject(IOSurfaceRef);
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>

static void (*g_mark)(const char *);
static void mark(NSString *s)
{
    printf("### %s\n", s.UTF8String);
    fflush(stdout);
    if (g_mark) g_mark(s.UTF8String);
}

static NSString *const kSrc =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut { float4 pos [[position]]; float4 color; };\n"
     "vertex VOut yc_vtx(uint vid [[vertex_id]], const device float4 *v [[buffer(0)]]) {\n"
     "  VOut o; o.pos = float4(v[vid].xy, 0.0, 1.0); o.color = float4(v[vid].z, v[vid].w, 0.25, 1.0); return o; }\n"
     "fragment float4 yc_frag(VOut in [[stage_in]]) { return in.color; }\n"
     "kernel void yc_add(const device float *a [[buffer(0)]], const device float *b [[buffer(1)]],\n"
     "                   device float *c [[buffer(2)]], uint i [[thread_position_in_grid]]) { c[i] = a[i] + b[i]; }\n"
     "constant int yc_k [[function_constant(0)]];\n"
     "constant bool yc_flag [[function_constant(1)]];\n"
     "kernel void yc_fc(device int *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = yc_flag ? yc_k + (int)i : -1; }\n"
     "kernel void yc_tex(texture2d<float, access::write> t [[texture(0)]], uint2 g [[thread_position_in_grid]]) {\n"
     "  t.write(float4(float(g.x) / 16.0, float(g.y) / 16.0, 0.5, 1.0), g); }\n"
     "struct YcArgs { device float *data [[id(0)]]; texture2d<float> tex [[id(1)]]; sampler s [[id(2)]]; };\n"
     "kernel void yc_arg(device YcArgs &args [[buffer(0)]], uint i [[thread_position_in_grid]]) { args.data[i] = args.data[i] * 2.0; }\n";

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLLibrary> srclib;

static id<MTLLibrary> lib(void)
{
    if (!srclib) {
        NSError *e = nil;
        mark(@"newLibraryWithSource");
        srclib = [dev newLibraryWithSource:kSrc options:nil error:&e];
        printf("library %p error %s\n", srclib, e.description.UTF8String ?: "-");
    }
    return srclib;
}

static void dumpPixels(const uint8_t *p, size_t bpr, int w, int h)
{
    int pts[][2] = { { 0, 0 }, { w / 2, h / 2 }, { w - 1, h - 1 }, { w / 4, h / 4 } };
    for (int i = 0; i < 4; i++) {
        const uint8_t *q = p + pts[i][1] * bpr + pts[i][0] * 4;
        printf("  pixel(%d,%d) = %02x %02x %02x %02x\n", pts[i][0], pts[i][1], q[0], q[1], q[2], q[3]);
    }
}

static void t_info(void)
{
    mark(@"info");
    printf("name %s registryID %llu unified %d\n", dev.name.UTF8String, dev.registryID, dev.hasUnifiedMemory);
    printf("maxThreadsPerThreadgroup %lu %lu %lu\n", dev.maxThreadsPerThreadgroup.width,
           dev.maxThreadsPerThreadgroup.height, dev.maxThreadsPerThreadgroup.depth);
    printf("maxThreadgroupMemoryLength %lu maxBufferLength %lu recommendedMaxWorkingSetSize %llu\n",
           dev.maxThreadgroupMemoryLength, dev.maxBufferLength, dev.recommendedMaxWorkingSetSize);
    printf("maxArgumentBufferSamplerCount %lu argumentBuffersSupport %lu readWriteTextureSupport %lu\n",
           dev.maxArgumentBufferSamplerCount, (unsigned long)dev.argumentBuffersSupport,
           (unsigned long)dev.readWriteTextureSupport);
    printf("rasterOrderGroups %d depth24Stencil8 %d raytracing %d functionPointers %d dynamicLibraries %d 32bitFloatFiltering %d 32bitMSAA %d BCTexture %d shaderBarycentric %d queryTextureLOD %d\n",
           dev.rasterOrderGroupsSupported, 0, dev.supportsRaytracing,
           dev.supportsFunctionPointers, dev.supportsDynamicLibraries, dev.supports32BitFloatFiltering,
           dev.supports32BitMSAA, dev.supportsBCTextureCompression, dev.supportsShaderBarycentricCoordinates,
           dev.supportsQueryTextureLOD);
    printf("currentAllocatedSize %lu sparseTileSizeInBytes %lu\n", dev.currentAllocatedSize,
           (unsigned long)dev.sparseTileSizeInBytes);
    MTLGPUFamily fams[] = { MTLGPUFamilyApple1, MTLGPUFamilyApple2, MTLGPUFamilyApple3, MTLGPUFamilyApple4,
                            MTLGPUFamilyApple5, MTLGPUFamilyApple6, MTLGPUFamilyApple7, MTLGPUFamilyApple8,
                            MTLGPUFamilyApple9, MTLGPUFamilyCommon1, MTLGPUFamilyCommon2,
                            MTLGPUFamilyCommon3, MTLGPUFamilyMetal3 };
    for (unsigned i = 0; i < sizeof fams / sizeof fams[0]; i++)
        printf("family %ld: %d\n", (long)fams[i], [dev supportsFamily:fams[i]]);
    for (int s = 1; s <= 8; s *= 2) printf("sampleCount %d: %d\n", s, [dev supportsTextureSampleCount:s]);
    printf("minimumLinearTextureAlignment(BGRA8) %lu minimumTextureBufferAlignment %lu\n",
           [dev minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGRA8Unorm],
           [dev minimumTextureBufferAlignmentForPixelFormat:MTLPixelFormatBGRA8Unorm]);
    MTLSizeAndAlign sa = [dev heapBufferSizeAndAlignWithLength:1000 options:0];
    printf("heapBufferSizeAndAlign(1000) %lu %lu\n", sa.size, sa.align);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:256 height:256 mipmapped:YES];
    sa = [dev heapTextureSizeAndAlignWithDescriptor:td];
    printf("heapTextureSizeAndAlign(256x256 mip BGRA) %lu %lu\n", sa.size, sa.align);
    printf("counterSets %lu\n", (unsigned long)dev.counterSets.count);
    printf("supportsVertexAmplificationCount 2: %d\n", [dev supportsVertexAmplificationCount:2]);
}

static void t_buffer(void)
{
    mark(@"buffer shared 4096");
    id<MTLBuffer> b1 = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    memset(b1.contents, 0xab, 4096);
    printf("b1 %p contents %p gpuAddress 0x%llx\n", b1, b1.contents, b1.gpuAddress);
    mark(@"buffer private 8192");
    id<MTLBuffer> b2 = [dev newBufferWithLength:8192 options:MTLResourceStorageModePrivate];
    printf("b2 %p gpuAddress 0x%llx\n", b2, b2.gpuAddress);
    mark(@"buffer bytes 100");
    uint8_t bytes[100];
    for (int i = 0; i < 100; i++) bytes[i] = (uint8_t)i;
    id<MTLBuffer> b3 = [dev newBufferWithBytes:bytes length:100 options:MTLResourceStorageModeShared];
    printf("b3 %p len %lu\n", b3, b3.length);
    mark(@"buffer nocopy 16384");
    void *mem = NULL;
    posix_memalign(&mem, 16384, 16384);
    memset(mem, 0x5a, 16384);
    id<MTLBuffer> b4 = [dev newBufferWithBytesNoCopy:mem length:16384 options:MTLResourceStorageModeShared
                                         deallocator:nil];
    printf("b4 %p contents %p (mem %p)\n", b4, b4.contents, mem);
    mark(@"buffer shared 1MiB writecombined");
    id<MTLBuffer> b5 = [dev newBufferWithLength:1 << 20
                                        options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
    printf("b5 %p\n", b5);
    mark(@"buffer label + release");
    b1.label = @"yc-label-b1";
    b1 = nil; b2 = nil; b3 = nil; b4 = nil; b5 = nil;
    mark(@"buffer end");
}

static void t_texture(void)
{
    MTLPixelFormat fmts[] = { MTLPixelFormatBGRA8Unorm, MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA16Float,
                              MTLPixelFormatR8Unorm, MTLPixelFormatDepth32Float, MTLPixelFormatBGRA8Unorm_sRGB };
    for (unsigned i = 0; i < sizeof fmts / sizeof fmts[0]; i++) {
        mark([NSString stringWithFormat:@"texture fmt %lu 128x64 private", (unsigned long)fmts[i]]);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmts[i] width:128
                                                                                      height:64 mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        printf("texture %p fmt %lu\n", t, (unsigned long)fmts[i]);
    }
    mark(@"texture shared 16x8 BGRA mipmapped, replaceRegion, getBytes");
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:16 height:8 mipmapped:YES];
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    uint32_t px[16 * 8];
    for (int i = 0; i < 16 * 8; i++) px[i] = 0xff000000u | (uint32_t)i * 0x010203u;
    mark(@"replaceRegion");
    [t replaceRegion:MTLRegionMake2D(0, 0, 16, 8) mipmapLevel:0 withBytes:px bytesPerRow:64];
    uint32_t back[16 * 8] = { 0 };
    mark(@"getBytes");
    [t getBytes:back bytesPerRow:64 fromRegion:MTLRegionMake2D(0, 0, 16, 8) mipmapLevel:0];
    printf("getBytes match %d (back[5]=%08x)\n", !memcmp(px, back, sizeof px), back[5]);
    mark(@"texture view");
    id<MTLTexture> v = [t newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB];
    printf("view %p\n", v);
    mark(@"texture 3D, cube, array, msaa");
    MTLTextureDescriptor *d3 = [MTLTextureDescriptor new];
    d3.textureType = MTLTextureType3D; d3.width = 8; d3.height = 8; d3.depth = 4;
    d3.pixelFormat = MTLPixelFormatRGBA8Unorm; d3.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t3 = [dev newTextureWithDescriptor:d3];
    MTLTextureDescriptor *dc = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                     size:16 mipmapped:NO];
    dc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> tc = [dev newTextureWithDescriptor:dc];
    MTLTextureDescriptor *dm = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:32 height:32 mipmapped:NO];
    dm.textureType = MTLTextureType2DMultisample; dm.sampleCount = 4; dm.storageMode = MTLStorageModePrivate;
    dm.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> tm = [dev newTextureWithDescriptor:dm];
    printf("3d %p cube %p msaa %p\n", t3, tc, tm);
    mark(@"texture from buffer");
    id<MTLBuffer> b = [dev newBufferWithLength:256 * 16 options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *db = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:16 height:16 mipmapped:NO];
    db.storageMode = MTLStorageModeShared;
    id<MTLTexture> tb = [b newTextureWithDescriptor:db offset:0 bytesPerRow:256];
    printf("buffer texture %p\n", tb);
    mark(@"texture end");
}

static id<MTLTexture> rt(MTLPixelFormat f, int w, int h)
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h
                                                                              mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [dev newTextureWithDescriptor:td];
}

static void readback(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLBuffer> *out)
{
    size_t bpr = t.width * 4;
    *out = [dev newBufferWithLength:bpr * t.height options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:*out destinationOffset:0
        destinationBytesPerRow:bpr destinationBytesPerImage:bpr * t.height];
    [be endEncoding];
}

static void clearTest(MTLPixelFormat f, int w, int h, MTLClearColor c, NSString *name)
{
    mark([NSString stringWithFormat:@"%@: make texture", name]);
    id<MTLTexture> t = rt(f, w, h);
    mark([NSString stringWithFormat:@"%@: command buffer", name]);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    cb.label = name;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = c;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re endEncoding];
    id<MTLBuffer> out;
    readback(cb, t, &out);
    mark([NSString stringWithFormat:@"%@: commit", name]);
    [cb commit];
    [cb waitUntilCompleted];
    mark([NSString stringWithFormat:@"%@: completed status %ld", name, (long)cb.status]);
    dumpPixels(out.contents, w * 4, w, h);
}

static id<MTLRenderPipelineState> trianglePipeline(void)
{
    static id<MTLRenderPipelineState> ps;
    if (ps) return ps;
    mark(@"newFunctionWithName yc_vtx/yc_frag");
    id<MTLFunction> vf = [lib() newFunctionWithName:@"yc_vtx"];
    id<MTLFunction> ff = [lib() newFunctionWithName:@"yc_frag"];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = vf;
    pd.fragmentFunction = ff;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.label = @"yc-tri-pipeline";
    NSError *e = nil;
    MTLAutoreleasedRenderPipelineReflection refl = nil;
    mark(@"newRenderPipelineState");
    ps = [dev newRenderPipelineStateWithDescriptor:pd options:MTLPipelineOptionArgumentInfo | MTLPipelineOptionBufferTypeInfo
                                        reflection:&refl error:&e];
    printf("pipeline %p error %s reflection %s\n", ps, e.description.UTF8String ?: "-",
           refl.description.UTF8String ?: "-");
    return ps;
}

static void triangleTest(const float *verts, MTLViewport vp, NSString *name)
{
    id<MTLRenderPipelineState> ps = trianglePipeline();
    id<MTLTexture> t = rt(MTLPixelFormatBGRA8Unorm, 64, 64);
    mark([NSString stringWithFormat:@"%@: encode", name]);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:ps];
    [re setViewport:vp];
    [re setVertexBytes:verts length:3 * 4 * sizeof(float) atIndex:0];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];
    id<MTLBuffer> out;
    readback(cb, t, &out);
    mark([NSString stringWithFormat:@"%@: commit", name]);
    [cb commit];
    [cb waitUntilCompleted];
    mark([NSString stringWithFormat:@"%@: completed status %ld", name, (long)cb.status]);
    dumpPixels(out.contents, 256, 64, 64);
}

static void computeWith(id<MTLLibrary> l, NSString *name, int n)
{
    mark([NSString stringWithFormat:@"%@: function + pipeline", name]);
    id<MTLFunction> f = [l newFunctionWithName:@"yc_add"];
    NSError *e = nil;
    MTLAutoreleasedComputePipelineReflection refl = nil;
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:f options:MTLPipelineOptionArgumentInfo
                                                                   reflection:&refl error:&e];
    printf("compute pipeline %p maxTotalThreadsPerThreadgroup %lu threadExecutionWidth %lu error %s\n", ps,
           ps.maxTotalThreadsPerThreadgroup, ps.threadExecutionWidth, e.description.UTF8String ?: "-");
    id<MTLBuffer> a = [dev newBufferWithLength:n * 4 options:0], b = [dev newBufferWithLength:n * 4 options:0],
                  c = [dev newBufferWithLength:n * 4 options:0];
    float *pa = a.contents, *pb = b.contents;
    for (int i = 0; i < n; i++) { pa[i] = (float)i; pb[i] = 1000.0f; }
    mark([NSString stringWithFormat:@"%@: encode", name]);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setBuffer:a offset:0 atIndex:0];
    [ce setBuffer:b offset:0 atIndex:1];
    [ce setBuffer:c offset:0 atIndex:2];
    [ce dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
    [ce endEncoding];
    mark([NSString stringWithFormat:@"%@: commit", name]);
    [cb commit];
    [cb waitUntilCompleted];
    float *pc = c.contents;
    mark([NSString stringWithFormat:@"%@: completed status %ld c[0]=%g c[%d]=%g", name, (long)cb.status, pc[0],
                                    n - 1, pc[n - 1]]);
}

static void t_fc(void)
{
    mark(@"fc: constants");
    MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
    int k = 7000;
    bool flag = true;
    [cv setConstantValue:&k type:MTLDataTypeInt atIndex:0];
    [cv setConstantValue:&flag type:MTLDataTypeBool atIndex:1];
    NSError *e = nil;
    id<MTLFunction> f = [lib() newFunctionWithName:@"yc_fc" constantValues:cv error:&e];
    printf("specialized %p error %s\n", f, e.description.UTF8String ?: "-");
    mark(@"fc: pipeline");
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:f error:&e];
    id<MTLBuffer> o = [dev newBufferWithLength:64 * 4 options:0];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setBuffer:o offset:0 atIndex:0];
    [ce dispatchThreadgroups:MTLSizeMake(2, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
    [ce endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    int *po = o.contents;
    mark([NSString stringWithFormat:@"fc: done o[0]=%d o[63]=%d", po[0], po[63]]);
}

static void t_blit(void)
{
    mark(@"blit: setup");
    id<MTLBuffer> src = [dev newBufferWithLength:4096 options:0], dst = [dev newBufferWithLength:4096 options:0];
    memset(src.contents, 0x11, 4096);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:32 height:32 mipmapped:YES];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> t1 = [dev newTextureWithDescriptor:td], t2 = [dev newTextureWithDescriptor:td];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    mark(@"blit: encode");
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromBuffer:src sourceOffset:16 toBuffer:dst destinationOffset:32 size:1024];
    [be fillBuffer:dst range:NSMakeRange(2048, 512) value:0x77];
    [be copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:128 sourceBytesPerImage:4096 sourceSize:MTLSizeMake(32, 32, 1)
             toTexture:t1 destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [be generateMipmapsForTexture:t1];
    [be copyFromTexture:t1 toTexture:t2];
    [be copyFromTexture:t2 sourceSlice:0 sourceLevel:1 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(16, 16, 1)
               toBuffer:dst destinationOffset:3072 destinationBytesPerRow:64 destinationBytesPerImage:1024];
    [be endEncoding];
    mark(@"blit: commit");
    [cb commit];
    [cb waitUntilCompleted];
    uint8_t *d = dst.contents;
    mark([NSString stringWithFormat:@"blit: done status %ld d[32]=%02x d[2048]=%02x d[3072]=%02x", (long)cb.status,
                                    d[32], d[2048], d[3072]]);
}

static void t_metallib(const char *path)
{
    mark(@"metallib: newLibraryWithURL");
    NSError *e = nil;
    id<MTLLibrary> l = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(path)] error:&e];
    printf("metallib library %p error %s functions %s\n", l, e.description.UTF8String ?: "-",
           l.functionNames.description.UTF8String);
    if (l) computeWith(l, @"metallib compute", 64);
    mark(@"metallib: newLibraryWithData");
    NSData *d = [NSData dataWithContentsOfFile:@(path)];
    dispatch_data_t dd = dispatch_data_create(d.bytes, d.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    id<MTLLibrary> l2 = [dev newLibraryWithData:dd error:&e];
    printf("data library %p\n", l2);
}

static void t_iosurface(void)
{
    mark(@"iosurface: create surface");
    NSDictionary *props = @{ (id)kIOSurfaceWidth: @64, (id)kIOSurfaceHeight: @32, (id)kIOSurfaceBytesPerElement: @4,
                             (id)kIOSurfacePixelFormat: @(0x42475241) };
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    printf("surface %p id %u bpr %zu\n", s, IOSurfaceGetID(s), IOSurfaceGetBytesPerRow(s));
    {
        xpc_object_t x = IOSurfaceCreateXPCObject(s);
        char *d = x ? xpc_copy_description(x) : NULL;
        printf("IOSurfaceCreateXPCObject -> %s\n", d ? d : "NULL");
        free(d);
    }
    mark(@"iosurface: newTextureWithDescriptor:iosurface:plane:");
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:64 height:32 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td iosurface:s plane:0];
    printf("texture %p\n", t);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1);
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    mark(@"iosurface: commit");
    [cb commit];
    [cb waitUntilCompleted];
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    mark(@"iosurface: done, surface pixels:");
    dumpPixels(IOSurfaceGetBaseAddress(s), IOSurfaceGetBytesPerRow(s), 64, 32);
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    mark(@"iosurface: compute writes it");
    id<MTLFunction> f = [lib() newFunctionWithName:@"yc_tex"];
    NSError *e = nil;
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:f error:&e];
    MTLTextureDescriptor *td2 = [td copy];
    td2.usage = MTLTextureUsageShaderWrite;
    id<MTLTexture> tw = [dev newTextureWithDescriptor:td2 iosurface:s plane:0];
    cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setTexture:tw atIndex:0];
    [ce dispatchThreads:MTLSizeMake(64, 32, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [ce endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    mark(@"iosurface: compute done");
    dumpPixels(IOSurfaceGetBaseAddress(s), IOSurfaceGetBytesPerRow(s), 64, 32);
    CFRelease(s);
}

static void t_heap(void)
{
    mark(@"heap: create");
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
    hd.size = 1 << 20;
    hd.storageMode = MTLStorageModePrivate;
    id<MTLHeap> h = [dev newHeapWithDescriptor:hd];
    printf("heap %p size %lu\n", h, h.size);
    mark(@"heap: buffer + texture");
    id<MTLBuffer> b = [h newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:64 height:64 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [h newTextureWithDescriptor:td];
    printf("heap buffer %p texture %p used %lu\n", b, t, h.usedSize);
    mark(@"heap: shared heap");
    hd.storageMode = MTLStorageModeShared;
    hd.size = 65536;
    id<MTLHeap> h2 = [dev newHeapWithDescriptor:hd];
    id<MTLBuffer> b2 = [h2 newBufferWithLength:1000 options:MTLResourceStorageModeShared];
    printf("shared heap %p buffer %p contents %p\n", h2, b2, b2.contents);
}

static void t_depth(void)
{
    mark(@"depth: state");
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionLess;
    dd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> ds = [dev newDepthStencilStateWithDescriptor:dd];
    mark(@"depth: pass");
    id<MTLRenderPipelineState> ps = nil;
    {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib() newFunctionWithName:@"yc_vtx"];
        pd.fragmentFunction = [lib() newFunctionWithName:@"yc_frag"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        NSError *e = nil;
        ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    }
    id<MTLTexture> c = rt(MTLPixelFormatBGRA8Unorm, 32, 32);
    id<MTLTexture> d = rt(MTLPixelFormatDepth32Float, 32, 32);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = c;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.depthAttachment.texture = d;
    rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.clearDepth = 0.75;
    rp.depthAttachment.storeAction = MTLStoreActionDontCare;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:ps];
    [re setDepthStencilState:ds];
    [re setCullMode:MTLCullModeBack];
    [re setFrontFacingWinding:MTLWindingCounterClockwise];
    [re setScissorRect:(MTLScissorRect){ 2, 2, 28, 28 }];
    float v[12] = { -1, -1, 1, 0, 3, -1, 0, 1, -1, 3, 1, 1 };
    [re setVertexBytes:v length:sizeof v atIndex:0];
    [re setBlendColorRed:0.1 green:0.2 blue:0.3 alpha:0.4];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:2];
    uint16_t idx[3] = { 0, 1, 2 };
    id<MTLBuffer> ib = [dev newBufferWithBytes:idx length:sizeof idx options:0];
    [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:3 indexType:MTLIndexTypeUInt16 indexBuffer:ib
            indexBufferOffset:0];
    [re endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    mark([NSString stringWithFormat:@"depth: done status %ld", (long)cb.status]);
}

static void t_sampler(void)
{
    mark(@"sampler");
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterNearest;
    sd.mipFilter = MTLSamplerMipFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeRepeat;
    sd.tAddressMode = MTLSamplerAddressModeMirrorRepeat;
    sd.maxAnisotropy = 4;
    sd.lodMaxClamp = 7.5;
    sd.supportArgumentBuffers = YES;
    id<MTLSamplerState> s = [dev newSamplerStateWithDescriptor:sd];
    printf("sampler %p gpuResourceID %llu\n", s, s.gpuResourceID._impl);
}

static void t_event(void)
{
    mark(@"event: shared event");
    id<MTLSharedEvent> ev = [dev newSharedEvent];
    id<MTLEvent> e2 = [dev newEvent];
    id<MTLFence> fence = [dev newFence];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    __block int done = 0;
    [cb addScheduledHandler:^(id<MTLCommandBuffer> b) { printf("scheduled\n"); }];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> b) { done = 1; printf("completed handler\n"); }];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    id<MTLBuffer> b = [dev newBufferWithLength:1024 options:0];
    [be fillBuffer:b range:NSMakeRange(0, 1024) value:1];
    [be updateFence:fence];
    [be endEncoding];
    be = [cb blitCommandEncoder];
    [be waitForFence:fence];
    [be fillBuffer:b range:NSMakeRange(0, 512) value:2];
    [be endEncoding];
    [cb encodeSignalEvent:ev value:5];
    [cb encodeSignalEvent:e2 value:3];
    [cb encodeWaitForEvent:e2 value:3];
    mark(@"event: commit");
    [cb commit];
    [cb waitUntilCompleted];
    mark([NSString stringWithFormat:@"event: done status %ld signaled %llu handler %d", (long)cb.status,
                                    ev.signaledValue, done]);
    mark(@"event: CPU signal");
    ev.signaledValue = 9;
    printf("signaled now %llu\n", ev.signaledValue);
    mark(@"event: GPU wait for CPU signal 10");
    id<MTLCommandBuffer> cb2 = [queue commandBuffer];
    [cb2 encodeWaitForEvent:ev value:10];
    [cb2 commit];
    usleep(200000);
    mark([NSString stringWithFormat:@"event: before CPU signal status %ld", (long)cb2.status]);
    ev.signaledValue = 10;
    [cb2 waitUntilCompleted];
    mark([NSString stringWithFormat:@"event: after status %ld", (long)cb2.status]);
}

static void t_error(void)
{
    mark(@"error: bad source");
    NSError *e = nil;
    id<MTLLibrary> l = [dev newLibraryWithSource:@"kernel void broken(device float *x [[buffer(0)]]) { x[0] = y; }"
                                         options:nil error:&e];
    printf("library %p error %s\n", l, e.description.UTF8String ?: "-");
    mark(@"error: warning source");
    MTLCompileOptions *o = [MTLCompileOptions new];
    o.fastMathEnabled = NO;
    o.languageVersion = MTLLanguageVersion3_0;
    o.preprocessorMacros = @{ @"YC_MACRO": @"42" };
    l = [dev newLibraryWithSource:@"kernel void warn(device int *x [[buffer(0)]]) { int unused; x[0] = YC_MACRO; }"
                          options:o error:&e];
    printf("library %p error %s\n", l, e.description.UTF8String ?: "-");
    mark(@"error: missing function");
    id<MTLFunction> f = [lib() newFunctionWithName:@"does_not_exist"];
    printf("function %p\n", f);
    mark(@"error: command buffer fault (out-of-range is not checked; skip)");
}

static void t_layer(void)
{
    mark(@"layer: CAMetalLayer");
    CAMetalLayer *ml = [CAMetalLayer layer];
    ml.device = dev;
    ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
    ml.drawableSize = CGSizeMake(64, 64);
    ml.framebufferOnly = NO;
    for (int i = 0; i < 3; i++) {
        mark([NSString stringWithFormat:@"layer: nextDrawable %d", i]);
        id<CAMetalDrawable> d = [ml nextDrawable];
        printf("drawable %p texture %p iosurface %p\n", d, d.texture, d.texture.iosurface);
        if (!d) break;
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = d.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.2 * i, 0.4, 0.6, 1);
        [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        [cb presentDrawable:d];
        mark([NSString stringWithFormat:@"layer: commit %d", i]);
        [cb commit];
        [cb waitUntilCompleted];
    }
    [CATransaction flush];
    mark(@"layer: end");
}

static void t_icb(void)
{
    mark(@"icb: create");
    MTLIndirectCommandBufferDescriptor *d = [MTLIndirectCommandBufferDescriptor new];
    d.commandTypes = MTLIndirectCommandTypeConcurrentDispatch;
    d.inheritBuffers = NO;
    d.maxKernelBufferBindCount = 3;
    d.inheritPipelineState = NO;
    id<MTLIndirectCommandBuffer> icb = [dev newIndirectCommandBufferWithDescriptor:d maxCommandCount:4 options:0];
    printf("icb %p size %lu\n", icb, icb.size);
}

static void t_argbuf(void)
{
    mark(@"argbuf: encoder");
    id<MTLFunction> f = [lib() newFunctionWithName:@"yc_arg"];
    id<MTLArgumentEncoder> ae = [f newArgumentEncoderWithBufferIndex:0];
    printf("argument encoder %p encodedLength %lu alignment %lu\n", ae, ae.encodedLength, ae.alignment);
    id<MTLBuffer> ab = [dev newBufferWithLength:ae.encodedLength options:0];
    id<MTLBuffer> data = [dev newBufferWithLength:256 options:0];
    float *pd = data.contents;
    for (int i = 0; i < 64; i++) pd[i] = (float)i;
    [ae setArgumentBuffer:ab offset:0];
    [ae setBuffer:data offset:0 atIndex:0];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:4 height:4 mipmapped:NO];
    [ae setTexture:[dev newTextureWithDescriptor:td] atIndex:1];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.supportArgumentBuffers = YES;
    [ae setSamplerState:[dev newSamplerStateWithDescriptor:sd] atIndex:2];
    printf("argument buffer bytes:");
    for (unsigned i = 0; i < ae.encodedLength; i++) printf(" %02x", ((uint8_t *)ab.contents)[i]);
    printf("\ndata gpuAddress 0x%llx\n", data.gpuAddress);
    NSError *e = nil;
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:f error:&e];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setBuffer:ab offset:0 atIndex:0];
    [ce useResource:data usage:MTLResourceUsageRead | MTLResourceUsageWrite];
    [ce dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
    [ce endEncoding];
    mark(@"argbuf: commit");
    [cb commit];
    [cb waitUntilCompleted];
    mark([NSString stringWithFormat:@"argbuf: done status %ld data[3]=%g", (long)cb.status, pd[3]]);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        g_mark = (void (*)(const char *))dlsym(RTLD_DEFAULT, "mslog_mark");
        mark(@"MTLCreateSystemDefaultDevice");
        dev = MTLCreateSystemDefaultDevice();
        printf("device %p %s class %s\n", dev, dev.name.UTF8String, NSStringFromClass([(id)dev class]).UTF8String);
        if (!dev) return 1;
        mark(@"newCommandQueue");
        queue = [dev newCommandQueue];
        for (int a = 1; a < argc; a++) {
            NSString *t = @(argv[a]);
            if ([t isEqual:@"info"]) t_info();
            else if ([t isEqual:@"buffer"]) t_buffer();
            else if ([t isEqual:@"texture"]) t_texture();
            else if ([t isEqual:@"clear"]) clearTest(MTLPixelFormatBGRA8Unorm, 64, 64, MTLClearColorMake(1, 0, 0, 1), @"clear");
            else if ([t isEqual:@"clear2"]) clearTest(MTLPixelFormatRGBA8Unorm, 32, 16, MTLClearColorMake(0, 0.5, 1, 1), @"clear2");
            else if ([t isEqual:@"triangle"]) {
                float v[12] = { -1, -1, 1, 0, 1, -1, 0, 1, 0, 1, 1, 1 };
                triangleTest(v, (MTLViewport){ 0, 0, 64, 64, 0, 1 }, @"triangle");
            } else if ([t isEqual:@"triangle2"]) {
                float v[12] = { -0.5, -0.5, 0.25, 0.5, 0.5, -0.5, 0.75, 0.5, 0, 0.5, 0.5, 0.5 };
                triangleTest(v, (MTLViewport){ 8, 4, 32, 48, 0.25, 0.75 }, @"triangle2");
            } else if ([t isEqual:@"compute"]) computeWith(lib(), @"compute", 256);
            else if ([t isEqual:@"compute2"]) computeWith(lib(), @"compute2", 96);
            else if ([t isEqual:@"fc"]) t_fc();
            else if ([t isEqual:@"blit"]) t_blit();
            else if ([t isEqual:@"metallib"] && a + 1 < argc) t_metallib(argv[++a]);
            else if ([t isEqual:@"iosurface"]) t_iosurface();
            else if ([t isEqual:@"heap"]) t_heap();
            else if ([t isEqual:@"depth"]) t_depth();
            else if ([t isEqual:@"sampler"]) t_sampler();
            else if ([t isEqual:@"event"]) t_event();
            else if ([t isEqual:@"error"]) t_error();
            else if ([t isEqual:@"layer"]) t_layer();
            else if ([t isEqual:@"icb"]) t_icb();
            else if ([t isEqual:@"argbuf"]) t_argbuf();
            else printf("unknown test %s\n", argv[a]);
        }
        mark(@"exit");
    }
    return 0;
}
