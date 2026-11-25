# B5-FIX-VIEWER: Start on a Mac simulator opens the simulator viewer (1.0.0-beta.5 fix round)

The owner's check on the Mac: Device Hub ▸ Start on a Mac (simctl)
simulator booted it, then ran `open -a Simulator --args -CurrentDeviceUDID
<udid>`. Xcode 27 ships no Simulator.app, so the open failed and the hub
reported that the app could not be found. Spec: `specs/ide/device-hub.md`,
"Ycode decisions (2026-11-17)", the bullet "The Mac's own simulators" and
its Evidence line (corrected in d7ca0698). macOS only: the Linux hub has no
simctl simulators (see below).

## What changed

- **The viewer is looked up through Launch Services**, at each Start and
  Show in Viewer, in the spec's order:
  1. bundle id `com.apple.dt.Devices`, opened with `open -b
     com.apple.dt.Devices` and no arguments (it lists the booted device);
  2. bundle id `com.apple.iphonesimulator`, opened with `open -a Simulator
     --args -CurrentDeviceUDID <udid>` (the spec's command, unchanged).
- **No viewer found:** the device stays booted and nothing is opened. The
  row shows Booted, the canvas shows the running capsule, and the banner
  says "No simulator viewer is installed. The device is running without a
  screen." It is not a start failure. Show in Viewer with no viewer shows
  the same banner.
- **A viewer that does not open** after a successful boot is no longer a
  start failure either: the row shows Booted and the banner gives the
  failure ("Could not show the simulator: … (the simulator viewer)").
  Before, the row stayed Shut Down until the next poll.
- **Canvas:** the capsule's state line reads "Running in the simulator
  viewer"; its button, the More Actions item and the row's context-menu
  item are "Show in Viewer" and open the viewer again.
- **Tooltip and banner** of the other controls: "The simulator viewer has
  these controls." (the tooltip keeps the control's name first, as every
  hub control does: "Home. The simulator viewer has these controls.").
- **Names:** the hub's own words for these devices name no Apple product;
  a test checks them.

## Screenshot of a multi-screen device, and failure wording (added 2026-11-24)

Spec: the same bullet's "Screenshot" and "Failure messages" (c7eea6af,
merged into this branch).

- **Several screens:** when `simctl io <udid> screenshot <file>` refuses
  and lists the screens (`--display=1  LCD (primary) 1398x2034`, …, code
  22), Ycode parses the list and captures each screen with
  `simctl io <udid> screenshot --display=<id> <file>`.
- **Black screens dropped:** a picture whose every pixel has red, green and
  blue 0 (read with ImageIO) is an off screen and is deleted, unless every
  picture is black: then the first listed screen's is kept.
- **Names:** one kept picture takes the plain name (`Screenshot <device>
  <date>.png`); several take ` (<screen name>)` before `.png`. The screen
  name is the text between the id and the size, e.g. `LCD (primary)`.
- **Banner:** "Screenshot Saved" or "N Screenshots Saved". A screen whose
  capture fails is skipped; if all fail, the banner gives the last failure.
- **Failure wording:** every failure reads "Could not <action> the
  simulator: <last line>", with whole phrases: "start", "shut down",
  "erase", "show", "take a screenshot of". The screenshot failure used to
  read "Could not take a screenshot the simulator: …".
- Code: `ycode/Sources/YcodeIDECore/Session/SimctlScreenshot.swift` (new);
  `SimctlDeviceControl.isBlackImage` (injected, default
  `SimctlDeviceControl.imageIsBlack`).
- Open: the spec leaves open what the reference saves for a two-screen
  device; Ycode does what the spec says.

## Where

- `ycode/Sources/YcodeIDECore/Session/SimctlDeviceControl.swift`: new
  `SimulatorViewer` (the two bundle ids, `openArguments(_:)`,
  `find(_:)`); `SimctlDeviceControl.isInstalled` (injected; the default is
  `NSWorkspace.urlForApplication(withBundleIdentifier:)`, false on Linux);
  `start` and `restart` return a `StartResult` (booted, banner);
  `noViewerMessage`. `showArguments` is gone.
- `ycode/Sources/YcodeUI/Window/DevicesController+Simctl.swift`: the texts,
  `showInViewer` (was `showInSimulator`), and `runSimctl`'s work returns
  its banner, so a booted start can carry a notice.
- `DevicesController.swift`, `DevicesController+Standalone.swift`,
  `YcodeDeviceUI/DeviceCanvasView.swift`: one call and comments.

## Linux

Nothing to change. The Linux hub has no simctl simulators: its simulators
are Ycode's own, started through `ycrun` (`DeviceHubSimHostBackend`), and
their screens show live in the hub's canvas. No Linux source contains the
Simulator-app text, `-CurrentDeviceUDID`, or the "elsewhere" capsule's
Mac-simulator wording; `SimulatorViewer.find` with the default lookup
returns nil there.

## Open facts

- The spec leaves open whether Device Hub can be opened on one device. Ycode
  opens it by bundle id with no arguments, as the spec says.
- The Simulator fallback is opened by name (`-a Simulator`), the spec's
  literal command, although it was found by bundle id.

## Tests

- `YcodeIDECoreTests/SimctlScreenshotTests`: the refusal parsed (the
  owner's observed line, plus a second screen line of the test's own); the
  black check on PNGs the test generates; a one-screen device; a closed Duo
  (lit outer, black inner: one file, plain name); both lit (two named
  files, "2 Screenshots Saved"); all black (the first screen's kept); every
  capture failing; each action's failure wording.

- `YcodeIDECoreTests/SimctlDeviceControlTests`: the viewer choice (both
  installed, Device Hub only, Simulator only, neither) and the lookup order;
  Start's arguments for each viewer; no viewer (booted, nothing opened, the
  notice); a viewer that does not open; restart, show, erase, screenshot.
- `YcodeUITests/DeviceHubSimctlTests` (offscreen, injected `open` and
  lookup): Start with Device Hub, with only Simulator and with neither; the
  capsule text, the button title, the tooltip and the banner; Show in Viewer
  for each case; menus; no Apple product names in the hub's words. Shots
  `mac-hub-simctl-running.png` and `mac-hub-simctl-no-viewer.png` (with
  `YCODE_B5_SHOTS`).
