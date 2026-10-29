#!/bin/sh
# Builds Ycode's guest capture layer libYcodeCamera.dylib (camera/;
# specs/simulator/camera.md "Ycode implementation") for the iOS simulator
# platform. Runs on macOS only (the iOS simulator SDK's public headers and
# stubs). The library links no capture framework: AVFoundation is reached
# at run time, once the app has it.
#   out/libYcodeCamera.dylib
# Copy it into the guest-tools directory on the simulator host (next to
# ylaunch) or pass ycode-simd --camera-library; with the device's camera on,
# ycode-simd stages it into the device and the kernel inserts it into apps.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/out}"
[ "$(uname -s)" = "Darwin" ] || { echo "SimGuestAgents/build-camera.sh: needs macOS" >&2; exit 1; }
mkdir -p "$out/obj-camera"
cc="xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2 -Wall -Wextra -Werror -Wno-unused-parameter -fvisibility=hidden"
src="$here/camera"
$cc -fobjc-arc -c -o "$out/obj-camera/YCHost.o" "$src/YCHost.m"
$cc -fobjc-arc -c -o "$out/obj-camera/YCCapture.o" "$src/YCCapture.m"
$cc -fobjc-arc -c -o "$out/obj-camera/YCInit.o" "$src/YCInit.m"
$cc -fno-objc-arc -c -o "$out/obj-camera/YCRuntime.o" "$src/YCRuntime.m"
$cc -c -o "$out/obj-camera/YCPixels.o" "$src/YCPixels.c"
$cc -dynamiclib -install_name @rpath/libYcodeCamera.dylib \
    -framework Foundation -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework IOSurface \
    -framework QuartzCore -framework CoreGraphics -framework ImageIO \
    -o "$out/libYcodeCamera.dylib" "$out/obj-camera/"*.o
if xcrun dyld_info -dependents "$out/libYcodeCamera.dylib" 2>/dev/null | grep -q AVFoundation \
   || xcrun otool -L "$out/libYcodeCamera.dylib" | grep -q AVFoundation; then
    echo "SimGuestAgents/build-camera.sh: the library must not link AVFoundation" >&2
    exit 1
fi
echo "$out/libYcodeCamera.dylib: $(wc -c < "$out/libYcodeCamera.dylib" | tr -d ' ') bytes"
echo "SimGuestAgents/build-camera.sh: ok"
