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
cp "$BIN" "$APP/Contents/MacOS/Ycode"
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
	</array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
