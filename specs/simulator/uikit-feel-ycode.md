# Spec: UIKit look and feel in Ycode's simulator, against the reference

Status: **measured and partly fixed** (B3-UIKITFEEL, 2026-11-05, issue #83).
Clean room: written from `uikit-feel.md` (the reference's numbers), Ycode's
own specs and code, and public UIKit documentation. Nothing here comes from
Apple's tools; Apple's simulator and Xcode were not run.

`uikit-feel.md` measured an unmodified UIKit app in the reference simulator.
UIKit runs unchanged in Ycode's guest, so its constants come out right by
themselves when the host gives the guest correct input and time. This spec
checks every value of `uikit-feel.md` §3–§8 in Ycode's simulator, lists what
Ycode changed, and says why each remaining difference stays.

## 1. How it is measured

| Item | Value |
|---|---|
| Probe | `ycode/Samples/UIKitFeelSamples` (UIKitFeel, our own): one page at a time (scroll, paging, gestures, keyboard, rotation, display, pixels); logs every callback with `CACurrentMediaTime()` to `/tmp/uikitfeel/log.txt` (the device's `DEV/data/tmp`); commands come through `/tmp/uikitfeel/cmd.txt`; each page logs its targets' rectangles |
| Driver and analysis | `ycode/scripts/ycode-uikit-feel` (`drive`, `analyze`, `pattern`), Python standard library: touches through the display stream (`display-stream.md` §5.1) on a 60 Hz grid, as XCUITest's 16.7 ms samples; the last sample of a drag lands on the grid with a shorter step |
| Window check | `ycode/scripts/ycode-uikit-feel-window`: the viewer of the platform with a script, the window at each scale, the probe's 96 × 96 pattern of random grey levels looked for in each picture |
| Device | `iphone-18-pro` on the iOS 27.1 runtime: 402 × 874 pt at 3×, the same size as the reference's iPhone 17 Pro, so the reference's numbers compare directly |
| Host | the arm64 Linux simulator host, release build, `-j 6`; load average 1–25 from other agents |
| Runs | 5 per value (the final run), medians [min..max] |
| Build and run | the probe is built on the x86-64 PC with `scripts/ycode-ios-build-linux Samples/UIKitFeelSamples/UIKitFeelSamples.xcodeproj UIKitFeel <dd>`; `ycode-simd --device … --device-type iphone-18-pro --display-server unix:<sock> --install-app UIKitFeel.app --launch org.ycode.samples.uikitfeel`; then `python3 -I scripts/ycode-uikit-feel drive --connect unix:<sock> --app-tmp <DEV>/data/tmp --out <dir> --runs 5` and `… analyze <dir>` (macOS or Linux) |

What the driver cannot reproduce exactly is XCUITest's own speed profile:
for flicks it asks a constant speed (600, 2300, 6000 pt/s) and compares with
the reference's model at the release velocity UIKit reports, not with the
reference's release velocities themselves. The swipe and pinch strokes are
the reference's distances and speeds; the pinch is slowed to 0.5 pt of finger
distance per sample so that the sample step does not hide the threshold.

## 2. Summary

- 167 of the table's 211 rows match, 25 are information (they depend on the
  driver), 19 differ. Scrolling physics (deceleration factor 0.998,
  travel ÷ velocity, end velocity, curve shape, rubber band c = 0.55, return
  curves, edge bounce, scroll to top), gesture timing (150 ms, 350 ms,
  500 ms, 10 pt, about 8 pt), the keyboard's notifications, frames and
  spring (ω 24), 60 Hz everywhere and the pixels all match.
- **Fixed in Ycode** (§4.0, §7.3, §8.1, §8.4): input timestamps that kept
  the viewer's spacing only when the guest was idle; a still screen that
  stayed JPEG- or video-blurred; device windows that filtered or misplaced a
  1:1 picture; screenshots without the sRGB chunk; the Linux window's size on
  connect.
- **Not fixable on the host now**: rotation of devices that do not fold (§6:
  the guest-side mechanism is not specified); the display link's
  timestamps, one frame later than the reference's (§7.2), which also shows
  as a frame's head start in the paging snap and the keyboard's hide (§3.5,
  §5.2); a 3× label at a half-pixel origin (§8.2).

## 3. Scrolling

All of §3 comes from UIKit; Ycode supplies the touches and the frame clock.
Deceleration, rubber band, return, edge bounce and scroll to top match. Three
rows differ:

- **§3.1 final offset − target**: the deceleration ends 0–2.7 pt short of the
  target UIKit reported, more for faster flicks (0–0.3 pt at 0.6 pt/ms,
  about 1 pt at 2.3 pt/ms, 2.7 pt at 5.7 pt/ms); the reference ends exactly
  on it. The end time and the end velocity match. Cause not found; it has
  the size of half a millisecond of motion at the release speed, the order
  of the frame-timestamp difference of §7.2 at the start of the motion.
- **§3.3 within 0.5 pt of rest**: 60–75 ms later than the reference, while
  the remaining fraction at 100–400 ms (12 values, all within 0.012) and
  `didEndDecelerating` match. Ycode's last half-pixel comes at the end; the
  reference sat within half a point for about 50 ms first. Sub-pixel timing of
  the same spring (offsets are whole pixels), the order of one frame.
  **The release velocity after the 0.6 s hold** is the drag's speed
  (0.3 pt/ms): a held mouse, script or XCUITest finger sends nothing, and
  backboardd drops a report at the same device pixel, so UIKit keeps the last
  speed. The reference's return curve is matched only with that speed (with
  the velocity forced to 0 by `YCODE_HID_REST=pixel`, the remaining fraction
  at 100 ms was 0.27 instead of 0.548), so the reference kept it too; the
  "zero velocity" of `uikit-feel.md` §3.3 is that spec's inference.
- **§3.5 paging**: results (same page, next page) and snap durations match.
  At 50 and 100 ms the snap is 0.06–0.13 further on than the reference's, a
  frame's head start (§7.2). The 60 % drag reports 0.289 pt/ms at release
  (the reference: 0): UIKit reports the speed of the last movement, and the
  driver's last step differs from XCUITest's; the 30 % drag reports 0 as in
  the reference (one run of five: 0.287).

## 4. Gestures

### 4.0 Input timing (fixed)

Before: a 60 Hz drag sent with 16.7 ms spacing reached UIKit with gaps of
25–80 ms and up to 4 samples missing, each stamped at its arrival. The display
server's receive thread waited for the guest's port; the moves behind it
then came in a burst and the 16 ms coalescing dropped them. Now
(`hid-input.md` §14.3): every input is stamped on receipt and sent from one
thread with its age, the HID bundle stamps the event that much earlier, and
moves are no longer dropped unless they back up faster than 120 Hz. In the
final run every drag's touch timestamps keep the sender's 16.7 ms spacing;
`TouchPacingTests` cover the rules, `HIDHostServiceTests` the encoding.

The times of §4.1 and §4.3 are measured from the window's receipt of the
touch, as the reference's sub-millisecond values are. The event's own
timestamp is 2.2–3.4 ms earlier in Ycode (backboardd → app inside the guest;
reported as information).

### 4.1–4.6

All match: highlight at once outside a scroll view and after 150.8 ms inside
one, a quick tap in a scroll view highlights at touch-up, `.touchUpInside`
every time; long press `.began` at 501 ms and not for presses of 424 and
465 ms; the single tap that waits for a double tap fires 351 ms after
touch-up; a pan begins at 10 pt with translation (0, 0); the ten swipe
strokes give the reference's outcomes and travel; a pinch begins after
8–9 pt with scale about 1. The pan's touch-down → `.began` time depends on
how long the driver presses first and is information only.

## 5. Keyboard

The software keyboard shows on every focus while GameController reports a
hardware keyboard (as the reference); 0.38333 s, curve 7, the zero begin
frame on show, the end frame (0, 546, 402, 328), will → did on hide all match.
The visible motion is the reference's critically damped spring: fitted
ω 24.4 (show) and 24.8 (hide), RMS 0.005 and 0.007, with its start fitted
too.

- **will-show → did-show** takes 37 ms longer, and the show's motion starts
  about 50 ms after `keyboardWillShow` (the reference: within a frame): the
  app's main thread builds the keyboard first. A guest-speed difference, not
  the host's clock.
- **§5.2 hide fractions** in the first four frames are 0.04–0.08 behind the
  reference's when counted from the fitted start; counted from the frame of
  first movement, as the reference did, they are ahead. Either way the
  difference is the phase of the first frame (§7.2); the spring itself
  matches.

## 6. Rotation (not offered)

Ycode's display server rotates only foldable devices (`foldable.md` §8.3,
the device-motion relay). For other device types the guest-side mechanism
is open (`ipad.md` §7.4, `hid-input.md` §10). Tried and dropped: sending the
foldable's device-motion orientation (`orientation-picker-control`) to an
iPhone 18 Pro with its device-motion service published; backboardd took the
events and the app saw no `viewWillTransition`. So every §6 value is open
until an observation specifies how the reference delivers a device
orientation to a phone or a pad (the `XCUIDevice.orientation` path).

