/*
 * argprobe: our own argument-buffer probe for the simulator (original Ycode
 * code, OBS-ARGBUF). Written against the public Metal API only.
 *
 * For each argument-buffer layout (a struct of our own shader source, or a
 * list of MTLArgumentDescriptor objects) it makes an argument encoder, fills
 * a shared buffer with 0xEE, points the encoder at it, sets every member to a
 * distinctive value (buffers: our data buffer at offset 16 x (k + 1);
 * textures and samplers: separate objects; inline data: a marker byte
 * written through constantDataAtIndex:) and prints the bytes that changed.
 * The function's reflection is printed afterwards (offsets as the driver
 * reports them). When run under mslog.dylib, every step puts a marker into
 * the recorder's log, so op 16 / 17 / 19 records can be matched to calls.
 *
 * Usage: argprobe [layout ...]   (default: all)   argprobe draw   (op 29 probe)
 *        argprobe lib <metallib> [filter]                  list function names
 *        argprobe lib <metallib> - <function> [index]      encoder(s) for a function's argument buffer(s)
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static void (*g_mark)(const char *);
static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLBuffer> g_data;

static void mark(NSString *s)
{
    printf("### %s\n", s.UTF8String);
    fflush(stdout);
    if (g_mark) g_mark(s.UTF8String);
}

/* ---- layouts: our own structs ---- */

typedef struct { const char *name, *decl; } Layout;

static const Layout kLayouts[] = {
    { "dense", "struct A { device float *b [[id(0)]]; texture2d<float> t [[id(1)]]; sampler s [[id(2)]]; };" },
    { "sparse", "struct A { device float *b [[id(0)]]; texture2d<float> t [[id(5)]]; sampler s [[id(9)]]; };" },
    { "weather", "struct A { device float *b0 [[id(200)]]; device float *b1 [[id(201)]]; texture2d<float> t [[id(230)]]; sampler s [[id(231)]]; };" },
    { "gap1", "struct A { device float *p [[id(1)]]; };" },
    { "gap1000", "struct A { device float *p [[id(1000)]]; };" },
    { "order", "struct A { texture2d<float> t [[id(3)]]; device float *p [[id(1)]]; float x [[id(2)]]; };" },
    { "implicit", "struct A { device float *a; texture2d<float> t; sampler s; float x; device float *b; };" },
    { "scalars", "struct A { float f [[id(0)]]; float4 v [[id(1)]]; int i [[id(2)]]; float3 v3 [[id(3)]]; half h [[id(4)]]; char c [[id(5)]]; float4x4 m [[id(6)]]; device float *p [[id(7)]]; packed_float3 pf [[id(8)]]; float2 v2 [[id(9)]]; uint u [[id(10)]]; };" },
    { "scalars2", "struct A { bool b [[id(0)]]; short s [[id(1)]]; ulong l [[id(2)]]; float2x3 m [[id(3)]]; half4 h4 [[id(4)]]; uchar2 c2 [[id(5)]]; device float *p [[id(6)]]; };" },
    { "mixed", "struct A { device float *p [[id(0)]]; float x [[id(1)]]; device float *q [[id(2)]]; half y [[id(3)]]; texture2d<float> t [[id(4)]]; };" },
    { "mixedsparse", "struct A { float x [[id(3)]]; device float *p [[id(10)]]; float4 v [[id(11)]]; sampler s [[id(40)]]; };" },
    { "arrays", "struct A { array<texture2d<float>, 4> ta [[id(0)]]; device float *p [[id(4)]]; array<sampler, 2> sa [[id(10)]]; float fa [[id(20)]] [3]; device float *pa [[id(30)]] [2]; };" },
    { "nested", "struct In { device float *p; texture2d<float> t; float k; }; struct A { In a [[id(0)]]; In b [[id(10)]]; device float *q [[id(20)]]; };" },
    { "nestedarr", "struct In { device float *p; sampler s; }; struct A { array<In, 2> a [[id(0)]]; float k [[id(8)]]; };" },
    { "kinds", "struct A { constant float *c [[id(0)]]; texture3d<float> t3 [[id(1)]]; depth2d<float> d [[id(2)]]; texturecube<float> tc [[id(3)]]; texture2d_array<float> ta [[id(4)]]; device int *w [[id(7)]]; texture1d<float> t1 [[id(8)]]; texture2d_ms<float> tms [[id(9)]]; texture_buffer<float> tb [[id(10)]]; };" },
    { "writable", "struct A { texture2d<float, access::write> tw [[id(0)]]; texture2d<float, access::read_write> trw [[id(1)]]; device float *p [[id(2)]]; };" },
    { "ptrab", "struct Sub { device float *p [[id(0)]]; texture2d<float> t [[id(1)]]; }; struct A { constant Sub *s [[id(0)]]; device float *q [[id(3)]]; };" },
    { "dense15", "struct A { device float *b0 [[id(0)]]; device float *b1 [[id(1)]]; device float *b2 [[id(2)]]; device float *b3 [[id(3)]]; device float *b4 [[id(4)]]; device float *b5 [[id(5)]]; device float *b6 [[id(6)]]; device float *b7 [[id(7)]]; device float *b8 [[id(8)]]; device float *b9 [[id(9)]]; device float *b10 [[id(10)]]; device float *b11 [[id(11)]]; device float *b12 [[id(12)]]; device float *b13 [[id(13)]]; device float *b14 [[id(14)]]; };" },
    { "arrays2", "struct A { float k [[id(0)]]; array<texture2d<float>, 3> ta [[id(1)]]; float4 fa [[id(4)]] [2]; sampler s [[id(6)]]; };" },
    { "bigdata", "struct A { device float *p [[id(0)]]; float4 m [[id(1)]] [40]; texture2d<float> t [[id(41)]]; };" },
    { "onefloat", "struct A { float x [[id(0)]]; };" },
    { "onehalf", "struct A { half x [[id(3)]]; char c [[id(4)]]; };" },
    { "floatptr", "struct A { float x [[id(0)]]; device float *p [[id(1)]]; };" },
    { "constdev", "struct A { const device float *r [[id(0)]]; device float4 *w [[id(1)]]; constant float4x4 *m [[id(2)]]; };" },
    { "texfirst", "struct A { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; device float *b [[id(2)]]; float4 c [[id(3)]]; };" },
};

