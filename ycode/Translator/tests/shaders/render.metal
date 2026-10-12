// Ycode translator tests (ours): vertex and fragment functions. draw_vs
// and draw_fs are drawn by tests/gpu/airc-gpu.c; the others are
// translated and validated.
#include <metal_stdlib>
using namespace metal;

struct VIn {
    float2 pos   [[attribute(0)]];
    half4  color [[attribute(1)]];
};

struct VOut {
    float4 position [[position]];
    float2 uv;
    half4  color;
};

struct Xform {
    float2 scale;
    float2 offset;
};

// The R8 render pipeline: stage-in attributes, a constant buffer, two
// varyings matched by name, a sampled texture, a half4 colour.
vertex VOut draw_vs(VIn in [[stage_in]], constant Xform &x [[buffer(1)]])
{
    VOut o;
    float2 p = in.pos * x.scale + x.offset;
    o.position = float4(p, 0.0f, 1.0f);
    o.uv = float2(p.x * 0.5f + 0.5f, 0.5f - p.y * 0.5f);
    o.color = in.color;
    return o;
}

fragment half4 draw_fs(VOut in [[stage_in]],
                       texture2d<half> tex [[texture(0)]],
                       sampler smp [[sampler(0)]])
{
    return tex.sample(smp, in.uv) * in.color;
}

// Varyings declared in a different order than the vertex function writes
// them; matched by name.
struct VOutSwapped {
    half4  color;
    float4 position [[position]];
    float2 uv;
};

fragment float4 draw_fs_swapped(VOutSwapped in [[stage_in]])
{
    return float4(in.uv, 0.0f, 1.0f) * float4(in.color);
}

// Vertex ID, instance ID, a matrix in a constant buffer, point size,
// several outputs including a flat integer.
struct Uniforms {
    float4x4 mvp;
    float    opacity;
};

struct VOut2 {
    float4 position [[position]];
    float2 uv;
    half4  color;
    uint   layerTag [[flat]];
    float  size [[point_size]];
};

vertex VOut2 vs_full(VIn in [[stage_in]],
                     constant Uniforms &u [[buffer(1)]],
                     device const float2 *offsets [[buffer(2)]],
                     uint vid [[vertex_id]],
                     uint iid [[instance_id]])
{
    VOut2 o;
    o.position = u.mvp * float4(in.pos + offsets[iid], 0.0f, 1.0f);
    o.uv = in.pos * 0.5f + 0.5f;
    o.color = in.color * half(u.opacity);
    o.layerTag = iid * 4u + (vid & 3u);
    o.size = 1.0f + float(vid & 1u);
    return o;
}

// Without stage_in: positions from a buffer by vertex ID.
vertex float4 vs_buffer(device const float4 *verts [[buffer(0)]], uint vid [[vertex_id]])
{
    return verts[vid];
}

// Two render targets, front facing, a constexpr sampler, a constant
// buffer.
struct FOut {
    half4  c0 [[color(0)]];
    float4 c1 [[color(1)]];
};

fragment FOut fs_mrt(VOut2 in [[stage_in]],
                     texture2d<half> tex [[texture(0)]],
                     sampler s [[sampler(0)]],
                     constant float4 &tint [[buffer(0)]],
                     bool front [[front_facing]])
{
    constexpr sampler lin(filter::linear, address::repeat);
    FOut o;
    half4 t = tex.sample(s, in.uv) + tex.sample(lin, in.uv, bias(0.5f));
    o.c0 = t * in.color;
    o.c1 = front ? tint : float4(in.position.xy, float(in.layerTag), 1.0f);
    return o;
}

// Discard, derivatives, read of a texture at the fragment position, depth
// comparison sampling.
fragment float4 fs_discard(VOut in [[stage_in]],
                           texture2d<float, access::read> src [[texture(0)]],
                           depth2d<float> shadow [[texture(1)]],
                           sampler cmp [[sampler(1)]])
{
    float4 c = src.read(uint2(in.position.xy));
    float d = shadow.sample_compare(cmp, in.uv, 0.5f);
    if (c.a < 0.01f) discard_fragment();
    float2 w = fwidth(in.uv) + dfdx(in.uv) * dfdy(in.uv);
    return c * d + float4(w, 0.0f, 0.0f);
}

// A function constant (resolved by the guest before the host sees it, or
// a specialization constant here).
constant bool kUseTint [[function_constant(0)]];
constant int kMode [[function_constant(1)]];

fragment half4 fs_fconst(VOut in [[stage_in]])
{
    half4 c = kUseTint ? in.color : half4(1.0h);
    if (kMode == 2) c.rgb = c.bgr;
    return c;
}

// An argument buffer with a texture, a sampler and a buffer pointer.
struct ArgBuf {
    texture2d<float> t [[id(0)]];
    sampler s           [[id(1)]];
    device float *data  [[id(2)]];
};

fragment float4 fs_argbuf(VOut in [[stage_in]], constant ArgBuf &ab [[buffer(2)]])
{
    return ab.t.sample(ab.s, in.uv) * ab.data[0];
}

// Depth output and sample mask.
struct DOut {
    float4 c [[color(0)]];
    float d [[depth(any)]];
};

fragment DOut fs_depth(VOut in [[stage_in]])
{
    DOut o;
    o.c = float4(in.color);
    o.d = in.uv.x;
    return o;
}

// A loop with a texture sample inside (blur-like).
fragment half4 fs_blur(VOut in [[stage_in]],
                       texture2d<half> tex [[texture(0)]],
                       constant float *weights [[buffer(0)]],
                       constant uint &taps [[buffer(1)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half4 acc = 0.0h;
    for (uint i = 0; i < taps; i++) {
        float2 off = float2(float(i) - float(taps) * 0.5f, 0.0f) / 256.0f;
        acc += tex.sample(s, in.uv + off) * half(weights[i]);
    }
    return acc;
}

// Outputs and arguments that exist only when a function constant is true.
constant bool kHasSecond [[function_constant(2)]];
constant bool kHasTint [[function_constant(3)]];

struct FOutOptional {
    float4 c0 [[color(0)]];
    float4 c1 [[color(1), function_constant(kHasSecond)]];
};

fragment FOutOptional fs_optional(VOut in [[stage_in]],
                                  constant float4 &tint [[buffer(0), function_constant(kHasTint)]])
{
    FOutOptional o;
    o.c0 = float4(in.color);
    if (kHasTint) o.c0 *= tint;
    if (kHasSecond) o.c1 = float4(in.uv, 0.0f, 1.0f);
    return o;
}

// Interpolants: explicit interpolation at the centre, centroid, a sample
// and an offset.
struct FInInterp {
    float4 position [[position]];
    interpolant<float2, interpolation::perspective> uv;
    interpolant<half4, interpolation::no_perspective> color;
};

fragment float4 fs_interpolants(FInInterp in [[stage_in]])
{
    float2 a = in.uv.interpolate_at_center() + in.uv.interpolate_at_centroid();
    float2 b = in.uv.interpolate_at_sample(0) + in.uv.interpolate_at_offset(float2(0.25f));
    return float4(a + b, 0.0f, 1.0f) * float4(in.color.interpolate_at_center());
}
