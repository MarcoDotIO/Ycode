#!/bin/sh
# Wraps the YcodeApp executable into Ycode.app. The Info.plist is our own;
# the app has no icon yet.
# Usage: scripts/make-app.sh [output-dir]   (run from ycode/)
set -eu
OUT="${1:-.build-ide/app}"
swift build -c release --product YcodeApp
BIN="$(swift build -c release --show-bin-path)/YcodeApp"
APP="$OUT/Ycode.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# SwiftPM records the deployment target (15.0) as the SDK version in the
# executable's LC_BUILD_VERSION, and AppKit then runs the app in its
# pre-macOS 26 look. Record the SDK the app was built with instead, so the
# system gives it its current design (Liquid Glass,
# specs/ide/liquid-glass-ycode.md §0).
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_VERSION="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
vtool -set-build-version macos "${MIN_VERSION:-15.0}" "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/Ycode" "$BIN" 2>/dev/null \
    || cp "$BIN" "$APP/Contents/MacOS/Ycode"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Ycode</string>
	<key>CFBundleIdentifier</key>
	<string>org.ycode.Ycode</string>
	<key>CFBundleName</key>
	<string>Ycode</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Ycode Workspace</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>com.apple.xcode.project</string>
				<string>com.apple.dt.document.workspace</string>
				<string>public.folder</string>
			</array>
			<key>NSDocumentClass</key>
			<string>YcodeUI.WorkspaceDocument</string>
		</dict>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Source File</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.source-code</string>
				<string>public.plain-text</string>
				<string>public.json</string>
				<string>public.xml</string>
				<string>com.apple.property-list</string>
			</array>
			<key>NSDocumentClass</key>
			<string>YcodeUI.SourceFileDocument</string>
		</dict>
	</array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
