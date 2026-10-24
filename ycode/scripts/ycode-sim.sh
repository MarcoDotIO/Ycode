#!/bin/bash
# ycode-sim: the host-side launcher behind Ycode's "Ycode Simulator (Linux)"
# run destination (specs/ide/run.md §Warm boot). Install it on the simulator
# host as the "ycode-simd path" of Settings ▸ Simulators. Ycode runs it over ssh:
#
#   echo YCODE-REMOTE-PID $$; exec env YCODE_WARM_BOOT=1|0 [YCODE_LEAN_BOOT=…] \
#       ycode-sim --device DEV --runtime-root RR [--install-app APP --launch ID] [extra options]
#   ycode-sim --erase --device DEV      erases the device (its directory and its snapshot)
#
# It adds ycode-simd's host-side options, takes a boot slot (a flock on
# $YCODE_SIM_LOCKS/boot.N, shared with benchmark runs so their timings stay
# fair) and runs ycode-simd. With YCODE_WARM_BOOT=1 the device keeps its
# state between runs (specs/simulator/snapshot.md §12): when the run is
# stopped, the app is ended and the device is saved (its memory, with its
# data directory left exactly as the save saw it), and the next run restores
# it in place, then installs and launches the app as after a boot. App data,
# settings and installed apps therefore stay until the device is erased. A
# run that ends without a save (a crash, a failed save) leaves the device
# directory as it is and the next run boots it cold. A restore that fails
# falls back to a cold boot by itself. Without YCODE_WARM_BOOT=1 it execs
# ycode-simd as before (cold boot, same pid).
#
# Configuration: the environment, or ycode-sim.conf next to this script
# (shell assignments; keep machine paths there, not here):
#   YCODE_SIM_TREE         ycode/ tree with release builds (required)
#   YCODE_SIM_DATA         data directory for snapshots, frames and logs (required;
#                          must be on the data volume, not the system disk)
#   YCODE_SIM_LOCKS        directory of the shared boot-slot locks (default: $YCODE_SIM_DATA/locks)
#   YCODE_SIM_SLOTS        number of boot slots (default 3)
#   YCODE_SIM_GPU_CACHE    --gpu-cache-dir (default: $YCODE_SIM_DATA/gpu-cache)
#   YCODE_SIM_GUEST_TOOLS  --guest-tools (directory with ylaunch; optional)
#   YCODE_SIM_TIMEOUT_MS   --timeout-ms (default 1500000)
#   YCODE_WARM_STAGE       RAM file system to stage a save in (default /run/user/<uid>;
#                          "none": write it to the data directory, a longer pause)
#   YCODE_WARM_SETTLE_MS   cold boot: time between the home screen and the app steps (default 60000)
#   YCODE_WARM_HOME_TIMEOUT_S  a restore that shows no home screen in this time has failed (default 120)
#   YCODE_WARM_APP_TIMEOUT_S   a restore whose app steps have not finished in this time has failed (default 300)
#   YCODE_WARM_STOP_TIMEOUT_S  how long a stop may take to save the device before ycode-simd is killed (default 120)
#   YCODE_WARM_SAVE_SETTLE_S  a cold boot is saved at its stop only this long after its home screen
#                          (default 30; a restore once its home screen shows): a device stopped
#                          earlier shuts down without a save, and the next run boots it cold
#   YCODE_WARM_FORCE_COLD  1: this run boots cold even when the snapshot matches (the snapshot is
#                          discarded; the device keeps its data and the stop saves it again)
#   YCODE_WARM_KEEP_LOGS   run logs and crash reports kept per device (default 10)
#   YCODE_WARM_LIVE_TIMEOUT_S  a restore whose guest has not answered a request in this
#                          time has failed (default 60; snapshot.md §12.5)
#   YCODE_WARM_FRAME_TIMEOUT_S  a restore whose guest has presented no new frame in this time
#                          has failed (default 90; 0: no such check; snapshot.md §12.5)
#
# Host crashes: unless SWIFT_BACKTRACE is set, ycode-simd's crash report goes to
# runs/<device>/crashes/ (all threads, the image list, no symbol lookup in the
# crashing process) and the launcher symbolizes it afterwards with
# llvm-symbolizer into <report>.sym.txt (snapshot.md §12.5).
#
# Device types: ycode-simd's --device-type passes through (a device directory
# keeps its type, specs/simulator/ipad.md §4.3; the option is part of the
# snapshot fingerprint), so give each type its own --device directory.
#
# scripts/ycode-sim-serve (the Mac viewer's host side) runs this launcher too,
# with --display-server and no app options, so a viewer session is saved at
# its end and restored by the next one (display-stream.md §8).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$HERE/ycode-sim.conf" ] && . "$HERE/ycode-sim.conf"
Y=${YCODE_SIM_TREE:?YCODE_SIM_TREE is not set}
DATA=${YCODE_SIM_DATA:?YCODE_SIM_DATA is not set}
LOCKS=${YCODE_SIM_LOCKS:-$DATA/locks}
SLOTS=${YCODE_SIM_SLOTS:-3}
SIMD=$Y/.build/release/ycode-simd
HOST_ARGS=(--shim "$Y/SimShim/out/shim.bin" --host-stubs "$Y/SimShim/out/host_stubs.bin" --host-libs "$Y/SimHostLibs/out"
           --runtime-paths --metal-translator "$Y/Translator/build/ycode-airc"
           --gpu-cache-dir "${YCODE_SIM_GPU_CACHE:-$DATA/gpu-cache}" --timeout-ms "${YCODE_SIM_TIMEOUT_MS:-1500000}")