/* A kernel that touches every member, so nothing is dropped from the struct. */
static NSString *kernelFor(const Layout *L)
{
    return [NSString stringWithFormat:
        @"#include <metal_stdlib>\nusing namespace metal;\n%s\n"
         "kernel void k(constant A &a [[buffer(0)]], device float *o [[buffer(1)]], uint i [[thread_position_in_grid]])"
         " { o[i] = (float)sizeof(A) + (float)(ulong)&a; }\n", L->decl];
}

/* ---- objects to set ---- */

static NSMutableArray *g_keep;

static id<MTLTexture> texFor(MTLTextureType tt, BOOL depth, BOOL write)
{
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = tt;
    d.pixelFormat = depth ? MTLPixelFormatDepth32Float : MTLPixelFormatRGBA8Unorm;
    d.width = 4; d.height = (tt == MTLTextureType1D || tt == MTLTextureTypeTextureBuffer) ? 1 : 4;
    d.depth = tt == MTLTextureType3D ? 4 : 1;
    d.arrayLength = tt == MTLTextureType2DArray ? 2 : 1;
    d.sampleCount = tt == MTLTextureType2DMultisample ? 4 : 1;
    d.storageMode = (depth || tt == MTLTextureType2DMultisample) ? MTLStorageModePrivate : MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead | (write ? MTLTextureUsageShaderWrite : 0) |
              (tt == MTLTextureType2DMultisample || depth ? MTLTextureUsageRenderTarget : 0);
    id<MTLTexture> t;
    if (tt == MTLTextureTypeTextureBuffer) {
        id<MTLBuffer> b = [dev newBufferWithLength:256 options:MTLResourceStorageModePrivate];
        [g_keep addObject:b];
        t = [b newTextureWithDescriptor:[MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
            width:4 resourceOptions:MTLResourceStorageModePrivate usage:MTLTextureUsageShaderRead] offset:0 bytesPerRow:256];
    } else
        t = [dev newTextureWithDescriptor:d];
    if (t) [g_keep addObject:t];
    printf("  texture type %lu -> %p gpuResourceID 0x%llx\n", (unsigned long)tt, t, t ? t.gpuResourceID._impl : 0);
    return t;
}

static id<MTLSamplerState> newSampler(void)
{
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.supportArgumentBuffers = YES;
    id<MTLSamplerState> s = [dev newSamplerStateWithDescriptor:sd];
    [g_keep addObject:s];
    printf("  sampler %p gpuResourceID 0x%llx\n", s, s.gpuResourceID._impl);
    return s;
}

/* ---- reflection walk: prints and sets each member ---- */

static int g_k;  /* running member counter for distinct values */

