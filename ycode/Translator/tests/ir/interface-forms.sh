#!/bin/sh
# interface-forms.sh: forms the visionOS runtime's functions sent to Ycode
# (visionos.md section 10.13), each as a small AIR module of ours (LLVM 18
# text, assembled with llvm-as-18), translated and validated:
#  1. the weak compare-exchange atomic in the guest's operand form
#     i32 (ptr addrspace(1), ptr, i32, i32, i32, i32, i1): a compare-exchange
#     increment loop (left as cas.spv/json in WORK_DIR for the GPU check in
#     ycode's CompareExchangeGPUTests: YCODE_TEST_CAS_SPV / _JSON);
#  2. a fragment function that returns an explicit imageblock beside its
#     colour and reads one as an input;
#  3. a fragment function linked to a vertex function that does not write
#     one of its inputs: accepted when the function never reads the input,
#     refused when it does;
#  4. the null guard on loads through pointers read from memory;
#  5. vertex stage-in attributes the function never reads.
# Usage: interface-forms.sh YCODE_AIRC WORK_DIR
set -eu
AIRC=$1; WORK=$2
mkdir -p "$WORK"
LLVM_AS=${LLVM_AS:-llvm-as-18}
HEAD='target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios13.0.0-simulator"'
pass=0; fail=0
check() {  # DESCRIPTION COMMAND...
    d=$1; shift
    if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $d"; fi
}
spv() {  # NAME BC FUNCTION [extra translate options]: translate and validate
    n=$1; bc=$2; f=$3; shift 3
    "$AIRC" translate "$bc" -f "$f" -o "$WORK/$n.spv" -r "$WORK/$n.json" -S "$WORK/$n.spvasm" "$@" &&
        spirv-val --target-env vulkan1.3 "$WORK/$n.spv"
}

# 1. Compare-exchange: every thread adds 1 to out[0] with a weak
#    compare-exchange loop; `expected` lives in private memory and is
#    updated by a failed exchange. out[0] ends at the thread count only if
#    the result is the success flag and `expected` is refreshed.
cat > "$WORK/cas.ll" <<IR
$HEAD
declare i32 @air.atomic.global.cmpxchg.weak.i32(ptr addrspace(1), ptr, i32, i32, i32, i32, i1)
define void @cas(ptr addrspace(1) %out, ptr addrspace(1) %in, i32 %gid) {
entry:
  %e = alloca i32, align 4
  %first = load volatile i32, ptr addrspace(1) %out, align 4
  store i32 %first, ptr %e, align 4
  br label %loop
loop:
  %cur = load i32, ptr %e, align 4
  %d = add i32 %cur, 1
  %ok = call i32 @air.atomic.global.cmpxchg.weak.i32(ptr addrspace(1) %out, ptr %e, i32 %d, i32 0, i32 0, i32 2, i1 true)
  %b = icmp ne i32 %ok, 0
  br i1 %b, label %exit, label %loop
exit:
  ret void
}
!air.kernel = !{!0}
!0 = !{ptr @cas, !1, !2}
!1 = !{}
!2 = !{!3, !4, !5}
!3 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"atomic_uint", !"air.arg_name", !"out"}
!4 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"in"}
!5 = !{i32 2, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"gid"}
IR
"$LLVM_AS" "$WORK/cas.ll" -o "$WORK/cas.bc"
check "cas: translates and validates" spv cas "$WORK/cas.bc" cas
check "cas: uses OpAtomicCompareExchange" grep -q OpAtomicCompareExchange "$WORK/cas.spvasm"

