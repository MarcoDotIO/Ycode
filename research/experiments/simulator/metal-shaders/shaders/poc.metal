// Ycode R8 proof-of-concept kernels (ours). Translated from AIR to SPIR-V
// by airc and run on the Thor by vkrun. Both compute out = a + b.
#include <metal_stdlib>
using namespace metal;

kernel void add_arrays(device const float *a [[buffer(0)]],
                       device const float *b [[buffer(1)]],
                       device float *out     [[buffer(2)]],
                       constant uint &count  [[buffer(3)]],
                       uint gid [[thread_position_in_grid]])
{
    if (gid < count)
        out[gid] = a[gid] + b[gid];
}

// A grid-stride loop: exercises loops, phis, a math intrinsic, and the
// threads_per_grid built-in (the exact dispatchThreads grid size).
kernel void add_strided(device const float *a [[buffer(0)]],
                        device const float *b [[buffer(1)]],
                        device float *out     [[buffer(2)]],
                        constant uint &count  [[buffer(3)]],
                        uint gid     [[thread_position_in_grid]],
                        uint threads [[threads_per_grid]])
{
    for (uint i = gid; i < count; i += threads)
        out[i] = fmax(a[i] + b[i], 0.0f);
}
