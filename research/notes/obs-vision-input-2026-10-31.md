# OBS-VISION-INPUT observations (agent OBS-VISION-INPUT, 2026-10-31)

Dirty-room notes behind `specs/simulator/visionos.md` §5.5 (input formats
and delivery) and §10.23 (the reference run, glass and metal). Prose only.
Raw logs, screenshots, recorder output and string lists stay in
`research/dirty/vision3/` (git-ignored). No disassembly or decompilation
was used; Ghidra, the reference tools folder and the IPSW were not opened.
Level 4 was limited to `nm`, `strings` and Objective-C type encodings of
three files: Xcode's visionOS DeviceKit plug-in, CoreSimulator's xros HID
bundle, and the runtime's `vhmdd`.

## Setup

- Xcode 27.1 (27A9269), CoreSimulator 1174.9.2, visionOS 27.0 (24M362),
  device type Apple Vision Pro (4K). One device, `ycode-test-vision3-a`,
  created with `simctl create`, booted twice, shut down and deleted at the
  end; `device_set.plist` byte-identical before and after. Host load 25–45.
- No GUI: no Device Hub window, no clicks. All input was our own messages:
  - `vhid` (Mac): calls the exported Indigo builders of SimulatorKit and of
    the vision DeviceKit plug-in by `dlsym`, optionally patches bytes, and
    sends through SimulatorKit's legacy HID client (as `hidsend` did for
    iOS). A `script` mode sends a timed sequence from one process.
  - `bprobe` (Mac): calls a builder in a forked child with recognisable
    values in the integer and vector argument registers and reports where
    they land in the returned message (black-box signature discovery).
  - `vhm` (Mac): looks up the guest's `com.apple.vhmdd` through
    CoreSimulator, wraps it in an XPC endpoint marked sim-to-host, and sends
    one dictionary; prints the reply and the events that follow.
  - `hidrec.dylib`: our interposer, inserted at boot
    (`SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`), logs each event the HID bundle
    dispatches (sender ID and the event's own description) and the
    arguments of vendor-defined event creation.
  - `InputProbe.app`: a SwiftUI visionOS app that logs every input callback
    (button, tap, spatial tap, drag, magnify, rotate, continuous hover,
    UIKit touches and hover, key presses and text) and, in a volume and an
    immersive space, entity-targeted tap/drag/magnify/rotate and the ARKit
    device anchor every 0.5 s. The volume holds a mirror-metal and a rough
    metal sphere.
- Logs: guest `log stream` with debug enabled for `com.apple.iohid`,
  `com.apple.BackBoard`, `com.apple.RealitySimulation`.

## Builders (level 3, black box)

- `IndigoHIDMessageForPalomaPose(target, float3 translation, quaternion)`.
- `IndigoHIDMessageForPalomaSelection(target, pointer to a ray of two
  16-byte float3: origin, direction)`; a null pointer crashes.
- `IndigoHIDMessageForPalomaCollection(target, ray pointer, byte
  selectionOnly, bool leftPinch, bool leftDirect, u16 leftExtra, bool
  rightPinch, bool rightDirect, u16 rightExtra (on the stack), float3
  leftTranslation, quaternion leftOrientation, float3 rightTranslation,
  quaternion rightOrientation)`. Calling it with only eight integer
  arguments leaves the ninth (right extra) as stack garbage.
- SimulatorKit's `IndigoHIDMessageForDigitalDialEvent(double delta)`:
  record kind 6, the double at record offset 0x1C, target 200 (0xC8).
- All give a 192-byte message: 24-byte Mach header (zero; the client fills
  it), inner size 0xA0, a type byte 1, then one 0xA0-byte record. The
  Paloma record: kind 1, 64-bit host time, a zero word, then the target
  word at message offset 0x30. Float3 values are written as 16-byte slots
  (x, y, z, 0): the CoreSimulator bundle's own type encoding lists packed
  12-byte `fff` structs, but the guest reads the builders' layout (the ray
  and hand values arrived exactly), so the builders' offsets are the wire
  format. Offsets in spec §5.5.6.

