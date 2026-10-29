# OBS-CAMERA: how the reference simulator handles cameras (dirty-room notes, 2026-10-27)

Agent OBS-CAMERA. Observation only. The boundary spec is
`specs/simulator/camera.md`. The tools, probe apps, recorder logs and
screenshots are in `research/dirty/obs-camera/` (git-ignored).

## Setup

- Xcode 27.1 (27A9269) tools on the Mac. The Simulator app is now
  `Contents/Applications/DeviceHub.app` (bundle ID `com.apple.dt.Devices`).
- `ycode-test-camera-1`: iPhone Duo, iOS 27.1 (24A94401), product class
  V68, model iPhone19,4. iOS 27.1 accepts only the iPhone Duo device type:
  `simctl create` refused iPhone 17 Pro and iPhone 18 Pro with "Incompatible
  device" (403).
- `ycode-test-camera-2`: iPhone 17 Pro, iOS 27.0 (24A434), product class
  V53, used for a comparison run.
- Both devices were deleted at the end. No other simulator was touched. The
  Mac was very busy (load average 200 to 370 from other agents' devices). The
  first boot of device 1 timed out, and the second boot took about 10 minutes
  of data migration.
- Boot `b1` ran our recorder `camrec` in every guest process
  (`SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`). The recorder logged look-ups, XPC
  connections and messages on camera, media and TCC names, `mach_msg` IDs to
  those ports, MobileGestalt questions, IOKit matching, and (on request)
  file-system calls, `getenv`, CFPreferences reads and `dlopen`.
- The probe app `camprobe` used only public AVFoundation, UIKit and CoreMedia
  API, plus MobileGestalt reads for the key dump. It was installed twice:
  `dev.ycode.obscamera.usage` has `NSCameraUsageDescription` and
  `NSMicrophoneUsageDescription`, and `dev.ycode.obscamera.nousage` has
  neither. `cammeta` listed ObjC class names per image (binary metadata).
- On iOS 27 an app with no scene manifest crashes when its scene is created
  (UIKit's "no scene lifecycle adoption" check). The probe therefore needs a
  `UIApplicationSceneManifest`.
- When `simctl launch` passes a `SIMCTL_CHILD_` variable that the boot
  environment already sets (for example `CR_DIR`), the boot value wins.
  Variables that the boot did not set do reach the app.
- An earlier build of the recorder hooked `getenv` and touched thread-local
  storage before libSystem had started. Every new process on the device
  crashed in `xpcproxy_sim` until the hook was rebuilt. The rebuilt hooks are
  marked noinline and check a volatile ready flag first.

## Runs

| Run | What | Result |
|---|---|---|
| d1, d2 | discover (d2 also recorded files, environment and preferences) | no video device; one placeholder video device object; microphone found |
| s1, s2-granted | session with no input plus video data, photo and movie outputs | runtime error -11800 (underlying -12782); "running" after a 9 s time-out; 0 frames; -11819 on stop |
| pc-base, pc-D93, pc-V53, pc-N104, pc-J821, pc-D93e | `SIMULATOR_PRODUCT_CLASS` changed in the app before the capture stack reads it | no change |
| caps-A, caps-B | `SIMULATOR_CAPABILITIES` pointed at a copy of the plist with `still-camera` and `front-facing-camera` false (A), or with all six camera keys true (B) | MobileGestalt answers follow the plist; image-picker camera availability follows `still-camera`; AVFoundation discovery does not change |
| st-granted, st-denied, rq-granted, rq-denied | status and request after `simctl privacy grant` or `revoke camera` | authorized or denied, answered without a prompt |
| rq-nousage | request after reset, with no usage string | tccd refuses; the app aborts (crash report) |
| rq-prompt | request after reset, with a usage string | system alert "Allow … to access your camera?" with the usage string; `simctl privacy grant` while the alert is up terminates the app |
| picker | `UIImagePickerController` with the camera source | camera UI with a grey preview, shutter, "PHOTO" and a flip button; the same capture errors; CAMCaptureEngine retries the session |
| ph | input from the placeholder device | `AVCaptureDeviceInput` is created with no error, with a nil ID |
| i270-d, i270-s | iOS 27.0, iPhone 17 Pro | the same as iOS 27.1 |

## Findings

1. **No camera.** `defaultDeviceWithMediaType:video`, every
   `defaultDeviceWithDeviceType:` (wide, ultra wide, telephoto, dual, dual
   wide, triple, TrueDepth, LiDAR, continuity, external; any position) and a
   discovery session for video all return nil or empty. The only device is the
   microphone (`AVCaptureFigAudioDevice`, nil unique ID and name,
   manufacturer "Apple, Inc", 0 formats). `multiCamSupported` is YES.
   `systemPreferredCamera` and `userPreferredCamera` return a placeholder
   video device. It has a nil unique ID, name and device type, position 0, 0
   formats and `hasMediaType:video` YES. The log reads "returning backup
   preferred camera" and "_registerVideoDevicesOnce: Did not find front wide
   camera".
2. **The decision is made inside the app process.** While devices were
   discovered and while a session ran, the app looked up no capture,
   media-server or CoreMediaIO name. It made only these connections:
   `com.apple.tccd` (camera and microphone pre-flights) and, for the
   microphone, `com.apple.audio.audiohald` with an IOKit notification on
   IOResources. No guest process in the boot (1209 process logs) looked up a
   capture-related name. The runtime has no `mediaserverd`, `cameracaptured`
   or `appleh1xcamerad` job, and the only capture-like files are
   ImageCaptureCore's `mscamerad-xpc` and a lifecycle-policy file
   `com.apple.cameracapture`.
3. **Errors in the log.** The `com.apple.cameracapture` subsystem logs
   "FigCaptureSourceSimulator signalled err=-12784" every time discovery runs.
   CoreMedia then logs "FormatDescription signalled err=-12710". When a session
   receives a configuration, "FigCaptureSessionSimulator signalled
   err=-12782" is logged. `startRunning` waits about 9 s ("Timed out waiting
   for session to start"), then posts DidStartRunning, and `running` becomes
   YES. Stopping times out after about 9 s and posts runtime error -11819
   followed by DidStopRunning.
4. **Inputs read by the capture stack.** In the discovery window the only
   environment variable read by CMCapture is `SIMULATOR_PRODUCT_CLASS`. The
   only preference reads are trace and effects keys in
   `com.apple.avfoundation`. The only file opens are AVFCore and AVFCapture
   bundle Info.plists and logging plists. There were no look-ups. Changing the
   product class changed nothing.
5. **Binary metadata (level 4).** The simulator build of CMCapture has 100
   ObjC classes: configuration objects (FigCaptureSessionConfiguration, sink
   and connection configurations, source formats and attributes,
   FigCaptureSourceManager), settings, statistics helpers and an empty graph
   framework (EG*). It has none of the capture-pipeline node or device
   classes. CMCaptureCore and CMCaptureDevice have no ObjC classes. No class
   name contains "Sim". The simulator source and session appear to be C
   objects (named only in log lines).
6. **MobileGestalt.** The simulator answers camera keys from the device
   type's `capabilities.plist` and falls back to built-in defaults when a key
   is absent. With the plist unchanged, `still-camera`,
   `front-facing-camera` and `auto-focus-camera` are 1, `video-camera`
   and `camera-flash` are 0, and `rear-facing-camera` and the HFR keys have
   no answer. The log has "Property isp[camera-front] found". UIKit's
   image-picker camera availability follows `still-camera`. Its media types
   are image only, and rear/front availability stays 0 even when the plist
   says true. AVFoundation does not use these keys.
7. **Permission.** The pre-flight and request go to `com.apple.tccd`
   (function `TCCAccessRequest`, service `kTCCServiceCamera`). With no record
   and a usage string, tccd shows the alert through CFUserNotification (it
   looks up `com.apple.SBUserNotification`). With no usage string, tccd logs
   "No usage string found (key:NSCameraUsageDescription)" and replies with
   `abort` and `problem_key`, and the app aborts. `simctl privacy grant
   camera <bundle>` works, although the help text does not list "camera". An
   unknown service name fails with EPERM ("Failed to create TCC authorization
   record"). CoreSimulatorBridge sends `TCCAccessSetInternal` with
   `auth_value` 2 (grant) or 0 (revoke) and `client_type` "bundle". The row
   is written to `data/Library/TCC/TCC.db` with auth_reason 4 and version 1.
   tccd terminates the running app (exit reason namespace TCC, "Access to
   service kTCCServiceCamera changed") and posts
   `com.apple.TCC.kTCCServiceCamera.authorization.changed`. After the app was
   terminated, the alert of its pending request stayed on screen. tccd logs
   "service not protected: kTCCServiceCamera" in this path.
8. **Host side.** CoreSimulator registers
   `com.apple.CoreSimulator.SimCaptureService` in the guest. Only the host's
   `SimRenderServer` (rendering bundle) names it, and no guest process looked
   it up during the boot or any camera run. It is display capture, not a
   camera. DeviceHub and CoreSimulatorService have no camera usage string or
   camera entitlement. The Mac's own tccd logged no `kTCCServiceCamera` event
   in the 100 minutes of the observation, so the Mac's camera was never used.
9. **iOS 27.0** behaves the same (discovery, MobileGestalt defaults,
   session errors).

## Why disassembly was not used

The question was where discovery comes up empty and from which input.
Black-box variation of every input the stack was seen to read (product
class, capabilities keys, environment, preferences, files, services), plus
class metadata showing that the simulator build has no capture pipeline,
answered it without disassembly. Disassembly could only show how the
simulator source fails internally, which Ycode does not need: there is no
input to supply, so Ycode cannot make Apple's stack produce a device. It
must add its own layer (spec §7).

## Open items

- Whether the microphone capture path (audio device, audiohald input) works
  in the reference. It was not run, to avoid starting the Mac's microphone.
- Whether the placeholder device can start a session that delivers anything.
  It was not tried with an input added and the session started. Expected: the
  same -12782.
- Which process draws the permission alert (SpringBoard serves
  `com.apple.SBUserNotification`; not confirmed separately).