static void setMember(id<MTLArgumentEncoder> ae, uint8_t *base, NSUInteger idx, MTLDataType dt,
                      MTLTextureReferenceType *tr, const char *name)
{
    int k = g_k++;
    switch (dt) {
    case MTLDataTypePointer:
        mark([NSString stringWithFormat:@"set buffer id %lu (%s) offset %d", (unsigned long)idx, name, 16 * (k + 1)]);
        [ae setBuffer:g_data offset:16 * (k + 1) atIndex:idx];
        break;
    case MTLDataTypeTexture: {
        MTLTextureType tt = tr ? tr.textureType : MTLTextureType2D;
        BOOL depth = tr && tr.isDepthTexture;
        BOOL write = tr && tr.access != MTLBindingAccessReadOnly;
        id<MTLTexture> t = texFor(tt, depth, write);
        mark([NSString stringWithFormat:@"set texture id %lu (%s) type %lu", (unsigned long)idx, name, (unsigned long)tt]);
        [ae setTexture:t atIndex:idx];
        break;
    }
    case MTLDataTypeSampler: {
        id<MTLSamplerState> s = newSampler();
        mark([NSString stringWithFormat:@"set sampler id %lu (%s)", (unsigned long)idx, name]);
        [ae setSamplerState:s atIndex:idx];
        break;
    }
    default: {
        mark([NSString stringWithFormat:@"constantData id %lu (%s) type %lu", (unsigned long)idx, name, (unsigned long)dt]);
        uint8_t *p = [ae constantDataAtIndex:idx];
        long off = p ? (long)(p - base) : -1;
        printf("  constantData id %lu (%s, dataType %lu) at +%ld\n", (unsigned long)idx, name, (unsigned long)dt, off);
        if (p) *p = (uint8_t)(0xA0 + (k & 0xf));
        break;
    }
    }
}

static void walkStruct(id<MTLArgumentEncoder> ae, uint8_t *base, MTLStructType *st, int depth, BOOL doSet);

static void walkType(id<MTLArgumentEncoder> ae, uint8_t *base, NSUInteger idx, MTLDataType dt, MTLType *ty,
                     const char *name, int depth, BOOL doSet)
{
    if (dt == MTLDataTypeArray) {
        MTLArrayType *at = (MTLArrayType *)ty;
        printf("%*s  array len %lu stride %lu argumentIndexStride %lu element %lu\n", depth * 2, "",
               (unsigned long)at.arrayLength, (unsigned long)at.stride, (unsigned long)at.argumentIndexStride,
               (unsigned long)at.elementType);
        for (NSUInteger e = 0; e < at.arrayLength; e++) {
            NSUInteger ei = idx + e * at.argumentIndexStride;
            MTLType *et = nil;
            switch (at.elementType) {
            case MTLDataTypeStruct: et = at.elementStructType; break;
            case MTLDataTypeArray: et = at.elementArrayType; break;
            case MTLDataTypeTexture: et = at.elementTextureReferenceType; break;
            case MTLDataTypePointer: et = at.elementPointerType; break;
            default: break;
            }
            char nm[128];
            snprintf(nm, sizeof nm, "%s[%lu]", name, (unsigned long)e);
            if (at.elementType == MTLDataTypeStruct && !doSet) continue;
            if (at.elementType == MTLDataTypeStruct) {
                /* nested struct elements: their members' indices are relative to ei */
                for (MTLStructMember *m in at.elementStructType.members) {
                    char nn[192];
                    snprintf(nn, sizeof nn, "%s.%s", nm, m.name.UTF8String);
                    MTLType *mt = m.dataType == MTLDataTypeTexture ? (MTLType *)m.textureReferenceType : nil;
                    if (doSet) setMember(ae, base, ei + m.argumentIndex, m.dataType, (MTLTextureReferenceType *)mt, nn);
                }
            } else if (doSet)
                setMember(ae, base, ei, at.elementType, (MTLTextureReferenceType *)et, nm);
            (void)et;
        }
        return;
    }
    if (dt == MTLDataTypeStruct) {
        walkStruct(ae, base, (MTLStructType *)ty, depth + 1, doSet);
        return;
    }
    if (doSet) setMember(ae, base, idx, dt, dt == MTLDataTypeTexture ? (MTLTextureReferenceType *)ty : nil, name);
}

