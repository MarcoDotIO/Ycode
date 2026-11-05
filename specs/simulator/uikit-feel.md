# Spec: how UIKit apps look and feel in the reference simulator

Status: **observed** (B3-UIKITOBS, 2026-11-05, issue #82). It gives the
clean-room implementer of #83 the numbers that Ycode's simulator must
reproduce when an unmodified UIKit app runs in it. These cover scrolling,
gestures, the keyboard, rotation, frame pacing and pixel output. Every value
comes from a probe app that we wrote ourselves and ran in Apple's simulator
as a black box (evidence level 3). Where public UIKit documentation states a
value, the documentation is cited as well (level 1). The spec has no Apple
code, no decompiler output and no images.

It builds on `display-stream.md`, `hid-input.md`, `ipad.md`,
`iphone-types.md` and `foldable.md`, and does not repeat them.

## 1. Conditions

| Item | Value |
|---|---|
| Xcode | 27.1 (27A9269), command-line tools only (`xcodebuild`, `xcrun simctl`) |
| Runtimes | iOS 27.1 (24A94401) for the iPhone Duo; iOS 27.2 (24B8117) for the iPhone 17 Pro and the iPad Pro (§1.1) |
| Devices | iPhone 17 Pro (402 × 874 pt, scale 3; the real device has a 120 Hz display); iPad Pro 11-inch (M5) (834 × 1210 pt, scale 2; the real device has a 120 Hz display); iPhone Duo cover display (466 × 678 pt, scale 3) |
| Boot | Headless (`simctl boot`); no Simulator window was opened |
| Driver | An XCUITest UI-test target in the probe project, run with `xcodebuild test-without-building`. It synthesizes taps, presses, drags with a set velocity, pinches and device-orientation changes |
| Clock | The probe logs `CACurrentMediaTime()` at every callback. Touch times are logged both as the event's own timestamp and as the moment the window received it |
| Runs | 5 runs per value unless the table says otherwise. Tables give **median [min..max]** |
| Host load | The Mac's load average was 500–970 during the runs, because other agents were building. Medians are stable. Single slow frames (maxima) are host noise and are flagged where they appear |

### 1.1 Why two runtimes

The installed iOS 27.1 runtime (24A94401) accepts **only** the iPhone Duo
device type: `simctl create` of an iPhone 17 Pro or an iPad on it fails with
"Incompatible device". Its `supportedDeviceTypes` list has one entry. The
iOS 27.0 runtime (24A434) is listed but cannot create devices ("runtime path
not found"). So the 120 Hz-class iPhone and the iPad ran on iOS 27.2
(24B8117), the nearest release runtime that works. The iPhone Duo on 27.1
ran the whole suite as a cross-check (§10). Every UIKit constant matched
27.2. There was one difference in notification timing: on the Duo,
`keyboardDidHide` arrives early.

### 1.2 Terms

- **pt**: UIKit points. **px**: device pixels (pt × scale).
- **Release velocity**: the velocity that UIKit passes to
  `scrollViewWillEndDragging(_:withVelocity:targetContentOffset:)`, in
  pt/ms.
- **Frame**: one display refresh. The simulator refreshes at 60 Hz (§7), so
  one frame is 16.667 ms.
- **Edge rest**: the content offset at which a scroll view rests at its top
  or bottom, with the adjusted content inset included.

## 2. Summary

1. **Every device refreshes at 60 Hz.** `maximumFramesPerSecond` is 60 on
   the iPhone 17 Pro and the iPad Pro too. Asking a `CADisplayLink` for
   80–120 Hz has no effect. All motion below advances in 16.667 ms steps.
2. **Scrolling deceleration** is exponential: the velocity is multiplied by
   0.998 every millisecond. The projected travel is about 499 ms × the
   release velocity. Deceleration ends when the velocity falls to about
   0.01 pt/ms. The final offset is exactly the projected target, on a pixel
   boundary.
3. **Rubber-banding** while dragging past an edge follows
   `offset = (1 − 1 / (x · 0.55 / d + 1)) · d`. Here x is the finger travel
   past the edge and d is the scroll view's height (or width, for
   horizontal scrolling). After release, the content returns to the edge in
   0.57–0.64 s.
4. **Gesture timing**: a button inside a scroll view highlights 150 ms after
   touch-down; elsewhere it highlights at once. A long press begins 500 ms
   after touch-down. A single tap that waits for a double tap fires 350 ms
   after touch-up. A pan begins after 10 pt of movement. A pinch begins
   after the finger distance changes by about 8 pt.
5. **The keyboard** reports a duration of 0.383 s and animation curve 7. The
   visible motion is a critically damped spring with ω ≈ 24 rad/s.
6. **Rotation** reports 0.3 s on the iPhone and 0.4 s on the iPad. The
   app's window bounds animate with ease-in-ease-out over that time. A
   180° turn reports 0.6 s on the iPhone and 0.8 s on the iPad, but changes
   no size.
7. **Pixels**: screenshots have exactly the device's pixel size and are
   opaque. Text is antialiased in grayscale only: there is no subpixel
   (colour-fringe) antialiasing and no stem hinting. Bitmaps are scaled with
   bilinear filtering. Solid-colour layer edges snap to whole pixels.

## 3. Scrolling

Probe: a vertical `UIScrollView` with the default configuration (bounces,
`alwaysBounceVertical`), 20 000 pt tall, holding striped rows. The
configuration that the probe read at run time:

| Property | Value | Evidence |
|---|---|---|
| `decelerationRate` (default) = `.normal` | 0.998 | 3 (probe read `rawValue`) |
| `.fast` | 0.99 | 3 |
| `delaysContentTouches` | true | 1, 3 |
| `scrollsToTop` | true | 1, 3 |
| Adjusted content inset (top, bottom), iPhone 17 Pro portrait | 62, 34 pt | 3 |
| Same, iPad Pro portrait | 32, 20 pt | 3 |

### 3.1 Flick deceleration

Trigger: the scroll view starts at offset 8000. The test presses for 50 ms,
drags upward over 0.35 × the screen height at the XCUITest velocity shown,
and releases with no hold. The probe logs every `scrollViewDidScroll` until
`scrollViewDidEndDecelerating`.

| Device | XCUITest velocity (pt/s) | Release velocity (pt/ms) | Projected travel (pt) | Travel ÷ release velocity (ms) | Time from release to end of deceleration (s) | Fitted velocity factor per ms |
|---|---|---|---|---|---|---|
| iPhone 17 Pro | 800 | 0.613 [0.598..0.613] | 301.3 [293.7..301.3] | 491.4 [491.0..491.6] | 2.067 [2.049..2.068] | 0.99805 [0.99804..0.99806] |
| iPhone 17 Pro | 2500 | 2.288 [1.297..2.780] | 1138 [643..1384] | 497.4 [495.6..497.7] | 2.717 [2.445..2.818] | 0.99802 [0.99798..0.99805] |
| iPhone 17 Pro | 6000 | 6.019 [6.019..6.095] | 3001.7 [3001.3..3039.7] | 498.6 [498.6..498.7] | 3.200 [3.200..3.217] | 0.99801 [0.99801..0.99802] |
| iPad Pro 11 | 800 | 0.553 [0.553..0.562] | 271.5 [271.5..275.5] | 490.5 [490.2..490.5] | 2.017 [2.001..2.018] | 0.99812 [0.99811..0.99813] |
| iPad Pro 11 | 2500 | 2.016 [2.016..2.025] | 1002.0 [1002.0..1006.5] | 497.0 [496.9..497.0] | 2.667 [2.663..2.668] | 0.99805 [0.99805..0.99806] |
| iPad Pro 11 | 6000 | 6.015 [3.417..6.064] | 2999.5 [1702..3024] | 498.7 [498.0..498.7] | 3.206 [2.918..3.229] | 0.99803 [0.99803..0.99805] |

The fitted factor comes from a log-linear fit of the per-frame velocity from
30 ms after release until the velocity falls to 0.05 pt/ms.

Shape of the curve: the fraction of the total travel covered at fixed times
after release. It is the same on both devices and at every speed, to within
0.02.

| Time after release (ms) | 100 | 250 | 500 | 1000 | 2000 |
|---|---|---|---|---|---|
| Fraction (all runs, median) | 0.18 | 0.39–0.40 | 0.63–0.64 | 0.87–0.88 | 0.98–1.00 |

Rules derived from the data:
- The per-millisecond factor is 0.998, which is `decelerationRate.normal`.
  So v(t) = v₀ · 0.998^t, with t in ms.
- The end condition: the extrapolated velocity at the end of deceleration
  is 0.0103–0.0126 pt/ms in every run (median 0.0108). That is where
  0.998^t · v₀ reaches about 0.01 pt/ms.
- The final `contentOffset` equals the `targetContentOffset` that UIKit
  reported, rounded to a whole pixel: the projected target values are
  multiples of 1/3 pt on the 3× iPhone and 1/2 pt on the 2× iPad. The last
  step before the end is exactly one pixel (0.333 pt on the iPhone, 0.5 pt
  on the iPad).
- `scrollViewDidScroll` arrives once per frame: the median interval is
  16.67 ms on both devices.
- At low speed the projected travel ÷ release velocity is about 491 ms. At
  high speed it is about 499 ms, which is 0.998/(1 − 0.998). The small
  shortfall at low speed is an open question (§11).

### 3.2 Rubber band while dragging past an edge

Trigger: the scroll view rests at its top (or bottom) edge. The test presses
for 50 ms, drags 100, 200 or 400 pt away from the content at 300 pt/s,
holds for 0.6 s and releases. The excursion is the largest distance from
edge rest while the finger is down.

| Device | Finger travel (pt) | Movement before scrolling starts (pt) | Excursion, top edge (pt) | Excursion, bottom edge (pt) |
|---|---|---|---|---|
| iPhone 17 Pro | 100 | 13.0 [13.0..13.0] | 46.7 [46.7..46.7] | 47.0 [42.7..47.0] |
| iPhone 17 Pro | 200 | 11.7 [11.7..11.7] | 93.3 [93.3..93.3] | 93.3 [93.3..93.3] |
| iPhone 17 Pro | 400 | 11.0 [11.0..11.0] | 172.3 [172.3..172.3] | 172.3 [172.3..172.3] |
| iPad Pro 11 | 100 | 23.5 [18.0..46.0] | 40.5 [29.0..43.5] | 43.5 [40.5..46.0] |
| iPad Pro 11 | 200 | 16.5 [16.5..36.5] | 93.0 [83.5..93.0] | 93.0 [93.0..95.5] |
| iPad Pro 11 | 400 | 15.5 [15.5..19.5] | 180.0 [178.5..180.0] | 180.0 [180.0..180.0] |

The "movement before scrolling starts" is the finger travel at
`scrollViewWillBeginDragging`. It is the pan threshold (§4.4) plus up to one
touch sample (5 pt at 300 pt/s).

**Model** (fitted over every run, both edges): excursion =
(1 − 1 / (x · c / d + 1)) · d, where x is the finger travel after scrolling
started and d is the scroll view's height.

| Device | d (pt) | Fitted c | RMS error (pt) |
|---|---|---|---|
| iPhone 17 Pro | 874 | 0.555 | 0.76 |
| iPad Pro 11 | 1210 | 0.550 | 0.11 |

Both edges behave the same. Ycode should use c = 0.55 and d = the scroll
view's size along the scroll axis. The excursion is rounded to whole pixels
(the iPhone values are multiples of 1/3 pt and the iPad values multiples of
1/2 pt).

### 3.3 Return to the edge after release

Same trigger as §3.2. The release has zero velocity because of the 0.6 s
hold. The table gives the fraction of the excursion that remains at fixed
times after touch-up.

| Device | Excursion (pt) | 100 ms | 200 ms | 300 ms | 400 ms | Within 0.5 pt of rest (s) | `scrollViewDidEndDecelerating` after release (s) | Overshoot past rest |
|---|---|---|---|---|---|---|---|---|
| iPhone 17 Pro | 46.7 | 0.548 | 0.251 | 0.107 | 0.043 | 0.517 [0.516..0.518] | 0.568 [0.567..0.568] | none |
| iPhone 17 Pro | 93.3 | 0.448 | 0.185 | 0.076 | 0.029 | 0.535 [0.533..0.535] | 0.585 [0.584..0.600] | none |
| iPhone 17 Pro | 172.3 | 0.408 | 0.160 | 0.062 | 0.023 | 0.567 [0.566..0.583] | 0.619 [0.617..0.636] | none |
| iPad Pro 11 | 43.5 | 0.568 | 0.272 | 0.116 | 0.049 | 0.466 [0.451..0.511] | 0.568 [0.551..0.635] | none |
| iPad Pro 11 | 93.0 | 0.451 | 0.190 | 0.077 | 0.032 | 0.501 [0.482..0.501] | 0.584 [0.583..0.587] | none |
| iPad Pro 11 | 180.0 | 0.402 | 0.161 | 0.062 | 0.023 | 0.534 [0.533..0.535] | 0.635 [0.634..0.637] | none |

The run-to-run spread of each fraction is 0.01 or less, except for the
iPad's 43.5 pt row (up to 0.17, from slow frames). The return never
overshoots. Larger excursions return proportionally faster, so the curve is
not one fixed-shape easing (§11). `didEndDragging` reports
`willDecelerate = true`, and the return ends with
`scrollViewDidEndDecelerating`.

### 3.4 A flick that runs into an edge

Trigger: the scroll view starts 600 pt from its top edge (or bottom edge).
The test flicks toward that edge over 0.30 × the screen height at 2500 or
6000 pt/s. The peak is the largest distance past edge rest. Times are
measured from the frame on which the offset first passes the edge.

| Device | Edge | Release velocity (pt/ms) | Peak past edge (pt) | Time to peak (ms) | Within 0.5 pt of rest (s) | `didEndDecelerating` (s) |
|---|---|---|---|---|---|---|
| iPhone 17 Pro | top | 2.353 [2.289..2.435] | 47.3 [46.0..51.0] | 83 [67..83] | 0.650 [0.633..0.666] | 0.700 [0.684..0.717] |
| iPhone 17 Pro | top | 3.210 [3.172..3.211] | 79.7 [72.7..79.7] | 83 [83..84] | 0.700 [0.683..0.700] | 0.767 [0.750..0.769] |
| iPhone 17 Pro | bottom | 2.353 [2.261..2.366] | 55.0 [50.3..56.0] | 83 [67..84] | 0.667 [0.650..0.667] | 0.717 [0.701..0.719] |
| iPhone 17 Pro | bottom | 3.210 [3.132..3.210] | 83.3 [67.7..84.0] | 83 [67..83] | 0.700 [0.666..0.701] | 0.750 [0.734..0.751] |
| iPad Pro 11 | top | 2.380 [2.332..2.384] | 56.5 [45.0..56.5] | 84 [67..161] | 0.617 [0.583..0.617] | 0.717 [0.684..0.729] |
| iPad Pro 11 | top | 6.465 [3.348..6.614] | 184.0 [79.5..188.5] | 83 [67..83] | 0.733 [0.667..0.750] | 0.843 [0.767..0.853] |
| iPad Pro 11 | bottom | 2.384 [2.308..2.442] | 59.5 [56.0..61.5] | 83 [66..83] | 0.617 [0.616..0.617] | 0.717 [0.717..0.719] |
| iPad Pro 11 | bottom | 6.371 [2.218..6.574] | 183.5 [44.0..190.0] | 83 [67..83] | 0.749 [0.583..0.750] | 0.850 [0.688..0.850] |

The content always reaches its peak 4–5 frames (67–83 ms) after it passes
the edge, whatever the speed. The peak grows with the velocity at the edge.
The return has no second overshoot. (On the iPhone the 6000 pt/s request
reached only 3.2 pt/ms, because the drag was short.)

### 3.5 Paging

Probe: a horizontal `UIScrollView` with `isPagingEnabled`, one page per
screen width (402 pt on the iPhone, 834 pt on the iPad). It starts on page
3. The drag runs from x = 0.8 × the width toward the left.

| Device | Trigger | Offset at release (pages) | Release velocity (pt/ms) | Result | Snap duration, release to `didEndDecelerating` (s) |
|---|---|---|---|---|---|
| iPhone 17 Pro | 30 % drag at 300 pt/s, 0.3 s hold | 0.275 | 0 | back to the same page | 0.367 [0.366..0.374] |
| iPhone 17 Pro | 60 % drag at 300 pt/s, 0.3 s hold | 0.575 | 0 | next page | 0.383 [0.383..0.385] |
| iPhone 17 Pro | 15 % flick at 2000 pt/s, no hold | 0.094 [0.063..0.125] | 0.475 | next page (n = 4) | 0.367 [0.348..0.367] |
| iPad Pro 11 | 30 % drag at 300 pt/s, 0.3 s hold | 0.275 | 0 | back to the same page | 0.438 [0.367..0.504] |
| iPad Pro 11 | 60 % drag at 300 pt/s, 0.3 s hold | 0.582 | 0 | next page | 0.435 [0.433..0.456] |
| iPad Pro 11 | 15 % flick at 2000 pt/s, no hold | 0.067 [0.023..0.112] | 2.178 [1.288..2.188] | next page | 0.417 [0.416..0.428] |

Rules: with no velocity, the view snaps to the nearer page boundary (the
50 % rule). A flick at 0.475 pt/ms advanced one page from only 6–12 % of a
page, so a release velocity overrides the 50 % rule. The smallest velocity
that does so was not measured. No snap overshoots.

The fraction of the remaining distance covered after release:

| Device | 50 ms | 100 ms | 200 ms | 300 ms |
|---|---|---|---|---|
| iPhone 17 Pro, no velocity | 0.17–0.20 | 0.51 | 0.88 | 0.99 |
| iPhone 17 Pro, flick | 0.23 | 0.54 | 0.90 | 0.99 |
| iPad Pro 11, no velocity | 0.14–0.15 | 0.41–0.42 | 0.80–0.81 | 0.96 |
| iPad Pro 11, flick | 0.22 | 0.50 | 0.85 | 0.97 |

The snap is slower on the wider page.

### 3.6 Scrolls to top

Trigger: a tap at y = 12 pt (the status bar) while the scroll view rests at
offset 8000 or 600.

| Device | Start offset | Distance (pt) | 50 % reached (ms) | 90 % (ms) | 99 % (ms) | Last visible movement (ms) | `scrollViewDidScrollToTop` (ms) |
|---|---|---|---|---|---|---|---|
| iPhone 17 Pro | 8000 | 8062 | 80 [74..82] | 248 [246..257] | 498 [497..507] | 1098 | 1614 [1611..1615] |
| iPhone 17 Pro | 600 | 662 | 81 [81..82] | 249 [247..249] | 499 [498..514] | 798 | 1615 [1614..1615] |
| iPad Pro 11 | 8000 | 8032 | 81 [79..165] | 247 [245..248] | 497 [496..512] | 1047 | 1614 [1613..1615] |
| iPad Pro 11 | 600 | 632 | 86 [77..90] | 252 [244..256] | 506 [500..510] | 752 | 1619 [1611..1623] |

Times are measured from `scrollViewShouldScrollToTop`. The tap reaches
`scrollViewShouldScrollToTop` with no event in the app's window: the status
bar belongs to the system. The animation has a **fixed length**, whatever
the distance. It is a strong ease-out: half the distance in 80 ms, 90 % in
250 ms, and 99 % in 500 ms. It ends at edge rest (−inset). After 99 %, the
offset still creeps in single-pixel steps, with ever fewer
`scrollViewDidScroll` calls, until about 0.75–1.1 s. Then nothing moves
until `scrollViewDidScrollToTop` arrives, always 1.614 s after the start.
5 of 5 taps fired in each case.

## 4. Gestures

Probe: a gesture page with a filled `UIButton`, a second button inside a
small `UIScrollView`, and pads that carry a default
`UILongPressGestureRecognizer`, a double-tap / single-tap pair (the single
tap requires the double tap to fail), left and right
`UISwipeGestureRecognizer`s, a `UIPanGestureRecognizer` and a
`UIPinchGestureRecognizer`. The window logs every touch.

### 4.1 Tap highlight

| Device | Trigger | Touch-down to `touchesBegan` on the button (ms) | Touch-down to highlight on (ms) | Touch-up to highlight off (ms) |
|---|---|---|---|---|
| iPhone 17 Pro | press 0.6 s, plain button | 0.2 [0.2..2.0] | 0.3 [0.2..2.1] | 0.2 [0.2..4.0] |
| iPhone 17 Pro | press 0.6 s, button in scroll view | 150.9 [150.6..151.3] | 151.1 [150.8..151.3] | 0.9 [0.4..8.8] |
| iPhone 17 Pro | tap (75 ms), plain button | 0.2 | 0.2 | 0.1 |
| iPhone 17 Pro | tap (75 ms), button in scroll view | at touch-up (+0.3) | at touch-up (+0.3) | 0.5 [0.3..8.7] |
| iPad Pro 11 | press 0.6 s, plain button | 0.2 [0.2..0.7] | 0.2 [0.2..0.8] | 0.2 [0.2..0.7] |
| iPad Pro 11 | press 0.6 s, button in scroll view | 150.8 [150.5..357.8] | 150.9 [150.5..357.9] | 0.5 [0.4..21.2] |
| iPad Pro 11 | tap (77 ms), plain button | 0.2 | 0.2 | 0.2 |
| iPad Pro 11 | tap (77 ms), button in scroll view | at touch-up (+0.3) | at touch-up (+0.2) | 0.4 [0.3..0.4] |

Rules:
- Outside a scroll view, the highlight turns on in the same event pass as
  touch-down.
- Inside a scroll view (`delaysContentTouches` = true), touches are held
  back for **150 ms**. A finger that lifts sooner gets its `touchesBegan`
  delivered at touch-up. The highlight then turns on and off in the same
  run-loop pass, so it never reaches the screen. `.touchUpInside` fires in
  every case (20 of 20).

### 4.2 Long press

The defaults read at run time: `minimumPressDuration` = 0.5 s and
`allowableMovement` = 10 pt (level 1, the documented defaults; level 3, the
probe read them).

| Device | Press length (ms) | Recognized | Touch-down to `.began` (ms) |
|---|---|---|---|
| iPhone 17 Pro | 1009 [1007..1025] | 5/5 | 501.7 [500.6..570.8] |
| iPhone 17 Pro | 424 [421..431] | 0/5 | — |
| iPhone 17 Pro | 465 [455..467] | 0/5 | — |
| iPhone 17 Pro | 559 [536..4057] | 5/5 | 506.0 [500.8..4031.6] |
| iPad Pro 11 | 1012 [1006..1015] | 5/5 | 501.4 [500.6..776.0] |
| iPad Pro 11 | 423 [382..432] | 0/5 | — |
| iPad Pro 11 | 455 [450..461] | 0/5 | — |
| iPad Pro 11 | 556 [553..565] | 5/5 | 501.4 [500.7..512.8] |

`.began` fires 500 ms after touch-down, plus up to 2 ms of delivery. It
fires while the finger is still down and does not wait for movement. The
4 s maxima are host stalls.

### 4.3 Double tap

| Device | Trigger | Value |
|---|---|---|
| iPhone 17 Pro | single tap (72 ms) on a pad where the single tap requires the double tap to fail | single tap fires 351.6 [351.2..352.1] ms after touch-up |
| iPad Pro 11 | same | 350.8 [350.4..351.4] ms after touch-up |
| both | `doubleTap()` (taps of 42–83 ms, 0.5–26 ms apart) | double tap recognized 5/5; single tap never fired |

So a single tap that waits for a double tap is delayed **350 ms** after
touch-up: that is how long UIKit waits for a second tap. XCUITest's
`doubleTap` puts its taps less than 30 ms apart, so the largest gap that
UIKit still accepts was not measured (§11).

### 4.4 Pan threshold

Trigger: a drag of 80 pt at 100 pt/s on the pan pad. The touch samples
arrive every 16.7 ms (1.67 pt apart).

| Device | Finger movement when `.began` fires (pt) | Touch-down to `.began` (ms) | `translation` at `.began` |
|---|---|---|---|
| iPhone 17 Pro | 10.00 [10.00..10.00] | 191 [187..199] | (0, 0) |
| iPad Pro 11 | 12.00 [10.00..12.00] | 204 [200..214] | (0, 0) |

A pan begins on the first touch sample that is 10 pt or more from the
touch-down point. Its translation is reset to zero at that moment: the
first 10 pt do not appear in the translation. A scroll view's drag starts at
the same distance (§3.2: 11–13 pt with 5 pt samples).

### 4.5 Swipe

Trigger: a horizontal drag (a 20 ms press, then a drag, then release with no
hold) on a pad with left and right `UISwipeGestureRecognizer`s, which have
the default configuration (1 touch). The sample cadence is 16.7 ms. These
results were identical on both devices.

| Drag | Speed (pt/s) | Recognized | Finger travel at recognition (pt) | Touch-down to recognition (ms) |
|---|---|---|---|---|
| 10 pt | 1500 | 0/5 | — | — |
| 20 pt | 1500 | 0/5 | — | — |
| 40 pt (lift at 40) | 1500 | 0/5 | — | — |
| 60 pt | 1500 | 5/5 | 52.7 | 67 |
| 100 pt | 1500 | 5/5 | 51.7 (one run: 100, at touch-up) | 67 |
| 200 pt | 1500 | 5/5 | 47.0 | 67 |
| 200 pt | 100 | 5/5 | 33.0 | 400 |
| 200 pt | 200 | 5/5 | 40.0 | 250 |
| 200 pt | 400 | 5/5 | 43.3 | 150 |
| 200 pt | 800 | 5/5 | 50.7 | 100 |

A swipe is recognized during the movement (never at touch-up). A stroke of
40 pt or less was never recognized, even at 1500 pt/s. Slow strokes of
100 pt/s were still recognized. The travel needed rises with speed, from
33 pt at 100 pt/s to about 50 pt at 800 pt/s and above, so the rule is not a
plain distance threshold (§11). A Ycode implementation that reproduces
these ten cases is acceptable.

### 4.6 Pinch

Trigger: XCUITest `pinch(withScale: 2, velocity: 1)` and
`pinch(withScale: 0.5, velocity: −1)` on the pinch pad.

| Device | Trigger | Finger distance at touch-down (pt) | Change in distance when `.began` fires (pt) | `scale` at `.began` | Touch-down to `.began` (ms) |
|---|---|---|---|---|---|
| iPhone 17 Pro | spread | 5.9 | +8.24 | 1.018 | 111 [98..115] |
| iPhone 17 Pro | pinch | 187.9 | −8.02 (magnitude) | 1.000 | 109 [103..117] |
| iPad Pro 11 | spread | 7.6 | +8.66 | 1.043 | 388 [383..399] |
| iPad Pro 11 | pinch | 372.1 | −8.54 | 0.999 | 174 [163..181] |

A pinch begins when the distance between the two touches has changed by
about 8–9 pt. The scale is measured from the distance at that moment, so
`scale` is about 1.0 at `.began`, not the ratio to the touch-down distance.
All 20 pinches were recognized.

## 5. Keyboard

### 5.1 Software keyboard

Trigger: a tap on a `UITextField` (show), then a button that calls
`resignFirstResponder` (hide). This was repeated 5 times in portrait and 5
times in landscape.

| Device | Orientation | `keyboardFrameEnd` when shown (pt) | Duration in user info (s) | Curve in user info | `keyboardFrameBegin` on show | Will-to-did interval (ms) |
|---|---|---|---|---|---|---|
| iPhone 17 Pro | portrait (402 × 874) | (0, 546, 402, 328) | 0.383 (all 22 notifications) | 7 | (0, 0, 0, 0) | show 403.7 [389.6..586.1]; hide 401.2 |
| iPhone 17 Pro | landscape (874 × 402) | (0, 178, 874, 224) | 0.383 | 7 | (0, 0, 0, 0) | as above |
| iPad Pro 11 | portrait (834 × 1210) | (0, 870, 834, 340) | 0.383 (all 23 notifications) | 7 | (0, 0, 0, 0) | show 407.3 [395.2..532.5]; hide 404.5 |
| iPad Pro 11 | landscape (1210 × 834) | (0, 406, 1210, 428) | 0.383 | 7 | (0, 0, 0, 0) | as above |

Notes:
- The duration is 0.38333 s exactly in every notification, which is 23
  frames at 60 Hz.
- On show, the **begin frame is the zero rectangle**, not an off-screen
  frame. On hide, the begin frame is the shown frame, and the end frame is
  the same size moved to y = the screen height.
- Every show and hide sends will-change-frame and did-change-frame as well.
  `keyboardIsLocal` is true.
- Once, the iPad sent a will-change and will-hide pair with begin
  (417, 605, 0, 0) and end (0, 1210, 834, 0): a zero-height keyboard at the
  bottom. This came during the orientation change before the first focus.

### 5.2 Visible motion

The probe pinned a view to `keyboardLayoutGuide` and sampled its
presentation layer every frame. The fraction of the travel completed, from
the frame of first movement:

| Device | Event | 1 frame | 2 | 3 | 4 | 6 | 9 | 12 | 18 | 24 | Fitted ω (rad/s) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| iPhone 17 Pro | show | 0.080 | 0.197 | 0.350 | 0.484 | 0.694 | 0.874 | 0.951 | 0.993 | 1.000 | 23.7 |
| iPhone 17 Pro | hide | 0.115 | 0.273 | 0.416 | 0.542 | 0.737 | 0.892 | 0.959 | 0.995 | 1.000 | 24.3 |
| iPad Pro 11 | show | 0.088 | 0.227 | 0.369 | 0.506 | 0.709 | 0.880 | 0.954 | 0.994 | 1.000 | 23.9 |
| iPad Pro 11 | hide | 0.123 | 0.272 | 0.417 | 0.543 | 0.735 | 0.892 | 0.959 | 0.995 | 1.000 | 24.0 |

The landscape values agree with the portrait values to within 0.02.

Curve 7 is reproduced, with an RMS error of 0.004 or less, by a
**critically damped spring that starts at rest**:
p(t) = 1 − (1 + ωt)·e^(−ωt) with ω ≈ 24 rad/s. That is a stiffness of
about 576 and a damping of about 48, for mass 1. Motion starts within 1
frame of `keyboardWillShow` (median lag 6–18 ms). It reaches 99 % at about
383 ms, the reported duration, and never overshoots.

### 5.3 Hardware keyboard

- At launch, every probe received `GCKeyboardDidConnect`, so GameController
  reports a hardware keyboard on a headless-booted device. Even so, the
  software keyboard appeared on every focus (§5.1).
- `simctl` has no command that connects or disconnects the hardware
  keyboard: neither `simctl io` nor `simctl ui` offers one. `simctl io
  enumerate` shows one HID port (`com.apple.CoreSimulator.HID.LegacyHID`)
  and no keyboard-specific port. The hardware-keyboard toggle is therefore
  not reachable headless, and its effect was not observed.
- XCUITest `typeText("abc")` produced **no** `UIPress` events in the app's
  window, so it does not type through the hardware-keyboard path.
- For hardware-key routing (HID page 7 to the focused responder), see
  `hid-input.md` §5.4 and §9.

## 6. Rotation

Trigger: `XCUIDevice.orientation` is set to portrait ↔ landscapeLeft
(90°), and to landscapeLeft ↔ landscapeRight (180°). There were 12 turns of
90° and 10 of 180° per device. The probe sampled the window's presentation
layer every frame.

### 6.1 Reported values and callback order

| Device | Turn | `transitionDuration` (s) | `completionCurve` | `willTransition` to completion (ms) |
|---|---|---|---|---|
| iPhone 17 Pro | 90° | 0.3 | 0 (ease-in-ease-out) | 339 [327..620] |
| iPhone 17 Pro | 180° | 0.6 | 0 | 4.2 [2.7..39.2] |
| iPad Pro 11 | 90° | 0.4 | 0 | 503 [448..849] |
| iPad Pro 11 | 180° | 0.8 | 0 | 6.4 [3.6..12.5] |

Order of callbacks after `viewWillTransition(to:with:)` on a 90° turn, in
ms after it (medians):

| Callback | iPhone 17 Pro | iPad Pro 11 |
|---|---|---|
| `viewSafeAreaInsetsDidChange` | 0.5 | — (insets do not change) |
| trait change (vertical size class regular ↔ compact) | 1.3 | — (stays regular/regular) |
| `viewWillLayoutSubviews` / `viewDidLayoutSubviews` (bounds already final) | 1.5 | 1.1 |
| `animate(alongsideTransition:)` block | 1.7 | 1.1 |
| scene `didUpdateEffectiveGeometry` | 1.7 | 2.7 |
| completion block | 339 | 503 |

On a 180° turn there is no layout, size, trait or safe-area callback: only
the alongside block (0.5 ms), the geometry update (0.5–1.3 ms) and the
completion (4–6 ms). The reported 0.6 or 0.8 s is not visible to the app.

Safe-area insets (top, left, bottom, right):

| Device | Portrait | Landscape |
|---|---|---|
| iPhone 17 Pro | 62, 0, 34, 0 | 0, 62, 20, 62 |
| iPad Pro 11 | 32, 0, 20, 0 | 32, 0, 20, 0 |

### 6.2 Visible animation

The app's window layer keeps an identity transform (rotation angle 0 in
every sample). Its **bounds** animate from the old size to the new one. The
fitted curve and length:

