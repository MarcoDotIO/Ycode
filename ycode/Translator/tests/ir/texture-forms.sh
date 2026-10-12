#!/bin/sh
# texture-forms.sh: operand forms of the texture intrinsics that ycode-airc
# must accept, beyond the ones our toolchain emits (the runtime's files use
# one form per family; functions the guest sends may use others). Each form
# is a small AIR module of ours (LLVM 18 text, assembled with llvm-as-18):
# a kernel that calls the intrinsic once and stores the result.
# Usage: texture-forms.sh YCODE_AIRC WORK_DIR
set -eu
AIRC=$1; WORK=$2
mkdir -p "$WORK"
pass=0; fail=0
form() {  # NAME DECLARATION-RESULT DECLARATION-ARGS CALL-ARGS USE
    name=$1; ret=$2; dargs=$3; cargs=$4; use=$5
    assign='%r ='
    [ "$ret" = void ] && assign=''
    cat > "$WORK/$name.ll" <<IR
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios13.0.0-simulator"

declare $ret @INTRINSIC($dargs)

define void @k(ptr addrspace(1) %out, ptr addrspace(1) %t, ptr addrspace(2) %s, <2 x i32> %c) {
  %c16 = trunc <2 x i32> %c to <2 x i16>
  %cf = uitofp <2 x i32> %c to <2 x float>
  $assign call $ret @INTRINSIC($cargs)
$use
  ret void
}

!air.kernel = !{!0}
!0 = !{ptr @k, !1, !2}
!1 = !{}
!2 = !{!3, !4, !5, !6}
!3 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"out"}
!4 = !{i32 1, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.arg_type_name", !"texture2d<float, read_write>", !"air.arg_name", !"t"}
!5 = !{i32 2, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"s"}
!6 = !{i32 3, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint2", !"air.arg_name", !"c"}
IR
    intr=$(echo "$name" | sed 's/__.*//')
    sed -i "s/@INTRINSIC/@$intr/g" "$WORK/$name.ll"
    if llvm-as-18 "$WORK/$name.ll" -o "$WORK/$name.bc" && out=$("$AIRC" translate "$WORK/$name.bc" -f k -o "$WORK/$name.spv") &&
       spirv-val --target-env vulkan1.3 "$WORK/$name.spv"; then
        pass=$((pass + 1))
    else
        echo "FAIL $name: $out"; fail=$((fail + 1))
    fi
}
R4='{ <4 x float>, i8 }'
USE_R='  %v = extractvalue { <4 x float>, i8 } %r, 0
  store <4 x float> %v, ptr addrspace(1) %out, align 16'
USE_W='  store <4 x float> zeroinitializer, ptr addrspace(1) %out, align 16'
V='<4 x float> <float 1.0, float 2.0, float 3.0, float 4.0>'
# read_texture_2d: (texture, [read sampler], coordinate, [offset], [LOD], [access])
form air.read_texture_2d.v4f32__observed "$R4" "ptr addrspace(1), ptr addrspace(2), <2 x i32>, <2 x i32>, i32, i32" "ptr addrspace(1) %t, ptr addrspace(2) %s, <2 x i32> %c, <2 x i32> zeroinitializer, i32 0, i32 3" "$USE_R"
form air.read_texture_2d.v4f32__nosampler "$R4" "ptr addrspace(1), <2 x i32>, <2 x i32>, i32, i32" "ptr addrspace(1) %t, <2 x i32> %c, <2 x i32> zeroinitializer, i32 0, i32 3" "$USE_R"
form air.read_texture_2d.v4f32__nooffset "$R4" "ptr addrspace(1), ptr addrspace(2), <2 x i32>, i32, i32" "ptr addrspace(1) %t, ptr addrspace(2) %s, <2 x i32> %c, i32 0, i32 1" "$USE_R"
form air.read_texture_2d.v4f32__noaccess "$R4" "ptr addrspace(1), ptr addrspace(2), <2 x i32>, <2 x i32>, i32" "ptr addrspace(1) %t, ptr addrspace(2) %s, <2 x i32> %c, <2 x i32> zeroinitializer, i32 0" "$USE_R"
form air.read_texture_2d.v4f32__minimal "$R4" "ptr addrspace(1), <2 x i32>, i32" "ptr addrspace(1) %t, <2 x i32> %c, i32 0" "$USE_R"
form air.read_texture_2d.v4f32__coordonly "$R4" "ptr addrspace(1), <2 x i32>" "ptr addrspace(1) %t, <2 x i32> %c" "$USE_R"
form air.read_texture_2d.i16.v4f32__ushort "$R4" "ptr addrspace(1), ptr addrspace(2), <2 x i16>, <2 x i16>, i16, i32" "ptr addrspace(1) %t, ptr addrspace(2) %s, <2 x i16> %c16, <2 x i16> <i16 1, i16 -1>, i16 0, i32 1" "$USE_R"
# write_texture_2d: (texture, coordinate, value, [LOD], [access])
form air.write_texture_2d.v4f32__observed void "ptr addrspace(1), <2 x i32>, <4 x float>, i32, i32" "ptr addrspace(1) %t, <2 x i32> %c, $V, i32 0, i32 3" "$USE_W"
form air.write_texture_2d.v4f32__noaccess void "ptr addrspace(1), <2 x i32>, <4 x float>, i32" "ptr addrspace(1) %t, <2 x i32> %c, $V, i32 0" "$USE_W"
form air.write_texture_2d.v4f32__minimal void "ptr addrspace(1), <2 x i32>, <4 x float>" "ptr addrspace(1) %t, <2 x i32> %c, $V" "$USE_W"
form air.write_texture_2d.i16.v4f32__ushort void "ptr addrspace(1), <2 x i16>, <4 x float>, i16, i32" "ptr addrspace(1) %t, <2 x i16> %c16, $V, i16 0, i32 3" "$USE_W"
# sample_texture_2d: (texture, sampler, coordinate, [i1], [offset], [i1 explicit LOD, LOD or bias, min LOD], [i32])
form air.sample_texture_2d.v4f32__observed "$R4" "ptr addrspace(1), ptr addrspace(2), <2 x float>, i1, <2 x i32>, i1, float, float, i32" "ptr addrspace(1) %t, ptr addrspace(2) %s, <2 x float> %cf, i1 true, <2 x i32> <i32 1, i32 0>, i1 true, float 0.0, float 0.0, i32 0" "$USE_R"
form air.sample_texture_2d.v4f32__notrailing "$R4" "ptr addrspace(1), ptr addrspace(2), <2 x float>, i1, <2 x i32>, i1, float, float" "ptr addrspace(1) %t, ptr addrspace(2) %s, <2 x float> %cf, i1 true, <2 x i32> zeroinitializer, i1 true, float 1.0, float 0.0" "$USE_R"
form air.sample_texture_2d.v4f32__nooffset "$R4" "ptr addrspace(1), ptr addrspace(2), <2 x float>, i1, float, float, i32" "ptr addrspace(1) %t, ptr addrspace(2) %s, <2 x float> %cf, i1 true, float 1.0, float 0.0, i32 0" "$USE_R"
form air.sample_texture_2d.v4f32__minimal "$R4" "ptr addrspace(1), ptr addrspace(2), <2 x float>" "ptr addrspace(1) %t, ptr addrspace(2) %s, <2 x float> %cf" "$USE_R"
form air.gather_texture_2d.v4f32__observed "$R4" "ptr addrspace(1), ptr addrspace(2), <2 x float>, i1, <2 x i32>, i32, i32" "ptr addrspace(1) %t, ptr addrspace(2) %s, <2 x float> %cf, i1 true, <2 x i32> zeroinitializer, i32 2, i32 0" "$USE_R"
form air.gather_texture_2d.v4f32__minimal "$R4" "ptr addrspace(1), ptr addrspace(2), <2 x float>, i32" "ptr addrspace(1) %t, ptr addrspace(2) %s, <2 x float> %cf, i32 1" "$USE_R"
echo "texture forms: $pass passed, $fail failed"
[ "$fail" = 0 ]
