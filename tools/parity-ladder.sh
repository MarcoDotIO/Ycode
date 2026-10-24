#!/bin/bash
# parity-ladder.sh: the service ladder of specs/simulator/parity-ladder.md on
# both platforms. Step k ("base+k") = the lean profile with the first k
# labels of tools/parity-ladder-order.txt enabled again; step 0 is the lean
# base, step 23 is the full boot. "Only <label>" = all-but-one: every label
# enabled except <label> (the leave-one-out check).
#
#   parity-ladder.sh order                       the ladder, numbered
#   parity-ladder.sh keep <k>                    comma list of the first k labels
#   parity-ladder.sh mac <k> <runs> <outdir> [first-index]
#                                                Mac: <runs> new devices at base+k,
#                                                first and second boot each
#   parity-ladder.sh mac-pair <k> <runs> <outdir>
#                                                Mac: <runs> rounds of base, base+k
#                                                (interleaved, the ladder protocol)
#   parity-ladder.sh mac-only <label> <runs> <outdir>
#                                                Mac: only <label> disabled
#   parity-ladder.sh mac-summary <outdir...>     Mac: table of the runs
#   parity-ladder.sh ycode <k> <run> [agent]     Ycode: one harness run at base+k
#   parity-ladder.sh ycode-only <label> <run> [agent]
#                                                Ycode: only <label> disabled
#   parity-ladder.sh ycode-result <run> [agent]  Ycode: result.txt, per-label
#                                                spawn counts, guest crash count
#
# The Mac side uses tools/mac-sim-lean-boot.py (devices named
# ycode-test-L-ladder*, deleted afterwards). The Ycode side needs
# YCODE_THOR (user@host, SSH key login only) and YCODE_SX (the harness
# directory on it, holding bin/bench.sh and <agent>/ with a release build);
# machine names stay out of the repository. Ycode runs use the lean-boot.md
# §7 harness settings: BENCH_TMPFS=1 BENCH_NOKILL=1 BENCH_SECS=700 (and BENCH_KEEPDEV=1:
# the harness drops the device copy otherwise, and ycode-result reads its TMP), and
# YCODE_LEAN_BOOT=daemons with YCODE_LEAN_BOOT_KEEP = the labels enabled
# again. A run name can be used once (bench.sh refuses an existing one).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
order=$here/parity-ladder-order.txt
labels() { grep -v '^#' "$order" | sed '/^[[:space:]]*$/d' | awk '{print $1}'; }
count() { labels | wc -l | tr -d ' '; }
keep() {
    local k=$1 n; n=$(count)
    [[ $k =~ ^[0-9]+$ ]] && [ "$k" -le "$n" ] || { echo "parity-ladder: step must be 0..$n" >&2; exit 64; }
    [ "$k" -eq 0 ] && { echo ""; return; }
    labels | head -n "$k" | paste -sd, -
}
known() { labels | grep -qx "$1" || { echo "parity-ladder: $1 is not in $order" >&2; exit 64; }; }
all_but() { known "$1"; labels | grep -vx "$1" | paste -sd, -; }
thor() {
    : "${YCODE_THOR:?set YCODE_THOR=user@host}" "${YCODE_SX:?set YCODE_SX=<harness dir>}"
    ssh -o BatchMode=yes "$YCODE_THOR" "$@"
}
safe() { [[ $1 =~ ^[A-Za-z0-9._-]+$ ]] || { echo "parity-ladder: bad name '$1'" >&2; exit 64; }; }

case "${1:-}" in
order) labels | nl -w2 -s'  ' ;;
keep) keep "$2" ;;
mac)
    k=$(keep "$2")
    python3 -I "$here/mac-sim-lean-boot.py" --mode lean --runs "$3" --keep "$k" \
        --prefix "ycode-test-L-ladder$2" --out "$4" --start-index "${5:-1}" ;;
mac-pair)
    # Interleaved with the base: <runs> rounds of (base, base+k), new devices each.
    k=$(keep "$2")
    for i in $(seq 1 "$3"); do
        python3 -I "$here/mac-sim-lean-boot.py" --mode lean --runs 1 \
            --prefix ycode-test-L-ladder0 --out "$4" --start-index "$i"
        python3 -I "$here/mac-sim-lean-boot.py" --mode lean --runs 1 --keep "$k" \
            --prefix "ycode-test-L-ladder$2" --out "$4" --start-index "$i"
    done ;;
mac-only)
    known "$2"
    python3 -I "$here/mac-sim-lean-boot.py" --mode lean --runs "$3" --enable "$2" \
        --prefix "ycode-test-L-only-$(echo "$2" | sed 's/^com\.apple\.//; s/[^A-Za-z0-9]/_/g')" --out "$4" ;;
mac-summary) shift; python3 -I "$here/mac-sim-lean-summary.py" "$@" ;;
ycode|ycode-only)
    agent=${4:-L2}; safe "$3"; safe "$agent"
    if [ "$1" = ycode ]; then k=$(keep "$2"); else k=$(all_but "$2"); fi
    thor "YCODE_LEAN_BOOT=daemons YCODE_LEAN_BOOT_KEEP='$k' BENCH_TMPFS=1 BENCH_NOKILL=1 BENCH_KEEPDEV=1 BENCH_SECS=700 \
          $YCODE_SX/bin/bench.sh $agent $3" ;;
ycode-result)
    agent=${3:-L2}; safe "$2"; safe "$agent"
    progs=$(labels | sed 's/^com\.apple\.//; s/^accessibility\.//' | paste -sd' ' -)
    # This boot's TMP: the UDID ycode-simd prints (older TMPs of the golden
    # device are kept next to it under other UDIDs).
    thor "r=$YCODE_SX/$agent/runs/$2; cat \$r/result.txt; grep -m1 'lean boot' \$r/log.txt || echo 'lean boot: off';
          echo \"guest processes ended by a signal other than 9: \$(grep 'ended with status' \$r/log.txt | grep signal | grep -vc 'signal 9;')\";
          u=\$(grep -m1 -o 'UDID [0-9A-F-]*' \$r/log.txt | cut -d' ' -f2);
          l=\$r/dev/private-var-tmp/com.apple.CoreSimulator.SimDevice.\$u/launchd.log;
          [ -f \$l ] && for p in $progs; do printf '%-34s spawns %s\\n' \$p \$(grep -c \"Successfully spawned \$p\\[\" \$l); done" ;;
*) sed -n '2,32p' "$0"; exit 64 ;;
esac