## 7. Frame pacing

- §7.1: `maximumFramesPerSecond` is 60 (the framebuffer's mode reports 6000).
- §7.2: every display-link interval is 16.667 ms (p5–p95 16.666–16.667)
  idle, animating, tracking and decelerating, for both variants; no
  interval shorter than 16.66 ms with 80–120 Hz asked; `duration` and
  `targetTimestamp − timestamp` 16.667 ms.
  **The callback runs 0.56 ms after `timestamp`; in the reference 17.19 ms
  after it**, i.e. 0.5 ms after `targetTimestamp`. Ycode's display link stamps
  the frame it is in, the reference's the frame before. Not caused by swap
  completions: completing swaps 16 ms late
  (`YCODE_FRAMEBUFFER_COMPLETION=delay-16`), on a 60 Hz grid, or blocking
  `SwapSubmit` until the grid point (`…=vsync`, `…=vsync-block`, kept as
  diagnostics) left it at 0.6 ms. How the reference's QuartzCore gets its
  frame times in the simulator (the framebuffer server's protocol,
  `simframebuffer.md` §6, was not studied) is the open question; it is the
  likely common cause of the one-frame differences in §3.1, §3.5 and §5.2.
- §7.3: the host receives a frame every 16.3–16.7 ms (median) while
  content moves and **none** while it is still.

## 8. Pixels

### 8.1–8.3

Screenshots are 1206 × 2622 px, RGBA, opaque and now carry the **sRGB
chunk** (fixed: Ycode's PNG writers had none). Text is grayscale-antialiased
(0 coloured pixels of 1094–4006 partly covered), unhinted, 251 grey levels; a
label moved by 1 px is the same picture moved; the 1-px checkerboard is only
0 and 255; half a pixel down it is 127–128; a 1-px view at a half-pixel
offset is one black row and a 1 pt view three; magnified and stretched
bitmaps are linearly filtered; the 96 × 96 pattern is exact.

**A 17 pt label at a half-pixel origin** differs: Ycode composites the
label's bitmap at the half pixel (it equals the average of the original
and the 1-px-moved original to 0.04 of 255), as the reference does at 2×;
the reference rasterizes the glyphs again at 3× (15.4 from that average). A
rendering policy inside the guest's QuartzCore, which runs unchanged; what
selects it per device was not found.

### 8.4 The device window at each scale (fixed)

Before: (1) the stream is JPEG (or video) and a picture is sent only when
the screen changes, so a still screen kept its compression artefacts and
text was never exact; (2) the macOS window filtered the picture
bilinearly at every size and rounded the screen's rectangle outwards to
whole points (`integral`), which could stretch a 1206-px picture over
1208 px; (3) the Linux window filtered linearly at every size and centred
the screen on fractions of a pixel. Now:

1. **Lossless once still** (`display-stream.md` §4.2.2): 200 ms after the
   screen stops, the parts sent lossy go again as zlib tiles. Every Ycode
   viewer asks for it (`stillLossless` in the hello).
2. **macOS**: the screen's rectangle is placed on whole backing pixels with
   its size rounded to pixels, not points; at one image pixel per display
   pixel the layer's filters are `nearest`, at any other size linear
   (trilinear below half size). `DeviceSharpnessTests`.
3. **Linux**: the layout puts the screen on a whole output pixel; at one
   stream pixel per output pixel the texture's scale mode is nearest, else
   linear. `RemoteViewerTests.pixelAccurateIsOneToOneOnWholePixels`.
4. **Linux window size**: the window takes the device frame's shape at the
   current scale when it connects (and when a foldable changes panel or
   turns), with room for the floating capsules (36.5 tall, 8 above the
   edge); an iPhone Duo no longer sits in the default 460 × 900.
   `WindowFitTests`.

Checked with `scripts/ycode-uikit-feel-window` and the probe on its pixels
page (iPhone 18 Pro, iOS 27.1):

| Window | Scale | Encoding | Pattern |
|---|---|---|---|
| server PNG | native | — | exact |
| Linux (x86-64 PC, Wayland, OpenGL renderer) | Pixel Accurate | auto, JPEG q80, H.264 | **exact** (0 of 9216 pixels differ) |
| Linux | Point Accurate, Fit | each | filtered (by design) |
| macOS (1× display) | expanded, one device pixel per display pixel (zoom 3) | JPEG q80 | **exact** |
| macOS | zoom 1, 0.75 | JPEG q80 | filtered (by design) |

At other scales the picture is resampled (linear; trilinear on macOS below
half size): exactness is neither possible nor asked there. How the
reference's window filters at its scales was not observed
(`uikit-feel.md` §8.4).

## 9. The table (final run)

Generated by `ycode-uikit-feel analyze` from the final run (5 runs per
value). "Spec" quotes `uikit-feel.md` (iPhone 17 Pro, iOS 27.2, unless the
row says otherwise); "info" rows depend on the driver or are context.

| § | Value | Spec (reference) | Ycode | Verdict | Note |
|---|---|---|---|---|---|
| 1 | device | iPhone 17 Pro 402 × 874 pt @3 (iOS 27.2) | 402 × 874 pt @3 | info |  |
| 5.3 | GameController hardware keyboard at launch | connected | connected | match |  |
| 3 | decelerationRate .normal | 0.998000 | 0.998000 | match |  |
| 3 | decelerationRate .fast | 0.990000 | 0.990000 | match |  |
| 3 | delaysContentTouches, scrollsToTop | true, true | true, true | match |  |
| 3 | adjusted content inset (top, bottom), portrait | 62, 34 pt (402 × 874 iPhone) | 62, 34 pt | match |  |
| 3.1 | velocity factor per ms (fit) | 0.99800 | 0.99802 | match | all flicks, 600 pt/s: 0.99805 [0.99803..0.99806], 2300 pt/s: 0.99802 [0.99802..0.99803], 6000 pt/s: 0.99801 [0.99801..0.99802] |
| 3.1 | travel ÷ release velocity, drag 600 pt/s (release 0.587 [0.585..0.594] pt/ms) | 491–499 ms (≈491.4 at this speed) | 491.1 | match |  |
| 3.1 | release → end of deceleration, release 0.587 pt/ms | 1.996 s (model: 0.998^t·v₀ = 0.0108) | 2.049 s | match |  |
| 3.1 | travel ÷ release velocity, drag 2300 pt/s (release 2.294 [2.280..2.298] pt/ms) | 491–499 ms (≈498 at this speed) | 497.3 | match |  |
| 3.1 | release → end of deceleration, release 2.294 pt/ms | 2.677 s (model: 0.998^t·v₀ = 0.0108) | 2.732 s | match |  |
| 3.1 | travel ÷ release velocity, drag 6000 pt/s (release 5.711 [3.171..5.731] pt/ms) | 491–499 ms (≈498 at this speed) | 498.6 | match |  |
| 3.1 | release → end of deceleration, release 5.711 pt/ms | 3.132 s (model: 0.998^t·v₀ = 0.0108) | 3.182 s | match |  |
| 3.1 | end velocity at end of deceleration | 0.0103–0.0126 pt/ms | 0.0097 pt/ms | match |  |
| 3.1 | final offset − target (largest) | 0 (on a pixel) | 2.667 pt | mismatch | per flick: 0.33 at 0.59 pt/ms, 0.00 at 0.58 pt/ms, 0.33 at 0.59 pt/ms, 0.00 at 0.59 pt/ms, 0.33 at 0.59 pt/ms, 0.67 at 2.29 pt/ms, 1.33 at 2.28 pt/ms, 1.00 at 2.29 pt/ms, 1.00 at 2.30 pt/ms, 1.00 at 2.30 pt/ms, 2.67 at 5.72 pt/ms, 2.67 at 5.64 pt/ms, 1.33 at 3.17 pt/ms, 2.67 at 5.71 pt/ms, 2.67 at 5.73 pt/ms |
| 3.1 | final offset on a whole pixel | yes | yes | match |  |
| 3.1 | last step before the end | 1 px (0.333 pt) | 0.333 pt | match |  |
| 3.1 | fraction of travel at 100 ms | 0.18 | 0.21 | match |  |
| 3.1 | fraction of travel at 250 ms | 0.40 | 0.41 | match |  |
| 3.1 | fraction of travel at 500 ms | 0.64 | 0.65 | match |  |
| 3.1 | fraction of travel at 1000 ms | 0.88 | 0.87 | match |  |
| 3.1 | fraction of travel at 2000 ms | 0.99 | 0.99 | match |  |
| 3.1 | scrollViewDidScroll interval (median) | 16.67 ms | 16.66 ms | match | frames the guest drew; a longer median means dropped frames |
| 3.2 | movement before scrolling starts, 100 pt drag | 13.0 pt (10 pt + ≤ 1 sample of 5 pt) | 10.0 [10.0..15.0] pt | match |  |
| 3.2 | excursion, 100 pt drag (model c = 0.55, d = 874: 46.8 [44.4..46.8]) | 46.7 pt on 874 pt; model for this run | 47.0 pt | match |  |
| 3.2 | movement before scrolling starts, 200 pt drag | 11.7 pt (10 pt + ≤ 1 sample of 5 pt) | 10.0 [10.0..15.0] pt | match |  |
| 3.2 | excursion, 200 pt drag (model c = 0.55, d = 874: 93.3 [91.1..93.3]) | 93.3 pt on 874 pt; model for this run | 93.3 pt | match |  |
| 3.2 | movement before scrolling starts, 400 pt drag | 11.0 pt (10 pt + ≤ 1 sample of 5 pt) | 10.0 [10.0..15.0] pt | match |  |
| 3.2 | excursion, 400 pt drag (model c = 0.55, d = 874: 172.2 [170.6..172.3]) | 172.3 pt on 874 pt; model for this run | 172.3 pt | match |  |
| 3.2 | fitted c (both edges) | 0.555 (iPhone), 0.550 (iPad) | 0.550 | match |  |
| 3.3 | remaining at 100 ms after release, 100 pt drag | 0.548 | 0.543 | match |  |
| 3.3 | remaining at 200 ms after release, 100 pt drag | 0.251 | 0.255 | match |  |
| 3.3 | remaining at 300 ms after release, 100 pt drag | 0.107 | 0.113 | match |  |
| 3.3 | remaining at 400 ms after release, 100 pt drag | 0.043 | 0.044 | match |  |
| 3.3 | within 0.5 pt of rest, 100 pt drag | 0.517 s | 0.578 s | mismatch |  |
| 3.3 | didEndDecelerating after release, 100 pt drag | 0.568 s | 0.579 s | match |  |
| 3.3 | overshoot past rest, 100 pt drag | none | none | match |  |
| 3.3 | release velocity after the 0.6 s hold, 100 pt drag | not logged (0 assumed) | 0.300 [0.298..0.300] pt/ms | info | the drag's speed: a held finger sends nothing; the return times match only with it (uikit-feel-ycode.md §3.3) |
| 3.3 | remaining at 100 ms after release, 200 pt drag | 0.448 | 0.446 | match |  |
| 3.3 | remaining at 200 ms after release, 200 pt drag | 0.185 | 0.193 | match |  |
| 3.3 | remaining at 300 ms after release, 200 pt drag | 0.076 | 0.079 | match |  |
| 3.3 | remaining at 400 ms after release, 200 pt drag | 0.029 | 0.032 | match |  |
| 3.3 | within 0.5 pt of rest, 200 pt drag | 0.535 s | 0.605 s | mismatch |  |
| 3.3 | didEndDecelerating after release, 200 pt drag | 0.585 s | 0.605 s | match |  |
| 3.3 | overshoot past rest, 200 pt drag | none | none | match |  |
| 3.3 | release velocity after the 0.6 s hold, 200 pt drag | not logged (0 assumed) | 0.300 [0.299..0.300] pt/ms | info | the drag's speed: a held finger sends nothing; the return times match only with it (uikit-feel-ycode.md §3.3) |
| 3.3 | remaining at 100 ms after release, 400 pt drag | 0.408 | 0.397 | match |  |
| 3.3 | remaining at 200 ms after release, 400 pt drag | 0.160 | 0.162 | match |  |
| 3.3 | remaining at 300 ms after release, 400 pt drag | 0.062 | 0.064 | match |  |
| 3.3 | remaining at 400 ms after release, 400 pt drag | 0.023 | 0.025 | match |  |
| 3.3 | within 0.5 pt of rest, 400 pt drag | 0.567 s | 0.643 s | mismatch |  |
| 3.3 | didEndDecelerating after release, 400 pt drag | 0.619 s | 0.643 s | match |  |
| 3.3 | overshoot past rest, 400 pt drag | none | none | match |  |
| 3.3 | release velocity after the 0.6 s hold, 400 pt drag | not logged (0 assumed) | 0.294 [0.288..0.302] pt/ms | info | the drag's speed: a held finger sends nothing; the return times match only with it (uikit-feel-ycode.md §3.3) |
| 3.4 | bottom edge, drag 2500 pt/s: release velocity | 2.35–6.5 pt/ms | 2.405 [2.396..2.413] pt/ms | info |  |
| 3.4 | bottom edge, drag 2500 pt/s: time from crossing to peak | 83 [67..84] ms | 83 ms | match |  |
| 3.4 | bottom edge, drag 2500 pt/s: peak past edge | 47–84 pt (iPhone, 2.4–3.2 pt/ms) | 55.0 [54.7..55.3] pt | info | grows with the velocity at the edge |
| 3.4 | bottom edge, drag 2500 pt/s: within 0.5 pt / didEndDecelerating | 0.65–0.70 s / 0.70–0.77 s | 0.717 [0.717..0.717] / 0.717 [0.717..0.717] s | info |  |
| 3.4 | bottom edge, drag 6000 pt/s: release velocity | 2.35–6.5 pt/ms | 3.193 [3.182..3.200] pt/ms | info |  |
| 3.4 | bottom edge, drag 6000 pt/s: time from crossing to peak | 83 [67..84] ms | 83 ms | match |  |
| 3.4 | bottom edge, drag 6000 pt/s: peak past edge | 47–84 pt (iPhone, 2.4–3.2 pt/ms) | 77.3 [77.0..77.7] pt | info | grows with the velocity at the edge |
| 3.4 | bottom edge, drag 6000 pt/s: within 0.5 pt / didEndDecelerating | 0.65–0.70 s / 0.70–0.77 s | 0.750 [0.750..0.750] / 0.751 [0.751..0.751] s | info |  |
| 3.4 | top edge, drag 2500 pt/s: release velocity | 2.35–6.5 pt/ms | 2.410 [2.405..2.429] pt/ms | info |  |
| 3.4 | top edge, drag 2500 pt/s: time from crossing to peak | 83 [67..84] ms | 83 ms | match |  |
| 3.4 | top edge, drag 2500 pt/s: peak past edge | 47–84 pt (iPhone, 2.4–3.2 pt/ms) | 55.3 [53.0..55.7] pt | info | grows with the velocity at the edge |
| 3.4 | top edge, drag 2500 pt/s: within 0.5 pt / didEndDecelerating | 0.65–0.70 s / 0.70–0.77 s | 0.717 [0.716..0.717] / 0.717 [0.717..0.718] s | info |  |
| 3.4 | top edge, drag 6000 pt/s: release velocity | 2.35–6.5 pt/ms | 3.179 [3.169..3.189] pt/ms | info |  |
| 3.4 | top edge, drag 6000 pt/s: time from crossing to peak | 83 [67..84] ms | 83 ms | match |  |
| 3.4 | top edge, drag 6000 pt/s: peak past edge | 47–84 pt (iPhone, 2.4–3.2 pt/ms) | 77.0 [70.0..77.3] pt | info | grows with the velocity at the edge |
| 3.4 | top edge, drag 6000 pt/s: within 0.5 pt / didEndDecelerating | 0.65–0.70 s / 0.70–0.77 s | 0.750 [0.733..0.750] / 0.750 [0.734..0.751] s | info |  |
| 3.5 | drag30: offset at release (pages) | 0.275 pages | 0.275 [0.275..0.275] pages | info |  |
| 3.5 | drag30: release velocity after the 0.3 s hold | 0 | 0.000 [0.000..0.287] pt/ms | mismatch | UIKit reports the last step's speed (uikit-feel-ycode.md §3.5) |
| 3.5 | drag30: result | same page | same, same, same, same, same | match |  |
| 3.5 | drag30: snap, release → didEndDecelerating | 0.367 s | 0.371 s | match |  |
| 3.5 | drag30: fraction of the snap at 50 ms | 0.18 | 0.24 | mismatch |  |
| 3.5 | drag30: fraction of the snap at 100 ms | 0.51 | 0.54 | match |  |
| 3.5 | drag30: fraction of the snap at 200 ms | 0.88 | 0.89 | match |  |
| 3.5 | drag30: fraction of the snap at 300 ms | 0.99 | 0.99 | match |  |
| 3.5 | drag60: offset at release (pages) | 0.575 pages | 0.575 [0.563..0.575] pages | info |  |
| 3.5 | drag60: release velocity after the 0.3 s hold | 0 | 0.289 [0.286..0.291] pt/ms | mismatch | UIKit reports the last step's speed (uikit-feel-ycode.md §3.5) |
| 3.5 | drag60: result | next page | next, next, next, next, next | match |  |
| 3.5 | drag60: snap, release → didEndDecelerating | 0.383 s | 0.365 s | match |  |
| 3.5 | drag60: fraction of the snap at 50 ms | 0.18 | 0.31 | mismatch |  |
| 3.5 | drag60: fraction of the snap at 100 ms | 0.51 | 0.61 | mismatch |  |
| 3.5 | drag60: fraction of the snap at 200 ms | 0.88 | 0.92 | match |  |
| 3.5 | drag60: fraction of the snap at 300 ms | 0.99 | 0.99 | match |  |
| 3.5 | flick15: offset at release (pages) | 0.094 pages | 0.067 [0.067..0.067] pages | info |  |
| 3.5 | flick15: release velocity | 0.475 pt/ms (XCUITest 2000 pt/s) | 0.556 [0.555..0.558] pt/ms | info |  |
| 3.5 | flick15: result | next page | next, next, next, next | match |  |
| 3.5 | flick15: snap, release → didEndDecelerating | 0.367 s | 0.366 s | match |  |
| 3.5 | flick15: fraction of the snap at 50 ms | 0.23 | 0.33 | mismatch |  |
| 3.5 | flick15: fraction of the snap at 100 ms | 0.54 | 0.62 | mismatch |  |
| 3.5 | flick15: fraction of the snap at 200 ms | 0.90 | 0.92 | match |  |
| 3.5 | flick15: fraction of the snap at 300 ms | 0.99 | 0.99 | match |  |
| 3.6 | start 600: status-bar taps that scrolled | 5/5 (10/10 on the Duo: 9) | 5/5 | match |  |
| 3.6 | start 600: 50 % reached | 80 ms | 79 ms | match |  |
| 3.6 | start 600: 90 % reached | 248 ms | 246 ms | match |  |
| 3.6 | start 600: 99 % reached | 498 ms | 512 ms | match |  |
| 3.6 | start 600: scrollViewDidScrollToTop | 1614 ms | 1612 ms | match |  |
| 3.6 | start 8000: status-bar taps that scrolled | 5/5 (10/10 on the Duo: 9) | 5/5 | match |  |
| 3.6 | start 8000: 50 % reached | 80 ms | 78 ms | match |  |
| 3.6 | start 8000: 90 % reached | 248 ms | 245 ms | match |  |
| 3.6 | start 8000: 99 % reached | 498 ms | 496 ms | match |  |
| 3.6 | start 8000: scrollViewDidScrollToTop | 1614 ms | 1612 ms | match |  |
| 4.1 | inner button, press: touch-down → touchesBegan | 150.9 ms | 151.1 ms | match |  |
| 4.1 | inner button, press: touch-down → highlight on | 151.1 ms | 151.1 ms | match |  |
| 4.1 | inner button, press: touch-up → highlight off | 0.9 ms | 0.7 ms | match |  |
| 4.1 | inner button, press: .touchUpInside | every time | 5/5 | match |  |
| 4.1 | inner button, press: touch event timestamp → the window has it | — | 2.4 [2.3..3.4] ms | info | backboardd → app delivery in the guest |
| 4.1 | inner button, tap: touchesBegan relative to touch-up | at touch-up (+0.3 ms) | 0.6 ms | match |  |
| 4.1 | inner button, tap: touch-up → highlight off | 0.5 ms | 0.9 ms | match |  |
| 4.1 | inner button, tap: .touchUpInside | every time | 5/5 | match |  |
| 4.1 | inner button, tap: touch event timestamp → the window has it | — | 2.3 [2.3..2.6] ms | info | backboardd → app delivery in the guest |
| 4.1 | plain button, press: touch-down → touchesBegan | 0.2 ms | 0.4 ms | match |  |
| 4.1 | plain button, press: touch-down → highlight on | 0.3 ms | 0.5 ms | match |  |
| 4.1 | plain button, press: touch-up → highlight off | 0.2 ms | 0.4 ms | match |  |
| 4.1 | plain button, press: .touchUpInside | every time | 5/5 | match |  |
| 4.1 | plain button, press: touch event timestamp → the window has it | — | 2.6 [2.2..3.0] ms | info | backboardd → app delivery in the guest |
| 4.1 | plain button, tap: touch-down → touchesBegan | 0.2 ms | 0.5 ms | match |  |
| 4.1 | plain button, tap: touch-down → highlight on | 0.2 ms | 0.5 ms | match |  |
| 4.1 | plain button, tap: touch-up → highlight off | 0.1 ms | 0.4 ms | match |  |
| 4.1 | plain button, tap: .touchUpInside | every time | 5/5 | match |  |
| 4.1 | plain button, tap: touch event timestamp → the window has it | — | 2.4 [2.3..3.3] ms | info | backboardd → app delivery in the guest |
| 4.2 | minimumPressDuration | 0.500 s | 0.500 s | match |  |
| 4.2 | allowableMovement | 10.0 pt | 10.0 pt | match |  |
| 4.2 | press of 424 [423..424] ms: recognized | 0/5 | 0/5 | match |  |
| 4.2 | press of 465 [465..465] ms: recognized | 0/5 | 0/5 | match |  |
| 4.2 | press of 559 [559..559] ms: recognized | 5/5 | 5/5 | match |  |
| 4.2 | press of 559 ms: touch-down → .began | 501.5 [500.6..506] ms | 503.8 ms | match |  |
| 4.2 | press of 1000 [999..1001] ms: recognized | 5/5 | 5/5 | match |  |
| 4.2 | press of 1000 ms: touch-down → .began | 501.5 [500.6..506] ms | 503.6 ms | match |  |
| 4.3 | single tap that waits for a double tap: delay after touch-up (the window's receipt) | 351 [350.4..352.1] ms | 351.0 ms | match | from the touch-up event's timestamp: 353.2 [352.6..354.2] ms |
| 4.3 | double tap (taps of 60 ms, 20 ms apart) | recognized 5/5; single never | 5/5 | match |  |
| 4.4 | finger movement when .began fires | 10.00 pt (first sample ≥ 10 pt) | 10.00 pt | match |  |
| 4.4 | touch-down → .began (drag at 100 pt/s) | 191 [187..199] ms (XCUITest's press first) | 108 [104..116] ms | info | 10 pt at 100 pt/s is 100 ms; the rest is the driver's press before the drag |
| 4.4 | translation at .began | (0, 0) | (0, 0) | match |  |
| 4.5 | 10 pt at 1500 pt/s: recognized | 0/5 | 0/5 | match |  |
| 4.5 | 20 pt at 1500 pt/s: recognized | 0/5 | 0/5 | match |  |
| 4.5 | 40 pt at 1500 pt/s: recognized | 0/5 | 0/5 | match |  |
| 4.5 | 60 pt at 1500 pt/s: recognized, travel at recognition, time | 5/5, 52.7 pt, 67 ms | 5/5, 50.0 pt, 65 [58..69] ms | match | within one touch sample |
| 4.5 | 100 pt at 1500 pt/s: recognized, travel at recognition, time | 5/5, 51.7 pt, 67 ms | 5/5, 50.0 pt, 61 [56..68] ms | match | within one touch sample |
| 4.5 | 200 pt at 1500 pt/s: recognized, travel at recognition, time | 5/5, 47.0 pt, 67 ms | 5/5, 50.0 pt, 64 [57..71] ms | match | within one touch sample |
| 4.5 | 200 pt at 100 pt/s: recognized, travel at recognition, time | 5/5, 33.0 pt, 400 ms | 5/5, 35.0 pt, 379 [372..386] ms | match | within one touch sample |
| 4.5 | 200 pt at 200 pt/s: recognized, travel at recognition, time | 5/5, 40.0 pt, 250 ms | 5/5, 40.0 pt, 231 [225..233] ms | match | within one touch sample |
| 4.5 | 200 pt at 400 pt/s: recognized, travel at recognition, time | 5/5, 43.3 pt, 150 ms | 5/5, 46.7 pt, 148 [141..153] ms | match | within one touch sample |
| 4.5 | 200 pt at 800 pt/s: recognized, travel at recognition, time | 5/5, 50.7 pt, 100 ms | 5/5, 53.3 pt, 98 [93..104] ms | match | within one touch sample |
| 4.6 | pinch: recognized | all | 5/5 | match |  |
| 4.6 | pinch: change in finger distance at .began | about 8–9 pt | 8.33 pt | match |  |
| 4.6 | pinch: scale at .began | ≈ 1.0 (1.018 / 1.000) | 0.998 | match |  |
| 4.6 | spread: recognized | all | 5/5 | match |  |
| 4.6 | spread: change in finger distance at .began | about 8–9 pt | 8.33 pt | match |  |
| 4.6 | spread: scale at .began | ≈ 1.0 (1.018 / 1.000) | 1.024 | match |  |
| 5.1 | software keyboard on focus (hardware keyboard reported connected) | shows every time | 5/5 | match |  |
| 5.1 | duration in user info | 0.38333 s | 0.38330 s | match |  |
| 5.1 | curve in user info | 7 | 7 | match |  |
| 5.1 | keyboardFrameBegin on show | (0, 0, 0, 0) | (0, 0, 0, 0) | match |  |
| 5.1 | keyboardFrameEnd on show (portrait) | (0, 546, 402, 328) on 402 × 874 | (0, 546, 402, 328) | match | same device size only |
| 5.1 | will-show → did-show | 403.7 [389.6..586.1] ms | 408.5 ms | match |  |
| 5.1 | will-hide → did-hide | 401.2 ms (Duo: 8–10 ms also allowed) | 415.9 ms | match |  |
| 5.2 | show: fraction 1 frame after the start | 0.080 | 0.060 | match |  |
| 5.2 | show: fraction 2 frames after the start | 0.197 | 0.208 | match |  |
| 5.2 | show: fraction 3 frames after the start | 0.350 | 0.354 | match |  |
| 5.2 | show: fraction 4 frames after the start | 0.484 | 0.490 | match |  |
| 5.2 | show: fraction 6 frames after the start | 0.694 | 0.700 | match |  |
| 5.2 | show: fraction 9 frames after the start | 0.874 | 0.877 | match |  |
| 5.2 | show: fraction 12 frames after the start | 0.951 | 0.952 | match |  |
| 5.2 | show: fraction 18 frames after the start | 0.993 | 0.994 | match |  |
| 5.2 | show: fraction 24 frames after the start | 1.000 | 1.000 | match |  |
| 5.2 | show: fitted ω (start time fitted too; RMS 0.005 [0.005..0.010]) | 23.7–24.3 rad/s | 24.5 rad/s | match |  |
| 5.2 | show: motion starts after the notification | within 1 frame (6–18 ms) | 17 ms | match | frames not drawn during the motion: 0 [0..1] |
| 5.2 | hide: fraction 1 frame after the start | 0.115 | 0.061 | mismatch |  |
| 5.2 | hide: fraction 2 frames after the start | 0.273 | 0.194 | mismatch |  |
| 5.2 | hide: fraction 3 frames after the start | 0.416 | 0.340 | mismatch |  |
| 5.2 | hide: fraction 4 frames after the start | 0.542 | 0.476 | mismatch |  |
| 5.2 | hide: fraction 6 frames after the start | 0.737 | 0.690 | mismatch |  |
| 5.2 | hide: fraction 9 frames after the start | 0.892 | 0.872 | match |  |
| 5.2 | hide: fraction 12 frames after the start | 0.959 | 0.950 | match |  |
| 5.2 | hide: fraction 18 frames after the start | 0.995 | 0.993 | match |  |
| 5.2 | hide: fraction 24 frames after the start | 1.000 | 1.000 | match |  |
| 5.2 | hide: fitted ω (start time fitted too; RMS 0.004 [0.002..0.008]) | 23.7–24.3 rad/s | 24.0 rad/s | match |  |
| 5.2 | hide: motion starts after the notification | within 1 frame (6–18 ms) | 12 ms | match | frames not drawn during the motion: 0 [0..0] |
| 6 | rotation (90°) | 0.3 s, curve 0, ease-in-ease-out bounds | not offered for this device type | mismatch | the display server refuses rotation for non-foldable devices |
| 7.1 | UIScreen.maximumFramesPerSecond | 60 | 60 | match |  |
| 7.2 | default, animating: display-link interval (p5–p95 16.666–16.667, n = 733, 1 long) | 16.667 ms | 16.667 ms | match |  |
| 7.2 | default, decelerating: display-link interval (p5–p95 16.666–16.667, n = 1160, 1 long) | 16.667 ms | 16.667 ms | match |  |
| 7.2 | default, idle: display-link interval (p5–p95 16.666–16.667, n = 505, 0 long) | 16.667 ms | 16.667 ms | match |  |
| 7.2 | duration and targetTimestamp − timestamp | 16.667 ms | 16.667 ms | match |  |
| 7.2 | callback after timestamp | 17.19 ms (0.5 ms after target) | 0.56 ms | mismatch |  |
| 7.2 | default, tracking: display-link interval (p5–p95 16.666–16.667, n = 803, 3 long) | 16.667 ms | 16.667 ms | match |  |
| 7.2 | max, animating: display-link interval (p5–p95 16.666–16.667, n = 745, 1 long) | 16.667 ms | 16.667 ms | match |  |
| 7.2 | max, animating: intervals shorter than 16.66 ms | none | 0 | match |  |
| 7.2 | max, idle: display-link interval (p5–p95 16.666–16.667, n = 505, 0 long) | 16.667 ms | 16.667 ms | match |  |
| 7.2 | max, idle: intervals shorter than 16.66 ms | none | 0 | match |  |
| 7.3 | host frame interval while content moves (n = 1994, p5 14.6, p95 19.1) | 16.67 ms | 16.61 ms | match |  |
| 7.3 | frames sent while nothing moves (0.0 s) | none | 0 | match |  |
| 8.1 | screenshot size | 1206 × 2622 px (points × scale) | 1206 × 2622 px | match |  |
| 8.1 | screenshot format | RGBA, sRGB chunk, opaque | RGBA, sRGB chunk, opaque | match |  |
| 8.2 | text9: partially covered pixels with an R/G/B difference | 0 (grayscale) | 0 of 1094 | match |  |
| 8.2 | text17: partially covered pixels with an R/G/B difference | 0 (grayscale) | 0 of 2057 | match |  |
| 8.2 | text34: partially covered pixels with an R/G/B difference | 0 (grayscale) | 0 of 4006 | match |  |
| 8.2 | text17: distinct gray levels | 254–256 | 251 | match |  |
| 8.2 | label moved by 1 px = the original moved | mean difference 0.000 | 0.000 | match |  |
| 8.2 | label moved by ½ px: mean difference from the original, from the 1-px average | 7.76, 15.41 (3×: re-rasterized) | 7.48, 0.04 | mismatch | the guest's own rendering; compared, not required to be equal |
| 8.2 | text17: partially covered pixels (no stem hinting) | many (stems 2.4–3.6 px wide) | 1312 | match |  |
| 8.3 | scale-1 bitmap at its point size (3×) | levels 0, 85, 170, 255 (linear) | 0, 85, 114, 141, 170, 255 | match |  |
| 8.3 | 16-px scale-1 bitmap stretched to 37 pt | 254 levels (smooth) | 254 | match |  |
| 8.3 | checkerboard at the screen scale, pixel-aligned | only 0 and 255 | 0, 255 | match |  |
| 8.3 | same image ½ px lower (bilinear: uniform 128) | 128 | 127 | match |  |
| 8.3 | 1-px solid view at a ½-px offset | one fully black row, no gray | 1 black, 0 gray | match |  |
| 8.3 | 1 pt solid view at a ½-px offset | 3 fully black rows | 3 | match |  |
| 8.3 | pixel-exact pattern (96 × 96 device pixels) | exact | 0 pixels differ (max 0) | match |  |

## 10. Open questions (for an observation of the reference)

1. How the reference's QuartzCore in the simulator gets its frame times
   (§7.2): the display link reports the previous frame; Ycode's the current.
2. How the reference delivers a device orientation to a phone or pad that
   does not fold (§6; `XCUIDevice.orientation`, Simulator's Rotate).
3. What makes a 3× label at a half-pixel origin rasterize again rather than
   resample (§8.2).
4. XCUITest's drag speed profile (the last sample's step) for the paging
   release velocity (§3.5).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Every Ycode value in §3–§8 and §9 | 3 | the UIKitFeel probe's log and screenshots on Ycode's simulator (our build, our device), analysed by `ycode-uikit-feel` |
| The reference's values | — | `uikit-feel.md` (quoted, not re-measured) |
| Input stalls and bursts before the fix (§4.0) | 3 | the driver's send times against the guest's touch timestamps |
| Release velocity and the return curve (§3.3) | 3 | runs with and without `YCODE_HID_REST=pixel` |
| Swap completion timing does not move the display-link timestamps (§7.2) | 3 | runs with `YCODE_FRAMEBUFFER_COMPLETION` delay-16 and vsync-block |
| The device-motion orientation does not rotate an iPhone (§6) | 3 | one boot with the service published for a non-foldable type |
| Window exactness (§8.4) | 3 | `ycode-uikit-feel-window` on macOS and Linux |
| UIKit property defaults | 1 | UIKit documentation |
