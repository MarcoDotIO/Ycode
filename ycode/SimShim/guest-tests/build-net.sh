#!/bin/sh
# Builds the networking guest probes (specs/simulator/networking-ycode.md §8) for the
# iOS simulator platform. Runs on macOS only.
#   ../out/guest-tests/net/p_net          C: sockets, kevent/select/poll, interfaces, DNS
#   ../out/guest-tests/net/p_urlsession   Objective-C: an NSURLSession data task
#   ../out/guest-tests/net/p_netpath      the SystemConfiguration store, reachability, the
#                                         Network.framework path and one nw_connection
# Copy the output directory to the Thor; run there with
#   ycode-simd --device D --oneshot "<dir>/p_net <host-port> example.com"
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/../out/guest-tests/net}"
[ "$(uname -s)" = "Darwin" ] || { echo "build-net.sh: needs macOS" >&2; exit 1; }
mkdir -p "$out"
flags="-target arm64-apple-ios27.0-simulator -O2 -Wall -Wextra -Werror"
xcrun --sdk iphonesimulator clang $flags -o "$out/p_net" "$here/net/p_net.c"
xcrun --sdk iphonesimulator clang $flags -fobjc-arc -framework Foundation -o "$out/p_urlsession" "$here/net/p_urlsession.m"
xcrun --sdk iphonesimulator clang $flags -fobjc-arc -framework Foundation -framework Network -framework SystemConfiguration \
    -Wno-deprecated-declarations -o "$out/p_netpath" "$here/net/p_netpath.m"
xcrun --sdk iphonesimulator clang $flags -o "$out/p_dispatch" "$here/net/p_dispatch.c"
for p in p_net p_urlsession p_netpath p_dispatch; do echo "$out/$p: $(wc -c < "$out/$p" | tr -d ' ') bytes"; done
echo "build-net.sh: ok"
