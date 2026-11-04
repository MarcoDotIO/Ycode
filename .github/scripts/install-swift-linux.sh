#!/bin/sh
# Installs a Swift release from swift.org on an Ubuntu machine into a folder,
# after checking its signature with the keys swift.org publishes.
# Usage: install-swift-linux.sh <version> <folder>     for example 6.4.2 "$HOME/.swift-toolchain"
# An installed toolchain in that folder (from the cache) is kept as it is.
set -eu
SWIFT="$1"
TARGET="$2"

if [ -x "$TARGET/usr/bin/swift" ]; then
    "$TARGET/usr/bin/swift" --version
    exit 0
fi

# Only VERSION_ID: sourcing /etc/os-release would also set VERSION ("24.04.3 LTS (Noble Numbat)").
VERSION_ID="$(. /etc/os-release && printf '%s' "$VERSION_ID")"
UBUNTU="ubuntu${VERSION_ID}"                           # ubuntu24.04
FOLDER="ubuntu$(printf '%s' "$VERSION_ID" | tr -d .)"  # ubuntu2404
SUFFIX=""
case "$(uname -m)" in
    aarch64) FOLDER="$FOLDER-aarch64"; SUFFIX="-aarch64" ;;
    x86_64) ;;
    *) echo "No Swift release for $(uname -m)" >&2; exit 1 ;;
esac
NAME="swift-${SWIFT}-RELEASE-${UBUNTU}${SUFFIX}.tar.gz"
URL="https://download.swift.org/swift-${SWIFT}-release/${FOLDER}/swift-${SWIFT}-RELEASE/${NAME}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL --retry 3 -o "$WORK/$NAME" "$URL"
curl -fsSL --retry 3 -o "$WORK/$NAME.sig" "$URL.sig"
export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
# The keys download now and then returns something other than the key file on
# CI runners, so check for the key block and try a few times.
for attempt in 1 2 3 4 5; do
    if curl -fsSL --retry 3 -o "$WORK/keys.asc" https://www.swift.org/keys/all-keys.asc \
        && grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$WORK/keys.asc"; then
        break
    fi
    [ "$attempt" = 5 ] && { echo "Could not download swift.org's signing keys" >&2; exit 1; }
    sleep $((attempt * 5))
done
gpg --batch --quiet --import "$WORK/keys.asc"
gpg --batch --quiet --verify "$WORK/$NAME.sig" "$WORK/$NAME"
mkdir -p "$TARGET"
tar -xzf "$WORK/$NAME" -C "$TARGET" --strip-components=1
"$TARGET/usr/bin/swift" --version
