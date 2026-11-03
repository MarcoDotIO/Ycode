#!/bin/sh
# Builds Ycode's macOS userland root (specs/macos/libsystem.md §9):
#   out/root/usr/lib/dyld                         Ycode's dynamic linker (dyld.md)
#   out/root/usr/lib/libSystem.B.dylib            Ycode's libSystem (libsystem.md)
#   out/root/usr/lib/system/libsystem_*.dylib     SimHostLibs' three libraries, tagged macOS
#   out/samples/hello-swift                       the Embedded Swift sample (if swiftc exists)
#
#   sh build.sh          build everything and run the host unit tests
#   sh build.sh test     only the host unit tests
#   sh build.sh clean    remove out/
#
# Needs SimHostLibs/out (sh SimHostLibs/build.sh) for the host libraries.
# Linux: . ~/.local/share/swiftly/env.sh first. Tools (override with the
# variables): CLANG LD64 NM AR SWIFTC PYTHON HOST_CC.

set -eu
LC_ALL=C
export LC_ALL

here=$(cd "$(dirname "$0")" && pwd)
out="$here/out"
hostlibs=${HOST_LIBS:-$here/../SimHostLibs/out}
strip_platform="$here/../SimHostLibs/common/strip_platform.py"
tool="$here/tools/macho_tool.py"

CLANG=${CLANG:-clang}
LD64=${LD64:-ld64.lld}
NM=${NM:-llvm-nm}
AR=${AR:-llvm-ar}
SWIFTC=${SWIFTC:-swiftc}
PYTHON=${PYTHON:-python3}
HOST_CC=${HOST_CC:-cc}

MACOS_MIN=14.0
TARGET=arm64-apple-macos$MACOS_MIN
CFLAGS="-target $TARGET -std=c11 -nostdlib -ffreestanding -fno-builtin -fno-stack-protector
 -fno-exceptions -fPIC -O2 -fvisibility=hidden -fno-common -fno-strict-aliasing
 -mno-outline-atomics -Wall -Wextra -Werror -I$here/common"
LINK="-arch arm64 -platform_version macos $MACOS_MIN $MACOS_MIN -no_adhoc_codesign"

die() {
    echo "build.sh: error: $*" >&2
    exit 1
}
say() { echo "build.sh: $*"; }

# compile <source> <object> [flags...]: compile, then strip the platform
# tag (the Swift toolchain's ld64.lld rejects tagged inputs; see
# SimHostLibs/build.sh).
compile() {
    src=$1
    obj=$2
    shift 2
    # shellcheck disable=SC2086
    "$CLANG" $CFLAGS "$@" -c -o "$obj" "$src" || die "compiling $src failed"
    "$PYTHON" -I "$strip_platform" "$obj" || die "stripping $obj failed"
}

build_dyld() {
    o="$out/obj/dyld"
    mkdir -p "$o"
    for f in ydl_main ydl_format; do compile "$here/dyld/$f.c" "$o/$f.o" "-I$here/dyld"; done
    compile "$here/dyld/ydl_start.S" "$o/ydl_start.o"
    # An MH_EXECUTE without libraries, entered at __ydl_start (dyld.md §10).
    # shellcheck disable=SC2086
    "$LD64" $LINK -e __ydl_start -o "$out/root/usr/lib/dyld" "$o/ydl_start.o" "$o/ydl_main.o" "$o/ydl_format.o" \
        || die "linking the dyld failed"
    "$PYTHON" -I "$tool" no-fixups "$out/root/usr/lib/dyld" || die "the dyld must have no fixups"
}

