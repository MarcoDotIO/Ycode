// Ycode R8 test shaders (ours): one function of each kind, to learn the
// metallib TYPE codes and the TESS/LAYR tags.
#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace raytracing;

[[visible]] float vis_fn(float x) { return x * 2.0f; }

[[stitchable]] float stitch_fn(float x, float y) { return x + y; }

struct MV { float4 p [[position]]; };
using MeshT = metal::mesh<MV, void, 3, 1, topology::triangle>;

[[mesh]] void mesh_fn(MeshT m, uint tid [[thread_index_in_threadgroup]])
{
    if (tid < 3) m.set_vertex(tid, MV{float4(0)});
    if (tid == 0) { m.set_index(0, 0); m.set_index(1, 1); m.set_index(2, 2); m.set_primitive_count(1); }
}

struct Payload { uint n; };
[[object]] void object_fn(object_data Payload &p [[payload]],
                          mesh_grid_properties g,
                          uint tid [[thread_index_in_threadgroup]])
{
    if (tid == 0) { p.n = 1; g.set_threadgroups_per_grid(uint3(1, 1, 1)); }
}

struct BoxResult { bool accept [[accept_intersection]]; float distance [[distance]]; };
[[intersection(bounding_box)]] BoxResult isect_fn(float tmin [[min_distance]], float tmax [[max_distance]])
{
    return BoxResult{tmax > tmin, tmin};
}

struct PIn { float3 pos [[attribute(0)]]; };
struct PatchIn { patch_control_point<PIn> cp; };
[[patch(triangle, 3)]] vertex float4 tess_vs(PatchIn p [[stage_in]],
                                             float3 bc [[position_in_patch]])
{
    return float4(p.cp[0].pos * bc.x + p.cp[1].pos * bc.y + p.cp[2].pos * bc.z, 1);
}

struct LOut { float4 p [[position]]; uint layer [[render_target_array_index]]; };
vertex LOut layer_vs(uint vid [[vertex_id]], uint iid [[instance_id]])
{
    LOut o; o.p = float4(float(vid), 0, 0, 1); o.layer = iid; return o;
}

kernel void plain_kernel(device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = vis_fn(o[i]); }
