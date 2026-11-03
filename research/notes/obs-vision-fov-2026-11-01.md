# OBS-VISION-FOV: field of view, camera smoothing and pose timing (2026-11-01)

Dirty-room observations behind `specs/simulator/visionos.md` §5.5.12
(camera smoothing and pose timing) and §5.6.6 (field of view), for the
headset viewer (XR-VIEWER): the owner wants a wider field of view (up to a
fully surrounding view, no black border) and less latency. Prose only.
Raw frame samples, logs, crash-report summaries and screenshots stay in
the agent scratch folder (`_agents/scratch/2026-11-01-obs-vision-fov/dirty/`).
No disassembly or decompilation (level 5 not used); Ghidra, the reference
tools folder and the IPSW were not opened; nothing was decrypted; no GUI
clicks or screen takeover.

## Setup

- Xcode 27.1; runtime **visionOS 27.2 (24N120)**. A 27.0 device could
  not be created ("runtime path not found", as in §5.5.9). The installed
  "Apple Vision Pro (at 2732x2048)" type was refused by 27.2, 26.5 and
  26.4 ("Incompatible device"); its profile limits it to runtimes ≤ 2.99,
  none of which is installed.
- Devices (all `ycode-test-vision7-*`, one booted at a time, all deleted
  at the end): `-a` (Apple Vision Pro 4K type) for the smoothing series,
  and five devices of **test device types of our own** in
  `~/Library/Developer/CoreSimulator/Profiles/DeviceTypes/` (copies of
  the installed 4K type with only the integrated display's width, height
  and refresh rate changed in `capabilities.plist`; created by
  `fov/mktype.py`, removed at the end): square 3840 × 3840, wide
  7680 × 2160, tall 2160 × 3840, extra tall 1024 × 8192, and 3840 × 2160
  at 30 Hz. CoreSimulator picked the types up without a restart.
- Tools (sources in `research/experiments/visionos/`):
  - `fov/camrec.m` (new): inserted into the boot. In backboardd it logs
    every PalomaPose event at dispatch (mach time, the event's timestamp,
    translation, quaternion) and can rewrite the pose events' flags
    (`CR_PFLAGS`, `CR_TFLAGS`, `CR_OFLAGS`). In wakeboardd it timestamps
    every `SFBSwapchainSwapAddSurface` and, while a marker file exists,
    samples three rows of the surface presented one swap earlier (8-bit
    luma, every second pixel).
  - `fov/camstep.py`: the camera's yaw per presented frame: the middle
    row resampled to view angle (pinhole, 90° horizontal) and matched
    against a reference frame (normalised cross-correlation, sub-bin
    peak). Normalised correlation 0.995–1.0 on every frame.
  - `fov/stepsum.py`, `fov/lagfit.py`: step summaries (first change,
    50 %, 90 %, within 0.1°) and delay/gain fits for pose streams.
  - `input/vhid.m` extended: `STAMP=1` prints the host's mach time of each
    send and the time written into the message; `TS_OFFSET_MS`, `TS_ABS`
    and `TS_SCALE` rewrite the message's host time (offset 0x24).
  - `fov/posegen.py` (pose scripts: steps, repeats, ramps, sines),
    `fov/series1.sh` (the series), `fov/pexp.sh` (preferences before boot,
    then a step, a sine and/or StereoProbe), `fov/setdomain.py`.
  - The runtime's `wakeboardctl status` (`simctl spawn`) for the per-eye
    tangents and projection; `StereoProbe` (OBS-VISION-STEREO) for what an
    app's CompositorLayer is given.
- All times are on the host's mach clock (the guest shares it): a pose is
  "sent" at vhid's send; a frame's time is its `SwapAddSurface`.

## Pose timing (Q3)

- The pose message's host time (offset 0x24, written by the builder at
  build time, ~1 µs before the send) **becomes the IOHIDEvent's timestamp
  unchanged**; backboardd dispatches the event about 3 ms after the send.
- The guest does not use that timestamp for the camera's timing:
  constant offsets of +200 ms, +3 s, −200 ms, −3 s, timestamps scaled by
  0.1 or 10 relative to the first message (so every event 10× closer or
  10× further apart in time than sent, up to 30 s in the future), all gave
  the same per-frame trajectory, to the hundredth of a degree, as real
  times.
- One exception: two consecutive events with the **same** timestamp (both
  1): the first moved the camera normally; the second (identity) did not
  take effect; ~420 ms later the picture jumped to the first segment's
  value (5.33° of 30°) and stayed there until later events. Ycode must send
  strictly increasing timestamps (it does: guest ticks).

