// Ycode R8 test shaders (ours): one function per feature the translator
// must handle. Written to exercise AIR intrinsics and metadata only.
#include <metal_stdlib>
using namespace metal;

struct VIn {
    float2 pos   [[attribute(0)]];
    float2 uv    [[attribute(1)]];
    half4  color [[attribute(2)]];
};

struct VOut {
    float4 position [[position]];
    float2 uv;
    half4  color;
    float  pointSize [[point_size]];
};

struct Uniforms {
    float4x4 mvp;
    float    opacity;
};

vertex VOut vs_main(VIn in [[stage_in]],
                    constant Uniforms &u [[buffer(1)]],
                    uint vid [[vertex_id]],
                    uint iid [[instance_id]])
{
    VOut o;
    o.position = u.mvp * float4(in.pos, float(iid) * 0.0f, 1.0f);
    o.uv = in.uv;
    o.color = in.color * half(u.opacity);
    o.pointSize = 1.0f + float(vid & 1u);
    return o;
}

struct FOut {
    half4 c0 [[color(0)]];
    float4 c1 [[color(1)]];
};

fragment FOut fs_main(VOut in [[stage_in]],
                      texture2d<half> tex [[texture(0)]],
                      sampler s [[sampler(0)]],
                      constant float4 &tint [[buffer(0)]],
                      bool front [[front_facing]])
{
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    FOut o;
    half4 t = tex.sample(s, in.uv) + tex.sample(lin, in.uv, level(0.0f));
    o.c0 = t * in.color;
    o.c1 = front ? tint : float4(in.position.xy, 0, 1);
    return o;
}

fragment float4 fs_discard(VOut in [[stage_in]],
                           texture2d<float, access::read> src [[texture(0)]],
                           depth2d<float> shadow [[texture(1)]],
                           sampler cmp [[sampler(1)]])
{
    float4 c = src.read(uint2(in.position.xy));
    float d = shadow.sample_compare(cmp, in.uv, 0.5f);
    if (c.a < 0.01f) discard_fragment();
    return c * d;
}

kernel void reduce_tg(device const float *in   [[buffer(0)]],
                      device atomic_uint *hist [[buffer(1)]],
                      device float *out        [[buffer(2)]],
                      threadgroup float *scratch [[threadgroup(0)]],
                      uint tid  [[thread_index_in_threadgroup]],
                      uint3 gid [[thread_position_in_grid]],
                      uint3 tgid [[threadgroup_position_in_grid]],
                      uint lane [[thread_index_in_simdgroup]],
                      uint sg   [[simdgroup_index_in_threadgroup]])
{
    float v = in[gid.x];
    float s = simd_sum(v);
    float sh = simd_shuffle_down(v, 1);
    if (lane == 0) scratch[sg] = s + sh * 0.0f;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        out[tgid.x] = scratch[0] + fast::exp(scratch[0]) * 0.0f + precise::sqrt(abs(scratch[0])) * 0.0f;
        atomic_fetch_add_explicit(&hist[0], 1u, memory_order_relaxed);
    }
}

kernel void tex_kernel(texture2d<float, access::read_write> img [[texture(0)]],
                       texture2d_array<half, access::sample> arr [[texture(1)]],
                       texturecube<float> cube [[texture(2)]],
                       uint2 gid [[thread_position_in_grid]])
{
    constexpr sampler s(coord::normalized, filter::nearest);
    float4 c = img.read(gid);
    c += float4(arr.sample(s, float2(0.5), 0)) + cube.sample(s, float3(0, 0, 1));
    img.write(clamp(c, 0.0f, 1.0f), gid);
}

struct ArgBuf {
    texture2d<float> t [[id(0)]];
    sampler s           [[id(1)]];
    device float *data  [[id(2)]];
};

fragment float4 fs_argbuf(VOut in [[stage_in]],
                          constant ArgBuf &ab [[buffer(2)]])
{
    return ab.t.sample(ab.s, in.uv) * ab.data[0];
}
