#!/bin/zsh
# Install the signed HealthProbe build on the paired iPhone and Apple Watch with devicectl.
# Both devices must be unlocked, in Developer Mode and trusted by this Mac.
# Device identifiers are looked up at run time; they and the device names are not printed.
# devicectl's own output goes to HP_LOG (default ~/Library/Logs/HealthProbe-install.log).
set -euo pipefail
cd "${0:A:h}"
DERIVED="${HP_DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/HealthProbe-research}"
APP="$DERIVED/Build/Products/Debug-iphoneos/HealthProbe.app"
LOG="${HP_LOG:-$HOME/Library/Logs/HealthProbe-install.log}"
[[ -d "$APP" ]] || { echo "Build first: ./build.sh" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
xcrun devicectl list devices --json-output "$TMP/devices.json" >/dev/null 2>&1
pick() {
  python3 -I -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hp = d.get("hardwareProperties", {})
    if hp.get("reality") == "physical" and hp.get("platform") == sys.argv[2]:
        print(d["identifier"])
        break
' "$TMP/devices.json" "$1"
}
PHONE=$(pick iOS)
WATCH=$(pick watchOS)
: > "$LOG"
if [[ -z "$PHONE" ]]; then echo "No physical iPhone is connected." >&2; exit 1; fi
if xcrun devicectl device install app --device "$PHONE" "$APP" >>"$LOG" 2>&1; then
  echo "iPhone: installed"
else
  echo "iPhone: install failed (details in $LOG)"; exit 1
fi
if [[ -z "$WATCH" ]]; then echo "No physical Apple Watch is visible; skipped." >&2; exit 1; fi
if xcrun devicectl device install app --device "$WATCH" "$APP/Watch/HealthProbeWatch.app" >>"$LOG" 2>&1; then
  echo "Watch: installed"
else
  echo "Watch: install failed (details in $LOG)"; exit 1
fi
