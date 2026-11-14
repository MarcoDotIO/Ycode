# Developing Ycode

This is the Swift package with the IDE, the command-line tools and the simulator.
To install or try Ycode, read the [root README](../README.md) instead.

This is clean-room code. Read [`../CONTRIBUTING.md`](../CONTRIBUTING.md) before you
make any change here.

## Layout

| Path | Contents |
|---|---|
| `Sources/Ycode{Plist,Project,Workspace,Settings,MachO}` | Project model, file formats, build settings, Mach-O |
| `Sources/Ycode{Build,Language,Debug,Assistant,Completion,Subprocess}` | IDE services: build engines and PIF, LSP and DAP clients, coding assistant, subprocess runs |
| `Sources/YcodeIDECore` | The IDE's portable model, shared by both windows |
| `Sources/Ycode{UI,DeviceUI,App}` | The macOS IDE (AppKit) and its device windows |
| `Sources/{YcodeIDEShell,ycode-ide}` | The Linux IDE (SwiftUI on OpenViews, `../frameworks/swiftui`) |
| `Sources/YcodeEditorKit` | The Linux IDE's source editor model: buffer, undo, movement, safe saving, recovery copies (portable) |
| `Sources/{YcodeXcodebuild,ycodebuild-cli}`, `Tools/ycode-swb` | `ycodebuild` and its swift-build helper |
| `Sources/Ycode{DarwinABI,DarwinKernel,Hypervisor,XPC,HostServices}`, `Sources/ycode-simd` | Simulator: the Darwin kernel layer, KVM, XPC, host services, the VM monitor |
| `Sources/Ycode{MetalHost,Vulkan}`, `Translator/` | Simulator: Metal on Vulkan, and the AIR to SPIR-V translator |
| `Sources/Ycode{DisplayStream,SimFeatures,SimLink}`, `Sources/ycode-sim-viewer` | Simulator: the display stream, settings features, the remote link, the viewer |
| `SimShim/`, `SimHostLibs/`, `SimGuestFrameworks/`, `SimGuestAgents/` | Simulator guest side, all our own code |
| `Samples/` | Small projects used by tests |
| `scripts/` | App packaging, simulator launchers, conformance and profiling scripts, the lint wrapper |

## Build and test

Platforms: the libraries and command-line tools build and test on macOS and
Linux (x86-64 and arm64, Swift 6.4). `YcodeUI`, `YcodeDeviceUI`, `YcodeApp`
and `ycode-sim-viewer` are macOS only. `ycode-simd` runs only on arm64 Linux
with KVM.

```bash
swift build
swift test
scripts/lint.sh                      # SwiftLint over ycode/ and frameworks/
scripts/make-app.sh                  # macOS: .build-ide/app/Ycode.app
.build/debug/ycode describe path/to/App.xcodeproj
.build/debug/ycode roundtrip path/to/App.xcodeproj    # also .xcscheme / contents.xcworkspacedata
.build/debug/ycode schemes path/to/App.xcworkspace
.build/debug/ycode macho path/to/binary
.build/debug/ycode dsc path/to/dyld_sim_shared_cache_arm64 [--images N] [--image /usr/lib/libobjc.A.dylib]
.build/debug/ycode settings path/to/App.xcodeproj -target App -configuration Debug [--assigned-only] [--json] [NAME=value]
.build/debug/ycode deps path/to/executable --root path/to/RuntimeRoot [--tree]
.build/debug/ycode build path/to/App.xcodeproj -scheme App [--test] [--engine xcodebuild|swift-build|swiftpm]
.build/debug/ycode build path/to/Package [--test]     # Linux and the Flatpak: SwiftPM, as the Linux IDE builds packages
.build/debug/ycode pif path/to/App.xcodeproj
.build/debug/ycode profile record --linux -o out.gaugetrace -- path/to/executable   # Gauge, the profiler
.build/debug/ycode profile summary|tree|flame|annotate|symbolicate out.gaugetrace ...
.build/debug/ycode assets compile App/Assets.xcassets App/AppIcon.icon --output out --platform iphonesimulator --app-icon AppIcon
.build/debug/ycode assets info out/Assets.car
.build/debug/ycode assets icon info|validate|to-json|from-json|render App/AppIcon.icon ...
.build/debug/ycode strings compile --output-directory out App/Localizable.xcstrings   # also generate-symbols, extract, convert, info
.build/debug/ycode mcp [--workspace path/to/Package] [--allow-writes] [--http [PORT]]   # the MCP server for coding agents
.build/debug/ycode mcp install-skill path/to/Package                                # the Ycode skill for agents
```

`ycode mcp` is Ycode's MCP server (`../specs/ide/coding-assistant.md` §10):
build, test, run (also on the Ycode Simulator, with screenshots), issues,
search, previews and String Catalogs for Claude Code, Codex and other MCP
clients, on macOS and Linux. Add it with `claude mcp add ycode -- ycode mcp`
or `codex mcp add ycode -- ycode mcp`. It is read-only unless started with
`--allow-writes`; in the IDE's agent mode every change is a proposal the
user reviews.

