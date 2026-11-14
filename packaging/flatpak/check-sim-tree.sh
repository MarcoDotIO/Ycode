#!/bin/sh
# Smoke check of the aarch64 release's simulator tree on a plain host
# (docs/SIMULATOR-UX.md §8, docs/RELEASING.md): unpacks the tarball into a
# fresh folder and runs its simulator programs with nothing from a build
# environment, the way docs/SIMULATOR-LINUX.md §5.1 installs them:
#
#   1. layout: ycode-simhost, ycode-simd, ycode-airc, the shim, the libraries, the guest tools
#   2. every simulator program and library loads with this system's C library
#   3. ycode-airc translates a kernel (selftest), ycode-simd's JPEG and zlib encode (--check-encoders)
#   4. ycode-simhost: check, serve on a test port, identity, pair (§1.4, §2.1 host side)
#   5. with --runtime-root and /dev/kvm: a device boots from the tree, its display
#      streams JPEG frames with tiles, a screenshot and Home work, and it stops (§4.4, §5)
#
# Usage: packaging/flatpak/check-sim-tree.sh <Ycode-<version>-aarch64.tar.xz | unpacked folder>
#            [--runtime-root DIR] [--device-type ID] [--port N] [--work DIR] [--keep]
#   --port N      ycode-simhost's control port (N+1 for media); default 48790
#   --work DIR    where to unpack and keep the device (default: a new folder in $TMPDIR)
#   --keep        leave the work folder
# Exit status 0 when every check passed, 1 otherwise. Needs only sh, tar, xz,
# ldd and python3 (for the display probe in step 5).
set -u
here=$(cd "$(dirname "$0")" && pwd)
probe=$here/../../ycode/scripts/ycode-display-probe

input=""
runtime=""
devtype=""
port=48790
work=""
keep=0
while [ $# -gt 0 ]; do
    case "$1" in
        --runtime-root) runtime=$2; shift ;;
        --device-type) devtype=$2; shift ;;
        --port) port=$2; shift ;;
        --work) work=$2; shift ;;
        --keep) keep=1 ;;
        -*) echo "check-sim-tree: unknown option $1" >&2; exit 64 ;;
        *) input=$1 ;;
    esac
    shift
done
[ -n "$input" ] || { echo "usage: check-sim-tree.sh <tarball|folder> [--runtime-root DIR] [--port N] [--work DIR] [--keep]" >&2; exit 64; }

if [ -z "$work" ]; then
    work=$(mktemp -d "${TMPDIR:-/tmp}/ycode-sim-tree-check.XXXXXX")
else
    mkdir -p "$work"
    work=$(cd "$work" && pwd)
