#!/bin/sh
# Builds visionos/vprobe (specs/simulator/visionos.md §7.2 R1: the guest's view
# of its UIDevice and MTLDevice) for the visionOS simulator platform. Runs on
# macOS only.
#   ../out/guest-tests/visionos/vprobe          arm64, visionOS simulator platform
#   ../out/guest-tests/visionos/mtlwatch.dylib  the same; a diagnostic dylib
#   ../out/guest-tests/visionos/rkprobe         the same; RealityKit renderer start
#   ../out/guest-tests/visionos/mtlrec.dylib    the same; Metal call recorder without a proxy
#   ../out/guest-tests/visionos/symaddr         the same; names sampled guest addresses
#   ../out/guest-tests/visionos/exports         the same; lists export names of a loaded image
#   ../out/guest-tests/visionos/shtex           the same; a shared texture, its IOSurface and handle
# Run it on the Thor as a one-shot: copy it into the device directory and
# pass ycode-simd --oneshot "<DEV path>/vprobe S" (it waits S seconds first).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/../out/guest-tests/visionos}"
[ "$(uname -s)" = "Darwin" ] || { echo "build-visionos.sh: needs macOS" >&2; exit 1; }
mkdir -p "$out"
xcrun --sdk xrsimulator clang -target arm64-apple-xros27.0-simulator -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -framework Foundation -framework UIKit -framework Metal -o "$out/vprobe" "$here/visionos/vprobe.m"
echo "$out/vprobe: $(wc -c < "$out/vprobe" | tr -d ' ') bytes"
# mtlwatch.dylib: a diagnostic MTLDevice call recorder (visionos/mtlwatch.m),
# inserted with --env DYLD_INSERT_LIBRARIES=<DEV path>/mtlwatch.dylib.
xcrun --sdk xrsimulator clang -target arm64-apple-xros27.0-simulator -fobjc-arc -O2 -Wall -Wextra -Werror -dynamiclib \
    -framework Foundation -framework Metal -o "$out/mtlwatch.dylib" "$here/visionos/mtlwatch.m"
echo "$out/mtlwatch.dylib: $(wc -c < "$out/mtlwatch.dylib" | tr -d ' ') bytes"
# mtlrec.dylib: records Metal calls on the device and on every Metal object it
# returns, in place (visionos/mtlrec.m); inserted like mtlwatch.dylib.
xcrun --sdk xrsimulator clang -target arm64-apple-xros27.0-simulator -fobjc-arc -O2 -Wall -Wextra -Werror -dynamiclib \
    -framework Foundation -framework Metal -framework IOSurface -lc++ -lMobileGestalt -Wl,-U,_REEngineInitWithConfiguration -o "$out/mtlrec.dylib" "$here/visionos/mtlrec.m"
echo "$out/mtlrec.dylib: $(wc -c < "$out/mtlrec.dylib" | tr -d ' ') bytes"
# symaddr: names the addresses of a boot-profile .pcraw timeline (visionos/symaddr.c).
xcrun --sdk xrsimulator clang -target arm64-apple-xros27.0-simulator -O2 -Wall -Wextra -Werror -o "$out/symaddr" "$here/visionos/symaddr.c"
echo "$out/symaddr: $(wc -c < "$out/symaddr" | tr -d ' ') bytes"
# rkprobe: does a RealityKit RealityRenderer start (visionos/rkprobe.swift)?
xcrun --sdk xrsimulator swiftc -target arm64-apple-xros27.0-simulator -O -o "$out/rkprobe" "$here/visionos/rkprobe.swift"
echo "$out/rkprobe: $(wc -c < "$out/rkprobe" | tr -d ' ') bytes"
# exports: names of a loaded image's exports that contain a text (visionos/exports.c).
xcrun --sdk xrsimulator clang -target arm64-apple-xros27.0-simulator -O2 -Wall -Wextra -Werror -o "$out/exports" "$here/visionos/exports.c"
echo "$out/exports: $(wc -c < "$out/exports" | tr -d ' ') bytes"
# shtex: a shared Metal texture, its IOSurface and its handle (visionos/shtex.m).
xcrun --sdk xrsimulator clang -target arm64-apple-xros27.0-simulator -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -framework Foundation -framework Metal -framework IOSurface -o "$out/shtex" "$here/visionos/shtex.m"
echo "$out/shtex: $(wc -c < "$out/shtex" | tr -d ' ') bytes"
