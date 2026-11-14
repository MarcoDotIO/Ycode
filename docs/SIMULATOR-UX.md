# Simulator UX walk-through (checklist)

This checklist walks through using Ycode's simulators from the IDE, from a
machine without a runtime to an app running on a device and stopped again.
It is written for three setups, and the fidelity council's passes (#81)
reuse it:

| Setup | IDE | Device runs on | Link |
|---|---|---|---|
| **M**: macOS | Ycode.app and `ycode-sim-viewer` on the Mac | an arm64 Linux simulator host | Ycode's link (`specs/simulator/sim-link.md`), or ssh for Device Hub |
| **X**: x86-64 Linux | the Linux IDE (`ycode-ide`) on the PC | the arm64 host ("remote", `docs/PARITY.md` §5.11) | Ycode's link |
| **T**: arm64 Linux | the Linux IDE on the simulator host itself | the same machine | Ycode's link over loopback |

Each step says what to do, what must be seen, and a time budget. "Silent"
means more than five seconds without a visible change or a console line;
no step may be silent. Steps marked **(script)** have an automated check;
the commands are in "Running the scripted parts" below.

Ycode never runs Apple's Simulator, Device Hub or `simctl` in this walk.
On a Mac, steps that would need them (Apple's own simulators, `simctl`
runtime listings) are skipped and recorded as skipped.

## 1. First run and runtime setup

Specs: `specs/simulator/runtime-onboarding.md` §3, §5, §11,
`specs/simulator/runtime-downloads.md` §6, `docs/SIMULATOR-LINUX.md` §5.1.

