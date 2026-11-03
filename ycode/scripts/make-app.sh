#!/bin/sh
# Builds Ycode.app: the YcodeApp executable, its helper tools, Info.plist, icon
# and notices, signed inside out. packaging/README.md describes the interface.
#
# Usage: scripts/make-app.sh [output-dir]      (default .build-ide/app)
#
# Environment (all optional):
#   YCODE_SIGN_IDENTITY  a code signing identity in a keychain; without one the
#                        app is signed ad hoc. scripts/make-dmg.sh sets it from
#                        the release secrets.
#   YCODE_ARCHS          the architectures, "arm64" (default) or "arm64 x86_64"
#                        for a universal app
#   YCODE_BUILD_NUMBER   CFBundleVersion (default 1)
#   YCODE_BUILD_ROOT     SwiftPM scratch folder (default .build-release)
#   YCODE_SWB_BUILD_ROOT scratch folder for the swift-build helper (default
#                        /tmp/ycode-release-<uid>): swift-build's sources use
#                        #filePath, which no compiler option remaps, so this
#                        folder's path ends up in the binaries and must name nobody
#   YCODE_ICON_ICNS      the icon (default packaging/icon/Ycode.icns)
#   YCODE_APP_MINIMAL=1  a quick app for development: this architecture only,
#                        and only YcodeApp and ycode-bsp as helper
set -eu

here=$(cd "$(dirname "$0")" && pwd)
ycode_dir=$(cd "$here/.." && pwd)
root=$(cd "$ycode_dir/.." && pwd)
cd "$ycode_dir"

OUT=${1:-.build-ide/app}
VERSION=$(cat VERSION)
BUILD_NUMBER=${YCODE_BUILD_NUMBER:-1}
ARCHS=${YCODE_ARCHS:-arm64}
BUILD_ROOT=${YCODE_BUILD_ROOT:-.build-release}
ICON=${YCODE_ICON_ICNS:-$root/packaging/icon/Ycode.icns}
IDENTITY=${YCODE_SIGN_IDENTITY:--}
MINIMUM_SYSTEM=15.0
HOST_ARCH=$(uname -m)

PRODUCTS="YcodeApp ycode-bsp"
HELPERS="ycode-bsp"
if [ "${YCODE_APP_MINIMAL:-0}" = 1 ]; then
    ARCHS=$HOST_ARCH
else
    PRODUCTS="$PRODUCTS ycode ycodebuild ycode-sim-viewer ycode-simhost YcodeTestAgent"
    HELPERS="ycode-bsp ycode ycodebuild ycode-sim-viewer ycode-simhost"
fi

# Source paths in the binaries become relative to the repository, so no
# machine's folder names ship (packaging/macos/verify-dmg.sh checks).
triple_for() { # arch
    [ "$1" = "$HOST_ARCH" ] || echo "--triple $1-apple-macosx$MINIMUM_SYSTEM"
}
swift_build() { # package-dir scratch arch label product
    # shellcheck disable=SC2046 # the triple is either nothing or two words
    (cd "$1" && swift build -c release --scratch-path "$2" $(triple_for "$3") \
        -Xswiftc -file-prefix-map -Xswiftc "$2=build" -Xswiftc -file-prefix-map -Xswiftc "$PWD=$4" \
        -Xcc -ffile-prefix-map="$2=build" -Xcc -ffile-prefix-map="$PWD=$4" \
        -Xcxx -ffile-prefix-map="$2=build" -Xcxx -ffile-prefix-map="$PWD=$4" --product "$5" >&2)
}

SCRATCH_BASE=$(mkdir -p "$BUILD_ROOT" && cd "$BUILD_ROOT" && pwd)
SWB_BASE=${YCODE_SWB_BUILD_ROOT:-/tmp/ycode-release-$(id -u)}
mkdir -p "$SWB_BASE"
for arch in $ARCHS; do
    for product in $PRODUCTS; do
        echo "make-app: building $product ($arch)" >&2
        swift_build "$ycode_dir" "$SCRATCH_BASE/$arch" "$arch" ycode "$product"
    done
    if [ "${YCODE_APP_MINIMAL:-0}" != 1 ]; then
        for product in ycode-swb SWBBuildServiceBundle; do
            echo "make-app: building $product ($arch)" >&2
            swift_build "$ycode_dir/Tools/ycode-swb" "$SWB_BASE/swb-$arch" "$arch" ycode-swb "$product"
        done
    fi
done

bin_dir() { # scratch arch
    # shellcheck disable=SC2046 # the triple is either nothing or two words
    swift build -c release --scratch-path "$1" $(triple_for "$2") --show-bin-path
}

APP="$OUT/Ycode.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

