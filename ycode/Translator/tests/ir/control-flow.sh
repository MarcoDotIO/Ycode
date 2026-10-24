#!/bin/sh
# control-flow.sh: two translator behaviours of stage8-contract.md §13.3 on
# small AIR modules of ours (LLVM 18 text, assembled with llvm-as-18):
#  1. the loop guard: with --loop-limit a loop whose exit never comes is
#     guarded (reflection "loop_limit"), a loop with a constant trip count
#     is not, and without the option nothing changes;
#  2. helpers kept out of line: a helper called under a branch on the
#     thread position is inlined, the same helper called under a branch on
#     a buffer value (the same for every thread) stays a DontInline function.
# Leaves spin.spv/json (guarded, limit 1000) in WORK_DIR for the GPU check
# in ycode's KernelHangProbeTests (YCODE_TEST_LOOP_SPV / _JSON).
# Usage: control-flow.sh YCODE_AIRC WORK_DIR
set -eu
AIRC=$1; WORK=$2
mkdir -p "$WORK"
LLVM_AS=${LLVM_AS:-llvm-as-18}
HEAD='target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios13.0.0-simulator"'
ARGS='!3 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"out"}
!4 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"in"}
!5 = !{i32 2, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"gid"}'
pass=0; fail=0
check() {  # DESCRIPTION COMMAND...
    d=$1; shift
    if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $d"; fi
}

# 1. Loops: `spin` waits for in[0] == 1 (never, with zeros); `four` runs 4 times.
cat > "$WORK/loops.ll" <<IR
$HEAD
define void @spin(ptr addrspace(1) %out, ptr addrspace(1) %in, i32 %gid) {
entry:
  br label %loop
loop:
  %i = phi i32 [0, %entry], [%n, %loop]
  %n = add i32 %i, 1
  %f = load volatile i32, ptr addrspace(1) %in, align 4
  %done = icmp eq i32 %f, 1
  br i1 %done, label %exit, label %loop
exit:
  %g = zext i32 %gid to i64
  %p = getelementptr i32, ptr addrspace(1) %out, i64 %g
  store i32 %n, ptr addrspace(1) %p, align 4
  ret void
}
define void @four(ptr addrspace(1) %out, ptr addrspace(1) %in, i32 %gid) {
entry:
  br label %loop
loop:
  %i = phi i32 [0, %entry], [%n, %loop]
  %s = phi i32 [0, %entry], [%s2, %loop]
  %g = zext i32 %gid to i64
  %q = getelementptr i32, ptr addrspace(1) %in, i64 %g
  %v = load i32, ptr addrspace(1) %q, align 4
  %s2 = add i32 %s, %v
  %n = add i32 %i, 1
  %done = icmp eq i32 %n, 4
  br i1 %done, label %exit, label %loop
exit:
  %p = getelementptr i32, ptr addrspace(1) %out, i64 %g
  store i32 %s2, ptr addrspace(1) %p, align 4
  ret void
}
!air.kernel = !{!0, !6}
!0 = !{ptr @spin, !1, !2}
!6 = !{ptr @four, !1, !2}
!1 = !{}
!2 = !{!3, !4, !5}
$ARGS
IR
"$LLVM_AS" "$WORK/loops.ll" -o "$WORK/loops.bc"
"$AIRC" translate "$WORK/loops.bc" -f spin --loop-limit 1000 -o "$WORK/spin.spv" -r "$WORK/spin.json" -S "$WORK/spin.spvasm" >/dev/null
check "spin: reflection has loop_limit 1000" grep -q '"loop_limit": *1000' "$WORK/spin.json"
check "spin: the guard compares with 1000" grep -q 'OpUGreaterThan' "$WORK/spin.spvasm"
"$AIRC" translate "$WORK/loops.bc" -f spin -o "$WORK/spin0.spv" -r "$WORK/spin0.json" -S "$WORK/spin0.spvasm" >/dev/null
check "spin without --loop-limit: no guard" sh -c "! grep -q loop_limit '$WORK/spin0.json'"
"$AIRC" translate "$WORK/loops.bc" -f four --loop-limit 1000 -o "$WORK/four.spv" -r "$WORK/four.json" -S "$WORK/four.spvasm" >/dev/null
check "four: constant trip count, no guard" sh -c "! grep -q loop_limit '$WORK/four.json'"

# 2. Helpers: @h (60 instructions) is called twice by each kernel.
{
    echo "$HEAD"
    echo 'define internal i32 @h(i32 %x0) noinline {'
    i=0
    while [ $i -lt 60 ]; do
        n=$((i + 1))
        case $((i % 3)) in
            0) echo "  %x$n = mul i32 %x$i, $((2 * i + 3))" ;;
            1) echo "  %x$n = xor i32 %x$i, $((i * 7919))" ;;
            2) echo "  %x$n = add i32 %x$i, $((i + 11))" ;;
        esac
        i=$n
    done
    echo '  ret i32 %x60'
    echo '}'
    for k in div uni; do
        if [ $k = div ]; then cond='%a = and i32 %gid, 1'; else cond='%a = load i32, ptr addrspace(1) %in, align 4'; fi
        cat <<IR
define void @$k(ptr addrspace(1) %out, ptr addrspace(1) %in, i32 %gid) {
entry:
  $cond
  %c = icmp eq i32 %a, 0
  br i1 %c, label %t, label %e
t:
  %r1 = call i32 @h(i32 %gid)
  br label %m
e:
  %v = add i32 %gid, 7
  %r2 = call i32 @h(i32 %v)
  br label %m
m:
  %r = phi i32 [%r1, %t], [%r2, %e]
  %g = zext i32 %gid to i64
  %p = getelementptr i32, ptr addrspace(1) %out, i64 %g
  store i32 %r, ptr addrspace(1) %p, align 4
  ret void
}
IR
    done
    cat <<IR
!air.kernel = !{!0, !6}
!0 = !{ptr @div, !1, !2}
!6 = !{ptr @uni, !1, !2}
!1 = !{}
!2 = !{!3, !4, !5}
$ARGS
IR
} > "$WORK/helpers.ll"
"$LLVM_AS" "$WORK/helpers.ll" -o "$WORK/helpers.bc"
"$AIRC" translate "$WORK/helpers.bc" -f div -o "$WORK/div.spv" -r "$WORK/div.json" -S "$WORK/div.spvasm" >/dev/null
"$AIRC" translate "$WORK/helpers.bc" -f uni -o "$WORK/uni.spv" -r "$WORK/uni.json" -S "$WORK/uni.spvasm" >/dev/null
check "div: helper called under a thread-dependent branch is inlined" sh -c "! grep -q DontInline '$WORK/div.spvasm'"
check "uni: helper called under a uniform branch stays out of line" grep -q DontInline "$WORK/uni.spvasm"
AIRC_OUTLINE_DIVERGENT=1 "$AIRC" translate "$WORK/helpers.bc" -f div -S "$WORK/div-old.spvasm" -o "$WORK/div-old.spv" >/dev/null
check "div with AIRC_OUTLINE_DIVERGENT=1: out of line (old behaviour)" grep -q DontInline "$WORK/div-old.spvasm"

echo "control-flow: $pass passed, $fail failed"
[ $fail -eq 0 ]
