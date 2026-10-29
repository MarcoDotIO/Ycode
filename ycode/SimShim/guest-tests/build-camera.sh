#!/bin/sh
# Builds the camera probe app CameraProbe.app (dev.ycode.CameraProbe;
# camera/CameraProbe.m; specs/simulator/camera.md "Ycode implementation",
# verification) for the iOS simulator platform. Runs on macOS only.
#   ../out/guest-tests/camera/CameraProbe.app
# Install and launch it on the Thor with ycode-simd --camera on --install-app
# <dir>/CameraProbe.app --launch dev.ycode.CameraProbe --app-arg <mode> …;
# its "camprobe: …" lines go to the app's stdout and DEV/data/tmp/camprobe.txt.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/../out/guest-tests/camera}"
[ "$(uname -s)" = "Darwin" ] || { echo "build-camera.sh: needs macOS" >&2; exit 1; }
app="$out/CameraProbe.app"
rm -rf "$app"
mkdir -p "$app"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations \
    -framework Foundation -framework UIKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework ImageIO \
    -framework CoreGraphics -framework QuartzCore -o "$app/CameraProbe" "$here/camera/CameraProbe.m"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>dev.ycode.CameraProbe</string>
	<key>CFBundleExecutable</key><string>CameraProbe</string>
	<key>CFBundleName</key><string>CameraProbe</string>
	<key>CFBundleDisplayName</key><string>Camera Probe</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
	<key>MinimumOSVersion</key><string>27.0</string>
	<key>LSRequiresIPhoneOS</key><true/>
	<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
	<key>UILaunchScreen</key><dict/>
	<key>UIApplicationSceneManifest</key>
	<dict>
		<key>UIApplicationSupportsMultipleScenes</key><false/>
		<key>UISceneConfigurations</key>
		<dict>
			<key>UIWindowSceneSessionRoleApplication</key>
			<array>
				<dict>
					<key>UISceneConfigurationName</key><string>Default</string>
					<key>UISceneDelegateClassName</key><string>SceneDelegate</string>
				</dict>
			</array>
		</dict>
	</dict>
	<key>NSCameraUsageDescription</key><string>The probe shows the Ycode camera.</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Info.plist" >/dev/null
codesign -s - "$app" 2>/dev/null || true
echo "$app: $(wc -c < "$app/CameraProbe" | tr -d ' ') bytes"
echo "build-camera.sh: ok"