static void walkStruct(id<MTLArgumentEncoder> ae, uint8_t *base, MTLStructType *st, int depth, BOOL doSet)
{
    for (MTLStructMember *m in st.members) {
        MTLType *ty = nil;
        switch (m.dataType) {
        case MTLDataTypeStruct: ty = m.structType; break;
        case MTLDataTypeArray: ty = m.arrayType; break;
        case MTLDataTypeTexture: ty = m.textureReferenceType; break;
        case MTLDataTypePointer: ty = m.pointerType; break;
        default: break;
        }
        if (!doSet) {
            printf("%*s  member %-6s offset %3lu argumentIndex %4lu dataType %3lu", depth * 2, "", m.name.UTF8String,
                   (unsigned long)m.offset, (unsigned long)m.argumentIndex, (unsigned long)m.dataType);
            if (m.dataType == MTLDataTypeTexture)
                printf(" textureType %lu access %lu depth %d", (unsigned long)m.textureReferenceType.textureType,
                       (unsigned long)m.textureReferenceType.access, m.textureReferenceType.isDepthTexture);
            if (m.dataType == MTLDataTypePointer)
                printf(" pointer elem %lu access %lu size %lu align %lu argbuf %d", (unsigned long)m.pointerType.elementType,
                       (unsigned long)m.pointerType.access, (unsigned long)m.pointerType.dataSize,
                       (unsigned long)m.pointerType.alignment, m.pointerType.elementIsArgumentBuffer);
            printf("\n");
            if (m.dataType == MTLDataTypeStruct) walkStruct(ae, base, m.structType, depth + 1, NO);
            if (m.dataType == MTLDataTypeArray) walkType(ae, base, m.argumentIndex, m.dataType, ty, m.name.UTF8String, depth + 1, NO);
            continue;
        }
        if (m.dataType == MTLDataTypeStruct) {
            for (MTLStructMember *n in m.structType.members) {
                char nn[192];
                snprintf(nn, sizeof nn, "%s.%s", m.name.UTF8String, n.name.UTF8String);
                if (n.dataType == MTLDataTypeArray)
                    walkType(ae, base, m.argumentIndex + n.argumentIndex, n.dataType, n.arrayType, nn, depth + 1, YES);
                else
                    setMember(ae, base, m.argumentIndex + n.argumentIndex, n.dataType,
                              n.dataType == MTLDataTypeTexture ? n.textureReferenceType : nil, nn);
            }
            continue;
        }
        walkType(ae, base, m.argumentIndex, m.dataType, ty, m.name.UTF8String, depth, YES);
    }
}

static void dump(const uint8_t *p, NSUInteger n)
{
    for (NSUInteger o = 0; o < n; o += 8) {
        int changed = 0;
        for (int j = 0; j < 8; j++) if (p[o + j] != 0xEE) changed = 1;
        if (!changed) continue;
        printf("    +%4lu:", (unsigned long)o);
        for (int j = 0; j < 8; j++) printf(" %02x", p[o + j]);
        uint64_t v; memcpy(&v, p + o, 8);
        printf("   u64 0x%llx\n", v);
    }
}

static void runEncoder(NSString *label, id<MTLArgumentEncoder> ae, MTLStructType *st, NSUInteger abOffset)
{
    printf("  encoder %p encodedLength %lu alignment %lu (label %s)\n", ae, (unsigned long)ae.encodedLength,
           (unsigned long)ae.alignment, label.UTF8String);
    id<MTLBuffer> ab = [dev newBufferWithLength:8192 options:MTLResourceStorageModeShared];
    [g_keep addObject:ab];
    memset(ab.contents, 0xEE, 8192);
    uint8_t *base = (uint8_t *)ab.contents + abOffset;
    mark([NSString stringWithFormat:@"%@: setArgumentBuffer offset %lu", label, (unsigned long)abOffset]);
    [ae setArgumentBuffer:ab offset:abOffset];
    printf("  argument buffer gpuAddress 0x%llx data gpuAddress 0x%llx\n", ab.gpuAddress, g_data.gpuAddress);
    g_k = 0;
    if (st) walkStruct(ae, base, st, 0, YES);
    mark([NSString stringWithFormat:@"%@: sets done", label]);
    printf("  bytes changed (from argument buffer offset %lu):\n", (unsigned long)abOffset);
    dump(base, 8192 - abOffset);
    printf("  bytes changed before the offset: ");
    int any = 0;
    for (NSUInteger o = 0; o < abOffset; o++) if (((uint8_t *)ab.contents)[o] != 0xEE) any = 1;
    printf("%s\n", any ? "YES" : "none");
}

