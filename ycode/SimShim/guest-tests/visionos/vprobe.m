// vprobe: the guest's view of its visionOS device and Metal device
// (specs/simulator/visionos.md §3.4, §4.5; round R1 of §7.2). Ycode's own
// probe, built for the visionOS simulator platform (build-visionos.sh) and
// run under Ycode as a one-shot: `vprobe [delay s]`. It prints UIDevice
// values and the MTLDevice properties that visionos.md §4.5 lists for the
// reference, so the two can be compared line by line.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#include <unistd.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);  // a probe killed later keeps what it printed
        int delay = argc > 1 ? atoi(argv[1]) : 0;
        if (delay > 0) sleep((unsigned)delay);
        printf("vprobe: start\n");
        id<MTLDevice> m = MTLCreateSystemDefaultDevice();
        printf("vprobe: device created\n");
        if (!m) {
            printf("MTLCreateSystemDefaultDevice: nil\n");
            return 1;
        }
        printf("name=%s registryID=0x%llx\n", m.name.UTF8String, (unsigned long long)m.registryID);
        struct { MTLGPUFamily f; const char *n; } fams[] = {
            {MTLGPUFamilyApple1, "Apple1"}, {MTLGPUFamilyApple2, "Apple2"}, {MTLGPUFamilyApple3, "Apple3"},
            {MTLGPUFamilyApple4, "Apple4"}, {MTLGPUFamilyApple5, "Apple5"}, {MTLGPUFamilyApple6, "Apple6"},
            {MTLGPUFamilyApple7, "Apple7"}, {MTLGPUFamilyApple8, "Apple8"}, {MTLGPUFamilyCommon1, "Common1"},
            {MTLGPUFamilyCommon2, "Common2"}, {MTLGPUFamilyCommon3, "Common3"}, {MTLGPUFamilyMetal3, "Metal3"},
        };
        printf("supportsFamily:");
        for (size_t i = 0; i < sizeof fams / sizeof fams[0]; i++) printf(" %s=%d", fams[i].n, [m supportsFamily:fams[i].f]);
        printf("\n");
        MTLSize t = m.maxThreadsPerThreadgroup;
        printf("maxThreadsPerThreadgroup=%lux%lux%lu maxThreadgroupMemoryLength=%lu maxBufferLength=%lu\n",
               (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.depth,
               (unsigned long)m.maxThreadgroupMemoryLength, (unsigned long)m.maxBufferLength);
        printf("hasUnifiedMemory=%d recommendedMaxWorkingSetSize=%llu currentAllocatedSize=%lu\n", m.hasUnifiedMemory,
               (unsigned long long)m.recommendedMaxWorkingSetSize, (unsigned long)m.currentAllocatedSize);
        printf("argumentBuffersSupport=%lu readWriteTextureSupport=%lu supportsRaytracing=%d supportsFunctionPointers=%d\n",
               (unsigned long)m.argumentBuffersSupport, (unsigned long)m.readWriteTextureSupport, m.supportsRaytracing,
               m.supportsFunctionPointers);
        printf("vertexAmplification1=%d vertexAmplification2=%d rasterizationRateMap1=%d\n",
               [m supportsVertexAmplificationCount:1], [m supportsVertexAmplificationCount:2],
               [m supportsRasterizationRateMapWithLayerCount:1]);
        printf("sampleCount:");
        for (NSUInteger s = 1; s <= 8; s *= 2) printf(" %lu=%d", (unsigned long)s, [m supportsTextureSampleCount:s]);
        printf("\n");
        printf("BCformats=%d 32bitFloatFiltering=%d\n", m.supportsBCTextureCompression, m.supports32BitFloatFiltering);
        // A private heap and a texture from it (ops 20-22, metal-sim-protocol.md §4.2).
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                      width:256 height:256 mipmapped:YES];
        td.storageMode = MTLStorageModePrivate;
        MTLSizeAndAlign sa = [m heapTextureSizeAndAlignWithDescriptor:td];
        printf("heapTextureSizeAndAlign 256x256 RGBA8 mipmapped: size=%lu align=%lu\n", (unsigned long)sa.size,
               (unsigned long)sa.align);
        MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
        hd.size = sa.size * 4;
        hd.storageMode = MTLStorageModePrivate;
        id<MTLHeap> heap = [m newHeapWithDescriptor:hd];
        id<MTLTexture> ht = [heap newTextureWithDescriptor:td];
        printf("heap=%s size=%lu used=%lu texture=%s maxAvailable(256)=%lu\n", heap ? "yes" : "nil", (unsigned long)heap.size,
               (unsigned long)heap.usedSize, ht ? "yes" : "nil", (unsigned long)[heap maxAvailableSizeWithAlignment:256]);
        id<MTLBuffer> b = [m newBufferWithLength:16384 options:MTLResourceStorageModeShared];
        printf("shared buffer 16 KiB=%s contents=%s gpuAddress=0x%llx\n", b ? "yes" : "nil", b.contents ? "yes" : "nil",
               (unsigned long long)b.gpuAddress);
        id<MTLSharedEvent> ev = [m newSharedEvent];
        id<MTLFence> fence = [m newFence];
        id<MTLCommandQueue> q = [m newCommandQueue];
        printf("sharedEvent=%s fence=%s queue=%s\n", ev ? "yes" : "nil", fence ? "yes" : "nil", q ? "yes" : "nil");
        // Last: UIDevice may wait for system services (backboardd) under a partial boot.
        UIDevice *d = UIDevice.currentDevice;
        printf("UIDevice model=%s systemName=%s systemVersion=%s idiom=%ld\n", d.model.UTF8String, d.systemName.UTF8String,
               d.systemVersion.UTF8String, (long)d.userInterfaceIdiom);
        fflush(stdout);
    }
    return 0;
}
