#!/bin/sh
# Builds the benchmark (specs/macos/objc-runtime.md §12) on a Mac:
#   <out>/bench-apple, <out>/cats<t>-apple.bundle   - the Mac's runtime
#   <out>/bench-ycode, <out>/cats<t>-ycode.bundle   - Ycode's runtime, native
#   <out>/bench, <out>/cats<t>-simd.bundle          - for ycode-simd --macos
#   <out>/cats<t>-<variant>-control.bundle          - the same, sections renamed (no runtime reads them)
#   <out>/warm.bundle                               - shared
#
#   sh build.sh <out dir>
#   <out>/bench-apple <out> apple
# python3 -I compare.py <out> [runs] runs both Mac variants alternately.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: build.sh <out dir>}
mkdir -p "$out/gen"
TARGET=arm64-apple-macos14.0
CC="clang -target $TARGET -O2 -fno-objc-arc"
python3 -I "$here/gen.py" "$out/gen"
# The Ycode runtime as a native dylib (build-mac.sh builds it; any program will do).
sh "$here/build-mac.sh" "$out" "$here/../tests/t_message.m" > /dev/null
lib="$out/libycobjc.dylib"
$CC -c "$here/bench.m" -o "$out/bench.o"
$CC -c "$out/gen/bench_gen.m" -o "$out/bench_gen.o"
$CC -o "$out/bench-apple" "$out/bench.o" "$out/bench_gen.o" -lobjc
$CC -o "$out/bench" "$out/bench.o" "$out/bench_gen.o" -lobjc
$CC -o "$out/bench-ycode" "$out/bench.o" "$out/bench_gen.o" "$lib" -Wl,-rpath,@executable_path
ren="python3 -I $here/rename_sections.py"
for t in 0 1 2 3 4; do
    $CC -c "$out/gen/cats$t.m" -o "$out/cats$t.o"
    $CC -bundle -o "$out/cats$t-apple.bundle" "$out/cats$t.o" -bundle_loader "$out/bench-apple" -lobjc
    $CC -bundle -o "$out/cats$t-simd.bundle" "$out/cats$t.o" -bundle_loader "$out/bench" -lobjc
    $CC -bundle -o "$out/cats$t-ycode.bundle" "$out/cats$t.o" -bundle_loader "$out/bench-ycode" "$lib"
    for v in apple simd ycode; do
        cp "$out/cats$t-$v.bundle" "$out/cats$t-$v-control.bundle"
        $ren --to __none_ "$out/cats$t-$v-control.bundle" > /dev/null
        codesign -f -s - "$out/cats$t-$v-control.bundle" 2> /dev/null
    done
    $ren "$out/cats$t-ycode.bundle" > /dev/null
    codesign -f -s - "$out/cats$t-ycode.bundle" "$out/cats$t-apple.bundle" "$out/cats$t-simd.bundle" 2> /dev/null
done
printf 'int warm_up(void) { return 1; }\n' > "$out/gen/warm.c"
$CC -bundle -o "$out/warm.bundle" "$out/gen/warm.c"
python3 -I "$here/rename_sections.py" "$out/bench-ycode" > /dev/null
codesign -f -s - "$out/bench-ycode" 2> /dev/null
echo "build.sh: $out/bench-apple $out/bench-ycode $out/bench"
