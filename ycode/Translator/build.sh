#!/bin/sh
# build.sh: configure and build ycode-airc (and the GPU test harness) on
# Linux with the system LLVM 18, SPIRV-Tools and Vulkan packages. No sudo,
# nothing installed.
# Usage: build.sh [BUILD_DIR]   (default: ./build next to this script)
# YCODE_AIRC_RPATH: the binary's only run-time search path, for a package
# (literal, e.g. '$ORIGIN/../../..'); unset, CMake's build-tree default.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/build}
LLVM_DIR=${LLVM_DIR:-$(llvm-config-18 --cmakedir 2>/dev/null || echo /usr/lib/llvm-18/lib/cmake/llvm)}
GEN=""
command -v ninja >/dev/null 2>&1 && GEN="-G Ninja"
cmake -S "$HERE" -B "$OUT" $GEN -DCMAKE_BUILD_TYPE=Release -DLLVM_DIR="$LLVM_DIR" \
    -DYCODE_AIRC_RPATH="${YCODE_AIRC_RPATH:-}" >/dev/null
cmake --build "$OUT" -j "${FLATPAK_BUILDER_N_JOBS:-$(nproc 2>/dev/null || echo 4)}"
echo "built: $OUT/ycode-airc"