[ -n "${YCODE_SIM_GUEST_TOOLS:-}" ] && HOST_ARGS+=(--guest-tools "$YCODE_SIM_GUEST_TOOLS")
# say: a status line for Ycode's console (and the run log); note: the run log only.
say() { echo "ycode-sim: $*"; note "$*"; }
# (printf's %(...)T: no command substitution, see tick below)
note() { [ -d "${RUN:-}" ] && printf '%(%F %T)T %s\n' -1 "$*" >> "$RUN/ycode-sim.log"; return 0; }
now_ns() { date +%s%N; }
# tick: NOW_NS = now, without a command substitution. The watch loop, its
# notes and the signal trap use no $(...): a SIGINT (Ycode's Stop) that came
# while bash 5.2 ran one made it fail with "unexpected EOF while looking for
# matching ')'" and exit, or was lost, and ycode-simd ran on without a stop
# (snapshot.md §12.5).
tick() { local t=${EPOCHREALTIME//[!0-9]/}; if [ -n "$t" ]; then NOW_NS=${t}000; else NOW_NS=$(date +%s%N); fi; }
# fsecs VAR A B: VAR = (B - A) ns as seconds with one decimal (builtins only).
fsecs() { local d=$(( ($3 - $2) / 100000000 )); printf -v "$1" '%d.%d' $((d / 10)) $((d % 10)); }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) / 1e9 }'; }
T_BEGIN=$(now_ns)

# The boot slot: fd 9 stays open (and locked) in ycode-simd until it exits.
mkdir -p "$LOCKS"
take_slot() {
  local waited=0 i
  while :; do
    for i in $(seq 1 "$SLOTS"); do
      exec 9>>"$LOCKS/boot.$i"
      if flock -n 9; then
        echo "$(date +%T) slot boot.$i: ide-remote ycode-sim" >> "$LOCKS/history.txt"
        say "boot slot $i acquired after $(secs "$T_BEGIN" "$(now_ns)") s"
        return
      fi
      exec 9>&-
    done
    [ $waited = 0 ] && echo "ycode-sim: waiting for a free boot slot" >&2
    waited=1; sleep 10
  done
}

# Swift's crash handler: symbol lookup inside the crashing process (its
# default, "full") has itself crashed in its DWARF reader on ycode-simd, which
# left no stack at all. "off" records raw addresses and the image list,
# which symbolize_crash turns into symbols afterwards, in another process.
backtrace_settings() {
  echo "enable=yes,interactive=no,symbolicate=off,threads=all,images=all,registers=crashed,timeout=60s,output-to=$1"
}

# symbolize_crash REPORT: writes REPORT.sym.txt, the report with each frame's
# image offset, function and source line (llvm-symbolizer, then
# swift-demangle when there is one).
SYMBOLIZER='
import os, re, shutil, subprocess, sys
src = sys.argv[1]
text = open(src, errors="replace").read().splitlines()
images = []
for l in text:
    m = re.match(r"^(0x[0-9a-f]+)\S(0x[0-9a-f]+)\s+\S+\s+\S+\s+(/.*)$", l.strip())
    if m: images.append((int(m.group(1), 16), int(m.group(2), 16), m.group(3).strip()))
tool = shutil.which("llvm-symbolizer")
# swift-demangle: on the PATH, else in a swiftly installation (a login PATH
# may not reach it from a non-interactive ssh command)
dem = shutil.which("swift-demangle") or next((p for p in [os.path.expanduser("~/.local/share/swiftly/bin/swift-demangle")]
                                              if os.access(p, os.X_OK)), None)