build_libsystem() {
    o="$out/obj/libsystem"
    t="$out/tbd"
    mkdir -p "$o" "$t"
    # The host libraries' link stubs, retargeted to macOS.
    reexports=""
    for lib in kernel platform pthread; do
        [ -f "$hostlibs/libsystem_$lib.tbd" ] || die "$hostlibs/libsystem_$lib.tbd is missing (run sh SimHostLibs/build.sh)"
        sed 's/arm64-ios-simulator/arm64-macos/g' "$hostlibs/libsystem_$lib.tbd" > "$t/libsystem_$lib.tbd"
        reexports="$reexports -reexport_library $t/libsystem_$lib.tbd"
    done
    objects=""
    for src in "$here/libsystem"/*.c; do
        obj="$o/$(basename "$src" .c).o"
        compile "$src" "$obj" "-I$here/libsystem"
        objects="$objects $obj"
    done
    dylib="$out/root/usr/lib/libSystem.B.dylib"
    # shellcheck disable=SC2086
    "$LD64" $LINK -dylib -install_name /usr/lib/libSystem.B.dylib -current_version 1.0.0 \
        -compatibility_version 1.0.0 -fixup_chains -o "$dylib" $objects $reexports || die "linking libSystem failed"
    # libSystem's own link stub: its exports and the re-exported ones.
    "$NM" -g --defined-only -j "$dylib" > "$t/libSystem.own.txt"
    for lib in kernel platform pthread; do
        "$NM" -g --defined-only -j "$hostlibs/libsystem_$lib.dylib" > "$t/libsystem_$lib.syms.txt"
    done
    "$PYTHON" -I "$tool" tbd "$t/libSystem.tbd" /usr/lib/libSystem.B.dylib "$t/libSystem.own.txt" \
        "$t/libsystem_kernel.syms.txt" "$t/libsystem_platform.syms.txt" "$t/libsystem_pthread.syms.txt"
    say "libSystem: $(wc -l < "$t/libSystem.own.txt" | tr -d ' ') own exports"
}

install_host_libraries() {
    mkdir -p "$out/root/usr/lib/system"
    for lib in kernel platform pthread; do
        dst="$out/root/usr/lib/system/libsystem_$lib.dylib"
        cp "$hostlibs/libsystem_$lib.dylib" "$dst"
        "$PYTHON" -I "$tool" retag "$dst" 1 "$MACOS_MIN" "$MACOS_MIN" || die "retagging $dst failed"
    done
}

# The Embedded Swift sample (libsystem.md §10): compiled for arm64-apple-ios
# (the open toolchain's Embedded standard library), linked as macOS.
build_swift_sample() {
    if ! command -v "$SWIFTC" >/dev/null 2>&1; then
        say "no swiftc: the Swift sample is skipped"
        return 0
    fi
    o="$out/obj/swift"
    rm -rf "$o"
    mkdir -p "$o/tables" "$out/samples"
    "$SWIFTC" -target arm64-apple-ios18.0 -enable-experimental-feature Embedded \
        -enable-experimental-feature Extern -wmo -Osize -parse-as-library \
        -c "$here/samples/hello.swift" -o "$o/hello.o" || die "compiling hello.swift failed"
    resource=$(dirname "$(command -v "$SWIFTC")")/../lib/swift/embedded/arm64-apple-ios
    if [ ! -d "$resource" ]; then
        resource=$("$SWIFTC" -print-target-info -target arm64-apple-ios18.0 2>/dev/null \
            | sed -n 's/.*"runtimeResourcePath": "\(.*\)".*/\1/p')/embedded/arm64-apple-ios
    fi
    tables="$resource/libswiftUnicodeDataTables.a"
    [ -f "$tables" ] || die "no $tables"
    (cd "$o/tables" && "$AR" x "$tables") || die "extracting $tables failed"
    "$PYTHON" -I "$strip_platform" "$o/hello.o" "$o/tables"/*.o || die "stripping the Swift objects failed"
    # shellcheck disable=SC2086
    "$LD64" $LINK -o "$out/samples/hello-swift" "$o/hello.o" "$o/tables"/*.o "$out/tbd/libSystem.tbd" \
        || die "linking hello-swift failed"
    say "samples/hello-swift"
}

run_tests() {
    t="$out/host-tests"
    mkdir -p "$t"
    "$HOST_CC" -O1 -Wall -Wextra -I"$here/common" -I"$here/dyld" -o "$t/ydl_format_test" \
        "$here/tests/ydl_format_test.c" "$here/dyld/ydl_format.c" || die "building the host tests failed"
    "$t/ydl_format_test" || die "host tests failed"
}

case "${1:-all}" in
all)
    mkdir -p "$out/root/usr/lib"
    build_dyld
    build_libsystem
    install_host_libraries
    build_swift_sample
    run_tests
    say "ok: $out/root"
    ;;
test) run_tests ;;
clean) rm -rf "$out" ;;
*) die "usage: sh build.sh [all|test|clean]" ;;
esac
