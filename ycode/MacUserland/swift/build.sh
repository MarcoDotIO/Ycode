#!/bin/sh
# Builds the Swift part of Ycode's macOS userland (specs/macos/swift-runtime.md):
# the Swift runtime and standard library for arm64-apple-macos (with
# Objective-C interop on Ycode's runtime), Concurrency, Synchronization,
# Observation, string processing and Regex, the Darwin and os overlays,
# LLVM's libc++ and libc++abi, and swift-foundation's FoundationEssentials;
# all linked against Ycode's libSystem and libobjc link stubs.
#
#   sh swift/build.sh            everything (after sh build.sh)
#   sh swift/build.sh sample     only the Foundation sample (after a full run)
#
# Runs on a Mac: it compiles against the macOS SDK's C headers (interface
# facts only; no Apple library is linked) with the toolchain's swiftc and
# clang. Needs MacUserland/out/tbd (from sh build.sh, on Linux or a Mac),
# cmake 3.29+, ninja, git and python3.
#
# Results:
#   out/sdk                         Ycode's macOS SDK for compiling programs:
#                                   the macOS SDK's usr/include, Ycode's link
#                                   stubs, Ycode's Swift modules
#   out/root/usr/lib/swift          the Swift libraries (install names
#                                   /usr/lib/swift/lib*.dylib)
#   out/root/usr/lib/libc++.1.dylib LLVM's libc++ with libc++abi
#   out/root/usr/share/licenses     the licence and notice of each project
#   out/samples/foundation, concurrency  the stage-B samples (macos-apps.md §9.4)
#
# Sources (fetched by sources.sh into out/src unless SOURCES names a
# directory with them) are used unmodified except for the patches in
# swift/patches, applied to the fetched checkouts.

set -eu
LC_ALL=C
export LC_ALL

here=$(cd "$(dirname "$0")" && pwd)
mu=$(cd "$here/.." && pwd)
out="$mu/out"
src=${SOURCES:-$out/src}
build="$out/swift-build"
stage="$out/swift-stage"
sdk="$out/sdk"
root="$out/root"
JOBS=${JOBS:-8}
MACOS_MIN=14.0
FOUNDATION_MIN=26.0   # swift-foundation's own deployment target

die() {
    echo "swift/build.sh: error: $*" >&2
    exit 1
}
say() { echo "swift/build.sh: $*"; }

[ "$(uname -s)" = Darwin ] || die "runs on a Mac (it needs the macOS SDK's headers)"
[ -f "$out/tbd/libSystem.tbd" ] || die "no $out/tbd/libSystem.tbd: run sh build.sh first"
APPLE_SDK=${APPLE_SDK:-$(xcrun --show-sdk-path)}
SWIFTC=${SWIFTC:-$(xcrun -f swiftc)}
CLANG=${CLANG:-$(xcrun -f clang)}
CLANGXX=${CLANGXX:-$(xcrun -f clang++)}

