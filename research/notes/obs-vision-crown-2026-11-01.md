# OBS-VISION-CROWN observations (agent OBS-VISION-CROWN, 2026-11-01)

Dirty-room notes behind `specs/simulator/visionos.md` §5.5.9 (the Digital
Crown, immersion and recentering). Prose only. Raw vhmdd exchanges, guest
logs, recorder output, string lists and screenshots stay in
`research/dirty/vision4/` (git-ignored). No disassembly or decompilation
was used; Ghidra, the reference tools folder and the IPSW were not opened;
nothing was decrypted. Level 4 was limited to `strings` and `nm -m` of
Xcode's visionOS DeviceKit plug-in, `strings` of the runtime's `vhmdd`
(27.0 and 27.2), of DeviceHub's executable, DeviceKit and SimulatorKit,
and a file listing of SurfBoard's bundle.

## Question

R9 (§10.25) delivers the crown as DigitalDial scroll events and nothing in
the guest reacts; OBS-VISION-INPUT saw the same in the reference. What does
turning, pressing, double-pressing and holding the crown do, and how does
the reference simulator deliver each?

## Public documentation (level 1)

- Apple Vision Pro User Guide, "Basic gestures and controls" and the
  "Digital Crown" aside: turn = immersion (of an Environment or an app's
  immersive space) or volume, depending on Settings > Digital Crown and on
  what the user looks at; press once = Home View; press and hold =
  recenter content in the field of view; double press = switch to a view
  of the surroundings, press again to return; triple press = the
  Accessibility Shortcut; crown + top button pressed together = still
  image of the view, held = Force Quit Applications, held longer = power
  off sliders, then force restart. Top button press = Capture.
- SwiftUI: `ProgressiveImmersionStyle` (`.progressive`, with an optional
  immersion range and initial amount), `onImmersionChange` (old and new
  `ImmersionChangeContext`, whose `amount` is an optional Double),
  `onWorldRecenter` (phases `began`, `ended`; "recentering the view with
  the digital crown").
- Xcode's "Interacting with your visionOS app in Device Hub" lists no crown
  control for visionOS: Home (button or Controls > Home), Control Center,
  volume (Device > Sound > Increase/Decrease Volume), the camera and the
  scenes. The crown rows of the general Device Hub article (click the
  bezel's crown, scroll over it) belong to watchOS.

## Setup

- Xcode 27.1 (27A9269). The brief asked for visionOS 27.0 (24M362), but
  `simctl create` (and CoreSimulator's own create call, tried with our
  `mkdev` for both 27.0 builds) refused every 27.0 device with "runtime
  path not found" this morning: two 27.0 builds (24M362 and a 24M5291p
  cryptex) now share the identifier. We did not change the runtime
  registration. The run therefore used **visionOS 27.2 (24N120)**, device
  type Apple Vision Pro (4K). `vhmdd`'s full string list is identical in
  27.0 (24M362) and 27.2 (553 strings, no difference), so the protocol
  facts carry over; visual details may differ.
- Device `ycode-test-vision4-c` (the `-a` and `-b` creates failed and made
  nothing), booted once at 00:44 with our HID recorder inserted, deleted at
  01:00; `device_set.plist` byte-identical before and after. No other
  simulator was booted or touched. The only processes stopped were our own
  log stream (by its PID) and our app (`simctl terminate`).
- Tools (sources in `research/experiments/visionos/`):
  - `vhm` (extended): one vhmdd connection, one message per stdin line,
    events printed with host time; `key=u:` for unsigned values.
  - `vhid` (extended): `bdown`/`bup` verbs, so holds and multi-presses are
    timed by the script.
  - `hidrec.dylib`: the recorder of dispatched HID events (unchanged).
  - `CrownProbe.app` (new): a window and four immersive spaces
    (progressive with the system range, progressive 0.2…0.8 initial 0.5,
    full, mixed) holding an unlit magenta sky sphere and a red cube; logs
    `onImmersionChange`, `onWorldRecenter` (window and space), scene phases
    and the ARKit device anchor.

## Turning the crown = vhmdd immersion commands, not the dial service

### change_immersion_level

`{cmd: change_immersion_level, immersion_level: double, absolute: bool}`.
Empty reply at once; then about 27–28 `immersion_level_did_change
{immersion_level}` events, one every ~11 ms for ~0.30 s, easing from the
old to the new level (slow, fast, slow). `get_immersion_level` →
`{immersion_level: double}`.

Two numbers must be kept apart:

- the **amount** a ∈ [0, 1] (what an app's `onImmersionChange` reports,
  and what the absolute command takes);
- the **level** L that vhmdd reports in replies and events: **L = a²**.

| Sent (absolute) | No immersive space | Progressive, system range | Progressive 0.2…0.8 (opens at a 0.5, L 0.25) |
|---|---|---|---|
| 0.0 | L 0 | a 0.5477, L 0.30 (clamped to the minimum) | a 0.2, L 0.04 |
| 0.1 | – | – | a 0.2, L 0.04 |
| 0.2 | – | no change, no events (below the minimum) | – |
| 0.3 | L 0.09 | – | – |
| 0.5 | L 0.25 | no change, no events | – |
| 0.6 | – | – | a 0.6, L 0.36 |
| 0.7 | L 0.49 | – | – |
| 0.8 | – | a 0.8, L 0.64 | – |
| 0.9 | L 0.81 | – | a 0.8 (clamped), L 0.64 |
| 1.0 | L 1.0 | a 1.0, L 1.0 | – |

- The app's amount animates through the same ease (25–28 callbacks of
  `onImmersionChange`), ending exactly at the value sent (or the clamp).
