# Spec: the headset viewer (a visionOS device in an OpenXR headset)

Status: **implemented** (agent XR-VIEWER, 2026-11-01; quality after run 7: §12). The OpenXR side ran
live on a headset (§2); the whole path Thor → x86 was run with recorded
tracking scripts in place of the headset (§9.1); the live run with the
headset is §9.2.
Ycode-original design. It describes how Ycode's own simulator, its display
stream (`display-stream.md`) and its visionOS input (`visionos.md` §5.5)
are viewed and driven from an OpenXR headset. It follows public
specifications only: the OpenXR 1.1 specification and registry (Khronos),
the Vulkan 1.3 specification, and WiVRn's user documentation (for how to
run it; no WiVRn code is used or linked).

Code: `Sources/CYcodeOpenXR` (the OpenXR and Vulkan side, C),
`Sources/YcodeXRViewer` and `Sources/ycode-xr-viewer` (the viewer),
`Sources/YcodeDisplayStream/XRViewer.swift` (the shared mapping, the eye
scheduler and the messages), `Sources/ycode-simd/DisplayXR.swift` (the
server's headset mode), `ycode sim remote view --xr`.

## 1. Architecture

```
 Thor (arm64, KVM)                        x86 PC (Linux)                     headset
 ┌──────────────────────────────┐  link  ┌─────────────────────────────┐ WiVRn ┌──────────┐
 │ guest: backboardd renders    │ (sim-  │ ycode-xr-viewer             │ (its  │ Quest Pro│
 │ one view per picture for the │ link.md│  stream client → per-eye    │ own   │ display, │
 │ camera pose it was given     │  TCP + │  canvases → OpenXR swap-    │ stream│ head,    │
 │ ycode-simd: DisplayXRState   │  UDP)  │  chains → projection layer  │ ing)  │ eyes,    │
 │  schedules eye poses, tags   │◀──────▶│  OpenXR tracking → XRInput- │◀─────▶│ hands,   │
 │  pictures, per-view damage   │        │  Mapper → views, selection, │       │ control- │
 │ HID bundle + vhmdd (R9 path) │        │  crown, immersion           │       │ lers     │
 └──────────────────────────────┘        └─────────────────────────────┘       └──────────┘
```

- The simulator keeps running on the simulator host. The viewer reaches it
  over Ycode's link (`sim-link.md`): control and input over TCP, frames by
  UDP. It accepts the display socket address too (`--connect`).
- The viewer is an OpenXR application. It links nothing of OpenXR at build
  time: CYcodeOpenXR opens the **Khronos OpenXR loader**
  (`libopenxr_loader.so.1`, Apache-2.0) and the Vulkan loader with `dlopen`,
  and the loader finds the active runtime. No runtime (WiVRn, Monado; GPL)
  and no vendor SDK is linked. Without a loader, `ycode-xr-viewer` says so
  and exits; on macOS the shim builds as stubs.
- The runtime used here is **WiVRn** (Monado-based; it streams its
  compositor's output to a standalone headset's own client). The viewer
  sets nothing in it. `XR_RUNTIME_JSON` names the runtime manifest when no
  active runtime is configured (the system's choice; the viewer never
  writes runtime configuration).

## 2. What the runtime offers (phase 1, measured 2026-11-01)

A Meta Quest Pro connected to WiVRn 26.9 (Ubuntu 26.04, OpenXR loader
1.1.47, NVIDIA RTX 4060 Ti), our probe and CYcodeOpenXR's own test pattern:

| What | Value |
|---|---|
| Runtime, system | WiVRn "v26.9" (26.9.0), "Meta Quest Pro on WiVRn" |
| Graphics | `XR_KHR_vulkan_enable2`; the runtime names the RTX 4060 Ti (Vulkan 1.4) |
| View configuration | PRIMARY_STEREO, 2 views; recommended 2700 × 2970 per eye (max 5400 × 5940), 1 sample |
| Fields of view | left eye −54° … +40° horizontally, right eye −40° … +54° (asymmetric, outward), 96° vertically; IPD 0.068 m |
| Frame timing | predicted display period 11.1 ms (90 Hz) |
| Spaces | VIEW, LOCAL, STAGE (STAGE bounds: not implemented by the runtime) |
| Blend modes | opaque, alpha blend |
| Swapchain formats | include `B8G8R8A8_SRGB` (taken: the stream's BGRA goes in unchanged) and `R8G8B8A8_SRGB` |
| Eye gaze | `XR_EXT_eye_gaze_interaction` v2, supported; located in 2445 of 2699 frames of a 30 s run (yaw −24° … +44°, pitch −27° … +28° relative to the head) |
| Eye tracking (social) | `XR_FB_eye_tracking_social` **not offered** by WiVRn; the gaze comes from EXT_eye_gaze_interaction only |
| Hands | `XR_EXT_hand_tracking` v4 (supported), `XR_EXT_hand_interaction` v2, `XR_EXT_hand_tracking_data_source`; pinches seen (tip distance down to 0.7 cm) |
| Controllers | `XR_FB_touch_controller_pro`, Oculus Touch; with the controllers put down the hands' profile is `/interaction_profiles/ext/hand_interaction_ext` |
| Recenter | the headset's recenter arrives as `XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING` |
| Session | IDLE → READY → SYNCHRONIZED → VISIBLE → FOCUSED; a request to exit ends STOPPING → IDLE → EXITING cleanly |
| Instance creation | blocks while WiVRn waits for its headset client (no instance without a headset) |

The test pattern (a grid, left eye tinted red, right eye blue, uploaded
alternately per eye at 1920 × 1080 and submitted with the guest's 90° field
of view at the pose each eye had when its image was made) ran 30 s with
2692 frames, 673 uploads and no error; the wearer saw one flat panel fixed
in space, red in the left eye and blue in the right: the per-eye path and
its orientation are right.

## 3. Frames and poses

- **XR base space**: STAGE (LOCAL when STAGE is missing). OpenXR's spaces
  are right-handed, +Y up, −Z forward, metres — the stage frame's
  conventions (`visionos.md` §5.5.1).
- **Anchor** (`XRStageAnchor`): the head's position and heading (yaw only)
  when the viewer starts or recentres. The stage frame's origin, the
  guest's default eye point, is the head at that moment; pitch and roll
  stay in the poses, so the stage stays level.
  stage = R(−yaw) · (base − origin); base = origin + R(yaw) · stage.
- **The guest's camera.** Absolute (§5.5.1); the viewer sends full
  rotations (with roll). In mono mode the camera is the head (OpenXR VIEW
  space, the point between the eyes); in alternate stereo, each eye's pose
  from `xrLocateViews`.
- **The guest's projection** (`XRFieldOfView.guest`): 90° horizontally,
  square pixels, centred: tangents ±1 horizontally and ±h/w vertically
  (±0.5625, i.e. ±29.4°, for 3840 × 2160). The headset's own field of view
  is wider (above); the image fills the centre and the rest is black.
- **Submission.** One projection layer; view *i* shows its eye's newest
  image with the **pose and field of view it was rendered for** (the tag of
  §4, mapped back to the base space), so the runtime's reprojection moves
  it to where the head is at display time. Images are copied from the
  decoded canvas into a per-eye swapchain (a host-visible staging buffer,
  `vkCmdCopyBufferToImage`, then COLOR_ATTACHMENT_OPTIMAL as OpenXR
  expects); an eye without a new image is submitted again from its last
  released image. The mono picture, the left eye's and the right eye's
  each have their own swapchain (slots 10, 0, 1; their insets 11, 4, 5), and
  `XRLayerPlan` picks what each eye shows: a mono picture newer than both
  eyes' goes to both; otherwise each eye shows its own picture, or the
  mono one until it has one. A change of mode therefore never shows one
  view's picture in the other eye or at another picture's pose (it did
  before run 5, when mono and the left eye shared a swapchain).

## 4. Stereo from Ycode's own host

**One view is the guest's design** (`visionos.md` §5.6, answering the
questions of this round): the guest's simulated headset renders one view,
with an identity eye transform and tangents (1, 1, 0.5625, 0.5625); no host
input, preference or vhmdd command gives it a second view (Q-XR1–Q-XR4,
answered). Ycode therefore makes stereo from what it owns, the camera pose
(§5.6.5): the guest is given one eye's pose, then the other's, and every
picture is tagged with the eye and pose it was rendered for.

**The guest's camera is smoothed** (measured, §6): after a new pose the
picture first changes about 170 ms later and keeps converging over about
250 ms more (its RMS distance to the final picture, one value per picture:
23 → 11 → 9 → 6 → 0.5 → 0 grey levels). Alternating the eyes on every
picture therefore blends them: tags by picture count (any latch 1–3 or
hold 1–3) matched only 24–68 % of pictures in a test whose two eyes are
60 cm apart. A pose's picture is right only once it has **settled**.

**Modes** (`XREyeScheduler`; the hello's `xr.stereo`):

| Mode | The guest is given | A picture is shown | Rate per eye (23 pictures/s guest) |
|---|---|---|---|
| **adaptive** (default) | while the head moves: the head, whenever it changes (at most every 16 ms); once it has been still for 300 ms (less than 4 mm and 0.4°): the left eye, then the right, in turn | moving: every new picture, as mono, tagged with the head pose sent 240 ms before it (§6); still: each eye's settled picture | moving: about 23 pictures/s to both eyes; still: about 1.2–1.5 Hz per eye |
| alternate | the eyes in turn, always | each eye's settled picture | about 1.2–1.5 Hz |
| mono | the head | every new picture, tagged as above | about 23 pictures/s to both eyes |

**Adaptive engages the eyes only at rest.** Besides the head (still for
300 ms within 1.5 cm and 1.5°), the eyes must rest too: a fovea move of
more than 2 % of the picture or a pinch keeps the mode mono for another
300 ms (`noteInteraction`). While the wearer looks at and selects things
the picture therefore follows at the guest's full rate; depth appears when
gaze and head rest. (Run 5: with only the head counted, the eye pictures —
one per eye every ~0.4 s — made hover and selection feel laggy half the
time.)

**Settling** (alternate, and adaptive when still): an eye's picture is
taken when its pose is at least 250 ms old and the picture has not changed
for 60 ms, or at 420 ms (then marked estimated); the other eye's pose goes
out at that moment. In a test with the eyes 60 cm apart every shown picture
matched its tag (100 %, settling from 170 ms with a 350 ms maximum; the
defaults are longer). If the head moves while an eye's pose is in flight,
adaptive gives up the eye and sends the head at once.

**vhmdd** gets the same pose as the rendered camera, with its rotation
(§5.6.5); `set_pose` moves only ARKit's anchor (§5.5.10 item 2).

**Picture counting.** The presenter swaps at 60 Hz whether or not it has
a new picture, so pictures are counted by content (§4.2). Damage is kept
**per view** (`display-stream.md` §4.2 against the viewer's copy of that
view), so a still scene costs nothing in either eye once both are sent.

**Rotation.** Until the HID bundle's fix (`visionos.md` §5.5.10: the
Orientation child made as a quaternion orientation event) the guest
ignored the pose's rotation; with it, a yaw of +30° turns the view left at
the plain home view (Thor, 2026-11-01). `YCODE_XR_GUEST_ROTATION=0` keeps
a diagnostic: the rendered camera gets the eye's position only and the tag
says so, which shows a correct world-locked window.

Server switches (environment of `ycode-simd`): `YCODE_XR_SETTLE_MS` (250),
`YCODE_XR_SETTLE_MAX_MS` (420), `YCODE_XR_RENDER_DELAY_MS` (240),
`YCODE_XR_LATCH` (mono tags by picture count when the render delay is 0).

### 4.1 Messages (`display-stream.md` §18)

| Type | Direction | Payload |
|---|---|---|
| 0x8D views | client → server | u32 sequence, u8 flags (bit 0 stereo), u8 0, u16 0, head, left, right: each 3 × f32 position, 4 × f32 quaternion x, y, z, w (stage frame) |
| 0x0A frame view | server → client, just before the frame it describes | u64 frame sequence, u8 view (0 mono, 1 left, 2 right), u8 flags (bit 0: estimated), u16 latch, u32 pose sequence (the views message the pose came from), pose (3 × f32, 4 × f32), 4 × f32 field-of-view tangents (left, right, up, down; left and down negative), u64 guest frame |

Client hello: `xr` = `{"stereo": "adaptive" | "alternate" | "mono",
"latch": n, "settleMs": n}` (all but `stereo` optional). Server hello: `xr: true` (a visionOS device whose server
has the headset mode). A viewer facing a server without `xr` falls back to
mono with pose messages (0x8A) and shows each picture at the head pose it
was received at (no tag).

The stream's encoding is the best both ends have (`display-stream.md` §14):
one encoder per view, and with one view (`--stereo synth`) one encoder.

### 4.2 Picture signature

64 × 36 samples of the BGRA surface (one 32-bit word each, evenly spread),
FNV-1a hashed. A change of the camera moves every textured part of the
room, so pictures of different poses differ; a picture that changes nowhere
at the samples counts as the same picture (cost: 2304 words per frame
record).

### 4.3 What the guest's camera does with a pose

- **Rotation** turns the view since the HID bundle's fix (`visionos.md`
  §5.5.10, §5.5.11). `YCODE_XR_GUEST_ROTATION=0` keeps the diagnostic of
  §4: the eye's position only.