| Device | Best curve | RMS | Fitted length (ms) | Start after `willTransition` (ms) |
|---|---|---|---|---|
| iPhone 17 Pro | ease-in-ease-out (0.42, 0, 0.58, 1) | 0.0015 | 300 [295..620] | 26 [6..98] |
| iPad Pro 11 | ease-in-ease-out | 0.0098 | 405 [395..695] | 70 [22..98] |

Ease-out, the UIKit default curve and linear all fit worse (RMS 0.010–0.043).
The measured iPhone profile at 50, 100, 150, 200, 250 and 300 ms after the
first change was 0.055, 0.230, 0.498, 0.767, 0.943 and 1.000. The
ease-in-ease-out curve gives 0.056, 0.232, 0.500, 0.768, 0.944 and 1.000.
The iPad samples had more dropped frames (host load), which explains the
larger start spread. How the system composes the rotation outside the app's
window (snapshot, crossfade, rotation of the device image) cannot be seen
from inside the app (§11).

## 7. Frame pacing

### 7.1 Refresh rates on offer

| Device | `UIScreen.maximumFramesPerSecond` | Display mode refresh (`simctl io enumerate`) | Real device |
|---|---|---|---|
| iPhone 17 Pro | 60 | 6000 (= 60.00 Hz) on every display port | 120 Hz ProMotion |
| iPad Pro 11 (M5) | 60 | 6000 | 120 Hz ProMotion |
| iPhone Duo (cover and inner) | 60 | 6000 | — |