`ycode assets` is Ycode's asset catalog compiler (`../specs/formats/assets-car.md`
"Ycode implementation"). Builds use it instead of Xcode's `actool` with
`YCODE_ASSET_COMPILER=ycode` (the default off macOS); `Samples/IconSamples`
is an iOS app built that way.

`ycode strings` is Ycode's String Catalog compiler, extractor and converter
(`../specs/ide/string-catalog.md` "Ycode implementation"). Builds use it
instead of Xcode's `xcstringstool` with `YCODE_STRINGS_COMPILER=ycode` (the
default off macOS, and on a Mac whose Xcode has no `xcstringstool`);
`Samples/StringsSamples` is an iOS app built that way.

`ycode profile` is Gauge's command line (`../specs/ide/profiler.md` §7). On
Linux it samples with `perf_event_open`, or, where the kernel forbids it
(`perf_event_paranoid` above 2), with `libYcodeGaugeAgent.so` from the same
build directory. Apps on the Ycode simulator are recorded by `ycode-simd
--profile` (§3.1) and, in the IDE, by Product ▸ Profile (⌘I).

`make-app.sh` builds `YcodeApp` in release, wraps it in an app bundle,
stamps the build SDK so that AppKit uses the current look, and signs it ad
hoc (`../specs/ide/liquid-glass-ycode.md` §0).

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

Tests hosted in an app (`TEST_HOST`) run inside it with Ycode's test agent
next to ycodebuild (`../specs/ide/testing.md`, "Ycode implementation"):

```bash
swift build --product YcodeTestAgent                    # .build/debug/libYcodeTestAgent.dylib (macOS hosts)
OUT=.build/debug SimGuestAgents/build-test-agent.sh     # .build/debug/iphonesimulator/ (the Ycode simulator)
.build/debug/ycodebuild -project Samples/TestHostSamples/HostMac/HostMac.xcodeproj -scheme HostMac test
# On the Ycode simulator: YCODE_SIM_HOST, YCODE_SIM_DATA, YCODE_SIM_RUNTIME, YCODE_SIM_SIMD (and YCODE_SIM_DEVICE)
.build/debug/ycodebuild -project Samples/TestHostSamples/HostPhone/HostPhone.xcodeproj -scheme HostPhone \
    -destination 'platform=iOS Simulator,name=Ycode Simulator,arch=arm64' test
.build/debug/ycode results path/to/Test-HostPhone-….xcresult
```

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

### Nothing on screen

On macOS no test may put a window, panel, sheet, alert or menu on a
display: the owner works on the Mac while agents run the suites. Every
macOS test target links `Tests/CYcodeTestOffscreen`, which installs itself
when the test bundle loads, before any test:

- Every window ordered in, and every frame given to a visible window, is
  moved 20,000 points left of all displays (only when it would touch one;
  its size and height stay), and AppKit's constraint to a screen is off, so
  it stays there. A visible window that moves, resizes or changes screen by
  any other path (AppKit's own, the window server's, a display added or
  rearranged) is moved off again at once. Every window is also fully
  transparent on the window server (`alphaValue` reads what was set), so
  one that reaches a display anyway shows nothing; a `screencapture -l`
  helper wraps the capture in `YcodeOffscreenOpaqueDuringCapture`.
  Ordering in and out runs without AppKit's window animations,
  which draw a document window's fade on a display even when the window is
  off every display. Tests still order windows in when they need the window
  server (accessibility, `screencapture -l`, sheets); they never need a
  screen.
- App-modal alerts and panels (`runModal`, open and save panels) answer
  Cancel without showing; menus do not pop up; the app is not activated;
  Finder and other apps are not asked to open anything. Give such code a
  hook the test can set (as `DevicesController.pairing.confirm` does) rather
  than relying on this. A process that loads several test bundles shares one
  guard.
- A sentinel checks the window server every 100 ms, from the first window
  on, for a window of the test process on a display. It moves the window
  off, prints `OffscreenGuard: …`, and at exit fails the run (status 1),
  naming the window. `OffscreenGuardTests` checks each of the above.

Measure positions against the window (`convert`, `contentLayoutRect`) or
against `NSScreen` frames computed by hand, never against where a window
landed on a real display. The escape hatch is `YCODE_TESTS_ON_SCREEN=1`, for
a recording the owner runs by hand (`FlickRecordingTests`); nothing in CI or
an agent's run sets it. `YCODE_OFFSCREEN_TRACE=1` prints every window the
guard moves, with the test that showed it.

### Tests in a full run

A full run executes each test bundle's suites in parallel, and other runs may
share the machine. What made tests pass alone and fail in full runs:

- **The main actor is shared.** UI suites run on it, and synchronous work in
  one suite (a window build, a toolchain call) holds it from all the others,
  for 150 s and more at the start of a full UI run. Wait for conditions with
  `waitUntil` (UI tests), which counts only the time the main actor actually
  had, never with a wall-clock deadline. Time limits are hang guards.
