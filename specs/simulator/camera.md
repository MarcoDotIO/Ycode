# Spec: cameras in the simulator guest

Status: **reference** (agent OBS-CAMERA, 2026-10-27); **Ycode's camera
extension implemented** (§9, agent CAMERA-GUEST, 2026-10-27/28). This spec records how
the iOS 27.1 (24A94401) and iOS 27.0 (24A434) simulator runtimes of Xcode
27.1 handle cameras: what a guest app sees, which guest parts take part,
which endpoints they use, how permission works, and where discovery comes up
empty. It then states what Ycode must do. There are two cases: plain parity
(no camera) and the planned extension, a USB webcam on the Linux host shown
to the guest as a camera.

Every behavioral fact comes from black-box runs on a Mac (level 3). The tools
were a recorder of our own inserted into every guest process (look-ups, XPC
connections and messages, Mach message IDs, MobileGestalt questions, IOKit
matching, file-system calls, `getenv`, preference reads, `dlopen`), a probe
app of our own that calls public AVFoundation, UIKit and CoreMedia API in
the guest, the guest's unified log, `simctl`, and the device's TCC database
read with `sqlite3`. Bundle and class inventories are level 2 and 4. No
disassembly was used. Notes: `research/notes/obs-camera-2026-10-27.md`.

Terms are those of `networking.md`. **Host**: the machine the simulator runs
on. **Guest**: processes of the simulated device. **Host-side endpoint**: a
Mach name registered by the host into the guest's bootstrap
(`launchd-sim.md` §6.3).

## 1. Answers in brief

1. **The reference simulator has no camera.** It exposes no capture device
   for video: no front, back or external camera, no Mac camera, and no
   virtual camera. The only capture device is the microphone. A capture
   session never delivers a frame. iOS 27.0 behaves the same as iOS 27.1.
2. **Nothing outside the app process takes part.** The simulator builds of
   the capture frameworks decide inside the app process that there are no
   devices. No capture daemon exists in the runtime, and no capture service,
   guest-side or host-side, is looked up. The only endpoints used are the
   guest's `com.apple.tccd` (permission) and, for the microphone,
   `com.apple.audio.audiohald` (`audio-host.md`).
3. **No input switches a camera on.** The product class, the
   capabilities-plist camera keys, the environment, preferences and files
   were varied or recorded, and none of them changes discovery. The
   simulator's capture library contains no capture pipeline. To give the
   guest a camera, Ycode must therefore add its own capture layer (§7.2). It
   cannot feed Apple's.
4. **Permission works as on a device**, through the guest's `tccd`: the
   usage-string check, the system alert, `simctl privacy grant|revoke|reset
   camera`, and termination of the app when its access changes. This works
   even though no camera exists.

## 2. What an app sees (reference)

### 2.1 Discovery

| Call (public API) | Result |
|---|---|
| default device for media type video | nil |
| default device for media type audio | one microphone device: device type microphone, position unspecified, unique ID nil, localized name nil, manufacturer "Apple, Inc", connected, not suspended, 0 formats |
| default device for muxed or depth-data media | nil |
| default device for each device type (built-in wide angle, ultra wide, telephoto, dual, dual wide, triple, TrueDepth, LiDAR depth, continuity, external) at each position (unspecified, back, front) | nil |
| discovery session over all those types plus microphone, any media, any position | 1 device (the microphone) |
| discovery session for video | 0 devices, 0 supported multi-cam sets |
| the deprecated device list | the microphone only |
| multi-cam session supported | YES |
| system preferred camera, user preferred camera | a **placeholder** video device (next table) |

The placeholder is the only video device object an app can get. Its unique
ID, name and model ID are nil. Its device type is unspecified and its
position is 0. It has 0 formats and no active format. It reports
`hasMediaType:video` YES and connected YES. An input made from it is created
without error. The log reports that no front wide camera was found and that
a backup preferred camera is returned. Discovery takes 6–35 ms.

### 2.2 Capture session

A session with no input and with a video data output, a photo output and a
movie file output:

1. All three outputs can be added. The video data output offers pixel
   formats `'420v'`, `'420f'` and `'BGRA'` (875704438, 875704422,
   1111970369), and its default settings are nil. Before an input exists, the
   session preset is High and High can be set.
2. Each configuration commit fails inside the process. AVFoundation posts a
   runtime-error notification with AVFoundation error **-11800** and an
   underlying OSStatus **-12782**.
3. `startRunning` blocks for about **9 s** and then logs a time-out waiting
   for the session to start. It posts did-start-running, and `running`
   becomes YES. The session is not interrupted. **No sample buffer arrives**
   (0 frames in 10 s).
4. `stopRunning` blocks for about 9 s, posts a runtime error **-11819**
   ("Cannot Complete Action", "Try again later."), then posts
   did-stop-running.

The access state makes no difference: the results are the same with
"not determined" and with "authorized".

### 2.3 Log signature

Each discovery logs, in the app's process (subsystem
`com.apple.cameracapture`), an error from the simulator capture source
(`-12784`), followed by a CoreMedia format-description error (`-12710`).
Each session configuration logs an error from the simulator capture session
(`-12782`). These are diagnostics only. No other process logs anything about
capture.

### 2.4 UIKit image picker

- "Is the camera source available" returns YES. Its media types are image
  only (`public.image`). Rear and front camera availability and rear flash
  availability are NO.
- Presenting the picker with the camera source does not throw. It shows the
  camera interface: a grey preview, a shutter button, the "PHOTO" mode label,
  a close button and a flip button. Inside the app it creates a capture
  session, gets the -11800/-12782 error, and retries the session (the log says
  it restarts the session to recover). The preview stays grey.