frames, want = {}, {}
for i, l in enumerate(text):
    m = re.match(r"^\s*\d+\s+(\[[a-z]+\]\s+)?(0x[0-9a-f]+)\b", l)
    if not m: continue
    a = int(m.group(2), 16); ra = (m.group(1) or "").strip() == "[ra]"
    for (s, e, p) in images:
        if s <= a < e:
            off = a - s - (1 if ra else 0)
            frames[i] = (p, off); want.setdefault(p, set()).add(off); break
names = {}
for p, offs in want.items():
    if not tool: break
    offs = sorted(offs)
    try:
        out = subprocess.run([tool, "--obj=" + p, "--functions=linkage", "--no-inlines"] + ["0x%x" % o for o in offs],
                             capture_output=True, text=True, timeout=600).stdout
    except Exception:
        out = ""
    blocks = [b.strip().splitlines() for b in out.strip().split("\n\n")]
    for o, b in zip(offs, blocks):
        names[(p, o)] = (b[0] if b else "?", b[1] if len(b) > 1 else "")
if dem and names:
    keys = list(names)
    try:
        d = subprocess.run([dem, "--simplified"], input="\n".join(names[k][0] for k in keys) + "\n",
                           capture_output=True, text=True, timeout=120).stdout.splitlines()
        if len(d) == len(keys):
            for k, v in zip(keys, d): names[k] = (v, names[k][1])
    except Exception:
        pass
with open(src + ".sym.txt", "w") as f:
    for i, l in enumerate(text):
        if i in frames:
            p, o = frames[i]; fn, loc = names.get((p, o), ("?", ""))
            f.write("%s  %s+0x%x  %s  %s\n" % (l.rstrip(), os.path.basename(p), o, fn, loc))
        else:
            f.write(l + "\n")
'
symbolize_crash() {
  python3 -I -c "$SYMBOLIZER" "$1" </dev/null >/dev/null 2>&1 9>&- 8>&-
}

# keep_newest DIR PATTERN N: removes all but the N newest files DIR/PATTERN.
keep_newest() {
  local f
  ls -1t "$1"/$2 2>/dev/null | tail -n +$(($3 + 1)) | while IFS= read -r f; do
    case "$f" in "$1"/?*) rm -f -- "$f" ;; esac
  done
}

STATUS=1; RESULT=failed
# The arguments Ycode passed: the device, the runtime root, and the app
# options (which do not change what a snapshot holds).
DEV=""; RR=""; BASE_ARGS=(); prev=""; ERASE=0
for a in "$@"; do
  case "$prev" in
    --device) DEV=$a ;;
    --runtime-root) RR=$a ;;
  esac
  case "$prev" in
    --install-app|--launch|--app-arg|--app-env|--app-url) ;;
    *) case "$a" in --install-app|--launch|--app-arg|--app-env|--app-url) ;; --erase) ERASE=1 ;; *) BASE_ARGS+=("$a") ;; esac ;;
  esac
  prev=$a
done

cold_exec() {
  take_slot
  mkdir -p "$DATA/shots" "$DATA/crashes"
  [ -n "${SWIFT_BACKTRACE+x}" ] || export SWIFT_BACKTRACE="$(backtrace_settings "$DATA/crashes")"
  exec "$SIMD" "$@" "${HOST_ARGS[@]}" --screenshot "$DATA/shots/run.png" \
    --screenshot-at 180 --screenshot-at 300 --screenshot-at 420 --screenshot-at 540 --screenshot-at 660
}

if [ $ERASE = 1 ] && [ -z "$DEV" ]; then echo "ycode-sim: --erase needs --device" >&2; exit 64; fi
if [ $ERASE = 0 ]; then
  if [ "${YCODE_WARM_BOOT:-0}" != 1 ] || [ -z "$DEV" ]; then cold_exec "$@"; fi
  if ! grep -qa YCODE_SNAPSHOT_STOP_DIR "$SIMD"; then
    say "warm boot: this ycode-simd build cannot save the device at a stop; cold boot"
    cold_exec "$@"
  fi
  if ! python3 -I -c "import PIL" 2>/dev/null; then
    say "warm boot: python3 with PIL is needed to watch for the home screen; cold boot"
    cold_exec "$@"
  fi
fi

