// Ycode translator tests (ours): compute kernels for scalar and vector
// arithmetic, conversions, control flow, private arrays and constant
// tables. Every t_* kernel writes values that tests/gpu/airc-gpu.c
// recomputes on the CPU. Convention: buffer(0) is the output, the thread
// index is the only input, and each thread writes `K` 32-bit words at
// out[gid * K].
#include <metal_stdlib>
using namespace metal;

// The R8 proof-of-concept kernels, kept as regression tests.
kernel void add_arrays(device const float *a [[buffer(0)]],
                       device const float *b [[buffer(1)]],
                       device float *out     [[buffer(2)]],
                       constant uint &count  [[buffer(3)]],
                       uint gid [[thread_position_in_grid]])
{
    if (gid < count)
        out[gid] = a[gid] + b[gid];
}

kernel void add_strided(device const float *a [[buffer(0)]],
                        device const float *b [[buffer(1)]],
                        device float *out     [[buffer(2)]],
                        constant uint &count  [[buffer(3)]],
                        uint gid     [[thread_position_in_grid]],
                        uint threads [[threads_per_grid]])
{
    for (uint i = gid; i < count; i += threads)
        out[i] = fmax(a[i] + b[i], 0.0f);
}

// K = 8: integer arithmetic and bit operations.
kernel void t_int(device uint *out [[buffer(0)]], uint gid [[thread_position_in_grid]])
{
    uint x = gid * 2654435761u + 12345u;
    int s = int(gid) - 500;
    device uint *o = out + gid * 8;
    o[0] = x;
    o[1] = (x >> 7) ^ (x << 3);
    o[2] = uint(s / 7) + uint(s % 7);
    o[3] = popcount(x) + (clz(x | 1u) << 8) + (ctz(x | 0x80000000u) << 16);
    o[4] = reverse_bits(x);
    o[5] = uint(abs(s)) + uint(max(s, -3)) + min(x, 1000u);
    o[6] = uint(clamp(s, -10, 10) + 10) + (gid > 300 ? 1000u : 0u);
    o[7] = (x / (gid + 1u)) + (x % (gid + 3u));
}

// K = 8: float math; compared with a tolerance.
kernel void t_math(device float *out [[buffer(0)]], uint gid [[thread_position_in_grid]])
{
    float x = float(gid) * 0.01f - 2.0f;
    device float *o = out + gid * 8;
    o[0] = x * x + 1.5f;
    o[1] = sqrt(fabs(x)) + rsqrt(fabs(x) + 1.0f);
    o[2] = fast::exp2(x) + fast::log2(fabs(x) + 1.0f);
    o[3] = precise::sin(x) + precise::cos(x);
    o[4] = fma(x, 2.0f, 0.25f) + floor(x) + ceil(x) + trunc(x);
    o[5] = fract(x) + mix(x, 1.0f, 0.25f) + saturate(x) + step(0.0f, x);
    o[6] = pow(fabs(x) + 0.5f, 1.5f) + atan2(x, 1.0f) + sign(x);
    o[7] = clamp(x, -1.0f, 1.0f) + fmin(x, 0.5f) + fmax(x, -0.5f) + smoothstep(-1.0f, 1.0f, x);
}

// K = 4: conversions between float, int, half and narrow integers.
kernel void t_convert(device uint *out [[buffer(0)]], uint gid [[thread_position_in_grid]])
{
    float f = float(gid) * 1.75f - 100.0f;
    half h = half(f * 0.125f);
    short sh = short(int(gid) - 300);
    uchar c = uchar(gid & 0xffu);
    device uint *o = out + gid * 4;
    o[0] = uint(int(f));
    o[1] = as_type<uint>(float(h));
    o[2] = uint(int(sh) * 3) + uint(c);
    o[3] = uint(float(gid) * 0.5f) + uint(ushort(gid * 7u));
}

// K = 4: loops with break and continue, nested loops, a switch.
kernel void t_control(device uint *out [[buffer(0)]], uint gid [[thread_position_in_grid]])
{
    uint acc = 0;
    for (uint i = 0; i < 64; i++) {
        if ((i & 3u) == (gid & 3u)) continue;
        acc += i * gid;
        if (acc > 5000u + gid) break;
    }
    uint nested = 0;
    for (uint i = 0; i < (gid & 7u); i++)
        for (uint j = 0; j <= i; j++) {
            if (j == 5) break;
            nested += i ^ j;
        }
    uint sw;
    switch (gid % 5u) {
    case 0: sw = 11; break;
    case 1: sw = gid * 3u; break;
    case 2: sw = acc + 1u; break;
    case 3: sw = nested; break;
    default: sw = 99; break;
    }
    uint w = gid;
    uint steps = 0;
    while (w != 1u && w != 0u && steps < 200u) {
        w = (w & 1u) ? 3u * w + 1u : w / 2u;
        steps++;
    }
    device uint *o = out + gid * 4;
    o[0] = acc;
    o[1] = nested;
    o[2] = sw;
    o[3] = steps;
}