# SwiftPM records the deployment target as the SDK version in the executable's
# LC_BUILD_VERSION, and AppKit then runs the app in its older look. Record the
# SDK the app was built with instead, so the system gives it its current design
# (specs/ide/liquid-glass-ycode.md §0).
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)

# install_binary <relative path in the build folder> <destination> <stamp-sdk 0|1>:
# one slice per architecture, debug symbols stripped, merged with lipo.
install_binary() {
    tmp=$(mktemp -d)
    slices=""
    for arch in $ARCHS; do
        case "$1" in
            ycode-swb|swbuild|SWBBuildServiceBundle) dir=$(bin_dir "$SWB_BASE/swb-$arch" "$arch") ;;
            *) dir=$(bin_dir "$SCRATCH_BASE/$arch" "$arch") ;;
        esac
        src="$dir/$1"
        slice="$tmp/$arch"
        if [ "$3" = 1 ]; then
            vtool -set-build-version macos "$MINIMUM_SYSTEM" "$SDK_VERSION" -replace -output "$slice" "$src" 2>/dev/null \
                || cp "$src" "$slice"
        else
            cp "$src" "$slice"
        fi
        strip -S -x "$slice" 2>/dev/null || true
        # SwiftPM records the toolchain's folders as search paths. Nothing
        # here links from them, and they name the machine that built it.
        otool -l "$slice" | awk '/LC_RPATH/ { f = 1 } f && / path / { print $2; f = 0 }' | while read -r rpath; do
            case "$rpath" in
                @*|/usr/lib/swift) ;;
                *) install_name_tool -delete_rpath "$rpath" "$slice" 2>/dev/null ;;
            esac
        done
        slices="$slices $slice"
    done
    # shellcheck disable=SC2086 # one word per slice
    lipo -create $slices -output "$2"
    chmod 755 "$2"
    rm -rf "$tmp"
}

install_binary YcodeApp "$APP/Contents/MacOS/Ycode" 1
for helper in $HELPERS; do
    stamp=0
    [ "$helper" = ycode-sim-viewer ] && stamp=1
    install_binary "$helper" "$APP/Contents/Helpers/$helper" "$stamp"
done
if [ "${YCODE_APP_MINIMAL:-0}" != 1 ]; then
    install_binary libYcodeTestAgent.dylib "$APP/Contents/Helpers/libYcodeTestAgent.dylib" 0
    install_binary ycode-swb "$APP/Contents/Helpers/ycode-swb" 0
    install_binary SWBBuildServiceBundle "$APP/Contents/Helpers/SWBBuildServiceBundle" 0
    # swift-build's own specifications (SwiftPM resource bundles, Apache-2.0).
    # A Swift tool looks for them next to itself.
    first_arch=${ARCHS%% *}
    for bundle in "$(bin_dir "$SWB_BASE/swb-$first_arch" "$first_arch")"/*.bundle; do
        [ -d "$bundle" ] || continue
        ditto "$bundle" "$APP/Contents/Helpers/$(basename "$bundle")"
    done
    # The launcher and the session script of a Linux simulator host, for
    # copying to that host (docs/SIMULATOR-LINUX.md §5); they do not run here.
    mkdir -p "$APP/Contents/Resources/simulator-host"
    cp scripts/ycode-sim.sh "$APP/Contents/Resources/simulator-host/ycode-sim"
    cp scripts/ycode-sim-serve "$APP/Contents/Resources/simulator-host/ycode-sim-serve"
fi

sed -e "s|@VERSION@|$VERSION|g" -e "s|@BUILD_NUMBER@|$BUILD_NUMBER|g" -e "s|@MINIMUM_SYSTEM@|$MINIMUM_SYSTEM|g" \
    "$root/packaging/macos/Info.plist.in" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f "$ICON" ]; then
    cp "$ICON" "$APP/Contents/Resources/Ycode.icns"
else
    echo "make-app: warning: no icon at $ICON; the app gets the generic icon" >&2
fi
cp "$root/LICENSE" "$APP/Contents/Resources/LICENSE"
[ -f "$root/THIRD_PARTY_NOTICES.md" ] && cp "$root/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

# Signing, inside out: helpers first, the app last. Hardened runtime on every
# executable, and no entitlements: nothing here needs an exception (no JIT, no
# plug-ins loaded from elsewhere). packaging/README.md lists why. A real
# identity also gets a secure timestamp, which notarization requires.
sign() { # path
    log=$(mktemp)
    if [ "$IDENTITY" = "-" ]; then
        codesign --force --options runtime --sign - "$1" 2>"$log" || { cat "$log" >&2; exit 1; }
    else
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1" 2>"$log" || { cat "$log" >&2; exit 1; }
    fi
    rm -f "$log"
}
for f in "$APP"/Contents/Helpers/*; do
    sign "$f"
done
sign "$APP"
codesign --verify --strict "$APP"
echo "$APP"
