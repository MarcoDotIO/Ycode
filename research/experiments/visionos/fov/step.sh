#!/bin/bash
# step.sh <run> "<vhid script>" : sample frames while vhid runs the script (STAMP on), then copy frames and logs to the run folder.
# env: FOV_WORK (scratch dirty folder with udid, build/), CR (the CR_DIR the boot used), VHID (vhid binary), PRE_MS (sampling before the script, default 800)
S=${FOV_WORK:?}; U=$(cat $S/udid); N=$1; O=$S/runs/$N; mkdir -p $O
rm -f $CR/frames.*.bin; touch $CR/on; sleep $(echo "${PRE_MS:-800}/1000" | bc -l)
printf '%s\n' "$2" | STAMP=1 $VHID $U script 2>/dev/null | grep -v '^objc' > $O/sent.txt
sleep ${POST_S:-2}; rm -f $CR/on; sleep 0.2
mv $CR/frames.*.bin $O/frames.bin; cp $CR/cr.backboardd.* $O/ 2>/dev/null
printf '%s\n' "$2" > $O/script.txt; echo "$N: $(grep -c SENT $O/sent.txt) sent, $(( $(stat -f %z $O/frames.bin 2>/dev/null || echo 0) / 5784 )) frames"
