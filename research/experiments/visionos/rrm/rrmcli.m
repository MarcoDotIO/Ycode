// rrmcli (our own code, OBS-VISION-RRM 2026-11-01, dirty room): what the visionOS simulator's Metal device
// answers about rasterization rate maps, and whether the answer involves the host.
// Run with `simctl spawn <dev> <path>/rrmcli [-make] [-render]`. Prints "RC:" lines.
//  1. device name/class; for each rate-map selector: responds?, the class that defines it, the image of its IMP.
//  2. supportsRasterizationRateMapWithLayerCount: 0..4 (and the private-looking maxRasterizationRateLayerCount /
//     supportsVariableRateRasterization when the device responds), with the Mach messages this task sent
//     during 1000 calls (task_info TASK_EVENTS_INFO), so a host round trip would show.
//  3. -make: newRasterizationRateMapWithDescriptor: with a 5x3-zone single-layer descriptor (screen 3840x2160) and
//     a two-layer one; logs the result and, when non-nil, its sizes, granularity, parameter buffer size and mappings.
//  4. -render: if a map exists, a render pass with it (clear + full-screen triangle) into a texture of the physical size.
//  5. compiles a fragment shader that uses rasterization_rate_map_decoder (always; logs success/error).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <mach/mach.h>

static void rc(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void rc(NSString *fmt, ...) { va_list ap; va_start(ap, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap); printf("RC: %s\n", s.UTF8String); fflush(stdout); }
static uint64_t msgsSent(void) {
    task_events_info_data_t e; mach_msg_type_number_t n = TASK_EVENTS_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_EVENTS_INFO, (task_info_t)&e, &n) != KERN_SUCCESS) return 0;
    return (uint64_t)e.messages_sent;
}
static NSString *definer(Class c, SEL s) {
    for (Class k = c; k; k = class_getSuperclass(k)) {
        unsigned n = 0; Method *ms = class_copyMethodList(k, &n); BOOL has = NO;
        for (unsigned i = 0; i < n; i++) if (method_getName(ms[i]) == s) { has = YES; break; }
        free(ms); if (has) return @(class_getName(k));
    }
    return @"(none)";
}
static NSString *imageOf(Class c, SEL s) {
    Method m = class_getInstanceMethod(c, s); if (!m) return @"-";
    Dl_info i; if (dladdr((const void *)method_getImplementation(m), &i) && i.dli_fname) return [@(i.dli_fname) lastPathComponent];
    return @"?";
}
static void describeMap(id<MTLRasterizationRateMap> m, NSString *tag) {
    rc(@"%@ map %@ class %s screenSize %lux%lu layerCount %lu physicalGranularity %lux%lu", tag, m, object_getClassName(m),
       (unsigned long)m.screenSize.width, (unsigned long)m.screenSize.height, (unsigned long)m.layerCount,
       (unsigned long)m.physicalGranularity.width, (unsigned long)m.physicalGranularity.height);
    MTLSizeAndAlign sa = m.parameterBufferSizeAndAlign;
    rc(@"%@ parameterBuffer size %lu align %lu", tag, (unsigned long)sa.size, (unsigned long)sa.align);
    for (NSUInteger l = 0; l < m.layerCount; l++) {
        MTLSize p = [m physicalSizeForLayer:l];
        rc(@"%@ layer %lu physicalSize %lux%lu", tag, (unsigned long)l, (unsigned long)p.width, (unsigned long)p.height);
        float pts[][2] = {{0, 0}, {960, 540}, {1920, 1080}, {2880, 1620}, {3840, 2160}};
        for (int i = 0; i < 5; i++) {
            MTLCoordinate2D s = MTLCoordinate2DMake(pts[i][0], pts[i][1]);
            MTLCoordinate2D ph = [m mapScreenToPhysicalCoordinates:s forLayer:l];
            MTLCoordinate2D back = [m mapPhysicalToScreenCoordinates:ph forLayer:l];
            rc(@"%@ layer %lu screen (%.0f, %.0f) -> physical (%.1f, %.1f) -> screen (%.1f, %.1f)", tag, (unsigned long)l, s.x, s.y, ph.x, ph.y, back.x, back.y);
        }
    }
}
static MTLRasterizationRateLayerDescriptor *layer53(void) {
    float h[5] = {0.25f, 0.5f, 1.0f, 0.5f, 0.25f}, v[3] = {0.5f, 1.0f, 0.5f};
    MTLRasterizationRateLayerDescriptor *l = [[MTLRasterizationRateLayerDescriptor alloc] initWithSampleCount:MTLSizeMake(5, 3, 0) horizontal:h vertical:v];
    return l;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL make = NO, render = NO;
        for (int i = 1; i < argc; i++) { if (!strcmp(argv[i], "-make")) make = YES; if (!strcmp(argv[i], "-render")) make = render = YES; }
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d) { rc(@"no device"); return 1; }
        Class dc = object_getClass(d);
        rc(@"device \"%@\" class %s registryID 0x%llx", d.name, class_getName(dc), d.registryID);
        const char *sels[] = {"supportsRasterizationRateMapWithLayerCount:", "newRasterizationRateMapWithDescriptor:", "maxRasterizationRateLayerCount",
                              "supportsVariableRateRasterization", "supportsFamily:", "supportsVertexAmplificationCount:"};
        for (unsigned i = 0; i < sizeof sels / sizeof *sels; i++) {
            SEL s = sel_registerName(sels[i]);
            rc(@"selector %s responds %d definedBy %@ impImage %@", sels[i], [d respondsToSelector:s], definer(dc, s), imageOf(dc, s));
        }
        for (NSUInteger n = 0; n <= 4; n++) {
            uint64_t m0 = msgsSent(); BOOL r = NO;
            for (int k = 0; k < 1000; k++) r = [d supportsRasterizationRateMapWithLayerCount:n];
            uint64_t m1 = msgsSent();
            rc(@"supportsRasterizationRateMapWithLayerCount:%lu = %d (mach messages sent during 1000 calls: %llu)", (unsigned long)n, r, m1 - m0);
        }
        if ([d respondsToSelector:@selector(maxRasterizationRateLayerCount)]) {
            NSUInteger v = ((NSUInteger(*)(id, SEL))objc_msgSend)(d, @selector(maxRasterizationRateLayerCount));
            rc(@"maxRasterizationRateLayerCount = %lu", (unsigned long)v);
        }
        SEL svr = sel_registerName("supportsVariableRateRasterization");
        if ([d respondsToSelector:svr]) rc(@"supportsVariableRateRasterization = %d", ((BOOL(*)(id, SEL))objc_msgSend)(d, svr));
        uint64_t m0 = msgsSent(); BOOL v2 = [d supportsVertexAmplificationCount:2];
        rc(@"supportsVertexAmplificationCount:2 = %d (messages %llu)", v2, msgsSent() - m0);
        rc(@"supportsFamily Apple1 %d Apple2 %d Apple4 %d Apple5 %d Apple6 %d Apple7 %d Mac2 %d Common1 %d Common2 %d Common3 %d Metal3 %d",
           [d supportsFamily:MTLGPUFamilyApple1], [d supportsFamily:MTLGPUFamilyApple2], [d supportsFamily:MTLGPUFamilyApple4], [d supportsFamily:MTLGPUFamilyApple5],
           [d supportsFamily:MTLGPUFamilyApple6], [d supportsFamily:MTLGPUFamilyApple7], [d supportsFamily:MTLGPUFamilyMac2], [d supportsFamily:MTLGPUFamilyCommon1],
           [d supportsFamily:MTLGPUFamilyCommon2], [d supportsFamily:MTLGPUFamilyCommon3], [d supportsFamily:MTLGPUFamilyMetal3]);

        // shader-side decoder
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                         "fragment float4 fsrrm(float4 p [[position]], constant rasterization_rate_map_data &m [[buffer(0)]]) {\n"
                         "  rasterization_rate_map_decoder dec(m); float2 s = dec.map_physical_to_screen_coordinates(p.xy); return float4(s / 4096.0, 0, 1); }\n";
        NSError *err = nil; uint64_t c0 = msgsSent();
        id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
        rc(@"compile rasterization_rate_map_decoder shader: %@ (error %@; messages %llu)", lib ? @"ok" : @"failed", err.localizedDescription ?: @"none", msgsSent() - c0);
        if (lib) {
            id<MTLFunction> f = [lib newFunctionWithName:@"fsrrm"];
            rc(@"function fsrrm %@", f ? @"ok" : @"nil");
        }
        if (!make) return 0;

        MTLRasterizationRateMapDescriptor *md = [MTLRasterizationRateMapDescriptor rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(3840, 2160, 0) layer:layer53()];
        md.label = @"rrmcli 5x3";
        uint64_t k0 = msgsSent(); id<MTLRasterizationRateMap> map = nil;
        @try { map = [d newRasterizationRateMapWithDescriptor:md]; }
        @catch (NSException *e) { rc(@"newRasterizationRateMapWithDescriptor: exception %@ %@", e.name, e.reason); }
        rc(@"newRasterizationRateMapWithDescriptor: (1 layer, 5x3 zones) -> %@ (messages %llu)", map ? @"object" : @"nil", msgsSent() - k0);
        if (map) describeMap(map, @"L1");
        MTLRasterizationRateMapDescriptor *md2 = [MTLRasterizationRateMapDescriptor rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(3840, 2160, 0)];
        [md2 setLayer:layer53() atIndex:0]; [md2 setLayer:layer53() atIndex:1];
        id<MTLRasterizationRateMap> map2 = nil;
        @try { map2 = [d newRasterizationRateMapWithDescriptor:md2]; }
        @catch (NSException *e) { rc(@"two-layer exception %@ %@", e.name, e.reason); }
        rc(@"newRasterizationRateMapWithDescriptor: (2 layers) -> %@", map2 ? @"object" : @"nil");
        if (map2) describeMap(map2, @"L2");
        if (!render || !map) return 0;

        MTLSize ps = [map physicalSizeForLayer:0];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:ps.width height:ps.height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [d newTextureWithDescriptor:td];
        id<MTLCommandQueue> q = [d newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0.5, 0, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.rasterizationRateMap = map;
        rc(@"render pass class %s rasterizationRateMap set -> %@", object_getClassName(rp), rp.rasterizationRateMap);
        id<MTLRenderCommandEncoder> enc = nil;
        @try { enc = [cb renderCommandEncoderWithDescriptor:rp]; } @catch (NSException *e) { rc(@"encoder exception %@ %@", e.name, e.reason); }
        rc(@"encoder %@", enc ? @"ok" : @"nil");
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        rc(@"command buffer status %lu error %@", (unsigned long)cb.status, cb.error);
    }
    return 0;
}
