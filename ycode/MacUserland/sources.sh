#!/bin/sh
# Fetches the open-source projects the macOS userland is built from
# (specs/macos/swift-runtime.md, libsystem.md §13) into one directory, at pinned tags, as
# shallow clones. swift/build.sh applies Ycode's patches (swift/patches)
# to the swift-foundation checkout and to copies of the Swift platform
# sources, and runs the Swift repository's Resync.cmake in its checkout.
#
#   sh sources.sh [DIR] [NAME...]     default DIR: MacUserland/out/src;
#                                     default NAME: all of them
#
# DIR/<name> is left alone when it already exists (delete it to refetch).
# Every project here is Apache-2.0 (LLVM's with the LLVM exception; the
# Swift projects with the Runtime Library Exception) except curl (the curl
# licence, MIT-style) and ICU (the Unicode licence) inside
# swift-foundation-icu; build.sh copies each licence into the userland root.

set -eu
here=$(cd "$(dirname "$0")" && pwd)
dir=${1:-$here/out/src}
[ $# -gt 0 ] && shift
mkdir -p "$dir"

SWIFT_TAG=swift-6.4.0-RELEASE

# name  repository  ref  [sparse paths]
projects() {
    cat <<EOF
llvm-project https://github.com/swiftlang/llvm-project.git $SWIFT_TAG libc compiler-rt/lib/builtins libunwind libcxx libcxxabi runtimes cmake llvm/cmake llvm/utils/llvm-lit third-party
swift https://github.com/swiftlang/swift.git $SWIFT_TAG
swift-corelibs-libdispatch https://github.com/swiftlang/swift-corelibs-libdispatch.git $SWIFT_TAG
swift-foundation https://github.com/swiftlang/swift-foundation.git $SWIFT_TAG
swift-foundation-icu https://github.com/swiftlang/swift-foundation-icu.git $SWIFT_TAG
swift-corelibs-foundation https://github.com/swiftlang/swift-corelibs-foundation.git $SWIFT_TAG
swift-experimental-string-processing https://github.com/swiftlang/swift-experimental-string-processing.git $SWIFT_TAG
swift-collections https://github.com/apple/swift-collections.git 1.1.6
EOF
}

fetch() {
    name=$1 url=$2 ref=$3
    shift 3
    if [ -d "$dir/$name" ]; then
        echo "sources.sh: $name: present"
        return 0
    fi
    echo "sources.sh: $name: fetching $ref"
    if [ $# -gt 0 ]; then
        git clone -q --depth 1 --filter=blob:none --sparse --branch "$ref" "$url" "$dir/$name"
        (cd "$dir/$name" && git sparse-checkout set "$@")
    else
        git clone -q --depth 1 --branch "$ref" "$url" "$dir/$name"
    fi
}

want() {
    for w in $WANTED; do [ "$w" = "$1" ] && return 0; done
    return 1
}

WANTED="$*"
projects | while read -r name url ref paths; do
    if [ -z "$WANTED" ] || want "$name"; then
        # shellcheck disable=SC2086
        fetch "$name" "$url" "$ref" $paths
    fi
done
