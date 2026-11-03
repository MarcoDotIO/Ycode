#!/bin/sh
# Builds Ycode's hosted-test agent, libYcodeTestAgent.dylib
# (Sources/YcodeTestAgent and Sources/CYcodeTestAgentLoader; specs/ide/testing.md
# "Ycode implementation"), for the iOS simulator platform. Runs on macOS
# only (the iOS simulator SDK). The agent links neither XCTest nor Testing.
#   out/iphonesimulator/libYcodeTestAgent.dylib
# ycodebuild finds it in iphonesimulator/ next to itself, or through
# YCODE_TEST_AGENT_IPHONESIMULATOR:
#   OUT=.build/debug SimGuestAgents/build-test-agent.sh      (from ycode/)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
src="$here/../Sources"
out="${OUT:-$here/out}/iphonesimulator"
[ "$(uname -s)" = "Darwin" ] || { echo "SimGuestAgents/build-test-agent.sh: needs macOS" >&2; exit 1; }
target="${TARGET:-arm64-apple-ios17.0-simulator}"
mkdir -p "$out/obj-test-agent"
xcrun --sdk iphonesimulator clang -target "$target" -O2 -Wall -Wextra -Werror \
    -I "$src/CYcodeTestAgentLoader/include" -c -o "$out/obj-test-agent/loader.o" "$src/CYcodeTestAgentLoader/loader.c"
xcrun --sdk iphonesimulator swiftc -target "$target" -O -module-name YcodeTestAgent -parse-as-library \
    -emit-library -Xlinker -install_name -Xlinker @rpath/libYcodeTestAgent.dylib \
    -o "$out/libYcodeTestAgent.dylib" "$src/YcodeTestAgent/TestAgent.swift" "$out/obj-test-agent/loader.o"
rm -rf "$out/obj-test-agent"
echo "$out/libYcodeTestAgent.dylib: $(wc -c < "$out/libYcodeTestAgent.dylib" | tr -d ' ') bytes"
echo "SimGuestAgents/build-test-agent.sh: ok"