static void doLayout(const Layout *L)
{
    mark([NSString stringWithFormat:@"layout %s: compile", L->name]);
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kernelFor(L) options:nil error:&e];
    if (!lib) { printf("  compile failed: %s\n", e.localizedDescription.UTF8String); return; }
    id<MTLFunction> f = [lib newFunctionWithName:@"k"];
    mark([NSString stringWithFormat:@"layout %s: newArgumentEncoderWithBufferIndex", L->name]);
    id<MTLArgumentEncoder> ae = [f newArgumentEncoderWithBufferIndex:0];
    if (!ae) { printf("  no encoder\n"); return; }
    mark([NSString stringWithFormat:@"layout %s: reflection", L->name]);
    MTLAutoreleasedArgument refl = nil;
    id<MTLArgumentEncoder> ae2 = [f newArgumentEncoderWithBufferIndex:0 reflection:&refl];
    MTLStructType *st = refl.bufferStructType;
    printf("  reflection: encoder %p len %lu align %lu; buffer dataSize %lu alignment %lu\n", ae2,
           (unsigned long)ae2.encodedLength, (unsigned long)ae2.alignment, (unsigned long)refl.bufferDataSize,
           (unsigned long)refl.bufferAlignment);
    walkStruct(ae, NULL, st, 0, NO);
    runEncoder([NSString stringWithFormat:@"layout %s", L->name], ae, st, 0);
    if (!strcmp(L->name, "sparse") || !strcmp(L->name, "weather") || !strcmp(L->name, "mixed"))
        runEncoder([NSString stringWithFormat:@"layout %s @256", L->name], ae, st, 256);
    if (!strcmp(L->name, "ptrab")) {
        mark(@"layout ptrab: newArgumentEncoderForBufferAtIndex 0");
        id<MTLArgumentEncoder> sub = [ae newArgumentEncoderForBufferAtIndex:0];
        printf("  sub-encoder %p len %lu align %lu\n", sub, (unsigned long)sub.encodedLength, (unsigned long)sub.alignment);
        if (sub) {
            id<MTLBuffer> sb = [dev newBufferWithLength:1024 options:0];
            [g_keep addObject:sb];
            memset(sb.contents, 0xEE, 1024);
            [sub setArgumentBuffer:sb offset:0];
            [sub setBuffer:g_data offset:0x300 atIndex:0];
            [sub setTexture:texFor(MTLTextureType2D, NO, NO) atIndex:1];
            printf("  sub bytes:\n");
            dump(sb.contents, 1024);
        }
    }
}

/* ---- layouts from argument descriptors ---- */

static MTLArgumentDescriptor *ad(MTLDataType dt, NSUInteger idx, NSUInteger len, MTLTextureType tt, MTLBindingAccess acc)
{
    MTLArgumentDescriptor *d = [MTLArgumentDescriptor argumentDescriptor];
    d.dataType = dt; d.index = idx; d.arrayLength = len; d.textureType = tt; d.access = acc;
    return d;
}

static void doDescriptors(const char *name, NSArray<MTLArgumentDescriptor *> *list)
{
    mark([NSString stringWithFormat:@"descriptors %s: newArgumentEncoderWithArguments", name]);
    id<MTLArgumentEncoder> ae = [dev newArgumentEncoderWithArguments:list];
    if (!ae) { printf("  no encoder\n"); return; }
    printf("  encoder %p encodedLength %lu alignment %lu\n", ae, (unsigned long)ae.encodedLength, (unsigned long)ae.alignment);
    id<MTLBuffer> ab = [dev newBufferWithLength:4096 options:0];
    [g_keep addObject:ab];
    memset(ab.contents, 0xEE, 4096);
    mark([NSString stringWithFormat:@"descriptors %s: setArgumentBuffer", name]);
    [ae setArgumentBuffer:ab offset:0];
    g_k = 0;
    for (MTLArgumentDescriptor *d in list) {
        NSUInteger n = d.arrayLength ? d.arrayLength : 1;
        for (NSUInteger e = 0; e < n; e++) {
            char nm[64];
            snprintf(nm, sizeof nm, "desc idx %lu[%lu]", (unsigned long)d.index, (unsigned long)e);
            MTLTextureReferenceType *tr = nil;
            if (d.dataType == MTLDataTypeTexture) {
                id<MTLTexture> t = texFor(d.textureType, NO, d.access != MTLBindingAccessReadOnly);
                mark([NSString stringWithFormat:@"set texture id %lu", (unsigned long)(d.index + e)]);
                [ae setTexture:t atIndex:d.index + e];
                g_k++;
                continue;
            }
            setMember(ae, ab.contents, d.index + e, d.dataType, tr, nm);
        }
    }
    mark([NSString stringWithFormat:@"descriptors %s: sets done", name]);
    dump(ab.contents, 4096);
}

/* ---- a library given by path (public API only): list functions, make an encoder ---- */

