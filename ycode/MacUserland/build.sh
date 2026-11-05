#!/bin/sh
# Builds Ycode's macOS userland root (specs/macos/libsystem.md §9):
#   out/root/usr/lib/dyld                         Ycode's dynamic linker (dyld.md)
#   out/root/usr/lib/libSystem.B.dylib            Ycode's libSystem (libsystem.md)
#   out/root/usr/lib/system/libsystem_*.dylib     SimHostLibs' three libraries, tagged macOS
#   out/root/usr/lib/libobjc.A.dylib              Ycode's Objective-C runtime (objc-runtime.md; needs cargo)
#   out/samples/hello-swift                       the Embedded Swift sample (if swiftc exists)
#
#   sh build.sh          build everything and run the host unit tests
#   sh build.sh test     only the host unit tests
#   sh build.sh objc     only libobjc.A.dylib (after a full build)
#   sh build.sh clean    remove out/
#
# Needs SimHostLibs/out (sh SimHostLibs/build.sh) for the host libraries,
# and LLVM's libc and compiler-rt sources for libSystem's math library and
# compiler-runtime helpers (libsystem.md §13): LLVM_PROJECT names an
# llvm-project checkout; without it, sources.sh fetches one into out/src.
# Linux: . ~/.local/share/swiftly/env.sh first. Tools (override with the
# variables): CLANG LD64 NM AR SWIFTC PYTHON HOST_CC CARGO. The Objective-C
# runtime needs a Rust toolchain with the aarch64-apple-darwin standard
# library (rustup target add aarch64-apple-darwin); without cargo it is skipped.

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
CARGO=${CARGO:-cargo}
LLVM_PROJECT=${LLVM_PROJECT:-$out/src/llvm-project}

MACOS_MIN=14.0
TARGET=arm64-apple-macos$MACOS_MIN
CFLAGS="-target $TARGET -std=c11 -nostdlib -ffreestanding -fno-builtin -fno-stack-protector
 -fno-exceptions -fPIC -O2 -fvisibility=hidden -fno-common -fno-strict-aliasing
 -mno-outline-atomics -Wall -Wextra -Werror -I$here/common"
# LLVM's libc (libsystem.md §13): freestanding C++, its own namespace, the
# generic (non-Darwin) floating-point environment code, errno through
# __error(), no errno from math functions (Darwin's math_errhandling).
LIBC_CXXFLAGS="-x c++ -target $TARGET -std=c++17 -nostdlib -ffreestanding -nostdinc++ -fno-exceptions -fno-rtti
 -fno-stack-protector -fPIC -O2 -fvisibility=hidden -mno-outline-atomics -U__APPLE__ -U__MACH__ -DNDEBUG
 -DLIBC_COPT_USE_C_ASSERT -DLIBC_FULL_BUILD -DLIBC_NAMESPACE=__ycode_libc
 -DLIBC_ERRNO_MODE=LIBC_ERRNO_MODE_EXTERNAL -DLIBC_MATH=LIBC_MATH_NO_ERRNO"
# compiler-rt's 128-bit integer and conversion helpers (exported).
BUILTINS="divti3 modti3 udivti3 umodti3 udivmodti4 floattidf floattisf floatuntidf floatuntisf fixdfti fixsfti
 fixunsdfti fixunssfti muloti4 mulodi4 multi3 ashlti3 ashrti3 lshrti3 popcountti2 clzti2 ctzti2 negti2"
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

need_llvm_project() {
    if [ ! -f "$LLVM_PROJECT/libc/src/math/generic/sin.cpp" ]; then
        [ "$LLVM_PROJECT" = "$out/src/llvm-project" ] || die "LLVM_PROJECT=$LLVM_PROJECT has no libc sources"
        sh "$here/sources.sh" "$out/src" llvm-project || die "fetching llvm-project failed"
    fi
}

