#!/bin/sh
# Builds the file-system and file-event guest probe (specs/simulator/
# file-system-features.md, fsevents-host.md "Ycode implementation") for the
# iOS simulator platform. Runs on macOS only.
#   ../out/guest-tests/fsevents/p_fsevents   C: volume capabilities, document IDs,
#       write generation counts, clonefile, renamex_np, an FSEvents stream
# Copy the output to the Thor; run there with
#   ycode-simd --device D --oneshot "<dir>/p_fsevents <guest folder>"
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/../out/guest-tests/fsevents}"
[ "$(uname -s)" = "Darwin" ] || { echo "build-fsevents.sh: needs macOS" >&2; exit 1; }
mkdir -p "$out"
flags="-target arm64-apple-ios27.0-simulator -O2 -Wall -Wextra -Werror"
xcrun --sdk iphonesimulator clang $flags -framework CoreServices -framework CoreFoundation \
    -o "$out/p_fsevents" "$here/fsevents/p_fsevents.c"
echo "$out/p_fsevents: $(wc -c < "$out/p_fsevents" | tr -d ' ') bytes"
echo "build-fsevents.sh: ok"