## Targets → services (level 3)

The record's target word chooses the virtual service that dispatches:

| Target | Service (sender `0xACEFADE0000000…`) | Event |
|---|---|---|
| 300 | 05 PalomaPose | pose (whatever builder made the payload) |
| 301 | 06 SelectionStream | collection |
| 302 | 07 Manipulator | the same collection event; no consumer reacted |
| 200 | 02 DigitalDial | scroll |
| 0 | — | backboardd raised "Encountered HID event with unexpected target 0 not in known targets: (50, 13, 11, 51, 302, 300, 200, 14, 12, 60, 100, 1073741825, 301)" and **exited**; the whole UI restarted |

## Dispatched events (level 3, `hidrec`)

Pose (target 300, translation (0.1, 0.2, 0.3), yaw 30°): one VendorDefined
event, page 0xFF00, usage 0x72, version 13, no data, flags 0x1, with two
children: Translation (relative; 0.1, 0.2, 0.3) and Orientation (relative,
orientation type 3; w 0.965912, y 0.258804).

Collection (target 301): parent VendorDefined 0xFF00/0x6F, version 13,
flags 0x2000003, phase Changed; children in order:

1. left hand: VendorDefined 0xFF00/0x70, version 13, data
   `{pinch, 2, direct}`, flags `leftExtra << 24 | 3` in our run
   (0x77000003), children Translation (relative) and Orientation (relative,
   type 3);
2. right hand: the same with data `{pinch, 1, direct}`, flags
   `rightExtra << 24 | 1` in our run (0x34000001);
3. gaze: VendorDefined 0xFF00/0x71, version 13, flags 0x3, children
   Translation (absolute, flags 0x1) = ray origin and **Rotation** (absolute,
   flags 0x1) whose x, y, z are the ray direction.

With the selection-only byte non-zero, children 1 and 2 are absent. The
Rotation fields arrive quantised to 16.16 fixed point (0.1 → 0.099991);
backboardd's own log showed 0.05 → 0.049988.

Vendor events were created with options 0x2 (parent, left hand, gaze) and
0 (right hand). The bundle imports, among others, the IOKit constructors
for vendor-defined, translation, rotation, quaternion-orientation and
scroll events and `IOHIDEventSetEventFlags`, `IOHIDEventSetPhase`,
`IOHIDEventAppendEvent` (level 4).

Dial (delta 0.5): a Scroll event from service 02, relative, flags 0x10,
Y = 0.5. No consumer reaction was seen in the logs.

## What backboardd does with them (level 3)

- backboardd's RealitySystemSupport hand provider logs each collection:
  phase, "Selection ray: { origin, direction, length: 10 }", and per hand
  "Active, Pinching, Allow direct interactions, Anchoring chirality, Force
  direct pinch, Pose". It re-runs the hit test on every frame with the last
  ray (the hover keeps updating without new messages).
- Pinch begins a contact: "Contact updated: source N … H/T/P BEGAN …
  position x y z" in the stage frame; the release ends it. Sources seen:
  2 left indirect pinch, 12 right indirect pinch, 11 right direct touch
  (T BEGAN, P INACTIVE), 13 right direct pinch.
- PalomaPose moves the rendered camera. The pose is absolute: the same
  message twice gives byte-identical screenshots. (0, 0, 0) with identity
  orientation is a view from the default eye point looking along −Z;
  (0, 1.6, 0) puts the eye 1.6 m higher (above the ceiling); +z moves back.
- RenderingEffectsSystem dismisses the home view "due to out of bounds"
  when the camera jumps far from it; Home (button source 0) shows it again
  (SurfBoard: "Toggle Home UI for reason: Crown").

## Frames (level 3)