# compile_cxx <source> <object> [flags...]: LLVM libc C++, platform tag
# stripped as for C.
compile_cxx() {
    src=$1
    obj=$2
    shift 2
    # shellcheck disable=SC2086
    "$CLANG" $LIBC_CXXFLAGS "-I$out/obj/libc-include" "-I$LLVM_PROJECT/libc" "-isystem$LLVM_PROJECT/libc/include" \
        "$@" -c -o "$obj" "$src" || die "compiling $src failed"
    "$PYTHON" -I "$strip_platform" "$obj" || die "stripping $obj failed"
}

# libSystem's math library and floating-point parsing from LLVM's libc:
# llvm_libc.cpp names each function; every LLVM libc function it calls is
# compiled from libc/src/{math/generic,stdlib}/<name>.cpp.
build_llvm_libc() {
    o="$out/obj/libc"
    rm -rf "$o"
    mkdir -p "$o" "$out/obj/libc-include"
    echo '#define assert(x) ((void)0)' > "$out/obj/libc-include/assert.h"
    compile_cxx "$here/libsystem/llvm_libc.cpp" "$o/llvm_libc.o"
    names=$("$NM" -u "$o/llvm_libc.o" | sed -n 's/^__ZN12__ycode_libc[0-9]*\([a-z0-9_]*\)E.*/\1/p' | sort -u)
    for name in $names; do
        src="$LLVM_PROJECT/libc/src/math/generic/$name.cpp"
        [ -f "$src" ] || src="$LLVM_PROJECT/libc/src/stdlib/$name.cpp"
        [ -f "$src" ] || die "LLVM libc has no $name"
        compile_cxx "$src" "$o/$name.o"
    done
    for helper in math/generic/common_constants math/generic/explogxf math/generic/inv_trigf_utils errno/libc_errno; do
        compile_cxx "$LLVM_PROJECT/libc/src/$helper.cpp" "$o/helper_$(basename "$helper").o"
    done
    # LLVM's libunwind (the _Unwind_* and unw_* interfaces macOS programs
    # import from libSystem), against Ycode's minimal headers.
    uw="$out/obj/unwind"
    rm -rf "$uw"
    mkdir -p "$uw"
    for name in libunwind.cpp UnwindLevel1.c UnwindLevel1-gcc-ext.c UnwindRegistersSave.S UnwindRegistersRestore.S; do
        case $name in
        *.cpp) lang="-x c++ -std=c++17 -nostdinc++ -fno-rtti" ;;
        *) lang="" ;;
        esac
        # shellcheck disable=SC2086
        "$CLANG" -target $TARGET $lang -nostdlib -ffreestanding -fno-exceptions -fno-stack-protector -fPIC -O2 \
            -mno-outline-atomics -funwind-tables -fvisibility=hidden -DNDEBUG -D_LIBUNWIND_IS_NATIVE_ONLY \
            "-D__OSX_AVAILABLE_STARTING(a,b)=" "-I$here/libsystem/include" "-I$LLVM_PROJECT/libunwind/include" \
            -c -o "$uw/$name.o" "$LLVM_PROJECT/libunwind/src/$name" || die "compiling libunwind's $name failed"
        "$PYTHON" -I "$strip_platform" "$uw/$name.o" || die "stripping $name failed"
    done
    rt="$out/obj/builtins"
    rm -rf "$rt"
    mkdir -p "$rt"
    for name in $BUILTINS; do
        # shellcheck disable=SC2086
        "$CLANG" -target $TARGET -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fPIC -O2 \
            -mno-outline-atomics -c -o "$rt/$name.o" "$LLVM_PROJECT/compiler-rt/lib/builtins/$name.c" \
            || die "compiling compiler-rt's $name failed"
        "$PYTHON" -I "$strip_platform" "$rt/$name.o" || die "stripping $name failed"
    done
}