`ipad.md` §5.4 found the same. The simulator offers **one refresh rate,
60 Hz**, on every device type, ProMotion models included.

### 7.2 `CADisplayLink` intervals

Trigger: a display link on the main run loop in common modes. Variant
"default" leaves the frame-rate range unset. Variant "max" asks for
`preferredFrameRateRange` (80, 120, preferred 120), and the app sets
`CADisableMinimumFrameDurationOnPhone`. Idle is 1.6 s with nothing moving,
repeated 5 times. Animating is a 2 s linear `UIView` animation, 5 times.
Scrolling is a slow drag held under the finger, then a 2500 pt/s flick
decelerating, 5 times.

| Device | Variant | Idle | Animating | Tracking a drag | Decelerating |
|---|---|---|---|---|---|
| iPhone 17 Pro | default | 16.667 (p5–p95 16.667–16.667), n = 480 | 16.667 (16.667–16.667), n = 583, 2 long | 16.667 (16.667–16.667), n = 629 | 16.667 (16.667–16.667), n = 814 |
| iPhone 17 Pro | max | 16.667, n = 480 | 16.667, n = 586, 0 long | 16.667, n = 634 | 16.667, n = 814 |
| iPad Pro 11 | default | 16.667, n = 480 | 16.667, n = 580, 3 long | 16.667, n = 851 | 16.667, n = 793 |
| iPad Pro 11 | max | 16.667, n = 480 | 16.667, n = 587, 4 long | 16.667, n = 846 | 16.667, n = 771 |

