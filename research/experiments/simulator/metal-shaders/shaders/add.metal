// Ycode R8 test shader (ours): element-wise add of two float buffers.
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