- Source availability follows the MobileGestalt answer `still-camera` (§4).
  With `still-camera` false, availability is NO and the media types are nil.
  Rear and front availability stay NO whatever the camera keys say.

## 3. Guest stack and endpoints

### 3.1 What exists

- The runtime has **no capture daemon**: no `mediaserverd`,
  `cameracaptured`, `appleh13camerad` or CoreMediaIO assistant job. The only
  capture-related launch files are ImageCaptureCore's `mscamerad-xpc`
  (an XPC service for external still cameras) and a RunningBoard
  lifecycle-policy domain file named `com.apple.cameracapture` (level 2).
- The capture frameworks are in the runtime's shared cache:
  `AVFoundation`, `AVFCapture`, `AVFCore`, `CMCapture`, `CMCaptureCore`,
  `CMCaptureDevice`, `Celestial`, `MediaExperience`, `CoreMedia`, `CameraUI`
  and `LockedCameraCapture`. CoreMediaIO has only its localization folders.
- The simulator build of `CMCapture` has 100 ObjC classes. They are session,
  connection, source and sink configuration objects, source formats and
  attributes, a source manager, settings, statistics helpers and an empty
  graph framework. It has **no capture-pipeline node or capture-device
  classes**. `CMCaptureCore` and `CMCaptureDevice` have none (level 4). The
  simulator capture source and session objects are named only in log lines.

### 3.2 Endpoints

