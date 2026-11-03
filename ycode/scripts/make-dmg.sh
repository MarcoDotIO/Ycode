#!/bin/sh
# Builds the disk image: Ycode.app, signed, in a styled window with an
# Applications link, notarized when the notary variables exist. Without any
# signing variable the same path gives an ad-hoc signed image.
# packaging/README.md describes the interface.
#
# Usage: scripts/make-dmg.sh [output-dir]      (default .build-ide/dist)
#
# Environment (all optional; values are never printed):
#   MACOS_CERTIFICATE_P12_BASE64, MACOS_CERTIFICATE_PASSWORD
#       a Developer ID Application certificate; imported into a temporary
#       keychain that is deleted at the end
#   YCODE_SIGN_IDENTITY      an identity already in a keychain; wins over the P12
#   NOTARY_KEY_P8_BASE64, NOTARY_KEY_ID, NOTARY_ISSUER_ID
#       an App Store Connect API key; all three are needed to notarize, and
#       notarizing needs a real identity
#   APPLE_TEAM_ID            checked against the signed app when set
#   YCODE_ARCHS              default "arm64 x86_64" (universal) here
#   YCODE_BUILD_NUMBER, YCODE_BUILD_ROOT, YCODE_SWB_BUILD_ROOT, YCODE_ICON_ICNS   see make-app.sh
#   YCODE_DMG_SKIP_APP=1     package the app already in <output-dir>/stage
set -eu
set +x

here=$(cd "$(dirname "$0")" && pwd)
ycode_dir=$(cd "$here/.." && pwd)
root=$(cd "$ycode_dir/.." && pwd)
macos="$root/packaging/macos"
cd "$ycode_dir"

# The release is universal: an Intel Mac runs the x86_64 slices.
YCODE_ARCHS=${YCODE_ARCHS:-arm64 x86_64}
export YCODE_ARCHS

OUT=${1:-.build-ide/dist}
VERSION=$(cat VERSION)
VOLUME="Ycode $VERSION"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
DMG="$OUT/Ycode-$VERSION.dmg"

