#!/bin/sh
# Checks a built image the way a user meets it: mounts it, copies the app to an
# empty folder, and runs it from there with an empty environment and no build
# tree in reach. Gatekeeper's answer is reported as it is; it fails for an
# ad-hoc image, which is expected, unless YCODE_VERIFY_REQUIRE_GATEKEEPER=1.
#
# usage: packaging/macos/verify-dmg.sh <file.dmg>
set -eu

dmg=$1
here=$(cd "$(dirname "$0")" && pwd)
version=$(cat "$here/../../ycode/VERSION")
work=$(cd "$(mktemp -d)" && pwd -P)
mounted=""
launched=""
cleanup() {
    [ -n "$launched" ] && kill "$launched" 2>/dev/null
    [ -n "$mounted" ] && hdiutil detach -quiet -force "$mounted" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "verify-dmg: FAILED: $*" >&2; exit 1; }
say() { echo "verify-dmg: $*"; }

hdiutil verify -quiet "$dmg" && say "image checksum: ok"
codesign --verify "$dmg" && say "image signature: ok"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountroot "$work" "$dmg"
mounted="$work/Ycode $version"
[ -d "$mounted/Ycode.app" ] || fail "no Ycode.app at the image's root"
[ -L "$mounted/Applications" ] || fail "no Applications link"
[ -f "$mounted/.background/background.tiff" ] || fail "no background picture"
[ -f "$mounted/.DS_Store" ] || fail "no window layout"

clean="$work/clean/place with a space"
mkdir -p "$clean"
ditto "$mounted/Ycode.app" "$clean/Ycode.app"
hdiutil detach -quiet "$mounted"
mounted=""
app="$clean/Ycode.app"
bare() { env -i HOME="$work/home" TMPDIR="$work/" PATH=/usr/bin:/bin "$@"; }
mkdir -p "$work/home"

codesign --verify --deep --strict "$app" && say "codesign --verify --deep --strict: ok"
codesign -dvv "$app" 2>&1 | grep -E '^(Authority|Signature|TeamIdentifier)=' | sed 's/^/verify-dmg:   /' || true
if codesign -d --verbose=4 "$app" 2>&1 | grep -q 'flags=.*runtime'; then
    say "hardened runtime: on"
else
    fail "the app is not hardened"
fi
if spctl_output=$(spctl --assess --type execute --verbose=2 "$app" 2>&1); then
    say "spctl: accepted: $spctl_output"
else
    say "spctl: rejected: $spctl_output"
    [ "${YCODE_VERIFY_REQUIRE_GATEKEEPER:-0}" != 1 ] || fail "Gatekeeper rejected the app"
fi

plist="$app/Contents/Info.plist"
[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$plist")" = "$version" ] || fail "Info.plist has another version"

# Every tool reports the version from the copied bundle.
for tool in "$app/Contents/MacOS/Ycode" "$app/Contents/Helpers/ycode" "$app/Contents/Helpers/ycodebuild" \
            "$app/Contents/Helpers/ycode-bsp" "$app/Contents/Helpers/ycode-swb" "$app/Contents/Helpers/ycode-sim-viewer" \
            "$app/Contents/Helpers/ycode-simhost"; do
    [ -x "$tool" ] || fail "missing $tool"
    line=$(bare "$tool" --version) || fail "$tool --version"
    case "$line" in
        *" $version") say "  $line" ;;
        *) fail "$tool says: $line" ;;
    esac
done

# A universal app: both slices, and the Intel one runs where Rosetta is present.
if lipo -archs "$app/Contents/MacOS/Ycode" | grep -q x86_64; then
    if [ "$(uname -m)" = arm64 ] && arch -x86_64 /usr/bin/true 2>/dev/null; then
        line=$(bare arch -x86_64 "$app/Contents/Helpers/ycode" --version) || fail "the x86_64 slice does not run"
        say "x86_64 slice under Rosetta: $line"
    else
        say "x86_64 slice: not run here"
    fi
fi
say "architectures: $(lipo -archs "$app/Contents/MacOS/Ycode")"

# Nothing links or points outside the bundle and the system.
for binary in "$app/Contents/MacOS/Ycode" "$app"/Contents/Helpers/*; do
    [ -f "$binary" ] || continue
    file "$binary" | grep -q Mach-O || continue
    # A universal binary lists one header line ("<file> (architecture ...):") per slice.
    bad=$(otool -L "$binary" | grep -v ':$' | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/|@rpath/libYcode|@rpath/lib|@loader_path/|@executable_path/)' || true)
    [ -z "$bad" ] || fail "$binary links $bad"
    rpaths=$(otool -l "$binary" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}' | grep -vE '^(@loader_path|@executable_path|/usr/lib/swift)' || true)
    [ -z "$rpaths" ] || fail "$binary has search paths $rpaths"
done
say "linkage: bundle and system only"

# No machine's paths in the binaries. The user's and machine's names are
# checked from the environment, so they are never written in this file.
# A path names a folder: "/home/<name>/". Machine code that builds a string in
# 8-byte immediates shows "/home/us" with no slash after it, which is not one.
patterns='/Users/[A-Za-z][A-Za-z0-9._-]*/|/home/[a-z][a-z0-9._-]*/|/Volumes/[A-Z][A-Za-z0-9._ -]*/|\.build-release'
[ -n "${USER:-}" ] && [ "${USER:-}" != runner ] && patterns="$patterns|$USER"
host=$(hostname -s 2>/dev/null || true)
[ -n "$host" ] && patterns="$patterns|$host"
leaks=0
for binary in "$app/Contents/MacOS/Ycode" "$app"/Contents/Helpers/*; do
    [ -f "$binary" ] || continue
    file "$binary" | grep -q Mach-O || continue
    found=$(strings -a "$binary" | grep -E "$patterns" | sort -u | head -5 || true)
    if [ -n "$found" ]; then
        echo "verify-dmg: paths in $(basename "$binary"):" >&2
        echo "$found" | sed 's/^/    /' >&2
        leaks=1
    fi
done
[ "$leaks" = 0 ] || fail "machine paths in the binaries"
say "machine paths: none"

# The helper tools work from here: a project query through the bundled tools.
bare "$app/Contents/Helpers/ycodebuild" -version >/dev/null || fail "ycodebuild -version"

# The app starts and stays up, hidden, from the clean place.
open -g -j -n -a "$app" --env "PATH=/usr/bin:/bin" || fail "open"
sleep "${YCODE_VERIFY_LAUNCH_SECONDS:-15}"
launched=$(pgrep -f "^$app/Contents/MacOS/Ycode" | head -1 || true)
[ -n "$launched" ] || fail "the app did not stay running"
say "launch from a clean folder: running after ${YCODE_VERIFY_LAUNCH_SECONDS:-15} s (pid $launched)"
images=$(vmmap "$launched" 2>/dev/null | grep -E '^__TEXT' | awk '{print $NF}' | grep -E '^/' | grep -vE '^(/usr/lib/|/System/|/Library/Apple/)' | grep -vF "$clean" | sort -u || true)
[ -z "$images" ] && say "loaded code: bundle and system only" || say "loaded code from elsewhere: $images"
kill "$launched"
launched=""
say "ok"
