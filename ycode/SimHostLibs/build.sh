#!/bin/sh
# Builds Ycode's clean-room host libraries (see README.md):
#   out/libsystem_kernel.dylib    /usr/lib/system/libsystem_kernel.dylib
#   out/libsystem_platform.dylib  /usr/lib/system/libsystem_platform.dylib
#   out/libsystem_pthread.dylib   /usr/lib/system/libsystem_pthread.dylib
# Contract: specs/simulator/host-libraries.md sections 2-4.
#
#   sh build.sh          build and self-check all three libraries
#   sh build.sh test     also build and run the platform host unit tests
#   sh build.sh clean    remove out/
#
# Linux (the Thor, the x86-64 workstation): . ~/.local/share/swiftly/env.sh first.
# Tools (override with the variables): CLANG=clang LD64=ld64.lld NM=llvm-nm
# OBJDUMP=llvm-objdump PYTHON=python3 HOST_CC=cc
# YCODE=<path to Ycode's `ycode` tool> (default: ../.build/debug/ycode; build
# it with `swift build` in ycode/). SPEC_DATA=<specs/simulator/data>.

set -eu
LC_ALL=C # one collation for sort and comm
export LC_ALL

here=$(cd "$(dirname "$0")" && pwd)
out="$here/out"
common="$here/common"

CLANG=${CLANG:-clang}
LD64=${LD64:-ld64.lld}
NM=${NM:-llvm-nm}
OBJDUMP=${OBJDUMP:-llvm-objdump}
PYTHON=${PYTHON:-python3}
HOST_CC=${HOST_CC:-cc}
YCODE=${YCODE:-$here/../.build/debug/ycode}
SPEC_DATA=${SPEC_DATA:-$here/../../specs/simulator/data}

die() {
    echo "build.sh: error: $*" >&2
    exit 1
}

say() {
    echo "build.sh: $*"
}

# Objects are compiled for the real Darwin triple, so that clang uses Apple's
# arm64 calling convention (DarwinPCS: variadic arguments on the stack,
# stack arguments packed at natural size and alignment). The Swift 6.4
# toolchain's ld64.lld rejects every input that carries a Darwin platform
# tag ("This version of lld does not support linking for platform ..."), so
# each object's LC_BUILD_VERSION is removed after compiling
# (common/strip_platform.py); the linker writes the dylib's own
# LC_BUILD_VERSION from -platform_version. Do NOT use arm64-apple-none-macho:
# it compiles generic AAPCS64, which is not ABI-compatible with Apple code.
# common/abi_check.py proves the convention on every build.
TARGET=arm64-apple-ios27.0-simulator
CFLAGS="-target $TARGET -std=c11 -nostdlib -ffreestanding -fno-builtin -fno-stack-protector
 -fno-exceptions -fPIC -O2 -fvisibility=hidden -fno-common -fno-strict-aliasing
 -mno-outline-atomics -Wall -Wextra -Werror -I$common"
ASFLAGS="-target $TARGET -I$common"

link_flags() {
    echo "-arch arm64 -platform_version ios-simulator 27.0 27.1 -dylib
 -install_name /usr/lib/system/libsystem_$1.dylib -current_version 1.0.0
 -compatibility_version 1.0.0 -fixup_chains -no_adhoc_codesign"
}

check_tools() {
    for tool in "$CLANG" "$LD64" "$NM" "$OBJDUMP" "$PYTHON"; do
        command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found in PATH"
    done
    [ -x "$YCODE" ] || die "Ycode's tool not found at $YCODE (run 'swift build' in ycode/ or set YCODE=)"
    [ -f "$SPEC_DATA/host-lib-surface-kernel.json" ] || die "surface tables not found in $SPEC_DATA (set SPEC_DATA=)"
}

# compile <source> <object> <extra flags...>
compile() {
    c_src=$1
    c_obj=$2
    shift 2
    # shellcheck disable=SC2086
    case "$c_src" in
    *.S) "$CLANG" $ASFLAGS "$@" -c -o "$c_obj" "$c_src" || die "assembling $c_src failed" ;;
    *.c) "$CLANG" $CFLAGS "$@" -c -o "$c_obj" "$c_src" || die "compiling $c_src failed" ;;
    esac
    "$PYTHON" -I "$common/strip_platform.py" "$c_obj" || die "stripping the platform tag of $c_obj failed"
}

# Fails the build unless the compile pipeline produces DarwinPCS code.
abi_check() {
    # shellcheck disable=SC2086
    "$PYTHON" -I "$common/abi_check.py" --clang "$CLANG" --ld "$LD64" --objdump "$OBJDUMP" \
        --python "$PYTHON" --out "$out/abi-check" -- $CFLAGS || die "the ABI check failed (see above)"
}

# Global symbols an object defines (hidden ones included).
defined_symbols() {
    "$NM" -g --defined-only -j "$1" || die "llvm-nm $1 failed"
}