fi
serve_pid=""
device_pid=""
cleanup() {
    [ -n "$device_pid" ] && kill "$device_pid" 2>/dev/null
    [ -n "$serve_pid" ] && kill "$serve_pid" 2>/dev/null
    [ -n "$device_pid" ] && wait "$device_pid" 2>/dev/null
    [ -n "$serve_pid" ] && wait "$serve_pid" 2>/dev/null
    if [ "$keep" = 1 ]; then echo "work folder kept: $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT
trap 'exit 1' INT TERM

passed=0
failed=0
pass() { passed=$((passed + 1)); echo "PASS $*"; }
fail() { failed=$((failed + 1)); echo "FAIL $*"; }

# Nothing from the caller's environment: a fresh home, the system's PATH.
home=$work/home
mkdir -p "$home"
clean() { env -i HOME="$home" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 "$@"; }
# For a program in the background, as `(clean_exec ...) &`: the subshell
# becomes the program, so $! is its PID (with `clean ... &` it was the
# subshell's, and stopping that left the program running).
clean_exec() { exec env -i HOME="$home" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 "$@"; }

# 1. Unpack.
if [ -d "$input" ]; then
    top=$(cd "$input" && pwd)
else
    mkdir -p "$work/tree"
    if ! tar -xJf "$input" -C "$work/tree"; then fail "unpack $input"; exit 1; fi
    top=$(find "$work/tree" -mindepth 1 -maxdepth 1 -type d | head -n 1)
fi
sim=$top/lib/ycode-sim
echo "tree: $top"

for f in bin/ycode-simhost bin/ycode-sim lib/ycode-sim/.build/release/ycode-simd lib/ycode-sim/.build/release/ycode-airc \
         lib/ycode-sim/airc/ycode-airc lib/ycode-sim/scripts/ycode-sim.sh; do
    if [ -x "$top/$f" ]; then pass "layout: $f"; else fail "layout: $f is missing or not executable"; fi
done
for f in lib/ycode-sim/SimShim/out/shim.bin lib/ycode-sim/SimHostLibs/out lib/ycode-sim/SimGuestFrameworks/out; do
    if [ -e "$top/$f" ]; then pass "layout: $f"; else fail "layout: $f is missing"; fi
done
macho() { [ "$(od -A n -t x1 -N 4 "$1" 2>/dev/null | tr -d ' \n')" = cffaedfe ]; }
tools=$sim/SimShim/out/guest-tests/stage7
for f in ylaunch ycode-settings-agent ycode-pairing-agent libYcodeEnvironmentOverrides.dylib libYcodeGauge.dylib; do
    if [ -s "$tools/$f" ] && macho "$tools/$f"; then pass "guest tools: $f"; else fail "guest tools: $f is missing or not an arm64 Mach-O image ($tools)"; fi
done

# 2. Every simulator program and the libraries they load (ldd follows the
# whole closure), and libjpeg, which ycode-simd loads at run time.
jpeglib=$(cd "$top" && ls lib/libjpeg.so.* 2>/dev/null | head -n 1)
for f in bin/ycode-simhost lib/ycode-sim/.build/release/ycode-simd "${jpeglib:-lib/libjpeg.so.N}"; do
    [ -e "$top/$f" ] || { fail "loads: $f is missing"; continue; }
    out=$(clean ldd "$top/$f" 2>&1)
    if printf '%s\n' "$out" | grep -E 'not found|version .* not found|No such file' >/dev/null; then
        fail "loads: $f: $(printf '%s\n' "$out" | grep -E 'not found|No such file' | head -n 3 | tr '\n' ' ')"
    else
        pass "loads: $f"
    fi
done

# 3. The programs start and do their work here.
for f in bin/ycode-simhost lib/ycode-sim/.build/release/ycode-simd lib/ycode-sim/.build/release/ycode-airc; do
    if out=$(clean "$top/$f" --version 2>&1); then pass "starts: $f ($out)"; else fail "starts: $f: $(printf '%s' "$out" | head -n 2 | tr '\n' ' ')"; fi
done
if out=$(clean "$sim/.build/release/ycode-airc" selftest 2>&1); then pass "translator: $out"; else fail "translator: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"; fi
out=$(clean "$sim/.build/release/ycode-simd" --check-encoders 2>&1)
status=$?
printf '%s\n' "$out" | sed 's/^/    /'
if printf '%s\n' "$out" | grep -q '^jpeg: ok'; then pass "display stream: JPEG encodes and decodes"; else fail "display stream: no working JPEG encoder"; fi
if printf '%s\n' "$out" | grep -q '^zlib: ok'; then pass "display stream: zlib"; else fail "display stream: no zlib"; fi
[ "$status" = 0 ] || fail "ycode-simd --check-encoders exited $status"

# 4. ycode-simhost as Apply sets it up (SIMULATOR-LINUX.md §5.1), on test ports.
data=$work/data
mkdir -p "$data/home" "$home/.config/ycode"
rt=$runtime
if [ -z "$rt" ]; then
    # check and serve need a runtime path; a stand-in when none was given (nothing boots).
    rt=$work/stand-in-runtime
    mkdir -p "$rt/sbin"
    : > "$rt/sbin/launchd_sim"
fi
config=$work/simhost.env
cat > "$config" <<EOF
YCODE_SIM_HOME=$data/home
YCODE_SIM_TREE=$sim
YCODE_SIM_RUNTIME=$rt
YCODE_SIM_LAUNCHER=$top/bin/ycode-sim
YCODE_SIM_DATA=$data
YCODE_SIMHOST_LISTEN=127.0.0.1:$port
YCODE_SIMHOST_MEDIA_PORT=$((port + 1))
YCODE_SIMHOST_NAME=sim-tree-check
EOF
if out=$(clean "$top/bin/ycode-simhost" check --config "$config" 2>&1); then
    pass "ycode-simhost check: $(printf '%s' "$out" | head -n 1 | cut -c1-160)"
    if printf '%s\n' "$out" | grep -q 'no guest tools'; then fail "ycode-simhost check: $(printf '%s\n' "$out" | grep 'no guest tools' | cut -c1-200)"; fi
else
    fail "ycode-simhost check: $(printf '%s' "$out" | head -n 4 | tr '\n' ' ')"
fi
(clean_exec "$top/bin/ycode-simhost" serve --config "$config") > "$work/simhost.log" 2>&1 &
serve_pid=$!
up=0
for _ in $(seq 1 50); do
    if grep -q "$port" "$work/simhost.log" 2>/dev/null && kill -0 "$serve_pid" 2>/dev/null; then up=1; break; fi
    kill -0 "$serve_pid" 2>/dev/null || break
    sleep 0.2
done
if [ $up = 1 ]; then pass "ycode-simhost serve: listening on 127.0.0.1:$port"; else fail "ycode-simhost serve: $(tail -n 3 "$work/simhost.log" | tr '\n' ' ')"; fi
if out=$(clean "$top/bin/ycode-simhost" identity --name sim-tree-check 2>&1) && printf '%s' "$out" | grep -q publicKey; then
    pass "ycode-simhost identity"
else
    fail "ycode-simhost identity: $(printf '%s' "$out" | head -n 2 | tr '\n' ' ')"
fi
if out=$(clean "$top/bin/ycode-simhost" pair --config "$config" 2>&1) && printf '%s' "$out" | grep -q 'ycode sim remote pair'; then
    pass "ycode-simhost pair: a pairing window opened"
else
    fail "ycode-simhost pair: $(printf '%s' "$out" | head -n 2 | tr '\n' ' ')"
fi
kill "$serve_pid" 2>/dev/null
wait "$serve_pid" 2>/dev/null
if kill -0 "$serve_pid" 2>/dev/null; then fail "ycode-simhost serve: still running after its stop"; else pass "ycode-simhost serve: stopped"; fi
serve_pid=""

# 5. A device from the tree, when this machine can run one.
# The share of a screenshot's pixels that are dark (the display server's PNG:
# 8-bit RGBA, filter 0 on every row; display-stream.md §4.4).
dark_fraction='
import struct, sys, zlib
d = open(sys.argv[1], "rb").read()
w, h = struct.unpack(">II", d[16:24])
i, idat = 8, b""
while i < len(d):
    n, t = struct.unpack(">I4s", d[i:i + 8])
    if t == b"IDAT": idat += d[i + 8:i + 8 + n]
    i += 12 + n
raw = zlib.decompress(idat)
stride, dark, total = 1 + w * 4, 0, 0
for y in range(0, h, 8):
    row = raw[y * stride + 1:(y + 1) * stride]
    for x in range(0, w * 4, 32):
        total += 1
        dark += row[x] + row[x + 1] + row[x + 2] < 60
print("%.3f" % (dark / max(total, 1)))
'

if [ -z "$runtime" ]; then
    echo "SKIP device: no --runtime-root"
elif [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "SKIP device: /dev/kvm is not usable here"
elif ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP device: no python3 for the display probe"
else
    dev=$data/devices/check-device
    sock=$data/check-device.display.sock
    mkdir -p "$data/devices"
    set -- --device "$dev" --runtime-root "$runtime" --display-server "unix:$sock"
    [ -n "$devtype" ] && set -- "$@" --device-type "$devtype"
    (clean_exec YCODE_SIM_DATA="$data" "$top/bin/ycode-sim" "$@") > "$work/device.log" 2>&1 &
    device_pid=$!
    t0=$(date +%s)
    while [ ! -S "$sock" ] && kill -0 "$device_pid" 2>/dev/null && [ $(($(date +%s) - t0)) -lt 120 ]; do sleep 1; done
    if [ -S "$sock" ]; then
        pass "device: its display server is up ($(($(date +%s) - t0)) s)"
        # The home screen: a screenshot that is mostly lit (the boot screen is
        # almost all dark). A first boot of an empty device takes minutes.
        home=0
        while kill -0 "$device_pid" 2>/dev/null && [ $(($(date +%s) - t0)) -lt 900 ]; do
            python3 -I "$probe" --connect "unix:$sock" --encoding zlib live shot "$work/boot.png" > /dev/null 2>&1
            dark=$(python3 -I -c "$dark_fraction" "$work/boot.png" 2>/dev/null || echo 1)
            if [ -s "$work/boot.png" ] && awk -v f="$dark" 'BEGIN { exit !(f < 0.5) }'; then home=1; break; fi
            sleep 10
        done
        if [ $home = 1 ]; then pass "device: the home screen is up ($(($(date +%s) - t0)) s)"; else fail "device: no home screen after $(($(date +%s) - t0)) s"; fi
        python3 -I "$probe" --connect "unix:$sock" --encoding jpeg --json "$work/frames.json" \
            live wait 3 shot "$work/home.png" button home wait 3 > "$work/probe.log" 2>&1
        sed 's/^/    /' "$work/probe.log" | tail -n 12
        frames=$(grep -c '"frame"' "$work/frames.json" 2>/dev/null)
        frames=${frames:-0}
        empty=$(grep '"frame"' "$work/frames.json" 2>/dev/null | grep -c '"tiles": 0[,}]')
        jpeg=$(grep -c '"encoding": "jpeg"' "$work/frames.json" 2>/dev/null)
        if [ "$frames" -gt 0 ] && [ "$empty" = 0 ]; then pass "device: $frames frames, every one with tiles"; else fail "device: $frames frames, $empty without tiles"; fi
        if [ "${jpeg:-0}" -gt 0 ]; then pass "device: the stream is JPEG ($jpeg frames)"; else fail "device: no JPEG frames (see the notices above)"; fi
        if [ -s "$work/home.png" ]; then pass "device: screenshot ($(wc -c < "$work/home.png") bytes)"; else fail "device: no screenshot"; fi
    else
        fail "device: no display server after 120 s: $(tail -n 5 "$work/device.log" | tr '\n' ' ')"
    fi
    kill "$device_pid" 2>/dev/null
    t1=$(date +%s)
    while kill -0 "$device_pid" 2>/dev/null && [ $(($(date +%s) - t1)) -lt 60 ]; do sleep 1; done
    if kill -0 "$device_pid" 2>/dev/null; then fail "device: still running 60 s after the stop"; kill -9 "$device_pid" 2>/dev/null; else pass "device: stopped ($(($(date +%s) - t1)) s)"; fi
    wait "$device_pid" 2>/dev/null
    device_pid=""
fi

echo "check-sim-tree: $passed passed, $failed failed"
[ "$failed" = 0 ]