- **One frame for everything.** Camera pose, gaze ray and hand poses are in
  one frame: metres, y up, −Z forward, origin at the default eye point. With
  the camera moved to (1, 0.5, 2) and turned 30° left, a ray built in camera
  space missed; the same ray transformed by the camera pose (origin =
  camera position, direction = camera rotation × camera-space direction)
  hit the target and the app logged `onTapGesture`. The host must do this
  transform; the guest does not apply the camera pose to the ray.
- In an immersive space this origin is ARKit's world (0, 1.6, 0): vhmdd logs
  "Pose requested for PID …, using stage transform" with translation
  (0, 1.6, 0) for our app.
- Projection of the 3840 × 2160 view: horizontal field of view 90° (focal
  length 1920 px), square pixels. Checked with a marker at (1, −0.1, −2)
  from the eye: it appeared 960 px right of centre and 48 px below.

## ARKit pose: vhmdd, not HID (level 3)

- Four PalomaPose messages (translations and rotations) left the app's
  `DeviceAnchor` at (0, 1.6, 0) looking along −Z, while the view moved.
- vhmdd `set_pose` with a translation (0.5, 0.2, −1) changed the anchor to
  (0.5, 1.8, −1) at once; with (2, 0, 0) to (2, 1.6, 0); the view did not
  change (whole-screen mean colour identical). `get_pose` returns the matrix
  last set (identity after boot without Device Hub).
- So the anchor is the per-app stage transform times vhmdd's pose; the
  rendered camera comes only from PalomaPose. The plug-in sends both
  (strings "HIDMessage - sending .camera with matrix", and `setPose:`).
  §5.4's 12.5° start orientation was Device Hub's initial camera; without
  Device Hub, the pose stays identity.

## vhmdd host protocol (level 3; key names level 4)

- Reachable only from the host: a guest client (`simctl spawn`) to
  `com.apple.vhmdd` or `com.apple.vhmdd-sim` was accepted but every request
  ended in "Connection interrupted" with nothing processed. The host path is
  CoreSimulator `lookup:` of `com.apple.vhmdd`, an XPC endpoint from that
  send right, the connection marked sim-to-host.
- Messages are XPC dictionaries; the command is the string under **`cmd`**.
  vhmdd stamps `majorVersion` 1, `minorVersion` 1 on what it sends.
- `get_pose` → reply `{pose: data(64)}` (a column-major float4x4).
  `set_pose` with `pose` data(64) → empty reply.
