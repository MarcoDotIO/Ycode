// RKProbe custom-material functions (original Ycode research code).
#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

[[visible]] void rkpStripes(realitykit::surface_parameters params) {
    float2 uv = params.geometry().uv0();
    half s = half(step(0.5f, fract(uv.x * 8.0f)));
    params.surface().set_base_color(half3(s, 0.2h, 1.0h - s));
    params.surface().set_roughness(0.5h);
}

[[visible]] void rkpWobble(realitykit::geometry_parameters params) {
    float3 p = params.geometry().model_position();
    float t = params.uniforms().time();
    params.geometry().set_model_position_offset(float3(0.0f, 0.02f * sin(p.x * 40.0f + t * 4.0f), 0.0f));
}
