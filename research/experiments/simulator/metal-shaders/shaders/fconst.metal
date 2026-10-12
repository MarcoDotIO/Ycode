// Ycode R8 test shader (ours): a function constant. The run-time compiler
// cannot serialize this one into a dynamic library ("unresolved function
// constants"); it needs the offline toolchain.
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 position [[position]]; half4 color; };

constant bool kUseTint [[function_constant(0)]];

fragment half4 fs_fconst(VOut in [[stage_in]])
{
    return kUseTint ? in.color : half4(1.0h);
}
