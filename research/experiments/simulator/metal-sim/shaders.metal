// Our own test shaders for the R7 probe (original Ycode code). Compiled at
// build time into a metallib for the "metallib" test; the same functions are
// also given to the device as source text by mtltest.m.
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float4 color; };

vertex VOut yc_vtx(uint vid [[vertex_id]], const device float4 *v [[buffer(0)]])
{
    VOut o;
    o.pos = float4(v[vid].xy, 0.0, 1.0);
    o.color = float4(v[vid].z, v[vid].w, 0.25, 1.0);
    return o;
}

fragment float4 yc_frag(VOut in [[stage_in]]) { return in.color; }

kernel void yc_add(const device float *a [[buffer(0)]], const device float *b [[buffer(1)]],
                   device float *c [[buffer(2)]], uint i [[thread_position_in_grid]])
{
    c[i] = a[i] + b[i];
}