| Endpoint | Kind | Who | Use |
|---|---|---|---|
| `com.apple.tccd` | guest-side XPC service | every app that asks for status or access | camera and microphone pre-flight and request (§6) |
| `com.apple.SBUserNotification` | guest-side Mach service (SpringBoard) | `tccd` | shows the permission alert |
| `com.apple.audio.audiohald` | host-side endpoint | the app, for the microphone device only | `audio-host.md` |
| `com.apple.CoreSimulator.SimCaptureService` | host-side endpoint (served by the host's rendering service) | **nobody** in a full boot (1209 guest process logs) or in any camera run | display capture, not a camera |

No guest process looked up any capture, media-server, CoreMediaIO or
continuity-camera name. No host endpoint is involved in camera behavior.

### 3.3 What the capture stack reads

In the discovery window, the only inputs the capture frameworks read were
these:

- the environment variable `SIMULATOR_PRODUCT_CLASS` (for example `V68`
  for iPhone Duo and `V53` for iPhone 17 Pro);
- preference keys of the domain `com.apple.avfoundation` for tracing and
  effects eligibility (all absent);
- the AVFCore and AVFCapture bundle `Info.plist` files and the unified-log
  configuration files.

Setting the product class to `D93`, `V53`, `N104` or `J821` in the app
before the capture stack read it changed nothing (§5).

## 4. Device answers (MobileGestalt)

The simulator answers MobileGestalt questions from the device type's
`capabilities.plist` (`device-capabilities.md`). When a key is absent it
falls back to built-in simulator defaults. Observed answers, the same on
iOS 27.0 (iPhone 17 Pro) and iOS 27.1 (iPhone Duo):

| Key | Answer with the device type's own plist (key absent) | Follows a plist entry? |
|---|---|---|
| `still-camera` | 1 | yes |
| `front-facing-camera` | 1 | yes |
| `auto-focus-camera` | 1 | yes |
| `video-camera` | 0 | yes |
| `camera-flash` | 0 | yes |
| `rear-facing-camera` | no answer | yes |
| `cameraRestriction` | 0 | not tested |
| `CameraButtonCapability`, `front-flash-capability`, `RearFacingCameraHFRCapability`, `FrontFacingCameraHFRCapability`, `DeviceSupportsCameraCaptureOnTouchDown` | no answer | not tested |
| `microphone` | 1 (in the plist) | yes |

These answers drive UIKit's image-picker source availability (§2.4) and
the Camera UI's own feature checks. They do **not** affect AVFoundation
discovery. Neither true nor false values brought a device into or out of
discovery.

## 5. Where discovery comes up empty

- **Who decides:** the simulator capture source inside the calling process
  (part of `CMCapture`, used through `AVFCapture`). The source fails
  (`-12784`) when the device list is built. AVFoundation then registers only
  the placeholder video device and the microphone.
- **From which input:** none that can be supplied from outside.
  The following were varied or recorded, and none changed the result:

| Input | Varied or recorded | Effect on discovery |
|---|---|---|
| `SIMULATOR_PRODUCT_CLASS` | V68, D93, V53, N104, J821 | none |
| Capabilities-plist camera keys (`SIMULATOR_CAPABILITIES`) | `still-camera` and `front-facing-camera` false; all six camera keys of §4 (`still-camera`, `video-camera`, `front-facing-camera`, `rear-facing-camera`, `camera-flash`, `auto-focus-camera`) true | none (UIKit availability changes only) |
| Host-side and guest-side services | all look-ups recorded | no capture look-up exists |
| Files | all opens, stats and directory reads recorded | none capture-specific |
| Preferences | all reads recorded | trace and effects keys only |
| Access state | not determined, authorized, denied | none |
| Runtime version | iOS 27.0 and iOS 27.1 | none |

- **Smallest input that would make a device appear:** there is none in the
  reference. The simulator build of the capture library has no capture
  pipeline to feed. A camera in the guest needs a capture layer that Ycode
  provides itself (§7.2).

## 6. Permission path

### 6.1 Status and request

- The usage key is `NSCameraUsageDescription` (Info.plist, public). The TCC
  service name is `kTCCServiceCamera` (the microphone's is
  `kTCCServiceMicrophone`).
- Asking for the status sends `TCCAccessRequest` to `com.apple.tccd` as a
  pre-flight. Discovery does this as well, once for the camera and once for
  the microphone. The reply has `auth_value`, `auth_reason`,
  `auth_version`, `prompt_type` and `preflight_unknown`. With no record the
  values are `auth_value` 1, `preflight_unknown` true, `prompt_type` 1, and
  the status is "not determined".
- A request (no pre-flight) with no record:
  - With a usage string, `tccd` presents the system alert through
    CFUserNotification (it looks up `com.apple.SBUserNotification`). The
    alert shows a camera glyph, the title "Allow "<app display name>" to
    access your camera?", the app's usage string, and the buttons Don't Allow
    and Allow.
  - Without a usage string, `tccd` refuses. It logs "No usage string found
    (key:NSCameraUsageDescription)" and replies with an `abort` text and
    `problem_key` = `NSCameraUsageDescription`. The app then aborts and
    leaves a crash report.
- With a record, a request completes immediately: granted YES and status
  "authorized", or granted NO and status "denied". No alert is shown and no
  usage string is needed, even for an app without one.

### 6.2 `simctl privacy`

- `simctl privacy <device> grant|revoke|reset camera <bundle ID>` works,
  although `camera` is not in the command's help list. An unknown service
  name fails with EPERM ("Failed to create TCC authorization record").
- The guest's CoreSimulatorBridge carries out the command. It sends
  `tccd` the function `TCCAccessSetInternal` with `service`
  `kTCCServiceCamera`, `client` = the bundle ID, `client_type` "bundle",
  `auth_value` 2 (grant) or 0 (revoke), and identity keys. `tccd` replies
  `result` true.
- The record goes into the device's `data/Library/TCC/TCC.db`, table
  `access`: service `kTCCServiceCamera`, client = the bundle ID,
  client_type 0, auth_value 2 or 0, auth_reason 4, auth_version 1.
- When an app's camera access changes, `tccd` terminates the app if it is
  running (exit reason namespace TCC, "Access to service kTCCServiceCamera
  changed"). It posts the notification
  `com.apple.TCC.kTCCServiceCamera.authorization.changed`. An alert the app
  had pending stayed on screen after the app was terminated.

## 7. What Ycode must do

### 7.1 Parity (no camera, as the reference)

Ycode runs the runtime's own frameworks in the guest, so parity mostly comes
from them:

1. Provide **no** capture service and no camera keys beyond those of the
   device type. Discovery then gives §2.1, sessions give §2.2, and the
   picker gives §2.4.
2. The permission path needs the guest's `tccd`, the device's
   `data/Library/TCC/` folder, and SpringBoard serving
   `com.apple.SBUserNotification` (for the alert). Ycode's equivalent of
   `simctl privacy … camera` must reach `tccd` as CoreSimulatorBridge does
   (§6.2). As a fallback while the device is shut down, it may write the
   row of §6.2 to the database. It must terminate the running app when the
   access changes.
3. Keep `SIMULATOR_PRODUCT_CLASS` set to the device type's product class
   (`V68` for iPhone Duo). The capture stack reads it.
4. Session timing: the 9 s start and stop time-outs of §2.2 come from the
   guest frameworks. They need a guest clock that advances and working
   condition waits. No host involvement is needed.

### 7.2 Extension: a host webcam as a guest camera

The reference gives no protocol to copy, so this is Ycode's own design. It
must stay faithful at the **public API surface**: everything an app can
observe through AVFoundation, CoreMedia, CoreVideo and UIKit should match
what the same app sees on a real device with one camera.

**A. Host side (Linux).**

1. A Ycode host camera service opens one USB webcam through the Linux video
   capture API (V4L2: query capabilities, list formats, frame sizes and frame
   intervals, set the format, memory-mapped buffers, stream on/off; level 1,
   Linux kernel documentation). It runs only when the user turns it on
   explicitly for that device. The host has no TCC, so Ycode's own opt-in is
   the host-side consent. Ycode should show that the camera is in use.
2. Convert each frame to one of the guest formats of §2.2: bi-planar 4:2:0
   video range `'420v'` (preferred: real devices default to it), bi-planar
   4:2:0 full range `'420f'`, or `'BGRA'`. Webcams usually deliver
   YUYV 4:2:2 or MJPEG. Conversion is Ycode's work.
3. Offer a small, fixed format list built from what the webcam really
   supports. Example: 640×480, 1280×720 and 1920×1080 at the rates the
   webcam reports (usually 30 fps, some 60).

**B. Transport to the guest.**

4. Register a Ycode-named host-side endpoint (for example
   `dev.ycode.camera`, not an Apple name) in the guest's `user/<uid>` domain,
   as for the other host services (`launchd-sim.md` §6.3).
5. Requests the endpoint must answer: list devices (ID, name, formats with
   size, pixel format and frame-rate ranges, position); open a device with a
   format; start; stop; close. It must also send connect and disconnect
   events for hot-plug.
6. Frames: a ring of guest-visible buffers. The best choice is IOSurfaces
   created through Ycode's IOSurface service (`iosurface-remote.md`), so the
   guest can wrap them as pixel buffers with the public CoreVideo API. A
   shared memory region holding the planes is the alternative. For each
   frame, send the buffer index, a sequence number and a presentation time in
   **guest host-time units** (the guest's `mach_absolute_time` clock, which
   CoreMedia's host clock uses). Frames are paced by the webcam, not by the
   guest.
7. Back-pressure: if the guest has not returned a buffer, drop the newest
   frame on the host. The guest output then sees no frame. Real devices
   report dropped frames to the video data output's drop callback, and
   Ycode should do the same.

**C. Guest side (the capture layer).**

8. The runtime's capture library cannot be fed (§5). Ycode therefore
   provides a **guest capture layer** written from this spec and public
   documentation only. It must not use Apple-private classes or their
   internals, and it must not be written from any disassembly. It is loaded
   into app processes when the camera extension is on. When the extension is
   off, apps see the reference behavior (§7.1).
9. Observable behavior the layer must give, with level-1 semantics from the
   public AVFoundation documentation:
   - Discovery: one video device. On iPhone device types, the default device
     type is built-in wide angle, position back. It can optionally also be
     listed as front, as configured by the user, because iPhone has no
     external-camera type. On iPad device types, an external device type
     (position unspecified) is the faithful choice. It must have a stable
     unique ID, a localized name, a model ID, manufacturer, connected YES,
     and the format list from step 3. The default device for video and the
     system and user preferred cameras return it. The microphone stays as in
     the reference.
   - Inputs: when the app is not authorized, creating a device input fails
     with the public AVFoundation "application is not authorized to use
     device" error. Authorization comes from the guest's `tccd` exactly as in
     §6, so the alert, usage-string abort, `simctl`-style grants and
     termination all keep working unchanged.
   - Sessions: `startRunning` returns once the host stream has started (no
     9 s time-out), posts did-start-running, and delivers sample buffers to
     video data outputs on the app's queue. Each buffer has a pixel buffer
     backed by the shared buffer, a presentation time on the host-time clock,
     the format description of the active format, and the output's requested
     pixel format (`'420v'` by default) and orientation. Stopping posts
     did-stop-running without an error. Interruption and runtime errors map
     to host events: device unplugged → runtime error and device
     disconnected notification; another guest app takes the camera →
     interruption.
   - Photo output: a capture returns a still from the next frame, encoded
     (HEIC or JPEG per the requested settings) with public ImageIO.
   - Movie file output: frames encoded with public VideoToolbox/AVAssetWriter
     in the guest.
   - The image picker then works (source available, rear availability YES
     for the back position), because it uses the same public discovery and
     session API. The capabilities answers should then match a device with a
     back camera: add `rear-facing-camera` and `video-camera` true to the
     device's capabilities plist when the extension is on, and leave
     `camera-flash` false (a webcam has no flash).
10. Only one guest process may hold the camera at a time. A second process
    starting a session interrupts the first, as on a device.

**D. Tests (black-box, against §2 and §6).**

11. With the extension off: the discovery and session results of §2.1–§2.2,
    including the placeholder device and the 9 s time-out.
12. With it on: one device with the configured formats; frames at the
    webcam's rate with increasing presentation times; `'420v'`, `'420f'` and
    `'BGRA'` each produce correct planes; the not-authorized input error; a
    grant through the Ycode tool terminates a running app; unplugging gives a
    disconnect notification.

## 8. Open questions

1. Whether the microphone capture path delivers audio in the reference
   (through `audiohald` input). It was not run, to avoid starting the Mac's
   microphone. If it does, `audio-host.md` needs input streams.
2. A session that has the placeholder device as input was not started.
   Expected: the same -12782 failure.
3. The process that draws the permission alert was not confirmed separately.
   `tccd` looks up `com.apple.SBUserNotification`, which SpringBoard serves.
4. Whether the guest capture layer (§7.2 C) should replace behavior at
   process start or only in apps that link AVFoundation. This is a design
   choice for the clean room.

## 9. Ycode implementation (agent CAMERA-GUEST, 2026-10-27)

Clean room: written from §1–§8 above, `camera-host.md`, `iosurface-remote.md`,
`audio-host.md`, Apple's public AVFoundation, CoreMedia, CoreVideo,
IOSurface, QuartzCore and ImageIO documentation and SDK headers (class
names, selectors, constants, error codes), and the public Objective-C
runtime and dyld documentation. No Apple simulator, Xcode or reference
tool was run, and no guest binary was disassembled. Everything here is
Ycode's own design: the reference has no camera (§1).

### 9.1 The switch (opt-in, off by default)

| Where | What |
|---|---|
| `ycode-simd --device DEV --camera MODE` | MODE `off` (default), `on` (the first V4L2 camera of the host, else the synthetic pattern), `synthetic`, a node `/dev/videoN` or an ID `v4l2:<bus>` (`camera-host.md` §2.3). Kept in `DEV/ycode-camera.plist` (`Mode`, `Position`) for this and later boots; without `--camera` the device's setting is used |
| `--camera-position back\|front\|external` | where the camera appears (default: back on an iPhone, external on an iPad) |
| `--camera-library <path>` | the capture layer; default `libYcodeCamera.dylib` in the guest tools, else `SimGuestAgents/out` next to the shim |
| Settings ▸ Simulators ▸ Camera | Off / Host webcam / Synthetic pattern (`specs/ide/run.md`) |

With the switch off nothing of this section exists in the run: no endpoint is
registered, no library is staged or inserted, the capabilities plist is the
device type's own, and the guest behaves as §2–§6 describe (placeholder
device, -11800, 9 s time-outs). The host has no TCC, so turning the switch
on is the host-side consent (§7.2 A.1).

With it on (`CameraDevice.swift`): the capabilities plist adds
`video-camera` and `still-camera` true and `rear-facing-camera` true
(`front-facing-camera` for the front position); `camera-flash` stays false.
The endpoint is started last of the host services (so the other services'
port names, which snapshots depend on, do not move) and registered late
(only apps look it up). The run prints `camera: on (<mode>, <position>):
<host camera>; capture layer <path>` and, at its end, the stream counters.

### 9.2 The endpoint `dev.ycode.camera` (host)

`CameraGuestService` (YcodeHostServices) on top of `CameraHostService`
(`camera-host.md`). Plain Mach messages in the MIG style, NDR record then
32-bit little-endian words; request n has ID 0x59434D00 + n, its reply
+100; messages to a client +200/+201 (`CameraGuestProtocol.swift`):

| n | Request | Reply |
|---|---|---|
| 1 | device list (word: protocol version 1) | complex: OOL binary property list (`version`, `devices`: `uniqueID`, `localizedName`, `modelID`, `manufacturer`, `deviceType`, `position`, `formats` of `width`, `height`, `minFrameRate`, `maxFrameRate`); word: its length |
| 2 | start: a port descriptor (make-send of the client's frame port); device index, width, height, fps × 1000, pixel format | status, stream ID, width, height, fps × 1000, pixel format of the stream |
| 3 | stop: stream ID | status |
| 4 | release (one-way): stream ID, ring slot, sequence | — |
| 200 | frame (to the frame port): stream ID, sequence, surface ID, slot, seed, width, height, pixel format, frames dropped before it, flags (1 synthetic), presentation time and duration in guest mach ticks | — |
| 201 | event (to the frame port): stream ID, kind (1 interrupted, 2 interruption ended, 3 disconnected, 4 reconnected, 5 failed), width, height | — |

Statuses: 0 ok, 1 no device, 2 busy (another host program holds the
camera, or no permission on the node), 3 bad request, 4 failed.

- **Device presentation.** One device. iPhone: `Back Camera` (or `Front
  Camera`), built-in wide angle, position 1 (2); iPad: the host camera's
  own name, external, position 0. Unique ID `dev.ycode.camera.<position>:<host
  camera ID>` (stable while the camera stays on its USB port), model ID the
  host camera's name, manufacturer `Ycode`. Formats: of the sizes 352×288,
  640×480, 960×540, 1280×720, 1920×1080 and 3840×2160, those the camera
  offers in a format Ycode converts, each with the slowest and fastest rate
  over those source formats; a camera with none of them offers all its sizes.
  The C615 gives 640×480, 1280×720 and 1920×1080, 5–30 fps.
- **Streams.** A start opens the host camera with the request (holding
  frames until released, ring of 8, no synthetic stand-in) and replies with
  the negotiated stream; the host does not scale (`camera-host.md` §3.1). A
  second start from the same frame port restarts the stream with the new
  request.
- **Time.** Each frame's host time (CLOCK_MONOTONIC, `camera-host.md` §3.4)
  is converted with a reading of the camera clock taken around a reading of
  the guest's mach clock (the VMM's guest counter at the guest timebase, as
  for audio): `ticks(t) = guest_now + (t − host_now) × hz / 10⁹`.
- **Flow control.** A sent frame's surface stays held until the client
  releases it (request 4). With every surface held the host drops new
  frames; the next sent frame carries the count. A frame the client's queue
  cannot take (send with time-out 0) is released at once and counted.
- **One process at a time** (§7.2 C 10). A start from another frame port
  interrupts the streaming client (event 1) and takes the camera; when the
  new client stops or its process ends, the most recently interrupted
  client gets the camera back with its request and event 2.
- **A client's end.** A dead-name notification on the frame port's send
  right ends its stream.
- **Hot-plug.** `camera-host.md` §6 events become events 3 and 4.

### 9.3 Getting the layer into apps

The kernel calls `DarwinSystem.imageEnvironment` for every spawn and exec.
With the switch on, an executable inside an `.app` bundle under an
`Applications` folder or an installed-app container (not
`System/Library/CoreServices` or `PrivateFrameworks`) gets
`DYLD_INSERT_LIBRARIES` with the staged `DEV/ycode-camera/libYcodeCamera.dylib`
(appended to any library already inserted) and `YCODE_CAMERA_SERVICE=dev.ycode.camera`.
Daemons, SpringBoard and the rest of the system are unchanged.
`DYLD_INSERT_LIBRARIES` is a public dyld feature, and the simulator's dyld
honours it for these processes.

The library links Foundation, CoreFoundation, CoreMedia, CoreVideo,
IOSurface, QuartzCore, CoreGraphics and ImageIO, **not AVFoundation**: an
app that never uses capture does not load it because of Ycode. Its
constructor does nothing without `YCODE_CAMERA_SERVICE`; else it installs
the layer at once when AVFoundation's capture classes are present (an app
that links AVFoundation), or later from an `objc_addLoadImageFunc`
callback when an image brings them. Installing asks the endpoint for the
device list; with no camera (or no endpoint) nothing is changed.

Debugging (app environment, `--app-env`): `YCODE_CAMERA_DEBUG=1` prints the
layer's trace to the app's standard error with times since load and, for
the discovery hooks, the calling image; `YCODE_CAMERA_SKIP=<parts>` (a
comma-separated list of `all`, `classes`, `discovery`, `photo`,
`sessions`, `outputs`, `preview`, `connections`) leaves parts out, to find
which part a failure needs.

### 9.4 The capture layer (guest)

`SimGuestAgents/camera` (`build-camera.sh`, macOS, the iOS simulator SDK's
public headers). Only public classes, selectors, functions and exported
constants are used; AVFoundation's string constants are read with `dlsym`
and classes found with `objc_getClass`.

- **Classes.** Run-time subclasses (`objc_allocateClassPair`) of the public
  classes whose initializers are not public: `YcodeCaptureDevice`
  (AVCaptureDevice), `YcodeCaptureDeviceFormat`, `YcodeFrameRateRange`,
  `YcodeCaptureDeviceInput`, `YcodeCaptureInputPort`,
  `YcodeCaptureConnection`, `YcodeCapturePhoto`,
  `YcodeCaptureResolvedPhotoSettings`. Instances are made without running a
  superclass initializer and deallocate as plain objects; every public
  property an app reads is overridden (encodings from the superclass), so
  `isKindOfClass:` and Swift casts see the public classes. They also take
  NSObject's key-value observing methods (`willChangeValueForKey:`,
  `addObserver:forKeyPath:options:context:`, `observationInfo`, …),
  `isEqual:` and `hash`: the public classes' own versions can rely on
  private state these instances do not have (a `setActiveFormat:` change
  notification crashed in the runtime before this, §9.7).