# build_lib <name> <dependency dylibs...>
build_lib() {
    lib=$1
    shift
    obj="$out/obj/$lib"
    rm -rf "$obj"
    mkdir -p "$obj"
    : > "$obj/defined.txt"
    objects=""

    # 1. Hand-written sources: SimHostLibs/<lib>/*.c and *.S (not tests/).
    nreal=0
    if [ -d "$here/$lib" ]; then
        for src in "$here/$lib"/*.c "$here/$lib"/*.S; do
            [ -f "$src" ] || continue
            o="$obj/real_$(basename "$src").o"
            compile "$src" "$o" "-I$here/$lib"
            defined_symbols "$o" >> "$obj/defined.txt"
            objects="$objects $o"
            nreal=$((nreal + 1))
        done
    fi
    nimpl=$(sort -u "$obj/defined.txt" | wc -l | tr -d ' ')

    # 2. Fallbacks: a whole file is dropped when the hand-written sources
    #    define every global it defines; a partial overlap is an error.
    for src in "$common/fallback/all"/*.c "$common/fallback/$lib"/*.c; do
        [ -f "$src" ] || continue
        o="$obj/fallback_$(basename "$src").o"
        compile "$src" "$o"
        defined_symbols "$o" | sort -u > "$o.syms"
        sort -u "$obj/defined.txt" > "$obj/defined.sorted"
        total=$(wc -l < "$o.syms" | tr -d ' ')
        overlap=$(comm -12 "$o.syms" "$obj/defined.sorted" | wc -l | tr -d ' ')
        if [ "$overlap" -eq 0 ]; then
            cat "$o.syms" >> "$obj/defined.txt"
            objects="$objects $o"
        elif [ "$overlap" -eq "$total" ]; then
            say "libsystem_$lib: fallback $(basename "$src") suppressed by $lib/ sources"
        else
            die "libsystem_$lib: $lib/ defines only part of fallback $(basename "$src") ($overlap of $total symbols); define all or none"
        fi
    done

    # 3. Generated stubs and data for every remaining table symbol.
    "$PYTHON" -I "$common/gen_stubs.py" --lib "$lib" --data-dir "$SPEC_DATA" --common "$common" \
        --defined "$obj/defined.txt" --out "$obj/stubs.S" --manifest "$out/libsystem_$lib.stubs.tsv" \
        || die "stub generation for libsystem_$lib failed"
    compile "$obj/stubs.S" "$obj/stubs.o"
    objects="$objects $obj/stubs.o"

    # 4. Link.
    dylib="$out/libsystem_$lib.dylib"
    rm -f "$dylib"
    # shellcheck disable=SC2046,SC2086
    "$LD64" $(link_flags "$lib") -o "$dylib" $objects "$@" || die "linking libsystem_$lib failed"
    nstub=$(grep -c -v '^#' "$out/libsystem_$lib.stubs.tsv" || true)
    say "libsystem_$lib: $nreal hand-written files ($nimpl symbols), $nstub generated stubs/data"

    # 5. Self-check (fails the build on any mismatch).
    "$PYTHON" -I "$common/verify.py" --lib "$lib" --dylib "$dylib" --data-dir "$SPEC_DATA" \
        --common "$common" --ycode "$YCODE" --nm "$NM" --objdump "$OBJDUMP" \
        || die "libsystem_$lib failed its self-check"

    # 6. A .tbd stub for the libraries that link against this one.
    "$PYTHON" -I "$common/make_tbd.py" --lib "$lib" --dylib "$dylib" --nm "$NM" \
        --out "$out/libsystem_$lib.tbd" || die "writing libsystem_$lib.tbd failed"
}

build_all() {
    check_tools
    mkdir -p "$out"
    abi_check
    build_lib kernel
    # Dependencies are linked through .tbd stubs (see common/make_tbd.py).
    build_lib platform "$out/libsystem_kernel.tbd"
    build_lib pthread "$out/libsystem_kernel.tbd" "$out/libsystem_platform.tbd"
    say "ok"
}

run_tests() {
    command -v "$HOST_CC" >/dev/null 2>&1 || die "host C compiler '$HOST_CC' not found"
    t="$out/host-tests"
    rm -rf "$t"
    mkdir -p "$t"
    objs=""
    for src in "$here/platform"/*.c "$here/platform"/*.S; do
        [ -f "$src" ] || continue
        case "$(basename "$src")" in
        thread_id.c) continue ;; # guest-only (reads TPIDRRO_EL0)
        *.S)
            case "$(uname -m)" in
            aarch64 | arm64) ;;
            *) continue ;;
            esac
            ;;
        esac
        o="$t/$(basename "$src").o"
        "$HOST_CC" -DYC_HOST_TEST -O2 -fno-builtin -fno-strict-aliasing -fvisibility=hidden -Wall -Wextra \
            -I"$common" -I"$here/platform" -c -o "$o" "$src" || die "host compile of $src failed"
        objs="$objs $o"
    done
    "$HOST_CC" -O1 -Wall -pthread -c -o "$t/test_main.o" "$here/platform/tests/test_main.c" \
        || die "host compile of test_main.c failed"
    # shellcheck disable=SC2086
    "$HOST_CC" -pthread -o "$t/platform_tests" "$t/test_main.o" $objs || die "linking the host tests failed"
    "$t/platform_tests" || die "platform host tests failed"

    # Agent Q's pthread host tests (output in out/host-tests-pthread/).
    if [ -f "$here/pthread/tests/run.sh" ]; then
        HOST_CC="$HOST_CC" sh "$here/pthread/tests/run.sh" || die "pthread host tests failed"
    fi
}

case "${1:-all}" in
all) build_all ;;
test)
    build_all
    run_tests
    ;;
hosttest) run_tests ;;
clean) rm -rf "$out" ;;
*) die "usage: sh build.sh [all|test|hosttest|clean]" ;;
esac
