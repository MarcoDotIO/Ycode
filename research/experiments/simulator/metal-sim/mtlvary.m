/*
 * mtlvary: field-separation runs for the R7 probe (original Ycode code).
 * Public Metal API only. Each subcommand encodes calls with distinctive
 * argument values; in render encoders every call is preceded by a separator
 * (setBlendColorRed:<n> green:0 blue:0 alpha:0), in blit encoders by
 * fillBuffer:<sep> range:{n,1} value:0xEE, so that records can be matched to
 * calls. The list of calls is printed to stdout in order.
 *
 * Usage: mtlvary <test> [...]
 *   render      render-encoder call matrix
 *   rp <n>      render pass descriptor variant n (0..7)
 *   compute     compute-encoder call matrix
 *   blit        blit-encoder call matrix
 *   pso <n>     render pipeline descriptor variant n (0..7)
 *   tex         texture descriptor variants
 *   sampler     sampler descriptor variants
 *   ds          depth-stencil descriptor variants
 *   big         one render encoder with more than 64 KiB of commands
 *   many        20 command buffers in flight
 *   bytes       setVertexBytes / setFragmentBytes sizes
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
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
     "struct VIn { float4 p [[attribute(0)]]; float2 uv [[attribute(1)]]; };\n"
     "struct VOut { float4 pos [[position]]; float4 color; };\n"
     "vertex VOut yc_vtx(uint vid [[vertex_id]], const device float4 *v [[buffer(0)]]) {\n"
     "  VOut o; o.pos = float4(v[vid].xy, 0.0, 1.0); o.color = float4(v[vid].z, v[vid].w, 0.25, 1.0); return o; }\n"
     "vertex VOut yc_vtx2(VIn in [[stage_in]]) { VOut o; o.pos = in.p; o.color = float4(in.uv, 0, 1); return o; }\n"
     "fragment float4 yc_frag(VOut in [[stage_in]]) { return in.color; }\n"
     "fragment float4 yc_ftex(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],\n"
     "                        constant float4 &k [[buffer(0)]]) { return t.sample(s, in.color.xy) * k; }\n"
     "struct MOut { float4 a [[color(0)]]; float4 b [[color(1)]]; };\n"
     "fragment MOut yc_fmrt(VOut in [[stage_in]]) { MOut o; o.a = in.color; o.b = in.color.yxzw; return o; }\n"
     "kernel void yc_add(const device float *a [[buffer(0)]], const device float *b [[buffer(1)]],\n"
     "                   device float *c [[buffer(2)]], uint i [[thread_position_in_grid]]) { c[i] = a[i] + b[i]; }\n"
     "kernel void yc_tex(texture2d<float, access::write> t [[texture(0)]], uint2 g [[thread_position_in_grid]]) {\n"
     "  t.write(float4(0.5), g); }\n"
     "kernel void yc_tg(device float *c [[buffer(0)]], threadgroup float *tg [[threadgroup(0)]], uint i [[thread_position_in_grid]]) { tg[0] = 1; c[i] = tg[0]; }\n";

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLLibrary> lib;

static id<MTLTexture> tex2d(MTLPixelFormat f, int w, int h, MTLTextureUsage u, MTLStorageMode sm)
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    td.usage = u;
    td.storageMode = sm;
    return [dev newTextureWithDescriptor:td];
}

static id<MTLRenderPipelineState> pso(NSString *vf, NSString *ff, MTLPixelFormat cf, MTLPixelFormat df)
{
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:vf];
    pd.fragmentFunction = [lib newFunctionWithName:ff];
    pd.colorAttachments[0].pixelFormat = cf;
    pd.depthAttachmentPixelFormat = df;
    NSError *e = nil;
    id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!p) printf("pso error %s\n", e.description.UTF8String);
    return p;
}

static int g_sep;
static void sep(id<MTLRenderCommandEncoder> re, const char *what)
{
    g_sep++;
    printf("sep %d (blend red %g): %s\n", g_sep, (double)g_sep, what);
    [re setBlendColorRed:(float)g_sep green:0 blue:0 alpha:0];
}

static void commitWait(id<MTLCommandBuffer> cb, NSString *name)
{
    mark([NSString stringWithFormat:@"%@: commit", name]);
    [cb commit];
    [cb waitUntilCompleted];
    mark([NSString stringWithFormat:@"%@: status %ld", name, (long)cb.status]);
}

static void t_render(void)
{
    id<MTLRenderPipelineState> p1 = pso(@"yc_vtx", @"yc_frag", MTLPixelFormatBGRA8Unorm, MTLPixelFormatDepth32Float);
    id<MTLRenderPipelineState> p2 = pso(@"yc_vtx", @"yc_ftex", MTLPixelFormatBGRA8Unorm, MTLPixelFormatDepth32Float);
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionLessEqual;
    id<MTLDepthStencilState> ds = [dev newDepthStencilStateWithDescriptor:dd];
    id<MTLTexture> c = tex2d(MTLPixelFormatBGRA8Unorm, 64, 64, MTLTextureUsageRenderTarget, MTLStorageModePrivate);
    id<MTLTexture> d = tex2d(MTLPixelFormatDepth32Float, 64, 64, MTLTextureUsageRenderTarget, MTLStorageModePrivate);
    id<MTLTexture> t = tex2d(MTLPixelFormatRGBA8Unorm, 8, 8, MTLTextureUsageShaderRead, MTLStorageModePrivate);
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    id<MTLSamplerState> ss = [dev newSamplerStateWithDescriptor:sd];
    id<MTLBuffer> vb = [dev newBufferWithLength:0x10000 options:MTLResourceStorageModeShared];
    id<MTLBuffer> ib = [dev newBufferWithLength:0x10000 options:MTLResourceStorageModeShared];
    id<MTLBuffer> indirect = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    printf("refs created in order: p1 p2 ds c d t ss vb ib indirect\n");
    mark(@"render: encode");
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = c;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.depthAttachment.texture = d;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    sep(re, "setRenderPipelineState p1"); [re setRenderPipelineState:p1];
    sep(re, "setRenderPipelineState p2"); [re setRenderPipelineState:p2];
    sep(re, "setDepthStencilState ds"); [re setDepthStencilState:ds];
    sep(re, "setViewport 1.5 2.5 30 40 0.125 0.875"); [re setViewport:(MTLViewport){ 1.5, 2.5, 30, 40, 0.125, 0.875 }];
    sep(re, "setScissorRect 3 4 50 60"); [re setScissorRect:(MTLScissorRect){ 3, 4, 50, 60 }];
    sep(re, "setCullMode Front(1)"); [re setCullMode:MTLCullModeFront];
    sep(re, "setCullMode Back(2)"); [re setCullMode:MTLCullModeBack];
    sep(re, "setFrontFacingWinding CCW(1)"); [re setFrontFacingWinding:MTLWindingCounterClockwise];
    sep(re, "setTriangleFillMode Lines(1)"); [re setTriangleFillMode:MTLTriangleFillModeLines];
    sep(re, "setDepthBias 0.5 slope 1.5 clamp 2.5"); [re setDepthBias:0.5 slopeScale:1.5 clamp:2.5];
    sep(re, "setDepthClipMode Clamp(1)"); [re setDepthClipMode:MTLDepthClipModeClamp];
    sep(re, "setStencilReferenceValue 0x5a"); [re setStencilReferenceValue:0x5a];
    sep(re, "setStencilFront 0x11 back 0x22"); [re setStencilFrontReferenceValue:0x11 backReferenceValue:0x22];
    sep(re, "setBlendColor 0.25 0.5 0.75 1"); [re setBlendColorRed:0.25 green:0.5 blue:0.75 alpha:1];
    sep(re, "setVertexBuffer vb off 0x1230 idx 5"); [re setVertexBuffer:vb offset:0x1230 atIndex:5];
    sep(re, "setVertexBufferOffset 0x2340 idx 5"); [re setVertexBufferOffset:0x2340 atIndex:5];
    sep(re, "setVertexBuffer vb off 0 idx 0"); [re setVertexBuffer:vb offset:0 atIndex:0];
    sep(re, "setVertexBuffer nil idx 6"); [re setVertexBuffer:nil offset:0 atIndex:6];
    float k16[4] = { 1, 2, 3, 4 };
    sep(re, "setVertexBytes 16 idx 7"); [re setVertexBytes:k16 length:16 atIndex:7];
    sep(re, "setFragmentBuffer vb off 0x450 idx 3"); [re setFragmentBuffer:vb offset:0x450 atIndex:3];
    sep(re, "setFragmentBufferOffset 0x560 idx 3"); [re setFragmentBufferOffset:0x560 atIndex:3];
    sep(re, "setFragmentBytes 16 idx 0"); [re setFragmentBytes:k16 length:16 atIndex:0];
    sep(re, "setVertexTexture t idx 2"); [re setVertexTexture:t atIndex:2];
    sep(re, "setFragmentTexture t idx 4"); [re setFragmentTexture:t atIndex:4];
    sep(re, "setFragmentTexture nil idx 1"); [re setFragmentTexture:nil atIndex:1];
    sep(re, "setVertexSamplerState ss idx 3"); [re setVertexSamplerState:ss atIndex:3];
    sep(re, "setFragmentSamplerState ss idx 5"); [re setFragmentSamplerState:ss atIndex:5];
    sep(re, "setFragmentSamplerState ss lod 0.5..3.5 idx 6"); [re setFragmentSamplerState:ss lodMinClamp:0.5 lodMaxClamp:3.5 atIndex:6];
    sep(re, "setRenderPipelineState p1 (for draws)"); [re setRenderPipelineState:p1];
    sep(re, "drawPrimitives tri start 0x11 count 0x22"); [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0x11 vertexCount:0x22];
    sep(re, "drawPrimitives point(0) start 0 count 3"); [re drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:3];
    sep(re, "drawPrimitives line(1) start 2 count 4"); [re drawPrimitives:MTLPrimitiveTypeLine vertexStart:2 vertexCount:4];
    sep(re, "drawPrimitives lineStrip(2) start 1 count 5"); [re drawPrimitives:MTLPrimitiveTypeLineStrip vertexStart:1 vertexCount:5];
    sep(re, "drawPrimitives triStrip(4) start 3 count 6"); [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:3 vertexCount:6];
    sep(re, "drawPrimitives tri start 0x12345 count 0x23456"); [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0x12345 vertexCount:0x23456];
    sep(re, "drawPrimitives tri start 0x11 count 0x22 inst 0x33"); [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0x11 vertexCount:0x22 instanceCount:0x33];
    sep(re, "drawPrimitives tri start 0x11 count 0x22 inst 0x33 base 0x44"); [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0x11 vertexCount:0x22 instanceCount:0x33 baseInstance:0x44];
    sep(re, "drawPrimitives tri start 0x11 count 0x22 inst 1"); [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0x11 vertexCount:0x22 instanceCount:1];
    sep(re, "drawIndexed tri count 0x66 u16 ib off 0x40"); [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:0x66 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0x40];
    sep(re, "drawIndexed tri count 0x66 u32 ib off 0x80"); [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:0x66 indexType:MTLIndexTypeUInt32 indexBuffer:ib indexBufferOffset:0x80];
    sep(re, "drawIndexed triStrip count 0x66 u16 ib off 0x12346"); [re drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip indexCount:0x66 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0x2346];
    sep(re, "drawIndexed tri count 0x12345 u16 ib off 0x10"); [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:0x12345 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0x10];
    sep(re, "drawIndexed tri count 0x66 u16 off 0x20 inst 0x77"); [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:0x66 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0x20 instanceCount:0x77];
    sep(re, "drawIndexed tri count 0x66 u16 off 0x20 inst 0x77 baseVertex 0x55 baseInst 0x44"); [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:0x66 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0x20 instanceCount:0x77 baseVertex:0x55 baseInstance:0x44];
    sep(re, "drawPrimitives indirect tri buf off 0x10"); [re drawPrimitives:MTLPrimitiveTypeTriangle indirectBuffer:indirect indirectBufferOffset:0x10];
    sep(re, "drawIndexed indirect tri u32 ib off 0x8 ind off 0x20"); [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexType:MTLIndexTypeUInt32 indexBuffer:ib indexBufferOffset:0x8 indirectBuffer:indirect indirectBufferOffset:0x20];
    sep(re, "useResource vb read"); [re useResource:vb usage:MTLResourceUsageRead];
    sep(re, "useResource t read stages fragment"); [re useResource:t usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
    sep(re, "memoryBarrierWithScope buffers after frag before vertex"); [re memoryBarrierWithScope:MTLBarrierScopeBuffers afterStages:MTLRenderStageFragment beforeStages:MTLRenderStageVertex];
    sep(re, "setColorStoreAction DontCare idx 0"); [re setColorStoreAction:MTLStoreActionDontCare atIndex:0];
    sep(re, "insertDebugSignpost"); [re insertDebugSignpost:@"yc-signpost"];
    sep(re, "pushDebugGroup"); [re pushDebugGroup:@"yc-group"];
    sep(re, "popDebugGroup"); [re popDebugGroup];
    sep(re, "end");
    [re endEncoding];
    commitWait(cb, @"render");
}

static void t_rp(int n)
{
    id<MTLTexture> c0 = tex2d(MTLPixelFormatBGRA8Unorm, 64, 32, MTLTextureUsageRenderTarget, MTLStorageModePrivate);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    const char *what = "";
    switch (n) {
    case 0: what = "color0 clear (0.1,0.2,0.3,0.4) store";
        rp.colorAttachments[0].texture = c0; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.3, 0.4);
        break;
    case 1: what = "color0 load(1) dontcare(0)";
        rp.colorAttachments[0].texture = c0; rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
        rp.colorAttachments[0].storeAction = MTLStoreActionDontCare;
        break;
    case 2: what = "color3 only, clear (0.5,0.6,0.7,0.8)";
        rp.colorAttachments[3].texture = c0; rp.colorAttachments[3].loadAction = MTLLoadActionClear;
        rp.colorAttachments[3].clearColor = MTLClearColorMake(0.5, 0.6, 0.7, 0.8);
        break;
    case 3: { what = "color0 mip level 1 slice 2 of 2D array (4 slices, 3 levels), depthPlane n/a";
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
        td.textureType = MTLTextureType2DArray; td.arrayLength = 4; td.mipmapLevelCount = 3;
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
        rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
        rp.colorAttachments[0].level = 1; rp.colorAttachments[0].slice = 2; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        break; }
    case 4: { what = "color0 msaa 4 + resolve to c0 (store MultisampleResolve=2)";
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:32 mipmapped:NO];
        td.textureType = MTLTextureType2DMultisample; td.sampleCount = 4;
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
        rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
        rp.colorAttachments[0].resolveTexture = c0; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
        break; }
    case 5: { what = "color0 + depth32F clear 0.375 + stencil (Depth32Float_Stencil8) clear 0x5c";
        rp.colorAttachments[0].texture = c0;
        id<MTLTexture> ds = tex2d(MTLPixelFormatDepth32Float_Stencil8, 64, 32, MTLTextureUsageRenderTarget, MTLStorageModePrivate);
        rp.depthAttachment.texture = ds; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.clearDepth = 0.375;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        rp.stencilAttachment.texture = ds; rp.stencilAttachment.loadAction = MTLLoadActionClear; rp.stencilAttachment.clearStencil = 0x5c;
        break; }
    case 6: what = "no attachments, renderTargetWidth 48 height 24 defaultRasterSampleCount 4";
        rp.renderTargetWidth = 48; rp.renderTargetHeight = 24; rp.defaultRasterSampleCount = 4;
        break;
    case 7: { what = "color0 + visibilityResultBuffer + renderTargetArrayLength 1";
        rp.colorAttachments[0].texture = c0;
        rp.visibilityResultBuffer = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
        break; }
    }
    printf("rp %d: %s\n", n, what);
    mark([NSString stringWithFormat:@"rp %d: %s", n, what]);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re endEncoding];
    commitWait(cb, [NSString stringWithFormat:@"rp %d", n]);
}

static void t_compute(void)
{
    NSError *e = nil;
    id<MTLComputePipelineState> pa = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"yc_add"] error:&e];
    id<MTLComputePipelineState> pt = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"yc_tex"] error:&e];
    id<MTLComputePipelineState> pg = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"yc_tg"] error:&e];
    id<MTLBuffer> b = [dev newBufferWithLength:0x10000 options:MTLResourceStorageModeShared];
    id<MTLTexture> t = tex2d(MTLPixelFormatRGBA8Unorm, 16, 16, MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead, MTLStorageModePrivate);
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    id<MTLSamplerState> ss = [dev newSamplerStateWithDescriptor:sd];
    printf("refs created in order: pa pt pg b t ss\n");
    mark(@"compute: encode");
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    int s = 0;
#define CSEP(txt) do { s++; printf("csep %d (threadgroupMemoryLength %d idx 30): %s\n", s, s * 16, txt); [ce setThreadgroupMemoryLength:s * 16 atIndex:30]; } while (0)
    CSEP("setComputePipelineState pa"); [ce setComputePipelineState:pa];
    CSEP("setBuffer b off 0x1230 idx 5"); [ce setBuffer:b offset:0x1230 atIndex:5];
    CSEP("setBufferOffset 0x2340 idx 5"); [ce setBufferOffset:0x2340 atIndex:5];
    uint32_t k[4] = { 0x11, 0x22, 0x33, 0x44 };
    CSEP("setBytes 16 idx 6"); [ce setBytes:k length:16 atIndex:6];
    CSEP("setTexture t idx 7"); [ce setTexture:t atIndex:7];
    CSEP("setSamplerState ss idx 8"); [ce setSamplerState:ss atIndex:8];
    CSEP("setSamplerState ss lod 0.5..3.5 idx 9"); [ce setSamplerState:ss lodMinClamp:0.5 lodMaxClamp:3.5 atIndex:9];
    CSEP("setThreadgroupMemoryLength 64 idx 0"); [ce setThreadgroupMemoryLength:64 atIndex:0];
    CSEP("dispatchThreadgroups 3,4,5 tg 6,7,1"); [ce dispatchThreadgroups:MTLSizeMake(3, 4, 5) threadsPerThreadgroup:MTLSizeMake(6, 7, 1)];
    CSEP("dispatchThreads 0x101,9,2 tg 8,4,2"); [ce dispatchThreads:MTLSizeMake(0x101, 9, 2) threadsPerThreadgroup:MTLSizeMake(8, 4, 2)];
    CSEP("dispatchThreadgroupsWithIndirectBuffer b off 0x30 tg 4,2,1"); [ce dispatchThreadgroupsWithIndirectBuffer:b indirectBufferOffset:0x30 threadsPerThreadgroup:MTLSizeMake(4, 2, 1)];
    CSEP("memoryBarrierWithScope buffers"); [ce memoryBarrierWithScope:MTLBarrierScopeBuffers];
    CSEP("memoryBarrierWithResources b"); [ce memoryBarrierWithResources:&b count:1];
    CSEP("useResource b readwrite"); [ce useResource:b usage:MTLResourceUsageRead | MTLResourceUsageWrite];
    CSEP("setComputePipelineState pg"); [ce setComputePipelineState:pg];
    CSEP("setStageInRegion 1,2,3 4,5,6"); [ce setStageInRegion:MTLRegionMake3D(1, 2, 3, 4, 5, 6)];
    CSEP("end");
    [ce endEncoding];
    mark(@"compute: second encoder, concurrent dispatch type");
    ce = [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent];
    [ce setComputePipelineState:pt];
    [ce setTexture:t atIndex:0];
    [ce dispatchThreads:MTLSizeMake(16, 16, 1) threadsPerThreadgroup:MTLSizeMake(4, 4, 1)];
    [ce endEncoding];
    commitWait(cb, @"compute");
}

static void t_blit(void)
{
    id<MTLBuffer> sepb = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    id<MTLBuffer> a = [dev newBufferWithLength:0x20000 options:MTLResourceStorageModeShared];
    id<MTLBuffer> b = [dev newBufferWithLength:0x20000 options:MTLResourceStorageModePrivate];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:YES];
    td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> t1 = [dev newTextureWithDescriptor:td], t2 = [dev newTextureWithDescriptor:td];
    MTLTextureDescriptor *ta = [td copy];
    ta.textureType = MTLTextureType2DArray; ta.arrayLength = 3;
    id<MTLTexture> t3 = [dev newTextureWithDescriptor:ta];
    printf("refs created in order: sepb a b t1 t2 t3\n");
    mark(@"blit: encode");
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    int s = 0;
#define BSEP(txt) do { s++; printf("bsep %d (fill sepb range %d,1 value 0xee): %s\n", s, s, txt); [be fillBuffer:sepb range:NSMakeRange(s, 1) value:0xee]; } while (0)
    BSEP("copy buffer a+0x10 -> b+0x20 size 0x30"); [be copyFromBuffer:a sourceOffset:0x10 toBuffer:b destinationOffset:0x20 size:0x30];
    BSEP("fill b range 0x100,0x200 value 0x5a"); [be fillBuffer:b range:NSMakeRange(0x100, 0x200) value:0x5a];
    BSEP("copy buffer a+0x40 bpr 0x100 bpi 0x4000 size 16,8,1 -> t1 slice 0 level 1 origin 2,3,0");
    [be copyFromBuffer:a sourceOffset:0x40 sourceBytesPerRow:0x100 sourceBytesPerImage:0x4000 sourceSize:MTLSizeMake(16, 8, 1) toTexture:t1 destinationSlice:0 destinationLevel:1 destinationOrigin:MTLOriginMake(2, 3, 0)];
    BSEP("copy t1 slice 0 level 0 origin 1,2,0 size 5,6,1 -> t3 slice 2 level 1 origin 3,4,0");
    [be copyFromTexture:t1 sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(1, 2, 0) sourceSize:MTLSizeMake(5, 6, 1) toTexture:t3 destinationSlice:2 destinationLevel:1 destinationOrigin:MTLOriginMake(3, 4, 0)];
    BSEP("copy t1 -> t2 whole"); [be copyFromTexture:t1 toTexture:t2];
    BSEP("copy t1 slice0 level0 -> t2 slice0 level0 count 1 levels 2");
    [be copyFromTexture:t1 sourceSlice:0 sourceLevel:0 toTexture:t2 destinationSlice:0 destinationLevel:0 sliceCount:1 levelCount:2];
    BSEP("copy t3 slice 1 level 2 origin 1,1,0 size 7,7,1 -> a+0x300 bpr 0x40 bpi 0x200");
    [be copyFromTexture:t3 sourceSlice:1 sourceLevel:2 sourceOrigin:MTLOriginMake(1, 1, 0) sourceSize:MTLSizeMake(7, 7, 1) toBuffer:a destinationOffset:0x300 destinationBytesPerRow:0x40 destinationBytesPerImage:0x200];
    BSEP("generateMipmaps t1"); [be generateMipmapsForTexture:t1];
    BSEP("synchronizeResource n/a; optimizeContentsForGPUAccess t2"); [be optimizeContentsForGPUAccess:t2];
    BSEP("end");
    [be endEncoding];
    commitWait(cb, @"blit");
}

static void t_pso(int n)
{
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"yc_vtx"];
    pd.fragmentFunction = [lib newFunctionWithName:@"yc_frag"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    const char *what = "base: BGRA8 color0, no label";
    switch (n) {
    case 1: what = "color0 RGBA16Float(115)"; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float; break;
    case 2: what = "blending on: src SourceAlpha(4) dst OneMinusSourceAlpha(5) op Add; alpha src One(1) dst Zero(0) op Max(4)";
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
        pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationMax;
        break;
    case 3: what = "writeMask Red|Alpha (0x9)"; pd.colorAttachments[0].writeMask = MTLColorWriteMaskRed | MTLColorWriteMaskAlpha; break;
    case 4: what = "depth Depth32Float(252) stencil n/a, rasterSampleCount 4";
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float; pd.rasterSampleCount = 4; break;
    case 5: what = "two color attachments (BGRA8, RGBA8) MRT fragment";
        pd.fragmentFunction = [lib newFunctionWithName:@"yc_fmrt"];
        pd.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA8Unorm; break;
    case 6: { what = "vertex descriptor: attr0 float4 off 0 buf 1, attr1 float2 off 16 buf 1, layout1 stride 24 perVertex";
        pd.vertexFunction = [lib newFunctionWithName:@"yc_vtx2"];
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        vd.attributes[0].format = MTLVertexFormatFloat4; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 1;
        vd.attributes[1].format = MTLVertexFormatFloat2; vd.attributes[1].offset = 16; vd.attributes[1].bufferIndex = 1;
        vd.layouts[1].stride = 24; vd.layouts[1].stepFunction = MTLVertexStepFunctionPerVertex;
        pd.vertexDescriptor = vd; break; }
    case 7: what = "label yc-pso-label-7, alphaToCoverage on, rasterization disabled no; inputPrimitiveTopology Triangle(3)";
        pd.label = @"yc-pso-label-7"; pd.alphaToCoverageEnabled = YES; pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle; break;
    case 8: what = "blend: rgbOp Subtract(1) srcAlpha SourceAlpha(4) dstAlpha OneMinusSourceAlpha(5); stencil Stencil8(253) depth Depth32Float_Stencil8? no: depth none";
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationSubtract;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.stencilAttachmentPixelFormat = MTLPixelFormatStencil8; break;
    case 9: { what = "vertex descriptor: attr2 Half4(26) off 12 buf 3; layout3 stride 40 PerInstance(2) rate 3";
        pd.vertexFunction = [lib newFunctionWithName:@"yc_vtx2"];
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        vd.attributes[0].format = MTLVertexFormatFloat4; vd.attributes[0].offset = 4; vd.attributes[0].bufferIndex = 3;
        vd.attributes[1].format = MTLVertexFormatHalf2; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 3;
        vd.layouts[3].stride = 40; vd.layouts[3].stepFunction = MTLVertexStepFunctionPerInstance; vd.layouts[3].stepRate = 3;
        pd.vertexDescriptor = vd; break; }
    }
    printf("pso %d: %s\n", n, what);
    mark([NSString stringWithFormat:@"pso %d: %s", n, what]);
    NSError *e = nil;
    id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    printf("pso %p error %s\n", p, e.description.UTF8String ?: "-");
}

static void t_tex(void)
{
    struct { const char *what; MTLTextureType type; MTLPixelFormat f; int w, h, d, mips, samples, array; MTLTextureUsage u; MTLStorageMode sm; MTLCPUCacheMode cm; } v[] = {
        { "2D BGRA8 private RT|SR", MTLTextureType2D, MTLPixelFormatBGRA8Unorm, 100, 50, 1, 1, 1, 1, 5, MTLStorageModePrivate, 0 },
        { "2D BGRA8 shared SR", MTLTextureType2D, MTLPixelFormatBGRA8Unorm, 100, 50, 1, 1, 1, 1, 1, MTLStorageModeShared, 0 },
        { "2D BGRA8 shared SR writecombined", MTLTextureType2D, MTLPixelFormatBGRA8Unorm, 100, 50, 1, 1, 1, 1, 1, MTLStorageModeShared, MTLCPUCacheModeWriteCombined },
        { "2D BGRA8 memoryless RT", MTLTextureType2D, MTLPixelFormatBGRA8Unorm, 100, 50, 1, 1, 1, 1, 4, MTLStorageModeMemoryless, 0 },
        { "2D BGRA8 private SW|PixelFormatView (0x12)", MTLTextureType2D, MTLPixelFormatBGRA8Unorm, 100, 50, 1, 1, 1, 1, 0x12, MTLStorageModePrivate, 0 },
        { "2DArray R8 private 3 slices 4 mips", MTLTextureType2DArray, MTLPixelFormatR8Unorm, 64, 32, 1, 4, 1, 3, 1, MTLStorageModePrivate, 0 },
        { "1D RGBA8 private w 77", MTLTextureType1D, MTLPixelFormatRGBA8Unorm, 77, 1, 1, 1, 1, 1, 1, MTLStorageModePrivate, 0 },
        { "CubeArray? no: Cube RGBA16F 32", MTLTextureTypeCube, MTLPixelFormatRGBA16Float, 32, 32, 1, 1, 1, 1, 1, MTLStorageModePrivate, 0 },
        { "3D RGBA8 9x10x11", MTLTextureType3D, MTLPixelFormatRGBA8Unorm, 9, 10, 11, 1, 1, 1, 1, MTLStorageModePrivate, 0 },
        { "2D 4097x8192 R16F", MTLTextureType2D, MTLPixelFormatR16Float, 4097, 8192, 1, 1, 1, 1, 1, MTLStorageModePrivate, 0 },
    };
    for (unsigned i = 0; i < sizeof v / sizeof v[0]; i++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.textureType = v[i].type; td.pixelFormat = v[i].f; td.width = v[i].w; td.height = v[i].h; td.depth = v[i].d;
        td.mipmapLevelCount = v[i].mips; td.sampleCount = v[i].samples; td.arrayLength = v[i].array;
        td.usage = v[i].u; td.storageMode = v[i].sm; td.cpuCacheMode = v[i].cm;
        printf("tex %u: %s\n", i, v[i].what);
        mark([NSString stringWithFormat:@"tex %u: %s", i, @(v[i].what)]);
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        printf("  -> %p\n", t);
    }
    mark(@"tex swizzle");
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    td.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleBlue, MTLTextureSwizzleGreen, MTLTextureSwizzleRed, MTLTextureSwizzleOne);
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    mark(@"tex view with type/levels/slices");
    id<MTLTexture> v2 = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB textureType:MTLTextureType2DArray levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)];
    printf("view %p\n", v2);
    mark(@"tex replaceRegion level 0 region 1,2 3x4 bpr 32");
    uint8_t px[256];
    for (int i = 0; i < 256; i++) px[i] = (uint8_t)i;
    [t replaceRegion:MTLRegionMake2D(1, 2, 3, 4) mipmapLevel:0 withBytes:px bytesPerRow:32];
    mark(@"tex getBytes region 2,1 4x3 bpr 64");
    uint8_t back[256];
    [t getBytes:back bytesPerRow:64 fromRegion:MTLRegionMake2D(2, 1, 4, 3) mipmapLevel:0];
}

static void t_texflags(void)
{
    for (int n = 0; n < 4; n++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
        const char *what = "default";
        if (n == 1) { what = "allowGPUOptimizedContents NO"; td.allowGPUOptimizedContents = NO; }
        if (n == 2) { what = "compressionType Lossy(1): not run, aborts in the simulator"; continue; }
        if (n == 3) { what = "hazardTrackingMode Untracked(2)"; td.hazardTrackingMode = MTLHazardTrackingModeUntracked; }
        printf("texflags %d: %s\n", n, what);
        mark([NSString stringWithFormat:@"texflags %d: %s", n, what]);
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        (void)t;
    }
}

static void t_sampler(void)
{
    for (int n = 0; n < 4; n++) {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        const char *what = "default";
        if (n == 1) { what = "min Linear mag Linear mip Nearest(1)"; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear; sd.mipFilter = MTLSamplerMipFilterNearest; }
        if (n == 2) { what = "s ClampToZero(4)? r Repeat t MirrorRepeat compare Less(1) normalized NO"; sd.sAddressMode = MTLSamplerAddressModeClampToZero; sd.rAddressMode = MTLSamplerAddressModeRepeat; sd.tAddressMode = MTLSamplerAddressModeMirrorRepeat; sd.compareFunction = MTLCompareFunctionLess; sd.normalizedCoordinates = NO; }
        if (n == 3) { what = "lodMin 1.25 lodMax 6.5 maxAnisotropy 8 border OpaqueWhite(2) ClampToBorder all"; sd.lodMinClamp = 1.25; sd.lodMaxClamp = 6.5; sd.maxAnisotropy = 8; sd.borderColor = MTLSamplerBorderColorOpaqueWhite; sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = MTLSamplerAddressModeClampToBorderColor; }
        printf("sampler %d: %s\n", n, what);
        mark([NSString stringWithFormat:@"sampler %d: %s", n, what]);
        id<MTLSamplerState> s = [dev newSamplerStateWithDescriptor:sd];
        (void)s;
    }
}

static void t_ds(void)
{
    for (int n = 0; n < 4; n++) {
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        const char *what = "default";
        if (n == 1) { what = "compare Greater(4) write YES"; dd.depthCompareFunction = MTLCompareFunctionGreater; dd.depthWriteEnabled = YES; }
        if (n == 2) { what = "front stencil: compare Equal(3) fail Replace(2) depthFail IncrementClamp(3) pass Invert(5) read 0xf0 write 0x0f";
            MTLStencilDescriptor *s = [MTLStencilDescriptor new];
            s.stencilCompareFunction = MTLCompareFunctionEqual; s.stencilFailureOperation = MTLStencilOperationReplace;
            s.depthFailureOperation = MTLStencilOperationIncrementClamp; s.depthStencilPassOperation = MTLStencilOperationInvert;
            s.readMask = 0xf0; s.writeMask = 0x0f; dd.frontFaceStencil = s; }
        if (n == 3) { what = "back stencil: compare NotEqual(5) fail Zero(1) depthFail DecrementWrap(7) pass IncrementWrap(6) read 0x3c write 0xc3";
            MTLStencilDescriptor *s = [MTLStencilDescriptor new];
            s.stencilCompareFunction = MTLCompareFunctionNotEqual; s.stencilFailureOperation = MTLStencilOperationZero;
            s.depthFailureOperation = MTLStencilOperationDecrementWrap; s.depthStencilPassOperation = MTLStencilOperationIncrementWrap;
            s.readMask = 0x3c; s.writeMask = 0xc3; dd.backFaceStencil = s; }
        printf("ds %d: %s\n", n, what);
        mark([NSString stringWithFormat:@"ds %d: %s", n, what]);
        id<MTLDepthStencilState> d = [dev newDepthStencilStateWithDescriptor:dd];
        (void)d;
    }
}

static void t_big(void)
{
    id<MTLRenderPipelineState> p = pso(@"yc_vtx", @"yc_frag", MTLPixelFormatBGRA8Unorm, MTLPixelFormatInvalid);
    id<MTLTexture> c = tex2d(MTLPixelFormatBGRA8Unorm, 16, 16, MTLTextureUsageRenderTarget, MTLStorageModePrivate);
    id<MTLBuffer> vb = [dev newBufferWithLength:4096 options:0];
    mark(@"big: encode 6000 draws");
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = c;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:p];
    [re setVertexBuffer:vb offset:0 atIndex:0];
    for (int i = 0; i < 6000; i++) [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:i vertexCount:3];
    [re endEncoding];
    commitWait(cb, @"big");
}

static void t_many(void)
{
    id<MTLBuffer> b = [dev newBufferWithLength:4096 options:0];
    mark(@"many: 20 command buffers");
    NSMutableArray *cbs = [NSMutableArray array];
    for (int i = 0; i < 20; i++) {
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be fillBuffer:b range:NSMakeRange(i, 1) value:i];
        [be endEncoding];
        [cb commit];
        [cbs addObject:cb];
    }
    for (id<MTLCommandBuffer> cb in cbs) [cb waitUntilCompleted];
    mark(@"many: done");
}

static void t_bytes(void)
{
    id<MTLRenderPipelineState> p = pso(@"yc_vtx", @"yc_frag", MTLPixelFormatBGRA8Unorm, MTLPixelFormatInvalid);
    id<MTLTexture> c = tex2d(MTLPixelFormatBGRA8Unorm, 16, 16, MTLTextureUsageRenderTarget, MTLStorageModePrivate);
    mark(@"bytes: encode");
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = c;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:p];
    uint8_t data[4096];
    for (int i = 0; i < 4096; i++) data[i] = (uint8_t)(i * 7);
    int sizes[] = { 4, 16, 100, 256, 1000, 4096 };
    for (int i = 0; i < 6; i++) {
        sep(re, [NSString stringWithFormat:@"setVertexBytes %d idx %d", sizes[i], i].UTF8String);
        [re setVertexBytes:data length:sizes[i] atIndex:i];
    }
    sep(re, "end");
    [re endEncoding];
    commitWait(cb, @"bytes");
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        g_mark = (void (*)(const char *))dlsym(RTLD_DEFAULT, "mslog_mark");
        dev = MTLCreateSystemDefaultDevice();
        queue = [dev newCommandQueue];
        NSError *e = nil;
        mark(@"library");
        lib = [dev newLibraryWithSource:kSrc options:nil error:&e];
        if (!lib) { printf("lib error %s\n", e.description.UTF8String); return 1; }
        for (int a = 1; a < argc; a++) {
            NSString *t = @(argv[a]);
            int n = a + 1 < argc ? atoi(argv[a + 1]) : 0;
            if ([t isEqual:@"render"]) t_render();
            else if ([t isEqual:@"rp"]) { t_rp(n); a++; }
            else if ([t isEqual:@"compute"]) t_compute();
            else if ([t isEqual:@"blit"]) t_blit();
            else if ([t isEqual:@"pso"]) { t_pso(n); a++; }
            else if ([t isEqual:@"tex"]) t_tex();
            else if ([t isEqual:@"sampler"]) t_sampler();
            else if ([t isEqual:@"texflags"]) t_texflags();
            else if ([t isEqual:@"ds"]) t_ds();
            else if ([t isEqual:@"big"]) t_big();
            else if ([t isEqual:@"many"]) t_many();
            else if ([t isEqual:@"bytes"]) t_bytes();
            else printf("unknown %s\n", argv[a]);
        }
        mark(@"exit");
    }
    return 0;
}