- **Hooks.** Public methods of the public classes are replaced with
  `method_setImplementation` / `class_addMethod` (initializers as C
  functions with the ARC init conventions): AVCaptureDevice's class methods
  (default device for a media type, for a type and position, `devices`,
  `devicesWithMediaType:`, `deviceWithUniqueID:`, system and user preferred
  camera), AVCaptureDeviceDiscoverySession (the factory records the
  request, `devices` adds the camera when type, media type and position
  match), AVCaptureDeviceInput's `initWithDevice:error:`, AVCaptureConnection's
  initializers (connections an app makes with the camera's port),
  AVCaptureSession (and AVCaptureMultiCamSession) inputs, outputs,
  connections, presets, configuration, running and interruption,
  AVCaptureOutput's `connections` and `connectionWithMediaType:`,
  AVCaptureVideoDataOutput's delegate and settings, AVCaptureVideoPreviewLayer,
  AVCapturePhotoOutput. The microphone and everything else stay the runtime's.
- **Discovery.** The default video device, the wide-angle device at the
  camera's position (or the external one on an iPad), discovery sessions
  that ask for it, `devices`, and the system and user preferred cameras
  return the camera; the reference's placeholder no longer appears. These
  answers go to the app, its libraries and the Swift overlay. Calls from
  the runtime's own capture frameworks (a caller in `AVFoundation.framework`
  or `AVFCapture.framework`, found with `dladdr` on the return address) get
  the runtime's answers: the runtime keeps private objects per device, and
  a photo output's initializer that found the camera through a discovery
  session crashed (§9.7).
