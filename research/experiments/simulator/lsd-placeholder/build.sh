#!/bin/sh
# Builds agent J's probes (home-screen.md §3.3–§3.4, §7) for the iOS simulator
# (macOS only). Output: $OUT (default /tmp/yc-9-J-probes). Run on the Mac with
# `xcrun simctl spawn <throwaway device> <probe> …`, under Ycode as one-shots
# copied into DEV/data/tmp. lstrace.dylib goes into a simulator daemon with
# `xcrun simctl spawn <dev> launchctl setenv DYLD_INSERT_LIBRARIES <path>`
# (LSTRACE_FILTER, LSTRACE_HIDE, LSTRACE_PATCH, LSTRACE_PATCHDIR,
# LSTRACE_PATCHPARENT, LSTRACE_FNDR, LSTRACE_CAPSCLEAR; see the source).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-/tmp/yc-9-J-probes}"
mkdir -p "$out"
T="-target arm64-apple-ios27.0-simulator"
cc() { xcrun --sdk iphonesimulator clang $T "$@"; }
for p in urlprobe fsnprobe miprobe mimeth; do cc -fobjc-arc -O1 -framework Foundation -o "$out/$p" "$here/$p.m"; done
cc -fobjc-arc -O1 -framework Foundation -Wl,-sectcreate,__TEXT,__entitlements,"$here/icprobe.entitlements" -o "$out/icprobe" "$here/icprobe.m"
cc -fobjc-arc -O1 -framework Foundation -Wl,-sectcreate,__TEXT,__entitlements,"$here/ljprobe.entitlements" -o "$out/ljprobe" "$here/ljprobe.m"
for p in csprobe volcaps ids; do cc -O1 -o "$out/$p" "$here/$p.c"; done
cc -dynamiclib -O1 -o "$out/lstrace.dylib" "$here/lstrace.c"
codesign -s - -f "$out/lstrace.dylib" "$out/icprobe" "$out/ljprobe" >/dev/null 2>&1
clang -O1 -o "$out/fndr-mac" "$here/fndr.c"
echo "built probes in $out"
