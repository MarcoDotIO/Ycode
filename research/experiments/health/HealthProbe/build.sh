#!/bin/zsh
# Build HealthProbe: the iOS app with the watch app embedded under Watch/.
#
#   ./build.sh --unsigned   compile only (no signing, no Apple account needed)
#   ./build.sh              sign with the team already selected in Xcode, using
#                           automatic signing (-allowProvisioningUpdates); needs the
#                           owner's account to be signed in to Xcode
#
# The team ID and the bundle prefix are passed on the command line and never stored in
# the project. Set HP_TEAM or HP_BUNDLE_PREFIX to override. Build output goes to
# HP_DERIVED (default: DerivedData on the internal disk).
set -euo pipefail
cd "${0:A:h}"
DERIVED="${HP_DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/HealthProbe-research}"
COMMON=(-project HealthProbe.xcodeproj -scheme HealthProbe -configuration Debug
        -destination generic/platform=iOS -derivedDataPath "$DERIVED")
if [[ "${1:-}" == "--unsigned" ]]; then
  xcodebuild "${COMMON[@]}" CODE_SIGNING_ALLOWED=NO build
  exit
fi
TEAM="${HP_TEAM:-$(defaults read com.apple.dt.Xcode IDEProvisioningTeamManagerLastSelectedTeamID 2>/dev/null || true)}"
if [[ -z "$TEAM" ]]; then
  echo "No team selected: sign in to Xcode (Settings > Accounts) or set HP_TEAM." >&2
  exit 1
fi
# Bundle IDs are global on Apple's side, so derive a per-team prefix.
PREFIX="${HP_BUNDLE_PREFIX:-org.ycode.research.t$(print -n "$TEAM" | shasum | cut -c1-8)}"
xcodebuild "${COMMON[@]}" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" HP_BUNDLE_PREFIX="$PREFIX" build
echo "built: $DERIVED/Build/Products/Debug-iphoneos/HealthProbe.app"
