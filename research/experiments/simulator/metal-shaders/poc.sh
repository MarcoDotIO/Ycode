#!/bin/sh
# poc.sh: reproduce the R8 proof of concept (AIR in a metallib -> SPIR-V ->
# the Thor's GPU). Usage: poc.sh SCRATCH_DIR [THOR_DIR]
#   SCRATCH_DIR  local output directory (outside the repository)
#   THOR_DIR     default $YCODE_DATA/work/8-R8 (YCODE_DATA: data directory on the
#                arm64 Linux machine; THOR: its user@host)
# Needs the public Metal toolchain on the Mac
# (xcodebuild -downloadComponent MetalToolchain) and an SSH key for the Thor.
# Only our own shaders (shaders/*.metal) are compiled and translated.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$1
: "${THOR:?set THOR to user@host of the arm64 Linux machine}"
: "${YCODE_DATA:?set YCODE_DATA to the data directory on that machine}"
TD=${2:-$YCODE_DATA/work/8-R8}
mkdir -p "$OUT"
for n in poc draw; do
    xcrun -sdk iphonesimulator metal "$HERE/shaders/$n.metal" -o "$OUT/$n.metallib"
done
python3 -I "$HERE/metallib_dump.py" "$OUT/poc.metallib" | head -20
ssh "$THOR" "mkdir -p $TD/src $TD/own $TD/build"
rsync -a --exclude '*.py' "$HERE/" "$THOR:$TD/src/"
scp -q "$OUT/poc.metallib" "$OUT/draw.metallib" "$THOR:$TD/own/"
ssh "$THOR" "set -e; cd $TD && sh src/build-thor.sh src build && cd build &&
  ./vkrun --features | head -4 &&
  ./vkrun --n 100000 add_ref.spv &&
  ./airc ../own/poc.metallib add_arrays add_arrays.spv --asm add_arrays.spvasm &&
  spirv-val --target-env vulkan1.3 add_arrays.spv &&
  ./vkrun --entry add_arrays --n 100000 add_arrays.spv &&
  ./vkrun --entry add_arrays --memfd --n 1000000 --local 128 add_arrays.spv &&
  ./airc ../own/poc.metallib add_strided add_strided.spv --opt &&
  ./vkrun --entry add_strided --n 100003 --grid 777 add_strided.spv &&
  ./vkdraw draw_ref.vert.spv main draw_ref.frag.spv main &&
  ./airc ../own/draw.metallib draw_vs draw_vs.spv &&
  ./airc ../own/draw.metallib draw_fs draw_fs.spv --link-vs draw_vs &&
  ./vkdraw draw_vs.spv draw_vs draw_fs.spv draw_fs air.ppm"
