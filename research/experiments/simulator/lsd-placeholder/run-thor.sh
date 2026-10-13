#!/bin/bash
# run.sh <run-name> <seconds> [extra ycode-simd args...]   (agent J, on the Thor)
# Device: FRESH=1 -> a new device directory (first boot, seeding) with debug logging
#   preferences for LaunchServices/MobileInstallation (LOGDEBUG=0 to skip);
#   DEV=name -> 9-J/devs/<name> (created from PRISTINE if missing, kept);
#   default -> a copy of PRISTINE (default 9-J/dev-pristine) in the run directory.
# LOGPRED: predicate for a `log stream` one-shot (NOLOG=1: none). @DEV@ in args = device dir.
W=$YCODE_DATA/work/9-J
Y=${YTREE:-$W/ycode}
R=$YCODE_DATA/runtimes/iOS-27.1-24A94401/RuntimeRoot
PRISTINE=${PRISTINE:-$W/dev-pristine}
RUN=$W/runs/$1; SECS=$2; shift 2
[ -e "$RUN" ] && { echo "$RUN exists"; exit 1; }
mkdir -p "$RUN/shots" $W/devs
if [ "${FRESH:-0}" = 1 ]; then D=$RUN/dev; mkdir -p "$D"
  if [ "${LOGDEBUG:-1}" = 1 ]; then L=$D/data/Library/Preferences/Logging/Subsystems; mkdir -p $L
    for s in com.apple.launchservices com.apple.installd com.apple.appinstallation com.apple.MobileInstallation ${LOGSUBSYS}; do cp $W/logging-debug.plist $L/$s.plist; done; fi
elif [ -n "$DEV" ]; then D=$W/devs/$DEV; [ -d "$D" ] || cp -a $PRISTINE "$D"
else D=$RUN/dev; cp -a $PRISTINE "$D"; fi
AT=""; t=${FIRSTSHOT:-150}; while [ $t -lt $SECS ]; do AT="$AT --screenshot-at $t"; t=$((t+${SHOTSTEP:-60})); done
LOGSTREAM=()
if [ "${NOLOG:-0}" != 1 ]; then
  if [ -n "$LOGPRED" ]; then LOGSTREAM=(--oneshot "/usr/bin/log stream --style compact ${LOGLEVEL:---info} --predicate '$LOGPRED'")
  else LOGSTREAM=(--oneshot "/usr/bin/log stream --style compact"); fi
fi
EXTRA=(); for a in "$@"; do EXTRA+=("${a//@DEV@/$D}"); done
echo "$(date) run $1 dev $D args ${EXTRA[*]}" > "$RUN/cmd.txt"
YCODE_METAL_STATS=60 SWIFT_BACKTRACE=enable=yes,symbolicate=fast,interactive=no \
$Y/.build/release/ycode-simd --device "$D" --runtime-root $R --shim $Y/SimShim/out/shim.bin \
  --host-stubs $Y/SimShim/out/host_stubs.bin --host-libs $Y/SimHostLibs/out --runtime-paths \
  --metal-translator $Y/Translator/build/ycode-airc --gpu-cache-dir $YCODE_DATA/ycode-cache \
  --timeout-ms $((SECS*1000)) --screenshot "$RUN/shots/home.png" $AT "${LOGSTREAM[@]}" "${EXTRA[@]}" > "$RUN/log.txt" 2>&1
echo "exit $?" > "$RUN/DONE"
for f in "$D"/data/tmp/ycode-oneshot-*.out; do [ -f "$f" ] && cp "$f" "$RUN/guest-$(basename $f .out).txt"; done
exit 0