- **Smoothing is the guest's own** (`visionos.md` §5.5.12, parity): the
  first change comes 3–4 presented pictures after a pose, then the camera
  closes in over a few more. (Since the event clock fix a window app has
  about 60 pictures/s and 75 ms to the first change, `visionos.md` §10.28.1;
  the rates in this document were measured before it.) Under Ycode at about
  23 pictures/s that is
  about 170 ms and 250 ms more. The server therefore sends a pose only when
  the head moved beyond a deadband (0.5 mm, 0.05°): repeating a pose slows
  the guest's settling.
- **Tags in motion** name the pose sent six picture intervals before the
  picture (measured, an exponential average of the interval; 60–400 ms);
  eye pictures are taken once settled: at least 250 ms and six intervals,
  quiet for 60 ms, at most four intervals more.

### 4.4 Field of view: the display's shape

The guest's projection has tangents (1, 1, h/w, h/w) (`visionos.md`
§5.6.6): 90° horizontally always, vertically as the display's aspect.
Ycode sets the display (`YCODE_VISION_SCREEN=<w>x<h>`, a ycode-simd
environment switch; the device type's default stays 3840 × 2160). Measured
on the Thor (screenshots checked):

| Display | Field of view | Guest pictures/s (walk script) |
|---|---|---|
| 3840 × 2160 | 90° × 58.7° | 23.5–23.7 (load 15–80) |
| 2732 × 2048 | 90° × 73.7° | — |
| 3072 × 3072 | 90° × 90° | 23.7–23.8 (load 18–40) |
| **2160 × 3840** | **90° × 121°** | 16.7–19.6 under load 50–168 (to be measured quietly) |

The Quest Pro's per-eye field is about 94° × 96°: 2160 × 3840 covers it
vertically with margin at the same pixel count as 3840 × 2160 and about
24 pixels per degree (the headset's own density); 2160 × 2400 would just
fit (±48°). The guest's picture rate did not follow its pixel count.

### 4.5 Foveated streaming (`--foveate`)

The viewer sends where the eyes look in the guest's view (0x8E fovea:
u32 sequence, f32 u, f32 v from the top left; latest wins, at most once a
frame and only when it moved 0.4 %). The server sends each picture at the
hello's downscale (2 by default with `--foveate`) and right after it a
**full-resolution inset** (0x0B: u64 frame sequence, u8 view, u8 encoding,
u16 x, y, w, h, u16 full width, height, then one JPEG) of a fraction of each
side (`xr.foveaFraction`, 0.35 by default: 1344 × 752 of 3840 × 2160) on
16-pixel boundaries around the gaze. Rule for a gaze that moves while the
picture does not: a new inset of the same picture when the gaze moved more
than 5 % of the picture, at most every 33 ms; a new picture always carries
the newest gaze. The viewer decodes the inset, feathers its outer 8 % to
transparent and submits it as a **second projection layer** over the
picture, same pose, with its own sub-frustum (the tangents of its rectangle
within the picture's), so the runtime places it exactly; nothing is
upscaled on the CPU.

| 3840 × 2160 guest, JPEG q80 | Bytes/s | Thor encode per picture | Seen → decoded p50 / p90 |
|---|---|---|---|
| ½ resolution | about 3.3 MB/s | 11.9 ms | 17.0 / 26.6 ms |
| full | 10.6 MB/s | 8–10 ms | 13–24 / 20–26 ms |
| foveated 35 % | 4.7 MB/s | 10.5 ms + inset 4.3 ms (61 KB) | 15.1 / 19.7 ms |

The viewer uploads about 12 MB per picture instead of 33 MB. The gaze point
travels only on the stream (the link's encryption), is never logged (the
input trace notes a "fovea" kind without coordinates), never recorded
(recordings use the composited picture), and the server keeps only the
newest.

### 4.6 Eye pictures turned outwards (`--eye-yaw`)

The headset's per-eye frustum is asymmetric (left eye −54° … +40°, right
eye −40° … +54°); the guest's is ±45°. With `xr.eyeYawDegrees` = 7 the
server turns each eye's rendered camera outwards by 7° about the eye's up
axis (`XRViews.canted`) and the tags carry the turned pose: each eye's
picture covers −52° … +38° (left), 90° of its 94°, 2° short at either side.
The head (mono) is never turned. Checked offline: with the eyes 60 cm
apart and turned 7°, every shown picture matched its tag (20 of 20).
With depth re-projection (`xr-depth.md` §6) the default is `--stereo
synth`, one view for both eyes, which is never turned: `--eye-yaw` applies
only with `--stereo adaptive` or `alternate`.

## 5. Input mapping (`XRInputMapper`, every headset frame)

All in the stage frame (§3); messages as `display-stream.md` §17.

| Headset | visionOS input |
|---|---|
| head (VIEW space) | the camera: `views` (0x8D) to a headset server, the pose (0x8A) to an older one; vhmdd `set_pose` follows the head (server) |
| eyes (`XR_EXT_eye_gaze_interaction` pose) | the gaze ray: origin = the gaze pose's position, direction = its −Z (`--pointer auto`/`eyes`) |
| no eye gaze | the newest controller's aim ray, else the head's forward (`auto`); `controller`, `head` force one |
| hand joints (`XR_EXT_hand_tracking`) | per hand: **pinch** from thumb tip to index tip with hysteresis (on < 2.0 cm between joint centres, off > 3.5 cm); position = the pinch point (halfway between the tips); **allowDirect** when the index finger is extended (straightness = metacarpal-to-tip distance / length along its bones, on > 0.92, off < 0.85) and the hand is not pinching, and then the position is the index tip; orientation = the head's (R9's validated choice; `--palm`: the palm joint's) |
| a hand not tracked, with a controller | position = grip (else aim); pinch = trigger (on > 0.7, off < 0.4) |
| neither | the hand rests at camera-space (±0.15, −0.35, −0.4), open (§5.5.8 item 4) |
| A or X | the Digital Crown's button (source 0) with the real down/up timing: a click is Home, a hold ≥ 0.5 s recentres (§5.5.9) |
| thumbstick y (either) | the crown turn: the immersion amount a changes by 0.5 × y per second (dead zone 0.2), clamped to [0, 1], sent absolute (`vision immersion a`, at most 10 per second, latest wins; §5.5.9 rule: absolute amounts, never relative) |
| right thumbstick click, or the headset's recenter | **recentre**: the anchor moves to the head (the camera is the default eye again), and the crown is held for 0.7 s so the guest places its content in front of the camera (§5.5.9) |

**The wearer's hands** (`--hands rendered`, the default; §5.1): drawn
from the joints over the picture. **Immersion** from the thumbstick is on
(`--no-immersion` turns it off); it hung Ycode's GPU translation in run 3,
fixed by GPU-SIRI and checked on a fresh device (0.8 and 0.2 from the home
view).

**The gaze is filtered** before it becomes the guest's ray and the fovea
(`XRGaze.swift`, §13.3): in the frame the eyes hold (the world during the
vestibulo-ocular reflex, the head when they travel with it), steady on a fixation,
with no lag on a saccade. `--gaze-filter oneeuro` is the One-Euro filter in head
space of runs 5–8. The viewer reports, at the end, the gaze's samples, dropouts,
saccades (a frame step over 3°), the frame-to-frame RMS while fixating (steps under
1.5°), the RMS the filter removed, how far the ray is behind the eye by time since
a saccade, and the times the ray entered another 3° cell — counts and spreads only
(§8).

**A dropout** (a blink) holds the last ray for up to 350 ms, in the world; only then
does the pointer fall back. It used to jump to the head's forward in that same frame.
A sample the runtime no longer marks as tracked counts as a dropout. **A pinch**: the
ray stays at the place it began until the release (the desktop viewers' rule,
`visionos.md` §5.5.8 item 4); a pinch within 70 ms of a saccade takes the fixation the
eyes left; the release takes two samples over the threshold, so a bounce is no
release; a hand the tracker loses for up to 200 ms stays where it was, pinched or not
(it used to jump to its rest and release); the hand's motion inside 12 mm of where the
pinch began is not sent, so closing and opening the fingers is no drag.

Selections go out about once per 16 ms and at once on a pinch change (the
server coalesces as before). When the viewer leaves, the server releases an
open pinch (§17). Hands-only use has no Home gesture yet (the system's own
palm pinch belongs to the headset); a controller's A/X is the crown.

### 5.1 The wearer's hands

One soft disc per joint of XR_EXT_hand_tracking (wrist and the 24 finger
joints) and one between the joints of each finger bone: 44 per hand, sized
2.2 × the runtime's joint radius, half-transparent white, the thumb and
index tips amber while the hand pinches. Each hand's discs are drawn on the
CPU (about 1 ms) into one 256² image, as seen from the eye, on a quad at
the hand's centre facing the eye: **one OpenXR quad layer per hand**,
composited by the runtime at its own rate (90 Hz) from the joints of the
frame being drawn; they never wait for the guest and are not sent to it.
(Runs 4 and 4b drew one layer per disc, 88 and 24 layers: WiVRn
composites each layer over the whole eye image, the x86 GPU went to
98–100 % and the headset to about 28 Hz.) Ycode's procedural model; no hand assets. The
headset's passthrough is not offered by WiVRn 26.9 (no
`XR_FB_passthrough`); its alpha-blend mode would need the picture masked on
the GPU each frame (follow-up).

