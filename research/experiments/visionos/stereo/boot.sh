#!/bin/bash
# boot.sh <run-name> [KEY=VAL ...]: boot the test device with $INS inserted (colon list), env as SIMCTL_CHILD_KEY=VAL, wait for bootstatus.
S=${STEREO_WORK:?set STEREO_WORK}
U=$(cat $S/udid); N=$1; shift
O=$S/runs/$N; mkdir -p $O
ENVS=("SIMCTL_CHILD_SP_DIR=$O" "SIMCTL_CHILD_MTLREC_DIR=$O")
[ -n "$INS" ] && ENVS+=("SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=$INS")
for kv in "$@"; do ENVS+=("SIMCTL_CHILD_$kv"); done
echo "INS=$INS $@" > $O/args
date '+%Y-%m-%d %H:%M:%S' > $O/start
env "${ENVS[@]}" xcrun simctl boot $U
T0=$(date +%s)
timeout ${BOOTWAIT:-240} xcrun simctl bootstatus $U > $O/bootstatus.txt 2>&1; echo "bootstatus rc=$? after $(( $(date +%s) - T0 )) s" | tee -a $O/bootstatus.txt