static void doLib(const char *path, const char *filter, const char *fn, int idx)
{
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(path)] error:&e];
    if (!lib) { printf("library failed: %s\n", e.localizedDescription.UTF8String); return; }
    if (!fn) {
        for (NSString *n in lib.functionNames)
            if (!filter || [n rangeOfString:@(filter)].location != NSNotFound) printf("function %s\n", n.UTF8String);
        return;
    }
    id<MTLFunction> f = [lib newFunctionWithName:@(fn)];
    printf("function %s -> %p type %lu constants %lu\n", fn, f, (unsigned long)f.functionType,
           (unsigned long)f.functionConstantsDictionary.count);
    for (NSString *k in f.functionConstantsDictionary) {
        MTLFunctionConstant *c = f.functionConstantsDictionary[k];
        printf("  constant %s index %lu type %lu required %d\n", k.UTF8String, (unsigned long)c.index, (unsigned long)c.type, c.required);
    }
    if (f.functionConstantsDictionary.count) {
        /* specialize with zeros for every constant */
        MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
        uint8_t zero[64] = { 0 };
        for (NSString *k in f.functionConstantsDictionary) {
            MTLFunctionConstant *c = f.functionConstantsDictionary[k];
            [cv setConstantValue:zero type:c.type atIndex:c.index];
        }
        f = [lib newFunctionWithName:@(fn) constantValues:cv error:&e];
        printf("specialized -> %p %s\n", f, e ? e.localizedDescription.UTF8String : "");
        if (!f) return;
    }
    NSMutableArray *idxs = [NSMutableArray new];
    if (idx >= 0) [idxs addObject:@(idx)];
    else if (getenv("ARGPROBE_VERTEX")) {
        /* list the function's arguments through a render pipeline's reflection */
        id<MTLFunction> v = [lib newFunctionWithName:@(getenv("ARGPROBE_VERTEX"))];
        if (v.functionConstantsDictionary.count) {
            MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
            uint8_t zero[64] = { 0 };
            for (NSString *k in v.functionConstantsDictionary) {
                MTLFunctionConstant *c = v.functionConstantsDictionary[k];
                [cv setConstantValue:zero type:c.type atIndex:c.index];
            }
            v = [lib newFunctionWithName:v.name constantValues:cv error:&e];
        }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = v;
        pd.fragmentFunction = f;
        pd.colorAttachments[0].pixelFormat = getenv("ARGPROBE_FORMAT") ? (MTLPixelFormat)atoi(getenv("ARGPROBE_FORMAT")) : MTLPixelFormatRGBA16Float;
        MTLAutoreleasedRenderPipelineReflection rr = nil;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd options:MTLPipelineOptionArgumentInfo | MTLPipelineOptionBufferTypeInfo
                                                                       reflection:&rr error:&e];
        printf("pipeline %p %s\n", ps, e ? e.localizedDescription.UTF8String : "");
        for (MTLArgument *a in rr.fragmentArguments) {
            printf("  fragment argument %s type %lu index %lu active %d", a.name.UTF8String, (unsigned long)a.type,
                   (unsigned long)a.index, a.isActive);
            if (a.type == MTLArgumentTypeBuffer) {
                printf(" dataType %lu size %lu argbuf %d", (unsigned long)a.bufferDataType, (unsigned long)a.bufferDataSize,
                       a.bufferPointerType.elementIsArgumentBuffer);
                if (a.bufferPointerType.elementIsArgumentBuffer) [idxs addObject:@(a.index)];
            }
            printf("\n");
        }
    }
    for (NSNumber *n in idxs) {
        int i = n.intValue;
        mark([NSString stringWithFormat:@"lib %s buffer %d: newArgumentEncoderWithBufferIndex", fn, i]);
        MTLAutoreleasedArgument refl = nil;
        id<MTLArgumentEncoder> ae = [f newArgumentEncoderWithBufferIndex:i reflection:&refl];
        if (!ae) continue;
        printf("buffer index %d: %s encodedLength %lu alignment %lu dataSize %lu\n", i, refl.name.UTF8String,
               (unsigned long)ae.encodedLength, (unsigned long)ae.alignment, (unsigned long)refl.bufferDataSize);
        walkStruct(ae, NULL, refl.bufferStructType, 0, NO);
        runEncoder([NSString stringWithFormat:@"lib %s buffer %d", fn, i], ae, refl.bufferStructType, 0);
    }
}

/* ---- range setters ---- */

