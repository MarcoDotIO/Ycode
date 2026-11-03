#!/bin/bash
# pexp.sh <run> <what> [domain:key=val ...]: restore the device's preferences, set the given keys, boot with camrec,
# record wakeboardctl status and a screenshot, then <what>: "step" (30 deg yaw step and back), "sine" (1 Hz +-15 deg at ~75/s),
# "probe" (StereoProbe layered for 12 s), any combination joined by +.
# env: FOV_WORK, FOV_DYLIB (camrec copy), VHID; CR_PFLAGS/CR_TFLAGS/CR_OFLAGS are passed to camrec; PROBE_APP (StereoProbe.app) is installed before "probe".
S=${FOV_WORK:?}; U=$(cat $S/udid); N=$1; W=$2; shift 2; O=$S/runs/$N; mkdir -p $O
F=$(cd "$(dirname "$0")" && pwd); DD=~/Library/Developer/CoreSimulator/Devices/$U/data; PD=$DD/Library/Preferences
export FOV_BACKUP=${FOV_BACKUP:-$S/prefs-backup}
xcrun simctl shutdown $U 2>/dev/null; sleep 1
[ -d $FOV_BACKUP ] && python3 -I $F/setdomain.py --restore $PD $FOV_BACKUP
for a in "$@"; do dom=${a%%:*}; kv=${a#*:}; python3 -I $F/setdomain.py $PD $dom "$kv"; done > $O/prefs.txt
CRD=$DD/cr-$N; rm -rf $CRD; mkdir -p $CRD; export CR=$CRD
EX=(); for v in CR_PFLAGS CR_TFLAGS CR_OFLAGS; do [ -n "${!v}" ] && EX+=("SIMCTL_CHILD_$v=${!v}"); done; echo "${EX[@]}" > $O/env.txt
env "${EX[@]}" SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=$FOV_DYLIB SIMCTL_CHILD_CR_DIR=$CRD xcrun simctl boot $U
timeout 300 xcrun simctl bootstatus $U > $O/bootstatus.txt 2>&1; echo "boot rc $?" >> $O/bootstatus.txt
sleep ${SETTLE:-25}
timeout 60 xcrun simctl spawn $U wakeboardctl status > $O/wbctl.txt 2>&1
timeout 60 xcrun simctl io $U screenshot $O/home.png >/dev/null 2>&1
G() { python3 -I $F/posegen.py "$@"; }
case $W in *step*) $F/step.sh $N/step "$(G step 30 1500)"$'\n'"$(G home 1500)";; esac
case $W in *sine*) $F/step.sh $N/sine "$(G sine 15 1 90 3000)";; esac
case $W in *probe*) [ -n "$PROBE_APP" ] && xcrun simctl install $U "$PROBE_APP"; ( xcrun simctl launch --console-pty --terminate-running-process $U dev.ycode.stereoprobe -layout layered > $O/probe.txt 2>&1 & ); sleep 12
   xcrun simctl io $U screenshot $O/probe.png >/dev/null 2>&1; xcrun simctl spawn $U wakeboardctl status > $O/wbctl-probe.txt 2>&1; xcrun simctl terminate $U dev.ycode.stereoprobe;; esac
cp $CRD/cr.* $O/ 2>/dev/null
echo "== $N: $(grep -m1 tangents $O/wbctl.txt | tr -s ' ') | fps $(grep -m1 -i 'duration on display' $O/wbctl.txt | tr -s ' ')"
for k in step sine; do [ -f $O/$k/frames.bin ] && python3 -I $F/camstep.py $O/$k/frames.bin $O/$k/sent.txt --maxshift 44 --quiet --csv $O/$k/yaw.csv; done
[ -f $O/step/yaw.csv ] && python3 -I $F/stepsum.py $O/step | head -2
[ -f $O/sine/yaw.csv ] && python3 -I $F/lagfit.py $O/sine
[ -f $O/probe.txt ] && grep -m3 -E "props|tangents|projection" $O/probe.txt | cut -c1-260
true
