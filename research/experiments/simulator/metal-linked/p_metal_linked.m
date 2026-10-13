/* p_metal_linked: Ycode stage-8 test probe (original Ycode code).
 *
 * Two compute dispatches that use Metal's function-linking features, to see
 * what reaches the simulator's Metal host and to check results:
 *   1. through_table: a kernel calls [[visible]] functions through a visible
 *      function table (pipeline function handles, setVisibleFunctionTable).
 *   2. through_link: a kernel calls an external [[visible]] function that is
 *      supplied at pipeline creation (MTLLinkedFunctions).
 * Expected: out1[i] = (0.5,0,0,1) for even i, (0,0,0.75,1) for odd i;
 * out2[i] = 3i + 1.
 *
 * Usage: p_metal_linked [METALLIB]   (default, or when the argument does not
 * name a .metallib: p_metal_linked.metallib next to the executable)
 * Prints "linked ok" or "linked FAIL: ..." (and which part failed).
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>

#define N 64

static void step(const char *s) {
    printf("p_metal_linked: %s\n", s);
    fflush(stdout);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *libPath;
        if (argc > 1 && strstr(argv[1], ".metallib")) {
            libPath = [NSString stringWithUTF8String:argv[1]];
        } else {
            char exe[1024];
            uint32_t n = sizeof exe;
            if (_NSGetExecutablePath(exe, &n) != 0) strcpy(exe, argv[0]);
            libPath = [[[NSString stringWithUTF8String:exe] stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:@"p_metal_linked.metallib"];
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { printf("linked FAIL: no device\n"); return 1; }
        printf("p_metal_linked: device \"%s\", function pointers %d\n", device.name.UTF8String, (int)device.supportsFunctionPointers);
        NSError *error = nil;
        id<MTLLibrary> lib = [device newLibraryWithURL:[NSURL fileURLWithPath:libPath] error:&error];
        if (!lib) { printf("linked FAIL: library: %s\n", error.description.UTF8String); return 1; }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        int failures = 0;

        /* 1. Visible function table (needs function pointers; the simulator
         * device reports none and aborts in functionHandleWithFunction:). */
        if (!device.supportsFunctionPointers) {
            step("table part skipped: no function pointers");
        } else {
            id<MTLFunction> kernelFn = [lib newFunctionWithName:@"through_table"];
            id<MTLFunction> red = [lib newFunctionWithName:@"keep_red"];
            id<MTLFunction> blue = [lib newFunctionWithName:@"keep_blue"];
            MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];
            d.computeFunction = kernelFn;
            MTLLinkedFunctions *lf = [MTLLinkedFunctions linkedFunctions];
            lf.functions = @[red, blue];
            d.linkedFunctions = lf;
            id<MTLComputePipelineState> ps = [device newComputePipelineStateWithDescriptor:d options:0 reflection:nil error:&error];
            if (!ps) {
                printf("p_metal_linked: table pipeline failed: %s\n", error.description.UTF8String);
                failures++;
            } else {
                step("table pipeline created");
                MTLVisibleFunctionTableDescriptor *td = [MTLVisibleFunctionTableDescriptor visibleFunctionTableDescriptor];
                td.functionCount = 2;
                id<MTLVisibleFunctionTable> table = [ps newVisibleFunctionTableWithDescriptor:td];
                [table setFunction:[ps functionHandleWithFunction:red] atIndex:0];
                [table setFunction:[ps functionHandleWithFunction:blue] atIndex:1];
                id<MTLBuffer> out = [device newBufferWithLength:N * 16 options:MTLResourceStorageModeShared];
                memset(out.contents, 0xEE, N * 16);
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:ps];
                [e setBuffer:out offset:0 atIndex:0];
                [e setVisibleFunctionTable:table atBufferIndex:1];
                [e dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
                [e endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                const float *v = out.contents;
                int bad = 0;
                for (int i = 0; i < N; i++) {
                    float er = (i % 2) ? 0 : 0.5f, eb = (i % 2) ? 0.75f : 0;
                    if (v[i * 4] != er || v[i * 4 + 1] != 0 || v[i * 4 + 2] != eb || v[i * 4 + 3] != 1) bad++;
                }
                printf("p_metal_linked: table: status %ld, out[0]=(%g,%g,%g,%g) out[1]=(%g,%g,%g,%g), %d wrong\n", (long)cb.status,
                       v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], bad);
                if (bad) failures++;
            }
        }

        /* 2. A linked external function. */
        {
            id<MTLFunction> kernelFn = [lib newFunctionWithName:@"through_link"];
            id<MTLFunction> impl = [lib newFunctionWithName:@"scale_value"];
            MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];
            d.computeFunction = kernelFn;
            MTLLinkedFunctions *lf = [MTLLinkedFunctions linkedFunctions];
            lf.functions = @[impl];
            d.linkedFunctions = lf;
            id<MTLComputePipelineState> ps = [device newComputePipelineStateWithDescriptor:d options:0 reflection:nil error:&error];
            if (!ps) {
                printf("p_metal_linked: link pipeline failed: %s\n", error.description.UTF8String);
                failures++;
            } else {
                step("link pipeline created");
                id<MTLBuffer> out = [device newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
                memset(out.contents, 0xEE, N * 4);
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:ps];
                [e setBuffer:out offset:0 atIndex:0];
                [e dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
                [e endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                const float *v = out.contents;
                int bad = 0;
                for (int i = 0; i < N; i++) if (v[i] != 3.0f * i + 1.0f) bad++;
                printf("p_metal_linked: link: status %ld, out[0..3]=%g %g %g %g, %d wrong\n", (long)cb.status, v[0], v[1], v[2], v[3], bad);
                if (bad) failures++;
            }
        }
        if (failures) { printf("linked FAIL: %d part(s)\n", failures); return 1; }
        printf("linked ok\n");
        return 0;
    }
}
