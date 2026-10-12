// Ycode R8 proof-of-concept render pipeline (ours): a vertex function with
// stage-in attributes (float2 position, half4 color), a constant buffer
// and a [[position]] output; a fragment function that samples a texture
// and writes [[color(0)]] as half4. Translated by airc, drawn by vkdraw.
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

vertex VOut draw_vs(VIn in [[stage_in]], constant Xform &x [[buffer(1)]])
{
    VOut o;
    float2 p = in.pos * x.scale + x.offset;
    o.position = float4(p, 0.0f, 1.0f);
    // Metal convention: NDC y up, texture v down.
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