The values are median intervals between `timestamp`s, in ms. "Long" counts
intervals more than 1.5× the median. Every long interval coincided with
host load or with XCUITest querying the app. While XCUITest was finding a
button, the "idle" stretches in the scroll runs had p95 27–38 ms. Those
hitches are caused by the test driver and are not part of UIKit's
behaviour.

Other display-link facts (all runs):
- `duration` = 16.667 ms, and `targetTimestamp − timestamp` = 16.667 ms.
- The callback runs a median of 17.19 ms after `timestamp`, which is about
  0.5 ms after `targetTimestamp`.
- Asking for 120 Hz changes nothing: no interval shorter than 16.66 ms was
  ever seen.

### 7.3 What the host receives (screen recording)

Trigger: `simctl io <iPhone 17 Pro> recordVideo --codec=h264` ran during
the 15-flick run of §3.1, 171 s in all.

| Fact | Value |
|---|---|
| Video | 1206 × 2622 px (native size), H.264, time base 1/600 s, variable frame rate |
| Frames | 3162. A new frame arrives only when the screen changes; idle gaps were up to 6.2 s with no frames |
| Interval while something moves (39 runs, 2900 intervals) | median 16.667 ms, p5 13.3 ms, p95 20.0 ms |
| Distribution | 16.7 ms: 51 %; 15.0 or 18.3 ms (one 1/600 s tick early or late, in alternating pairs): 35 %; 13.3 or 20.0 ms: 5 %; about 33 ms (one dropped frame): 1.8 % |

