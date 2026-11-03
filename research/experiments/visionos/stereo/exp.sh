#!/bin/bash
# exp.sh <run-name> [key=intval ...]: shut down the test device, set wakeboardd defaults (ints) in its preference file,
# boot with stereopeek, then record wakeboardctl status, StereoProbe output, a screenshot. Keys set are removed afterwards
# only by the next exp (each run starts from the plist with only hmd.preferred-languages).
S=${STEREO_WORK:?set STEREO_WORK to a scratch folder holding udid (the test device), runs/ and tools/}
B=${STEREO_BUILD:?set STEREO_BUILD to the folder with stereopeek.dylib}
U=$(cat $S/udid); N=$1; shift; O=$S/runs/$N; mkdir -p $O
xcrun simctl shutdown $U 2>/dev/null
P=~/Library/Developer/CoreSimulator/Devices/$U/data/Library/Preferences/com.apple.wakeboardd.plist
python3 -I $(dirname "$0")/setprefs.py $P.new "$@" > /dev/null
mv $P.new $P; plutil -p $P > $O/prefs.txt
INS=$B/stereopeek.dylib SP_PASSES=${SP_PASSES:-3} $(dirname "$0")/boot.sh $N SP_CAPTURES=${SP_CAPTURES:-3}
sleep ${SETTLE:-20}
xcrun simctl io $U screenshot $O/home.png >/dev/null 2>&1
xcrun simctl spawn $U wakeboardctl status > $O/wbctl-status.txt 2>&1
( xcrun simctl launch --console-pty --terminate-running-process $U dev.ycode.stereoprobe -layout layered > $O/probe.txt 2>&1 & )
sleep 15
xcrun simctl io $U screenshot $O/probe.png >/dev/null 2>&1
xcrun simctl spawn $U wakeboardctl status > $O/wbctl-status-probe.txt 2>&1
xcrun simctl terminate $U dev.ycode.stereoprobe
echo "== $N"; sed -n 3,12p $O/probe.txt | grep -E 'props|view 0|views'; grep -E 'SwapAddSurface #1 |newSharedTextureWithDescriptor' $O/sp.wakeboardd.* | head -3 | cut -c1-220
grep -n -E 'Type   |HMD State|layout  |Color Texture' $O/wbctl-status.txt | head -6
