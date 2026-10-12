#!/bin/sh
# run-gpu-tests.sh: translate the functions of tests/gpu/tests.txt with
# ycode-airc and run them on the Vulkan device with airc-gpu, comparing
# with the Metal oracle's outputs.
# Usage: run-gpu-tests.sh BUILD_DIR METALLIB_DIR ORACLE_DIR WORK_DIR [TEST...]
#   METALLIB_DIR: tests/compile-shaders.sh output (from the Mac)
#   ORACLE_DIR:   mtl-oracle output (from the Mac)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BUILD=$1; LIBS=$2; ORACLE=$3; WORK=$4
shift 4
mkdir -p "$WORK/spv" "$WORK/out"
AIRC="$BUILD/ycode-airc"
grep -v '^#' "$HERE/gpu/tests.txt" | while read -r kind name lib f1 f2 rest; do
    [ -n "$kind" ] || continue
    if [ "$kind" = compute ]; then
        # --link: visible functions the kernel calls come from the same library.
        "$AIRC" translate "$LIBS/$lib.metallib" -f "$f1" --link "$LIBS/$lib.metallib" \
            -o "$WORK/spv/$lib.$f1.spv" -r "$WORK/spv/$lib.$f1.json" >/dev/null ||
            echo "translate $lib.$f1 failed: $("$AIRC" translate "$LIBS/$lib.metallib" -f "$f1")"
    else
        "$AIRC" translate "$LIBS/$lib.metallib" -f "$f1" -o "$WORK/spv/$lib.$f1.spv" -r "$WORK/spv/$lib.$f1.json" >/dev/null
        CONST=""
        [ "$name" = draw_fconst ] && CONST="--constant 0=1 --constant 1=2"
        "$AIRC" translate "$LIBS/$lib.metallib" -f "$f2" --link-vertex "$LIBS/$lib.metallib:$f1" $CONST \
            -o "$WORK/spv/$lib.$f2.spv" -r "$WORK/spv/$lib.$f2.json" >/dev/null ||
            echo "translate $lib.$f2 failed"
    fi
done
# The command-line validator agrees with the in-process one.
n=0
for f in "$WORK"/spv/*.spv; do spirv-val --target-env vulkan1.3 "$f" && n=$((n + 1)); done
echo "spirv-val --target-env vulkan1.3: $n modules valid"
"$BUILD/airc-gpu" "$HERE/gpu/tests.txt" "$WORK/spv" "$ORACLE" "$WORK/out" "$@"
