// Ycode R8 test shaders (ours): tile and imageblock features, programmable
// blending, raster order groups, function tables and ray tracing types,
// to learn which AIR address spaces and metadata they use.
#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace raytracing;

struct Px { half4 c [[color(0)]]; float d [[color(1)]]; };

// Programmable blending: read the current render-target value.
fragment half4 fs_blend(float4 pos [[position]], half4 dst [[color(0)]])
{
    return dst * half(0.5) + half4(0.25h);
}

// Raster order group on an output.
struct ROut { half4 c [[color(0), raster_order_group(0)]]; };
fragment ROut fs_rog(float4 pos [[position]], device uint *ctr [[buffer(0), raster_order_group(0)]])
{
    ROut o; o.c = half4(half(ctr[0] & 1u)); return o;
}

// Explicit imageblock in a tile kernel.
struct IB { half4 acc [[color(0)]]; };
kernel void tile_k(imageblock<IB, imageblock_layout_implicit> ib,
                   ushort2 lid [[thread_position_in_threadgroup]])
{
    IB v = ib.read(lid);
    v.acc *= half(2.0);
    ib.write(v, lid);
}

[[visible]] float vf(float x) { return x + 1.0f; }

kernel void use_tables(device float *o [[buffer(0)]],
                       visible_function_table<float(float)> vft [[buffer(1)]],
                       instance_acceleration_structure as [[buffer(2)]],
                       uint i [[thread_position_in_grid]])
{
    ray r(float3(0), float3(0, 0, 1));
    intersector<instancing, triangle_data> isect;
    auto h = isect.intersect(r, as);
    o[i] = vft[0](h.distance);
}
