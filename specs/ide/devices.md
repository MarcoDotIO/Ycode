# Devices and Simulators window (read-only)

Ycode module: `YcodeUI` (`DevicesList`, `DevicesController`).

Correction (2026-10-19): the reference has no Window ▸ Devices and
Simulators item. The window opens from Product ▸ Destination ▸ Manage
Devices… (⇧⌘2) and from the destination menu's "Manage Devices…"
(`reference-ui-4.md` §14.3, `reference-ui-5.md` §2.9). What that command
opens in the reference (a window or the "Device Hub" tool listed in Xcode ▸
Open Developer Tool) is still to observe. Ycode's window: a Devices /
Simulators switch, a list, and the selected entry's details. Ycode never boots, pairs,
installs on, or otherwise operates a device or simulator.

Update (OBS-DEVHUB, 2026-10-28): in the reference, Manage Devices… opens
**Device Hub** (Apple's documentation, level 1). Device Hub's window, which
this window should come to resemble (sidebar with Available / Unavailable
sections, canvas, Settings / Reports / Info inspector, compact device
windows), is specified in `specs/ide/device-hub.md`; its gap list (§9)
names the changes to this window and to `ycode-sim-viewer`.

Update (HUB-UI, 2026-10-28): **this window is now Ycode's Device Hub**
(`device-hub.md` "Ycode implementation"): sidebar with Available /
Unavailable sections, search and the Filter menu (All Devices, Simulators,
Physical Devices) in place of the Devices / Simulators switch; a canvas
with the selected Ycode simulator's live screen in Ycode's frame, or its
status view with Start; an inspector with Settings (the boxes below),
Reports and Info (the details below). The lists, their sources and the
details' values are unchanged; the sections below say where each control
went. Ycode now starts, shuts down and shows its own remote simulators;
other simulators and physical devices stay read-only.

## Sources

- Simulators: `xcrun simctl list -j`. `devices` maps runtime identifiers
  (`com.apple.CoreSimulator.SimRuntime.<Platform>-<major>-<minor>`) to
  device objects (`name`, `udid`, `state`, `isAvailable`,
  `deviceTypeIdentifier`). Runtime versions come from `runtimes[]`
  (`identifier`, `version`), else from the identifier; model names from
  `devicetypes[]` (`identifier`, `name`), else the identifier's last
  component. Platforms: iOS, watchOS, tvOS, visionOS (`xrOS`); others are
  skipped. Sorted by platform, name, version.
- Devices: `xcrun devicectl list devices --json-output <file> -q`.
  `result.devices[]`: `identifier`, `deviceProperties` (`name`,
  `osVersionNumber`), `hardwareProperties` (`platform`, `reality` —
  only `physical` entries are listed —, `marketingName`, `productType`),
  `connectionProperties` (`pairingState`, `tunnelState`). Sorted by name.

## Details

Name, Model, OS Version (`<platform> <version>`), State (simulators) or
Connection (`<pairingState>, <tunnelState>`), Identifier, Available.
Empty lists show "No Devices Connected" / "No Simulators".

*Since HUB-UI:* the inspector's Info tab, in a rounded group box: Name, OS
(`<platform> <version>`), Model, State or Connection, Identifier,
Available (and Fold, Erase for Ycode's simulators), with Edit Visibility.
Nothing selected: "No Selection" (canvas and inspector).

## Folding Ycode's remote iPhone Duo (FOLD-IMPL, 2026-10-27)

Ycode's own commands, not the reference's (Xcode 27 has its pose and rotate
controls in Device Hub, `specs/simulator/foldable.md` §4; their labels are
an open question there). A Ycode simulator row whose device type folds
(the iPhone Duo rows, `YcodeSimulatorDeviceType.isFoldable`) shows, below
its details:

- a segmented control **Closed / Half Open / Open Flat** (0°, 90°, 180°),
  a **hinge slider** 0–180° with the angle beside it, and **Rotate Left** /
  **Rotate Right** buttons;
- a **Fold** detail row: the angle and preset ("180° (Open Flat)"),
  "Unknown" while it is being read, "Closed when it boots" for a device
  that is not running (every boot starts closed), and **Fold Status** with
  the last command's result;
- the same presets (with a check mark on the current one) and Rotate
  Left / Right at the top of the row's context menu, above Erase All
  Content and Settings….

*Since HUB-UI:* the segmented control, the slider and the two rotate
buttons are gone from the details; the poses are the canvas's [Rotate │
Closed · Partially Open · Open] buttons (the reference's labels;
`device-hub.md` §4.4), Option-drag shows the hinge slider, and the context
menu and Info's Fold row use "Closed", "Partially Open", "Open". With a
live display the canvas sends them over the display stream; without one
(the forward not up yet) through the control socket as below.

The controls are enabled only while the row's device runs ("Booted") and no
command is in flight. Each sends one command through ssh: `ycode-sim
--device <dev> --control fold <angle>` or `rotate left|right`
(`foldable.md` §10.1); the reply goes to the console. Selecting a running
foldable row reads its fold (`--control state`), so the check mark follows
a restored device. Other rows (iPads, the iPhone 18 Pro, Mac simulators)
show none of this.

## Settings of a running Ycode simulator (FEAT-IMPL, 2026-10-27)

The reference puts these controls in Device Hub's inspector
(`specs/simulator/simulator-features.md` §7.1). Ycode shows them under a
Ycode simulator row's details, in three boxes, each row with a leading
symbol, in §7.1's order and with its labels:

1. **Appearance** pop-up (Light, Dark); **Liquid Glass** slider (opacity
   0–1; the runtime reports one look, so no look pop-up); **Color Filter**
   pop-up (None, Red/Green (Protanopia), Green/Red (Deuteranopia),
   Blue/Yellow (Tritanopia), Grayscale); **Text Size** slider with 12
   steps (its tooltip names the size); **Reduce Motion**, **Increase
   Contrast**, **Show Borders**, **Reduce Transparency**, **VoiceOver**
   switches.
2. **Location** pop-up: None; the 14 places; a "Trips" header with City
   Run, City Bicycle Ride, Freeway Drive; Apple; Custom Coordinates… (a
   sheet with Latitude and Longitude fields). The guest cannot report the
   simulated location, so the pop-up shows the item last chosen for that
   row (None after a boot; location does not persist).
3. **Sound** slider (0–100); **Output** and **Input** pop-ups: None,
   System (the host default), then the host devices Ycode's audio service
   offers (one output, "Ycode Simulator Output"; no input device).

A row whose device is not running shows "Start the simulator to customize
behavior and appearance." instead. While the device runs, selecting the row
reads its settings (`--control settings`: one line per setting, the audio
choices, the agent's pid); "Reading the device’s settings…" shows until the
answer arrives, and the controls are disabled until then and while a
command is in flight. Each change is one ssh call of the launcher,
`ycode-sim --device <dev> --control ui|accessibility|location|audio …`
(the grammar is `YcodeSimFeatures.SimSettingsCommand`), followed by a new
read. A failure shows an alert titled as the reference's ("Failed to Set
Appearance", "Failed to Set Liquid Glass", "Failed to Set Color Filter",
"Failed to Set Text Size", "Failed to Set Reduce Motion", "Failed to Set
Increase Contrast", "Failed to Set Reduce Transparency", "Failed to Set
VoiceOver", "Failed to Set Volume", "Failed to Set Location"; Ycode adds
"Failed to Set Show Borders", "Failed to Set Output", "Failed to Set
Input") with the device's message. The boxes scroll when they are taller
than the pane. *Since HUB-UI:* they are the inspector's Settings tab
(`settingsPaneWidth`, the inspector's width less its insets); other rows
show "No settings are available for the selected device. …". The fold controls of an iPhone Duo row stay above them;
further device boxes (the camera's toggle, CAMERA-GUEST) go after Sound
in the same stack.

Code: `YcodeUI` `DevicesController+Settings.swift`
(`DeviceSettingsSnapshot`, `settingsControls()`, `applySetting`),
`WorkspaceWindowController+RemoteDevice.swift` (`deviceSettings`).
Tests: `SimulatorSettingsUITests`.

## Camera of a Ycode simulator (CAMERA-GUEST, 2026-10-28)

Ycode's own control (the reference simulator has no camera,
`specs/simulator/camera.md` §1). In Device Hub, a Ycode simulator's
**Settings** tab shows, under FEAT-IMPL's boxes (§Settings), a **Camera**
box: a camera symbol, the label, a pop-up (Off, Host webcam, Synthetic
pattern) with Settings ▸ Simulators' camera help text as its tooltip, and
the note "Applies the next time the simulator boots." It is shown whether
or not the device runs. It is the same setting as Settings ▸ Simulators ▸
Camera (`specs/ide/run.md`; defaults key `Ycode.remote.camera`), shared by
every Ycode simulator: choosing a value marks it chosen, so every later
run passes `--camera off|on|synthetic`, and the device takes it when it
boots (the warm-boot fingerprint includes it, so the change boots cold
once). Other simulators and devices do not show it.

Code: `YcodeUI` `DevicesController+Camera.swift` (`cameraSetting(_:)`,
`cameraControls()`, `chooseCamera(_:)`), the Settings tab in
`DevicesController.updateInspector()`,
`WorkspaceWindowController+RemoteDevice.swift`. Tests: `CameraDevicesTests`.

## Evidence

- Correction 2026-10-19: no Window-menu item; Product ▸ Destination ▸ Manage Devices… ⇧⌘2 (`reference-ui-5.md` §2.9, level 3, menu bar read through the accessibility API).
- Command lines and JSON keys: the tools' JSON output studied as a format
  (level 2/3), the same keys `YcodeBuild.DestinationCatalog` reads.
  Tests use synthetic JSON only.
- Window layout: Apple's public documentation for the Devices and
  Simulators window (level 1).
- Camera control: Ycode design (`specs/simulator/camera.md` §9); `CameraDevicesTests`.
- Fold controls: Ycode design (`foldable.md` §8.3, §10); `FoldControlsTests`.
- Device Hub window, grouping and pose-control labels: `device-hub.md` (levels 1, 3).
- Device Hub layout, Start / Shut Down, the live display: `device-hub.md`
  "Ycode implementation" (levels 1, 3 there; Ycode decisions); tests
  `FoldControlsTests`, `OrganizerTests`, `SimulatorSideR37Tests`,
  `YcodeDeviceUITests`, `YcodeDeviceModelTests`.
- Settings boxes: labels, order, alert titles and the stopped message from
  `specs/simulator/simulator-features.md` §7.1 (level 3/4 there); layout,
  Ycode's extra alert titles and the location pop-up's memory are Ycode
  design; `SimulatorSettingsUITests`.
- OPEN QUESTION: the reference's grouping (connected / discovered),
  device screenshots and logs, and runtime management.
