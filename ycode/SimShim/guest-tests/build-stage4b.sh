#!/bin/sh
# Builds the stage-4b guest probes (multiple processes) for the iOS simulator platform
# (specs/simulator/stage4b-contract.md section 1). Runs on macOS only.
#   ../out/guest-tests/stage4b/<probe>   arm64, LC_BUILD_VERSION platform 7
# Each probe re-executes its own path (argv[0]) with a mode argument for its
# children. stage4b/probe_util.h holds the shared helpers.
# The output directory is git-ignored. Copy it to the Thor with rsync.
# Usage: build-stage4b.sh [probe ...]   (default: every p_*.c in stage4b/)

set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="$here/../out/guest-tests/stage4b"

die() {
    echo "guest-tests/build-stage4b.sh: error: $*" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || die "this script needs macOS (xcrun and the iOS simulator SDK)"
command -v xcrun >/dev/null 2>&1 || die "xcrun not found"

mkdir -p "$out"
out=$(cd "$out" && pwd)

if [ $# -eq 0 ]; then
    set -- $(cd "$here/stage4b" && ls p_*.c | sed 's/\.c$//')
fi

for probe in "$@"; do
    src="$here/stage4b/$probe.c"
    [ -f "$src" ] || die "no source $src"
    xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2 -Wall -Wextra -Werror \
        -o "$out/$probe" "$src" \
        || die "compiling $probe.c failed"
    [ -s "$out/$probe" ] || die "$probe is empty"

    # LC_BUILD_VERSION must say platform 7 (iOS simulator).
    platform=$(xcrun otool -l "$out/$probe" |
        awk '/cmd LC_BUILD_VERSION/ { inbv = 1; next }
             inbv && $1 == "platform" { print $2; exit }')
    case "$platform" in
        7|IOSSIMULATOR) ;;
        "") die "$probe has no LC_BUILD_VERSION" ;;
        *) die "$probe is platform '$platform', expected 7 (iOS simulator)" ;;
    esac
    arch=$(xcrun lipo -archs "$out/$probe")
    [ "$arch" = "arm64" ] || die "$probe is '$arch', expected arm64 only"
    size=$(wc -c < "$out/$probe" | tr -d ' ')
    echo "$out/$probe: $size bytes, arm64, platform $platform"
done
echo "guest-tests/build-stage4b.sh: ok"
