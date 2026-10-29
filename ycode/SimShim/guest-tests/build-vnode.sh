#!/bin/sh
# Builds the kqueue EVFILT_VNODE guest probe (specs/simulator/
# threads-and-events.md §3.10) for the iOS simulator platform. Runs on
# macOS only.
#   ../out/guest-tests/vnode/p_vnode   C: a file's and a directory's notes for
#       the probe's own changes, accumulation, EV_CLEAR, EV_ONESHOT, a child
#       process's write, a dispatch vnode source; `watch <path> <s>` prints
#       a path's notes as they come (host writes)
# Copy the output to the Thor; run there with
#   ycode-simd --device D --oneshot "<dir>/p_vnode <guest folder>"
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/../out/guest-tests/vnode}"
[ "$(uname -s)" = "Darwin" ] || { echo "build-vnode.sh: needs macOS" >&2; exit 1; }
mkdir -p "$out"
flags="-target arm64-apple-ios27.0-simulator -O2 -Wall -Wextra -Werror"
xcrun --sdk iphonesimulator clang $flags -o "$out/p_vnode" "$here/vnode/p_vnode.c"
echo "$out/p_vnode: $(wc -c < "$out/p_vnode" | tr -d ' ') bytes"
echo "build-vnode.sh: ok"
