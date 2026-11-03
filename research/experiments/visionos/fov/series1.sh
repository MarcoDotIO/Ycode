#!/bin/bash
# series1.sh: the camera-smoothing series of OBS-VISION-FOV (step sizes, translation, pose timestamps, send rates).
# env as step.sh. Each run ends at identity.
F=$(cd "$(dirname "$0")" && pwd); G() { python3 -I $F/posegen.py "$@"; }
run(){ n=$1; shift; $F/step.sh $n "$*"; }
for r in "$@"; do case $r in
 s2) run s2-60 "$(G step 60 1500)"$'\n'"$(G home 1500)";;
 s3) run s3-5 "$(G step 5 1500)"$'\n'"$(G home 1500)";;
 s4) run s4-t03 "$(G tstep 0.3 1500)"$'\n'"$(G home 1500)";;
 s5) TS_OFFSET_MS=200 run s5-fut200 "$(G step 30 1500)"$'\n'"$(G home 1500)";;
 s6) TS_OFFSET_MS=-200 run s6-past200 "$(G step 30 1500)"$'\n'"$(G home 1500)";;
 s7) TS_OFFSET_MS=-3000 run s7-past3000 "$(G step 30 1500)"$'\n'"$(G home 1500)";;
 s7b) TS_OFFSET_MS=3000 run s7b-fut3000 "$(G step 30 1500)"$'\n'"$(G home 3500)";;
 s8) TS_ABS=1 run s8-abs1 "$(G step 30 1500)"$'\n'"$(G home 1500)";;
 s9) run s9-rep90 "$(G repeat 30 90 600)"$'\n'"sleep 900"$'\n'"$(G repeat 0 90 600)"$'\n'"sleep 900";;
 s10) run s10-rep30 "$(G repeat 30 30 600)"$'\n'"sleep 900"$'\n'"$(G repeat 0 30 600)"$'\n'"sleep 900";;
 s11) run s11-ramp90 "$(G ramp 30 90 500 1200)"$'\n'"$(G home 1500)";;
 s12) run s12-ramp30 "$(G ramp 30 30 500 1200)"$'\n'"$(G home 1500)";;
 s13) run s13-sine90 "$(G sine 15 1 90 3000)";;
 s14) run s14-sine30 "$(G sine 15 1 30 3000)";;
 t1) TS_SCALE=0.1 run t1-sine90-ts01 "$(G sine 15 1 90 3000)";;
 t2) TS_SCALE=10 run t2-sine90-ts10 "$(G sine 15 1 90 3000)";;
 t3) TS_SCALE=0.1 run t3-rep90-ts01 "$(G repeat 30 90 600)"$'\n'"sleep 900"$'\n'"$(G repeat 0 90 600)"$'\n'"sleep 900";;
 t4) TS_SCALE=3 run t4-rep90-ts3 "$(G repeat 30 90 600)"$'\n'"sleep 900"$'\n'"$(G repeat 0 90 600)"$'\n'"sleep 900";;
 pair*) g=${r#pair}; run u-pair$g "$(G step 15 $g)"$'\n'"$(G step 30 1500)"$'\n'"$(G home 1500)";;
 boost*) g=${r#boost}; run u-boost$g "$(G step 36.5 $g)"$'\n'"$(G step 30 1500)"$'\n'"$(G home 1500)";;
 t5) run t5-pair33 "$(G step 15 33)"$'\n'"$(G step 30 1500)"$'\n'"$(G home 1500)";;
esac; done