- The progressive style without a range starts at and never goes below
  a = 0.5477 (L = 0.30); its maximum is 1. A ranged style is clamped to its
  range and starts at its initial amount (0.5 → L 0.25).
- **Relative** (`absolute` false): the new amount is clamp(**L** + delta)
  — the delta is added to the *level*, not to the amount. Observed with no
  space: 0.25 +0.1 → a 0.35 (L 0.1225); 0.1225 +0.1 → a 0.2225 (L 0.0495);
  0 +0.2 → L 0.04; 0 +1 → 1; 1 −1 → 0; and in the 0.2…0.8 space, from
  L 0.04 four steps of +0.1 did nothing (0.14 < 0.2, clamped back), +0.3
  gave a 0.34. A host that sends small relative steps can get stuck; send
  absolute amounts.
- No immersive space open: the level still changes (it is the system's),
  and at 1.0 the home view's glass turns dark (the "More Apps" disc and the
  sidebar went from light to dark grey); the room stays.
- Full space: opening it sets a = 1 (L 1). Absolute 0.5 → a 0.5 and the
  sky fades (a dark floor shadow appears); 0 → the scene is black and the
  window dark grey: immersion fades the full space's content out but no
  passthrough room comes back.
- Mixed space: `onImmersionChange` reports only its initial value; the
  level still moves (system level) with no visible change.
- When the app exits, the level returns to the system value.
- Screenshot pairs (progressive, system range): at the minimum the room
  shows below the window, fading into the sky (the portal's lower edge);
  at 0.8 the whole view is sky; at 1.0 the window glass turns dark.

### Events back to the host

- vhmdd sends events only on connections that have already sent it a
  message: a listener that sent nothing for 30 s got nothing; with one
  `get_immersion_level` first it got everything.
- `immersion_level_did_change {immersion_level}` (L) during every change,
  also when the app's own open/close changes it (opening the full space: 0
  → 1).
- `immersion_style_did_change {immersion_style: int}`: **2** when a
  progressive space opens, **−1** when it closes. Opening a mixed or a full
  space sent no style event; a full space sent `active_environment_changed
  {environment_id: ""}` (the room is unloaded) and, after it closed,
  `active_environment_changed {LivingRoomDay}` (twice, then "" once),
  `environments_changed` and `synthetic_environment_did_load`.
- `keyboard_editing_active_changed {keyboard_editing_active: false}` arrived
  at app launches and exits.

### The dial service does nothing for immersion

DigitalDial scroll events (`vhid dial ±1`, 1 and 10 per burst, 30 ms
apart) were dispatched by the HID bundle (recorder: Scroll, relative,
flags 0x10, Y ±1) while a progressive space was open, before and after
`set_controls_enabled true`: no immersion change, no vhmdd event, no
SurfBoard or app reaction.

### What Device Hub has (level 4, names only)