## Camera smoothing (Q2)

### Single step (isolated pose after ≥ 1.5 s of no input)

Every isolated step gives the same fraction of the step per 60 Hz frame,
independent of size (5°, 30°) and of rotation versus translation (0.3 m
in x: the same fractions):

| Frame after the first changed one | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|---|---|
| Fraction of the step | 0.274 | 0.548 | 0.822 | 0.871 | 0.919 | 0.968 | 0.977 | 0.985 | 0.994 | 0.996 |

i.e. three-frame linear segments whose end points close 82.2 % of the
remaining error each (0.822, 0.968, 0.994, …: the error shrinks by 0.178
per 50 ms). Measured from the send (27 isolated 30° steps, both
directions, 13 boots and runs, 60 Hz, 3840 × 2160 and 2160 × 3840; one
step of the 7680 × 2160 run is left out because its row match failed):

| | min | mean | max |
|---|---|---|---|
| First changed frame | 53 ms | 62 ms | 75 ms |
| 50 % | 69 ms | 79 ms | 91 ms |
| 90 % | 119 ms | 128 ms | 141 ms |
| Within 0.1° of 30° | 219 ms | 229 ms | 241 ms |

The first changed frame is the pipeline (send → backboardd renders →
wakeboardd composites → swap: 3–4 frames); the smoothing itself takes
about 50 ms to 82 %, 100 ms to 97 % and 170 ms to 99.7 % after that.

### Continuous motion

A 1 Hz sine of ±15° yaw: best fit picture(t) = g · command(t − L):
L = 98 ms, g = 0.958 (75.6 poses/s) and L = 100 ms, g = 0.946
(27.0 poses/s). A 30° ramp over 0.5 s at ~75/s trails the command by about
100 ms and arrives ~100 ms after the last pose. **The send rate (27 vs 76
per second) does not change the delay.**

### Repeats, pairs, pre-compensation (the filter is not linear time-invariant)

- The same target repeated at 90 Hz or 30 Hz for 600 ms converges
  **slower** than one event (90 %: 160–180 ms; within 0.1°: 300–390 ms),
  identically whatever the timestamps (scaled 0.1 or 3).
- A second pose 16 ms after the first replaces it: the trajectory is that
  of the second alone. Second poses 33–150 ms later change the trajectory
  from the next three-frame segment on.
- Sending an overshoot (36.5° = 30/0.822) and the target 50 ms later puts
  the picture on 30° within two frames of the correction, but it then
  falls back to 24.7° and re-converges as an ordinary step (within 0.1° at
  217 ms): no net gain and a visible bounce. 16 ms later: no gain.

### What does not change it

| Input | Result |
|---|---|
| wakeboardd `hmd.compositor.fps` 30 | presented every 33 ms; the frames show every second value of the 60 Hz trajectory (16.44, 26.12, 29.04, …): the smoothing runs on time, not on presented frames; first change 113 ms; sine delay 136 ms |
| test device type with a 30 Hz display | the same: every second value; first change 159 ms |
| backboardd `SimulatedHeadset` YES (three domains) | unchanged |
| `enableHeadPoseLateLatching` NO (`com.apple.backboardd`, `com.apple.re`, also prefixed) | trajectory unchanged; first change 70 and 82 ms (two boots; normal 53–68 ms): possibly one frame later; whether backboardd read the key was not recorded |
| `useLegacyHeadPoseLateLatching` YES | unchanged |
| wakeboardd `hmd.pov.time-warp.enabled` NO | unchanged |
| parent flags 0 or 3, children flags 1 (rewritten before dispatch) | unchanged |
| timestamps (above) | unchanged |
| send rate 27–90 Hz | steady delay unchanged; repeats slow a step down |

The wakeboardd layer record (`wakeboardctl status`) carries a layer pose
of type "invalid" (identity) for backboardd's layers: the camera motion is
rendered by backboardd, not re-projected by wakeboardd.

### Where (level 4 names only, not confirmed)

