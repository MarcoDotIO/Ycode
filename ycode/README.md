# Ycode (implementation)

This is clean-room code. Read `../CLAUDE.md` before you make any change here.

```bash
swift build
swift test
.build/debug/ycode describe path/to/App.xcodeproj
.build/debug/ycode roundtrip path/to/App.xcodeproj    # also .xcscheme / contents.xcworkspacedata
.build/debug/ycode schemes path/to/App.xcworkspace
.build/debug/ycode macho path/to/binary
.build/debug/ycode dsc path/to/dyld_sim_shared_cache_arm64 [--images N] [--image /usr/lib/libobjc.A.dylib]
.build/debug/ycode settings path/to/App.xcodeproj -target App -configuration Debug [--assigned-only] [--json] [NAME=value]
```

## ycodebuild

`ycodebuild` accepts `xcodebuild` command lines (`-list`, `-showsdks`,
`-version`, `-showBuildSettings [-json]`, `-showdestinations`, `build`,
`analyze`, `clean`, `install`, `build-for-testing`, …) and prints the same
formats; see `../specs/xcodebuild/`. Build settings and builds go through
swift-build via a small helper package, built once:

```bash
cd Tools/ycode-swb && swift build --product ycode-swb && swift build --product SWBBuildServiceBundle
export YCODE_SWB=$PWD/.build/debug/ycode-swb
cd ../.. && .build/debug/ycodebuild -project path/to/App.xcodeproj -scheme App build
# Conformance against the reference tool (macOS):
YCODE_PBXPROJ_CORPUS=manifest.txt python3 -I scripts/xcodebuild-conformance.py --details
```

Supported platforms: macOS and Linux (x86-64 and arm64, tested with Swift 6.4).
Set `YCODE_SIM_RUNTIME_ROOT` to a simulator `RuntimeRoot` to run the runtime
tests on Linux.

To test on a Linux machine, sync the package without build outputs, then build
and test there:

```sh
rsync -az --delete --exclude .build --exclude .build-ide ycode/ <user>@<linux-host>:Ycode/ycode/
ssh <user>@<linux-host> 'cd Ycode/ycode && swift build && swift test'
```

`.build-ide` holds test and IDE scratch output. Tests write into their own
temporary directories, so it can be deleted at any time.

## Corpus tests

`PBXProjCorpusTests` runs against real projects that are not checked in. It
reads a manifest from `../research/dirty/pbxproj-corpus.txt`, or from the path
in `YCODE_PBXPROJ_CORPUS`. The manifest has one path per line:

- `= /path/App.xcodeproj`: written by Xcode. The round trip must be
  byte-identical.
- `~ /path/App.xcodeproj`: edited by other tools. The round trip must be
  lossless and idempotent.

If there is no manifest, the suite is skipped.

## Try the simulator from a Mac (`scripts/ycode-sim-try`)

The simulator (`ycode-simd`) runs on an arm64 Linux host with KVM. From a
Mac with ssh key access to that host, one command boots a device there and
opens a viewer window on the Mac:

```sh
# once: tell the launcher where the host and your area on it are
mkdir -p ~/.config/ycode
cat > ~/.config/ycode/sim-try.env <<'CONF'
YCODE_SIM_HOST=<user>@<simulator host>
YCODE_SIM_HOME=<data volume on the host>/<your area>/sim-try
CONF
# and on the host, $YCODE_SIM_HOME/sim-serve.env names the built tree, the
# runtime, the pristine device and the boot-slot locks (see scripts/ycode-sim-serve);
# saving and restoring the device also needs python3 with PIL there

scripts/ycode-sim-try            # from ycode/
scripts/ycode-sim-try --downscale 2 --quality 70   # for a slow link
scripts/ycode-sim-try --cold     # boot cold this time (the device keeps its data)
scripts/ycode-sim-try --erase    # start over with a new device (data and saved state erased)
```

It builds the viewer (`ycode-sim-viewer`), installs `scripts/ycode-sim-serve`
and `scripts/ycode-sim.sh` (as `ycode-sim`, the launcher the IDE's runs use)
on the host, starts the device there in a free boot slot with
`--display-server`, forwards the display socket over the same ssh session,
and opens the viewer. Closing the window saves the device and frees the
slot; the next session restores it in place, so the home screen (or the
app you left open) is back and takes input a few seconds after the slot is
free, with its apps, data and settings as you left them (like Xcode's
Simulator, a device keeps its state until it is erased). The first session,
a new simulator build, or `--cold` boot cold: about a minute to the home
screen, the window shows "Booting…" until the first frame, and the app
icons come with the wallpaper. A cold-booted device is saved only from 30 s
after its home screen showed; closing the window earlier shuts it down
cleanly and the next session boots it cold again (its data stays).

The device behaves like Xcode's Simulator: it boots to an unlocked home
screen and never dims or locks by itself (⌘L locks it; Home or Lock wakes
it), and the first click on the home screen is taken at once. The first
launch of an app after a cold boot takes about 10–20 s to draw.

In the window: click and drag = one finger (swipe up from the bottom edge
goes home), Option-drag = pinch/rotate, Option-Shift-drag = two-finger pan,
scroll wheel or trackpad = drag, typing = hardware keyboard. ⇧⌘H Home,
⌘L Lock, ⌥⌘↑/↓ volume, ⌘S screenshot (PNG on the Desktop), ⌘1/⌘2/⌘3 window
size. Protocol and design:
`specs/simulator/display-stream.md`; input: `specs/simulator/hid-input.md`.