- `request_environments` → empty reply, then an event `{cmd:
  environments_changed, environments_data: <JSON string>}` with an object
  keyed by room key (`KitchenDay` … `MuseumNight`), each `{displayName,
  thumbnailURL}` (a PNG in the runtime's SystemEnvironments framework).
- `set_active_environment` with `environment_id` → empty reply, then events
  `active_environment_changed {environment_id}` (twice) and, about 1–3 s
  later, `synthetic_environment_did_load {environment_id, load_error: ""}`.
  The room changed live and the preference file then held the new key.
- Other command names in both binaries (not sent): `set_controls_enabled`,
  `get_controls_enabled`, `observe_hand_mode`, `set_hand_mode`,
  `change_immersion_level` (`immersion_level`, `absolute`),
  `get_immersion_level`, `set_cursor_visible` (`visible`),
  `recenter_open_apps`, `simulate_facetime_session`
  (`standard_participant_count`, `spatial_participant_count`); events
  `hand_mode_changed`, `keyboard_editing_active_changed`,
  `immersion_level_did_change`, `immersion_style_did_change`.

## Room before boot (level 3)

With the device shut down, `activeSyntheticEnvironment` set to `MuseumDay`
in `DEV/data/Library/Preferences/com.apple.RealityEnvironment.plist`: the
next boot showed Museum (Day) with the home view. Yes, it selects the room.

## What the app received (level 3)

| Input sent | App log |
|---|---|
| gaze on a button + right pinch 100 ms | `Button` action |
| on a view with `onTapGesture` | `onTapGesture` |
| on a `SpatialTapGesture` view | location (100.0, 70.6) pt, `location3D` z 0.005 |
| on a UIKit view | `touchesBegan`/`Ended`, touch type 0 (direct), tapCount 1, force 0 |
| pinch, right hand moved +0.10 m x, +0.05 m y, release | `DragGesture` changes up to translation (70.2, −35.1) pt; predicted end (175.5, −87.7) |
| both hands pinched, separation 0.3 → 0.6 m | `MagnifyGesture` 2.0 |
| both hands pinched, rotated 30° counter-clockwise (seen by the user) | `RotateGesture` −30° |
| one hand rotated 45° | nothing |
| gaze only, 300 ms | no `onContinuousHover`, no UIKit hover; the system hover highlight was drawn (the tap rectangle's mean colour went from (255, 172, 90) to (255, 196, 112)) |
| tap on a text field, then keys `h`, `i` | `onKeyPress` h, i; text "Hi"; the system keyboard panel appeared |
| immersive sphere | `entityTap` scene point (0, 1.51, −1.8): the sphere's front surface |
| volume sphere, indirect pinch | `entityTap` |
| volume sphere, pinch and hand moved +0.1 m x, +0.1 m z | `entityDrag` translation3D (136, 0, 136) pt |
| right hand moved into the sphere with "direct" set, no pinch | `entityTap` (contact source 11) |

## Glass and metal (levels 2, 3)

- Window glass, fitted on screenshots with and without the window at the
  same camera pose (Living Room Day): inside the glass, out ≈ 0.58 ×
  Gaussian-blurred background (σ ≈ 128 px at 3840 width) + 49 (8-bit sRGB),
  R² 0.99 on a strip in front of the television; weaker fits elsewhere
  (less background contrast). A thin light rim of 2–4 px follows the
  rounded top edge. The panel is never opaque: the television shows
  through as a soft dark area.
- CoreMaterial's `platformContentGlass.materialrecipe` (a plist): backdrop
  `blurRadius` 45 and a 4×5 colour matrix whose rows sum to 0.629 with an
  offset of 0.235 per colour channel. With the window at about 2.6 px per
  point, 45 pt ≈ 116 px; gain 0.63 and offset 0.235 (60 in 8-bit) match the
  fit. The variants `…Darker`, `…Lighter`, `…UltraDarker` exist beside it.
  CoreRE's `glass.rematerialdefinition` (JSON) is a different, RealityKit
  glass: technique "Glass", fragment entry `fsBlurTransparent`, base colour
  from `rendergraph.inputColor`.
- Mirror sphere (metallic, roughness 0) reflects a room image (walls,
  ceiling lights, floor) but not the app window next to it; the rough
  sphere is a soft white. Each room ships one
  `*_IBL_Linear_Display-P3_envProbeMap.ktx`: KTX 1, cube (6 faces),
  256 × 256, **9 mip levels**, `GL_HALF_FLOAT`/`GL_RGBA`/`GL_RGBA16F`
  (= `MTLPixelFormatRGBA16Float`), key/value `ToolVersion` "1",
  `PositiveZForward` "true"; linear HDR (Living Room Day face means 0.39–1.14,
  maximum 27.2); the stored mips are plain averages. It is the only
  RGBA16Float cube in a room asset. The albedo textures are KTX 1 2D with
  `GL_COMPRESSED_SRGB8_ALPHA8_ASTC_6x6` (0x93D4), 4096² with 13 levels or
  1024² with 11.
- Whether `generateClampedMap` reads that cube was not observed (no Metal
  recorder in the reference this round); everything else points to it.

## Devices and processes

| Device | Type | Created | Deleted |
|---|---|---|---|
| `ycode-test-vision3-a` | Apple Vision Pro (4K), visionOS 27.0 24M362 | 04:09 | 04:35 |

Every process we stopped was one we started (two log streams, by PID). One
backboardd restart was caused by us (target 0, above).
