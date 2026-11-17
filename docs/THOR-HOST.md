# Runbook: the arm64 Linux simulator host

How the project's arm64 Linux simulator host ("the Thor": an NVIDIA Jetson
Thor, Ubuntu 24.04 aarch64, KVM) is set up: where the data lives, the
always-on simulator service, the pristine devices, and pairing a client.
The same steps work on any arm64 Linux host with `/dev/kvm`.

Placeholders: `<host>` is the simulator host's address, `<user>` the account
the service runs as, `<client>` the client's address. Real names, addresses
and paths stay out of the repository (keep them in your local notes).

## 1. Data layout

Everything large lives under one folder, `$YCODE_DATA` in specs and
scripts. On the Thor it is `~/ycode-data` on the system disk (NVMe; the
earlier separate USB data drive is gone, 2026-11-17). Budget about 120 GB:
four runtimes (about 19 GB each for iOS), the pristine devices (a few GB
each), the service's devices with their saved state (about 3 GB of
snapshot per device), and the GPU cache.

| Path | Holds | Who writes it |
|---|---|---|
| `$YCODE_DATA/runtimes/<platform>-<version>-<build>/RuntimeRoot` | the simulator runtimes (iOS 27.1 24A94401, iOS 27.0 24A434, watchOS 27.0 24R362, xrOS 27.0 24M362), copied from a Mac's own Xcode installation | the owner or the runtime wizard; **read-only** for everyone else |
| `$YCODE_DATA/devices/pristine/<device type>` | one first-booted, cleanly shut-down device per type: the template (§3) | `ycode-sim-pristine make` only |
| `$YCODE_DATA/devices/pristine/<device type>.timing` | its first-boot and copy-boot timings | `ycode-sim-pristine` |
| `$YCODE_DATA/pristine-runs/` | the launcher's logs and frames of those boots | `ycode-sim-pristine` |
| `$YCODE_DATA/simhost/` | the service's home (`YCODE_SIM_HOME`): `devices/<name>` with `<name>.json`, `run/<name>.sock` and `.log`, `apps/`, `snapshots/<name>` (warm boot), `runs/<name>` | `ycode-simhost` |
| `$YCODE_DATA/locks/` | the shared boot-slot locks (`boot.N`, `flock`) | every launcher on the host |
| `$YCODE_DATA/gpu-cache/` | the shader cache (content-keyed, shared by runtimes) | every launcher on the host |

The service's code is in its own stable folder, outside any agent's area:

| Path | Holds |
|---|---|
| `~/ycode-service/src/` | the source tree, copied from a main-line commit (`rsync`, no `.git`, no `research/`) |
| `~/ycode-service/src/ycode/.build/release/` | `ycode-simd`, `ycode-simhost`, `ycode` (release builds) |
| `~/ycode-service/guest-tools/` | `ylaunch` and the guest agents, built on a Mac (`packaging/flatpak/build-guest-tools.sh <dir>`) |
| `~/ycode-service/simhost.env` | the service's configuration (§2.2) |
| `~/ycode-service/build.sh` | the build of §2.1 |
| `~/.config/ycode/sim-link/` | the host's link identity (`identity.key`) and trusted clients (`trusted-peers.json`); mode 0700, files 0600; never copy, print or regenerate them |

## 2. The simulator service

### 2.1 Build

