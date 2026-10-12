#!/bin/sh
# Builds the stage-4c guest probes (host bootstrap) for the iOS simulator
# platform (specs/simulator/stage4c-contract.md §8). Runs on macOS only.
#   ../out/guest-tests/stage4c/<probe>   arm64, LC_BUILD_VERSION platform 7
# Usage: build-stage4c.sh [probe ...]   (default: every p_*.c in stage4c/)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/../out/guest-tests/stage4c}"
[ "$(uname -s)" = "Darwin" ] || { echo "build-stage4c.sh: needs macOS" >&2; exit 1; }
mkdir -p "$out"
if [ $# -eq 0 ]; then set -- $(cd "$here/stage4c" && ls p_*.c | sed 's/\.c$//'); fi
for probe in "$@"; do
    xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2 -Wall -Wextra -Werror \
        -o "$out/$probe" "$here/stage4c/$probe.c"
    echo "$out/$probe: $(wc -c < "$out/$probe" | tr -d ' ') bytes"
done
echo "build-stage4c.sh: ok"