The plug-in has actions `increaseImmersion:`, `decreaseImmersion:` and
`setImmersionTo0:`/`25`/`50`/`75`/`100:` (on its input view and an "SPI"
responder class), an `ImmersionController` that receives
`immersion_level_did_change` and `immersion_style_did_change` ("Received
change of immersion level to %f", "… style to %lld"), a remote-service
method `changeImmersionLevel:isAbsolute:` and `getImmersionLevelWithReply:`,
identifiers `immersionUp`/`immersionDown`, and log strings "HIDMessage -
sending IndigoHIDMessageForDigitalDialEvent(1)" and "(-1)". vhmdd holds a
SurfBoard immersion-service client (entitlement
`com.apple.surfboard.immersion-client`, `applyAbsoluteDialImmersion:…`,
"Changing immersion value: %f, absolute: %{bool}d"). How the menu items map
to the two paths was not observed (no GUI); the black box above shows that
only the vhmdd path changes immersion in 27.2.

## Crown presses = the Home button (source 0)

All sent as Indigo button messages, source 0 (0x0C/0x40 from
MainScreenButtons), with our own down/up timing. SurfBoard names each
gesture in its log ("Detected SFBSHardware…Gesture"):

| Input | SurfBoard gesture | Result |
|---|---|---|
| press 100 ms | TapCrown | "Toggle Home UI for reason: Crown". With a progressive space open: the space is closed (scene phases inactive → background, amount nil, the view disappears), the window stays, the home view does not show. With only a window: the home view shows. |
| two presses, 80 ms down, 150 ms apart | DoubleTapCrown | "Performing system-default action"; nothing changed on screen (no surroundings view in the simulator) |
| three presses, 70 ms down, 120 ms apart | DoubleTapCrown, then TapCrown | no triple gesture (no Accessibility Shortcut); the tap showed the home view |
| hold 400 ms | TapCrown | as a press |
| hold ≥ 500 ms (500, 600, 700, 1000, 1500, 3000) | LongPressCrown, detected ~0.49 s after the press while still held; at release "LongPressCrown … Not performing any actions" | **recenter**: "Performing a recenter action", the sound `LongPress_CrownRecenter.wav` (SurfBoard's bundle), backboardd's RealitySimulation placement recenter (`performRecenterWithReason:…`, "Fading recenterable placements"); the app gets `onWorldRecenter` began then ended in the window and the space |
| source 1 (0x0C/0x30) 100 ms | TouchDownLock, TapLock | the **top button**: Capture launch refused in the simulator ("ignoring Capture launch …") |
| source 3000 (0x0C/0x95) | none | – |
| sources 1 + 0 down together 150 ms | TouchDownLock, TapBoth | "Taking screenshot…" |
| sources 1 + 0 held 2.5 s | LongPressBoth ~1.5 s after the press | "Force quit gesture recognized", the Force Quit Applications panel (CrownProbe listed) |

## Recentering

- vhmdd's `recenter_open_apps` is a **no-op** in 27.2: vhmdd logs
  "re-centering was moved to PlacementController, this is a no op" and does
  not reply (the client's reply handler gets "Connection interrupted"
  immediately; the connection stays usable). The plug-in has a
  `PlacementController` ("recenter all open apps") — the crown hold above
  is the working path.
- What moves: windows, the home view and the immersive content are placed
  again in front of the **rendered camera** (the PalomaPose camera). Two
  mismatch runs settled it: render camera at identity with vhmdd's pose
  turned 60° → the home view stayed in front; render camera turned 60°
  with vhmdd's pose at identity → the home view moved in front of the
  turned camera.
- ARKit: after a recenter with camera = vhmdd pose = (0.5, 0, 0) turned 70°
  left, vhmdd logged the app's new stage transform as a rotation of −70°
  about y with translation (−0.171, 1.6, −0.470) = T(0, 1.6, 0) × pose⁻¹,
  and `queryDeviceAnchor` went back to (0, 1.6, 0) looking along −Z. The
  stage transform persists across app relaunches (a later app saw the
  previous recenter's 40° as a 30° offset at 70°). Whether the stage
  transform is computed from vhmdd's pose or from the rendered camera was
  not separated (they agreed in that run).

## Other vhmdd commands (exercised)

| Command | Reply | Effect |
|---|---|---|
| `get_controls_enabled` | `{controls_enabled: false}` after boot | – |
| `set_controls_enabled {controls_enabled: bool}` | empty | stored ("Setting controls: enabled"); no visible change, no effect on the dial |
| `observe_hand_mode` | empty | subscribes to `hand_mode_changed` |
| `set_hand_mode {hand_mode: string}` | empty, then `hand_mode_changed {hand_mode}` echoing the string | any string was accepted and echoed (`left`, `right`, `both`, `none`, `auto`, …); no visible change. An integer value got no reply. |
| `set_cursor_visible {visible: bool}` | empty | true draws a grey ring (about 22 px across at 3840 × 2160) at the view's centre (no gaze had been sent); false removes it |
| `recenter_open_apps` | none | no-op (above) |
| `simulate_facetime_session` | – | not sent (not crown-related) |

## Devices and processes

| Device | Type | Runtime | Created | Deleted |
|---|---|---|---|---|
| `ycode-test-vision4-c` | Apple Vision Pro (4K) | visionOS 27.2 (24N120) | 00:43 | 01:00 |