## 6. Latency and rates

Stages of one shown picture, on the viewer's clock (`--measure` writes
them): the pose's views message sent → the picture rendered with it
received and decoded → uploaded into the swapchain → its predicted display
time (`XR_KHR_convert_timespec_time`). Head **rotation** to photon is the
runtime's own: every displayed frame is reprojected from the pose its
image carries, so the guest's lag shows as the picture catching up, not as
the world swimming.

Measured 2026-11-01 with Ycode's simulator on the Thor (visionOS 27.0 at the
home view, load 8–25), the display socket forwarded to the x86 PC by ssh,
zlib tiles at downscale 2, scripts replayed by `ycode-xr-viewer --replay`
(`--dump` per frame: tag, decode time, a 32 × 18 grey thumbnail, the
pose's send time):

| What | Value |
|---|---|
| Guest pictures per second, the camera changing every picture (mono slide) | 23.5 (interval p50 44 ms, p90 50 ms) |
| Same, a new eye's pose after every picture (alternate, no settling) | 24 — the pose messages do not slow the guest |
| Pose sent → first change of the picture (pose steps of ±0.3 m, mono) | about 170 ms (167–218 ms) |
| Pose sent → the picture has converged | about 370–420 ms (RMS distance to the final picture 23 → 11 → 9 → 6 → 0.5 → 0, one value per picture after the first change) |
| Pose sent → picture decoded on the x86, moving head, mono tags | p10 70, p50 74, p90 85 ms with the tag's pose the latest sent (latch 1); the picture actually shows a pose about 240 ms older, which the tag now names (render delay) |
| The stream's own share (record seen → decoded) | a few ms (`display-stream.md` §16: 6–10 ms at full size with JPEG) |
| Alternate stereo with settling | 2.6 eye pictures per second (1.3 Hz per eye); 100 % of shown pictures matched their tag |

So the guest's own camera path (170 ms to start, about 250 ms more to
settle) dominates; the stream, the decode and the upload add
milliseconds. Per-eye rates of 30 Hz would need the guest's camera
smoothing gone or a guest-native second view (§11).