| # | Step | Expected | Budget |
|---|---|---|---|
| 1.1 | Open the runtime wizard (Linux: Window ▸ Downloads or first launch; macOS: Settings ▸ Components ▸ Simulator Runtimes…, or the destination menu's Get a Simulator Runtime…) | The checklist rows for this computer and the configured host, each ok / missing / unknown with a reason and at most one fix | 2 s |
| 1.2 | Host setup report (`ycode-host-setup --report`, the wizard's Check) **(script)** | Every check has a state and a reason; a missing simulator service names what Apply does | 5 s (3 s of it the KVM SVE probe) |
| 1.3 | Apply (`--apply`) **(script)** | Runs only steps that need no root, prints `YCODE-RAN <id> ok` per step, then `DONE pass` | 2 s |
| 1.4 | Check again while the service runs **(script)** | Still `DONE pass`: the service's own ports and self-test are not reported as another program | 5 s |
| 1.5 | Get a runtime when none is there | The wizard offers routes C, B, A in that order on a Mac and B, A on Linux; nothing is fetched before a click and a confirmation that names Apple, the size and the route | — |

## 2. Pairing and hosts

| # | Step | Expected | Budget |
|---|---|---|---|
| 2.1 | `ycode-simhost pair` on the host, `ycode sim remote pair <host>[:port] <code>` on the client | "paired with …" and the host's fingerprint | 1 s |
| 2.2 | `ycode sim remote info` / `devices` | The host's device types and runtime; the devices with their state | 1 s |
| 2.3 | A paired host that is off | A destination row "<host> is offline"; Run on it fails at once with the reason and where to check | 1 s |

## 3. Devices and destinations

Specs: `specs/ide/devices.md`, `specs/ide/destinations.md`.

| # | Step | Expected | Budget |
|---|---|---|---|
| 3.1 | Open an iOS app project | The destination menu lists My Computer and each host's devices, grouped with the group's title, the chosen one checked; an iOS app opens on a host's device, not on My Computer **(script)** | 1 s for the host lookup |
| 3.2 | A host with no devices | One row for the device Run makes (the host's first iPhone type, "iPhone 18 Pro (host)") **(script)** | — |
| 3.3 | Create a device (Run on 3.2's row, `ycode sim remote create`, or Device Hub ▸ Add Device on macOS) | Created from the host's pristine copy, or empty when the host has none; the console says the first boot sets it up and takes minutes **(script)** | 1 s |
| 3.4 | Choose a destination | The toolbar shows its name and an iPhone symbol | — |

## 4. Run, boot progress, Stop

Specs: `specs/ide/run.md`, `specs/simulator/sim-link.md` §9–§10.

| # | Step | Expected | Budget |
|---|---|---|---|
| 4.1 | Product ▸ Run | Activity "Build", then "Launching <app>", then "Running <app> on <device>" once the app opened; Stop is enabled throughout **(script)** | build: seconds |
| 4.2 | The build | Build output in the console; a missing SDK, `ycode-swb` or build script is named with what to set **(script)** | — |
| 4.3 | Upload and install | "Uploaded <app>…", "Installing and launching <bundle id> on <device>…"; a running device is first saved and restarted, and the console says so **(script)** | 1 s; restart ≈ 15 s |
| 4.4 | Boot | "<device>'s display is up", then "Booting <device>… N s" every 10 s; the device window says "Starting... N s" until the screen lights **(script)** | first boot of an empty device: minutes; warm boot: seconds |
| 4.5 | The app opens | "<app> is open on <device> (N s)" and activity "Running <app> on <device>" **(script)** | — |
| 4.6 | A device that stops while booting | Run fails with "<device> stopped on <host> before its display came up" and the end of the host's log **(script)** | 5 s |
| 4.7 | Stop (⌘. / Ctrl+.) during the build | The build ends; activity "Build Cancelled" **(script)** | 1 s |
| 4.8 | Stop while running | The device window closes; activity "Finished running <app> on <device>"; Run is enabled again **(script)** | 1 s |
| 4.9 | Run again | Warm: the device is restored and the app opens in seconds | 30 s |

## 5. The device window

Specs: `specs/ide/device-hub.md` §2.2, §4, §I.2, `specs/simulator/display-stream.md` §13.

| # | Step | macOS (`ycode-sim-viewer`, the IDE's compact window) | Linux (SDL window) |
|---|---|---|---|
| 5.1 | Opens with the run | Compact window, title the device type, subtitle the OS | Window with the device in its frame and the control row |
| 5.2 | Chrome | Frame with buttons; Show / Hide Bezels | Frame; Ctrl+B |
| 5.3 | Scaling | Resize the window (the width sets the scale); Expand ▸ zoom segments | Ctrl+1/2/3: fit, point, pixel |
| 5.4 | Rotation | Rotate Left / Right (⌘← / ⌘→) for foldables; disabled for other devices | Ctrl+Left/Right; "This device does not rotate" for other devices |
| 5.5 | Screenshot | ⇧⌘S, banner "Screenshot Saved", PNG on the Desktop or the screenshot location | Ctrl+Shift+S or Shot, notice "Screenshot Saved to <folder>" |
| 5.6 | Recording | ⇧⌘R, red stop symbol, "Recording Saved" | not available (open item) |
| 5.7 | Home, Lock, Volume | Controls and menus | Ctrl+Shift+H, Ctrl+L, Ctrl+Up/Down, control row |
| 5.8 | Touch and keys | Click and drag, Option for two fingers, keys | Click and drag, Alt for two fingers, keys |
| 5.9 | Boot and errors on the screen | "Starting… N s", "The device is not running or the connection dropped; reconnecting" | Same texts; "<device> is starting" while the host starts it |

## 6. Device Hub (macOS)

Spec: `specs/ide/device-hub.md` §I. The Linux IDE has no Device Hub yet;
there `ycode sim remote boot|shutdown|create|log` do its device actions.

| # | Step | Expected |
|---|---|---|
| 6.1 | Window ▸ Devices and Simulators (⇧⌘2) | Sidebar with Ycode's devices, canvas, inspector |
| 6.2 | Start / Shut Down / Restart / Erase | Spinner in the status view while it runs; the canvas goes live |
| 6.3 | Open in New Window / Expand | Moves the device between the compact and hub windows |
| 6.4 | Settings inspector | The running device's settings |

## 7. Errors (consolidated)

| Situation | Message (where) |
|---|---|
| Host off | "<host> is offline" row; Run: "The simulator host <host> did not answer on Ycode's link. Check that it is on and that ycode-simhost serve runs there…" (console) |
| No iOS SDK on this Linux computer | "No iOS SDK: set YCODE_USER_SDK to a folder with your own copy of Xcode's Platforms/iPhoneSimulator.platform and Toolchains/XcodeDefault.xctoolchain…" (console) |
| No build script | "the iOS Simulator build script was not found at …; set YCODE_IOS_BUILD …" (console) |
| No guest tools on the host | "this host's simulator tree has no guest tools (…/ylaunch), so it can boot devices but not install or launch apps…" (console; `ycode-simhost check` notes it) |
| Device stops while booting | "<device> stopped on <host> before its display came up. The host's log for it ends with: …" (console) |
| Build fails | the build's errors in the console; activity "Build Failed" |

## 8. Running the scripted parts

- Unit and loopback tests (Mac and Linux): `swift test --filter
  'SimulatorUXTests|SimulatorUXSetupTests|SimHostCreateTests|DeviceWindowNoticeTests|LinkTransportTests|EmptyAppIconTests'`.
  `SimulatorUXTests` runs a real `SimHostService` on loopback with a
  stand-in launcher (create, boot progress, app opened, a device that
  stops). The setup-script and launcher tests run on Linux only.
- The Linux IDE walk: `YCODE_IDE_SIMUX=<shot prefix>` (driver
  `ycode/Sources/ycode-ide/ShellDriver+SimulatorUX.swift`) runs §3–§4 with
  screenshots and timings; `YCODE_IDE_SIMUX_DEST`, `_LIMIT`, `_HOLD`.
  Set `YCODE_SIM_VIEWER` to a wrapper that adds `--script <file>` to run
  §5 in the device window (viewer script commands:
  `ycode/Sources/YcodeRemoteViewer/ViewerScript.swift`).
- The macOS device window: `ycode-sim-viewer --link <device> --script <file>`
  (commands: `ycode/Sources/ycode-sim-viewer/ScriptRunner.swift`).
- The host: `ycode-host-setup --report`, `--apply`, then `--report` again
  while `ycode-simhost serve` runs (§1.2–§1.4).
- A release's simulator tree on a plain host:
  `packaging/flatpak/check-sim-tree.sh Ycode-<version>-aarch64.tar.xz
  [--runtime-root <RuntimeRoot>]` unpacks it into a fresh folder and, with
  nothing from a build environment, checks its layout and guest tools, that
  its programs load and work (the translator's self-test, `ycode-simd
  --check-encoders`), `ycode-simhost` check, serve, identity and pair, and with
  a runtime and `/dev/kvm` a device that boots, streams JPEG frames with
  tiles, takes a screenshot and stops. The release runs it on
  `ubuntu-24.04-arm`.

## 9. Results

Walked on 2026-11-05 on branch `b3-simux`. M: the Mac (macOS 27), its
`ycode` and `ycode-sim-viewer` over Ycode's link to the arm64 host. X: the
x86-64 PC (Ubuntu 26.04, Wayland) with the arm64 host. T: the Linux IDE on
the arm64 host (Ubuntu 24.04; an offscreen SDL display, no desktop session
of its own). The host ran the 1.0.0-beta.2 aarch64 release's simulator tree
with this branch's `ycode-simhost` and launcher on test ports, the
read-only iOS 27.1 runtime, an iPhone 18 Pro, and the template iOS app
"Hello" built on X. Times are wall clock from the step's start.

| # | Step | M | X | T |
|---|---|---|---|---|
| 1.1 | Runtime wizard | skipped: on a Mac its listing runs `simctl` | not walked (no view changes this round; B3-WIZARD owns its layout) | not walked |
| 1.2 | Host setup report | – | pass, 3.3 s; **fixed**: a `--sim-tree` release reported "ycode-simhost was not found" | (same host) |
| 1.3 | Apply | – | pass, 0.3 s (6 steps) | (same host) |
| 1.4 | Check while the service runs | – | **fixed**: failed (self-test port test, UDP owner, ports kept by the device's `sleep`/`tee`); now pass, 5 s | (same host) |
| 1.5 | Get a runtime | not walked (would fetch from Apple) | not walked | not walked |
| 2.1 | Pair | pass, 0.8 s | pass, 0.03 s | pass, 0.03 s |
| 2.2 | Info, devices | pass | pass, 0.02 s | pass |
| 2.3 | Offline host | – | pass: row "offline-host is offline", Run fails in 0.4 s with the reason | – |
| 3.1 | Destinations | (Ycode.app: ssh destinations, not the link; open item) | pass, lookup 0.01 s; **fixed**: grouped, checked, iOS app opens on the host's device | pass |
| 3.2 | Host without devices | – | **fixed**: the host disappeared from the menu; now "iPhone 18 Pro (host)" | – |
| 3.3 | Create a device | – | **fixed**: refused without a pristine copy; now created empty, first boot sets it up | – |
| 4.1 | Run: activity, Stop | `ycode sim remote run`: 33 s to the device window | **fixed**: no activity and Stop disabled during a remote run; now Build → Launching → Running, Stop enabled | pass (as X) |
| 4.2 | Build | – | **fixed**: build script not found from a swift-build product folder, `ycode build` wanting `swbuild` beside `ycode-swb`, the SDK's platforms registered twice, `ycode` stopping on the template's empty app icon set; now 1–5 s | stand-in build (no SDK, no `ld64.lld` on the host) |
| 4.3 | Upload, install, restart | 0.0 s upload | pass; **fixed**: the 5–15 s save-and-restart of a running device was silent | pass |
| 4.4 | Boot progress | "iPhone-18-Pro is starting" in the window, live after 7.9 s (warm) | **fixed**: console silent and "Running" shown at the display server's start; now display up, "Booting… N s" every 10 s; first boot of an empty device 243 s, warm 13–17 s | pass, warm 13 s |
| 4.5 | App opens | pass | pass, "Hello is open on iPhone-18-Pro (13 s)" | pass |
| 4.6 | Device stops while booting | – | **fixed** (loopback test): now fails with the host's log | – |
| 4.7 | Stop during the build | – | **fixed** (test): the build ran on | – |
| 4.8 | Stop while running | viewer quits | pass, 1 s, no device window left | pass |
| 4.9 | Run again | – | pass, app open after 21–27 s (save, restore, launch) | pass, 15 s |
| 5.1 | Window opens | pass: compact window "iPhone 18 Pro" / "iOS 27.1" | pass | pass |
| 5.2 | Chrome, bezels | pass (Hide Bezels) | pass | pass |
| 5.3 | Scaling | pass (window width 420, Expand, Zoom In) | pass (fit, point, pixel) | pass |
| 5.4 | Rotation | pass: "This device does not rotate" | pass: same notice | pass |
| 5.5 | Screenshot | pass: banner "Screenshot Saved", PNG | **fixed**: saved silently; now "Screenshot Saved to <folder>" | (as X) |
| 5.6 | Recording | pass: "Recording Saved", .mov | not available (open item) | not available |
| 5.7 | Home | pass, 445 ms to the screen | pass, 609 ms | pass |
| 5.9 | Boot on the screen | pass | **fixed**: "not running" while starting, minutes of black screen in a first boot; now "is starting", "Starting... N s" until the screen lights | pass |
| 6.x | Device Hub | not walked: Ycode.app's hub lists `simctl` devices and drives the host over ssh; covered by `YcodeDeviceUITests`/`YcodeUITests` (pass) | no hub on Linux (open item) | no hub |
| 7 | Errors | – | pass (offline host); the others by tests | – |

Host problems the walk found that were outside that round's files: the
1.0.0-beta.2 aarch64 release's simulator tree could not render on Ubuntu
24.04 (its `ycode-airc` needed glibc 2.44 and `libxml2.so.16`; its JPEG frames
were empty against the system's `libjpeg.so.8`, so viewers had to ask for
zlib), and it had no guest tools (`ylaunch`). The walk used a `ycode-airc`
built from source on the host, the guest tools built on the Mac, and
`--encoding zlib`. Branch `b3-armtree` fixed all three (2026-11-08, below).

### The release's simulator tree on a plain host (2026-11-08)

The aarch64 tarball built by `build-flatpak.sh` from branch `b3-armtree`
(with `YCODE_GUEST_TOOLS`), unpacked on the arm64 host (Ubuntu 24.04, glibc
2.39) and run with nothing from a build on `PATH` or `LD_LIBRARY_PATH`:

| # | Step | Result |
|---|---|---|
| — | `check-sim-tree.sh <tarball> --runtime-root …` | 34 passed, 0 failed: layout and guest tools, every simulator program loads, `ycode-airc selftest`, JPEG (libjpeg ABI 62, the tree's own) and zlib, `ycode-simhost` check, serve, identity, pair, stop; a new device's home screen at 88 s, 22 JPEG frames all with tiles, screenshot, Home, stop in 11 s |
| 1.2 | Host setup report (`--sim-tree` the tree, test ports) | 3.6 s; **fixed**: libjpeg reported missing (no `/sbin` on `PATH`; a release carries its own), LLVM 18 and SPIRV-Tools asked of a release |
| 1.3 | Apply | pass, 3.8 s (5 steps) |
| 1.4 | Check while the service runs | pass, 3.6 s |
| 2.1 | Pair (client: the Mac's `ycode`) | pass, 1.2 s |
| 2.2 | Info, devices | pass |
| 3.3 | Create a device | pass, 1.6 s |
| 4.3–4.5 | Run an app (`ycode sim remote run … --no-view`) | pass: installed and launched by the tree's `ylaunch`; first boot of the empty device home at 60 s, app open after the settled home screen |
| 4.8 | Stop | pass, 14 s (the device is saved) |
| 4.9 | Run again | pass, warm: home 7 s after start, app open at 15 s |
| 5 | The display stream | JPEG frames with tiles (the 1.0.0-beta.2 tree: 1 frame of 36 bytes, 0 tiles, on the same host) |

The tarball's `ycode`, IDE and viewer still need glibc 2.43 and OpenSSL 3.2
(libcurl, SDL 3), so on this host the client was the Mac; see
`docs/SIMULATOR-LINUX.md` §5.1.

### Open items

- Recording in the Linux device window (macOS has it).
- A Device Hub in the Linux IDE (start, shut down, erase, settings); today
  `ycode sim remote boot|shutdown|create`.
- Ycode.app (macOS) runs on paired link hosts only through
  `ycode sim remote`; its destinations and hub use ssh.
- Stop in the Linux IDE closes the device window but leaves the app running
  on the device (the link has no "terminate app" request).
- New SwiftUI template apps do not build on Linux: `#Preview` needs Apple's
  `PreviewsMacros` plug-in.
- The aarch64 tarball's `ycode`, IDE and viewer on a distribution older than
  freedesktop 26.08 (libcurl needs glibc 2.43 and OpenSSL 3.2, SDL 3 glibc 2.43).

## Evidence

| Claim | Evidence | Level |
|---|---|---|
| Steps, texts and order | Ycode's own code and runs (this walk, 2026-11-05) and the specs cited per section | – (our own code) |
| Xcode behaviour referred to | `specs/ide/device-hub.md`, `specs/ide/destinations.md`, `specs/ide/run.md`, `specs/simulator/runtime-onboarding.md`, with their own Evidence sections | as those specs record |
| Not used | `research/`, the reference tools, Apple's Simulator, Device Hub and `simctl` | – |
