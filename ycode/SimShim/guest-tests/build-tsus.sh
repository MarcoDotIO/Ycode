#!/bin/sh
# Builds the Mach suspension guest probes (specs/simulator/
# threads-and-events.md §1.6) for the iOS simulator platform. Runs on
# macOS only.
#   ../out/guest-tests/tsus/p_tsus   C: thread_suspend/resume/get_state/
#       set_state/thread_info of a spinning, a self-suspending and a blocked
#       thread; task_suspend/resume of a child; POSIX_SPAWN_START_SUSPENDED
#   ../out/guest-tests/tsus/p_jsgc   C, JavaScriptCore: threads of one
#       context group keep objects referenced from their stacks while they
#       allocate and collect (the collector suspends and scans the others)
# Copy the outputs into a device's data folder on the Linux host; run there with
#   ycode-simd --device D --oneshot "<D>/data/tmp/tsus/p_tsus"
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/../out/guest-tests/tsus}"
[ "$(uname -s)" = "Darwin" ] || { echo "build-tsus.sh: needs macOS" >&2; exit 1; }
mkdir -p "$out"
flags="-target arm64-apple-ios27.0-simulator -O2 -Wall -Wextra -Werror"
xcrun --sdk iphonesimulator clang $flags -o "$out/p_tsus" "$here/tsus/p_tsus.c"
xcrun --sdk iphonesimulator clang $flags -o "$out/p_jsgc" "$here/tsus/p_jsgc.c" -framework JavaScriptCore
for p in p_tsus p_jsgc; do echo "$out/$p: $(wc -c < "$out/$p" | tr -d ' ') bytes"; done
echo "build-tsus.sh: ok"