The host needs `/dev/kvm` (§2.3), a Vulkan driver, Swift 6.4 through
swiftly, LLVM 18 with `clang-18`, `cmake`, `ninja`, SPIRV-Tools, and
`python3` with PIL (the launcher's home-screen watch). The guest tools are
iOS- and watchOS-simulator programs of our own, so they build on a Mac with
the simulator SDKs.

On a Mac, from the repository root:

```sh
packaging/flatpak/build-guest-tools.sh /tmp/guest-tools
rsync -az --delete --exclude .build --exclude .build-ide --exclude .git --exclude research \
  --exclude .claude ./ <user>@<host>:ycode-service/src/
rsync -az /tmp/guest-tools/ <user>@<host>:ycode-service/guest-tools/
```

On the host (`~/ycode-service/build.sh`; limit jobs on a shared host):

```sh
. ~/.local/share/swiftly/env.sh
cd ~/ycode-service/src/ycode
swift build -c release -j 6 --product ycode-simd
swift build -c release -j 6 --product ycode-simhost
swift build -c release -j 6 --product ycode
sh SimShim/build.sh
YCODE=$PWD/.build/release/ycode sh SimHostLibs/build.sh
sh SimGuestFrameworks/build.sh
sh Translator/build.sh
```

What the steps make, and what `ycode-simd` and the launcher read (other
agents on the host may point at this tree read-only instead of building
their own: `YCODE_SIM_TREE=<home>/ycode-service/src/ycode`,
`YCODE_SIM_GUEST_TOOLS=<home>/ycode-service/guest-tools`):

| Step | Output under `src/ycode/` | Used as |
|---|---|---|
| `swift build` | `.build/release/ycode-simd`, `ycode-simhost`, `ycode` | the VMM, the service, the host-library build's tool |
| `SimShim/build.sh` | `SimShim/out/shim.bin`, `host_stubs.bin` | `--shim`, `--host-stubs` (the EL1 shim) |
| `SimHostLibs/build.sh` | `SimHostLibs/out/libsystem_kernel.dylib`, `libsystem_platform.dylib`, `libsystem_pthread.dylib` | `--host-libs` (`specs/simulator/host-libraries.md`); without them every guest process stops with "Library not loaded: /usr/lib/system/libsystem_platform.dylib" |
| `SimGuestFrameworks/build.sh` | `SimGuestFrameworks/out/SimHID.framework`, `SimFramebuffer.framework` | staged into each device |
| `Translator/build.sh` | `Translator/build/ycode-airc` | `--metal-translator` |
| `build-guest-tools.sh` (Mac) | `~/ycode-service/guest-tools/`: `ylaunch`, the settings, pairing (iOS and `watchos/`), Environment Overrides, Gauge, camera and health agents, `MANIFEST.txt` | `--guest-tools` (app install and launch) |

The launcher (`scripts/ycode-sim.sh`) passes all of these to `ycode-simd`
from `YCODE_SIM_TREE` and `YCODE_SIM_GUEST_TOOLS`. On the Thor the whole
build took 20 minutes (`-j 6`, the `ycode` product 12 of them).

A rebuild with the service running: build, then
`systemctl --user restart ycode-simhost` (running devices are saved first).
A new simulator build boots every device cold once (the warm-boot
fingerprint changes), then restores again.

### 2.2 Configuration

`~/ycode-service/simhost.env` (keys of `specs/simulator/sim-link.md` §9):

```sh
YCODE_SIM_HOME=<data>/simhost
YCODE_SIM_TREE=<home>/ycode-service/src/ycode
YCODE_SIM_LAUNCHER=<home>/ycode-service/src/ycode/scripts/ycode-sim.sh
YCODE_SIM_GUEST_TOOLS=<home>/ycode-service/guest-tools
YCODE_SIM_RUNTIME=<data>/runtimes/iOS-27.1-24A94401/RuntimeRoot
YCODE_SIM_LOCKS=<data>/locks
YCODE_SIM_GPU_CACHE=<data>/gpu-cache
YCODE_SIM_SLOTS=4
YCODE_SIM_HOURS=12
YCODE_SIMHOST_LISTEN=0.0.0.0:47800
YCODE_SIMHOST_MEDIA_PORT=47801
YCODE_SIMHOST_NAME=thor
# one line per pristine template (§3):
YCODE_SIM_PRISTINE=<data>/devices/pristine/iphone-duo
YCODE_SIM_PRISTINE_IPAD_A16=<data>/devices/pristine/ipad-a16
YCODE_SIM_PRISTINE_APPLE_WATCH_SERIES_12_46MM=<data>/devices/pristine/apple-watch-series-12-46mm
YCODE_SIM_RUNTIME_APPLE_WATCH_SERIES_12_46MM=<data>/runtimes/watchOS-27.0-24R362/RuntimeRoot
YCODE_SIM_PRISTINE_VISION_PRO=<data>/devices/pristine/vision-pro
YCODE_SIM_RUNTIME_VISION_PRO=<data>/runtimes/xrOS-27.0-24M362/RuntimeRoot
```

Add a `YCODE_SIM_PRISTINE_<TYPE>` line only once that template exists: the
service copies the named folder when a client creates a device of that type.
`ycode-simhost check --config ~/ycode-service/simhost.env` checks the file,
the tree and the ports without booting anything.

### 2.3 The unit

`~/.config/systemd/user/ycode-simhost.service`:

```ini
[Unit]
Description=Ycode simulator host service (ycode-simhost: 47800/tcp control, 47801/udp media)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=%h/ycode-service/src/ycode/.build/release/ycode-simhost check --config %h/ycode-service/simhost.env
ExecStart=%h/ycode-service/src/ycode/.build/release/ycode-simhost serve --config %h/ycode-service/simhost.env
# SIGTERM to ycode-simhost only: it stops (saves) every device, then exits.
# Nothing else is killed: each launcher's background save job (snapshot.md
# §12.2 rule 5) moves the save into place after its launcher has exited.
KillMode=process
# The VMM puts its threads in cpu-weighted threaded child cgroups (scheduling-policy.md §4.7).
Delegate=yes
TimeoutStopSec=300
Restart=on-failure
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now ycode-simhost
systemctl --user status ycode-simhost
journalctl --user -u ycode-simhost -f
```

`KillMode=process` matters: with the default, systemd would send SIGTERM to
the launchers and `ycode-simd` too, and a second signal makes `ycode-simd`
exit without saving; with `mixed`, systemd kills what is left in the unit's
cgroup once `ycode-simhost` has exited, and that includes each launcher's
background save job, which moves the save into place after the launcher
exits (`specs/simulator/snapshot.md` §12.2 rule 5): the device then boots
cold next time ("the last run ended without saving it"). The service stops
each device with SIGTERM to its launcher (up to 150 s each), so the stop
timeout is generous. `Delegate=yes` matters
too: without the cpu controller in the unit's cgroup, `ycode-simd`'s host
scheduling backend logs "host none: cannot enable cpu in …" and runs without
its class weights (`specs/simulator/scheduling-policy.md` §4.7); with it the
log says "host cgroup …/ycode-simhost.service".

**Without a login session.** A user manager runs only while the user is
logged in, unless lingering is on: `loginctl show-user <user> -p Linger`
must say `yes` (the owner turns it on with `sudo loginctl enable-linger
<user>`). It is on for the Thor's account.

**KVM access.** The account needs read-write access to `/dev/kvm`:
membership of the `kvm` group (`sudo usermod -aG kvm <user>`; persistent),
or the seat ACL that logind gives the user logged in at the console (lost
when nobody is). The user manager keeps the groups it started with: after a
group change, restart it (`sudo systemctl restart user@<uid>.service`, which
ends the user's other sessions, or reboot). `systemctl --user show-environment`
does not show groups; check with
`cat /proc/$(systemctl --user show -p MainPID --value ycode-simhost)/status | grep Groups`
against `getent group kvm`.

### 2.4 Ports and firewall

47800/tcp (control and display) and 47801/udp (media), from the client's
address only (owner, once: `sudo ufw allow from <client> to any port 47800
proto tcp`, the same for `47801 proto udp`). Other agents' services on the
host use 47820 and up; keep 47800–47801 for this service.

## 3. The pristine devices

A new device's first boot runs the data migration and seeds the
LaunchServices store (`specs/simulator/first-boot.md`): minutes. A copy of
a device that has done that once skips both, and keeps its guest path, so it
needs no store rebuild (`specs/simulator/app-launch.md` §3.3). The service
makes each new device as such a copy, and the device's later boots restore
its saved state (warm boot, `specs/simulator/snapshot.md` §12): seconds.

`ycode/scripts/ycode-sim-pristine` (environment: `YCODE_DATA`,
`YCODE_SIM_TREE`, `YCODE_SIM_GUEST_TOOLS`):

```sh
export YCODE_DATA=<data> YCODE_SIM_TREE=<home>/ycode-service/src/ycode YCODE_SIM_GUEST_TOOLS=<home>/ycode-service/guest-tools
P=$YCODE_SIM_TREE/scripts/ycode-sim-pristine
R=$YCODE_DATA/runtimes
$P make iphone-duo --runtime-root $R/iOS-27.1-24A94401/RuntimeRoot
$P make ipad-a16 --runtime-root $R/iOS-27.1-24A94401/RuntimeRoot
$P make apple-watch-series-12-46mm --runtime-root $R/watchOS-27.0-24R362/RuntimeRoot
$P make vision-pro --runtime-root $R/xrOS-27.0-24M362/RuntimeRoot
$P try iphone-duo --runtime-root $R/iOS-27.1-24A94401/RuntimeRoot   # time a boot of a copy
$P copy iphone-duo <new device directory>                           # a working copy
$P list
```

`make` boots `$YCODE_DATA/devices/pristine/<type>` through the launcher
until the home screen shows and the migration marker and the LaunchServices
store are written, waits 90 s more, and shuts the guest down cleanly (the
launcher's save is held back, so the template has no snapshot). Rebuild a
template with `make <type> --force` (the old one is moved aside) after a new
runtime build; a simulator build alone does not need it. Then run
`systemctl --user restart ycode-simhost` only if you added a line to
`simhost.env`.

The copy is `cp -a --reflink=auto`: ext4 has no reflinks, so it is a full
copy (seconds); on XFS or btrfs it shares blocks. The template must stay
unchanged: boot copies, never the template.

### 3.1 Measured (2026-11-17, the Thor, main line 45a0f646)

Load 13–34 from other agents' boots throughout. "Home" is the launcher's
home-screen watch (seconds after `ycode-simd` started); a copy boot is a
cold boot of a fresh copy of the template.

| Device type (runtime) | Template size | First boot: home | Copy | Copy boot: home |
|---|---|---|---|---|
| `iphone-duo` (iOS 27.1 24A94401) | 867 MB | 82.5 s | 0.9 s | 35.7 s |
| `ipad-a16` (iOS 27.1 24A94401) | 1.3 GB | 95.6 s | 1.1 s | 35.9 s |
| `apple-watch-series-12-46mm` (watchOS 27.0 24R362) | 1.1 GB | 45.3 s | 0.7 s | 30.4 s |
| `vision-pro` (xrOS 27.0 24M362) | 1.8 GB | 65.6 s | 1.2 s | 30.6 s |

Through the service: a device created from the iPhone template booted cold
to its home screen in 27–46 s; after a saved stop it restores in place to
its home screen in 6.9–9.2 s (also across a restart of the unit), and a Run
from the Linux IDE (stop and save, restore, install, launch) had the app
running 10.1 s after `ycode-simd` started.

## 4. Pairing a client

The host's identity is in `~/.config/ycode/sim-link/identity.key`. Keep it:
regenerating it makes every client distrust the host.

One-time code (the host's `ycode-simhost` and the client's `ycode` from the
same main line):

```sh
# on the host (prints a code, valid 5 minutes, one attempt):
~/ycode-service/src/ycode/.build/release/ycode-simhost pair
# on the client:
ycode sim remote pair <host>:47800 <code> --name thor --media-port 47801
ycode sim remote devices
```

`--name` is the name the client keeps for the host (the IDE shows it in its
destinations, "<device> (thor)"); the host keeps the client under the
client's own host name. Pairing writes the host into the client's
`~/.config/ycode/sim-link/trusted-peers.json` and the client into the host's. The running service reads the host's file
on each connection; no restart. Re-pairing replaces the entry of the same
name. To remove a client: `ycode-simhost untrust <name>`. A client that
already trusted the host's key keeps working after a rebuild or a reboot of
the host.

## 5. Checks from a client

```sh
ycode sim remote devices                       # lists the host's devices
ycode sim remote create iPhone --type iphone-duo   # a copy of the pristine iPhone
ycode sim remote boot iPhone
ycode-sim-viewer --link iPhone --timing --measure /tmp/m.tsv --script bench.txt
ycode sim remote run iPhone MyApp.app          # upload, install, launch, view
ycode sim remote shutdown iPhone               # saves it; the next boot restores
```

Latency is measured as in `specs/simulator/display-stream.md` §16: the
viewer's `--timing --measure` gives each frame's stages on the client's
clock; "record seen → presented" is the figure (about 10 ms p50 on the LAN).
On 2026-11-17 (x86 PC on the same subnet, the viewer on the desktop's X
server through Xwayland, renderer Vulkan, media by UDP, the REMOTE-X86
workload: 8 page swipes, 2 Search taps, 2 Home presses): JPEG 8.2 / 15.3 ms
(p50 / p90), H.264 12.7 / 16.1 ms; round trip 0.43 ms. The A/V probe
(Samples/StreamSamples AVSync): 408 Opus packets, none late.

The viewer's SDL needs a display it supports: the project's SDL 3 build has
no Wayland back end, so on a GNOME Wayland desktop use its Xwayland display
(`DISPLAY=:0` with `XAUTHORITY` set to the session's
`/run/user/<uid>/.mutter-Xwaylandauth.*`).

## 6. After a lost data folder

Nothing unique lives on the host: code and measurements are in git and the
specs, and the link identity is in the home folder. To rebuild: copy the
runtimes back (§1), build (§2.1), write `simhost.env` and the unit (§2.2,
§2.3), make the pristine devices (§3), create the service's devices from a
client (§5). The specs' Evidence sections name run folders of the old data
drive (`SX/…`, `ide-remote/…`); those runs are gone, their numbers stand as
recorded.
