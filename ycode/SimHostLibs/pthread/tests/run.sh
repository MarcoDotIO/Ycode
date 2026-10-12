#!/bin/sh
# Builds and runs the host unit tests of Ycode's libsystem_pthread sources
# (see test_main.c). Works on Linux and macOS hosts:
#   sh pthread/tests/run.sh        (from ycode/SimHostLibs)
# HOST_CC overrides the compiler (default cc). Output: out/host-tests-pthread/.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)   # SimHostLibs/pthread
root=$(cd "$here/.." && pwd)             # SimHostLibs
HOST_CC=${HOST_CC:-cc}
t="$root/out/host-tests-pthread"
rm -rf "$t"
mkdir -p "$t"
objs=""
for src in "$here"/*.c; do
    o="$t/$(basename "$src").o"
    "$HOST_CC" -DYC_HOST_TEST -O2 -fno-builtin -fno-strict-aliasing -fvisibility=hidden -Wall -Wextra \
        -I"$root/common" -I"$here" -c -o "$o" "$src"
    objs="$objs $o"
done
"$HOST_CC" -O1 -Wall -pthread -c -o "$t/test_main.o" "$here/tests/test_main.c"
# shellcheck disable=SC2086
"$HOST_CC" -pthread -o "$t/pthread_tests" "$t/test_main.o" $objs
"$t/pthread_tests"