The host gets 60 frames per second while content moves and none while it
is still. The ±1.7 ms jitter comes from the capture path; the guest's
display link has none (§7.2).

## 8. Text and image sharpness

Trigger: a probe page with black labels on white (system font at 9, 12, 17
and 34 pt), the same 17 pt label moved by exactly 1 px and by ½ px, red
text, 1-px checkerboard images, hairlines and a 1 pt line. It was captured
with `simctl io <device> screenshot`, with the default mask policy, at the
native size.

### 8.1 Screenshot and display geometry

| Device | Points | Scale (`scale` = `nativeScale`) | Screenshot pixels | PNG |
|---|---|---|---|---|
| iPhone 17 Pro | 402 × 874 | 3 | 1206 × 2622 | RGBA, sRGB chunk, no ICC profile, alpha 255 everywhere |
| iPad Pro 11 (M5) | 834 × 1210 | 2 | 1668 × 2420 | RGBA, sRGB chunk, no ICC profile, alpha 255 everywhere |
| iPhone Duo cover (`LCD`) | 466 × 678 | 3 | 1398 × 2034 (needs `--display=LCD`; without it `simctl` refuses with "Invalid argument" because the device has several displays) | RGBA, sRGB chunk, alpha 255 everywhere |
| iPhone Duo inner (`LCD-1`) | — | 3 | 2007 × 2853 (enumerated mode; not captured) | — |

