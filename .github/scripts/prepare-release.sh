#!/bin/sh
# Gathers release files and writes the checksums and notes.
# Usage: prepare-release.sh <artifacts-dir> <out-dir> <version> <macos-signing>
#   artifacts-dir  holds the DMG, the Flatpak bundles and the Linux tarballs, in any subfolders
#   macos-signing  notarized | developer-id | ad-hoc
# Writes <out-dir>/{the packages, SHA256SUMS.txt} and <out-dir>/../release-notes.md.
# Fails unless the DMG and both Flatpak bundles and tarballs are there.
set -eu
ARTIFACTS="$1"
OUT="$2"
VERSION="$3"
SIGNING="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$OUT"
FILES="Ycode-$VERSION.dmg Ycode-$VERSION-x86_64.flatpak Ycode-$VERSION-aarch64.flatpak Ycode-$VERSION-x86_64.tar.xz Ycode-$VERSION-aarch64.tar.xz"
for name in $FILES; do
    found="$(find "$ARTIFACTS" -type f -name "$name" | head -n 1)"
    [ -n "$found" ] || { echo "Missing release file: $name" >&2; exit 1; }
    cp "$found" "$OUT/$name"
done

if command -v sha256sum >/dev/null 2>&1; then SUM="sha256sum"; else SUM="shasum -a 256"; fi
# shellcheck disable=SC2086 # FILES is a list of plain names.
(cd "$OUT" && $SUM $FILES > SHA256SUMS.txt)

NOTES="$(dirname "$OUT")/release-notes.md"
python3 -I "$HERE/changelog-section.py" "$VERSION" > "$NOTES"
{
    echo
    echo "## Install"
    echo
    echo "See [Install](https://github.com/MarcoDotIO/Ycode#install) in the README. Check a download with \`shasum -a 256 -c SHA256SUMS.txt --ignore-missing\`."
    echo
    case "$SIGNING" in
        notarized)
            echo "The macOS disk image is signed with a Developer ID and notarized." ;;
        developer-id)
            echo "The macOS disk image is signed with a Developer ID but **not notarized**. macOS blocks it on first launch: see [Opening an ad-hoc signed build](https://github.com/MarcoDotIO/Ycode#opening-an-ad-hoc-signed-build)." ;;
        *)
            echo "The macOS disk image in this release is **ad-hoc signed, not notarized**. macOS blocks it on first launch: see [Opening an ad-hoc signed build](https://github.com/MarcoDotIO/Ycode#opening-an-ad-hoc-signed-build)." ;;
    esac
    echo
    echo "The \`.tar.xz\` files hold the same files as the Flatpak bundles, for repackaging. They are built against the freedesktop 25.08 runtime (glibc 2.42) and are not meant to run directly on most distributions: install the \`.flatpak\` instead."
    echo
    echo "Ycode is not affiliated with or endorsed by Apple Inc. Nothing of Apple's is in these packages."
} >> "$NOTES"
cat "$OUT/SHA256SUMS.txt"
