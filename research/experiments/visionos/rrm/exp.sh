#!/bin/bash
# exp.sh <run> [domain:key=val ...] (OBS-VISION-RRM 2026-11-01): restore the test device's preferences, set the given keys
# (fov/setdomain.py syntax), boot with rrmpeek in every job, then record wakeboardctl status, a screenshot, rrmcli,
# StereoProbe (-layout layered, plus $PROBE_ARGS) for 12 s with a second status and screenshot, and collect the rp.* logs.
# env: RRM_WORK (scratch folder holding udid, runs/, prefs-backup/), RRM_BUILD (rrmpeek.dylib, rrmcli, StereoProbe.app);
# RP_INS (more dylibs to insert, colon list; stereopeek's SP_DIR is the same folder), RP_EXTRA (space-separated KEY=VAL passed to every job, e.g. RP_FORCE_RRM=1), PROBE_ARGS, SETTLE (s after bootstatus).
S=${RRM_WORK:?}; B=${RRM_BUILD:?}; U=$(cat $S/udid); N=$1; shift; O=$S/runs/$N; mkdir -p $O
F=$(cd "$(dirname "$0")/../fov" && pwd); DD=~/Library/Developer/CoreSimulator/Devices/$U/data; PD=$DD/Library/Preferences
export FOV_BACKUP=$S/prefs-backup
xcrun simctl shutdown $U 2>/dev/null; sleep 1
[ -d $FOV_BACKUP ] && python3 -I $F/setdomain.py --restore $PD $FOV_BACKUP
for a in "$@"; do dom=${a%%:*}; kv=${a#*:}; python3 -I $F/setdomain.py $PD $dom "$kv"; done > $O/prefs.txt
RPD=$DD/rp-$N; rm -rf $RPD; mkdir -p $RPD
EX=("SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=$B/rrmpeek.dylib${RP_INS:+:$RP_INS}" "SIMCTL_CHILD_RP_DIR=$RPD" "SIMCTL_CHILD_SP_DIR=$RPD" "SIMCTL_CHILD_RP_EARLY_SCAN=wakeboardd,backboardd")
for kv in $RP_EXTRA; do EX+=("SIMCTL_CHILD_$kv"); done; echo "${EX[@]} PROBE_ARGS=$PROBE_ARGS" > $O/env.txt
date '+%F %T' > $O/start
env "${EX[@]}" xcrun simctl boot $U
timeout 300 xcrun simctl bootstatus $U > $O/bootstatus.txt 2>&1; echo "boot rc $?" >> $O/bootstatus.txt
sleep ${SETTLE:-25}
timeout 60 xcrun simctl spawn $U wakeboardctl status > $O/wbctl.txt 2>&1
timeout 60 xcrun simctl io $U screenshot $O/home.png >/dev/null 2>&1
timeout 60 xcrun simctl spawn $U $B/rrmcli -render > $O/rrmcli.txt 2>&1; echo "rrmcli rc $?" >> $O/rrmcli.txt
xcrun simctl install $U $B/StereoProbe.app
xcrun simctl launch --console-pty --terminate-running-process $U dev.ycode.stereoprobe -layout layered $PROBE_ARGS > $O/probe.txt 2>&1 & LP=$!; sleep 12
timeout 60 xcrun simctl io $U screenshot $O/probe.png >/dev/null 2>&1
timeout 60 xcrun simctl spawn $U wakeboardctl status > $O/wbctl-probe.txt 2>&1
timeout 30 xcrun simctl terminate $U dev.ycode.stereoprobe 2>/dev/null; sleep 1; kill $LP 2>/dev/null   # only the launch this script started
sleep 2; cp $RPD/rp.* $O/ 2>/dev/null; cp $RPD/sp.* $O/ 2>/dev/null
echo "== $N: $(tail -1 $O/bootstatus.txt) | rp files: $(ls $O | grep -c '^rp\.')"
grep -h -E "supportsRasterizationRateMap|newRasterizationRateMap|setRasterizationRateMap|^.* (get|set) -\[" $O/rp.* 2>/dev/null | sed 's/^[0-9.]* //' | cut -c1-200 | sort | uniq -c | sort -rn | head -40
grep -E "caps |config chosen|props|rrm " $O/probe.txt | head -8 | cut -c1-240
grep -c "VRR Not Enabled" $O/wbctl-probe.txt
true
