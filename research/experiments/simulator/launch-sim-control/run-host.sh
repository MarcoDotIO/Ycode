#!/bin/sh
# Host mode: start the runtime's launchd_sim on this Mac with lsprobe as its host
# bootstrap, then run a scenario (lsprobe.c, "host mode"; scenarios/*.txt).
# usage: run-host.sh <bin-dir> <device-dir> <udid> <scenario> <out-prefix>
# <device-dir> holds env.txt and data/var/run/launchd_bootstrap.plist (a fake
# device made from a real device's bootstrap plist, read as a file format; see
# specs/simulator/launch-sim-control.md Appendix A). The scenarios expect
# <device-dir> = /tmp/ycode-R3/dev, lsguest copied to /tmp/ycode-R3/lsguest and
# /tmp/ycode-R3/rr a symlink to the RuntimeRoot.
BIN=$1; DEV=$2; UDID=$3; SCEN=$4; OUTP=$5
RR=${YC_RR:-"/Library/Developer/CoreSimulator/Volumes/iOS_24A94401/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.1.simruntime/Contents/Resources/RuntimeRoot"}
export YC_LIB="$RR/usr/lib/system/host/liblaunch_sim.dylib"
export YC_NAME_PREFIX=com.apple.CoreSimulator.SimDevice.$UDID
export YC_ENVFILE=$DEV/env.txt
export YC_SIM_STDERR=$OUTP.sim-stderr.txt
export YC_SCRIPT=$SCEN
T=/private/var/tmp/com.apple.CoreSimulator.SimDevice.$UDID
[ -d $T ] && cat /dev/null > $T/launchd.log
DYLD_INSERT_LIBRARIES=$BIN/lsinterpose.dylib $BIN/lsprobe host "$RR/sbin/launchd_sim" \
    ${YC_PLIST:-$DEV/data/var/run/launchd_bootstrap.plist} > $OUTP.txt 2>&1
echo "rc=$?"
cp $T/launchd.log $OUTP.launchd.log 2>/dev/null
