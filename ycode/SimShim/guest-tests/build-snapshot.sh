#!/bin/sh
# Builds the snapshot probe (specs/simulator/snapshot.md §9) for the iOS
# simulator platform. Runs on macOS only.
#   ../out/guest-tests/snapshot/p_snap   arm64, LC_BUILD_VERSION platform 7
# The output directory is git-ignored. Copy it to the Thor with rsync.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="$here/../out/guest-tests/snapshot"

die() {
    echo "guest-tests/build-snapshot.sh: error: $*" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || die "this script needs macOS (xcrun and the iOS simulator SDK)"
command -v xcrun >/dev/null 2>&1 || die "xcrun not found"
mkdir -p "$out"

xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2 -Wall -Wextra -Werror \
    -o "$out/p_snap" "$here/snapshot/p_snap.c" || die "compiling p_snap.c failed"
platform=$(xcrun otool -l "$out/p_snap" |
    awk '/cmd LC_BUILD_VERSION/ { inbv = 1; next } inbv && $1 == "platform" { print $2; exit }')
case "$platform" in
    7|IOSSIMULATOR) ;;
    *) die "p_snap is platform '$platform', expected 7 (iOS simulator)" ;;
esac
echo "$out/p_snap: $(wc -c < "$out/p_snap" | tr -d ' ') bytes, platform $platform"

# The warm-boot persistence probe app (snapshot.md §12): SnapPersist.app,
# bundle id dev.ycode.snap-persist, ad-hoc signed; its keychain entitlements
# in __TEXT,__entitlements, where the simulator reads them (as for ylaunch).
app="$out/SnapPersist.app"
mkdir -p "$app"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O2 -Wall -Wextra -Werror \
    -framework UIKit -framework Foundation -framework Security \
    -Wl,-sectcreate,__TEXT,__entitlements,"$here/snapshot/snap_persist.entitlements" \
    -o "$app/SnapPersist" "$here/snapshot/snap_persist_app.m" || die "compiling snap_persist_app.m failed"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>dev.ycode.snap-persist</string>
	<key>CFBundleExecutable</key><string>SnapPersist</string>
	<key>CFBundleName</key><string>SnapPersist</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>27.0</string>
	<key>UIDeviceFamily</key><array><integer>1</integer></array>
	<key>UILaunchScreen</key><dict/>
	<key>UIApplicationSceneManifest</key>
	<dict>
		<key>UIApplicationSupportsMultipleScenes</key><false/>
		<key>UISceneConfigurations</key>
		<dict>
			<key>UIWindowSceneSessionRoleApplication</key>
			<array><dict>
				<key>UISceneConfigurationName</key><string>Default</string>
				<key>UISceneDelegateClassName</key><string>SnapPersistSceneDelegate</string>
			</dict></array>
		</dict>
	</dict>
</dict>
</plist>
PLIST
printf 'APPL????' > "$app/PkgInfo"
codesign --force --sign - "$app" >/dev/null 2>&1 || die "codesign SnapPersist.app failed"
echo "$app: $(wc -c < "$app/SnapPersist" | tr -d ' ') bytes"