*(The live run's head-motion-to-photon on the headset: §9.2.)*

## 7. The viewer (`ycode-xr-viewer`)

`ycode-xr-viewer --link <device> [--host N] [--media udp|tcp]` or
`--connect <address>`; `--stereo adaptive|alternate|mono` (§4), `--latch
n`, `--settle ms`, `--pointer auto|eyes|controller|head`, `--palm`,
`--encoding auto|hevc444|hevc|h264|jpeg|zlib` (auto: the best both ends have; a
name is the first wish, and what follows it in that order the fallback; a
fallback always prints which, why and what to expect, `display-stream.md`
§14.1), `--video-qp n` (default 20), `--video-bitrate kbit/s` and
`--video-fps n` (CBR instead, one picture of VBV), `--quality` (JPEG), `--downscale` (1–4; 1 = the guest's 3840 × 2160 per eye),
`--fps`, `--seconds`, `--measure <tsv>` (§6), `--record <script>` (tracking
as JSON lines, without the gaze), `--replay <script>` (no headset: the
script drives the same mapping and the stream: the stand-in for tests),
`--dump <tsv>` (per frame: tag, times, a grey thumbnail; §9.1), `--drive
<script>` (the headset's session with a script's tracking, looped: the whole
display path without a wearer), `--probe
[--session]` (§2), `--verbose`. Over the link (the way to run it: no ssh, §12.1) the frames go by
TCP unless `--media udp`: a video keyframe is hundreds of datagrams, and one
lost costs a whole new keyframe. `--hands rendered|off`,
`--immersion`, `--foveate [fraction]`, `--eye-yaw deg`,
`--record <file.mp4>` and `--record-cursor` (§7.1), `--record-tracking
<script>`; the gaze path's and the picture's options: §13.6. A line every 5 s gives headset frames,
tracked frames and the stream's counts (off the headset's loop since XR-GAZE: the summary sorts every sample so far). `ycode sim remote [--host N] view
<device> --xr [viewer options]` runs it for a device of a paired host (it
finds `ycode-xr-viewer` next to `ycode`, or `$YCODE_XR_VIEWER`).

### 7.1 Recording (`--record <file.mp4>`)

What the left eye sees — the picture and the hands — cropped to its centred
16:9 and scaled to 1920 × 1080, at 60 frames per second on the recorder's
own clock from the newest state the headset loop hands over (no copy, never
waiting), only while the headset tracks (worn); 30 frames a second and
1 Mbit/s by default (about 7.5 MB a minute; `--record-fps`,
`--record-bitrate`). During the session the recorder's thread draws and
JPEG-compresses each frame on the CPU into `<file>.spool` (5.6 ms per
frame); after the session it decodes the spool, encodes H.264 with NVENC
(CYcodeVideo) and writes the MP4 with Ycode's own writer (one track, one
chunk: ftyp, mdat, moov with avcC, stts from the frames' times, stss every
IDR at 2 s), then removes the spool. The GPU's encoder is not used during
the session: WiVRn streams to the headset with it, and sharing it in run 3
slowed the headset to about 20 Hz and its predicted display to 150 ms. A
20 s replay gave 1261 frames, none dropped, encoded in 9.1 s afterwards;
`--record-cursor` draws a ring where the eyes look (off by default: no eye
data in the file).

### 7.2 Switching control (`--state-file`, XR-HUB 2026-11-02)

For Device Hub's View in Headset / Back to Desktop (`specs/ide/device-hub.md`
§I.12) the viewer has a small control interface and nothing else changed:
`--state-file <path>` gets one JSON object, rewritten whole through a
temporary file — `{"phase": "waitingForHeadset"}` at start, `"streaming"`
when the first picture arrives (the display is the headset's now),
`"stopped"` at the end (with `"message"` when the exit status was not 0),
and `"pid"`. SIGTERM and SIGINT end it cleanly (the OpenXR session is asked
to exit; `--replay` stops between samples). The server's takeover notice
(`display-stream.md` §1.1) ends it too: the headset never fights another
viewer for the display. `ycode sim headset view` and the hub start it
detached on the viewer host and poll the file.

## 8. Privacy

Eye-gaze data is used for one thing: the gaze ray of the current frame,
sent to the simulator over the link (encrypted, `sim-link.md`) and handed
to the guest's HID bundle. It is **never logged, traced, recorded or
stored** by the viewer, the server or the shim: `--record` drops it,
`--verbose` and the summaries print counts only, the server's input trace
(`YCODE_DISPLAY_TIMING`) records the kind and time of a selection but no
ray, and nothing keeps a gaze sample past the frame (the fixation filter keeps its
own state and the one fixation a pinch can go back to, in memory). `--gaze-calibrate`
keeps the tracker's constant error in memory for the session and logs only its size;
the pinch log gives times and states, never a direction; `--hover-probe` and
`--tag-probe` exist only in `--replay`, with a written script's gaze. Hand and head poses
are recorded only by `--record`, on the viewer's machine, when asked.

## 9. Runs

### 9.1 Recorded scripts, Thor → x86 (2026-11-01)

Device: a copy of `visionos9/devices/base` (visionOS 27.0 runtime), booted
with this branch's release build (`ide-remote/xr-viewer/bin/xboot.sh`:
`--display-server unix:<run>/display.sock`); home view after 57–65 s. The
x86 viewer reached it through `ssh -L 127.0.0.1:47950:<socket>`. Scripts
(`mkscript.py`, our own): `calib` (eyes 60 cm apart, still), `step` (the
head jumps ±0.3 m every second), `slide` (the head slides ±0.2 m), `walk`
(the head turns ±20° and its eyes 63 mm apart). Analysis: `latch.py`
(k-means of the thumbnails into two clusters against the tags) and
`conv.py` (convergence after a step).

| Run | Result |
|---|---|
| alternate, a new eye every picture, latch 2 / 1 | tags agree with the pictures 24 % / 68 % |
| alternate, hold 1 / 2 / 3 pictures | 52 % / 62 % / 31 % |
| alternate, settle ≥ 200 ms / 300 ms (quiet rule, then the next eye) | 100 % / 100 % (92 and 41 frames in 20 s) |
| mono `step` | first change ≈ 170 ms after the pose, converged ≈ 400 ms |
| adaptive `walk` (moving all the time) | 939 mono frames in 40 s (23.5/s), no eye pictures |
| `vision pose 0 0 0 30 0` before / after the HID fix | byte-identical to identity / turned left (`visionos.md` §5.5.10) |

Also checked: JPEG tiles need libjpeg's header at the viewer's build time;
without it the viewer asks for what comes next, and says so (§12.1).

### 9.2 Live runs with the headset (2026-11-01, the owner, Quest Pro over WiVRn)