work=$(mktemp -d)
keychain=""
previous_keychains=""
mount_point=""
cleanup() {
    [ -n "$mount_point" ] && hdiutil detach -quiet -force "$mount_point" 2>/dev/null
    if [ -n "$keychain" ]; then
        eval "security list-keychains -d user -s $previous_keychains" 2>/dev/null
        security delete-keychain "$keychain" 2>/dev/null
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# --- the signing identity ---------------------------------------------------
if [ -z "${YCODE_SIGN_IDENTITY:-}" ] && [ -n "${MACOS_CERTIFICATE_P12_BASE64:-}" ]; then
    : "${MACOS_CERTIFICATE_PASSWORD:?MACOS_CERTIFICATE_PASSWORD is needed with MACOS_CERTIFICATE_P12_BASE64}"
    umask 077
    printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | base64 -D > "$work/certificate.p12"
    keychain="$work/signing.keychain-db"
    keychain_password=$(uuidgen)
    previous_keychains=$(security list-keychains -d user | tr -d '\n')
    security create-keychain -p "$keychain_password" "$keychain"
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$keychain_password" "$keychain"
    security import "$work/certificate.p12" -k "$keychain" -P "$MACOS_CERTIFICATE_PASSWORD" -f pkcs12 -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
    eval "security list-keychains -d user -s \"$keychain\" $previous_keychains"
    rm -f "$work/certificate.p12"
    YCODE_SIGN_IDENTITY=$(security find-identity -v -p codesigning "$keychain" | awk -F'"' '/Developer ID Application/ { print $2; exit }')
    [ -n "$YCODE_SIGN_IDENTITY" ] || { echo "make-dmg: the certificate holds no Developer ID Application identity" >&2; exit 1; }
    export YCODE_SIGN_IDENTITY
fi
IDENTITY=${YCODE_SIGN_IDENTITY:--}
if [ "$IDENTITY" = "-" ]; then
    echo "make-dmg: no signing identity: signing ad hoc (the image will not pass Gatekeeper)" >&2
else
    echo "make-dmg: signing with a Developer ID identity" >&2
fi

# --- the app ----------------------------------------------------------------
STAGE="$OUT/stage"
if [ "${YCODE_DMG_SKIP_APP:-0}" != 1 ]; then
    "$here/make-app.sh" "$STAGE" >/dev/null
fi
APP="$STAGE/Ycode.app"
if [ -n "${APPLE_TEAM_ID:-}" ] && [ "$IDENTITY" != "-" ]; then
    codesign -dvv "$APP" 2>&1 | grep -q "^TeamIdentifier=$APPLE_TEAM_ID\$" \
        || { echo "make-dmg: the app is not signed by team APPLE_TEAM_ID" >&2; exit 1; }
fi

# --- notarization helpers ---------------------------------------------------
notarizing=0
if [ -n "${NOTARY_KEY_P8_BASE64:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
    if [ "$IDENTITY" = "-" ]; then
        echo "make-dmg: notary variables exist but there is no signing identity: not notarizing" >&2
    else
        notarizing=1
        umask 077
        printf '%s' "$NOTARY_KEY_P8_BASE64" | base64 -D > "$work/notary-key.p8"
    fi
else
    echo "make-dmg: no notary variables: not notarizing" >&2
fi
notarize() { # file
    result="$work/notary-result.json"
    if ! xcrun notarytool submit "$1" --key "$work/notary-key.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
        --wait --output-format json > "$result"; then
        echo "make-dmg: notarytool failed" >&2
        return 1
    fi
    status=$(/usr/bin/plutil -extract status raw "$result" 2>/dev/null || echo unknown)
    if [ "$status" != Accepted ]; then
        submission=$(/usr/bin/plutil -extract id raw "$result" 2>/dev/null || echo "")
        echo "make-dmg: notarization status: $status" >&2
        [ -n "$submission" ] && xcrun notarytool log "$submission" --key "$work/notary-key.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" >&2
        return 1
    fi
}

# The app gets its own ticket, so a copy dragged out of the image opens offline.
if [ "$notarizing" = 1 ]; then
    echo "make-dmg: notarizing the app" >&2
    ditto -c -k --keepParent "$APP" "$work/Ycode.zip"
    notarize "$work/Ycode.zip"
    xcrun stapler staple "$APP" >/dev/null
    rm -f "$work/Ycode.zip"
fi

# --- the image --------------------------------------------------------------
app_kb=$(du -sk "$APP" | cut -f1)
rw="$work/rw.dmg"
hdiutil create -quiet -size "$((app_kb / 1024 + 64))m" -fs HFS+ -volname "$VOLUME" -ov "$rw"
mount_root="$work/mnt"
mkdir -p "$mount_root"
hdiutil attach -quiet -nobrowse -noautoopen -noverify -mountroot "$mount_root" "$rw"
mount_point="$mount_root/$VOLUME"
ditto "$APP" "$mount_point/Ycode.app"
ln -s /Applications "$mount_point/Applications"
mkdir "$mount_point/.background"
cp "$macos/dmg-background.tiff" "$mount_point/.background/background.tiff"
cat > "$work/layout.json" <<'JSON'
{"window": [660, 420], "icon_size": 128, "icons": {"Ycode.app": [170, 190], "Applications": [490, 190]}}
JSON
/usr/bin/python3 -I "$macos/make-dsstore.py" "$mount_point" .background/background.tiff "$work/layout.json"
rm -rf "$mount_point/.fseventsd" "$mount_point/.Trashes"
hdiutil detach -quiet "$mount_point"
mount_point=""
rm -f "$DMG"
hdiutil convert -quiet "$rw" -format ULFO -o "$DMG"
rm -f "$rw"

if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$DMG"
else
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
if [ "$notarizing" = 1 ]; then
    echo "make-dmg: notarizing the image" >&2
    notarize "$DMG"
    xcrun stapler staple "$DMG" >/dev/null
fi

"$macos/verify-dmg.sh" "$DMG"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
ls -l "$DMG" >&2
echo "$DMG"