- **Outputs before a session.** Until an output is added to a session, its
  `connections`, `connectionWithMediaType:` and the photo output's
  `availablePhotoCodecTypes`, `availablePhotoPixelFormatTypes`,
  `supportedFlashModes` and `maxPhotoDimensions` are the runtime's (its
  initializers read some of them).
- **Device.** Name, IDs, type, position from the host; `connected` YES
  (NO after a disconnect event, with KVO); formats as on a device: a
  `'420v'` and a `'420f'` format per size, each with its CMVideoFormatDescription
  and one frame-rate range; the active format follows the session preset
  (High = the largest 16:9 size up to 1920×1080) or `setActiveFormat:`
  (which needs `lockForConfiguration:` and turns the session's preset into
  InputPriority, as documented); `activeVideoMin/MaxFrameDuration` default
  to 1/30 s (or the format's fastest) and are checked against the range.
  A webcam's controls: no torch or flash, focus locked, continuous
  automatic exposure and white balance, zoom 1.
- **Inputs and authorization.** Making an input asks the runtime's
  `authorizationStatusForMediaType:` (the guest's `tccd`, §6): denied or
  restricted → nil and AVFoundationErrorDomain −11852
  (AVErrorApplicationIsNotAuthorizedToUseDevice); not determined → the
  runtime's `requestAccessForMediaType:` (so `tccd` shows its alert, or
  aborts an app without `NSCameraUsageDescription`, §6.1) and the input is
  made. Frames reach outputs only while the status is authorized (checked
  once a second until it is).
- **Sessions.** `canAddInput:` (one camera input per session; the runtime's
  microphone input is accepted and gives nothing), `addInput:` and
  `addOutput:` make connections between the camera port and every video
  data, photo and movie file output and every preview layer (except those
  added "with no connections"); invalid additions raise
  NSInvalidArgumentException as documented. Presets: the table of
  `YCPresetSize` (Medium 480×360, Low 192×144, Photo the largest 4:3, the
  fixed-size presets their size); `canSetSessionPreset:` follows the
  device's `supportsAVCaptureSessionPreset:`. `startRunning` asks the host
  for a stream (the active format's size, the frame rate of
  `activeVideoMinFrameDuration`, the first video data output's pixel format,
  else the format's own, else BGRA when only preview layers and photo
  outputs consume), returns once the stream runs (no 9 s time-out), sets
  `running` with KVO and posts did-start-running; `stopRunning` stops the
  stream and posts did-stop-running. Configuration changes restart the
  stream only when what it asks for changed. Host statuses become runtime
  errors: no device −11814, busy −11815, other −11800. One stream per
  process: a session that starts while another runs interrupts it (reason
  3, video device in use by another client); a host interruption does the
  same, interruption ended clears it. In the background (the public
  UIApplication notifications) the stream stops and the session is
  interrupted (reason 1); back in the foreground it resumes.
- **Video data output.** For each frame: an IOSurface looked up by ID
  (`IOSurfaceLookup`, cached per stream), a CVPixelBuffer on it
  (`CVPixelBufferCreateWithIOSurface`) with BT.601 Y'CbCr matrix and BT.709
  primaries/transfer attachments and a release token attachment (its
  deallocation sends request 4, so the host slot frees when the app lets the
  buffer go), a CMSampleBuffer (`CMSampleBufferCreateReadyWithImageBuffer`)
  with presentation time `CMClockMakeHostTimeFromSystemUnits(ticks)` (the
  host time clock, the time base CoreMedia's capture clock uses) and the
  stream's frame duration. Delivered on the output's queue to
  `captureOutput:didOutputSampleBuffer:fromConnection:`. The connection's
  `videoRotationAngle` (0, 90, 180, 270, clockwise; the deprecated
  `videoOrientation` maps to 90 portrait, 270 upside down, 180 landscape
  left, 0 landscape right) and `videoMirrored` are applied by copying into
  a CVPixelBufferPool buffer; a BGRA request on a 4:2:0 stream is converted.
  With `alwaysDiscardsLateVideoFrames` a frame that arrives while the
  delegate still runs is dropped and reported to
  `captureOutput:didDropSampleBuffer:fromConnection:` (reason FrameWasLate);
  frames the host dropped because the app held buffers are reported with
  OutOfBuffers.
- **Orientation decision.** The native orientation (rotation angle 0) shows
  the webcam image upright, as it arrives; preview connections default to
  angle 0 too, so a portrait app shows the webcam upright without rotating.
  An app that sets an angle gets that rotation applied. A front camera's
  preview connection is mirrored (automatic mirroring); data outputs are not.
  The rotation coordinator (`AVCaptureDeviceRotationCoordinator`) is not
  provided for.
- **Preview layer.** `AVCaptureVideoPreviewLayer` keeps its real class and
  initializer (run with no session); the layer's session, connection and
  `previewing` come from the layer. Each frame (dropped while the previous
  one is still being drawn) is converted to a BGRA CGImage on a serial queue
  and set as the contents of a sublayer below the app's own sublayers,
  sized to the layer, with the contents gravity from `videoGravity` and the
  connection's rotation and mirroring as a transform.
  `captureDevicePointOfInterestForPoint:` is computed for an unrotated layer.
- **Photo output.** `capturePhotoWithSettings:delegate:` takes the next
  frame from the 10th frame of the stream on (a webcam's first frames after
  it opens are dark while its automatic exposure starts): will-begin, will-capture, did-capture, did-finish-processing (a
  `YcodeCapturePhoto`: JPEG `fileDataRepresentation` encoded with ImageIO at
  quality 0.9, `CGImageRepresentation`, a BGRA `pixelBuffer` when the
  settings ask for a pixel format, `timestamp`, `resolvedSettings` with the
  photo's dimensions) and did-finish-capture, on a serial queue. A session
  that is not running gives −11803 (AVErrorSessionNotRunning).
  `availablePhotoCodecTypes` is `jpeg`, the pixel formats BGRA, the flash
  modes off. HEIC, RAW, depth, Live Photos and movie file recording are not
  provided.
- **Image picker.** UIKit's camera source follows the MobileGestalt answers
  of §4, which the switch changes. The picker's own camera interface is
  not fed (§9.6).

### 9.5 Privacy command

`ycode-simd --device DEV --privacy grant|revoke|reset camera|microphone
<bundle ID>` writes §6.2's row into `DEV/data/Library/TCC/TCC.db` (table
`access`; service `kTCCServiceCamera` or `kTCCServiceMicrophone`, client the
bundle ID, client type 0, auth value 2 grant / 0 revoke, auth reason 4,
auth version 1; reset deletes the row) through the host's SQLite library
(loaded at run time). With the device running the command goes to its
control socket (`privacy …`): the running ycode-simd writes the row and
ends the app (`ylaunch kill`), as `tccd` does when an app's access
changes. With the device stopped the row is written directly and read at
the next boot. The database must exist (the guest's `tccd` makes it at the
first boot). Ycode does not send `TCCAccessSetInternal` to `tccd` (§6.2):
the control path is Ycode's own.

### 9.6 Image picker, and what is not provided

- `UIImagePickerController` with the camera source: with the switch on,
  `isSourceTypeAvailable(.camera)` is YES and the picker presents its camera
  interface (shutter, zoom buttons, PHOTO mode), but its viewfinder stays
  grey. `isCameraDeviceAvailable` is NO for rear and front. The picker's
  capture runs inside the runtime's own frameworks, whose calls get the
  runtime's answers (§9.4 Discovery); feeding them would need private
  interfaces, which the clean room does not use. Apps that use
  AVFoundation directly get the camera.
- Not provided: HEIC, RAW, depth, Live Photos, movie file recording,
  `AVCaptureDeviceRotationCoordinator`, the multi-camera session's second
  camera, focus, exposure and white-balance controls beyond the fixed
  values of §9.4, torch and flash.
- Snapshots: the camera runs on the Thor were cold boots. A warm restore of
  a device whose app was streaming is not designed or tested; the launcher's
  fingerprint includes `--camera`, so changing the switch boots cold.

### 9.7 Verification (Ycode's simulator on the Thor, iOS 27.1, iPhone Duo device type; 2026-10-28)

Our probe `CameraProbe` (`SimShim/guest-tests/camera`, public UIKit and
AVFoundation API) installed and launched by `ycode-simd --install-app
--launch`, with the C615 webcam (`/dev/video0`) or the synthetic camera.

| Check | Result |
|---|---|
| Switch off: discovery | default video device nil; discovery sessions: the microphone only; no endpoint, no library in the app (`--camera off`, and a new device) |
| Switch on: discovery | default video device "Back Camera", built-in wide angle, position back, model "HD Webcam C615", manufacturer Ycode, connected; discovery (all types) the microphone and Back Camera; video discovery 1; formats `420v`/`420f` × 352×288, 640×480, 1280×720, 1920×1080 at 5–30 fps (the synthetic camera: 6 formats); system preferred camera Back Camera |
| Permission: no record | status "not determined"; a request shows `tccd`'s alert ("Allow “Camera Probe” to access your camera?", the app's usage string, Don't Allow / Allow; screenshot) |
| Permission: `--privacy revoke` (stopped device) | an input fails with AVFoundationErrorDomain −11852 |
| Permission: `--privacy grant` (stopped device) | status "authorized", inputs are made (after the kernel fix of `sandbox-extensions.md` §5: before it, `tccd` allowed the record but its failed sandbox extension made the app see "denied") |
| Permission: `--privacy revoke` (running device) | "ok revoke camera dev.ycode.CameraProbe; app: ylaunch: killed dev.ycode.CameraProbe"; the record's auth value 0 |
| Stream 1280×720 `420v`, preview | 174 frames in 5.96 s (29.0 fps), none dropped, first frame 213 ms after its time stamp; sizes 1280×720, `420v`, IOSurface-backed; the preview layer previewing with the live webcam picture (aspect fill; screenshot). An earlier run under heavy host load (load average about 150) got its first frame 5.2 s late, then 30 fps |
| Stream 640×480 BGRA, angle 90, mirrored | 233 frames in 7.96 s (29.2 fps), none dropped, first frame 264 ms after its time stamp; 480×640 BGRA, rotated and mirrored |
| Stream 1920×1080 `420f` | 292 frames in 9.92 s (29.3 fps), none dropped, first frame 251 ms after its time stamp; host: MJPG 1920×1080 → `420f` |
| Pixel content | the guest's last 1280×720 frame against a frame of `ycode-simd --camera-probe` taken minutes later: mean absolute difference 2.2 per channel (0–255); two host frames of the same scene 2.1 |
| Flow control | every frame the host sent was released (e.g. 298 sent, 298 released; 554 sent, 552 released when the app ended with frames held); 0 not taken |
| Photo | `capturePhotoWithSettings:delegate:` (JPEG): will-begin (1920×1080), did-finish-processing with a 280 KB JPEG and a 1920×1080 CGImage, did-finish-capture, no error; the picture is the webcam's |
| Webcam release | `fuser /dev/video0` empty after every run |
| Boot | two boots started together on two copies of the same device: home screen seen 83.8 s with the webcam on, 80.6 s with the switch off. Over the day, 81–150 s with the camera on and 83–292 s off (the shared host's load varied from about 2 to 200). The camera endpoint registers after the queued services; with the switch off nothing of §9 runs (§9.1) |

Problems found and fixed while verifying: the probe needed the scene life
cycle (the iOS 27 SDK refuses to launch an app without a scene manifest);
the layer's host calls read their replies from the wrong buffer
(MACH_RCV_INVALID_DATA); the kernel refused `tccd`'s camera sandbox
extension (`sandbox-extensions.md` §5); the public superclasses'
key-value observing methods crashed on the layer's uninitialized instances
(§9.4 Classes); the runtime's photo output initializer crashed with the
layer's answers (§9.4 Discovery and Outputs before a session); the first
frames after the webcam opens are dark (§9.4 Photo output).

### 9.8 Evidence for §9

| Claim | Level | Source |
|---|---|---|
| Class names, selectors, constants, error codes, documented behavior of the capture API (§9.4) | 1 | Apple's public AVFoundation, CoreMedia, CoreVideo, IOSurface, QuartzCore, ImageIO and UIKit documentation and SDK headers |
| `DYLD_INSERT_LIBRARIES`, the Objective-C runtime calls, `dladdr` (§9.3, §9.4) | 1 | public dyld, Objective-C runtime and dlfcn documentation |
| Results in §9.6 and §9.7 | 3 | our probe on Ycode's simulator on the Thor (runs e1–e17, p1–p11, o1–o4); guest `log stream --process tccd`; kernel trace of `tccd` |
| The endpoint, its protocol, the opt-in, time conversion, flow control, one client at a time, the privacy command, the IDE controls | — | Ycode design (the reference has no camera, §1) |

## Evidence

| Claim | Level | Source |
|---|---|---|
| No video device; the microphone device; placeholder preferred camera; multi-cam flag (§2.1) | 3 | probe runs d1, d2, pc-*, caps-*, i270-d (public API), guest unified log |
| Session results, error codes, 9 s time-outs, no frames, output pixel formats (§2.2) | 3 | probe runs s1, s2-granted, i270-s; guest unified log |
| Log signature (§2.3) | 3 | guest unified log of the probe |
| Image picker (§2.4) | 3 | probe runs d1, caps-A, caps-B, picker (screenshot, log) |
| No capture daemon; framework and file inventory (§3.1) | 2 | the runtime's launchd plists and folders; shared-cache map (image paths only) |
| Simulator CMCapture class list (§3.1) | 4 | `objc_copyClassNamesForImage` in the guest (our `cammeta`) |
| Endpoints used and not used (§3.2) | 3 | recorder in every guest process of boot b1 (1209 process logs) and in the probe during discovery, session and picker |
| SimCaptureService belongs to the host's rendering service | 4 | host bundle string search (name only); `launchd-sim.md` §6.3 |
| Inputs the capture stack reads (§3.3) | 3 | recorder `getenv`, file-system, preference and `dlopen` hooks in the probe (run d2) |
| MobileGestalt camera answers and plist control (§4) | 3 | probe MobileGestalt reads with the device type's plist and with modified copies (caps-A, caps-B) |
| Product class and other inputs have no effect (§5) | 3 | runs pc-base, pc-D93, pc-V53, pc-N104, pc-J821, pc-D93e, caps-A, caps-B, st-*, i270-* |
| TCC request and reply keys, alert, abort without a usage string (§6.1) | 3 | recorder XPC dumps; guest unified log of the probe and `tccd`; screenshot of the alert (run rq-prompt); crash report (run rq-nousage) |
| `simctl privacy … camera`; `TCCAccessSetInternal` message; database row; termination; notification (§6.2) | 3 | `simctl` runs; `tccd` and CoreSimulatorBridge unified log; `sqlite3` read-only on the device's TCC.db |
| The Mac's camera was never used | 3 | the Mac's unified log (no `kTCCServiceCamera` events in the observation window); no camera usage strings or entitlements in DeviceHub or CoreSimulatorService (level 4) |
| V4L2, public AVFoundation, CoreMedia, CoreVideo and ImageIO semantics (§7.2) | 1 | Linux kernel media documentation; Apple's public framework documentation |

Level 5 (disassembly or decompilation) was not used. It was not needed:
varying every input the capture stack reads (§5), together with the class
inventory (§3.1), showed that no external input can produce a device.
