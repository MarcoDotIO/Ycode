// Shaders of the p_metal_linked probe (original Ycode code).
#include <metal_stdlib>
using namespace metal;

// Called through a visible function table.
[[visible]] float4 keep_red(float4 c) { return float4(c.r, 0, 0, c.a); }
[[visible]] float4 keep_blue(float4 c) { return float4(0, 0, c.b, c.a); }

kernel void through_table(device float4 *out [[buffer(0)]],
                          visible_function_table<float4(float4)> table [[buffer(1)]],
                          uint id [[thread_position_in_grid]]) {
    float4 c = float4(0.5, 0.25, 0.75, 1.0);
    out[id] = table[id % 2](c);
}

// Called directly; supplied at pipeline creation (MTLLinkedFunctions).
[[visible]] float scale_value(float x);

kernel void through_link(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    out[id] = scale_value(float(id));
}
