#!/bin/sh
# Builds DebugDemo.app for the iOS simulator with debug information
# (specs/simulator/debug-stub.md §9): build/DebugDemo.app, its .dSYM, and
# the object files the debug map names. Usage: sh build.sh [out-dir]
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/build}
app=$out/DebugDemo.app
mkdir -p "$out/obj" "$app"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
target=arm64-apple-ios18.0-simulator
xcrun --sdk iphonesimulator swiftc -target $target -sdk "$sdk" -g -Onone -module-name DebugDemo -parse-as-library \
  -c "$here/Sources/Work.swift" "$here/Sources/App.swift" -working-directory "$out/obj" \
  -emit-module -emit-module-path "$out/obj/DebugDemo.swiftmodule"
# The module is registered with the linker (as Xcode builds do), so the
# debugger's Swift expressions can import it and see its types.
xcrun --sdk iphonesimulator swiftc -target $target -sdk "$sdk" -g -Onone -module-name DebugDemo \
  "$out/obj/Work.o" "$out/obj/App.o" -Xlinker -add_ast_path -Xlinker "$out/obj/DebugDemo.swiftmodule" -o "$app/DebugDemo"
rm -rf "$app/DebugDemo.dSYM"   # swiftc -g puts one next to the binary; it belongs beside the app
# The plugin the app loads with dlopen during a run.
xcrun --sdk iphonesimulator clang -target $target -isysroot "$sdk" -g -O0 -c "$here/Sources/Plugin.c" -o "$out/obj/Plugin.o"
xcrun --sdk iphonesimulator clang -target $target -isysroot "$sdk" -dynamiclib \
  -install_name @rpath/libDemoPlugin.dylib "$out/obj/Plugin.o" -o "$app/libDemoPlugin.dylib"
xcrun dsymutil "$app/libDemoPlugin.dylib" -o "$out/libDemoPlugin.dylib.dSYM"
cp "$here/Info.plist" "$app/Info.plist"
printf 'APPL????' > "$app/PkgInfo"
xcrun dsymutil "$app/DebugDemo" -o "$out/DebugDemo.app.dSYM"
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "built $app"
