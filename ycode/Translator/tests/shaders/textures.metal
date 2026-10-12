// Ycode translator tests (ours): texture reads, writes, sampling and
// queries from compute kernels, so tests/gpu/airc-gpu.c can check them
// without a render pass. Texture 0 is a 16 x 16 RGBA32F texture whose
// texel (x, y) is (x, y, x + y, 1) / 16; texture 1 is a 16 x 16 RGBA32F
// storage texture; texture 2 a 16 x 16 R32Uint texture of x * 16 + y;
// texture 3 a 4 x 4 x 4 RGBA8Unorm 3D texture.
#include <metal_stdlib>
using namespace metal;

// One thread per texel of a 16 x 16 grid.
kernel void t_tex_rw(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]])
{
    float4 c = src.read(gid);
    dst.write(c.wzyx * 2.0f, gid);
}

// K = 4: sampling at texel centres with a constexpr sampler (nearest and
// linear, explicit level), size queries, a null-texture check.
kernel void t_tex_sample(device float *out [[buffer(0)]],
                         texture2d<float> tex [[texture(0)]],
                         texture2d<float> missing [[texture(5)]],
                         sampler s [[sampler(0)]],
                         uint gid [[thread_position_in_grid]])
{
    constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);
    uint x = gid & 15u, y = gid >> 4;
    float2 uv = (float2(x, y) + 0.5f) / 16.0f;
    float4 a = tex.sample(nearest, uv, level(0.0f));
    float4 b = tex.sample(s, uv + float2(0.5f / 16.0f, 0.0f), level(0.0f));
    device float *o = out + gid * 4;
    o[0] = a.x + a.y * 16.0f;
    o[1] = b.x;
    o[2] = float(tex.get_width() * 100u + tex.get_height());
    o[3] = is_null_texture(missing) ? 1.0f : 0.0f;
}

// K = 1: integer textures, read-write access.
kernel void t_tex_uint(device uint *out [[buffer(0)]],
                       texture2d<uint, access::read_write> img [[texture(2)]],
                       uint gid [[thread_position_in_grid]])
{
    uint2 p = uint2(gid & 15u, gid >> 4);
    uint v = img.read(p).x;
    img.write(uint4(v + 1000u), p);
    out[gid] = v;
}

// K = 4: 3D texture sampling and reading.
kernel void t_tex_3d(device float *out [[buffer(0)]],
                     texture3d<float> vol [[texture(3)]],
                     uint gid [[thread_position_in_grid]])
{
    constexpr sampler s(filter::nearest);
    uint3 p = uint3(gid & 3u, (gid >> 2) & 3u, (gid >> 4) & 3u);
    float4 a = vol.sample(s, (float3(p) + 0.5f) / 4.0f);
    float4 b = vol.read(p);
    device float *o = out + gid * 4;
    o[0] = a.x;
    o[1] = a.y;
    o[2] = b.z;
    o[3] = float(vol.get_depth());
}

// K = 1: packing and unpacking.
kernel void t_pack(device uint *out [[buffer(0)]], uint gid [[thread_position_in_grid]])
{
    float4 c = unpack_unorm4x8_to_float(gid * 0x01020304u);
    out[gid] = pack_float_to_unorm4x8(c.wzyx) + uint(pack_float_to_unorm565(c.xyz));
}

// K = 1: an argument buffer holding a texture, a sampler and a buffer
// address (written by the CPU: resource IDs and GPU addresses).
struct ArgBufK {
    texture2d<float> t [[id(0)]];
    sampler s          [[id(1)]];
    device float *data [[id(2)]];
};

kernel void t_argbuf(device float *out [[buffer(0)]],
                     constant ArgBufK &ab [[buffer(1)]],
                     uint gid [[thread_position_in_grid]])
{
    float2 uv = (float2(gid & 15u, gid >> 4) + 0.5f) / 16.0f;
    out[gid] = ab.t.sample(ab.s, uv, level(0.0f)).x * 10.0f + ab.data[gid];
}
