// Ycode translator tests (ours): one call of each texture function variant
// (sample, sample_compare, gather, read, write, queries) on each texture
// type, translated and validated (not run).
#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 position [[position]];
    float2 uv;
};

fragment float4 fs_sample_variants(VOut in [[stage_in]],
                                   texture2d<float> t2 [[texture(0)]],
                                   texture2d_array<float> t2a [[texture(1)]],
                                   texture3d<float> t3 [[texture(2)]],
                                   texturecube<float> tc [[texture(3)]],
                                   texturecube_array<float> tca [[texture(4)]],
                                   texture1d<float> t1 [[texture(5)]],
                                   texture1d_array<float> t1a [[texture(6)]],
                                   sampler s [[sampler(0)]])
{
    float4 r = t2.sample(s, in.uv);
    r += t2.sample(s, in.uv, int2(1, -1));
    r += t2.sample(s, in.uv, bias(1.0f));
    r += t2.sample(s, in.uv, level(2.0f));
    r += t2.sample(s, in.uv, gradient2d(float2(0.1f), float2(0.2f)));
    r += t2.sample(s, in.uv, min_lod_clamp(1.0f));
    r += t2a.sample(s, in.uv, 3u);
    r += t2a.sample(s, in.uv, 2u, level(1.0f));
    r += t3.sample(s, float3(in.uv, 0.5f));
    r += t3.sample(s, float3(in.uv, 0.5f), level(1.0f), int3(1, 0, 0));
    r += tc.sample(s, float3(in.uv, 1.0f));
    r += tc.sample(s, float3(in.uv, 1.0f), level(1.0f));
    r += tca.sample(s, float3(in.uv, 1.0f), 1u);
    r += t1.sample(s, in.uv.x);
    r += t1a.sample(s, in.uv.x, 1u);
    r += t2.gather(s, in.uv);
    r += t2.gather(s, in.uv, int2(0), component::y);
    return r;
}

fragment float4 fs_depth_variants(VOut in [[stage_in]],
                                  depth2d<float> d2 [[texture(0)]],
                                  depth2d_array<float> d2a [[texture(1)]],
                                  depthcube<float> dc [[texture(2)]],
                                  depth2d_ms<float> dms [[texture(3)]],
                                  sampler s [[sampler(0)]])
{
    constexpr sampler cmp(compare_func::less_equal, filter::linear);
    float r = d2.sample(s, in.uv);
    r += d2.sample_compare(cmp, in.uv, 0.5f);
    r += d2.sample_compare(cmp, in.uv, 0.5f, level(0.0f));
    r += d2a.sample_compare(cmp, in.uv, 1u, 0.5f);
    r += dc.sample_compare(cmp, float3(in.uv, 1.0f), 0.5f);
    r += d2.read(uint2(in.position.xy));
    r += dms.read(uint2(in.position.xy), 1u);
    float4 g = d2.gather_compare(cmp, in.uv, 0.5f);
    r += float(d2.get_width() + d2.get_num_mip_levels());
    return float4(r) + g;
}

kernel void k_read_write_variants(texture2d<float, access::read_write> rw [[texture(0)]],
                                  texture2d_array<half, access::write> wa [[texture(1)]],
                                  texture3d<int, access::read> r3 [[texture(2)]],
                                  texture2d_ms<float, access::read> ms [[texture(3)]],
                                  texture1d<uint, access::write> w1 [[texture(4)]],
                                  texturecube<float, access::read> rc [[texture(5)]],
                                  texture2d<ushort, access::write> w16 [[texture(6)]],
                                  texture2d_array<float, access::read> ra [[texture(7)]],
                                  texture2d<float> sampled [[texture(8)]],
                                  device float *out [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]])
{
    float4 c = rw.read(gid);
    rw.write(c * 2.0f, gid);
    wa.write(half4(c), gid, 2u);
    int4 i = r3.read(uint3(gid, 1u), 1u);
    float4 m = ms.read(gid, 2u);
    w1.write(uint4(gid.x), gid.x);
    float4 f = rc.read(gid, 3u);
    w16.write(ushort4(gid.xyxy), gid);
    float4 a = ra.read(gid, 1u);
    float4 sv = sampled.read(gid, 1u);
    out[gid.x] = c.x + float(i.y) + m.z + f.w + a.x + sv.y +
                 float(rw.get_width() + rw.get_height() + wa.get_array_size() + r3.get_depth() +
                       ms.get_num_samples() + sampled.get_num_mip_levels());
}

kernel void k_null_textures(texture2d<float> t [[texture(0)]],
                            texture3d<float> t3 [[texture(1)]],
                            device uint *out [[buffer(0)]],
                            uint gid [[thread_position_in_grid]])
{
    out[gid] = (is_null_texture(t) ? 1u : 0u) + (is_null_texture(t3) ? 2u : 0u);
}