# 2. Imageblock data in a fragment function (explicit layout { float, float }).
cat > "$WORK/ib.ll" <<IR
$HEAD
%struct.IB = type { float, float }
%struct.Out = type { <4 x float>, %struct.IB }
define %struct.Out @ibfrag(<2 x float> %uv, %struct.IB %prev) {
  %a = extractvalue %struct.IB %prev, 0
  %u = extractelement <2 x float> %uv, i32 0
  %s = fadd float %a, %u
  %c = insertelement <4 x float> <float 0.0, float 0.0, float 0.0, float 1.0>, float %s, i32 0
  %b0 = insertvalue %struct.IB undef, float %s, 0
  %b1 = insertvalue %struct.IB %b0, float %u, 1
  %r0 = insertvalue %struct.Out undef, <4 x float> %c, 0
  %r1 = insertvalue %struct.Out %r0, %struct.IB %b1, 1
  ret %struct.Out %r1
}
!air.fragment = !{!0}
!0 = !{ptr @ibfrag, !1, !4}
!1 = !{!2, !3}
!2 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4", !"air.arg_name", !"color"}
!3 = !{!"air.imageblock_data", !"air.arg_type_name", !"IB", !"air.arg_name", !"ib"}
!4 = !{!5, !6}
!5 = !{i32 0, !"air.fragment_input", !"generated(2uvDv2_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"uv"}
!6 = !{i32 1, !"air.imageblock_data", !"air.arg_type_name", !"IB", !"air.arg_name", !"prev"}
IR
"$LLVM_AS" "$WORK/ib.ll" -o "$WORK/ib.bc"
check "imageblock fragment: translates and validates" spv ib "$WORK/ib.bc" ibfrag
check "imageblock fragment: one colour output, nothing else" sh -c "[ \$(grep -c '= OpVariable .* Output' '$WORK/ib.spvasm') -eq 1 ]"
check "imageblock fragment: reflection names the dropped output" grep -q imageblock_output_dropped "$WORK/ib.json"
check "imageblock fragment: reflection names the zero input" grep -q imageblock_input_zero "$WORK/ib.json"

# 3. Linking: the vertex function writes position and uv; fragment `quiet`
#    declares normal without reading it, fragment `loud` reads it.
cat > "$WORK/vs.ll" <<IR
$HEAD
%struct.V = type { <4 x float>, <2 x float> }
define %struct.V @vmain(i32 %vid) {
  %f = uitofp i32 %vid to float
  %p = insertelement <4 x float> <float 0.0, float 0.0, float 0.0, float 1.0>, float %f, i32 0
  %u = insertelement <2 x float> zeroinitializer, float %f, i32 1
  %r0 = insertvalue %struct.V undef, <4 x float> %p, 0
  %r1 = insertvalue %struct.V %r0, <2 x float> %u, 1
  ret %struct.V %r1
}
!air.vertex = !{!0}
!0 = !{ptr @vmain, !1, !4}
!1 = !{!2, !3}
!2 = !{!"air.position", !"air.arg_type_name", !"float4", !"air.arg_name", !"position"}
!3 = !{!"air.vertex_output", !"generated(2uvDv2_f)", !"air.arg_type_name", !"float2", !"air.arg_name", !"uv"}
!4 = !{!5}
!5 = !{i32 0, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"vid"}
IR
cat > "$WORK/fs.ll" <<IR
$HEAD
define <4 x float> @quiet(<2 x float> %uv, <3 x float> %normal) {
  %u = extractelement <2 x float> %uv, i32 0
  %c = insertelement <4 x float> <float 0.0, float 0.0, float 0.0, float 1.0>, float %u, i32 0
  ret <4 x float> %c
}
define <4 x float> @loud(<2 x float> %uv, <3 x float> %normal) {
  %u = extractelement <3 x float> %normal, i32 0
  %c = insertelement <4 x float> <float 0.0, float 0.0, float 0.0, float 1.0>, float %u, i32 0
  ret <4 x float> %c
}
!air.fragment = !{!0, !6}
!0 = !{ptr @quiet, !1, !3}
!6 = !{ptr @loud, !1, !3}
!1 = !{!2}
!2 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4", !"air.arg_name", !"color"}
!3 = !{!4, !5}
!4 = !{i32 0, !"air.fragment_input", !"generated(2uvDv2_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"uv"}
!5 = !{i32 1, !"air.fragment_input", !"generated(6normalDv3_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float3", !"air.arg_name", !"normal"}
IR
"$LLVM_AS" "$WORK/vs.ll" -o "$WORK/vs.bc"
"$LLVM_AS" "$WORK/fs.ll" -o "$WORK/fs.bc"
check "linked fragment, unread input missing from the vertex outputs: translates and validates" \
    spv quiet "$WORK/fs.bc" quiet --link-vertex "$WORK/vs.bc:vmain"
check "linked fragment: one input variable (uv at the vertex function's location 0)" \
    sh -c "[ \$(grep -c '= OpVariable .* Input' '$WORK/quiet.spvasm') -eq 1 ] && grep -q 'Location 0' '$WORK/quiet.spvasm'"
check "linked fragment, read input missing from the vertex outputs: refused" \
    sh -c "! '$AIRC' translate '$WORK/fs.bc' -f loud --link-vertex '$WORK/vs.bc:vmain' -o '$WORK/loud.spv'"
check "unlinked fragment: both inputs declared" spv quiet0 "$WORK/fs.bc" quiet

# 4. Null guard: a load through a pointer read from memory. Left as np.spv/json
#    for ycode's NullPointerGPUTests (YCODE_TEST_NULLPTR_SPV / _JSON).
cat > "$WORK/np.ll" <<IR
$HEAD
define void @np(ptr addrspace(1) %out, ptr addrspace(1) %in, i32 %gid) {
  %p = load ptr addrspace(1), ptr addrspace(1) %in, align 8
  %q = getelementptr i8, ptr addrspace(1) %p, i64 16
  %v = load i32, ptr addrspace(1) %q, align 4
  %g = zext i32 %gid to i64
  %o = getelementptr i32, ptr addrspace(1) %out, i64 %g
  store i32 %v, ptr addrspace(1) %o, align 4
  ret void
}
!air.kernel = !{!0}
!0 = !{ptr @np, !1, !2}
!1 = !{}
!2 = !{!3, !4, !5}
!3 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"out"}
!4 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 1, !"air.arg_type_size", i32 8, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"Args", !"air.arg_name", !"in"}
!5 = !{i32 2, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"gid"}
IR
"$LLVM_AS" "$WORK/np.ll" -o "$WORK/np.bc"
check "null guard: translates and validates" spv np "$WORK/np.bc" np
check "null guard: one guarded load in the reflection" grep -q '"null_guarded_loads": *1' "$WORK/np.json"
check "null guard: the address is compared with 64 KiB" grep -q 'OpUGreaterThanEqual' "$WORK/np.spvasm"
AIRC_NULL_GUARD=0 "$AIRC" translate "$WORK/np.bc" -f np -o "$WORK/np0.spv" -r "$WORK/np0.json" >/dev/null
check "null guard off (AIRC_NULL_GUARD=0, new translator process): no guard" sh -c "! grep -q null_guarded '$WORK/np0.json'"