// K = 2: a private array indexed dynamically, and a constant table.
constant uint kTable[16] = {3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3};

kernel void t_private(device uint *out [[buffer(0)]], uint gid [[thread_position_in_grid]])
{
    uint a[12];
    for (uint i = 0; i < 12; i++) a[i] = i * i + gid;
    for (uint i = 0; i < 12; i++) a[(i * 5u + gid) % 12u] += i;
    uint s = 0;
    for (uint i = 0; i < 12; i++) s += a[i] * (i + 1u);
    out[gid * 2] = s + a[gid % 12u];
    out[gid * 2 + 1] = kTable[gid & 15u] + kTable[(gid >> 4) & 15u] * 10u;
}

// K = 4: half precision, float2/3/4 vectors, dot, length, cross.
kernel void t_vector(device float *out [[buffer(0)]], uint gid [[thread_position_in_grid]])
{
    float3 a = float3(float(gid), 1.0f, -2.0f) * 0.1f;
    float3 b = float3(0.5f, float(gid & 7u), 3.0f) * 0.25f;
    half4 h = half4(half(gid & 15u), 1.0h, 0.5h, -1.0h);
    float4 v = float4(a.zyx, 1.0f) + float4(b, 0.0f).wzyx;
    device float *o = out + gid * 4;
    o[0] = dot(a, b);
    o[1] = length(a) + distance(a, b);
    o[2] = cross(a, b).y + normalize(b + 1.0f).x;
    o[3] = float(dot(h, h * 0.5h)) + v.x * v.w - v.y;
}

struct Pair { float4 a; uint2 b; float c; };

// K = 4: structs through a device buffer (copies, members), constant
// buffer argument. Buffer(1) holds Pair records, buffer(2) a scale.
kernel void t_struct(device uint *out [[buffer(0)]],
                     device const Pair *pairs [[buffer(1)]],
                     constant float &scale [[buffer(2)]],
                     uint gid [[thread_position_in_grid]])
{
    Pair p = pairs[gid];
    Pair q = pairs[(gid + 1u) % 64u];
    device uint *o = out + gid * 4;
    o[0] = as_type<uint>((p.a.x + q.a.w) * scale);
    o[1] = p.b.x + q.b.y;
    o[2] = as_type<uint>(p.c * 2.0f);
    o[3] = uint(p.a.y);
}

// Visible functions (translated linked into a caller, or alone inside a
// generated test function).
[[visible]] float vis_scale(float x, float k) { return x * k + 1.0f; }
[[visible]] float vis_twice(float x) { return vis_scale(x, 2.0f); }

kernel void call_visible(device float *out [[buffer(0)]], uint gid [[thread_position_in_grid]])
{
    out[gid] = vis_twice(float(gid));
}

// K = 4: helpers that the Metal compiler keeps as calls (noinline), each
// called more than once: ycode-airc keeps such helpers out of line. They
// take a private array and a constant pointer, and return a struct.
struct Pair2 { float a; uint b; };

constant float kBias[4] = {0.5f, 1.0f, 1.5f, 2.0f};

__attribute__((noinline)) Pair2 helper_poly(float x, thread float *coeffs, constant float *bias, uint n)
{
    Pair2 r = {0.0f, 0u};
    for (uint i = 0; i < n; i++) {
        r.a = r.a * x + coeffs[i];
        if (r.a > 100.0f) { r.a *= 0.5f; r.b++; }
    }
    r.a += bias[n & 3u];
    return r;
}

kernel void t_calls(device float *out [[buffer(0)]], uint gid [[thread_position_in_grid]])
{
    float c[6];
    for (uint i = 0; i < 6; i++) c[i] = float(i + gid % 5u) * 0.75f;
    Pair2 p = helper_poly(float(gid) * 0.01f, c, kBias, gid & 3u);
    Pair2 q = helper_poly(1.0f + float(gid & 7u) * 0.1f, c, kBias, 6);
    out[gid * 4] = p.a;
    out[gid * 4 + 1] = q.a;
    out[gid * 4 + 2] = float(q.b + p.b);
    out[gid * 4 + 3] = c[gid % 6u];
}
