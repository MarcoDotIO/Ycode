#!/bin/sh
# run-thor.sh: build ycode-airc and run every translator test on the Thor
# (or any Linux host with LLVM 18, SPIRV-Tools and a Vulkan 1.3 GPU).
# Usage: run-thor.sh WORK_DIR METALLIB_DIR ORACLE_DIR [RUNTIME_ROOT]
#   METALLIB_DIR, ORACLE_DIR: made on the Mac by compile-shaders.sh and
#   mtl-oracle (see tests/gpu/mtl-oracle.m)
#   RUNTIME_ROOT: optional simulator runtime root; its home-screen
#   metallibs are translated as input data and only statistics are printed.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$1; LIBS=$2; ORACLE=$3; ROOT=${4:-}
mkdir -p "$WORK"
sh "$HERE/../build.sh" "$WORK/build"
AIRC="$WORK/build/ycode-airc"
echo "== own shaders: translate and validate every function"
"$AIRC" corpus --quiet "$LIBS"
echo "== own shaders with spirv-opt"
"$AIRC" corpus --quiet --opt "$LIBS" | grep -E '"(functions|ok|failed)"'
echo "== GPU tests against the Metal oracle"
sh "$HERE/run-gpu-tests.sh" "$WORK/build" "$LIBS" "$ORACLE" "$WORK/gpu"
echo "== texture intrinsic operand forms"
sh "$HERE/ir/texture-forms.sh" "$AIRC" "$WORK/forms"
echo "== persistent mode"
rm -rf "$WORK/serve-cache" && mkdir -p "$WORK/serve-cache"
python3 -I "$HERE/serve-test.py" "$AIRC" "$LIBS" "$WORK/serve-cache"
if [ -n "$ROOT" ]; then
    for lib in Frameworks/QuartzCore PrivateFrameworks/MTLSimDriver PrivateFrameworks/RenderBox \
               PrivateFrameworks/CoreMaterial3D PrivateFrameworks/IconRendering PrivateFrameworks/CoreUI; do
        echo "== runtime $lib (statistics only)"
        "$AIRC" corpus --quiet "$ROOT/System/Library/$lib.framework/default.metallib"
    done
fi