| Run | Settings | Result |
|---|---|---|
| 2 | zlib, ½ resolution, adaptive (stillness 4 mm / 0.4°) | the room stayed put while turning; depth while still; look-and-pinch opened Settings and Photos. 90 Hz headset, about 14 pictures/s shown, stereo in 1 % of pictures (threshold too strict: now 1.5 cm / 1.5°); frame seen → decoded 74 ms (zlib encode 37 ms); tagged pose → shown 381 ms |
| 3 | JPEG full resolution, MP4 recording on the GPU | "a lot more laggy": the recording's NVENC competed with WiVRn's (headset about 20 Hz, predicted display 150 ms), and a second boot of ours loaded the Thor (network 200 ms). Without recording (3c): 90 Hz, seen → decoded 12 ms, stereo 34 + 29 eye pictures |
| 4 | 2160 × 3840, foveated, hands as 88 disc layers, MP4 recording | headset about 28 Hz, x86 GPU 98–100 %; 1175 pictures (151 eye pictures); frame seen → decoded 23 ms; MP4 5748 frames, 1 dropped |
| 4b | the same with 24 disc layers, no recording | "worse in some ways": flicker between the 9:16 picture and a full surround (most likely the runtime's own scene when our frames came late), selection "finicky". 78 Hz average; 3817 pictures (230 eye pictures); frame seen → decoded 12.1 / 14.5 ms; insets 4250 × 72 KB, 4.1 ms; WiVRn's predicted display 147 ms (33 ms in run 2). Fixed after: one layer per hand, separate swapchains per view (§3), a new picture waits up to 50 ms for its inset. Offline check with `--drive`: GPU 14–20 %, loop p99 3.4 ms |
| 3 | thumbstick immersion | the guest's GPU hung in `immersivemask::precomputeMaskTransition` (6 × 11 groups of 32 × 16 threads), the device was lost and backboardd aborted in a loop ("Command buffer SharedEventSignalBuffer failed to execute"); Siri's `affordanceDynamicPointLight` (also 32 × 16) hung the same way in run 2. Ycode GPU bugs (a kernel hang, a lost device not recreated), reported; immersion now needs `--immersion` |

Controllers worked (A = Home, hold A = recentre, thumbstick).

### 9.3 What run 8 leaves open (XR-ICONS, 2026-11-02)

Run 8's server had a translator of 2026-10-13 (`visionos.md` §10.29). The bands
beside the home icons with re-projection on are fixed (`xr-depth.md` §5.6). For the next
headset run, on a tree with both fixes:

1. Look at the home view from the sofa, sway a few centimetres, then step 10 cm
   sideways. Is there still anything like a cylinder?
2. The same with `--stereo adaptive --reproject off`. If it shows there, that is
   not re-projection: say which icon and the head's position, and the operator then
   runs `touch` on the file named by `YCODE_GPU_FRAME_MAP_FILE` (with the count in it)
   and takes a screenshot at that moment, so that the picture and its draws can be
   read.
3. While the head moves, do the icons lag or lose part of a disc (`xr-depth.md` §5.6,
   "what it costs")?

## 10. Open questions (for an observation of the reference)

Q-XR1–Q-XR4 (what decides the view count, two native views, the
two-slice passes, vhmdd stereo commands) are answered in `visionos.md`
§5.6: one view, fixed inside the guest; no host input changes it. The
pose's rotation is answered in §5.5.10.

- **Q-XR5** Does the reference's rendered camera follow a new pose at once
  or smoothed, and over what time (under Ycode: first change about 170 ms
  after the pose, settled about 250 ms later, §6)? If the reference is
  faster, the difference is Ycode's to find; if the smoothing is the
  guest's own (a filter on the head pose), a host cannot avoid it, and
  alternate-eye stereo stays slow.

- **Q-XR6** While a pinch is held on the reference, does a moving gaze ray change
  anything (under Ycode the viewer now holds it, as the desktop viewers do)?
- **Q-XR7** When a hand has `allowDirect` set away from any element (an open hand with a
  straight index finger), does the reference's hover or indirect pinch behave any
  differently? Ycode's viewer sets it for a straight finger; `--poke off` is the A/B.
- **Q-XR8** How far from an element does the reference's hover still catch it, on the
  home view's icons? Under Ycode a ray 2.9° off an icon's centre still highlights it
  (§13.3).

## 11. Next steps

*Depth re-projection, synthesised stereo and the surround (world cache,
environment) are `xr-depth.md` (XR-DEPTH): `--reproject`, `--stereo synth`.*

- Native two views if Q-XR1/Q-XR2 allow (the frame view message already
  names the view; two images per guest frame would be two tagged frames).
- Faster eyes: if the guest's camera smoothing has a switch or a host
  input (Q-XR5), eyes could alternate on every picture (about 12 Hz per
  eye at today's 23 pictures/s).
- Corners of the depth mesh sit at the corners of depth blocks, half a block
  off the blocks' centres (2 picture pixels at 1/4): at rest it does not show
  (§12.3), in parallax it shifts edges by that much.
- Done (XR-HUB): Device Hub's View in Headset / Back to Desktop and the
  headset onboarding (`device-hub.md` §I.12), `ycode sim headset`, `ycode
  sim remote view --xr --background | --desktop`. The display size stays a
  boot choice (`--vision-display`; the guest reads it once, §I.12.5).

## 12. Run 7 and what changed (XR-QUALITY, 2026-11-02)

Run 7: the owner in the headset, defaults, 2160 × 3840: "the simulator takes up
the full view now", but "very weird artifacting and aliasing on certain parts
of the scene and on the UI", and selection "more finicky". 4.2 pictures/s,
28 MB/s, seen → decoded 158 / 177 ms.

### 12.1 Codec and transport

**Cause.** The viewer's default was `jpeg`. The x86 PC had `libjpeg.so.8` but no
`jpeglib.h` when the viewer was built, so JPEG was compiled out, and the hello fell
back to zlib without a word. H.264 was never asked for, though NVDEC was there all
along (`ycode-sim-viewer` had used it). The frames then went over an ssh forward.
(`libjpeg-turbo8-dev` was installed on the PC later that day, so builds since then
decode JPEG; the default no longer depends on it.)

**Fix.** `display-stream.md` §14: HEVC 4:4:4, HEVC, H.264, JPEG, zlib by runtime
capability checks at both ends; every fallback is loud. The XR path always could
carry tags, depth and pictures in video (they are paired by frame sequence); the
foveated inset stays JPEG over tiles, and `--foveate` says so when it cannot work.
The link (`sim-link.md`) replaces the ssh forward: it had never carried the headset
mode, and over UDP a frame could outrun its frame view (TCP) and arrive untagged,
so the frame view now goes with its frame.

| Same scene, same script | Pictures/s | Rate | Seen → decoded p50 / p90 | Ours: seen → shown p50 / p90 |
|---|---|---|---|---|
| Run 7 (headset): zlib, ssh | 4.2 | 28 MB/s | 158 / 177 ms | — (§12.2) |
| zlib, ssh (offscreen, the same load) | 5.7 | 59 MB/s | 201 / 234 ms | 212 / 246 ms |
| **hevc444 QP 20, link TCP** | 28.6–35.1 | 2.8–3.4 MB/s | 19.4–19.8 / 22.6–22.8 ms | about 30 / 38 ms (of it 11 ms waiting for the headset frame and the upload) |

Pictures per second follow the guest and the Thor's load (30–60 from other agents).

### 12.2 The 12.6 s "ours" p90

**Mis-measured.** "Ours" was recorded only in the path without re-projection. That
path ran only when the headset stopped tracking (taken off, at the end of the
run), and uploaded a picture decoded 12.5 s before; there were two samples, both
from then. The re-projection path now records every picture, and the other path
no longer counts when re-projection is on. Nothing stalled. The summary also gives
pictures per second and the stream's rate, and the clock is re-synchronised every
second (three pings at connect left it off by 100 ms and more).

### 12.3 Artifacts and aliasing

Offscreen captures at the headset's 2700 × 2970 per eye, the Settings window open,
before (XR-DEPTH's viewer) and after, the right eye at rest and 6 cm to the side.

| Cause | Where it showed | Fix | After |
|---|---|---|---|
| Every triangle across a depth edge took one flat colour, moved or not (a band of 4 picture pixels around each edge, staircased, in the picture and in the cache) | Curtains, lampshades, shelves, window corners: the jagged, blocky edges | A triangle samples at its own place until the move stretches it, then one colour of the background (`xr-depth.md` §5.2); over the cache it is kept until then too | The curtain and shelf edges are clean; at the picture's own viewpoint every pixel is the picture (test) |
| Colours decoded with the wrong matrix (BT.601 for BT.709) on every video path | Would have shifted saturated colours as soon as video was on | BT.709 everywhere, signalled in the VUI (`display-stream.md` §14) | PSNR 27.7 → 35.1 dB in G on a synthetic UI |
| 4:2:0 chroma, once video is on | Coloured icon details and coloured text smear | HEVC 4:4:4 | Window, R / B: +2.2 / +3 dB against H.264 at QP 24, +5 / +6 dB at 50 Mbit/s (`display-stream.md` §14.2) |
| No mips: the picture and the cache are minified off-axis (at 45° off the guest's axis the picture has twice the pixels per degree; a cube face's corners about three times) | Shimmer on turning, off-centre | Mip chains, trilinear, anisotropy 8 where the device has it (the session enables it); a partly empty cache texel no longer darkens | A 1-pixel checker minified 8 × is flat within 6 levels (test); GPU per eye p50 1.3 ms, unchanged |
| Environment 128² per face (1.4 texels per degree) | Blur wherever the cache has nothing yet | The cube's top level, 256² (the guest's largest). One message, about 3 MB raw: no need to send it in stages on this link | Still soft: it shows only until the sweep (§5.5 of `xr-depth.md`) and in holes |
| A slow guest during the sweep: "nothing new for 1.5 s" took the last stop's picture at this stop's pose; a stop out of time left a hole | A band of wrong room or of the cube in one direction (2 of 7 stops at load 60) | The rule does not apply in a sweep; a stop out of time takes its own newest picture | 0 of 7 stops missed in four runs of five at load 30–60, 1 in the fifth (no picture of it came in 2.5 s) |

Remaining: steps of 4 picture pixels on curved depth edges in parallax (window
corners). `--depth 2` halves them, visibly, at a cost: GPU per eye p50 3.07 ms
against 1.30 ms, the x86 GPU at 67 % against 25 % offscreen at 90 Hz. Worth trying
in the headset; not the default until a headset run shows the runtime keeps its
frame rate. A dark sliver can remain at the very corner of a window, where the
uncovered wedge meets the fill. The decorative dark panel at the eye's right edge in
the living room is the room's own wall, not an artifact.

### 12.4 Selection

**The mapping is right.** The gaze goes to the guest as a ray in the stage frame and
the guest hits it against its own geometry (`visionos.md` §5.5.1): neither the camera
hold, the displayed frame nor an eye enters. Tests with synthetic poses
(`XRSelectionTests`): a target on a window plane, the head still, 1 cm and 1° inside
the hold, or 10 cm and 15° ahead of a stale picture: the ray hits the target's guest
pixel, and the re-projected picture shows that same pixel along the gaze
(within 1.2 % of the picture); also without re-projection, with a turned anchor, and
from either eye's place.

**The likely cause is feedback** (found by reading the path and the numbers; only a
headset run can confirm it). At 4.2 pictures/s and 158 ms a hover highlight showed about
300–400 ms late, and after any head movement past the hold's band (1.5 cm, 1.5°;
run 7's p50 between picture and eye was 2.7°) new pictures stayed *under the cache*
until they were final, up to 800 ms, which hid hovers and pinch feedback. So a picture of a camera pose that already has a
final picture is now final at once: only its content changed (`XRFinalPictureRule`). With the codec, the stream adds about
30 ms to the guest's own time. Pinches went out at once already. The first picture
after a move past the band still waits for its final state: moving content under a
moving head stays as `xr-depth.md` §9 says.

### 12.5 Resolution

hevc444 QP 20, link, `walk` script, the same Thor load:

| Display | Field of view | Pictures/s | Rate | Seen → decoded p50 / p90 |
|---|---|---|---|---|
| 2160 × 3840 | 90° × 121° | 28.6–35.1 | 2.8–3.4 MB/s | 19.4–19.8 / 22.6–22.8 ms |
| 3840 × 2160 | 90° × 58.7° | 33.7–46.8 | 4.2–5.8 MB/s | 18.7–19.1 / 22.2–22.4 ms |

The same pixel count costs the same: **keep 2160 × 3840** (`YCODE_VISION_SCREEN`).
It fills the headset's field vertically from one picture; 3840 × 2160 gets the
rest from the cache.

## 13. Run 8 and what changed (XR-GAZE, 2026-11-02)

Run 8: the owner in the headset, hevc444, about 35 pictures/s: "looking around the
environment seems perfectly smooth at this point", "things are still hard to grab on
to with the gaze control", "some interruption / pause hiccups for a couple of
seconds". `--stereo adaptive --reproject off` had a queue of 11 s. Run 8 used a stale
translator (of 10-13, many visionOS pipelines failed), so its guest-side rates are no
baseline; its viewer and stream stages stand. Everything measured below is with a
current translator, at 2160 × 3840, the viewer offscreen on the x86 (`--replay`, no
headset, no WiVRn) with written scripts, the load being the Thor's at the start and
end of the arm, with another agent's device running on it.

### 13.1 Hiccups

The viewer records every stretch over 250 ms without a new picture while tracked
(`XRGapRecorder`), with both ends: the guest's presents (60 a second while its
presenter lives, `visionos.md` §10.28), the capture gap, the way here, the time here,
the longest headset frame and our work in it, what was asked since the last picture
(camera moves, pinches, saccades) and for how long unanswered, the head's motion, the
time the picture was under the cache. The server logs its side (`XRServerGapLog`:
presents, scans and how many found nothing, poses, selections, pinch changes, the
window, the load). No gaze, no pose values. `idle` lines are counted, not printed.

| Class | What it is | Measured | Whose | Done |
|---|---|---|---|---|
| **Under the cache** | Pictures come, but the newest is drawn under the world cache: hover and pinch feedback, a window opening, do not show | A head wandering at up to 5°/s, run 8's rules (load 10–12): **90 % of the headset frames, longest 9.5 s**. Turns of 30° with 3 s rests: 30 %, longest 1.3 s. Run 8's own log fits (14–22 poses/s, 2 % of its pictures final; inferred, it did not count this) | Ycode | §13.5: 2.8–3.1 % and 753–842 ms, the sweep's only; turns 20 %, 823 ms |
| **Guest's presenter stopped** | Presents +2 to +11 over the stretch, asked and unanswered | Intermittent, about the owner's "couple of seconds": one 5-minute arm (load 7–11) had 6 (33 s, **longest 17.8 s**); 3.5 s once (load 5–8); 1.0 s in its repeat (load 6–8); 1.0 s at load 41 with another device booting. Two other 5-minute arms had none (load 15–19 on a device 3–9 min old; load 2.5–5 at 18–24 min) | Ycode's simulator (host side or guest kernel; not found) | Open, §13.7 |
| Guest, no new picture | Presenter alive, camera moved, no new picture | With the stalls above: 11 (12.5 s, longest 2.5 s). Without: 0–2 (one 1.2 s just after the sweep) | Simulator | Open |
| Stream | Captured on time, arrived late (way here 365–1351 ms, never on the network's account: p50 1 ms) | 5 (4.4 s, longest 1.4 s), only together with the stalls above. None elsewhere | Simulator's host side, inferred (the encode or the send held up) | Open |
| Viewer | Received long before uploaded; our loop | None over 250 ms in any arm; the longest headset frame 24–37 ms offscreen. Run 8: at most 77 ms; the 5 s summary sorted every sample on the headset's loop (from reading; it grows with the session) | Ycode | Summary off the loop |
| Runtime (WiVRn) | xrWaitFrame | Run 8: 447–451 headset frames in every 5 s window while tracked, so its loop never stalled for hiccups of seconds. Not reproducible offscreen. WiVRn's link to the headset cannot be seen from the loop | — | The viewer now logs long waits and stretches of stale tracking samples (`XRStaleTracking`) |
| Nothing asked | A rest; a saccade over nothing | Most stretches: `idle`, `idle-gaze` | — | — |

A hiccup in the headset tells itself apart: everything frozen to the head is WiVRn's
link; the world follows the head and the content does not move is the guest or the
cache. The gap lines then say which.

### 13.2 The 11 s queue

**Cause** (the two mechanisms read from the code, then reproduced). Without
re-projection, a 4:4:4 picture went through `StreamCanvas.withPixels`: a BGRX
conversion on one thread on the headset's loop, holding the lock the decoder needs,
then a copy. Run 8d: 33 headset frames/s, decode 30 ms against 8 ms alone. That made
the stream's consumer slower than the guest, and nothing dropped: the link's transport
kept every message in an unbounded queue behind its TCP reader, and TCP's buffers
hold seconds of video at this rate. "Network" was that queue.

**Fix.** (a) Latest wins: the frame window, `display-stream.md` §4.2.1 (`--frame-window
3`): the server captures only with room in the window, so nothing queues, the next
frame is the newest picture and no keyframe is needed. (b) Planes convert on 8 threads
straight into the staging buffer (`yxr_upload_yuv444`). (c) The transport's queue is
bounded (16 MB). `--upload bgrx`, `--frame-window 0` and `--slow-consumer ms` remain for
A/B; `--replay --reproject off` runs this path offscreen (conversion and copies, not the
swapchain's).

| Arm (`walk60`: the head always moving) | Load | Pictures/s | Stream p50 / p90 ms | "Network" p50 ms |
|---|---|---|---|---|
| Run 8d (headset) | — | 22.4 | 11 474 / 14 913 | 11 420 |
| Slow consumer 50 ms a picture, no window | 11 | 17.3 | **12 205 / 20 784** | 12 188 |
| Slow consumer 50 ms a picture, window 3 | 11 → 9 | 17.3 | **102 / 110** | 77 |
| Run 8's path, no window, guest slower than it | 41 → 22 | 27.0 | 26 / 297 | 1.0 |
| **New path, window 3** | 21 → 15 | 28.3 | 19.0 / 22.0 | 0.9 |
| **New path, window 3, a fast guest** (faster than run 8d's consumer ever was) | 21 → 18 | 58.4 | 18.7 / 21.1 | 0.7 |

An upload costs p50 5.1 / p99 6.3 ms. Run 8d's other numbers (22 layer changes: adaptive
stereo doing its job; 3.3 % gaze dropouts at 33 Hz) need a headset run to compare.

### 13.3 Selection: what was found

**Measured on the real guest** (`--hover-probe`, offscreen, load 28 → 12). The gaze goes
from the floor to each of the home view's 8 icons (about 4.6° across, 8.4° apart): the
changed area's centre against where the ray points in the picture.

| | Result |
|---|---|
| Ray at an icon's centre | The highlight within **0.2–0.4°** of the ray, wherever the area is that icon alone |
| Ray 1.7° and 2.9° off the centre | Still that icon |
| Ray → first changed picture decoded | p50 131 ms, 96–220 ms |
| A camera move or pinch → next picture | p50 25–33, p90 34–66 ms during motion |

So the ray, the guest's hit test and the picture agree, end to end, on a still head.

**The guest's camera does not put the ray off.** The guest hits the ray against its own
world (§12.4), and the picture is placed by its tag. `--tag-probe` (a picture's yaw
measured against a reference picture, pure yaw, load 5): the tag is off by |p50| 0.10°,
|p90| 0.20° at a peak of 5°/s, 0.10° / 0.60° at 15°/s, 0.20° / 0.60° at 40°/s. This also
says the cache hid pictures far more than their tags deserved (§13.5). "Tagged pose sent
→ shown p90 about 1 s" is a held camera naming its old pose, not a delay.

**End to end, a pinch** (hand joints from a script, `pinch.jsonl`): eyes on Settings, moving on
to Photos 40 ms before the fingers close, three frames of lost hand in mid-pinch: Settings
opened; the log says "rewound past a saccade 22 ms ago", one pinch, "a lost hand held
for 4 frames". With `--pinch-rewind 0` the same script on a fresh device opened Photos.

**The filter: not the main cause, and worth changing** (tests, `XRGazeTests.swift`:
synthetic gaze with run 8's noise, 0.30° RMS from frame to frame, and its saccade rate).
Run 8's "filter removed 1.5–1.9° RMS" looked like a heavy filter. It is not lasting lag:
the old filter on synthetic gaze gives 1.40°, nearly all in the first 100 ms after each
saccade. With a still tracker error both filters select 1.3° targets once the eyes have
rested for 200 ms. Differences:

| On synthetic gaze | One-Euro in head space (runs 5–8) | Fixation filter |
|---|---|---|
| Ray behind the eye, first 100 ms after a saccade | 3.75° RMS | 0.29° RMS (the tracker's own noise is 0.2°) |
| A 10° saccade (43 ms) until within 1° | 122 ms | 44 ms |
| Head swaying ±6° at 0.3 Hz, eyes on a target (reflex): ray off the target | 0.67° RMS | 0.18° RMS |
| Ray entering another 3° cell, 120 s | 801 | 423 (it does not travel across what lies between; each is a possible hover the guest pays for, `visionos.md` §10.28) |
| 1.3° targets, pinch 150 ms after the saccade began | 91.5 % | 100 % |

**Bugs that a real eye and hand would hit, and tests cannot rank:** a dropout jumped the
ray to the head's forward for that frame (4–7 per run in run 8); a hand lost for a frame
released the pinch and jumped 30 cm to its rest; closing and opening the fingers moved the
pinch point, which is a drag; the ray followed the eyes during a pinch; a late saccade took the
selection with it. All fixed, each with a test.

**Not measured: the tracker's constant error.** No synthetic gaze can say whether the Quest Pro's
gaze sits where the wearer looks. A constant 1.5° misses a 2° target in nearly every try (test:
under 20 % against over 90 % with it taken off). `--gaze-dot` shows it and `--gaze-calibrate`
removes it. **Which of these was "hard to grab" is inferred, not known**: the hidden feedback
(§13.5) is the largest thing found, and only a run can rank the rest.

### 13.4 Seeing it: `--gaze-dot` and the counters

`--gaze-dot` (off by default) draws a ring with a dot at the point the viewer sends, on
the surface the ray meets in the newest depth (so both eyes agree), as one quad layer
that never goes to the guest or a recording: cyan tracking, orange a dropout's held ray,
green a pinch's ray. `--gaze-calibrate`: after the sweep five white rings, head-locked,
looked at for about 0.7 s each (one skips itself after 4 s): the median of target minus
gaze is the tracker's constant error, taken off in head space; the log gives only its
size and how far the targets disagree.

Counters, none with eye data: one line per pinch begin and end with the gaze's state
(fixating for N ms, held through a dropout, rewound past a saccade N ms ago), how long it
lasted and how close the fingers came; at the end pinches, pinches under 60 ms, near
misses, fingers' closest approach p50 / p90, frames a lost hand was held, the eye sample's
age, samples without the tracked bit. **Hover target changes per second:** the guest does
not report its target, so the server counts what it draws: bursts of small damage with the
camera still and no pinch, and a burst elsewhere is a new target (`XRHoverCounter`; gaze over
the icons: 0.3–0.45/s of bursts, 0.3/s new places in the slow arm); the viewer counts bursts
and 3° cells.

### 13.5 The picture on top

Why it was hidden: since XR-DEPTH a picture stays under the cache until **final** (800 ms
after the camera came to rest, or 300 ms with no newer one), because its tag was only trusted
then (XR-QUALITY relaxed it for a camera with a final picture). A head that never quite rests
never gets there. Now only the cache waits for a final picture. A picture goes on top

- while the camera moves under 20°/s and 20 cm/s (`--fresh-top-speed`), at its tag (measured
  above: within 0.6° at p90), and
- 350 ms after the camera came to rest (`--fresh-top`), at the camera's pose (the smoothing is
  on time, within 0.1° at about 230 ms, `visionos.md` §5.5.12).

Faster head motion still shows the cache, which is why looking around stayed smooth. The hold
band grew from 1.5° and 1.5 cm to 3° and 2 cm (`--hold-band`): a head that isn't quite still
moves no camera, and the guest renders nothing for it. A band the owner can see through: parallax
inside it is the re-projection's.

| Arm (load 10–12, except the last) | Newest picture under the cache | Longest |
|---|---|---|
| Wander, up to 5°/s, run 8's rules | 89.9 % | 9486 ms |
| Same, on top under 8°/s | 6.9 % | 753 ms (the sweep) |
| Same, on top under 20°/s (the default; 5 min arms, load 2–19) | 2.8–3.1 % | 753–842 ms (the sweep) |
| Turns of 30° in 0.6 s, run 8's rules | 29.5 % | 1342 ms |
| Same, new rules (under 8°/s) | 20.5 % | 823 ms |

What this costs is not measured in a headset: a seam or a slight swim where the fresh
picture meets the cache. Hence the A/B.

### 13.6 The options for the next run

Defaults are the new behaviour. Each line changes one thing against the defaults, so one sitting can
compare them; each is a restart of the viewer on the same device.

| # | Options | Tells |
|---|---|---|
| 1 | `--gaze-dot` | First look: does the ring sit on what the wearer looks at, does it jump or lag; is selection better than run 8 |
| 2 | `--gaze-dot --gaze-calibrate` | Look at five white rings first: is a constant error the rest of the problem (the log gives its size) |
| 3 | `--gaze-dot --fresh-top 0 --fresh-top-speed 0 --hold-band 1.5,1.5` | Run 8's picture rules: how much was hidden feedback |
| 4 | `--gaze-dot --gaze-filter oneeuro` | Run 8's filter: how much was the filter |
| 5 | `--gaze-dot --gaze-cutoff 6 --gaze-deadband 0` or `--gaze-cutoff 2 --gaze-deadband 0.2` | Quicker or steadier ring |
| 6 | `--fresh-top-speed 8` or `40` | A swim or seam while moving against hidden feedback |
| 7 | `--pinch-rewind 0 --pinch-freeze off` | Run 8's pinch: does the new one feel wrong anywhere (dragging, say) |
| 8 | `--pinch-on 2.5 --pinch-off 4` | If the log's fingers come to 2 cm or more, or near misses add up |
| 9 | `--poke off` | Whether a straight finger's direct touch gets in the way (Q-XR7) |
| 10 | `--gaze-time now` | The gaze at the present, not extrapolated to the display time |
| 11 | `--reproject off` | The comparison mode, now without its queue: pictures/s, stream, headset frames/s |
| 12 | `--hold-band 6,3` | Fewer guest renders while nearly still; parallax |

### 13.7 Open

- **The guest's presenter stopping**: the one class of seconds-long hiccups found, cause not found.
  Ruled out by the numbers: the viewer (its loop kept 90 Hz throughout), the stream (network p50 1 ms, window never
  held) and load alone (none at 15–19, 17.8 s at 7–11). Not the device's age (none at 18–24 min, the worst arm at
  19–25 min). Timed screenshots looked guilty (several stalls ended just before a `screenshot at` log line, every
  harness boot takes one each 30 s, and two arms without them had none), but the repeat with them had one stall of
  1 s, so that is not settled: boot with `SHOT_FIRST=999999` for a run, it costs nothing. Not tested: host I/O on the shared
  USB drive, where the guest's frame record lives (`/proc/pressure` does not exist on this kernel). Next: sample the
  presenter's and render server's threads during a stall (`frame-profile.md`) on a long arm. VISION-FPS-2's 2.95 s
  pose-step stall (`visionos.md` §10.28) may be the same thing. The server's log line has presents, scans and the load
  at each one.
- A camera command right after the sweep, to a pose the picture already shows, counts as asked: a `guest-no-picture` line of many seconds with one camera move at the start of a rest (18.6 s in one smoke run) is that, not a stall. The server's line ("presents") tells them apart.
- The session path (swapchain copy) of the plain upload: offscreen it runs without a runtime; only a run shows its 90 Hz.
- Over `--media udp` the window was not exercised (the link defaults to TCP).
- Other viewers do not ask for a frame window yet (`ycode-sim-viewer`, the IDE's canvas); the same slow-consumer queue can form behind them, now bounded by the transport's limit and TCP's buffers.
- `tagged pose sent → shown` should say "held" for a held camera; the render-delay estimate (`effectiveRenderDelay`) follows the idle time between sparse pictures up to 400 ms (from reading; it matters only for an on-top picture just after a rest).

## Evidence

| Claim | Level | Source |
|---|---|---|
| OpenXR calls, structures, events, spaces, swapchain use, projection layers, extensions (eye gaze, hand tracking, hand interaction, convert timespec, Vulkan enable 2) | 1 | OpenXR 1.1 specification and registry (Khronos), the OpenXR-SDK release-1.1.47 headers (Apache-2.0 OR MIT), vendored in `Sources/CYcodeOpenXR/openxr` |
| Vulkan staging copy, layouts, queue use | 1 | Vulkan 1.3 specification; the CVulkan target's vendored headers (Apache-2.0) |
| WiVRn's behaviour and the headset's capabilities (§2) | 3 | our probe and test pattern against WiVRn 26.9 with a Quest Pro, 2026-11-01 (counts and ranges only) |
| WiVRn usage (runtime manifest, server) | 1 | WiVRn's user documentation; no WiVRn code used |
| Stage frame, absolute camera, gaze and hands in the stage frame, 90° projection, vhmdd pose, crown and recentre | — | `visionos.md` §5.5 (Ycode's spec; its own evidence there) |
| One view per presented picture, two-slice passes, device answers (§4) | — | `visionos.md` §1, §4.5, §10.6.1, §10.13.3, §10.24.1; `metal-sim-protocol.md` §5.11 |
| One view, the camera's tangents, no stereo input (§4) | — | `visionos.md` §5.6 (Ycode's spec; its evidence there) |
| Rotation lost by a generically made Orientation child, and the fix (§4) | — / 3 | `visionos.md` §5.5.10; our Thor boots before and after the fix |
| The guest's picture rate, pose → picture times, convergence, tag agreement (§6, §9.1) | 3 | Ycode's own simulator on the Thor with our scripts and analysis, 2026-11-01 |
| Adaptive and settled scheduling, tags, per-view damage, signatures, the mapping's thresholds, the messages | — | Ycode design decisions |
| Run 7's causes, the measurements and captures of §12 | 3 | XR-QUALITY: Ycode's own stream, Thor → x86, offscreen viewer, 2026-11-02; run 7's log |
| Run 8's numbers in §13 | 3 | run 8's logs (viewer and Thor), counts and ranges only |
| Gaps, the queue, tags, hover place and latency, the pinch (§13.1–§13.3, §13.5) | 3 | XR-GAZE: Ycode's own simulator with a current translator, Thor → x86, offscreen viewer and written scripts, 2026-11-02 |
| Filter comparisons (§13.3) | — | Ycode's tests, synthetic gaze of the shape run 8 measured; no real eye data |
| How eyes move (fixation, saccade main sequence, vestibulo-ocular reflex) | 1 | public eye-movement literature, general knowledge; no code or device behaviour used |
| Filter, calibration, pinch gate, reticle, frame window, gap recorders | — | Ycode design decisions |

No Apple binary, Apple software, reference tool or `research/` material was
used for this spec.
