// Ycode translator tests (ours): threadgroup memory, barriers, SIMD-group
// and quad-group operations, atomics. Run with threadgroups of 64 threads
// (tests/gpu/airc-gpu.c); SIMD groups have 32 threads on the Thor, as on
// Apple GPUs.
#include <metal_stdlib>
using namespace metal;

// K = 2: a reduction through a static threadgroup array.
kernel void t_tg_static(device uint *out [[buffer(0)]],
                        uint gid [[thread_position_in_grid]],
                        uint tid [[thread_index_in_threadgroup]],
                        uint tgx [[threadgroup_position_in_grid]])
{
    threadgroup uint shared[64];
    shared[tid] = gid * 3u + 1u;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = 32; s > 0; s >>= 1) {
        if (tid < s) shared[tid] += shared[tid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    out[gid * 2] = shared[0];
    out[gid * 2 + 1] = shared[(tid + 1u) & 63u] + tgx;
}

// K = 1: a dynamic threadgroup buffer ([[threadgroup(0)]], 64 floats and
// [[threadgroup(1)]], 64 halves), whose length the dispatch sets.
kernel void t_tg_dynamic(device float *out [[buffer(0)]],
                         threadgroup float *a [[threadgroup(0)]],
                         threadgroup half *b [[threadgroup(1)]],
                         uint gid [[thread_position_in_grid]],
                         uint tid [[thread_index_in_threadgroup]],
                         uint n [[threads_per_threadgroup]])
{
    a[tid] = float(gid) * 0.5f;
    b[tid] = half(tid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    out[gid] = a[(tid + 1u) % n] + float(b[n - 1u - tid]);
}

// K = 4: SIMD-group reductions and shuffles, quad shuffles.
kernel void t_simd(device uint *out [[buffer(0)]],
                   uint gid [[thread_position_in_grid]],
                   uint lane [[thread_index_in_simdgroup]],
                   uint sg [[simdgroup_index_in_threadgroup]],
                   uint width [[threads_per_simdgroup]])
{
    uint v = gid * 7u + 1u;
    device uint *o = out + gid * 4;
    o[0] = simd_sum(v);
    o[1] = simd_shuffle_and_fill_down(v, v + 1000u, 3);
    o[2] = quad_shuffle_xor(v, 1);
    o[3] = simd_shuffle_down(v, 1) + sg * 100000u + width * 1000000u + simd_max(lane);
}

// K = 1 per thread plus 4 counters: device and threadgroup atomics.
kernel void t_atomic(device uint *out [[buffer(0)]],
                     device atomic_uint *counters [[buffer(1)]],
                     uint gid [[thread_position_in_grid]],
                     uint tid [[thread_index_in_threadgroup]])
{
    threadgroup atomic_uint local;
    if (tid == 0) atomic_store_explicit(&local, 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    atomic_fetch_add_explicit(&local, gid & 3u, memory_order_relaxed);
    atomic_fetch_add_explicit(&counters[0], 1u, memory_order_relaxed);
    atomic_fetch_max_explicit(&counters[1], gid, memory_order_relaxed);
    atomic_fetch_or_explicit(&counters[2], 1u << (gid & 31u), memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    out[gid] = atomic_load_explicit(&local, memory_order_relaxed);
}

// K = 1: device memory barrier between two phases of the same threadgroup.
kernel void t_device_barrier(device uint *out [[buffer(0)]],
                             device uint *scratch [[buffer(1)]],
                             uint gid [[thread_position_in_grid]],
                             uint tid [[thread_index_in_threadgroup]],
                             uint tgx [[threadgroup_position_in_grid]])
{
    scratch[gid] = gid * gid;
    threadgroup_barrier(mem_flags::mem_device);
    uint base = tgx * 64u;
    out[gid] = scratch[base + ((tid + 5u) & 63u)];
}
