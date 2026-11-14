#!/bin/sh
# Builds Ycode-<version>-<arch>.flatpak and the same files as a relocatable
# Ycode-<version>-<arch>.tar.xz, from the committed tree. packaging/README.md
# describes the interface.
#
# Usage: packaging/flatpak/build-flatpak.sh [output-dir]    (default packaging/flatpak/out)
#
# Environment (all optional):
#   YCODE_SOURCE_REF   the commit to package (default HEAD)
#   YCODE_SOURCE_TAR   a tar of the same paths, instead of git archive
#   YCODE_FLATPAK_WORK the work folder (default packaging/flatpak/.work)
#   YCODE_FLATPAK_JOBS at most this many build jobs (default: every core)
#   YCODE_GUEST_TOOLS  the simulator's guest tools for the aarch64 tree, built on
#                      a Mac by build-guest-tools.sh (a release must have them)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
id=io.github.MarcoDotIO.Ycode
out=${1:-$here/out}
work=${YCODE_FLATPAK_WORK:-$here/.work}
version=$(cat "$root/ycode/VERSION")
arch=$(flatpak --default-arch)

mkdir -p "$out" "$work/manifest/source"
out=$(cd "$out" && pwd)
work=$(cd "$work" && pwd)

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$here/$id.desktop"
fi
if command -v appstreamcli >/dev/null 2>&1; then
    appstreamcli validate --no-net "$here/$id.metainfo.xml"
fi

flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# The package is built from committed files only: no research/, no local files.
if [ -n "${YCODE_SOURCE_TAR:-}" ]; then
    cp "$YCODE_SOURCE_TAR" "$work/manifest/source/ycode-source.tar"
else
    git -C "$root" archive --format=tar -o "$work/manifest/source/ycode-source.tar" "${YCODE_SOURCE_REF:-HEAD}" \
        ycode frameworks packaging LICENSE THIRD_PARTY_NOTICES.md specs/simulator/data
fi
cp "$here/swift-dependencies.json" "$work/manifest/"
rm -rf "$work/manifest/guest-tools"
mkdir -p "$work/manifest/guest-tools"
if [ -n "${YCODE_GUEST_TOOLS:-}" ]; then
    [ -f "$YCODE_GUEST_TOOLS/ylaunch" ] || { echo "build-flatpak: $YCODE_GUEST_TOOLS has no ylaunch" >&2; exit 1; }
    cp -R "$YCODE_GUEST_TOOLS/." "$work/manifest/guest-tools/"
else
    echo "Guest tools: none (YCODE_GUEST_TOOLS); the simulator tree has none." > "$work/manifest/guest-tools/README"
    if [ "$arch" = aarch64 ]; then
        echo "build-flatpak: warning: no YCODE_GUEST_TOOLS; the aarch64 simulator tree will boot devices but not run apps" >&2
    fi
fi
if [ "$arch" = aarch64 ]; then
    sed 's/^  #aarch64-only: /  /' "$here/$id.yml" > "$work/manifest/$id.yml"
else
    cp "$here/$id.yml" "$work/manifest/$id.yml"
fi

# flatpak-builder's cache knows a local archive only by its path and hash: without
# the hash, a new commit would reuse the previous commit's build.
source_sha=$(sha256sum "$work/manifest/source/ycode-source.tar" | cut -d' ' -f1)
sed -i "s|^        path: source/ycode-source.tar\$|&\n        sha256: $source_sha|" "$work/manifest/$id.yml"
grep -q "sha256: $source_sha" "$work/manifest/$id.yml" || { echo "build-flatpak: could not pin the source" >&2; exit 1; }

flatpak-builder --user --install-deps-from=flathub --force-clean --disable-rofiles-fuse --arch="$arch" \
    ${YCODE_FLATPAK_JOBS:+--jobs="$YCODE_FLATPAK_JOBS"} \
    --state-dir="$work/state" --repo="$work/repo" "$work/build" "$work/manifest/$id.yml"

bundle="$out/Ycode-$version-$arch.flatpak"
flatpak build-bundle --arch="$arch" --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
    "$work/repo" "$bundle" "$id"
(cd "$out" && sha256sum "$(basename "$bundle")" > "$(basename "$bundle").sha256")

# The same files as a relocatable tarball, for a wrapper that takes the release
# as it is. It needs this runtime's libraries (or a host with its glibc or newer).
top="Ycode-$version-$arch"
tarball="$out/$top.tar.xz"
epoch=$(git -C "$root" log -1 --format=%ct "${YCODE_SOURCE_REF:-HEAD}" 2>/dev/null || cat "$root/.source-date-epoch" 2>/dev/null || echo 0)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    --transform "s,^files,$top," -C "$work/build" -cf - files | xz -T0 -6 > "$tarball"
(cd "$out" && sha256sum "$top.tar.xz" > "$top.tar.xz.sha256")

ls -l "$bundle" "$tarball"
echo "$bundle"
echo "$tarball"
