#!/bin/sh
# Builds WCProbe (wcprobe/; device-pairing.md §10, watchos.md §7.2 round W5):
# Ycode's own WatchConnectivity test app, an iOS simulator app with its watch
# app embedded as <iOS app>/Watch/<watch app>.app (device-pairing.md §5).
#   out/WCProbe.app                          bundle id dev.ycode.wcprobe (iOS 27.0 simulator)
#   out/WCProbe.app/Watch/WCProbeWatch.app   bundle id dev.ycode.wcprobe.watchkitapp (watchOS 27.0
#                                            simulator; WKApplication, WKCompanionAppBundleIdentifier)
# The executables carry only the linker's ad-hoc signature, which the
# simulator installs (app-install-launch.md §4.1). Runs on macOS only.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/out}"
[ "$(uname -s)" = "Darwin" ] || { echo "SimGuestAgents/build-wcprobe.sh: needs macOS" >&2; exit 1; }
src="$here/wcprobe"
app="$out/WCProbe.app"
watch="$app/Watch/WCProbeWatch.app"
rm -rf "$app"
mkdir -p "$watch"

plist() { # <file> <key> <type> <value>
    /usr/libexec/PlistBuddy -c "Add :$2 $3 ${4-}" "$1" >/dev/null
}

xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios27.0-simulator -parse-as-library -O \
    -o "$app/WCProbe" "$src/Probe.swift" "$src/App.swift"
xcrun --sdk watchsimulator swiftc -target arm64-apple-watchos27.0-simulator -parse-as-library -O \
    -o "$watch/WCProbeWatch" "$src/Probe.swift" "$src/App.swift"

p="$app/Info.plist"
plist "$p" CFBundleIdentifier string dev.ycode.wcprobe
plist "$p" CFBundleExecutable string WCProbe
plist "$p" CFBundleName string WCProbe
plist "$p" CFBundleDisplayName string WCProbe
plist "$p" CFBundlePackageType string APPL
plist "$p" CFBundleInfoDictionaryVersion string 6.0
plist "$p" CFBundleShortVersionString string 1.0
plist "$p" CFBundleVersion string 1
plist "$p" MinimumOSVersion string 27.0
plist "$p" DTPlatformName string iphonesimulator
plist "$p" LSRequiresIPhoneOS bool true
plist "$p" CFBundleSupportedPlatforms array
plist "$p" CFBundleSupportedPlatforms:0 string iPhoneSimulator
plist "$p" UIDeviceFamily array
plist "$p" UIDeviceFamily:0 integer 1
plist "$p" UILaunchScreen dict
plist "$p" UIApplicationSceneManifest dict
plist "$p" UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes bool true

p="$watch/Info.plist"
plist "$p" CFBundleIdentifier string dev.ycode.wcprobe.watchkitapp
plist "$p" CFBundleExecutable string WCProbeWatch
plist "$p" CFBundleName string WCProbe
plist "$p" CFBundleDisplayName string WCProbe
plist "$p" CFBundlePackageType string APPL
plist "$p" CFBundleInfoDictionaryVersion string 6.0
plist "$p" CFBundleShortVersionString string 1.0
plist "$p" CFBundleVersion string 1
plist "$p" MinimumOSVersion string 27.0
plist "$p" DTPlatformName string watchsimulator
plist "$p" WKApplication bool true
plist "$p" WKCompanionAppBundleIdentifier string dev.ycode.wcprobe
plist "$p" CFBundleSupportedPlatforms array
plist "$p" CFBundleSupportedPlatforms:0 string WatchSimulator
plist "$p" UIDeviceFamily array
plist "$p" UIDeviceFamily:0 integer 4

# Ad-hoc signatures whose identifier is the bundle id, as a real build signs
# them (the linker's own ad-hoc signature names the file instead, and the
# guest's daemons key some per-app state by that identifier; WATCH-W7,
# health-simulation.md §12.3). The inner app first.
codesign --force --sign - --timestamp=none "$watch"
codesign --force --sign - --timestamp=none "$app"

for f in "$app/WCProbe" "$watch/WCProbeWatch"; do echo "$f: $(wc -c < "$f" | tr -d ' ') bytes"; done
echo "SimGuestAgents/build-wcprobe.sh: ok"