# ---- Warm boot -------------------------------------------------------------
# A closed ssh channel (Ycode's Stop closes it) must not end the launcher or
# ycode-simd while the device is being saved: writes to it fail instead.
trap '' PIPE
NAME=$(basename "$DEV")
SR=$DATA/snapshots/$NAME          # current/ (the snapshot), device-sync, device-ino, jobs.log
RUN=$DATA/runs/$NAME              # frames/, logs/, crashes/, log-restore.txt, log-cold.txt, home
KEEP=${YCODE_WARM_KEEP_LOGS:-10}
mkdir -p "$SR" "$RUN/frames" "$RUN/logs" "$RUN/crashes"
# The run log of earlier launchers was one file per mode, overwritten by
# every run: keep it with the others.
for m in restore cold; do
  [ -f "$RUN/log-$m.txt" ] && [ ! -L "$RUN/log-$m.txt" ] \
    && mv "$RUN/log-$m.txt" "$RUN/logs/$(date -r "$RUN/log-$m.txt" +%Y%m%d-%H%M%S)-$m.txt"
done
BT_OWN=0
[ -n "${SWIFT_BACKTRACE+x}" ] || { export SWIFT_BACKTRACE="$(backtrace_settings "$RUN/crashes")"; BT_OWN=1; }
# The launcher's own log grows by a few lines a run; start a new one past 1 MB.
[ "$(stat -c %s "$RUN/ycode-sim.log" 2>/dev/null || echo 0)" -gt 1048576 ] && mv "$RUN/ycode-sim.log" "$RUN/ycode-sim.log.1"

# Deletes a directory in the background after moving it out of the way (same
# file system, so the move is a rename). Only paths below the snapshot
# directory or next to the device directory are accepted.
discard() {
  local p=$1 t
  [ -e "$p" ] || return 0
  case "$p" in
    "$SR"/?*) t="$SR/trash.$(now_ns)" ;;
    */devices/?*) t="$(dirname "$p")/.trash-$(basename "$p").$(now_ns)" ;;
    *) say "not discarding $p (unexpected path)"; return 1 ;;
  esac
  mv -- "$p" "$t" || return 1
  setsid nohup rm -rf -- "${t:?}" </dev/null >/dev/null 2>&1 9>&- 8>&- &
}

# What a snapshot depends on: the simulator build, the runtime, the device
# path and the boot options (everything but the app options), lean boot.
fingerprint() {
  {
    echo "ycode-sim warm boot 2"
    printf '%s\n' "${BASE_ARGS[@]}" "${HOST_ARGS[@]}"
    env | grep -E '^YCODE_LEAN_BOOT' | sort
    stat -L -c '%n %s %Y' "$SIMD" "$Y/SimShim/out/shim.bin" "$Y/SimShim/out/host_stubs.bin" "$Y/Translator/build/ycode-airc" 2>&1
    find "$Y/SimHostLibs/out" "$Y/SimGuestFrameworks/out" -type f -printf '%p %s %T@\n' 2>/dev/null | sort
    stat -L -c '%n %s %Y' "$RR/System/Library/CoreServices/SystemVersion.plist" 2>&1
  } | sha256sum | cut -d' ' -f1
}

# The device lock (fd 8): held from here to the end of the run. ycode-simd
# inherits it, and the save after a stop takes it over, so the next run of
# this device (or an erase) waits until the device is no longer in use and
# its snapshot is saved. (A flock belongs to the open file description,
# which every inherited copy of fd 8 shares.)
exec 8>>"$SR/.lock"
if ! flock -n 8; then
  say "warm boot: waiting for the previous run of this device to end and its save to finish"
  flock 8
fi

if [ $ERASE = 1 ]; then
  discard "$SR/current"; rm -f "${SR:?}/device-sync" "${SR:?}/device-ino"
  discard "$DEV"
  say "erased $DEV"
  exit 0
fi
FP=$(fingerprint)

# A snapshot is used only when the device directory is exactly as the
# snapshot left it: the run that saved it ended right after the save, and no
# run has used the device since (device-sync holds the snapshot's id; every
# run removes it before it starts).
snapshot_problem() {
  local c=$SR/current id
  [ -f "$c/ycode-warm.stamp" ] || { echo "no snapshot yet"; return; }
  [ "$(sed -n 1p "$c/ycode-warm.stamp")" = "$FP" ] || { echo "the simulator build, the runtime or the boot options changed"; return; }
  [ -d "$DEV" ] || { echo "the device was erased"; return; }
  [ "$(stat -c %i "$DEV")" = "$(cat "$SR/device-ino" 2>/dev/null)" ] || { echo "the device directory was replaced"; return; }
  [ "$(head -n 1 "$c/device-path" 2>/dev/null)" = "$DEV" ] || { echo "the snapshot belongs to another device path"; return; }
  [ -f "$c/manifest.ysnap" ] && [ -f "$c/device-inodes" ] || { echo "the snapshot is incomplete"; return; }
  id=$(sed -n 3p "$c/ycode-warm.stamp")
  [ -n "$id" ] && [ "$(cat "$SR/device-sync" 2>/dev/null)" = "$id" ] \
    || { echo "the device changed since the snapshot (the last run ended without saving it)"; return; }
}
PROBLEM=$(snapshot_problem)
if [ -z "$PROBLEM" ] && [ "${YCODE_WARM_FORCE_COLD:-0}" = 1 ]; then PROBLEM="a cold boot was asked for"; fi
if [ -n "$PROBLEM" ] && [ -e "$SR/current" ]; then
  say "warm boot: discarding the snapshot ($PROBLEM)"
  discard "$SR/current"; rm -f "${SR:?}/device-sync"
