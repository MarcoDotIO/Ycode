// Ycode stage-8 probe shaders (original Ycode code; stage8-contract.md §8).
// The classic hello triangle: stage-in position and color, interpolated color.
#include <metal_stdlib>
using namespace metal;

struct TriangleIn {
    float2 position [[attribute(0)]];
    float4 color [[attribute(1)]];
};

struct TriangleOut {
    float4 position [[position]];
    float4 color;
};

vertex TriangleOut triangle_vertex(TriangleIn in [[stage_in]]) {
    TriangleOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 triangle_fragment(TriangleOut in [[stage_in]]) {
    return in.color;
}
