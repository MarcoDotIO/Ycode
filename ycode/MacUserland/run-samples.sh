#!/bin/sh
# Runs the Milestone A samples under `ycode-simd --macos` and checks their
# standard output and exit status (specs/macos/macos-apps.md §9.1).
#
#   sh run-samples.sh <ycode-simd> <directory with hello fileio threads dispatch [hello-swift]>
#
# The C samples are built on a Mac:
#   clang -target arm64-apple-macos14.0 -O1 -o <dir>/<name> samples/<name>.c
# hello-swift is built by build.sh (out/samples/). Output of each run goes
# to $OUT (default ./sample-runs).

set -u
simd=${1:?usage: run-samples.sh <ycode-simd> <samples dir>}
dir=${2:?usage: run-samples.sh <ycode-simd> <samples dir>}
here=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$PWD/sample-runs}
mkdir -p "$OUT"
failed=0
passed=0

# check <name> <expected status> <expected stdout file> <ycode-simd arguments...>
check() {
    name=$1
    want_status=$2
    want=$3
    shift 3
    "$simd" --macos-root "${MACOS_ROOT:-$here/out/root}" --timeout-ms 60000 "$@" \
        > "$OUT/$name.out" 2> "$OUT/$name.err"
    status=$?
    if [ "$status" -ne "$want_status" ]; then
        echo "FAIL $name: exit status $status, expected $want_status (stderr: $OUT/$name.err)"
        failed=$((failed + 1))
    elif ! diff -u "$want" "$OUT/$name.out" > "$OUT/$name.diff"; then
        echo "FAIL $name: output differs ($OUT/$name.diff)"
        failed=$((failed + 1))
    else
        echo "ok   $name (exit $status)"
        passed=$((passed + 1))
    fi
}

exp="$OUT/expected"
mkdir -p "$exp"

cat > "$exp/hello" <<'EOF'
hello from a macOS arm64 program (argc 3)
argv[1] = first
argv[2] = second arg
YCODE_SAMPLE = from ycode-simd
numbers: -42 42 beef -1234567890123 9007199254740993     7|7    | 003.2 str Z %
snprintf-64
EOF
check hello 0 "$exp/hello" --macos "$dir/hello" --env YCODE_SAMPLE="from ycode-simd" --exec-args first "second arg"

cat > "$exp/hello-fail" <<'EOF'
hello from a macOS arm64 program (argc 2)
argv[1] = fail
YCODE_SAMPLE = (unset)
numbers: -42 42 beef -1234567890123 9007199254740993     7|7    | 003.2 str Z %
snprintf-64
EOF
check hello-fail 3 "$exp/hello-fail" --macos "$dir/hello" --exec-args fail

cat > "$exp/fileio" <<'EOF'
size 790
read 100 lines, last 99
end 795, tail tail
missing file: No such file or directory
fileio ok
EOF
check fileio 0 "$exp/fileio" --macos "$dir/fileio"

cat > "$exp/threads" <<'EOF'
counter 80000 (expected 80000), join sum 308 (expected 308)
EOF
check threads 0 "$exp/threads" --macos "$dir/threads"

cat > "$exp/dispatch" <<'EOF'
sum of squares 338350 (expected 338350)
apply 1000 (expected 1000)
serial order 0 1 2
once 1
main queue after 20 ms
EOF
check dispatch 0 "$exp/dispatch" --macos "$dir/dispatch"

swift_sample="$dir/hello-swift"
[ -f "$swift_sample" ] || swift_sample="$here/out/samples/hello-swift"
if [ -f "$swift_sample" ]; then
    cat > "$exp/hello-swift" <<'EOF'
hello from Swift on Ycode
fibonacci: 0 1 1 2 3 5 8 13 21 34 55 89 144 233 377
a: 3
b: 2
c: 1
swift ok
EOF
    check hello-swift 0 "$exp/hello-swift" --macos "$swift_sample"
else
    echo "skip hello-swift (not built)"
fi

# The stage-B samples (swift/build.sh, on a Mac): FoundationEssentials and
# Swift Concurrency. They need the Swift libraries in the userland root.
foundation_sample="$dir/foundation"
[ -f "$foundation_sample" ] || foundation_sample="$here/out/samples/foundation"
if [ -f "$foundation_sample" ] && [ -f "${MACOS_ROOT:-$here/out/root}/usr/lib/swift/libFoundationEssentials.dylib" ]; then
    check foundation 0 "$here/samples/foundation.expected" --macos "$foundation_sample"
    concurrency_sample="$(dirname "$foundation_sample")/concurrency"
    [ -f "$concurrency_sample" ] && check concurrency 0 "$here/samples/concurrency.expected" --macos "$concurrency_sample"
else
    echo "skip foundation and concurrency (not built: sh swift/build.sh on a Mac)"
fi

echo "run-samples: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