fi
# The previous layout's spare device copy is no longer used.
rm -f "${SR:?}/spare.ok"; discard "$SR/spare"

# Background job (detached, low I/O priority, holding the device lock it
# inherits on fd 8): moves a saved snapshot into $SR/current with its stamp
# (fingerprint, time, id) and records that the device directory is in its
# state (device-sync = the id).
save_job() {
  local stage=$1 ino; ino=$(stat -c %i "$DEV")
  setsid nohup bash -c '
    stage=$1 SR=$2 FP=$3 ino=$4 id=$5 inc=$2/incoming.$(date +%s%N)
    t0=$(date +%s)
    if [ "${stage#$SR/}" != "$stage" ]; then mv "$stage" "$inc"; else ionice -c3 nice -n 19 cp -a "$stage" "$inc"; fi || exit 1
    printf "%s\n%s\n%s\n" "$FP" "captured $(date -Is)" "$id" > "$inc/ycode-warm.stamp"
    case "$SR" in */snapshots/?*) ;; *) exit 1 ;; esac
    [ -e "$SR/current" ] && mv "$SR/current" "$SR/trash.$(date +%s%N)"
    mv "$inc" "$SR/current" && echo "$ino" > "$SR/device-ino" && echo "$id" > "$SR/device-sync"
    case "$stage" in /run/user/[0-9]*/ycode-warm/?*) rm -rf -- "${stage:?}" ;; esac
    echo "$(date +%T) snapshot $id saved in $(( $(date +%s) - t0 )) s" >> "$SR/jobs.log"
    exec 8>&-
    for t in "$SR"/trash.*; do [ -e "$t" ] && ionice -c3 nice -n 19 rm -rf -- "${t:?}"; done
  ' save "$stage" "$SR" "$FP" "$ino" "$(basename "$stage")" </dev/null >>"$SR/jobs.log" 2>&1 9>&- &
}

# Watches the frames for the home screen: two frames in a row that are lit,
# i.e. less than 90 % of a 70 x 102 grey sample darker than 24 (a stale
# frame can flash once while the display comes back). The boot logo and a
# blank screen are about 99 % dark; the home screen is 0 % (light
# appearance) or about 7 % (dark appearance, whose wallpaper a mean
# brightness of 60 missed). Writes the first one's time (seconds after $2)
# into the file $3.
WATCHER='
import os, re, sys, time
from PIL import Image
fd, t0, out, pid, limit = sys.argv[1], int(sys.argv[2]) / 1e9, sys.argv[3], int(sys.argv[4]), float(sys.argv[5])
seen, prev = set(), None
def alive():
    try: os.kill(pid, 0); return True
    except OSError: return False
while alive() and time.time() - t0 < limit:
    for f in sorted(os.listdir(fd), key=lambda n: int(re.sub(r"\D", "", n) or 0)):
        m = re.match(r"^f-(\d+)s\.png$", f)
        if not m or f in seen: continue
        p = os.path.join(fd, f)
        try: im = Image.open(p).convert("L").resize((70, 102))
        except Exception: continue
        seen.add(f)
        t = os.path.getmtime(p) - t0
        if sum(im.histogram()[:24]) < 0.9 * 70 * 102:
            if prev is not None:
                open(out + ".tmp", "w").write("%.1f\n" % prev); os.rename(out + ".tmp", out); sys.exit(0)
            prev = t
        else:
            prev = None
    time.sleep(0.5)
'

# Stop (Ycode sends SIGINT to this pid): ycode-simd gets SIGTERM, ends the
# app, saves the device and exits (a background child of a script ignores
# SIGINT).
STOPPING=0; STOP_AT=0; CHILD=""; STOPPING_KILLED=0
forward() { if [ $STOPPING = 0 ]; then tick; STOP_AT=$NOW_NS; fi; STOPPING=1; [ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null; }
trap forward INT TERM HUP

# Whether Ycode asked for app steps (--install-app / --launch).
HAS_APP=0
for a in "$@"; do case "$a" in --install-app|--launch) HAS_APP=1 ;; esac; done
SETTLE_MS=${YCODE_WARM_SETTLE_MS:-60000}
APP_TIMEOUT=${YCODE_WARM_APP_TIMEOUT_S:-300}
STOP_TIMEOUT=${YCODE_WARM_STOP_TIMEOUT_S:-120}
LIVE_TIMEOUT=${YCODE_WARM_LIVE_TIMEOUT_S:-60}
FRAME_TIMEOUT=${YCODE_WARM_FRAME_TIMEOUT_S:-90}

