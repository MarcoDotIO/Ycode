#!/bin/sh
# build-thor.sh: build the R8 tools on the Thor (Ubuntu 24.04 aarch64) with
# the system llvm-18-dev, spirv-tools, libvulkan-dev and glslang-tools.
# Usage: build-thor.sh SRC_DIR OUT_DIR   (no sudo, nothing installed)
set -eu
SRC=$1; OUT=$2
mkdir -p "$OUT"
cc -O2 -Wall -o "$OUT/vkrun" "$SRC/vk/vkrun.c" -lvulkan
cc -O2 -Wall -o "$OUT/vkdraw" "$SRC/vk/vkdraw.c" -lvulkan
glslangValidator -V --target-env vulkan1.3 -o "$OUT/add_ref.spv" "$SRC/vk/add_ref.comp"
glslangValidator -V --target-env vulkan1.3 -o "$OUT/draw_ref.vert.spv" "$SRC/vk/draw_ref.vert"
glslangValidator -V --target-env vulkan1.3 -o "$OUT/draw_ref.frag.spv" "$SRC/vk/draw_ref.frag"
c++ -std=c++17 -O1 -fno-rtti -Wall -Wno-unused-parameter \
    $(llvm-config-18 --cxxflags | sed 's/-fno-exceptions//') \
    -o "$OUT/airc" "$SRC/airc/airc.cpp" \
    $(llvm-config-18 --ldflags) -lLLVM-18 \
    -lSPIRV-Tools-opt -lSPIRV-Tools
