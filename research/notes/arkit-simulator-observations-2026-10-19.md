# ARKit in the reference iOS Simulator: observations (2026-10-19)

Dirty-room notes by KIT-ARKIT, the source for
`specs/frameworks/arkit/simulator-baseline.md`. Prose only; raw probe logs
and screenshots stay in `research/dirty/arkit/` (not committed). Apple's
localized error strings are paraphrased, not quoted.

## 1. Setup

- Xcode 27.1 (27A9269), iOS 27.1 simulator runtime (24A94401), ARKit bundle
  version 781.0.7.
- Device: `ycode-test-arkit-1`, device type iPhone Duo (iPhone 18 Pro was
  refused by the 27.1 runtime as incompatible). Created, used and deleted in
  this session. The device type has two displays; screenshots must name
  `--display=LCD` or they capture the second, black display.
- Probe: `research/experiments/arkit/ARProbe` (our Objective-C app, built with
  `xcrun clang` against the simulator SDK, ad-hoc signed). Three Info.plist
  variants: with `NSCameraUsageDescription`; without it; with it plus
  `UIRequiredDeviceCapabilities = [arkit]`. Launch arguments select the probe
  set (`-probe all|consts|none`) and the view left on screen
  (`-ui none|scn|sk|coach|coachscn`).
- `simctl launch --stderr=PATH` resolves PATH inside the guest: `/tmp/X`
  appears at `<device>/data/tmp/X` on the Mac. `run.sh` relies on this.
- Other agents were using CoreSimulator heavily at the same time; `simctl`
  commands (install, terminate) sometimes took minutes. Nothing in the
  results depends on timing except where stated.

## 2. Capability and configuration results

Every configuration class answered "not supported" to every query, had no
video formats, and gave nil for the capture device and recommended formats.
The only positive answer anywhere: plane classification is reported as
supported. Geo availability checks returned "not available" with no error,
synchronously, on the main thread (the documentation promises an arbitrary
serial queue; the simulator just calls back inline).

Configuration objects: all properties read zero on a fresh object, against the
documented defaults; writes are stored and read back, except App Clip Code
tracking on the world-tracking class, which stays off; `copy` returns a fresh
object without the written values. No setter throws. Descriptions show only
class and address.

## 3. Sessions

Run returns normally; the failure callback arrives afterwards with the ARKit
error domain, code 100, and two user-info keys (localized description: a
short "unsupported configuration" title; localized failure reason: one
sentence saying the configuration is not supported on this device). On a
private serial delegate queue the callback ran right away (same millisecond
as the run call returned); on the main queue it ran about 110 ms later, after
the app's scene connected, i.e. on a later main-loop turn. A second run on the
same session (from a main-queue block) failed the same way.

Nothing else is ever called: no tracking-state change, no frames, no anchors.
The four asynchronous session requests (current world map, create reference
object, geo location for point, high-resolution frame) never called their
completion handlers; the process was left running for more than two minutes
after the requests. Anchor add/remove, world-origin change and pause are
silent no-ops. Raycast gives an empty list; a tracked raycast gives nil.

Identifiers: each new session has a UUID; it did not change on run. The view
rotation angle reads NaN.

## 4. Data objects

Plain anchors are complete (storage, copy, equality, secure coding).
Environment-probe anchors store their extent (infinite by default). Geo anchors
and app-created raycast queries ignore their arguments and read zero. A
neutral face geometry is an empty mesh. The 2D skeleton definition is complete
(19 joints; list in `specs/frameworks/arkit/anchors.md` §6); the 3D one is
empty. The matte generator and SceneKit plane geometry are created; SceneKit
face geometry is not.

Reference images keep their physical size. Validation always fails with code
100 after roughly 1.2–1.5 s, on the main queue, even for a uniform gray image.
The first reference image creation took several seconds in the first run
(0.5 s in the second), so it is probably one-time framework or catalog
loading; the unified log shows the framework trying to open an asset catalog
named "Assets" in the app bundle around that time. Reference objects from a
bogus or a missing file come back nil without an error. World-map unarchiving
of garbage gives the standard Cocoa "wrong format" error (4864).

Camera: no capture device, authorization not determined, no prompt. The
unified log shows AVFoundation's simulator capture-source component reporting
errors when the probe asked for the default video device; i.e. the reference
simulator has a capture-source stand-in for AVFoundation, with no device
behind it.

## 5. Views

The SceneKit AR view and the SpriteKit AR view both have a nil session, so
calls through it do nothing and the view delegates never hear of a failure.
The SceneKit view's AR-specific flags read off, and it renders like a plain
SceneKit view: SceneKit added its default camera (positioned to frame the
content), the red test box filled the screen, statistics showed 0 fps, the AR
debug options drew nothing, and a raycast query from a view point was nil.
The SpriteKit view showed its scene's default dark gray background. The
coaching overlay defaults to goal "tracking", automatic activation off,
inactive; forcing it active did not change its state or draw anything, both
with a stand-alone session and with the SceneKit view's (nil) session.

## 6. Constants and archive layout

- Domain string and legacy reference-object extension: see
  `specs/frameworks/arkit/anchors.md` §8.
- SceneKit debug option values: feature points 1 << 30; world origin bit 31,
  sign-extended to 64 bits.
- Blend-shape and joint-name strings: `anchors.md` §8.
- Anchor archive: keys identifier (UUID object), name (absent when unnamed),
  transform and referenceTransform (64 bytes each, 16 floats column-major —
  checked with a 90° z-rotation plus translation (0.1, 0.2, −0.5): bytes held
  0 1 0 0 / −1 0 0 0 / 0 0 1 0 / 0.1 0.2 −0.5 1), lastUpdateTimestamp (0),
  isHiddenFromPublicDelegate (0); class chain ARAnchor → NSObject.

## 7. Install-time behavior

The app variant requiring the `arkit` capability installed and ran like the
others. The device type's `capabilities.plist` contains no `arkit` key and no
camera keys. The variant without a camera usage string behaved identically to
the one with it (no crash, no prompt, same errors).

## 8. Runtime bundle structure (file list only)

The simulator runtime has `ARKit.framework` (Info.plist, code signature, a
Metal library; code in the shared cache) and
`SubFrameworks/ARKitCore.framework` holding only `Localizable.strings` for 57
localizations. The device SDK's `.tbd` shows ARKit re-exporting three
sub-frameworks (Core, Foundation, UI); the simulator SDK's `.tbd` has no
re-exports. The strings files were not opened.

## Method limits

No disassembly or decompilation. The reference tools folder, Ghidra and the
IPSW were not used. No device hardware was available, so device behavior in
the spec comes from documentation (level 1) and is flagged where unverified.
