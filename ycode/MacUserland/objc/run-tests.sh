#!/bin/sh
# Conformance tests of Ycode's Objective-C runtime (specs/macos/
# objc-runtime.md §12). Each tests/t_*.m prints one line per check; the
# expected output in tests/<name>.expected is what the program prints on a
# Mac with the Mac's own runtime.
#
#   sh run-tests.sh mac <out dir>
#       (Mac) builds every test three ways with bench/build-mac.sh and
#       checks the Mac's runtime and Ycode's runtime (native) against the
#       expected output. Leaves <out>/<name> for ycode-simd.
#   sh run-tests.sh simd <ycode-simd> <dir with the test programs>
#       (arm64 Linux) runs each program under ycode-simd --macos with the
#       userland root (MACOS_ROOT, default ../out/root) and checks it.
set -u
here=$(cd "$(dirname "$0")" && pwd)
mode=${1:?usage: run-tests.sh mac <out> | simd <ycode-simd> <dir>}
passed=0
failed=0
tests="t_message t_memory t_arc t_runtime t_threads"

flags_for() {
    case "$1" in
    t_arc) echo "-fobjc-arc" ;;
    *) echo "" ;;
    esac
}

check() { # check <label> <expected> <actual> <status>
    if [ "$4" -ne 0 ]; then
        echo "FAIL $1: exit status $4"
        failed=$((failed + 1))
    elif ! diff -u "$2" "$3" > "$3.diff"; then
        echo "FAIL $1: output differs ($3.diff)"
        failed=$((failed + 1))
    else
        echo "ok   $1"
        passed=$((passed + 1))
    fi
}

case "$mode" in
mac)
    out=${2:?usage: run-tests.sh mac <out dir>}
    mkdir -p "$out"
    for t in $tests; do
        CFLAGS=$(flags_for "$t") sh "$here/bench/build-mac.sh" "$out" "$here/tests/$t.m" > "$out/$t.build.log" 2>&1 \
            || { echo "FAIL $t: build ($out/$t.build.log)"; failed=$((failed + 1)); continue; }
        "$out/$t-apple" > "$out/$t.apple.out" 2>&1
        check "$t (Mac runtime)" "$here/tests/$t.expected" "$out/$t.apple.out" $?
        "$out/$t-ycode" > "$out/$t.ycode.out" 2>&1
        check "$t (Ycode runtime, native)" "$here/tests/$t.expected" "$out/$t.ycode.out" $?
    done
    ;;
simd)
    simd=${2:?usage: run-tests.sh simd <ycode-simd> <dir>}
    dir=${3:?usage: run-tests.sh simd <ycode-simd> <dir>}
    out=${OUT:-$PWD/objc-test-runs}
    mkdir -p "$out"
    for t in $tests; do
        "$simd" --macos-root "${MACOS_ROOT:-$here/../out/root}" --timeout-ms 120000 --macos "$dir/$t" \
            > "$out/$t.out" 2> "$out/$t.err"
        check "$t (ycode-simd)" "$here/tests/$t.expected" "$out/$t.out" $?
    done
    ;;
*)
    echo "usage: run-tests.sh mac <out> | simd <ycode-simd> <dir>" >&2
    exit 2
    ;;
esac
echo "run-tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
