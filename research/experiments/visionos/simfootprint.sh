#!/bin/sh
# Sum phys_footprint over the processes of one booted simulator (macOS host).
# Usage: simfootprint.sh <udid>   (needs simprocs.py next to it)
here=$(dirname "$0")
total=0
for p in $(python3 -I "$here/simprocs.py" "$1" | grep -v '^#' | cut -f1); do
  kb=$(footprint -p "$p" 2>/dev/null | awk '/phys_footprint:/{v=$2; u=$3; if(u=="MB")v*=1024; else if(u=="GB")v*=1048576; else if(u=="B")v/=1024; print int(v); exit}')
  name=$(ps -p "$p" -o comm= | awk -F/ '{print $NF}')
  [ -n "$kb" ] && { echo "$p	$kb	$name"; total=$((total+kb)); }
done
echo "# total_phys_footprint_MiB $((total/1024))"
