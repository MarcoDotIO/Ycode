#!/bin/sh
# Builds and runs the host unit tests of libsystem_kernel's library-side
# spawn and libproc code (kernel/spawn.c, kernel/libproc.c; see
# test_main.c). arm64 hosts only (macOS or Linux): yc_kernel.h names arm64
# registers. On other hosts it prints a note and succeeds.
#   sh kernel/tests/run.sh        (from ycode/SimHostLibs)
# HOST_CC overrides the compiler (default cc). Output: out/host-tests-kernel/.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)   # SimHostLibs/kernel
root=$(cd "$here/.." && pwd)             # SimHostLibs
HOST_CC=${HOST_CC:-cc}
case "$(uname -m)" in
aarch64 | arm64) ;;
*)
    echo "kernel host tests: skipped (not an arm64 host)"
    exit 0
    ;;
esac
t="$root/out/host-tests-kernel"
rm -rf "$t"
mkdir -p "$t"
objs=""
for src in "$here/spawn.c" "$here/libproc.c"; do
    o="$t/$(basename "$src").o"
    "$HOST_CC" -DYC_HOST_TEST -O2 -fno-builtin -fno-strict-aliasing -fvisibility=hidden -Wall -Wextra \
        -I"$root/common" -I"$here" -c -o "$o" "$src"
    objs="$objs $o"
done
"$HOST_CC" -O1 -Wall -Wextra -c -o "$t/test_main.o" "$here/tests/test_main.c"
# shellcheck disable=SC2086
"$HOST_CC" -o "$t/kernel_tests" "$t/test_main.o" $objs
"$t/kernel_tests"
