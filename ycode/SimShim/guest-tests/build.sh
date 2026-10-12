#!/bin/sh
# Builds the stage-3 guest test programs for the iOS simulator platform
# (specs/simulator/stage3-contract.md section 9). Runs on macOS only.
#   ../out/guest-tests/hello   arm64, LC_BUILD_VERSION platform 7
# The output directory is git-ignored. Copy it to the Thor with rsync.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="$here/../out/guest-tests"

die() {
    echo "guest-tests/build.sh: error: $*" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || die "this script needs macOS (xcrun and the iOS simulator SDK)"
command -v xcrun >/dev/null 2>&1 || die "xcrun not found"

mkdir -p "$out"
out=$(cd "$out" && pwd)

xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2 \
    -o "$out/hello" "$here/hello.c" \
    || die "compiling hello.c failed"
[ -s "$out/hello" ] || die "hello is empty"

# LC_BUILD_VERSION must say platform 7 (iOS simulator). otool prints the
# platform as a number or as a name, depending on its version.
platform=$(xcrun otool -l "$out/hello" |
    awk '/cmd LC_BUILD_VERSION/ { inbv = 1; next }
         inbv && $1 == "platform" { print $2; exit }')
case "$platform" in
    7|IOSSIMULATOR) ;;
    "") die "hello has no LC_BUILD_VERSION" ;;
    *) die "hello is platform '$platform', expected 7 (iOS simulator)" ;;
esac
arch=$(xcrun lipo -archs "$out/hello")
[ "$arch" = "arm64" ] || die "hello is '$arch', expected arm64 only"

size=$(wc -c < "$out/hello" | tr -d ' ')
echo "$out/hello: $size bytes, arm64, platform $platform"
echo "guest-tests/build.sh: ok"