static void doRange(void)
{
    Layout L = { "range", "struct A { device float *b0 [[id(10)]]; device float *b1 [[id(11)]]; device float *b2 [[id(12)]]; texture2d<float> t0 [[id(20)]]; texture2d<float> t1 [[id(21)]]; sampler s0 [[id(30)]]; sampler s1 [[id(31)]]; };" };
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kernelFor(&L) options:nil error:&e];
    if (!lib) { printf("  compile failed: %s\n", e.localizedDescription.UTF8String); return; }
    id<MTLArgumentEncoder> ae = [[lib newFunctionWithName:@"k"] newArgumentEncoderWithBufferIndex:0];
    id<MTLBuffer> ab = [dev newBufferWithLength:1024 options:0];
    memset(ab.contents, 0xEE, 1024);
    [ae setArgumentBuffer:ab offset:0];
    id<MTLBuffer> bufs[3] = { g_data, g_data, g_data };
    NSUInteger offs[3] = { 0x40, 0x80, 0xc0 };
    mark(@"range: setBuffers 10..12");
    [ae setBuffers:bufs offsets:offs withRange:NSMakeRange(10, 3)];
    id<MTLTexture> tx[2] = { texFor(MTLTextureType2D, NO, NO), texFor(MTLTextureType2D, NO, NO) };
    mark(@"range: setTextures 20..21");
    [ae setTextures:tx withRange:NSMakeRange(20, 2)];
    MTLSamplerDescriptor *sd2 = [MTLSamplerDescriptor new];
    sd2.supportArgumentBuffers = YES;
    sd2.minFilter = MTLSamplerMinMagFilterLinear;
    id<MTLSamplerState> s2 = [dev newSamplerStateWithDescriptor:sd2];
    printf("  sampler2 gpuResourceID 0x%llx\n", s2.gpuResourceID._impl);
    id<MTLSamplerState> ss[2] = { newSampler(), s2 };
    mark(@"range: setSamplerStates 30..31");
    [ae setSamplerStates:ss withRange:NSMakeRange(30, 2)];
    mark(@"range: done before nil");
    dump(ab.contents, 1024);
    mark(@"range: setBuffer nil 11");
    [ae setBuffer:nil offset:0 atIndex:11];
    mark(@"range: setTexture nil 21");
    [ae setTexture:nil atIndex:21];
    mark(@"range: done");
    dump(ab.contents, 1024);
}

/* ---- op 29 probe (Q24) ---- */