build_libsystem() {
    need_llvm_project
    build_llvm_libc
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
    for src in "$here/libsystem"/*.S; do
        [ -f "$src" ] || continue
        obj="$o/$(basename "$src" .S).o"
        compile "$src" "$obj" "-I$here/libsystem"
        objects="$objects $obj"
    done
    objects="$objects $out/obj/libc/*.o $out/obj/builtins/*.o $out/obj/unwind/*.o"
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

# Ycode's Objective-C runtime (specs/macos/objc-runtime.md §11): the Rust
# static library's members, platform tags stripped, linked as
# /usr/lib/libobjc.A.dylib against libSystem, exporting objc/exports.txt.
build_objc() {
    if ! command -v "$CARGO" >/dev/null 2>&1; then
        say "no cargo: libobjc.A.dylib is skipped"
        return 0
    fi
    o="$out/obj/objc"
    rm -rf "$o"
    mkdir -p "$o/builtins"
    (cd "$here/objc" && "$CARGO" build --release --target aarch64-apple-darwin --target-dir "$out/cargo") \
        || die "building the Objective-C runtime failed (is the aarch64-apple-darwin target installed?)"
    lib="$out/cargo/aarch64-apple-darwin/release/libycobjc.a"
    (cd "$o" && "$AR" x "$lib") || die "extracting $lib failed"
    rm -f "$o"/*.rmeta
    # The crate is one object (LTO); compiler_builtins members go into an
    # archive so only the ones it uses are linked.
    for f in "$o"/compiler_builtins*.o; do
        [ -f "$f" ] && mv "$f" "$o/builtins/"
    done
    "$PYTHON" -I "$strip_platform" "$o"/*.o "$o"/builtins/*.o || die "stripping the runtime's objects failed"
    "$AR" rcs "$o/builtins.a" "$o"/builtins/*.o || die "archiving compiler_builtins failed"
    # shellcheck disable=SC2086
    "$LD64" $LINK -dylib -install_name /usr/lib/libobjc.A.dylib -current_version 1.0.0 \
        -compatibility_version 1.0.0 -fixup_chains -dead_strip \
        -exported_symbols_list "$here/objc/exports.txt" -o "$out/root/usr/lib/libobjc.A.dylib" \
        "$o"/*.o "$o/builtins.a" "$out/tbd/libSystem.tbd" || die "linking libobjc failed"
    say "libobjc: $("$NM" -g --defined-only -j "$out/root/usr/lib/libobjc.A.dylib" | wc -l | tr -d ' ') exports"
}

# The libSystem sub-libraries that Mac-built dylibs (the Swift runtime,
# Foundation) name directly: on a Mac libSystem re-exports them; here each
# is an empty dylib that re-exports libSystem, so a two-level bind to it
# finds the symbol in libSystem (libsystem.md §2).
SUBLIBRARIES="libdispatch libsystem_c libsystem_m libsystem_malloc libsystem_blocks libsystem_info libunwind libcompiler_rt"
install_sublibrary_aliases() {
    o="$out/obj/alias"
    mkdir -p "$o" "$out/root/usr/lib/system"
    echo 'static int ycl_alias_unused __attribute__((unused));' > "$o/empty.c"
    compile "$o/empty.c" "$o/empty.o"
    for lib in $SUBLIBRARIES; do
        # shellcheck disable=SC2086
        "$LD64" $LINK -dylib -install_name "/usr/lib/system/$lib.dylib" -current_version 1.0.0 \
            -compatibility_version 1.0.0 -o "$out/root/usr/lib/system/$lib.dylib" "$o/empty.o" \
            -reexport_library "$out/tbd/libSystem.tbd" || die "linking the $lib alias failed"
    done
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
    install_sublibrary_aliases
    build_objc
    build_swift_sample
    run_tests
    say "ok: $out/root"
    ;;
test) run_tests ;;
objc) build_objc ;;
clean) rm -rf "$out" ;;
*) die "usage: sh build.sh [all|test|objc|clean]" ;;
esac