# 5. Stage-in attributes the vertex function never reads get no input variable.
cat > "$WORK/vin.ll" <<IR
$HEAD
define <4 x float> @vin(<3 x float> %position, <4 x float> %color, <2 x float> %uv) {
  %x = extractelement <3 x float> %position, i32 0
  %u = extractelement <2 x float> %uv, i32 1
  %p0 = insertelement <4 x float> <float 0.0, float 0.0, float 0.0, float 1.0>, float %x, i32 0
  %p1 = insertelement <4 x float> %p0, float %u, i32 1
  ret <4 x float> %p1
}
!air.vertex = !{!0}
!0 = !{ptr @vin, !1, !3}
!1 = !{!2}
!2 = !{!"air.position", !"air.arg_type_name", !"float4", !"air.arg_name", !"position"}
!3 = !{!4, !5, !6}
!4 = !{i32 0, !"air.vertex_input", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"float3", !"air.arg_name", !"position"}
!5 = !{i32 1, !"air.vertex_input", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"float4", !"air.arg_name", !"color"}
!6 = !{i32 2, !"air.vertex_input", !"air.location_index", i32 7, i32 1, !"air.arg_type_name", !"float2", !"air.arg_name", !"uv"}
IR
"$LLVM_AS" "$WORK/vin.ll" -o "$WORK/vin.bc"
check "vertex inputs: translates and validates" spv vin "$WORK/vin.bc" vin
check "vertex inputs: locations 0 and 7 declared, 1 not" sh -c "grep -q 'Location 0' '$WORK/vin.spvasm' && grep -q 'Location 7' '$WORK/vin.spvasm' && ! grep -q 'Location 1\$' '$WORK/vin.spvasm'"

echo "interface forms: $pass passed, $fail failed"
[ "$fail" = 0 ]
