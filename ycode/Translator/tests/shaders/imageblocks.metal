// Ycode translator tests (ours): imageblocks in compute kernels (explicit
// and implicit layouts, data pointers, implicit field loads and stores,
// slices written to a texture). Kept in threadgroup memory by ycode-airc.
#include <metal_stdlib>
using namespace metal;
struct Px { half4 c; float d; };
kernel void k_ib_explicit(imageblock<Px, imageblock_layout_explicit> ib,
                          texture2d<half, access::write> out [[texture(0)]],
                          ushort2 lid [[thread_position_in_threadgroup]],
                          uint2 gid [[thread_position_in_grid]])
{
    threadgroup_imageblock Px *p = ib.data(lid);
    p->c = half4(half(lid.x), half(lid.y), 0.0h, 1.0h);
    p->d = 2.0f;
    threadgroup_barrier(mem_flags::mem_threadgroup_imageblock);
    threadgroup_imageblock Px *q = ib.data(lid ^ ushort2(1, 0));
    out.write(q->c * half(q->d), gid);
    ushort w = ib.get_width();
    ushort h = ib.get_height();
    if (lid.x == 0 && lid.y == 0) out.write(half4(half(w), half(h), 0.0h, 0.0h), gid + uint2(100));
}
struct IBI { half4 acc [[color(0)]]; float x [[color(1)]]; };
kernel void k_ib_implicit(imageblock<IBI, imageblock_layout_implicit> ib,
                          texture2d<half, access::write> out [[texture(0)]],
                          ushort2 lid [[thread_position_in_threadgroup]],
                          uint2 gid [[thread_position_in_grid]])
{
    IBI v = ib.read(lid);
    v.acc *= half(2.0);
    ib.write(v, lid);
    threadgroup_barrier(mem_flags::mem_threadgroup_imageblock);
    out.write(ib.read(lid ^ ushort2(1, 1)).acc, gid);
}
kernel void k_ib_slice(imageblock<Px, imageblock_layout_explicit> ib,
                       texture2d<half, access::write> out [[texture(0)]],
                       ushort2 lid [[thread_position_in_threadgroup]],
                       uint2 tg [[threadgroup_position_in_grid]])
{
    threadgroup_imageblock Px *p = ib.data(lid);
    p->c = half4(1.0h);
    threadgroup_barrier(mem_flags::mem_threadgroup_imageblock);
    if (lid.x == 0 && lid.y == 0) out.write(ib.slice(p->c), ushort2(tg * 8));
}

// GPU tests (tests/gpu/tests.txt): 16 x 16 grid, 8 x 8 threadgroups.
kernel void t_imageblock(imageblock<Px, imageblock_layout_explicit> ib,
                         device float *out [[buffer(0)]],
                         ushort2 lid [[thread_position_in_threadgroup]],
                         uint2 gid [[thread_position_in_grid]])
{
    threadgroup_imageblock Px *p = ib.data(lid);
    p->c = half4(half(lid.x), half(lid.y), 1.0h, 2.0h);
    p->d = float(gid.x * 3u + gid.y);
    threadgroup_barrier(mem_flags::mem_threadgroup_imageblock);
    threadgroup_imageblock Px *q = ib.data(ushort2(lid.y, lid.x));
    uint i = (gid.y * 16u + gid.x) * 2u;
    out[i] = float(q->c.x) + float(q->c.y) * 10.0f;
    out[i + 1] = q->d + float(ib.get_width() * 100u + ib.get_height());
}

struct Px2 { float4 c; };

kernel void t_imageblock_slice(imageblock<Px2, imageblock_layout_explicit> ib,
                               texture2d<float, access::write> dst [[texture(1)]],
                               ushort2 lid [[thread_position_in_threadgroup]],
                               uint2 tg [[threadgroup_position_in_grid]],
                               uint2 gid [[thread_position_in_grid]])
{
    threadgroup_imageblock Px2 *p = ib.data(lid);
    p->c = float4(float(gid.x), float(gid.y), float(lid.x + lid.y), 1.0f);
    threadgroup_barrier(mem_flags::mem_threadgroup_imageblock);
    if (lid.x == 0 && lid.y == 0) dst.write(ib.slice(p->c), ushort2(tg * 8u));
}