- **The cooperative pool is shared.** Never block a pool thread for long
  (`flock`, `waitUntilExit`, a blocking `read` in a detached task): a dozen
  such waits leave no thread for streamed replies or other suites, and can
  deadlock the process. `InterprocessLock.acquire` polls for this reason.
  Work that a blocked caller waits for (a pipe reader or writer) gets a
  `Thread` of its own, never `DispatchQueue.global()`: when waiting callers
  fill that queue's pool, the work never starts. `Subprocess.run` hung the
  3-core CI runner this way.
- **Host state moves.** Volume free space, clocks and the process list
  change while a test runs; compare only what the code under test decides.
- **Fixed pauses race.** Wait for the state itself (a thread blocked in the
  kernel, a line in the console), not for a few milliseconds.
- **Checkouts differ.** A test's scratch paths contain the checkout's name
  (`…/visionos-r10b/…`): read meaning only from the part of a
  path the code owns (a runtime's platform comes from the runtime's own
  name, not from the directories above it).
- **Fakes must end.** A stand-in launcher or server answers every command
  the code under test may send; one that hangs keeps a child process and a
  thread to the end of the run, and `ProcessAudit` fails the bundle (it
  names the child and its arguments).
- Suites that keep a language server on the sample package use their own
  copy (`samplePackage(directory:)`); others rewrite and build the shared one.

Known flaky tests (rerun alone before reporting one; CI reads the same list from
`../.github/ci/known-flaky.txt` and retries nothing else):
`SnapshotKernelRoundTripTests.calendarTimersFollowTheWallClockAcrossARestore`,
`CLIAgentTests.cancelInterruptsTheTool`,
`MainThreadResponsivenessTests.fileSystemWatcherReportsChanges`,
`threadSelfusageCountsTheCallingThread` under load,
`StreamingProcessTests.anInheritedPipeDoesNotHoldTheExitBack` under load (its
limit was 3.9 s, with 3.9 and 4.8 s seen in full runs; since 2026-11-04 the
child lives 60 s and the limit is 20 s),
`SourceKitLSPEndToEndTests` timeouts on the arm64 Linux host, and, on the
3-core macOS CI runner only, `BuildServerWindowTests.projectWindowUsesTheBuildServer`
(it passes alone). Two layout tests,
`NavigatorInspectorR45Tests.filterOptionsAndTogglesSitInsideTheField` and
`UISpacingTests.hubSidebarGroupEndsAtTheSidebarEdge`, need macOS 27.2: their
positions were measured there, and CI's macOS 27.0 lays these controls out
differently.

CI runs on macOS and on Linux x86-64 and arm64 (`../.github/workflows/ci.yml`),
one test at a time (`swift test --no-parallel`): its machines have three or four
cores, and a parallel run there spent minutes waiting for the main actor.
Its hosted machines have no KVM guarantee, GPU, simulator runtime or corpus, so
those tests skip themselves; each job's summary lists what it skipped. A clean
checkout on an x86-64 Linux machine with 16 cores builds in under 2 minutes and
runs all of its 2,216 tests in about 3.

## Corpus tests

`PBXProjCorpusTests` runs against real projects that are not checked in. It
reads a manifest from `../research/dirty/pbxproj-corpus.txt`, or from the path
in `YCODE_PBXPROJ_CORPUS`. The manifest has one path per line:

- `= /path/App.xcodeproj`: written by Xcode. The round trip must be
  byte-identical.
- `~ /path/App.xcodeproj`: edited by other tools. The round trip must be
  lossless and idempotent.

If there is no manifest, the suite is skipped.

Other opt-in test inputs:

- `YCODE_SIM_RUNTIME_ROOT`: a simulator `RuntimeRoot`, for the Mach-O and
  runtime tests.
- `YCODE_KEYCHAIN_TESTS=1`, `YCODE_LIVE_ASSISTANT=ollama,claude,codex,agy`:
  the coding assistant's keychain and live-provider tests.
- `YCODE_E2E_REMOTE`, `YCODE_E2E_DATA`, `YCODE_E2E_RUNTIME`, `YCODE_E2E_SIMD`,
  `YCODE_E2E_APP`: an end-to-end run on a remote Ycode simulator.
- `YCODE_CAMERA_HW_TESTS=1`: tests with a real host webcam.

Tools are found on `PATH` or through overrides: `YCODE_SWB` (the swift-build
helper), `YCODE_SOURCEKIT_LSP`, `YCODE_LLDB_DAP`, `YCODE_BUILD_TOOL`.

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
a new simulator build, or `--cold` boot cold: about 30 s to the home screen
on an idle host and longer for a new device
([`lean-boot.md`](../specs/simulator/lean-boot.md) §9). The window shows
"Booting…" until the first frame, and the app icons come with the wallpaper. A cold-booted device is saved only from 30 s
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
[`../specs/simulator/display-stream.md`](../specs/simulator/display-stream.md);
input: [`../specs/simulator/hid-input.md`](../specs/simulator/hid-input.md).
To build the simulator on the host, see
[`../docs/SIMULATOR-LINUX.md`](../docs/SIMULATOR-LINUX.md) §5.