The default screenshot is unmasked and opaque: the rounded corners are not
cut out.

### 8.2 Text rendering

| Fact | iPad Pro (2×, iOS 27.2) | iPhone Duo (3×, iOS 27.1) and iPhone 17 Pro (3×, iOS 27.2) |
|---|---|---|
| Antialiasing | grayscale: 0 of 1904 partially covered pixels in black 17 pt text have any colour difference between R, G and B (9 pt: 0 of 1278; 34 pt bold: 0 of 1582) | grayscale: 0 of 2802 (9 pt: 0 of 1965) |
| Subpixel (LCD) antialiasing | none | none |
| Distinct gray levels in a 17 pt line | 254 | 256 |
| Stem hinting | none: an `l` stem at 17 pt covers 218, 0, 0, 65 (about 2.4 px wide) | none: 72, 0, 0, 0, 98 (about 3.6 px wide) |
| Label moved by 1 px | identical to the original, moved by 1 px (mean difference 0.000) | identical (0.000) |
| Label moved by ½ px | equals the average of the original and the 1-px-shifted original (mean difference 0.06 of 255): the label's bitmap is composited at a half-pixel offset with bilinear filtering, not re-rasterized | differs from both whole-pixel renderings (7.8 of 255) and does not equal their average (15.4): glyphs are re-rasterized at the fractional origin |

