#!/bin/sh
# Builds the settings-features probe app FeatureProbe.app (dev.ycode.FeatureProbe;
# features/FeatureProbe.m; specs/simulator/simulator-features.md "Ycode
# implementation", verification) for the iOS simulator platform. Runs on macOS only.
#   ../out/guest-tests/features/FeatureProbe.app
# Install and launch it on the Thor with ycode-simd --install-app <dir>/FeatureProbe.app
# --launch dev.ycode.FeatureProbe; its "probe: <ms> …" lines go to the app's stdout.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/../out/guest-tests/features}"
[ "$(uname -s)" = "Darwin" ] || { echo "build-features.sh: needs macOS" >&2; exit 1; }
app="$out/FeatureProbe.app"
rm -rf "$app"
mkdir -p "$app"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O2 -Wall -Wextra -Werror \
    -framework Foundation -framework UIKit -framework CoreLocation -framework AVFoundation -framework Accessibility \
    -o "$app/FeatureProbe" "$here/features/FeatureProbe.m"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>dev.ycode.FeatureProbe</string>
	<key>CFBundleExecutable</key><string>FeatureProbe</string>
	<key>CFBundleName</key><string>FeatureProbe</string>
	<key>CFBundleDisplayName</key><string>Feature Probe</string>
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
					<key>UISceneDelegateClassName</key><string>ProbeSceneDelegate</string>
				</dict>
			</array>
		</dict>
	</dict>
	<key>NSLocationWhenInUseUsageDescription</key><string>The probe prints simulated locations.</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Info.plist" >/dev/null
codesign -s - "$app" 2>/dev/null || true
echo "$app: $(wc -c < "$app/FeatureProbe" | tr -d ' ') bytes"
echo "build-features.sh: ok"
