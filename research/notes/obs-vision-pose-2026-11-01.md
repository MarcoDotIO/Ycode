# OBS-VISION-POSE: the pose's rotation (2026-11-01)

Dirty-room observation for XR-VIEWER (Quest Pro viewer of Ycode's visionOS
simulator): under Ycode the view follows the PalomaPose translation but not
its rotation at the plain home view. Result: the reference turns the view;
Ycode's Orientation child is built with the wrong constructor, so it is a
type-0 event with no quaternion. Spec: `specs/simulator/visionos.md` §5.5.2
(corrected) and §5.5.10.

## Setup

- Device `ycode-test-vision6-pose`, Apple Vision Pro 4K, visionOS 27.2
  (24N120). visionOS 27.0 creation failed ("runtime path not found").
  Deleted at the end. Room: Living Room (Day), the default.
- Tools (sources in `research/experiments/visionos/input/`):
  - `vhid pose 300 tx ty tz qx qy qz qw` (unchanged).
  - `hidrec2.dylib` (new): hidrec plus, for the event and every child,
    type, event flags and the float/integer value of each field
    `(type << 16) | 0..15`; optional `HIDREC_REWRITE=1` rebuilds a pose
    event's Orientation child the way Ycode's bundle does before dispatch.
  - `oprobe` (new, guest command line): builds Orientation events several
    ways and reads the fields back.
  - `vhm` for vhmdd `get_pose`/`set_pose`; `CrownProbe.app` for a window
    and mixed / progressive / full spaces (launch arguments).
- Practical: a recorder log path on the USB volume produced no log; a
  folder in the device's data directory worked (`data/tmp` is cleared at
  boot, so not there). Overwriting a loaded dylib in place and booting
  again did not load it; build to a new file.

## Runs

| Run | Recorder | What | Result |
|---|---|---|---|
| r5 | record only | home view: identity, yaw +30°, pitch +20°, yaw −30°, identity | every rotation changed the frame; +yaw turned left, +pitch looked up; the home view stays in the room |
| r6 | `HIDREC_REWRITE=1` (Ycode-style child) | home view: identity, yaw +30°, pitch +20° | all three frames byte-identical to the boot frame |
| r6 | same | mixed space (CrownProbe `-mixed`): identity, yaw +30°, then `set_pose` yaw +30°, then `set_pose` identity | window and cube stayed centred throughout |
| r7 | record only | window (CrownProbe, no space), mixed, progressive, full: identity, yaw +30°, pitch +20° | the view turned in every case; vhmdd `get_pose` = identity at the end (never set in this boot) |

## Recorded event (r5, r7; yaw +30°, pitch +20°)

Parent VendorDefined, flags 0x1, page 0xFF00, usage 0x72, version 13, data
length 0. Children: Translation (flags 0; fields 0–2 = x, y, z), then
Orientation (flags 0; field 3 = 3; field 8 = w, 9 = x, 10 = y, 11 = z).
Yaw +30°: w 0.965912, y 0.258804. Pitch +20°: w 0.984802, x 0.173645
(16.16 fixed point). No other Orientation field non-zero.

## Construction (oprobe)

- Generic create of type 10, then integer field 3 = 3 and floats 8–11 (in
  either order, or field 3 as a float): every field reads 0, description
  "Orientation type: 0".
- `IOHIDEventCreateQuaternionOrientationEvent(alloc, ts, w, x, y, z, 0)`:
  field 3 = 3, fields 8–11 = w, x, y, z; calling it with x, y, z, w puts
  them in 8–11 in that order (so the arguments are w, x, y, z). After it,
  setting field 9 works.
- Present by name: `IOHIDEventCreateOrientationEvent`,
  `…PolarOrientationEvent`, `…QuaternionOrientationEvent`,
  `…DeviceOrientationEventWithUsage`. Absent: `…OrientationEventWithQuaternion`,
  `…TiltOrientationEvent`, `…EulerOrientationEvent`.

## Ycode

`simhid.c` `quaternion_event` uses the generic constructor and setters
(fields 3 and 8–11; numbers right), so its pose and hand Orientation
children are type 0 and empty. Fix: use the quaternion constructor (§5.5.10
"What Ycode must do"). Not explained here: R9 saw the view turn in a mixed
space under Ycode (§10.25.1); in the reference a Ycode-style child did not
turn it there.

## Evidence levels

3 for all behaviour and field values; 4 for constructor names (dlsym).
No level 5, no disassembly, nothing decrypted, no GUI clicks.