The iPhone 17 Pro (3×, iOS 27.2) gave **pixel-identical** results to the
iPhone Duo (3×, iOS 27.1) on every row of this table and of §8.3. The
numbers match exactly, including the mean differences 7.76 and 15.41 for
the half-pixel label. So the different half-pixel behaviour depends on the
**scale**, not the runtime. At 2× a label at a half-pixel origin is
resampled bilinearly. At 3× it is rasterized again at the fractional
position.

### 8.3 Images and solid layers

| Item | iPad Pro (2×) | iPhone Duo and iPhone 17 Pro (3×) |
|---|---|---|
| Checkerboard drawn at the screen scale, pixel-aligned | exact: only gray levels 0 and 255 | exact: 0 and 255 |
| Same image at a ½-px vertical offset | uniform 128 (each pixel averages two rows): bilinear | 128: bilinear |
| A scale-1 bitmap shown at its point size (2× or 3× magnification) | levels 64, 96, 159, 191: interpolated, not nearest-neighbour | 0, 85, 170, 255 across each 3-px span: linear interpolation |
| A 16-px scale-1 bitmap stretched to 37 pt (`scaleToFill`) | 180 distinct levels: smooth (bilinear) | 254 levels: smooth |
| A 1-px solid view at a ½-px offset | one fully black row, no gray: the edge snaps to the pixel grid | one fully black row |
| A 1 pt solid view at a ½-px offset | 2 fully black rows | 3 fully black rows |

Rules: bitmap content is sampled with **linear filtering**, the default
`magnificationFilter`, at its exact sub-pixel position. Solid-colour layers
with axis-aligned edges are **not** antialiased: their edges round to whole
pixels. The image left on screen is exactly the app's rendering at native
resolution. The screenshot path adds no scaling or blur.

### 8.4 Window scales

The issue asks for sharpness "at each scale the device window offers". Our
rules forbade opening Simulator's window, so the window's scaling options
(and how the host scales the framebuffer for them) were not observed (§11).
Everything above is at native resolution, 1 device pixel per screenshot
pixel.

## 9. What Ycode must reproduce (guidance for #83)

These are behaviours, not implementation instructions. Ycode runs the real
UIKit inside the guest, so most of §3–§6 comes for free **if** the guest
sees the right display timing and receives input with correct timestamps.
The host-side requirements are:

1. **A 60 Hz vsync** with a 16.667 ms period. `maximumFramesPerSecond` must
   be 60 on every device type, ProMotion models included (§7.1). The
   display-link `timestamp` must advance in steady 16.667 ms steps when idle.
2. **Touch samples** must reach the guest at the cadence that the host
   input provides, with timestamps that increase monotonically. UIKit's
   thresholds measure distance (10 pt pan, about 8 pt pinch, 33–53 pt swipe)
   and time (150 ms, 350 ms, 500 ms) against those timestamps. Late or
   bunched delivery shifts the highlight and long-press timing that users
   see.
3. **The visible result** of a flick must follow §3.1: a 0.998 per-ms
   decay, ending at the pixel-rounded target. A rubber band must follow
   c = 0.55 (§3.2). The keyboard must move as a critically damped spring at
   ω ≈ 24 over about 383 ms (§5.2). Rotation must ease in and out over 0.3 s
   (iPhone) or 0.4 s (iPad) (§6.2). If Ycode's guest shows a different
   result, the guest clock or vsync is wrong.
4. **Pixels**: the viewer must show the framebuffer at 1:1 with no
   filtering, and screenshots must have exactly the sizes in §8.1. Text
   comes from the guest and needs no host processing: grayscale, no
   hinting.
5. **The hardware keyboard** is reported as connected (GameController) but
   the software keyboard still shows on focus (§5.3). Ycode's default
   should give the same result.

## 10. iPhone Duo on iOS 27.1 (cross-check)

The whole probe suite (§3–§7) ran on the iPhone Duo's cover display (466 ×
678 pt, scale 3) with the reference runtime, iOS 27.1 (24A94401). It had the
same triggers and run counts as the other devices. Every UIKit constant
matches the iOS 27.2 values. Distances that depend on the view's size scale
with the cover's size, as the models predict.

