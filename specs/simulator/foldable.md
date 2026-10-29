# Spec: folding and unfolding the iPhone Duo

Status: **proposed** (OBS-FOLD, 2026-10-27); Ycode implementation in §10
(FOLD-IMPL, 2026-10-27: hinge input works end to end into the guest's
relay; the inner panel was blocked by §9 Q7 and stays behind a switch;
OBS-FOLD2, 2026-10-27: Q7 answered, the `displays` capability; FOLD2,
2026-10-27: Ycode's iPhone Duo unfolds, §10.4). It tells a clean agent how the
reference simulator folds and unfolds the iPhone Duo (iOS 27.1, `iPhone19,4`,
product class V68) and what Ycode must build so its iPhone Duo can do the
same. Observations behind it: `research/notes/obs-fold-2026-10-27.md`. It
builds on `hid-input.md` (Ycode's HID bundle and host transport),
`simframebuffer.md` (displays), `home-apps.md` §2.2, `iphone-types.md` §3.3
and `device-capabilities.md`; it does not repeat them.

Terms: **cover** = the outer display `LCD`; **inner** = the folding display
`LCD-1`; **hinge angle** = 0° closed … 180° open flat; **guest** = the
simulated iOS; **relay** = the device-state relay inside the guest's
`locationd` (CoreMotion), which turns host input into hinge and pose events.
**Ycode decision** marks design choices.

## 1. Summary

1. The fold state is **not a display setting**. Both built-in displays stay
   connected and powered in every state. The host sends **one input, the hinge
   angle** (plus device orientation). Everything else (which display is lit,
   the swap animation, interface orientation, moving apps) is done by the
   guest's own SpringBoard.
2. The angle travels as a **vendor-defined HID event** (usage page 0xFF61,
   usage 0x5B) from a guest HID service with that usage pair. Its data is a
   small dictionary in IOKit's text serialization: `source`
   `hinge-slider-control`, `type` `range`, `value` = whole degrees (§5).
3. The relay converts it into a hinge-angle event (0xFF0C/0x21) and a
   device-state event (0xFF0C/0x22) that CoreMotion clients read. SpringBoard
   then switches between **FullyClosed** (cover primary, inner off) and
   **FoldingDual** (inner primary, cover auxiliary/dark) (§6).
4. Unfolded with the device upright, the inner display shows a **landscape**
   UI (951 × 669 points), because the inner panel is mounted at 270° (§2).
5. A running app's scene **moves** from the cover screen to the inner screen
   (same scene, new screen, new size and orientation); it is not relaunched.
6. The state is **not persisted**: every boot starts closed (§7).
7. Xcode 27's own controls are in **Device Hub** (there is no Simulator.app):
   a pose control and rotate buttons for V68 devices, with a hinge slider and
   tabletop controls only in an Apple-internal action bar (§4; level 4 only,
   not seen on screen). `simctl` has no fold command.

## 2. The two displays

From the device type's `capabilities.plist` (`displays`), `simctl io
enumerate`, and the guest's logs:

| | Cover | Inner |
|---|---|---|
| Display name / device name | `LCD` / `primary` | `LCD-1` / `primary-1` |
| Screen ID (framebuffer id) | 1 | 3 |
| Pixels (framebuffer, portrait) | 1398 × 2034 | 2007 × 2853 |
| Scale, dpi, refresh | 3, 460, 60 Hz | 3, 460, 60 Hz |
| Points (SpringBoard) | 466 × 678 | 669 × 951 (panel), 951 × 669 as seen unfolded |
| Colorspace, surface type | P3, 1 | sRGB, 2 |
| Native orientation / rotation | 0 / 0 | **270 / 270** |
| Corner radii (UL, LL, UR, LR) | 8, 8, 59, 59 (left edge is the hinge side) | 55 each |
| Chrome identifier | `phone15` | `phone14` |
| Mask identifier | `1C896A2B-F0D7-405C-8D0F-66E4B80AD044` | `BF0DC480-5EE2-4EC1-B02B-C75E94759832` |
| Digitizer | yes; guest touch service `ScreenTouchService.<cover UUID>` | yes; `ScreenTouchService.<inner UUID>` |
| Initial power state | 1 (on) | 1 (on) |
| SpringBoard name for it | "Main", surface `.cover` | "Unknown.main[3]", surface `.inner` |

The guest identifies the panels by their display UUIDs (the framebuffer
display UIDs). `SIMULATOR_MAINSCREEN_*` describes the cover.

## 3. States

### 3.1 The hinge angle

- Range 0–180°, as `devicectl device motion hinge-angle` reports it ("Range:
  0-180"); a fresh device reads 0.0 (angle and mechanical angle).
- The relay classifies the angle into a **hinge state**: closed at 0°;
  partially open for every tested angle from 5° to 175°; open flat at 180°.
  The boundary between partially open and open flat lies in (175°, 180°].

### 3.2 Postures the reference names

| Name (Device Hub, CoreDevice) | Angle | Guest result |
|---|---|---|
| `closed` | 0° | FullyClosed: cover on, inner off |
| `partiallyOpen` ("half open", "bent"; the guest's display tool calls about 100° "book") | between | after an opening sweep: inner on (landscape); after a closing sweep from open: inner stays on down to about 80° |
| `openFlat` | 180° | inner on (landscape) |

Device orientation is a second, independent input (portrait, landscape
left/right, face up/down, §5.4). A **tabletop** pose and **StandBy** exist in
the host plug-ins and the relay but were not exercised (§9).

### 3.3 What SpringBoard does with the angle

SpringBoard has its own hinge model with hysteresis; the host does not
implement it, but must feed it the way the reference does:

- **Opening** from closed with a continuous sweep (several events tens of
  milliseconds apart, or one large jump): when SpringBoard's position passes
  about **90°**, it swaps to the inner display (mode `FoldingDual`, inner
  primary, cover auxiliary) and the interface orientation changes from
  portrait to **landscapeLeft**. A quick sweep that stops at 40° starts the
  transition and then falls back: the cover stays primary.
- **Closing** from open with a sweep: the swap back to the cover happens when
  the position passes about **80°**; at 0° the mode becomes `FullyClosed`
  (inner off) and the orientation returns to portrait.
- **Fold avoidance:** stopping between about 30° and 120° after an opening
  leaves the inner display primary.
- **Slow, small steps** (5–10° every few seconds) each start a small
  transition that autocompletes back; SpringBoard then stays "closed" until
  about 170°. A host that moves the hinge must therefore **sweep**, not
  creep (§5.5).
- SpringBoard's reported angle can differ from the commanded one by a few
  degrees (its own profile and smoothing).
- **Commanded targets** (OBS-FOLD2; each move a sweep of 17 events 30 ms
  apart, as Ycode sends, §10.1): from closed, a target of 60° or 75° falls
  back to the cover; **85°** and 90° end on the inner. From open flat,
  90° and 85° stay on the inner (the closing transition starts, then falls
  back); **80°** and 75° end on the cover. So the opening boundary lies in
  (75°, 85°] and the closing boundary in (80°, 85°]. Half Open (90°) ends
  on the inner from both sides.
- *Under Ycode (FOLD2, §10.4), the same guest with the same sweeps:* an
  opening to every whole degree from 76° to 84° ends on the cover, 85° and
  more on the inner; a closing from open flat to 81°–84° ends on the cover,
  85° and 90° on the inner. Both boundaries lie in (84°, 85°] there.

## 4. Host controls in the reference

Observed only as bundle metadata (level 4); Device Hub's window was opened
but none of its controls were used (the owner stopped the session's GUI
interaction).

- **Xcode 27 has no Simulator.app.** Device Hub shows each simulator; its
  toolbar has Capture Keyboard, Resize mode, zoom buttons, Open in New Window
  and More Actions. For V68 devices a Device Hub plug-in adds a 3D device
  view (a model of the folding phone; its names suggest the hinge can be
  dragged on the model) and an
  action bar.
- **Public action bar for V68:** a **Poses** control (presets; names closed,
  partially open, open flat; landscape half-open and bent-portrait pose
  images) and a **Rotate** control (rotate left, rotate right).
- **Internal action bar** (setting "Use Internal Action Bar", Apple-internal):
  adds a **hinge slider**, more pose controls, rotate, and **Table Mode**
  ("Table Mode is not available in the current pose"; "Tabletop mode,
  keyboard shortcuts, additional pose controls.").
- **Setting "Disable Hinge Interpolation"** (internal settings section):
  "send a commanded angle to the device in one event instead of sweeping
  through the fold". So by default the host **sweeps** from the current
  angle to the target with a send interval, smoothing time and a settle
  tolerance, and watches the reported angle until it settles.
- The plug-in also reads back the device's hinge angle and the guest's
  active-display report, and decides which panel to show from the hinge
  angle, cross-checked against the reported active display and that
  display's backlight.
- **`simctl`**: no subcommand or option for fold, hinge, posture or display
  roles. `simctl io <dev> screenshot|recordVideo --display=LCD|LCD-1` selects
  a panel; `io screenConfig power|geometry` exists but is not how folding is
  done.
- **`devicectl`** (lists simulators): `device motion hinge-angle` monitors
  the angle (angle, mechanical angle, velocity, validity flags, range);
  `device orientation get|set` exists (set did not reach the guest on this
  simulator). No command sets the hinge.

## 5. The host → guest mechanism (interop facts)

### 5.1 Path in the reference

Device Hub plug-in → CoreDevice → the guest helper `dtuhidd` (a CoreSimulator
program, job `com.apple.coredevice.dtuhidd`, `hid-input.md` §1 item 5),
which owns a guest HID service named `avpCustom` with usage pair
**0xFF61 / 0x5B** (65377 / 91) and transport "CoreDevice", and dispatches the
vendor-defined event from it. (This hop is inferred from names; the
consumer side below was observed.)

### 5.2 The event

| Field | Value |
|---|---|
| Event type | vendor-defined |
| Usage page / usage | 0xFF61 / 0x5B (as the sending service's primary pair) |
| Version | 0 |
| Data | IOKit text serialization of one dictionary (§5.3), no terminator required |
| Sender | any guest HID service whose primary usage pair and `DeviceUsagePairs` are 0xFF61 / 0x5B. A client-side virtual service with properties `PrimaryUsagePage`, `PrimaryUsage`, `DeviceUsagePairs`, `Transport` ("Virtual" worked) and `Product` was accepted. |

backboardd logs it as "VendorDefinedEvent usagePage:0xFF61 usage:91". The
relay in `locationd` subscribes to services with that usage pair, reads the
data, and logs "Received AVP event", "Processing AVP event - Source: …,
Type: …".

### 5.3 The data: dictionary and serialization

Serialization: IOKit's CF text serialization (the format of IOKitUser's
`IOCFSerialize`, open source; the reader is `IOCFUnserialize`). A
dictionary is written as a `dict` element containing alternating `key`
elements and value elements; strings as `string` elements; integers as
`integer` elements with a `size` attribute (`32` or `64`) and hexadecimal
text (for example 90 is written as the text `0x5a`). Key order does not
matter. The serializer turns a floating-point number into a 64-bit integer,
so the angle arrives in **whole degrees**.

| Key | Hinge | Orientation |
|---|---|---|
| `source` | string `hinge-slider-control` | string `orientation-picker-control` |
| `type` | string `range` | string `enum` |
| `value` | integer, degrees 0–180 | string: `portrait`, `landscape-left`, `landscape-right`, `faceup`, `facedown`, `ambiguous` |

`portrait-upside-down` (and any other string) is rejected ("Unknown
orientation"). A missing `source` or `type` is rejected. A third input,
**standby**, is read by the relay but was not exercised.

### 5.4 What the relay sends on

When all inputs are known (they are at boot: angle 0, portrait, standby off)
the relay builds a device state and dispatches two events from its own guest
virtual services:

| Service (product) | Usage pair | Content |
|---|---|---|
| `CoreMotion_DeviceStateRelay_Crane` | 0xFF0C / 0x21 | hinge-angle event: angle, mechanical angle (equal to the input), velocity 0 |
| `CoreMotion_DeviceStateRelay_DeviceState` | 0xFF0C / 0x22 | device-state report: orientation code (0 ambiguous, 1 portrait, 3 landscape left, 4 landscape right, 5 face up, 6 face down), per-surface orientation (cover / inner; inner is ambiguous while closed), hinge state (1 closed, 2 partially open, 3 open flat), tabletop (0 here) |

CoreMotion clients (SpringBoard, sharingd, `dtdeviceinfod`) receive them as
CMMagicPose events (`hingeState: Closed | PartiallyOpen | OpenFlat`). The
relay is part of the runtime; Ycode runs it unchanged.

### 5.5 Order and timing

- One event carries one value; the relay keeps the latest angle and the
  latest orientation.
- To fold or unfold, the reference host sends a **sweep** of angle events by
  default (§4). A sweep of 20 events 30 ms apart (0→180 or 180→0) produced
  clean swaps in both directions; one 0→90 jump also swapped.
- The relay and CoreMotion react within about 50 ms of the event;
  SpringBoard starts the swap within about 0.3 s and completes it, with the
  orientation change, within about 1 s.

## 6. What the guest shows in each state

| | Closed (0°) | Opened past the swap point (e.g. 90°, 100°, 180°) |
|---|---|---|
| SpringBoard display-content mode | `FullyClosed` (cover `pri`, inner `off`) | `FoldingDual` (inner `pri`, cover `aux`) |
| Cover screenshot | home screen / app, portrait, 1398 × 2034 | black |
| Inner screenshot | black | home screen / app, landscape (the PNG from `simctl io screenshot` is 2853 × 2007) |
| Interface orientation (device upright) | portrait (1) | landscapeLeft (4); `simctl io enumerate` shows "UI Orientation: Landscape Left" for both built-in displays |
| Backlight (guest BacklightServices) | cover on, inner off | inner Off→ActiveOn, cover off |
| Host display ports | all powered on, connected | unchanged |
| Inner home screen | — | landscape layout with widgets on page 1 (Batteries, Screen Time) beside the apps |

**Running app.** A foreground app follows the swap. Its scene keeps its
session; UIKit logs "Scene did move screens" from the cover's screen to the
inner's, disconnects the old screen object, switches the orientation mode
to "all" and changes the interface orientation to landscapeLeft.
SpringBoard sets the scene to the inner display with bounds 669 × 951
points (landscape-left, so 951 × 669 as seen). Settings showed its
two-column layout there. Folding back moves it to the cover and portrait.

**Orientation input alone** (folded) changes CoreMotion's device orientation
(MagicPose LandscapeLeft, …); the portrait-only home screen did not rotate.

## 7. Persistence

None in the guest. A device rebooted while open flat came up closed (angle
0, cover home screen, inner black). `device.plist` has no fold key and no
guest preference file mentions hinge or fold. Whether Device Hub re-sends its
last pose after a boot was not observed.

## 8. What Ycode must do

### 8.1 Displays (`simframebuffer.md`, viewer)

- **D1.** For the iPhone Duo identity, the framebuffer library publishes the
  **second built-in display** with the values of §2 and
  `simframebuffer.md` §4 (id 3, type 0, `LCD-1`, `primary-1`, 2007 × 2853 @3,
  460 dpi, power 1, flags 1, its own stable UID) and accepts a swapchain on
  it, as on display 1. backboardd then creates a swapchain for it as for
  every type-0 display. Both displays exist from boot; folding never
  connects or disconnects a display and never changes a power state.
- **D2.** The library accepts per-display backlight and UI-orientation calls
  (`SFBDisplaySetBacklightState`, `SFBDisplaySetCurrentUIOrientation`) and
  reports them to the viewer. A display that is backlight-off, or that gets
  no frames, is shown black.
- **D3.** The viewer shows the **active panel**: the cover while folded, the
  inner while open. Ycode decision: decide from the hinge angle Ycode last
  commanded and the side of the swap SpringBoard ended on (cover below about
  80–90°, inner above), and confirm with the guest's backlight state and
  which display receives frames, as the reference host does (§4). Ycode may
  also offer a side-by-side view of both panels.
- **D4.** The viewer rotates each panel's image by the panel's current UI
  orientation (the inner panel's framebuffer is portrait, its upright UI is
  landscape-left). Screenshots per panel follow `simctl io screenshot
  --display=LCD|LCD-1` (rotated to the UI orientation).
- **D5.** Masks and corner radii per panel (§2) for the viewer's chrome.

### 8.2 Input (`hid-input.md`)

- **I1.** The Ycode HID bundle publishes a **touch-screen service per
  built-in display**, each with that display's `displayUUID`
  (`hid-input.md` §4.3, §6), and the viewer sends touches to the service of
  the panel it shows.
- **I2.** The bundle publishes one more service, **device-motion control**:
  primary pair 0xFF61 / 0x5B, `DeviceUsagePairs` with that pair, a `Product`
  string, transport "Virtual". Ycode decision: service ID
  `0x59434F4400000004` (next after `hid-input.md` §4.1's IDs). It never
  answers `copyEvent`.
- **I3.** New host→guest message kinds on Ycode's HID transport
  (`hid-input.md` §7): **hinge angle** (integer degrees 0–180) and
  **device orientation** (one of the six strings of §5.3). For each, the
  bundle builds the dictionary of §5.3, serializes it in the IOKit text
  format (the runtime's IOKit exports the serializer; Ycode may also write the
  three-key text itself), and dispatches one vendor-defined event, usage page
  0xFF61, usage 0x5B, version 0, guest timestamp, from the service of I2.
- **I4.** The host sends a **sweep** to change the fold: from the current
  angle to the target in steps about 30 ms apart over about 0.5 s (Ycode
  decision, matching §5.5), ending exactly on the target. An "instant"
  option sends only the target (the reference's "Disable Hinge
  Interpolation").
- **I5.** At boot the host's model is angle 0 and portrait (the relay's own
  defaults); Ycode sends nothing until the user changes the fold. Ycode
  decision: the host resets its fold state to closed on every boot (§7).

### 8.3 IDE and command line

- **E1.** Device ▸ Fold controls for foldable device types (those whose
  device type lists two integrated displays): **Closed** (0°), **Half Open**
  (90°; the reference's partially open / "book" pose), **Open Flat**
  (180°), plus a hinge slider 0–180° (the reference has the slider only in
  an internal action bar; Ycode decision to expose it). Each preset sends a
  sweep (I4). Rotate Left / Rotate Right send device orientation.
- **E2.** The fold controls are disabled while the device is not booted and
  show the current state as a check mark (Ycode's own state; the guest does
  not report a posture back through any channel Ycode uses today).
- **E3.** `ycode-simctl io <dev> screenshot --display=LCD|LCD-1` as in the
  reference; a Ycode command to set the fold (for example `ycode-simctl
  fold <dev> closed|half|open|<degrees>`) — Ycode decision, the reference
  has none.
- **E4.** No new environment variable and no device-plist key is needed;
  the guest learns that it is a foldable from the device identity (model
  `iPhone19,4`, product class V68) and from the two displays. *Correction
  (FOLD-IMPL, §10.2; OBS-FOLD2, §9 Q7): not sufficient. The panels'
  surface types come from the `displays` array of the capabilities file
  (`device-capabilities.md` §3.1), which Ycode must write.*

### 8.4 Test plan

1. Boot an iPhone Duo in Ycode: cover shows the home screen, inner black,
   relay logs a device state with hinge closed.
2. Sweep 0→180: SpringBoard logs `FullyClosed→FoldingDual`, the inner shows
   the landscape home screen, the cover is black, `UI Orientation` is
   landscape-left.
3. Sweep 180→0: back to `FullyClosed`, portrait cover.
4. Sweep 0→40: stays on the cover. Sweep 0→100: inner.
5. Launch Settings folded, unfold: the same process continues on the inner
   panel in landscape.
6. Touches on each panel land on that panel.
7. Reboot while open: comes up closed.

## 9. Open questions

1. Device Hub's visible labels, menu items, shortcuts and enabled states for
   the pose and rotate controls; whether it re-sends the pose after a reboot.
2. The CoreDevice → `dtuhidd` message that carries the payload (Ycode does
   not need it; it publishes its own service, §8.2).
3. Standby input: where the relay reads it and what the host sends; tabletop
   pose (`coredevicepop.v68.tabletop`).
4. Whether the guest calls `SFBDisplaySetBacklightState` on the panel it
   turns off, or only stops drawing (decides how D2 is exercised).
   *Partly answered (OBS-FOLD2, level 3):* the guest does switch panel
   backlights. backboardd logs "Setting CoreBrightness backlight
   factor:<f>" (without naming the panel): factor 1 twice at boot (one per
   panel), factor 0 a few seconds after `FullyClosed` (inner off); at every
   swap, and at every transition that falls back, factor 1 0.1–1.4 s after
   the transition starts (the incoming panel) and factor 0 0.3–4 s later
   (the panel that ends up not primary). The host's view does not change
   (`simctl io enumerate` keeps "Power state: On"; `simctl io poll` is
   silent). Whether this reaches the framebuffer as
   `SFBDisplaySetBacklightState` cannot be seen on the reference; under
   Ycode, `YCODE_FRAMEBUFFER_CALLS=1` should show the matching calls (two
   at boot are already seen, `simframebuffer.md` §3.4).
   *Answered under Ycode (FOLD2, level 3; §10.4):* **no.** backboardd logs
   the same factor changes (1 twice at boot, 0 about 40 s later, then 1 and
   0 at every swap), but no guest process calls
   `SFBDisplaySetBacklightState` (nor `SetCurrentUIOrientation`,
   `SetBrightnessFactor` or `GetMaskPath`) in a whole boot with a dozen
   swaps: the call log and both frame records show none. The calls of
   `simframebuffer.md` §3.4 come from CoreSimulator's host-side bridge,
   which Ycode does not have. The panel the guest turns off keeps getting
   frames, and they are black; that is the sign Ycode's viewer uses (D2,
   D3).
5. The exact open-flat boundary (175°–180°).
6. *Answered (§10.2, level 3 under Ycode):* a service published from
   inside backboardd (Ycode's bundle, `_IOHIDServiceCreateVirtual`) is
   matched by the relay: `locationd` logs "AVP Service added." about 10 s
   into the boot and "Received AVP event" / "Processing AVP event - Source:
   hinge-slider-control, Type: range" (and `orientation-picker-control`,
   `enum`) for every event Ycode sends.
7. *Answered (OBS-FOLD2, 2026-10-27; levels 2 and 3).* How does the guest
   learn each built-in panel's *surface* (cover / inner)? Under Ycode, with
   both panels published, SpringBoard reports surface `.default` for both
   ("display power required: NO surface: .default") and stops with
   "ManagedDisplaysController.swift:38: Assertion failed: Cloning source
   already exists: <UID>" (restarted by launchd, again and again), where
   the reference has `.cover` and `.inner`.
   a. **Structure.** `displays` is a key inside the `capabilities`
      dictionary of the file named by `SIMULATOR_CAPABILITIES`: an array of
      five dictionaries (`LCD` and `LCD-1` of type `integrated`, `TVOut`
      `tvOut`, `Wireless` `carPlay`, `Resizable` `scene`). Every key, value
      type and value is in `device-capabilities.md` §3.1. Only the two
      `integrated` entries carry `surfaceType` (integer; `LCD` 1, `LCD-1`
      2), `nativeOrientation`/`nativeRotation`, corner radii, chrome and
      mask identifiers. No other `capabilities` key names a surface or the
      second panel (`ScreenDimensionsCapability`, `MainScreenClass`,
      `DeviceCornerRadius`, `displayGamut` describe the cover only).
   b. **The guest reads it.** `SIMCTL_CHILD_SIMULATOR_CAPABILITIES` on
      `simctl boot` changes the path in every guest process, while the
      host's displays stay as the device type says. Results:
      - copy without `displays`: both surfaces `.default`, SpringBoard
        crashes again and again (crash reports: Swift assertion in
        SpringBoard's managed-displays controller, on a scene's
        cloning-source update) — **the same failure as Ycode**;
      - copy without the two `surfaceType` keys: the same failure;
      - `surfaceType` values swapped (LCD 2, LCD-1 1): no failure, but the
        roles swap: `Main` is `.inner`, `Unknown.main[3]` is `.cover`, and
        the closed state shows the home screen on `LCD-1` (portrait) with
        `LCD` black;
      - an `integrated` entry that lacks `chromeIdentifier`,
        `framebufferMaskIdentifier` or the four corner radii is ignored
        (same failure); `colorspace` and `refreshRate` may be left out;
        the `tvOut`, `carPlay` and `scene` entries are not needed.
      So surface 1 = `.cover`, 2 = `.inner`, missing = `.default`, read
      from the panel's own complete `integrated` entry.
      Not determined: how the guest pairs an entry with a framebuffer
      display (entries holding only `displayName`, only `screenID`, or
      `displayType` + names + `screenID` with `surfaceType` were all
      ignored, because incomplete). On the reference the host's displays
      carry the same names, ids and mask (`simctl io enumerate`: "Mask ID",
      "Mask URL" naming the mask identifier). If Ycode's boot with the full
      array still shows `.default`, check first that Ycode's framebuffer
      displays agree with the entries (name, device name, id, size), then
      the mask path Ycode reports (`SFBDisplayGetMaskPath`, NULL today).
   c. No guest log names the reader. MobileGestalt does not answer a
      question named `displays` (our probe's `MGCopyAnswer` returned
      nothing; `DeviceCornerRadius` answered). The file itself is the
      input; Ycode needs no other channel.
   Also: on the reference, BacklightServices logs `surfaceType:0` for both
   panels too, and the inner panel's ShellSceneKit root is of kind
   `bringupDisplay` too; neither is part of the failure.
   **Ycode:** write the whole `displays` array into
   `DEV/ycode-capabilities.plist` for the iPhone Duo
   (`device-capabilities.md` §3.1) and turn `YCODE_FOLD_DISPLAYS` on by
   default (§10.3).

## 10. Ycode implementation (FOLD-IMPL, 2026-10-27)

Clean-room work from this spec, `hid-input.md`, `simframebuffer.md`,
`display-stream.md` and IOKit's open-source serializer format; Ycode boots
on the Thor only.

### 10.1 What is built

| Piece | Where | What |
|---|---|---|
| Device type | `ycode-simd/DeviceTypes.swift` | the iPhone Duo's `secondDisplay`: id 3, `LCD-1` / `primary-1`, 2007 × 2853 @3, 460 dpi, UID `59434F44-4500-4000-8000-000000000003` (Ycode's own, stable), mounted at 270°; a type with one is *foldable* |
| Displays (D1, D2) | `SimGuestFrameworks/SimFramebuffer` | with `YCODE_FRAMEBUFFER_SECOND_DISPLAY` ("<id> <name> <device name> <w> <h> <scale> <pitch> <uid>") the library publishes the reference's five-display list of `simframebuffer.md` §4 — `LCD` 1, `TVOut` 2, `LCD-1` 3, `Wireless` 4, `Resizable` 5 — with the values of that table (the three others powered off, no swapchain asked for); `LCD-1` takes a swapchain like display 1. Backlight and UI-orientation calls are kept per display. `simframebuffer.md` §10 |
| The switch | `DeviceMode.swift` | `ycode-simd` sets that variable only with **`YCODE_FOLD_DISPLAYS=1`** in its environment, because of §9 Q7; by default the iPhone Duo publishes its cover display only, as before. *Since FOLD2 (§10.4): on by default for foldables, with the `displays` capability; `YCODE_FOLD_DISPLAYS=0` turns both off* |
| Hinge and orientation input (I2, I3) | `SimGuestFrameworks/SimHID`, `HIDHostService.swift` | the device-motion service `0x59434F4400000004` (primary pair 0xFF61/0x5B, `DeviceUsagePairs`, `Product` "Ycode Device Motion", `Transport` "Virtual"), published for every foldable (`YCODE_SIMHID_DEVICE_MOTION=1`); host messages kind 6 (hinge angle, whole degrees) and kind 7 (orientation code of §5.4); one vendor-defined event each (page 0xFF61, usage 0x5B, version 0). The data is written by the runtime's own `IOCFSerialize` (found with `dlsym`; the bundle writes the same text itself if it is missing). `hid-input.md` §15 |
| Touch per panel (I1) | SimHID | with a second display, a second touch screen `0x59434F4400000005` with that display's `displayUUID`; touch messages name the display (0 cover, 1 inner) |
| HID bundle | `InputBridge.swift` | a foldable boots with the HID bundle (as with `--display-server`); `--hid-bundle none` still turns it off |
| Fold model and sweep (I4, I5) | `ycode-simd/FoldModel.swift`, `FoldControl.swift` | the host keeps the angle it last sent (0 at every cold boot), the orientation (portrait) and the panel it expects (opening to 90° or more → inner; closing to 80° or less → cover; §3.3; *85° since FOLD2*). A move is a sweep of 17 messages 30 ms apart (0.5 s) ending exactly on the target, or one message with `instant`; a new move replaces one in progress. The model is kept in the memory directory's `fold.state`: a cold boot starts without it (closed), a warm-boot restore gets it back with the device (`snapshot.md`), so host and guest agree |
| Control socket (E3) | `FoldControl.swift` | every device run serves `<memory file system>/ycodectl-<uid>-<id>.sock` (mode 0600; `/dev/shm` by default), one text command a connection: `fold closed\|half\|open\|<0–180> [instant]`, `orientation portrait\|landscape-left\|landscape-right\|faceup\|facedown`, `rotate left\|right`, `state`, `screenshot LCD\|LCD-1\|active <path.png>`; replies start with `ok` or `error` |
| Command line (E3) | `main.swift`, `scripts/ycode-sim.sh` | `ycode-simd --device DEV --fold closed\|half\|open\|<deg> [--instant]`, `--orientation <name>`, `--rotate left\|right`, `--fold-state`, `--control <command…>`; the launcher passes these straight to `ycode-simd` (no boot slot), so the IDE's ssh command is `ycode-sim --device DEV --control fold half` |
| Screenshots (D4) | `ScreenCapture.swift`, `--display LCD\|LCD-1\|active` | `--screenshot`/`--screenshot-at` and the control socket take one panel, turned to its upright UI (the inner panel's image 90° clockwise: 2853 × 2007); default `active`, the panel shown |
| Which panel is shown (D3) | `FoldModel.swift` `activePanel` | the model's panel, unless the guest set that panel's backlight to 0 while the other one is lit (from the frame records); *since FOLD2 also unless that panel's latest frame is black while the other's is not (§10.4)* |
| Display stream | `display-stream.md` §11 | display-state message (0x07: panel, size, turn, hinge, posture, orientation), fold message (0x89), rotate (0x88) carried out for foldables; frames, touches and screenshots follow the panel shown |
| Viewer | `ycode-sim-viewer` | for a foldable: a fold bar (Closed / Half Open / Open Flat, a hinge slider 0–180°, Rotate Left / Rotate Right), Device ▸ Fold ▸ Closed ⌥⌘1 / Half Open ⌥⌘2 / Open Flat ⌥⌘3 with a check mark, Rotate Left ⌘← / Right ⌘→; the picture is turned by the panel's turn and touches are mapped back to the panel's own points; script commands `fold`, `rotate`, `wait-display` |
| IDE | `specs/ide/devices.md` | Devices and Simulators (Ycode's Device Hub equivalent): the same presets, slider and rotate buttons, and the same items in the row's context menu, only on Ycode simulator rows whose device type folds (the iPhone Duo rows), enabled while the device runs |

### 10.2 Results on the Thor (iOS 27.1, iPhone Duo)

- **Input reaches the relay (Q6).** `backboardd`: "VendorDefinedEvent
  usagePage:0xFF61 usage:91" for each message; `locationd`: "AVP Service
  added." at boot, then "Received AVP event" and "Processing AVP event -
  Source: hinge-slider-control, Type: range" 30 ms apart during a sweep,
  and "Source: orientation-picker-control, Type: enum" for orientations.
  The runtime exports `IOCFSerialize`; its text for 90° is
  `<dict><key>type</key><string>range</string><key>value</key><integer
  size="64">0x5a</integer><key>source</key><string>hinge-slider-control</string></dict>`
  followed by a NUL byte (sent as is).
- **With one display (the default):** the relay produces no device state
  (SpringBoard never logs a hinge state or a MagicPose event, before or
  after input) and the cover keeps showing, also after Open Flat; Settings
  launched folded stays on the cover. Every boot of this round reached the
  home screen and launched Settings (the iPhone 18 Pro on 27.0 too). Some
  boots, with this build and with the main line's alike, had one early
  SpringBoard restart ("we must have a remote target", BaseBoard) before
  the home screen; it is not related to folding.
- The viewer's and the IDE's controls are covered by unit tests
  (`FoldControlsTests`, `DisplayStreamFoldTests`); no viewer session was
  run in this round.
- **With the inner panel (`YCODE_FOLD_DISPLAYS=1`):** the relay works
  ("Hinge state changed from .unknown to .closed", "CMMagicPose surface
  orientation changed: cover Am -> Po, inner Am -> Am", "Swap boundary 0.0°
  -> 85.0°") and SpringBoard names the panels "Main" and
  "Unknown.main[3]" as on the reference, but stops on the cloning-source
  assertion of §9 Q7 before the home screen. With only `LCD` and `LCD-1`
  published (no TV-out between them) the inner panel was
  "Unknown.main[2]" and the assertion named the inner UID instead of the
  cover's; with the five displays it names the cover's. Both show the
  panel surfaces as `.default`.
- So §8.4 items 2–6 (the swap, the landscape inner home screen, the moving
  app, touches on the inner panel) are **not yet verified**; they wait for
  Q7. *Verified since (FOLD2, §10.4).*

### 10.3 After Q7

Write the `displays` capability (Q7 answered: `device-capabilities.md`
§3.1, all five entries with all their keys) for the iPhone Duo,
make `YCODE_FOLD_DISPLAYS` the default for foldables (`DeviceType.
publishedSecondDisplay`), then run §8.4. Still to check then: whether the
guest calls `SFBDisplaySetBacklightState` on the panel it turns off (Q4;
the frame records and `YCODE_FRAMEBUFFER_CALLS=1` show it), the direction
of the inner panel's turn (Ycode's choice, 90° clockwise, is to be checked
against the reference's 2853 × 2007 screenshot), and Half Open's swap
thresholds against the model.

*Reference answers (OBS-FOLD2, level 3):*

- **Turn direction.** The reference's raw recording of `LCD-1` while open
  (`simctl io recordVideo --display=LCD-1`) stores portrait frames (the
  framebuffer's 2007 × 2853, rounded down to even sizes by the encoder)
  with a −90° display matrix, i.e. "show turned 90° clockwise". The stored
  frame is the upright landscape image turned 90° counter-clockwise (the
  framebuffer's top edge is the upright image's right edge). So turning
  the inner framebuffer **90° clockwise** gives the upright 2853 × 2007
  image: Ycode's choice matches. Upright check: widgets on the left, the
  clock at the top right, Safari at the right edge, search at the bottom
  right.
- **Thresholds.** §3.3 "Commanded targets": the model's "opening to 90° or
  more → inner; closing to 80° or less → cover" agrees with the reference
  for the presets (Closed, Half Open 90°, Open Flat) and for 75° and 80°
  closing; it is wrong for an opening to **85°** (the reference ends on the
  inner). Ycode decision for the model: opening to **85°** or more →
  inner (instead of 90°); closing to 80° or less → cover (unchanged).
  Targets of 76–84° opening and 81–84° closing were not measured; there
  the backlight check of D3 decides.
- **Backlight.** Q4: the guest switches each panel's backlight at every
  swap; check the framebuffer calls under Ycode.

### 10.4 FOLD2: the iPhone Duo unfolds (2026-10-27)

Clean-room work from §9 Q7, §10.3 and `device-capabilities.md` §3.1;
Ycode's own simulator on the Thor only (iOS 27.1 runtime 24A94401).

**What changed**

| Piece | Where | What |
|---|---|---|
| `displays` capability | `ycode-simd/DeviceTypes.swift` (`DisplayEntry.iPhoneDuo`, `CapabilityValue.array`) | the iPhone Duo's five entries with every key and plist type of `device-capabilities.md` §3.1, inside `capabilities` of `DEV/ycode-capabilities.plist`; the `LCD-1` entry is built from the same record as the published second display, so names, ids and sizes agree. Written only together with the inner panel |
| Inner panel by default | `DeviceType.foldDisplaysEnabled` | on for every foldable; **`YCODE_FOLD_DISPLAYS=0`** in `ycode-simd`'s environment publishes the cover only and writes the old capabilities file (no `displays`) |
| Mask | — | **Ycode decision: no mask file.** The guest never calls `SFBDisplayGetMaskPath` (which stays NULL) and accepts the entries with the mask and chrome identifiers as plain strings: SpringBoard reports `.cover` and `.inner`. Ycode ships and generates no mask; a viewer that wants rounded corners can draw them from the corner radii of the entries |
| Swap model | `FoldModel` | opening to **85°** or more → inner; closing to **84°** or less → cover (measured under Ycode for every degree 76–85, below); Half Open (90°) ends on the inner from both sides |
| Panel shown (D2, D3) | `activePanel`, `PanelPicture.isBlack`, `IOSurfaceHostService.presentedFrameIsBlack` | the model's panel, unless its latest frame is black while the other panel's is not (a 32 × 32 sample grid, colour bytes zero). This replaces the backlight check in practice: the guest sets no backlight through the framebuffer library (Q4). The control socket's `state` reports both signs (`frames LCD lit, LCD-1 black`) |
| Display server | `startDisplayServer` | now gives the server the foldable's panels, the hinge and the touch panel (FOLD-IMPL never wired them: the hello had no `foldable`, and the fold bar answered "this device does not fold") |
| Warm restore | `ExecHost.swift` | the restore's "first new frame" watches every built-in panel (a device saved open draws on the inner panel only; before, the check waited 300 s for the cover) |
| Hinge input | `FoldController` | a hinge message the guest's input queue refuses (full for a moment under load) is retried every 30 ms for about 0.5 s before the sweep stops |
| Call log | `simframebuffer.c` | display setters and `GetMaskPath` keep their own budget of 4096 lines (`simframebuffer.md` §10) |

**§8.4 on the Thor** (control socket; screenshots per panel turned
upright; SpringBoard, locationd and backboardd log stream):

| Step | Result |
|---|---|
| 1. Boot closed | home screen at 62–135 s (load-dependent); SpringBoard: `Main` surface `.cover`, `Unknown.main[3]` surface `.inner`, no cloning-source assertion, no restart; `Hinge state changed from .unknown to .closed`; `FullyClosed` (inner `off`). Cover: portrait home screen; inner: black |
| 2. Sweep 0→180 | `FullyClosed→FoldingDual` during the sweep (target inner `pri`, cover `aux`; the inner resolved `pri` about 2 s later), hinge `.partiallyOpen → .openFlat`; MercuryPoster "Scene did move screens". Inner: the **landscape home screen** (2853 × 2007 upright: Batteries and Screen Time widgets on the left, Settings at the top, clock top right, Safari at the right edge, search bottom right — the reference's layout of §6); cover: black. In one boot the first unfold of the boot still showed the dimmed swap animation 12 s later; in the others the inner was drawn within 4 s |
| 3. Sweep 180→0 | `FoldingDual→FullyClosed`; cover portrait home screen, inner black |
| 4. 0→40 / 0→100 | 40°: stays on the cover. 100°: inner |
| Thresholds | opening to 75° and every degree 76–84°: cover; 85°: inner. From open flat to 85° and 90°: inner; to 84°, 83°, 82°, 81° and 80°: cover. (The model said "inner" for 81–84° closing before this round; the frame rule showed the cover all the same, and the model now says so too) |
| Half Open | 90° from closed and from open flat: inner, landscape |
| 5. Settings | launched folded: the cover shows its list. Unfolded: the same process continues on the inner panel in its **two-column** layout (General selected); folded again: the cover shows General's page (the state kept), portrait |
| 6. Touches | through the viewer: a tap at the Settings icon of the inner home screen (499, 83 landscape points) opened Settings **on the inner panel**; the HID bundle has the second touch screen (`0x59434F4400000005`, the inner UID) |
| Rotation | Rotate Left while open turns the inner home screen's UI a quarter (dock at the left edge of the upright picture); Rotate Right back |
| Viewer | `ycode-sim-viewer --script` over a forwarded display socket: hello with `foldable` and `displays`; Fold ▸ Open/Half/Closed swap the shown panel within 0.7–1.6 s (`display: LCD-1 turned 90° (hinge 180°, openFlat, portrait)`), pictures 2853 × 2007 open, 1398 × 2034 closed |
| IDE path | `scripts/ycode-sim.sh --device DEV --control fold half`, `--fold-state`, `--fold closed` (what the IDE's controls run over ssh): `ok` replies, panels as expected |
| 7. Warm restore | a device saved open (stop snapshot) restores open: `fold: restored (angle 180° (Open Flat), inner side)`, the first new frame comes on the inner panel 1.0 s after the root starts, the inner shows the home screen, the cover black; Closed and Open work afterwards. A cold boot always starts closed (`fold: starts closed`) |

**Q4 under Ycode**: no setter calls at all (§9 Q4); the viewer follows the
frames. **Mask**: not asked for (above).

**Regressions** (same build): iPhone 18 Pro on iOS 27.0 reaches its home
screen (176 s, under load average about 37), `fold` answers "does not
fold", no second display; iPad (A16) on 27.1 reaches its home screen
(165 s). Neither gets `displays` or the second display.

**Boot time** (one `timed.sh` pair, the same iPhone Duo device, cold,
`YCODE_FRAMEBUFFER_CALLS=1` and a log-stream one-shot in both): cover
only (`YCODE_FOLD_DISPLAYS=0`) 71.1 s to the home screen; both panels
61.6 s. The second panel costs nothing measurable; the difference is
run-to-run noise (the single-panel run came first, after the device's
previous two-panel boots).

**Re-check on the merged tree (2026-10-28).** After the main line was
merged into this work (no conflicts), the same build ran again on the
Thor while other agents' boots kept the load average between 130 and 220:

- §8.4 items 1–5, the thresholds and Half Open from both sides (the step
  list above, one boot with Settings): every step ends on the same panel
  as before (Closed, 40°, 75°, 80° closing → cover; 85° from both sides,
  90° from both sides, 100°, 180° → inner); one SpringBoard process for
  the whole boot, no cloning-source assertion; Settings moves to the inner
  panel's two-column layout and back to the cover with its page kept.
  Home screen at 517 s (load, not the fold: the iPhone 18 Pro and the
  iPad of the same round took 530 s and 426 s).
- Touches on each panel (item 6), through `ycode-sim-viewer --script`:
  folded, a tap at the cover's Settings icon (56, 82 portrait points)
  opens Settings **on the cover**; after Home and Open Flat, a tap at the
  inner home screen's Settings icon (499, 83 landscape points) opens it
  **on the inner panel**; Closed brings it back to the cover. Touch to
  first changed frame 1.1–1.4 s under that load.
- IDE path (`ycode-sim.sh --control fold half`, `--fold-state`,
  `--fold closed`): `ok` replies, panels as expected.
- Regressions: the iPhone 18 Pro on iOS 27.0 and the iPad (A16) reach
  their home screens and answer "does not fold".

**Not done / open**: tabletop and standby (Q3); the reference's own
behavior for rotation while open (not observed there); the open-flat
boundary (Q5).

### 10.5 Controls since HUB-UI (2026-10-28)

The viewer's fold bar and the Devices window's segmented control, hinge
slider and rotate buttons are replaced by Device Hub's controls
(`specs/ide/device-hub.md` §4.4 and "Ycode implementation"): the pose
buttons Closed, Partially Open, Open after one Rotate control (click
left, Option-click right) in the control row of the compact window and
the hub's canvas; Option-drag on a pose button or on the frame shows the
hinge slider with the angle, and the hinge sweeps there on release. The
presets are named "Closed", "Partially Open", "Open" everywhere (the
viewer's Device ▸ Fold ▸ items keep ⌥⌘1–⌥⌘3). The frame and the compact
window follow the panel shown: the cover in portrait, the inner panel wide;
Partially Open draws a hinge line and shades one half. The commands are
the same display-stream messages (0x88, 0x89) and, without a display,
the same control-socket words as before.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Displays, sizes, orientations, masks, chrome ids (§2) | 2 | device type `capabilities.plist` and `profile.plist` via `plistlib`; `simctl io enumerate` |
| SpringBoard point sizes, display names, surfaces (§2, §6) | 3 | guest log stream (SpringBoard `DisplayTransforming`, `DeviceSceneHandle`) |
| No fold control in `simctl`; `devicectl` commands and output (§4) | 3 | `simctl help <sub>`, `devicectl help …`, `devicectl device motion hinge-angle`, `orientation get/set` |
| Device Hub plug-in controls, settings, poses, interpolation (§4, §5.1) | 4 | strings and import names of `CoreDevicePopDeviceKitExtension.devicekitplugin` and `CoreDevicePopCoreDeviceExtension.coredeviceplugin` |
| `dtuhidd` `avpCustom` service, usage pair, transport (§5.1) | 3, 4 | guest log at boot; `dtuhidd` and CoreDeviceUtilities strings |
| Event, payload keys, values, units, serialization (§5.2, §5.3) | 1, 3, 4 | IOKitUser open source (serializer format); our guest probe's events accepted by `locationd` (logs quote source, type, angle, orientation code); serializer output checked with the Mac's own IOKit; import names of the plug-ins and `locationd` |
| Relay services, report fields, hinge-state classes (§3.1, §5.4) | 3 | guest logs of `locationd`, SpringBoard, sharingd, backboardd while sweeping 0–180° in steps |
| SpringBoard swap behavior, thresholds, fold avoidance (§3.3, §6) | 3 | guest `DevicePose`/`DisplayContentMode` logs, `simctl io screenshot` of both panels in each state |
| App scene move (§6) | 3 | Settings launched folded, then unfolded; its UIKit log and SpringBoard's scene-handle log; inner screenshot |
| Orientation input (§5.3, §6) | 3 | probe events with each orientation string; relay and MagicPose logs; screenshot |
| No persistence (§7) | 3 | reboot while open; `device.plist`; search of the device's preference files |
| Displays stay powered (§1, §6) | 3 | `simctl io enumerate` in both states |
| Ycode requirements (§8) | — | Ycode decisions based on the above |
| A backboardd-created service is matched by the relay; `IOCFSerialize` exists in the runtime and its text (§9 Q6, §10.2) | 3 | Ycode boots on the Thor: `locationd`/`backboardd` debug log stream, the HID bundle's log |
| Without the inner panel the relay sends no device state (§10.2) | 3 | Ycode boots on the Thor: SpringBoard and `locationd` debug log stream, screenshots |
| With the inner panel SpringBoard stops on the cloning-source assertion; surfaces `.default`, `surfaceType:0`; root `bringupDisplay`; display names by position (§9 Q7, §10.2) | 3 | Ycode boots on the Thor with two and with five published displays: SpringBoard log stream, crash annotations |
| `displays` structure, key types (§9 Q7a) | 2 | the device type's `capabilities.plist` via `plistlib` (OBS-FOLD2) |
| The guest takes each panel's surface from `surfaceType` in `displays`; failure without it; required keys; reference `surfaceType:0` and `bringupDisplay` (§9 Q7b, c) | 3 | reference boots of throwaway iPhone Duo devices with `SIMCTL_CHILD_SIMULATOR_CAPABILITIES` pointing at edited copies: SpringBoard log stream, `ps -E`, launchd run counts, crash reports, screenshots; our MobileGestalt probe (OBS-FOLD2) |
| Commanded-target thresholds (§3.3, §10.3) | 3 | one reference device, 16 sweeps of 17 events 30 ms apart from our guest probe; SpringBoard `DCMResolved` and hinge-state lines (OBS-FOLD2) |
| Backlight switching at swaps (§9 Q4) | 3 | guest log stream (backboardd Backlight, SpringBoard BacklightServices) during the same sweeps; `simctl io enumerate`/`poll` (OBS-FOLD2) |
| Inner panel turn direction (§10.3) | 3 | `simctl io recordVideo --display=LCD-1` (frame size, display matrix via `ffprobe`, a frame read without the matrix) against `simctl io screenshot` (OBS-FOLD2) |
| Implementation (§10.1) | — | Ycode design; unit tests `FoldModelTests`, `DisplayStreamFoldTests`, `HIDHostServiceTests.deviceMotionBodies`, `FoldControlsTests` |
| FOLD2 results: surfaces, swaps, inner landscape home screen, Settings moving, touches on each panel, viewer and IDE paths, warm restore; re-check on the merged tree (§10.4) | 3 | Ycode boots on the Thor: control-socket screenshots of both panels, SpringBoard/locationd/backboardd log stream (`DisplayContentMode`, `DevicePose`, `DisplayControlling`, UIKit "Scene did move screens"), `ycode-sim-viewer --script` runs, the HID bundle log |
| Ycode swap band 76–85° (§3.3, §10.4) | 3 | one Ycode boot, 17-message sweeps from closed and from open flat to each degree; screenshots of both panels |
| Q4 under Ycode: no framebuffer setter calls (§9 Q4) | 3 | `YCODE_FRAMEBUFFER_CALLS` call log with the setters' own budget, both frame records over whole boots; backboardd Backlight log lines |
| Boot time with both panels (§10.4) | 3 | one `timed.sh` pair on the Thor |
| `displays` written, mask decision (§10.4) | — | Ycode design; `DeviceTypeTests.iPhoneDuoDisplaysList`, `FoldModelTests` |

Level 5 was not used. Ghidra, the reference tools folder and the IPSWs were
not opened. §10 (and §10.4, FOLD2) was written by a clean agent from this
spec and the specs it names; it ran only Ycode's own simulator. Our probes and all raw data stay in `research/dirty/obs-fold/`
and `research/dirty/obs-fold2/`;
no Apple file or code was copied into the repository.
