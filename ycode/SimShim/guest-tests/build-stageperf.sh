#!/bin/sh
# Builds the performance probes for the iOS simulator platform
# (specs/simulator/fast-traps.md section 7). Runs on macOS only.
#   ../out/guest-tests/stageperf/<probe>   arm64, LC_BUILD_VERSION platform 7
# Each probe re-executes its own path (argv[0]) with a mode argument for its
# children; stage4b/probe_util.h holds the shared helpers. The output
# directory is git-ignored; copy it to the Thor with rsync.
# Usage: build-stageperf.sh [probe ...]   (default: every p_*.c in stageperf/)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/../out/guest-tests/stageperf}"
[ "$(uname -s)" = "Darwin" ] || { echo "build-stageperf.sh: needs macOS" >&2; exit 1; }
mkdir -p "$out"
if [ $# -eq 0 ]; then set -- $(cd "$here/stageperf" && ls p_*.c | sed 's/\.c$//'); fi
for probe in "$@"; do
    case "$probe" in
    p_loadtap)  # a dylib, inserted with DYLD_INSERT_LIBRARIES
        xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2 -Wall -Wextra -Werror \
            -dynamiclib -install_name @executable_path/libp_loadtap.dylib \
            -o "$out/libp_loadtap.dylib" "$here/stageperf/$probe.c"
        echo "$out/libp_loadtap.dylib: $(wc -c < "$out/libp_loadtap.dylib" | tr -d ' ') bytes"
        continue ;;
    p_cpufeat_bench)  # links the frameworks it measures (cpu-features.md section 7.3)
        xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2 -Wall -Wextra -Werror \
            -framework Accelerate -framework JavaScriptCore -framework CoreFoundation -framework CoreGraphics \
            -framework ImageIO -lcompression -o "$out/$probe" "$here/stageperf/$probe.c"
        echo "$out/$probe: $(wc -c < "$out/$probe" | tr -d ' ') bytes"
        continue ;;
    esac
    xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2 -Wall -Wextra -Werror \
        -o "$out/$probe" "$here/stageperf/$probe.c"
    echo "$out/$probe: $(wc -c < "$out/$probe" | tr -d ' ') bytes"
done
echo "build-stageperf.sh: ok"