static void doDraw(void)
{
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { float4 p [[position]]; };\n"
        "vertex V vs(uint v [[vertex_id]], uint i [[instance_id]], uint bi [[base_instance]], const device float4 *x [[buffer(0)]])"
        " { V o; o.p = x[v] + float4(float(i + bi) * 0.0, 0, 0, 0); return o; }\n"
        "fragment float4 fs() { return float4(1); }\n";
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
    if (!lib) { printf("compile failed %s\n", e.localizedDescription.UTF8String); return; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) { printf("pipeline failed %s\n", e.localizedDescription.UTF8String); return; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> vb = [dev newBufferWithLength:4096 options:0];
    memset(vb.contents, 0, 4096);
    id<MTLBuffer> ib = [dev newBufferWithLength:4096 options:0];
    memset(ib.contents, 0, 4096);
    /* fill a first command buffer's segment with records whose high halves are distinctive, then the probe draws */
    for (int round = 0; round < 3; round++) {
        mark([NSString stringWithFormat:@"draw round %d", round]);
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps];
        [re setVertexBuffer:vb offset:0 atIndex:0];
        if (round == 0) {
            /* records with large values at the positions op 29's last word will occupy in later rounds */
            for (int j = 0; j < 8; j++)
                [re setViewport:(MTLViewport){ 1.5, 2.5, 3.5, 4.5, 0.0, 1.0 }];
        }
        uint32_t bis[] = { 0, 1, 7, 0x1234, 0xFFFF };
        for (int j = 0; j < 5; j++)
            [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:36 indexType:MTLIndexTypeUInt16
                          indexBuffer:ib indexBufferOffset:0 instanceCount:6 baseVertex:(j == 3 ? -2 : 0)
                         baseInstance:bis[j]];
        [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:36 indexType:MTLIndexTypeUInt16
                      indexBuffer:ib indexBufferOffset:0 instanceCount:6 baseVertex:0 baseInstance:0x10000];
        [re endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        printf("round %d status %ld\n", round, (long)cb.status);
    }
}

/* op 29 with stale high bytes: does the host use only the low 16 bits? A vertex function writes the
 * base instance it sees into a buffer (rasterization off). Round 0 leaves viewport records (doubles)
 * where round 1's op 29 lands. */
static void doDraw2(void)
{
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex void vs(uint v [[vertex_id]], uint i [[instance_id]], uint bi [[base_instance]], device atomic_uint *o [[buffer(1)]])"
        " { atomic_fetch_max_explicit(&o[0], bi, memory_order_relaxed); atomic_fetch_max_explicit(&o[1], i, memory_order_relaxed);"
        "   atomic_fetch_add_explicit(&o[2], 1u, memory_order_relaxed); }\n";
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
    if (!lib) { printf("compile failed %s\n", e.localizedDescription.UTF8String); return; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.rasterizationEnabled = NO;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) { printf("pipeline failed %s\n", e.localizedDescription.UTF8String); return; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> ib = [dev newBufferWithLength:4096 options:0];
    memset(ib.contents, 0, 4096);
    id<MTLBuffer> out = [dev newBufferWithLength:64 options:0];
    for (int round = 0; round < 2; round++) {
        memset(out.contents, 0, 64);
        mark([NSString stringWithFormat:@"draw2 round %d", round]);
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps];
        [re setVertexBuffer:out offset:0 atIndex:1];
        if (round == 0)
            for (int j = 0; j < 8; j++) [re setViewport:(MTLViewport){ 1.1, 2.2, 3.3, 4.4, 0.0, 1.0 }];
        else
            [re drawIndexedPrimitives:MTLPrimitiveTypePoint indexCount:3 indexType:MTLIndexTypeUInt16
                          indexBuffer:ib indexBufferOffset:0 instanceCount:2 baseVertex:0 baseInstance:5];
        [re endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        uint32_t *o = out.contents;
        printf("draw2 round %d status %ld: max base_instance %u, max instance_id %u, invocations %u\n", round,
               (long)cb.status, o[0], o[1], o[2]);
    }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        g_mark = (void (*)(const char *))dlsym(RTLD_DEFAULT, "mslog_mark");
        g_keep = [NSMutableArray new];
        dev = MTLCreateSystemDefaultDevice();
        printf("device %s argumentBuffersSupport %lu\n", dev.name.UTF8String, (unsigned long)dev.argumentBuffersSupport);
        if (!dev) return 1;
        queue = [dev newCommandQueue];
        g_data = [dev newBufferWithLength:4096 options:0];
        printf("data buffer gpuAddress 0x%llx\n", g_data.gpuAddress);
        if (argc >= 3 && !strcmp(argv[1], "lib")) {
            doLib(argv[2], argc > 3 ? argv[3] : NULL, argc > 4 ? argv[4] : NULL, argc > 5 ? atoi(argv[5]) : -1);
            mark(@"end");
            return 0;
        }
        BOOL all = argc < 2;
        for (size_t i = 0; i < sizeof kLayouts / sizeof kLayouts[0]; i++) {
            BOOL want = all;
            for (int a = 1; a < argc; a++) if (!strcmp(argv[a], kLayouts[i].name)) want = YES;
            if (want) doLayout(&kLayouts[i]);
        }
        BOOL wantDesc = all;
        for (int a = 1; a < argc; a++) if (!strcmp(argv[a], "desc")) wantDesc = YES;
        if (wantDesc) {
            MTLBindingAccess RO = MTLBindingAccessReadOnly, RW = MTLBindingAccessReadWrite;
            doDescriptors("d-dense", @[ ad(MTLDataTypePointer, 0, 0, 0, RO), ad(MTLDataTypeTexture, 1, 0, MTLTextureType2D, RO),
                                        ad(MTLDataTypeSampler, 2, 0, 0, RO) ]);
            doDescriptors("d-weather", @[ ad(MTLDataTypePointer, 200, 0, 0, RO), ad(MTLDataTypePointer, 201, 0, 0, RO),
                                          ad(MTLDataTypeTexture, 230, 0, MTLTextureType2D, RO), ad(MTLDataTypeSampler, 231, 0, 0, RO) ]);
            doDescriptors("d-data", @[ ad(MTLDataTypePointer, 0, 0, 0, RW), ad(MTLDataTypeFloat4, 3, 0, 0, RO),
                                       ad(MTLDataTypeFloat, 4, 0, 0, RO), ad(MTLDataTypeTexture, 10, 4, MTLTextureType2D, RO) ]);
            doDescriptors("d-onefloat", @[ ad(MTLDataTypeFloat, 0, 0, 0, RO) ]);
            doDescriptors("d-half2", @[ ad(MTLDataTypeHalf, 0, 0, 0, RO), ad(MTLDataTypeHalf, 1, 0, 0, RO) ]);
            doDescriptors("d-gapfloat", @[ ad(MTLDataTypeFloat, 7, 0, 0, RO), ad(MTLDataTypePointer, 9, 0, 0, RO), ad(MTLDataTypeFloat, 12, 0, 0, RO) ]);
            doDescriptors("d-unsorted", @[ ad(MTLDataTypeTexture, 5, 0, MTLTextureType2D, RO), ad(MTLDataTypePointer, 0, 0, 0, RW),
                                           ad(MTLDataTypeSampler, 2, 3, 0, RO) ]);
        }
        for (int a = 1; a < argc; a++) if (!strcmp(argv[a], "draw")) doDraw();
        for (int a = 1; a < argc; a++) if (!strcmp(argv[a], "range")) doRange();
        for (int a = 1; a < argc; a++) if (!strcmp(argv[a], "draw2")) doDraw2();
        mark(@"end");
    }
    return 0;
}