RealitySimulation's strings speak of getting "a head pose for time %f"
for a compositor-predicted time and of falling back to the last pose;
RealitySystemSupport has an `InputPoseProvider` type. No preference key
read by backboardd (≈1 640 distinct, from OBS-VISION-STEREO's log) names
a camera/head-pose smoothing, filter or prediction time; the period /
interpolation strings found belong to pointer and scroll input. The
filter's location was not pinned down; no level 5 was used.

## Field of view (Q1)

### What decides it: the display size

| Display (device type) | wakeboardd Left tangents | Projection y scale | FOV (h × v) | StereoProbe (app) |
|---|---|---|---|---|
| 3840 × 2160 (4K type) | 1, 1, 0.5625, 0.5625 | 1.7778 | 90° × 58.7° | same tangents, viewport 3840 × 2160 |
| 3840 × 3840 (square) | 1, 1, 1, 1 | 1 | 90° × 90° | (did not launch on this boot) |
| 7680 × 2160 (wide) | 1, 1, 0.28125, 0.28125 | 3.5556 | 90° × 31.4° | same, viewport 7680 × 2160 |
| 2160 × 3840 (tall) | 1, 1, 1.7778, 1.7778 | 0.5625 | 90° × 121.3° | same, viewport 2160 × 3840 |
| 1024 × 8192 (extra tall) | 1, 1, 8, 8 | 0.125 | 90° × 165.8° | same, viewport 1024 × 8192 |

Rule: the horizontal tangents are always 1 (90°); the vertical tangent is
height / width. The layer textures, the swapchain and the presented
surface take the display's size. Screenshots: the room renders with a
correct pinhole projection at every size (no stretch, no crop; straight
lines straight); the home view keeps its size relative to the width.
Apps' CompositorLayers receive the same tangents and a viewport of the
display's size. The step response was the same at 2160 × 3840 and
1024 × 8192 (first change 63 and 82 ms; same fractions). StereoProbe
logged only its first four frames on these boots and its immersive space
showed black behind the window (on the 4K type earlier it showed its red
clear); the tangents it was given are what matters here.

### Preferences tried

One boot each on the 4K type; tangents from `wakeboardctl status`;
screenshots compared with the baseline's (mean absolute difference over
a 960 × 540 copy: 0.0 for every run):

| Key (domain) | Value | Result |
|---|---|---|
| `CameraScale` (`com.apple.backboardd`, `com.apple.RealitySimulation`, `com.apple.dmm`) | 2.0 | no change |
| `hmd.mesh.override-rectilinear-fov` (wakeboardd) | 120.0 (a number) | wakeboardd aborts at start in a loop (crash reports: an Objective-C exception while reading preferences, in a reader of four-float values); boot stalls "Waiting on BackBoard" |
| same | (2, 2, 1, 1); (60, 60, 45, 45) (arrays) | boots; no change |
| `hmd.cvcalibration.field-of-view-degree-delta` | 30.0 (with three others) | the same abort loop |
| same | (30, 30, 30, 30) | boots; no change |
| `hmd.input.remote-compositor-extended-fov-delta` 0.5, `hmd.display-tap.extra-rendered-fov` 3.0, `hmd.cvcalibration.use-nominal-mcam-fov` YES | together | no change |

The keys were picked from the ~500 wakeboardd reads and ~1 640
backboardd reads recorded by OBS-VISION-STEREO (names containing fov,
field, tangent, camera, projection). backboardd's `Fov*AngleThresholdDegrees`
(80/45, extended 110/65) and `FovMinimumDistance` belong to window
placement.

### Can the horizontal FOV exceed 90°?

No input found does it: the display's width always maps to tangent 1,
the preferences above change nothing, vhmdd has no such command
(OBS-VISION-STEREO). A viewer that wants more than 90° horizontally must
assemble it from pictures at several camera yaws, paying a settle (~230
ms to 0.1°) per turn.

## Cleanup

`ycode-test-vision7-a`, `-sq`, `-wide`, `-tall`, `-hz30`, `-xtall` were
deleted; the five test device types were removed from
`~/Library/Developer/CoreSimulator/Profiles/DeviceTypes/`;
`device_set.plist` compared before and after. CoreSimulator had also
created, by itself, a default device of each test type on visionOS 26.4,
26.5 and 27.2 (15 devices named "ycode-test-vision7 <type>", because the
copied profile kept `createByDefaultForRuntimeVersions`; `mktype.py` now
drops that key); all 15 were deleted. `device_set.plist` still holds 15
`DefaultDevices` records (test type → deleted device) written by
CoreSimulator; everything else in it is unchanged. The file belongs to the
running CoreSimulator service and was not edited by hand. The owner's simulators and
other agents' devices were not touched. One slip: the square-type device
was left booted for about 25 minutes after its run, overlapping the
wide, tall, 30 Hz and two 4K boots (two of our devices booted at once);
it was shut down when noticed. The step results of those runs match the
others.

## Evidence levels

3 for all behaviour (timings, tangents, screenshots, crash at start);
2 for the device-type profiles; 4 for the printable strings of four shared
cache images (RealitySimulation, RealitySimulationServices,
RealitySystemSupport, PalomaSimService) and the function names in
wakeboardd's crash reports. No level 5.