| Area | iPhone Duo, iOS 27.1 | Same as 27.2? |
|---|---|---|
| Flick (§3.1), release velocity 0.641 / 2.589 / 3.094 pt/ms | per-ms factor 0.99805 / 0.99801 / 0.99801; travel ÷ velocity 491.8 / 497.6 / 497.9 ms; end of deceleration after 2.085 / 2.784 / 2.867 s; final step 1 px; end velocity 0.0104–0.0109 pt/ms | yes |
| Rubber band (§3.2), finger 100 / 200 / 400 pt | movement before scrolling 13.0 / 11.7 / 11.0 pt; excursion 46.0 / 90.3 / 163.0 pt (top and bottom alike); the model with c = 0.55 and d = 678 gives 44.6 / 89.7 / 162.6 | yes (d = the cover's height) |
| Return (§3.3) | remaining at 100 / 200 / 300 / 400 ms: 0.550, 0.253, 0.110, 0.044 (46 pt); 0.446, 0.187, 0.075, 0.030 (90 pt); 0.407, 0.161, 0.061, 0.025 (163 pt); `didEndDecelerating` 0.568 / 0.584 / 0.617 s | yes, to within 0.005 |
| Edge bounce (§3.4), about 2.6–2.7 pt/ms | peak 60.0 pt (top), 58.3 pt (bottom); peak 83 ms after the crossing; `didEndDecelerating` 0.718–0.733 s | yes. The 6000 pt/s request gave unusable runs on this short screen: 3 of 5 with a lower velocity |
| Paging (§3.5), page 466 pt | 30 % back, 60 % forward, 13 % flick at 0.966 pt/ms forward; snap 0.384 / 0.384 / 0.367 s; fraction at 100 / 200 / 300 ms 0.50, 0.88, 0.99 | yes (between the iPhone 17 Pro and the iPad, matching the page width) |
| Scroll to top (§3.6), 8000 and 600 pt | 50 % at 81 ms, 90 % at 247–248 ms, 99 % at 498 ms; `didScrollToTop` at 1.614 s; 9 of 10 taps fired | yes |
| Highlight (§4.1) | plain 0.2 ms; in a scroll view 151.2 [150.4..151.6] ms; a quick tap in a scroll view highlights at touch-up and clears 0.3 ms later | yes |
| Long press (§4.2) | 0.5 s and 10 pt defaults; `.began` 500.9 [500.4..576.5] ms after down; presses of 425 and 462 ms 0/5; 564 ms 5/5 | yes |
| Double tap (§4.3) | single tap 351.3 [350.5..351.4] ms after touch-up; double tap 5/5 | yes |
| Pan (§4.4) | begins at 10.00 pt, translation (0, 0) | yes |
| Swipe (§4.5) | same ten outcomes; recognized at 33 / 40 / 43 / 51 pt for 100 / 200 / 400 / 800 pt/s; nothing at 40 pt or less | yes |
| Pinch (§4.6) | a spread begins after +8.14 pt, scale 1.010 at `.began`. The inward pinch's two touches started 203 pt apart, wider than the small pad on this screen, so it began only after a 66 pt change (scale 0.70). That is an artifact of the probe layout and not a different threshold | spread yes |
| Keyboard (§5) | portrait frame (0, 389, 466, 289); 0.383 s; curve 7; begin frame zero on show; visible curve 0.083, 0.198, 0.347, 0.484, 0.695, 0.874, 0.951, 0.993, 1.0 at 1–24 frames (show) | yes |
| Keyboard hide notifications | after the first hide, `keyboardDidHide` arrived 8–10 ms after `keyboardWillHide` (10 of 11 hides), while the visible motion still ran for the full 383 ms. On the iPhone 17 Pro and iPad on 27.2 it arrived after about 400 ms | **no**: Ycode must allow both; a guest that sends did-hide early is not a fault |
| Rotation (§6) | setting the device orientation to landscape did **not** rotate the cover display's interface: no `viewWillTransition`, the size stayed 466 × 678, and the safe area changed once from (82, 0, 34, 0) to (0, 0, 34, 84). The keyboard was therefore measured in portrait only | not comparable (`foldable.md` covers the Duo's orientation handling) |
| Frame pacing (§7) | `maximumFramesPerSecond` 60; every interval 16.667 ms when idle and animating, for both variants; callback 17.19–17.20 ms after `timestamp` | yes |
| Pixels (§8) | identical to the iPhone 17 Pro | yes |

## 11. Open questions

1. Find the swipe recognizer's rule: the required travel rises with speed
   (§4.5). Find the largest gap between taps that still makes a double tap
   (XCUITest cannot space taps); the single-tap delay of 350 ms is an upper
   bound.
2. Find a formula for the release of a rubber band: the return is faster
   for larger excursions, and no single spring fits all three (§3.3). The
   tables are the target for now.
3. Find why the projected flick travel is about 491 ms × the release
   velocity at low speed but 498–499 ms at high speed, on all three devices
   (§3.1).
4. Find how the system composes rotation outside the app's window (§6.2)
   and how the host scales the framebuffer at each Simulator window scale
   (§8.4). Both need the Simulator window, which our rules kept closed.
5. Toggling the hardware keyboard headless is not possible with `simctl`
   (§5.3). What changes when a host keyboard is connected through
   Simulator's menu was not observed.
6. Find the smallest release velocity at which paging advances a page
   instead of following the 50 % rule (§3.5).
7. Find why the iPhone Duo on 27.1 sends `keyboardDidHide` at the start of
   the hide animation (§10), and whether the runtime or the device type
   causes it. The iPhone 17 Pro on 27.1 cannot be created, so a same-device
   comparison is not possible with the installed runtimes.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Runtimes, device-type support, "Incompatible device" on 27.1 (§1.1) | 3 | `simctl list runtimes -j`, `simctl create` results |
| `decelerationRate` values, `delaysContentTouches`, `scrollsToTop` defaults (§3) | 1, 3 | UIKit documentation (property defaults); probe read at run time |
| Deceleration factor, end condition, pixel-rounded target, curve (§3.1) | 3 | probe `scrollViewDidScroll` log, 15 flicks per device |
| Rubber-band excursions and fitted c = 0.55 (§3.2) | 3 | probe log, 30 drags per device; the fit is ours |
| Return and edge-bounce timing (§3.3, §3.4) | 3 | probe log |
| Paging snap and 50 % rule (§3.5) | 3 | probe log, 15 drags per device |
| Scroll-to-top curve and timing (§3.6) | 3 | probe log, 10 taps per device |
| Highlight delays, 150 ms content-touch delay (§4.1) | 3 | probe window and button logs; the existence of the delay is documented for `delaysContentTouches` (1) |
| Long-press defaults 0.5 s and 10 pt (§4.2) | 1, 3 | UIKit documentation for `minimumPressDuration` and `allowableMovement`; probe read and timing |
| Double-tap wait 350 ms (§4.3) | 3 | probe log |
| Pan threshold 10 pt and zero translation at `.began` (§4.4) | 3 | probe log |
| Swipe recognition points (§4.5) | 3 | probe log, 50 strokes per device |
| Pinch threshold about 8 pt and scale reference (§4.6) | 3 | probe log |
| Keyboard frames, duration, curve 7, zero begin frame (§5.1) | 3 | keyboard notification user info logged by the probe |
| Keyboard motion as a critically damped spring (§5.2) | 3 | `keyboardLayoutGuide` presentation samples; the fit is ours |
| GameController keyboard connected; no simctl toggle; no `UIPress` from `typeText` (§5.3) | 3 | probe log; `simctl help io` / `simctl help ui`; `simctl io enumerate` |
| Rotation durations, curve 0, callback order, safe areas (§6.1) | 3 | probe log |
| Rotation ease-in-ease-out fit (§6.2) | 3 | presentation-layer samples; the fit is ours; CA easing control points as publicly documented (1) |
| 60 Hz, `maximumFramesPerSecond`, display-link intervals (§7) | 3 | probe screen and display-link logs; `simctl io enumerate` refresh 6000 |
| iPhone Duo on iOS 27.1, all areas (§10) | 3 | the same probe suite on the reference runtime |
| Host-side frame cadence (§7.3) | 3 | `simctl io recordVideo` file; frame timestamps read with `ffprobe` |
| Screenshot sizes and format (§8.1) | 3 | `simctl io screenshot` files, read with an image library |
| Text antialiasing, hinting, half-pixel behaviour (§8.2) | 3 | pixel statistics of our screenshots |
| Image filtering and pixel-snapping of solid layers (§8.3) | 3 | pixel statistics of our screenshots |

Levels 4 and 5 were not used. No Apple binary was opened, disassembled or
decompiled, and Ghidra was not used. Apple's simulator and `xcodebuild` ran
only as black boxes on devices that we created (`ycode-test-uikit-*`). The
probe app, its UI tests, logs, screenshots and analysis scripts stay in the
git-ignored `research/dirty/uikit-feel/` and are not committed.
