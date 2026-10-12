// Ycode translator tests (ours): discard_fragment in a helper that a kernel
// also calls, behind a function constant. Metal accepts the kernel when the
// constant is false and refuses it when true (checked on the Mac);
// ycode-airc translates the call in a kernel as no operation while the
// constant is unresolved, and refuses the kernel when it is specialized true.
#include <metal_stdlib>
using namespace metal;
constant bool kFrag [[function_constant(0)]];
__attribute__((noinline)) float shade(float x) { if (kFrag && x < 0.0f) discard_fragment(); return x * 2.0f; }
kernel void k_helper_discard(device float *out [[buffer(0)]], uint gid [[thread_position_in_grid]])
{
    out[gid] = shade(float(gid) - 4.0f);
}
fragment float4 f_helper(float4 p [[position]]) { return float4(shade(p.x)); }