# Where a stop saves the device: the RAM file system when it has room (a
# pause of seconds), else the data directory.
new_stage() {
  local ram=${YCODE_WARM_STAGE:-/run/user/$(id -u)}
  if [ "$ram" != none ] && [ -d "$ram" ] && [ "$(df --output=avail -B1G "$ram" | tail -n 1 | tr -d ' ')" -ge 6 ]; then
    echo "$ram/ycode-warm/$NAME.$(now_ns)"
  else
    echo "$SR/new.$(now_ns)"
  fi
}

# run_simd restore|cold: runs ycode-simd as a child (its output to Ycode and
# to $RUN/log-<mode>.txt), watches it, and sets STATUS, RESULT and SAVED:
# RESULT ok, stopped (Stop), failed (a restore without a home screen, or
# whose app steps did not finish), crashed (a restored run that ended by
# itself with a non-zero status); SAVED the directory of the save the stop
# wrote, or empty.
SAVED=""
run_simd() {
  local mode=$1; shift
  local envs=() at=() t stage launched=0 appfail=0 home="" home_s=0 deadline live=1 framed=1
  # Each run's log is kept (logs/<time>-<mode>.txt, the newest $KEEP);
  # log-<mode>.txt links to the latest of its mode.
  local log; log=$RUN/logs/$(date +%Y%m%d-%H%M%S)-$mode.txt
  find "$RUN/frames" -maxdepth 1 -name 'f-*s.png' -delete
  rm -f "${RUN:?}/home" "${RUN:?}/home.tmp" "${RUN:?}/settled"
  : > "$log"
  ln -sfn "logs/$(basename "$log")" "$RUN/log-$mode.txt"
  keep_newest "$RUN/logs" '*.txt' "$KEEP"
  local crashes_before; crashes_before=$(ls "$RUN/crashes" 2>/dev/null | grep -c '\.log$')
  SAVED=""
  stage=$(new_stage); mkdir -p "$(dirname "$stage")"
  # The device is about to change: the snapshot stops matching it until
  # this run saves a new one.
  rm -f "${SR:?}/device-sync"
  # After a stop's save ycode-simd closes fds 8 (the device lock: this
  # launcher keeps its own copy until the save job has it) and 9 (the boot
  # slot) and exits; its VMs' teardown (seconds) then holds nobody up.
  # A stop is saved only once the device has settled at its home screen
  # (snapshot.md §12.4: a save from the middle of a boot does not restore).
  # YCODE_EXIT_WITH_PARENT: should this launcher end without stopping
  # ycode-simd (killed, or a shell failure), ycode-simd gets SIGTERM.
  envs=(YCODE_EXIT_WITH_PARENT=1 YCODE_SNAPSHOT_STOP_DIR="$stage" YCODE_SNAPSHOT_DEADLINE_MS=15000 YCODE_SNAPSHOT_STOP_CLOSE_FDS=8,9
        YCODE_SNAPSHOT_STOP_REQUIRES="$RUN/settled")
  local settle=${YCODE_WARM_SAVE_SETTLE_S:-30}
  [ "$mode" = restore ] && settle=0
  # Builds that answer the liveness request say so after a restore.
  [ "$mode" = restore ] && grep -qa "restore: guest live" "$SIMD" && live=0
  [ "$mode" = restore ] && [ "$FRAME_TIMEOUT" -gt 0 ] && grep -qa "restore: first new frame" "$SIMD" && framed=0
  if [ "$mode" = restore ]; then
    envs+=(YCODE_RESTORE_DIR="$SR/current" YCODE_RESTORE_LAZY=1 YCODE_RESTORE_LENIENT=1)
    for ((t = 2; t <= 60; t += 2)); do at+=(--screenshot-at "$t"); done
    for ((t = 65; t <= 180; t += 5)); do at+=(--screenshot-at "$t"); done
    deadline=${YCODE_WARM_HOME_TIMEOUT_S:-120}
  else
    # The app steps wait for the settled home screen (a cold boot that
    # installs the app before SpringBoard runs does not reach the home
    # screen: snapshot.md §10.5).
    envs+=(YCODE_SNAPSHOT_WHEN_FILE="$RUN/home" YCODE_SNAPSHOT_DELAY_MS="$SETTLE_MS" YCODE_SNAPSHOT_HOLD_APPS=480)
    for ((t = 5; t <= 400; t += 5)); do at+=(--screenshot-at "$t"); done
    deadline=420
  fi
  tick; local t0=$NOW_NS
  env "${envs[@]}" "$SIMD" "$@" "${HOST_ARGS[@]}" --screenshot "$RUN/frames/f.png" "${at[@]}" > >(tee -p -a "$log") 2>&1 &
  CHILD=$!
  # A Stop that came before ycode-simd started reaches it now.
  [ $STOPPING = 1 ] && kill -TERM "$CHILD" 2>/dev/null
  python3 -I -c "$WATCHER" "$RUN/frames" "$t0" "$RUN/home" "$CHILD" "$deadline" </dev/null >/dev/null 2>&1 9>&- 8>&- &
  local watcher=$!
  while kill -0 "$CHILD" 2>/dev/null; do
    tick
    local elapsed=$(( (NOW_NS - t0) / 1000000000 ))
    if [ -z "$home" ] && [ -f "$RUN/home" ]; then
      read -r home < "$RUN/home"
      local hi=${home%%.*} hf=${home#*.} hb
      [ "$hf" = "$home" ] && hf=0
      # (whole seconds, rounded up, for the settle rule)
      home_s=$(( 10#$hi + 1 ))
      fsecs hb "$T_BEGIN" "$(( t0 + (10#$hi * 10 + 10#${hf:0:1}) * 100000000 ))"
      say "home screen at $home s after ycode-simd started ($hb s after this run began; $mode)"
    fi
    if [ $framed = 0 ] && grep -q "snapshot: restore: first new frame" "$log" 2>/dev/null; then
      framed=1; local fs; fsecs fs "$t0" "$NOW_NS"; note "first new frame $fs s after ycode-simd started"
    fi
    if [ $live = 0 ] && grep -q "snapshot: restore: guest live" "$log" 2>/dev/null; then
      live=1; local ls; fsecs ls "$t0" "$NOW_NS"; note "guest live $ls s after ycode-simd started"
    fi
    # A restore is saved at its stop only once its guest has shown that it
    # runs (a hung restore saved again would hang the next run too).
    if [ -n "$home" ] && [ ! -f "$RUN/settled" ] && [ $live = 1 ] && [ "$elapsed" -ge $(( home_s + settle )) ]; then
      touch "$RUN/settled"; note "the device has settled; a stop now saves it"
    fi
    if [ $launched = 0 ] && grep -q "ylaunch: launched " "$log" 2>/dev/null; then
      launched=1; local a1 a2; fsecs a1 "$t0" "$NOW_NS"; fsecs a2 "$T_BEGIN" "$NOW_NS"
      note "app running $a1 s after ycode-simd started ($a2 s after this run began; $mode)"
    fi
    if [ "$mode" = restore ] && [ $STOPPING = 0 ] && [ $appfail = 0 ]; then
      # A failed restore is killed (SIGTERM would save it).
      local why=""
      if [ -z "$home" ] && ! kill -0 "$watcher" 2>/dev/null && [ ! -f "$RUN/home" ]; then
        why="no home screen ${deadline} s after the restore"
      elif [ $live = 0 ] && [ "$elapsed" -ge "$LIVE_TIMEOUT" ]; then
        # The restored frame is lit from the start: only the guest's answer
        # says that it runs (snapshot.md §12.5).
        why="the restored guest did not answer ${LIVE_TIMEOUT} s after the restore"
      elif [ $framed = 0 ] && [ "$elapsed" -ge "$FRAME_TIMEOUT" ]; then
        # A UI that hangs keeps the restored frame (a status bar redraws at
        # least each minute, and the restore's clock change redraws it).
        why="the restored guest presented no new frame ${FRAME_TIMEOUT} s after the restore"
      elif [ $HAS_APP = 1 ] && [ $launched = 0 ] && [ "$elapsed" -ge "$APP_TIMEOUT" ]; then
        why="the app steps did not finish ${APP_TIMEOUT} s after the restore"
      fi
      if [ -n "$why" ]; then
        say "warm boot: $why"
        # Where every guest thread waits, into the run log, before the kill.
        kill -USR1 "$CHILD" 2>/dev/null
        local w=0; while [ $w -lt 10 ] && ! grep -q "ycode-simd: thread report on SIGUSR1" "$log" 2>/dev/null; do sleep 0.5; w=$((w + 1)); done
        sleep 3
        appfail=1; kill -KILL "$CHILD" 2>/dev/null
      fi
    fi
    # The stop's save is written: the guest no longer runs (the host
    # process is only ending), the run is over.
    if grep -q "snapshot: exiting after the snapshot" "$log" 2>/dev/null && [ -f "$stage/manifest.ysnap" ]; then
      SAVED=$stage; break
    fi
    if [ $STOPPING = 1 ] && [ $(( (NOW_NS - STOP_AT) / 1000000000 )) -ge "$STOP_TIMEOUT" ]; then
      note "stop: ycode-simd had not ended ${STOP_TIMEOUT} s after the stop; killed"
      if [ "$STOPPING_KILLED" = 0 ] && [ "$BT_OWN" = 1 ]; then
        # Where the host threads are, before the kill: a SIGSEGV sent with
        # kill makes Swift's handler write the report (all threads) and the
        # process goes on (snapshot.md §12.5).
        kill -SEGV "$CHILD" 2>/dev/null; sleep 5
      fi
      STOPPING_KILLED=1
      kill -KILL "$CHILD" 2>/dev/null
    fi
    sleep 0.5
  done
  if [ -n "$SAVED" ]; then
    STATUS=0
  else
    wait "$CHILD"; STATUS=$?
    # (A save whose exit came before the last check.)
    if [ $appfail = 0 ] && [ "$STATUS" = 0 ] && grep -q "snapshot: exiting after the snapshot" "$log" 2>/dev/null \
       && [ -f "$stage/manifest.ysnap" ]; then SAVED=$stage; fi
  fi
  CHILD=""
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  # A host crash: Swift's handler wrote a report into crashes/; symbolize
  # it and copy the crashing thread's frames into the run log.
  if [ "$STATUS" -ge 128 ] && [ "$(ls "$RUN/crashes" 2>/dev/null | grep -c '\.log$')" != "$crashes_before" ]; then
    local report; report=$(ls -1t "$RUN/crashes"/*.log | head -n 1)
    symbolize_crash "$report"
    say "ycode-simd crashed (status $STATUS); crash report $report$([ -f "$report.sym.txt" ] && echo " (symbolized: $report.sym.txt)")"
    { echo "---- crash report (crashing thread), $report"
      sed -n '/crashed:$/,/^$/p' "$report.sym.txt" 2>/dev/null | head -n 80; } >> "$log"
    keep_newest "$RUN/crashes" '*.log' "$KEEP"
    ls -1 "$RUN/crashes"/*.sym.txt 2>/dev/null | while IFS= read -r f; do [ -f "${f%.sym.txt}" ] || rm -f -- "$f"; done
  fi
  if [ -n "$SAVED" ]; then
    note "stop: the device was saved ($(grep -o 'total pause [0-9]* ms' "$log" | tail -n 1))$([ $STOPPING = 1 ] && echo ", $(secs "$STOP_AT" "$(now_ns)") s after the stop")"
  else
    case "$stage" in /run/user/[0-9]*/ycode-warm/?*) rm -rf -- "${stage:?}" ;; "$SR"/new.*) discard "$stage" ;; esac
  fi
  if [ $STOPPING = 1 ]; then RESULT=stopped
  elif [ "$mode" = restore ] && { [ $appfail = 1 ] || { [ -z "$home" ] && [ ! -f "$RUN/home" ]; }; }; then RESULT=failed
  elif [ "$mode" = restore ] && [ "$STATUS" != 0 ] && [ -z "$SAVED" ]; then RESULT=crashed
  else RESULT=ok; fi
}

drop_snapshot() { discard "$SR/current"; rm -f "${SR:?}/device-sync"; }

take_slot
if [ -z "$PROBLEM" ]; then
  say "warm boot: restoring the device from its snapshot ($(sed -n 2p "$SR/current/ycode-warm.stamp"))"
  run_simd restore "$@"
  if [ "$RESULT" = failed ]; then
    say "warm boot: the restore failed (ycode-simd status $STATUS); discarding the snapshot and booting cold"
    drop_snapshot
    run_simd cold "$@"
  elif [ "$RESULT" = crashed ]; then
    say "warm boot: ycode-simd ended with status $STATUS after a restore; the snapshot is discarded"
    drop_snapshot
  fi
else
  say "warm boot: $PROBLEM; cold boot"
  run_simd cold "$@"
fi
if [ -n "$SAVED" ]; then
  # The save job takes the device lock over (fd 8 is inherited).
  save_job "$SAVED"
  say "warm boot: the device was saved; the next run continues from it"
else
  say "warm boot: the device was not saved; the next run boots it cold (its data stays)"
fi
exec 8>&-
exit "$STATUS"