fetch_sources() {
    sh "$mu/sources.sh" "$src" swift llvm-project swift-foundation swift-collections swift-foundation-icu \
        swift-experimental-string-processing
    # Ycode's patches, applied once.
    for patch in "$here"/patches/*.patch; do
        name=$(basename "$patch" .patch)
        case $name in
        swift-foundation-*) dir="$src/swift-foundation" ;;
        swift-platform-*) continue ;;  # applied to copies (build_overlays)
        *) die "patch $name: unknown project" ;;
        esac
        if ! (cd "$dir" && git apply --reverse --check "$patch" 2>/dev/null); then
            (cd "$dir" && git apply "$patch") || die "applying $name failed"
        fi
    done
    # The new runtime build copies the standard library sources into place.
    (cd "$src/swift/Runtimes" && cmake -DStringProcessing_ROOT_DIR="$src" -P Resync.cmake > /dev/null) \
        || die "Resync.cmake failed"
}

# Ycode's SDK: the macOS SDK's headers, Ycode's stubs and Swift modules.
make_sdk() {
    mkdir -p "$sdk/usr/lib/swift"
    ln -sfn "$APPLE_SDK/usr/include" "$sdk/usr/include"
    cat > "$sdk/SDKSettings.json" <<EOF
{"CanonicalName": "macosx27.0", "DisplayName": "Ycode macOS userland", "Version": "27.0",
 "DefaultDeploymentTarget": "$MACOS_MIN", "MaximumDeploymentTarget": "27.0.99",
 "SupportedTargets": {"macosx": {"Archs": ["arm64"], "LLVMTargetTripleSys": "macos",
   "LLVMTargetTripleVendor": "apple", "MinimumDeploymentTarget": "$MACOS_MIN",
   "DefaultDeploymentTarget": "$MACOS_MIN", "MaximumDeploymentTarget": "27.0.99",
   "PlatformFamilyName": "macOS"}}}
EOF
    cp "$out/tbd/libSystem.tbd" "$sdk/usr/lib/libSystem.tbd"
    # The libSystem sub-libraries (aliases that re-export libSystem,
    # build.sh): stubs with libSystem's symbols under their own names.
    mkdir -p "$sdk/usr/lib/system"
    for lib in libdispatch libsystem_c libsystem_m libsystem_malloc libsystem_blocks libsystem_info libunwind libcompiler_rt; do
        sed "s#/usr/lib/libSystem.B.dylib#/usr/lib/system/$lib.dylib#" "$out/tbd/libSystem.tbd" > "$sdk/usr/lib/system/$lib.tbd"
    done
    [ -f "$root/usr/lib/libobjc.A.dylib" ] || die "no libobjc.A.dylib in $root (build.sh needs cargo)"
    xcrun nm -gU -j "$root/usr/lib/libobjc.A.dylib" > "$build/objc.syms"
    python3 -I "$mu/tools/macho_tool.py" tbd "$sdk/usr/lib/libobjc.tbd" /usr/lib/libobjc.A.dylib "$build/objc.syms"
}

# cmake_runtime <name> <source dir> [extra cmake arguments]: one project of
# the Swift repository's runtime build (Runtimes/), for arm64 macOS with
# Objective-C interop, installed into the stage.
cmake_runtime() {
    name=$1
    dir=$2
    shift 2
    b="$build/$name"
    rm -rf "$b"
    mkdir -p "$b"
    cache="$src/swift/Runtimes/Core/cmake/caches/Vendors/Apple"
    printf 'set(CMAKE_OSX_DEPLOYMENT_TARGET %s CACHE STRING "")\nset(SwiftCore_TARGET_VARIANT_DEPLOYMENT_TARGET 17.0 CACHE STRING "")\n' \
        "$MACOS_MIN" > "$b/first.cmake"
    # Headers come from the macOS SDK (through Ycode's SDK), link stubs from
    # Ycode's SDK, so a missing libSystem function fails the link.
    (cd "$b" && SDKROOT=macosx cmake -G Ninja "$dir" -Wno-dev -C first.cmake -C "$cache/arm64-MacOSX.cmake" \
        -DCMAKE_TOOLCHAIN_FILE="$cache/Darwin.toolchain.cmake" -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_C_COMPILER="$CLANG" -DCMAKE_CXX_COMPILER="$CLANGXX" -DCMAKE_Swift_COMPILER="$SWIFTC" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$stage" -DCMAKE_INSTALL_NAME_DIR=/usr/lib/swift \
        -DCMAKE_DISABLE_FIND_PACKAGE_SwiftSwiftDirectRuntime=TRUE "$@" > "$build/$name.cmake.log" 2>&1) \
        || die "configuring $name failed (see $build/$name.cmake.log)"
    (cd "$b" && ninja -j "$JOBS" > "$build/$name.log" 2>&1 && ninja install >> "$build/$name.log" 2>&1) \
        || die "building $name failed (see $build/$name.log)"
    say "$name"
}

build_runtime() {
    rm -rf "$stage"
    # The runtime's Objective-C interop sources include the public headers
    # of CoreFoundation and Foundation (which include CoreGraphics' and
    # others') for declarations. The macOS SDK's framework headers are on
    # the C, C++ and Objective-C search paths for this build only; nothing
    # from any framework is linked (the runtime looks Foundation's classes
    # up by name, and only if a Foundation is loaded).
    frameworks="$APPLE_SDK/System/Library/Frameworks"
    # Core: the runtime, the standard library and Concurrency (its global
    # executor is libdispatch's, i.e. Ycode's dispatch in libSystem).
    # Off: Apple's CrashReporter, os_signpost tracing, the backtracer,
    # libmalloc zones, the back-deployment symbols and the toolchain's
    # SwiftDirectRuntime archive (an Apple binary).
    cmake_runtime Core "$src/swift/Runtimes/Core" -DSwiftCore_ENABLE_CONCURRENCY=ON \
        -DCMAKE_C_FLAGS="-iframework $frameworks" -DCMAKE_CXX_FLAGS="-iframework $frameworks" \
        -DCMAKE_OBJC_FLAGS="-iframework $frameworks" -DCMAKE_OBJCXX_FLAGS="-iframework $frameworks" \
        -DSwiftCore_ENABLE_CRASH_REPORTER_CLIENT=OFF -DSwiftCore_ENABLE_STDLIB_TRACING=OFF \
        -DSwiftCore_ENABLE_BACKTRACING=OFF -DSwiftCore_ENABLE_STRICT_AVAILABILITY=OFF \
        -DSwiftCore_OPTIMIZATION_REMARKS=OFF -DSwiftCore_ENABLE_BACKDEPLOYMENT_SUPPORT=OFF \
        -DSwiftCore_HAS_DARWIN_LIBMALLOC=OFF -DSwiftCore_ENABLE_RUNTIME_FUNCTION_COUNTERS=OFF
}

# The Supplemental libraries import Darwin: they come after the overlays.
build_supplemental() {
    for lib in Synchronization Observation StringProcessing; do
        cmake_runtime "$lib" "$src/swift/Runtimes/Supplemental/$lib" \
            -DSwiftCore_DIR="$stage/lib/cmake/SwiftCore"
    done
}

# Every library in the stage gets the install name /usr/lib/swift/<leaf>,
# and every @rpath reference between them the same absolute path, as on a Mac.
fix_install_names() {
    for lib in "$@"; do
        leaf=$(basename "$lib")
        install_name_tool -id "/usr/lib/swift/$leaf" "$lib" 2> /dev/null
        for dep in $(otool -L "$lib" | awk 'NR > 1 && $1 ~ /^@rpath\// {print $1}'); do
            install_name_tool -change "$dep" "/usr/lib/swift/${dep#@rpath/}" "$lib" 2> /dev/null
        done
    done
}

install_runtime_into_sdk() {
    lib="$sdk/usr/lib/swift"
    rm -rf "$lib"
    mkdir -p "$lib"
    cp -R "$stage/lib/swift/shims" "$lib/"
    for m in "$stage"/lib/swift/*.swiftmodule "$stage"/lib/swift/macosx/*.swiftmodule \
        "$stage"/lib/swift/*.dylib "$stage"/lib/swift/macosx/arm64/*.dylib; do
        [ -e "$m" ] && cp -R "$m" "$lib/"
    done
    fix_install_names "$lib"/*.dylib
}

# swiftmod <Module> <sources...>: a library-evolution Swift module in the SDK.
swiftmod() {
    module=$1
    shift
    o="$build/mod-$module"
    rm -rf "$o" "$sdk/usr/lib/swift/$module.swiftmodule"
    mkdir -p "$o" "$sdk/usr/lib/swift/$module.swiftmodule"
    (cd "$o" && "$SWIFTC" -target "arm64-apple-macos$MACOS_MIN" -sdk "$sdk" -runtime-compatibility-version none \
        -module-name "$module" -module-link-name "swift$module" -swift-version 5 -parse-as-library -O -wmo \
        -enable-library-evolution -emit-library -emit-module -no-verify-emitted-module-interface \
        -emit-module-path "$sdk/usr/lib/swift/$module.swiftmodule/arm64-apple-macos.swiftmodule" \
        -emit-module-interface-path "$sdk/usr/lib/swift/$module.swiftmodule/arm64-apple-macos.swiftinterface" \
        -Xlinker -install_name -Xlinker "/usr/lib/swift/libswift$module.dylib" \
        -o "$sdk/usr/lib/swift/libswift$module.dylib" "$@" > "$build/mod-$module.log" 2>&1) \
        || die "building the $module overlay failed (see $build/mod-$module.log)"
    say "$module overlay"
}

# The Darwin overlay: the Swift project's shared platform sources (patched
# for Darwin, swift/patches/swift-platform-darwin.patch) and Ycode's
# Darwin.swift; the os overlay is Ycode's; _Builtin_float is the Swift
# project's.
build_overlays() {
    p="$build/platform"
    rm -rf "$p"
    mkdir -p "$p/stdlib/public/Platform"
    for f in Platform.swift Math.swift TiocConstants.swift tgmath.swift.gyb; do
        cp "$src/swift/stdlib/public/Platform/$f" "$p/stdlib/public/Platform/"
    done
    (cd "$p" && patch -p1 -s < "$here/patches/swift-platform-darwin.patch") || die "patching the platform sources failed"
    python3 "$src/swift/utils/gyb" -DCMAKE_SDK=OSX -o "$p/tgmath.swift" "$p/stdlib/public/Platform/tgmath.swift.gyb" \
        || die "gyb failed"
    swiftmod Darwin "$here/Darwin/Darwin.swift" "$p/stdlib/public/Platform/Platform.swift" \
        "$p/stdlib/public/Platform/Math.swift" "$p/stdlib/public/Platform/TiocConstants.swift" "$p/tgmath.swift"
    swiftmod os "$here/os/os.swift"
    # <float.h> constants (the Swift project's ClangOverlays/float.swift.gyb);
    # the Supplemental build looks for its link stub.
    python3 "$src/swift/utils/gyb" -DCMAKE_SDK=OSX -o "$p/float.swift" \
        "$src/swift/stdlib/public/ClangOverlays/float.swift.gyb" || die "gyb failed"
    swiftmod _Builtin_float "$p/float.swift"
    xcrun nm -gU -j "$sdk/usr/lib/swift/libswift_Builtin_float.dylib" > "$build/float.syms"
    python3 -I "$mu/tools/macho_tool.py" tbd "$sdk/usr/lib/swift/libswift_Builtin_float.tbd" \
        /usr/lib/swift/libswift_Builtin_float.dylib "$build/float.syms"
}

# LLVM's libc++ and libc++abi as static archives, linked into one
# /usr/lib/libc++.1.dylib against Ycode's libSystem.
build_libcxx() {
    b="$build/libcxx"
    rm -rf "$b"
    mkdir -p "$b"
    (cd "$b" && cmake -G Ninja "$src/llvm-project/runtimes" -Wno-dev -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$CLANG" -DCMAKE_CXX_COMPILER="$CLANGXX" \
        -DCMAKE_OSX_SYSROOT="$APPLE_SDK" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXXABI_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
        -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXXABI_ENABLE_SHARED=OFF -DLIBCXX_ENABLE_STATIC=ON -DLIBCXXABI_ENABLE_STATIC=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=OFF -DLIBCXX_CXX_ABI=libcxxabi > "$build/libcxx.cmake.log" 2>&1) \
        || die "configuring libc++ failed (see $build/libcxx.cmake.log)"
    (cd "$b" && ninja -j "$JOBS" cxx_static cxxabi_static > "$build/libcxx.log" 2>&1) \
        || die "building libc++ failed (see $build/libcxx.log)"
    xcrun ld -arch arm64 -platform_version macos "$MACOS_MIN" "$MACOS_MIN" -dylib -install_name /usr/lib/libc++.1.dylib \
        -current_version 1.0.0 -compatibility_version 1.0.0 -all_load "$b/lib/libc++.a" "$b/lib/libc++abi.a" \
        "$sdk/usr/lib/libSystem.tbd" -o "$root/usr/lib/libc++.1.dylib" > "$build/libcxx.link.log" 2>&1 \
        || die "linking libc++.1.dylib failed (see $build/libcxx.link.log)"
    xcrun nm -gU -j "$root/usr/lib/libc++.1.dylib" > "$build/cxx.syms"
    python3 -I "$mu/tools/macho_tool.py" tbd "$sdk/usr/lib/libc++.tbd" /usr/lib/libc++.1.dylib "$build/cxx.syms"
    say "libc++"
}

build_foundation() {
    b="$build/foundation"
    rm -rf "$b"
    mkdir -p "$b"
    # FoundationEssentials only: FoundationInternationalization (ICU) and
    # the Foundation macros are not built (macos-apps.md §9.4).
    (cd "$b" && cmake -G Ninja "$src/swift-foundation" -Wno-dev -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=YES \
        -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_DEPLOYMENT_TARGET="$FOUNDATION_MIN" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_C_COMPILER="$CLANG" -DCMAKE_CXX_COMPILER="$CLANGXX" -DCMAKE_Swift_COMPILER="$SWIFTC" \
        -DCMAKE_Swift_COMPILER_TARGET="arm64-apple-macosx$FOUNDATION_MIN" -DCMAKE_Swift_COMPILER_WORKS=YES \
        -DCMAKE_Swift_FLAGS="-runtime-compatibility-version none" -DSwiftFoundation_MACRO="$build/no-macros" \
        -DSwiftFoundation_MODERN_DATA_ABI=YES -DCMAKE_INSTALL_NAME_DIR=/usr/lib/swift \
        -D_SwiftCollections_SourceDIR="$src/swift-collections" \
        -D_SwiftFoundationICU_SourceDIR="$src/swift-foundation-icu" > "$build/foundation.cmake.log" 2>&1) \
        || die "configuring swift-foundation failed (see $build/foundation.cmake.log)"
    (cd "$b" && ninja -j "$JOBS" FoundationEssentials > "$build/foundation.log" 2>&1) \
        || die "building FoundationEssentials failed (see $build/foundation.log)"
    cp "$b/lib/libFoundationEssentials.dylib" "$sdk/usr/lib/swift/"
    for m in FoundationEssentials _FoundationCollections; do
        rm -rf "$sdk/usr/lib/swift/$m.swiftmodule"
        mkdir -p "$sdk/usr/lib/swift/$m.swiftmodule"
        for ext in swiftmodule swiftdoc abi.json; do
            [ -f "$b/swift/$m.$ext" ] && cp "$b/swift/$m.$ext" "$sdk/usr/lib/swift/$m.swiftmodule/arm64-apple-macos.$ext"
        done
    done
    # The C shims' module map, for clients that import FoundationEssentials.
    rm -rf "$sdk/usr/lib/swift/_FoundationCShims"
    cp -R "$src/swift-foundation/Sources/_FoundationCShims/include" "$sdk/usr/lib/swift/_FoundationCShims"
    fix_install_names "$sdk/usr/lib/swift/libFoundationEssentials.dylib"
    say "FoundationEssentials"
}

install_root() {
    mkdir -p "$root/usr/lib/swift"
    rm -f "$root"/usr/lib/swift/*.dylib
    cp "$sdk"/usr/lib/swift/*.dylib "$root/usr/lib/swift/"
    # Licences and notices (Apache-2.0 asks for both to travel with the binaries).
    lic="$root/usr/share/licenses"
    rm -rf "$lic"
    for project in swift llvm-project swift-foundation swift-collections swift-experimental-string-processing; do
        mkdir -p "$lic/$project"
        for f in LICENSE.txt LICENSE.TXT LICENSE.md LICENSE NOTICE.txt NOTICE; do
            [ -f "$src/$project/$f" ] && cp "$src/$project/$f" "$lic/$project/"
        done
    done
    say "installed into $root"
}

build_sample() {
    mkdir -p "$out/samples"
    for name in foundation concurrency; do
        "$SWIFTC" -target "arm64-apple-macos$FOUNDATION_MIN" -sdk "$sdk" -runtime-compatibility-version none \
            -parse-as-library -O -Xcc "-I$sdk/usr/lib/swift/_FoundationCShims" \
            "$mu/samples/$name.swift" -o "$out/samples/$name" > "$build/sample-$name.log" 2>&1 \
            || die "building samples/$name.swift failed (see $build/sample-$name.log)"
        say "samples/$name"
    done
}

case "${1:-all}" in
all)
    mkdir -p "$build"
    fetch_sources
    make_sdk
    build_libcxx
    build_runtime
    install_runtime_into_sdk
    build_overlays
    build_supplemental
    install_runtime_into_sdk
    build_overlays
    build_foundation
    install_root
    build_sample
    say "ok: $sdk, $root"
    ;;
sample) build_sample ;;
*) die "usage: sh swift/build.sh [all|sample]" ;;
esac
