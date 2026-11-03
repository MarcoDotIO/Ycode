# Spec: the watchOS simulator (watchOS 27.0, Apple Watch) — what differs from iOS, and what Ycode must add

Status: **draft, round 0** (agent OBS-WATCH, 2026-10-29); round W1 under Ycode in §10 (agent WATCH-BOOT); round W2 in §11 (agent WATCH-DISPLAY); the input observations of round W3a in §5.1 (agent OBS-WATCH2, 2026-10-30); round W3b, the crown under Ycode, in §12 (agent WATCH-W3B, 2026-10-30); buttons, the Action button and the gesture event in §5.2 (agent OBS-WATCH3, 2026-10-31); round W7, buttons and gestures under Ycode, in §13 (agent WATCH-W7, 2026-10-31). It describes the
observable behavior and file formats of Xcode 27.1's watchOS 27.0 simulator
runtime (24R362) and its Apple Watch device types, as deltas from the iOS
27.1 runtime that `ycode-simd` boots today, and it states what Ycode must
add, in rounds sized for one agent each. Pairing a watch with an iPhone (the
host endpoint, the wire format, WatchConnectivity behavior, the IDE's pair
handling) is in the companion spec **`device-pairing.md`**. Facts come from
the runtime and device-type files read as formats (level 2), black-box runs
of throwaway devices on the Mac (level 3) and bundle metadata (level 4:
names of Mach services, exported symbols, strings). No disassembly or
decompilation was used. Raw material is in `research/dirty/watch/`
(git-ignored); prose observations in `research/notes/watchos-observations.md`;
our probes in `research/experiments/watch/`.

The Mac was under very heavy load from unrelated work during every
measurement (load average 190–840); **all times are upper bounds**.

Terms as in `launchd-sim.md`: **RR** (a runtime's `RuntimeRoot`), **DEV**
(the device directory; `DEV/data` is the guest's writable world).

## 1. Answers in brief

1. **The runtime is plain arm64, like iOS.** Every executable, library and
   the shared cache (`dyld_sim_shared_cache_arm64`, 2 306 images) is arm64
   for platform 9 (watchOS simulator). There is **no arm64_32** in the
   simulator (that is the device ABI). `ycode-simd` loads it with the iOS
   loader path; nothing new to emulate at the instruction level (§2.3).
2. **Packaging as iOS**: a sealed, unencrypted, read-only APFS cryptex
   volume, 9.0 GB used. Copied to `$YCODE_DATA/runtimes/watchOS-27.0-24R362/RuntimeRoot`
   (9.0 GB, 383 077 entries, `SystemVersion.plist` 24R362) without any
   decryption (§2.6).
3. **The guest is a smaller iOS**: 229 job labels (iOS 363), 178 processes
   at idle, 5.3 GiB summed footprint, almost no idle CPU (the face redraws
   once a minute). The system app is **Carousel**; the face is drawn by a
   separate **ClockFace** process. Jobs live in launchd's **`system`
   domain**, not `user/501` (§2.4).
4. **Rendering is the iOS path**: backboardd owns a single 416 × 496 (Series
   12 46 mm) `'BGRA'` SimFramebuffer display at scale 2, 60 Hz, P3 (Carousel
   also maps the framebuffer library). Four SimMetalHost processes; two new
   per-process Metal names, `ClockFace` and `NTKFaceSnapshotService` (§4).
5. **Input**: a new HID service **`MainScreenDigitalCrownService`** (vendor
   page 0xFF0B, usage 1) next to the iOS buttons, keyboard and touch
   services; SimulatorKit builds crown messages carrying one signed double
   (the rotation delta) and watch-gesture messages carrying one integer. The
   guest-side effects were not observed (§5, §9 Q2–Q4).
6. **Boot** (Mac, loaded): first boot 30.3 s to `bootstatus` terminal,
   repeat boot 13.9–15.7 s, face 1.5 s later (§6). The first boot **after
   pairing** took 54.4 s, and 163.9 s in a run with a 145 s stall under
   heavy load (`device-pairing.md` §3).
7. **One device type change matters for boot**: `powerexperienced` in the
   runtime is an arm64e *device* binary; the reference fails to spawn it
   ("Bad CPU type") every boot and carries on. Ycode must fail it the same
   way (§2.4).

## 2. The runtime

### 2.1 Identification

| Item | Value |
|---|---|
| Runtime identifier | `com.apple.CoreSimulator.SimRuntime.watchOS-27-0` (one build installed: 24R362) |
| Bundle | `watchOS 27.0.simruntime`, `CFBundleVersion` 392, `DTXcodeBuild` 27A200c |
| `SystemVersion.plist` | `ProductName` **"Watch OS"**, `ProductVersion` 27.0, `ProductBuildVersion` 24R362 |
| Mount | `/Library/Developer/CoreSimulator/Volumes/watchOS_24R362` |

Runtime detection keys on `ProductName` "Watch OS" (with a space) and the
build, as V-2 of `visionos.md` does for `xrOS`.

### 2.2 `profile.plist` (runtime bundle, `Contents/Resources/`)

Differences from iOS 27.1 (24A94401); keys not listed are equal:

| Key | iOS 27.1 | watchOS 27.0 |
|---|---|---|
| `platformIdentifier` | `com.apple.platform.iphonesimulator` | `com.apple.platform.watchsimulator` |
| `defaultVersionString` | 27.1 | 27.0 |
| `equivalentIOSVersion` | – | 27.0 |
| `supportedProductFamilyIDs` | [2, 1] | **[4]** |
| `restrictedToDeviceTypes` | [`…V68`] | absent |
| `pairingRequirements` | {`maxPairs` 100, `minOSVersion` 3.2, `supportedProductFamilies` [4]} | **{`maxPairs` 1, `minOSVersion` 12.0, `supportedProductFamilies` [1]}** |
| `requiredHostServices` | 14 names | the same minus `com.apple.FileProvider.sim2host` and `com.apple.ist.ds.appleconnect.service.sim2host` (12) |
| `supportedFeatures` added | | `com.apple.CoreSimulator.pairing`, `com.apple.hid.applepay.authorize`, `com.apple.hid.keyboard`, `com.apple.hid.touch-pressure` = **false**, `com.apple.watch.pairing.qws` |
| `supportedFeatures` removed | `carplay.sessionController`, `CoreSimulator.display.rotation`, `CoreSimulator.pasteboard`, `UIKit.userInterfaceStyleMode` | |
| `supportedFeaturesConditionalOnDeviceType` | 10 names (carplay, resizableScene, pairing, ambient-overlay, …) | **`com.apple.hid.watch.gestures`, `com.apple.location.nearby-interaction`, `com.apple.motion.fall-detection`** |
| `supportedArchs` | arm64, x86_64 | arm64, x86_64 (the runtime itself is arm64 only, §2.3) |

Family 4 is the Apple Watch family (`UIDeviceFamily` 4).

### 2.3 Layout relative to iOS 27.1

| Item | iOS 27.1 (24A94401) | watchOS 27.0 (24R362) | Consequence for `ycode-simd` |
|---|---|---|---|
| RR top level | `Applications`, `Developer`, `Library`, `System`, `bin`, `sbin`, `usr`, `private`, `etc` → `private/etc`, `.nofollow`, `.resolve` | same, plus `RestoreVersion.plist` | the prefix/volume code applies unchanged |
| Architecture | arm64, platform 7 | **arm64, platform 9** (594 executables, 507 bundles, 30 dylibs; one exception below) | Mach-O and loader checks accept platform 9; no arm64_32 |
| Shared cache | `dyld_sim_shared_cache_arm64` 2 035 384 320 B + `.01` 1 748 582 400 B; 1 819 images | same file names, header "dyld_v1   arm64"; 2 040 791 040 B + `.01` 1 099 792 384 B + `.atlas` 786 024 B + `.map`; **2 306** images in the map | same loader path (`dyld-sim-handoff.md`); different build |
| `usr/lib/dyld_sim` | 701 840 B | 701 824 B (platform 9) | re-check the handoff facts on this build |
| `sbin/launchd_sim`, `launchd_sim_trampoline` | 469 744 B, 219 680 B | 470 464 B, 72 448 B | re-check `launchd-sim.md`, `bootstrap-wire.md` |
| `/usr/libexec/powerexperienced` | absent | **fat arm64e / arm64e.x1, platform 4 (device)** | spawn must fail with `EBADARCH` (86) as in the reference (§2.4) |
| App bundles (`Applications` + `CoreServices`) | 267 | 102 | lsd seeds fewer apps |
| `DataClassMigrators` | 35 | 24 | 24 migration plugins on the first boot |
| Runtime volume (used) | 16 GiB | 9.0 GB | disk on `$YCODE_DATA` |

### 2.4 launchd jobs

`Bootstrap.Paths` has the same four entries as on iOS (`launchd-sim.md`
§4.1): `RR/System/Library/LaunchDaemons` (**227** plists; iOS 329),
`RR/System/Library/LaunchAngels` (**2**; iOS 25),
`RR/Developer/Library/LaunchDaemons` (1, testmanagerd), and
`DEV/data/Library/LaunchDaemons` (**8** host plists: the bridge and seven
CoreDevice `dt*` daemons; iOS's ninth, `dtpasteboardd`, is absent).
`RR/System/Library/LaunchAgents` is empty. As on iOS, the jobs of
`RR/System/Library/NanoLaunchDaemons` (4: nanofindlocallyd, nanomessagesd,
pairedunlockd, otpaird) and `NanoLaunchDaemonsAltAccount` (6: appconduitd,
homed, nanomaild, nanomapsgd, nanophotosd, nanosystemsettingsd) are present
at run time though not in `Paths` (`lean-boot.md` §1.1);
`NanoLaunchDaemonsAltAccountOnly` (dataaccessd) is not loaded.

**Domain.** The watch's jobs and the host-side endpoints live in launchd's
**`system`** domain: `launchctl print system` lists 266 services and the
`com.apple.xpc.launchd.simhost` block; `launchctl print user/501` is
refused ("Unrecognized target specifier"). On iOS the jobs are in
`user/501` (382 services) and `system` holds 7. Ycode's control channel
(`launch-sim-control.md` §3.2–3.4, measured on iOS in `user/<uid>`) must be
re-checked on this runtime: registrations must land where the watch's jobs
look them up.

Over the four standard directories there are 229 labels: 208 shared with
iOS, **21 only on watchOS**, 155 only on iOS.

| Only on watchOS | Program | Role (from names and logs) |
|---|---|---|
| `com.apple.Carousel` | `/System/Library/CoreServices/Carousel.app` | the **system shell** (FrontBoard host) in place of SpringBoard; RunAtLoad, KeepAlive; vends `PurpleSystemAppPort` and 131 more services (`com.apple.Carousel.*`, `CSLS*`, `NTKServer`, fall detection, live activities, …) |
| `com.apple.gizmoappd` | `WatchKit.framework/Support/gizmoappd` | watch app manager; `com.apple.gizmoappd`, `.appmanager`, `.dtsupport` |
| `com.apple.watchgesturesd` | `WatchGestures.framework/watchgesturesd` | gestures (double tap, wrist); vends `com.apple.WatchGestures.WatchGesturesSimulatorServer` among 7 |
| `com.apple.nanotimekitd` | `NanoTimeKit.framework/nanotimekitd` | faces and complications |
| `com.apple.carouselecomoded`, `com.apple.lightlayerd`, `com.apple.servicetowerd`, `com.apple.relevanced` | | low-power mode, the light layer, UI triggers, Smart Stack relevance |
| `com.apple.powerexperienced` | `/usr/libexec/powerexperienced` | **fails to spawn** in the reference (device binary, "Bad CPU type in executable", launchd_sim does not retry) |
| `nanomediaremoted`, `nanopassd`, `nanoweatherd`, `eventkitsyncd`, `addressbooksyncd`, `appaudiod`, `appleidsetupd`, `messagesregistrationd`, `corespotlightd`, `cache_delete`, `deleted_helper`, `SensorKitALSHelper` | | sync and Nano services |

Only on iOS (selection): SpringBoard, PosterBoard, CarPlayApp, InputUI,
companiond, nanotimekitcompaniond, pasteboard, FileProvider, healthappd,
weatherd, the Safari and Maps helpers. The pairing daemons
(`ids_simd`, `nanoregistryd`, `nanoregistrylaunchd`, `identityservicesd`,
`rapportd`, `sharingd`) are in both (`device-pairing.md` §4).

Running after boot (selection): Carousel, backboardd, ClockFace,
NTKFaceSnapshotService, nanotimekitd, chronod and about 20 WidgetKit
complication extensions, healthd, fitnessintelligenced, five
MTLCompilerService, and the usual daemons.

### 2.5 Host services

The host registers its names under `com.apple.xpc.launchd.simhost` in the
`system` domain (§2.4). An unpaired watch had **28**:

| Group | Names | Difference from the iPhone (27, same Mac) |
|---|---|---|
| CoreSimulator | `host.bootstrap_port`, `SimFramebufferServer`, `SimCaptureService`, `SimIdentityService`, `IndigoHIDRegistrationPort`, `NearbyInteraction` | same |
| GPU | `com.apple.metal.simulator` (own port); `…backboardd` (own port); `…Carousel`, `…HeadBoard`, `…PineBoard`, `…SBRendererService`, `…SpringBoard` (one shared port); **`…ClockFace`, `…NTKFaceSnapshotService`** (one shared port); `com.apple.IOSurface.Remote`; `com.apple.gputools.service.simulator` | + ClockFace and NTKFaceSnapshotService |
| Audio, System, Other | as on iOS | − `com.apple.FileProvider.sim2host` |

Four `SimMetalHost` processes served the device (one per distinct port).
The pairing endpoint `com.apple.IDSSimRPC.remote.<phone UDID>` appears in
this block only while the paired phone is booted (`device-pairing.md` §4).

### 2.6 Copying the runtime (done, round W0)

`simctl runtime list -v`: "Patchable Cryptex Disk Image", 3.6 GB, mounted
read-only (mode Cryptex). `diskutil info`: APFS, **Sealed: Yes, Encrypted:
No, FileVault: No**, volume "WatchOS 27.0 Simulator", 9.0 GB used.
Copied (rsync over SSH, symlinks, modes and times preserved, no decryption)
to **`$YCODE_DATA/runtimes/watchOS-27.0-24R362/RuntimeRoot`**: 9.0 GB,
383 077 entries (the same count as the source), `SystemVersion.plist` reads
24R362. One directory, `private/var/db/modelmanagerd` (mode 0700, owned by
a role account), is unreadable to a normal user on the Mac; it is empty
(64-byte APFS directory) and was created empty with mode 0700 in the copy,
as in the earlier iOS copy. The thirteen device-type bundles of §3.1 were
copied beside it to `$YCODE_DATA/runtimes/watchOS-27.0-24R362/DeviceTypes/`
(1.2 MB) as dirty-room reference; Ycode's own device data is written from
this spec, not from those files (as for iPad and visionOS).

## 3. The device types

### 3.1 Bundles

Thirteen types accept watchOS 27.0 (every one: family [4], scale 2, pitch
326, 60 Hz, P3, `integrated` display):

| Device type (`com.apple.CoreSimulator.SimDeviceType.…`) | Model / represented | Class | Screen (px) | `main-screen-class` | Corner radius | Chrome | Runtimes | Default create / pair |
|---|---|---|---|---|---|---|---|---|
| `Apple-Watch-Series-12-46mm` | `Watch8,3` / `Watch8,3`, `Watch8,5` | N237b | 416 × 496 | 35 | 50 | watch5b | 27.0– | 27.0–99.99 / 27.0–99.99 |
| `Apple-Watch-Series-12-42mm` | `Watch8,4` / `Watch8,2`, `Watch8,4` | N238s | 374 × 446 | 34 | 44 | watch5s | 27.0– | 27.0–99.99 / 27.0–99.99 |
| `Apple-Watch-Ultra-4-49mm` | `Watch8,1` | N240 | 422 × 514 | 38 | 57 | watch6 | 27.0– | 27.0–99.99 / 27.0–99.99 |
| `Apple-Watch-Series-11-46mm` | `Watch7,18` / `+Watch7,20` | N227b | 416 × 496 | 35 | 50 | watch5b | 26.0– | 26.0–26.99 / 26.0–26.99 |
| `Apple-Watch-Series-11-42mm` | `Watch7,17` / `+Watch7,19` | N227s | 374 × 446 | 34 | 44 | watch5s | 26.0– | 26.0–26.99 / same |
| `Apple-Watch-Series-10-46mm` | `Watch7,9` / `+Watch7,11` | N217b | 416 × 496 | 35 | 50 | watch5b | 11.0– | 11.x / 11.x |
| `Apple-Watch-Series-10-42mm` | `Watch7,8` / `+Watch7,10` | N217s | 374 × 446 | 34 | 44 | watch5s | 11.0– | 11.x / 11.x |
| `Apple-Watch-Series-9-45mm` | `Watch7,4` / `+Watch7,2` | N208b | 396 × 484 | 26 | 42.5 | watch3b | 10.0– | 10.x / 10.x |
| `Apple-Watch-Series-9-41mm` | `Watch7,3` / `+Watch7,1` | N208s | 352 × 430 | 27 | 38.5 | watch3s | 10.0– | 10.x / 10.x |
| `Apple-Watch-Ultra-3-49mm` | `Watch7,12` | N230 | 422 × 514 | 38 | 57 | watch6 | 26.0– | 26.x / 26.x |
| `Apple-Watch-Ultra-2-49mm` | `Watch7,5` | N210 | 410 × 502 | 29 | 54 | watch4 | 10.0– | 10.0–11.99 / same |
| `Apple-Watch-SE-3-44mm` | `Watch7,16` / `+Watch7,14` | N244b | 368 × 448 | 17 | 34 | watch2b | 26.0– | 26.0–99.99 / **none** |
| `Apple-Watch-SE-3-40mm` | `Watch7,13` / `+Watch7,15` | N243s | 324 × 394 | 16 | 28 | watch2 | 26.0– | 26.0–99.99 / none |

Chrome ids are `com.apple.dt.devicekit.chrome.<value>`. Each bundle has a
framebuffer-mask PDF named by a UUID (`framebufferMask`) — the round-rect
watch outline; Ycode draws its own (rule 5 of AGENTS.md). Older types
(Series 2–8, SE 1st/2nd generation, Ultra 1) stop before 27.0.

### 3.2 `profile.plist` (Series 12 46 mm; the others differ only as in §3.1)

| Key | Value |
|---|---|
| `modelIdentifier`, `representedModelIdentifiers` | `Watch8,3`; [`Watch8,3`, `Watch8,5`] |
| `productClass` | `N237b` |
| `supportedProductFamilyIDs` | [4] |
| `environment` | `SIMULATOR_LEGACY_ASSET_SUFFIX` = "" |
| `springBoardConfigName` | `iPhone4Simulator` |
| `chromeIdentifier`, `framebufferMask` | `com.apple.dt.devicekit.chrome.watch5b`, a UUID |
| `supportedFeatures` | `com.apple.display.aot` (always-on), `com.apple.display.integrated`, **`com.apple.hid.digital-crown`**, `com.apple.hid.touch-screen`; Ultra types also **`com.apple.hid.sting`** (the Action button) |
| `supportedFeaturesConditionalOnRuntime` | `com.apple.deviceIdentity`, `com.apple.hid.watch.gestures`, `com.apple.location.nearby-interaction`, `com.apple.motion.fall-detection` |
| `supportedArchs` | arm64, x86_64, i386 |
| `minRuntimeVersion`, `createByDefaultForRuntimeVersions`, `pairByDefaultForRuntimeVersions` | 27.0; 27.0–99.99; 27.0–99.99 |

### 3.3 `capabilities.plist` (`SIMULATOR_CAPABILITIES`)

Same structure as on iPhone (`device-capabilities.md` §1). Values that
differ in kind (Series 12 46 mm):

| Key | Value |
|---|---|
| `idiom` | `watch` |
| `ArtworkTraits` | idiom `watch`, subtype 496, gamut P3, `CompatibleDeviceFallback` `Watch7,18`, product description "Apple Watch Series 12", `GraphicsFeatureSetFallbacks` `APPLE10:…:APPLE1:GLES2,0` |
| `ScreenDimensionsCapability` | class 35, 416 × 496, scale 2, pitch 326, `main-screen-orientation` 4.712389 (3π/2) |
| numbers | `DeviceCornerRadius` 50, `HomeButtonType` 0, `memoryClass` **3** (2 on Series 11 and older), `subtype` 496, `graphicsClass` 0, `software-dimming-alpha` 0 |
| strings | `graphicsFeatureSetClass` **APPLE11** (APPLE8 on the older types), `ModelNumber`/`RegulatoryModelNumber` A3584, `marketing-name` "Apple Watch Series 12", `device-name` **"Watch Simulator"**, `ThinningProductType` `Watch8,3` |
| true (41) | `always-on-time`, `hardware-detents`, `GPSCapability`, `magnetometer`, `accelerometer`, `microphone`, `bluetooth`, `bluetooth-le`, `wifi`, `location-services`, `DeviceSupportsSwimmingWorkouts`, `DeviceSupportsElton`, `stand-alone-contacts`, `encrypted-data-partition`, `gas-gauge-battery`, `ASTC`, `hidpi`, HEVC decoders, `arm64` (false on Series 9/10, Ultra 2) … |
| false (30) | **`metal`**, `telephony`/`sms`/`contains-cellular-radio` (true on the cellular models: Series 12 42 mm, Ultra 4, Series 9, Ultra 2/3, SE 3 44 mm), `watch-companion`, `touch-id`, `pearl-id`, `ipad`, `DeviceSupportsDynamicIsland`, `720p`, `screenrecorder`, `OysterCapability` … |
| Ultra only | `WatchAppButtonCapability` true |
| `displays` | one entry: `primary` / `LCD`, `integrated`, 416 × 496, scale 2, 326 × 326 dpi, `refreshRate` 60, `colorspace` P3, corner radii 50 (all four), `hasDigitizer` true, `screenID` 1, `powerState` 1, `chromeIdentifier`, `framebufferMaskIdentifier`, `nativeOrientation` 90 and `nativeRotation` 90 (Series 12, Ultra 4, Ultra 3, Ultra 2; 0 on the others) |

No `uniqueId` is fixed in the file: the display's unique id is per device
(as on iOS, unlike visionOS).

### 3.4 Launch environment and bootstrap plist

`DEV/data/var/run/launchd_bootstrap.plist` has the same top-level and
`Bootstrap` keys as on iOS (`launchd-sim.md` §3). `Child` has **31** keys:
the iOS set minus `SIMULATOR_EXTENDED_DISPLAY_PROPERTIES` and
`IPHONE_TVOUT_EXTENDED_PROPERTIES`. Values that differ:

| Variable | Value |
|---|---|
| `SIMULATOR_MODEL_IDENTIFIER`, `SIMULATOR_PRODUCT_CLASS` | `Watch8,3`, `N237b` |
| `SIMULATOR_LEGACY_ASSET_SUFFIX` | "" |
| `SIMULATOR_MAINSCREEN_WIDTH`, `…_HEIGHT`, `…_SCALE`, `…_PITCH` | 416, 496, `2.000000`, `326.000000` |
| `SIMULATOR_RUNTIME_VERSION`, `…_BUILD_VERSION` | 27.0, 24R362 |
| `SIMULATOR_FRAMEBUFFER_FRAMEWORK`, `SIMULATOR_HID_SYSTEM_MANAGER` | host paths under CoreSimulator's `Platforms/watchos/…` (watchOS builds of the two libraries) |
| `SIMULATOR_VERSION_INFO` | "… Runtime: watchOS 27.0 (24R362) - DeviceType: Apple Watch Series 12 (46mm)" |

## 4. How the reference simulator renders

### 4.1 What is shown

`simctl io <dev> screenshot` returns the full 416 × 496 rectangle (no mask
applied; the round-rect outline is the device type's mask PDF). During boot:
backboardd's Apple-logo overlay on black. Then the face; the default face
after a first boot is a large two-colour digital time. Apps run full screen
with the time at top right.

### 4.2 Where the picture is made

As on iOS: apps and Carousel render through Core Animation into
**backboardd**, which owns the SimFramebuffer display ("StartWindowServer:
initial main screen size:{416, 496} scale:2", nativeRotation 0).
**ClockFace** renders the face (its own Metal name) and
**NTKFaceSnapshotService** renders face snapshots. Processes mapping the
SimFramebuffer library: **backboardd, Carousel** and CoreSimulatorBridge;
backboardd alone maps SimulatorHID. backboardd logs "SimDisplay :
unsupported SimColorSpace" once (harmless in the reference).

### 4.3 Metal host names

Per-process names registered: `com.apple.metal.simulator.backboardd` (own
port), the iOS shell group on one port, and **`.ClockFace` with
`.NTKFaceSnapshotService` on one port**; every other process uses the plain
name (`metal-sim-protocol.md` §1.1 fallback). The capabilities file says
`metal` false: that is the MobileGestalt answer apps see, not the simulator
Metal device (the system renders through the simulator Metal host).

### 4.4 Display and framebuffer

`simctl io enumerate`: one display port `com.apple.framebuffer.display`,
416 × 496 `'BGRA'`, 1 664 bytes per row, 835 584 bytes per surface; the
framebuffer server with one screen: id 1, "LCD", `primary`, integrated,
416 × 496, dot pitch 326, preferred UI scale 2, `'BGRA'`, DCI-P3, SDR,
refresh 6000, UI orientation "Ambiguous", a mask URL (the type's PDF) and
the chrome id. Other ports: `com.apple.display.captureservice`, the
accelerator ports `metal` and `iosurface`, `LegacyHID`, and a stream
processor. No rotation feature.

### 4.5 What this means for Ycode

- The iOS framebuffer path suffices; the display is one small screen.
  Idle cost is tiny (about 0.7 % CPU over the whole guest on the Mac): no
  continuous animation at the face.
- The display unique id is generated per device, and the touch service's
  identifier carries it (§5).

## 5. Input

backboardd connects these services (identifiers `0xACEFADE0000000xx`):

| ID | Identifier (`com.apple.SimulatorHID.…`) | Usage page / usage | Properties | iOS 27.1 |
|---|---|---|---|---|
| 00 | `MainScreenButtonsService` | 0x0B / 1 | Built-In, Authenticated | same |
| 01 | **`MainScreenDigitalCrownService`** | **0xFF0B / 1** | Built-In | absent |
| 02 | `ExternalKeyboardService` | 1 / 6 | | same |
| 03 | `PalomaPoseService` | 0xFF00 / 0x72 | Built-In | present, unused |
| 04 | `SelectionStreamService` | 0xFF00 / 0x71 | Built-In | present, unused |
| 05 | `ManipulatorService` | 0xFF00 / 0x6F | Built-In | present, unused |
| 06 | `ScreenTouchService.<display unique id>` | 0x0D / 4 | builtin, authenticated, displayIntegrated | same |

No game-pad and no proximity service (iOS has both). All carry
`DeviceUsagePairs` equal to the primary pair. As on iOS (`hid-input.md`
§1), buttons, keyboard and touch are disconnected about 5 s after
connecting ("dtuhidd-suppressed") and come back on the first Indigo event.

The Mac side (level 3 black box of SimulatorKit's exported builders, our
`watchhid`): `IndigoHIDMessageForDigitalCrownEvent` returns a 192-byte
message whose one 0xA0-byte record has kind **6**, the host timestamp, and
the **rotation delta as a 64-bit float** (the builder's first
floating-point argument; no other argument is used).
`IndigoHIDMessageForWatchGesture` returns a record of kind 1 (the
button/key kind) carrying 0x46 and the builder's **first integer
argument** (the gesture). The guest's `watchgesturesd` vends
`com.apple.WatchGestures.WatchGesturesSimulatorServer`. What backboardd and
Carousel do with crown records, which usage the crown press and the side
button use on watchOS, and the gesture numbering were **not observed**: in
our runs no button, crown or tap changed the screen and nothing was logged
(§9 Q2–Q4). Ycode's crown service follows the usage pair above; its event
payload is open. *Superseded by §5.1:* the crown and the gestures work
(round 0's host load hid them); buttons and touches are suppressed by
dtuhidd.

### 5.1 What the guest does with watch input (round W3a, agent OBS-WATCH2, 2026-10-30)

Reference: Xcode 27.1, a Series 12 (46mm) watch on watchOS 27.0, paired and
idle on the face, driven only from our Mac tools (`watchhid`, `hidsend`:
SimulatorKit's exported builders handed to `SimDeviceLegacyHIDClient`); no
GUI. The guest's own logs (backboardd, Carousel, watchgesturesd, the apps;
debug level switched on in that guest) and `simctl io` screenshots show what
arrived. Level 3, with level 4 names where marked.

**Two input paths, and only one of them answers to Indigo here.** CoreSimulator's
guest daemon `dtuhidd` was running on every boot and had set the notify
state `com.apple.coredevice.dtuhidd.active` to 1 (the host's CoreDevice
connects to every booted simulator). While that state is 1 the SimulatorHID
bundle keeps its **buttons, keyboard and touch** services out of the event
system. An Indigo button, key or touch message makes the bundle log
"Connecting dtuhidd-suppressed service due to IndigoHID event", the event
system logs the service added and removed in the same millisecond, and the
event never reaches backboardd's routing (no sender, no destination, no
UIKit event): home (source 0), lock (1), side (3000), key usage 4 and taps
all had no effect. Setting the notify state to 0 by hand changed nothing.
Device Hub sends those through dtuhidd's own Mach services
(`com.apple.coredevice.feature.remote.hid.{button,digitizer,keyboard,vendordefined}`,
XPC; dtuhidd's strings name `IndigoButtonEvent`, `LegacyHIDUsagePair`),
which this round could not drive without the GUI. **The crown service is
not suppressed, and watch gestures take another route**, so both work
through Indigo:

| Input | Host message (Mac side) | Guest path | Event the apps see | Effect seen |
|---|---|---|---|---|
| Crown rotation | `IndigoHIDMessageForDigitalCrownEvent(double delta)`: one 0xA0 record, kind 6, the delta as a 64-bit float | the bundle dispatches it from `MainScreenDigitalCrownService` (sender `0xACEFADE00000001`); backboardd routes it as a **Scroll** event to the keyboard-focus context (Carousel's main UI on the face; the front app's window otherwise); AttentionAwareness gets a DigitalCrown attention event | UIKit scroll event (type 7, subtypes 200/201); Carousel's wheel handler (`_wheelChanged`) passes it to the active controller's crown handler | face: **positive** delta starts face → **Smart Stack**, **negative** starts face → **Notification Center** (both sprang back when our bursts stopped short of the threshold); app (watch Settings): positive scrolls the list **forward**, negative back; 30 events of +20 went from the top to the end of the list |
| Watch gesture | `IndigoHIDMessageForWatchGesture(uint32 type)`: a record of the button/key kind with field 0x46 and the type | the bundle (`handleGestureType:`) → XPC to watchgesturesd's `com.apple.WatchGestures.WatchGesturesSimulatorServer` → watchgesturesd's own HID service (its own sender ID) dispatches a **GenericGesture** event → backboardd → keyboard focus | GenericGesture UIEvent (type 15) in the focused process | see the numbering below |
| Crown press, side button, Action button (Ultra), touches, keys | button/arbitrary/touch builders | suppressed (above) | none | **open** (§9 Q2, Q3) |

Gesture numbering (`WAGSimulatorGestureType…` in watchgesturesd's log):

| Value | Gesture | HID gesture type | Effect on the face |
|---|---|---|---|
| 0 | double tap | HandTap | Carousel's primary-action interaction: the **Smart Stack opened** |
| 1 | flick | HandFlick | ClockFace's dismiss interaction: the Smart Stack **closed** back to the face |
| 2 | single tap | — | accepted, then "rejected (no receiver)" |
| 3, 4, 5 | none | — | logged as received; no handler |

**Units.** The crown delta has no pixel meaning: 10 events of 0.1 or 1.0
barely moved the face's transition (sequencer offsets of 0.0003), 30 of 20
moved it to 0.0075 and 20 of 50 to 0.014 before it sprang back. The guest
does the detent and acceleration work itself.

**What Ycode must do** (refines W-9, W-10):

- Crown: Ycode's HID bundle dispatches, from its `MainScreenDigitalCrownService`
  (0xFF0B / 1, Built-In), one scroll event per host crown message carrying
  the signed delta unchanged (positive = the direction that scrolls lists
  forward and opens the Smart Stack); the viewer maps scroll wheel and
  trackpad deltas to it with a user-adjustable factor. backboardd and UIKit
  do the routing.
- Gestures: a host message with the gesture number (0 double tap, 1 flick,
  2 single tap); the bundle forwards it to watchgesturesd's
  `WatchGesturesSimulatorServer` (the reference's route), which makes the
  GenericGesture event itself. The XPC message shape between the bundle
  and watchgesturesd was not recorded (it is internal to the reference's
  bundle); Ycode needs it only if it forwards the same way, otherwise its
  bundle can create the GenericGesture event directly (HandTap, HandFlick).
- Buttons and touches: Ycode does not run dtuhidd, so its own bundle never
  suppresses its services; crown press, side button and Action button
  usages stay open until Q2/Q3 are answered (Device Hub with the owner's
  approval, or a dtuhidd client).

### 5.2 Buttons, the Action button and the gesture event (agent OBS-WATCH3, 2026-10-31)

Reference: Xcode 27.1, throwaway watches `ycode-test-watch3-a` (Series 12
46 mm) and `ycode-test-watch3-b` (Ultra 4 49 mm), watchOS 27.0, driven
only by our Mac tools through `SimDeviceLegacyHIDClient`; no GUI. Level 3
unless marked. Notes: `research/notes/obs-watch3-2026-10-31.md`.

**dtuhidd is the only obstacle.** In a test watch where the dtuhidd job was
disabled in the guest's launchd (`launchctl disable
system/com.apple.coredevice.dtuhidd`, then a reboot) the job never starts
(it is demand-launched by its Mach services, which the host's CoreDevice
connects to), the notify state `com.apple.coredevice.dtuhidd.active`
stays 0, the SimulatorHID bundle keeps its buttons, keyboard and touch
services, and Indigo buttons and taps work. §5.1's "suppressed" applies only
while dtuhidd runs.

**Buttons.** `IndigoHIDMessageForButton(source, down/up, target 0x33)`
arrives from the buttons service (`0xACEFADE00000000`) as a Keyboard-type
HID event with the usage pair below; backboardd sends it to the system app
(Carousel):

| Indigo source | Usage page / usage | Carousel's button | Effect |
|---|---|---|---|
| 0 (home) | 0x0C / 0x40 | crown | **crown press**: on the face → the app grid; in an app → the face; held 1.8 s → Siri (presented while held, dismissed at release) |
| 3000 (side) | 0x0C / 0x95 | side ("pill") | tap → **Control Center**; held 2.5 s (held, then "long held") → the power-off / Emergency SOS sheet |
| 1 (lock) | 0x0C / 0x30 | power | toggles the screen off / on |
| 500 | 0x0C / 0x1BA | — | no receiver |
| 2000 | 0x0C / 0x223 | unknown | none |
| 10000 (keyboard) | keyboard page 7, usage 0 | unknown | none |
| any other tried (2–8, 1000, 4000) | a vendor-defined event 0xFF00 / 0x10 | — | none |
| 0x400002 | — | — | **the reference's backboardd crashed** (its HID bundle, making a vendor-defined event); the watch UI restarted |

**The Action button** (Ultra types) has no Indigo source. Level 2: each
watch device type's `profile.plist` names a device chrome
(`chromeIdentifier`), and the chrome's `Contents/Resources/chrome.json`
lists its hardware inputs as `{name, type, usagePage, usage, …}`: every
watch chrome has `digital-crown` (type crown, 0x0C/0x40) and `side-button`
(type button, 0x0C/0x95); the Ultra chromes (`watch4` for Ultra and Ultra 2,
`watch6` for Ultra 3 and Ultra 4) add **`left-side-button`** (type button,
page **0xFF01**, usage **0x200**). Sent with
`IndigoHIDMessageForHIDArbitrary(target 0x33, 0xFF01, 0x200, down/up)`, it
arrives from the buttons service, backboardd names it "Action", and
Carousel handles it as its Action-button key: with no action chosen the
watch shows "Choose what you'd like the Action button to do." with
**Choose Action** and Cancel. (0x0B/0x2D, which backboardd also names
"Action", is unknown to Carousel.) The arbitrary builder's target 0x32 sends
from the touch service instead; backboardd routes a known button pair from
either.

**Watch gestures: the event** (§9 Q15). watchgesturesd dispatches, from a
HID service of its own whose primary page and usage are 0, one
**GenericGesture** event (IOHIDFamily event type **39**) that backboardd
routes to the keyboard focus:

| Field | Double tap (Indigo gesture 0) | Flick (1) |
|---|---|---|
| gesture type, field (39 << 16) + 0 | **2** (HandTap) | **8** (HandFlick) |
| tap count, field (39 << 16) + 1 | **2** | not set |
| phase | Ended | Ended |
| value type | relative | relative |
| event flags | 0x4000000 | 0x4000000 |
| UIKit event in the focused process | type 15, subtype 220 | type 15, subtype 221 |

Single tap (2) is rejected inside watchgesturesd (no receiver) and produces
no event. Other gesture-type values, read from the events' own
descriptions inside the guest (black-box use of the exported constructor):
0 Tap, 1 Swipe, 4 HandTapHold, 5 Squeeze, 6 LongSqueeze, 7 DoubleSqueeze;
3 and 9–12 are unnamed. The XPC message from the bundle to watchgesturesd
was not recorded; it is not needed to make the event.

**What Ycode must do** (refines W-9, W-10; replaces the provisional
buttons of §11.3 and §12.1):

- Ycode runs no dtuhidd; its bundle never suppresses its services.
- **Crown press** = 0x0C/0x40, **side button** = 0x0C/0x95, both from the
  buttons service, down and up as the user presses (the guest measures
  holds: crown held → Siri, side held → the power-off sheet; shorter holds
  than 1.8 s and 2.5 s were not tried). Ycode's host
  messages may keep the Indigo sources 0 and 3000 for them.
- **Action button** = 0xFF01/0x200 from the buttons service, offered only
  on the Ultra types (Ultra, Ultra 2, Ultra 3, Ultra 4); Ycode keeps its own
  per-type table of these inputs (the usage pairs above are interop facts;
  the chrome files are not copied).
- The screen toggle (0x0C/0x30) may be offered as "Lock / wake screen";
  it is not a watch hardware button.
- Unknown sources: ignore them (never crash, unlike the reference with
  0x400002).
- **Gestures**: the bundle makes the GenericGesture event itself (IOHIDFamily's
  constructor with the values above: double tap = type 2 with tap count 2,
  flick = type 8; phase Ended, flags 0x4000000) and dispatches it from one
  of its own services; single tap does nothing, as in the reference.
- Taps on the touch screen need nothing new (they worked once dtuhidd was
  out of the way).

**Ycode implementation** (agent WATCH-W7, 2026-10-31; details in §13):
done as above. One table (`DeviceButtonTable`) gives the pairs for the
viewer, the display stream (new button `action`) and the control socket's
`button crown|side|action|screen [hold-ms]`; the HID bundle dispatches
only a watch's own pairs (the Action button on Ultra types only) and makes
the GenericGesture event itself from a watch-gestures service. Under Ycode
the crown press opens the app grid and returns to the face, the side
button opens Control Center (held 3 s: the power-off sheet), the Ultra's
Action button shows its "Choose Action" sheet, and a double tap runs an
app's primary action (§13.3).

## 6. Boot and run (Mac, level 3, heavy host load)

| Measure | watchOS 27.0, Series 12 46 mm | iOS 27.1, iPhone Duo |
|---|---|---|
| First boot, `bootstatus` terminal | 30.3 s | 28.2 s (this session) |
| Migration | 24 plugins, 12.3 s summed, `success` **true**; slowest `managedconfiguration.migrator` 6.5 s, LaunchServices 4.3 s | `success` false (`first-boot.md`) |
| Repeat boot, terminal | 13.9 s, 15.7 s | – |
| Face in a screenshot | 1.5 s after terminal | – |
| Repeat boot of a paired watch | 18.7 s, 25.2 s (phone up); 20.2 s (phone down) | – |
| First boot after pairing (or after an unpair erased it) | 54.4 s; 163.9 s in a heavily loaded run (`device-pairing.md` §3) | – |
| Processes after boot | 177–178 | 227 |
| Memory (sum of `phys_footprint`) | 5.3 GiB | – |
| Idle CPU (10 s, whole guest) | 0.7 % of a core | – |

`bootstatus` stages: "Waiting on BackBoard" (2 s), "Waiting on Data
Migration", "Waiting on System App" (Carousel), terminal.

**Launches**: our WatchConnectivity app (`device-pairing.md` §5) installed
with `simctl install` on the watch and started with `simctl launch` (launch
times were not measured under the load). Apps listed on the paired watch
before ours was installed: 15 (`simctl listapps`).

## 7. What Ycode must add

### 7.1 Requirements

Identity and boot:

- **W-1** Device types for the thirteen watches of §3.1 (ids like
  `apple-watch-series-12-46mm`): model, class, legacy suffix "", screen,
  scale 2, pitch 326, corner radius, capability answers of §3.3 (Ycode's
  own data), features (crown on all, Action button on Ultra); refused on
  non-watchOS runtimes and vice versa. Family `watch`.
- **W-2** Runtime detection: `ProductName` "Watch OS", build 24R362;
  per-runtime state keyed by build.
- **W-3** Mach-O platform 9 accepted wherever platform 7 is (loader,
  `dyld_sim` handoff, the shared cache map); spawning a platform-4 or arm64e
  executable fails with `EBADARCH` (`powerexperienced`), never a crash.
- **W-4** Bootstrap `Child` without the two extended-display variables
  (§3.4); host library paths are Ycode's own.
- **W-5** Host names in the **`system`** domain (§2.4), the iOS set minus
  `FileProvider.sim2host`, plus optionally the two Metal names of §4.3.
  Re-check 701/702/709 of `launch-sim-control.md` on this runtime.
- **W-6** A watchOS lean-boot list by label if lean boot is used during
  development (parity benchmarks boot everything).

Rendering:

- **W-7** The headless framebuffer library serves backboardd **and
  Carousel**: one display (id 1, `LCD`, `primary`, a per-device unique id,
  416 × 496 for Series 12 46 mm, scale 2, pitch 326, 60 Hz, `'BGRA'`).
- **W-8** The Metal→Vulkan layer runs ClockFace, NTKFaceSnapshotService and
  the complication renderers (WidgetKit snapshots); the viewer draws the
  watch outline from §3.1 radii (Ycode's own artwork).

Input:

- **W-9** Ycode's HID bundle publishes, for watch types, the buttons,
  keyboard and touch services plus `MainScreenDigitalCrownService` (0xFF0B /
  1, Built-In); no game pad, no proximity.
- **W-10** Host messages and viewer mapping for crown rotation (scroll
  wheel / trackpad → signed delta), crown press, side button, Action
  button (Ultra) and watch gestures — after §9 Q2–Q4 are answered.
  *§5.1:* crown rotation and gestures 0–2 are specified there; crown
  press, side and Action buttons remain open. *§12:* the crown service
  (W-9) and crown rotation are done; gestures reach Ycode's bundle but not
  the guest (Q15).

Pairing (`device-pairing.md` §7): **P-1 … P-9**.

### 7.2 Rounds (one agent each)

| Round | Name | Work | Depends on | Done when |
|---|---|---|---|---|
| W0 | WATCH-COPY | copy RR 24R362 and the device-type bundles (§2.6) | — | **done** (this round): tree present, `SystemVersion.plist` 24R362 |
| W1 | **WATCH-BOOT** (done, §10) | W-1…W-6; re-check `dyld_sim` handoff, `launchd_sim` bootstrap and the control channel's domain on this build; 24 migration plugins on the first boot | W0 | DEV has `LastSystemVersion` 24R362 and a LaunchServices store; Carousel, backboardd, ClockFace, nanoregistryd and ids_simd running; powerexperienced refused as in the reference; no Ycode-only crash report |
| W2 | **WATCH-DISPLAY** (done, §11) | W-7, W-8; viewer frame and scale for a 416 × 496 screen; screenshot | W1 | a Ycode screenshot shows the face like §4.1; the face updates each minute; idle CPU measured |
| W3a | WATCH-INPUT-R (dirty side) | answer §9 Q2–Q4 (crown, buttons, gestures) with Device Hub driven only with the owner's approval, or with SimulatorKit's builders from our Mac tool plus a guest-side HID monitor with the entitlement problem of `hid-input.md` solved | — | an input section here with event types, payloads and effects |
| W3b | **WATCH-INPUT** (in part, agent WATCH-W3B, §12) | W-9, W-10 | W2, W3a | crown press opens the app grid; crown rotation scrolls a list in an app; side button shows the dock (or the reference's equivalent). *§12:* crown rotation done (Smart Stack, lists); buttons and gestures open (Q2, Q3, Q15) |
| W4 | **PAIR-HOST** (done, `device-pairing.md` §8) | `device-pairing.md` P-1…P-5: pair records, `ycode-sim pair`/`unpair`/`pair_activate`/`list pairs`, the bridge-equivalent guest agent requests, endpoint registration and removal on peer boot/shutdown | W1 | two Ycode simulators on one host show "(active, connected)"; both nanoregistryd logs "State change … [CREATED]"; unpair erases the watch |
| W5 | **PAIR-RELAY** (done, `device-pairing.md` §10) | P-6, P-7: the cross-VM relay of `com.apple.IDSSimRPC.remote.*` (MIG 1000/1100, one OOL region, send-once replies, dead-name on peer exit) | W4 | WCProbe traffic both ways under Ycode; `isReachable` true on the watch; message round trip measured |
| W6 | **PAIR-IDE** | P-8, P-9: Devices window and Device Hub pair UI, watch run destinations, installing the embedded watch app | W4 (W5 for the end-to-end test) | the IDE creates a pair, shows "Paired with …", runs a watch app on the paired watch |

W1 and W3a can run in parallel; W4 needs only a watch that boots (no
display). W3a and any further reference observation are dirty-room work and
must not be given to a clean agent.

### 7.3 Risks

1. **The pairing relay is new kind of work**: a Mach port that lives in
   another VM (`device-pairing.md` §7.3).
2. **First paired boot** took 54 s on the reference (164 s in a loaded
   run with a 145 s stall in nanoregistryd). Under Ycode it may be minutes more; the
   W4 done-criterion must allow it.
3. **System domain** registration (§2.4): if Ycode's control-channel
   operations only work in `user/<uid>`, the watch's jobs will not see the
   host names.
4. **Input formats unknown** (crown, gestures) until W3a.
5. **Platform 9** checks spread through the loader and kernel code paths
   written for platform 7.

Not risks: arm64_32 (absent), new GPU features (the face is simple), memory
(5.3 GiB summed on the Mac; half of iOS's process count).

## 8. IDE notes

Run destinations for watchOS: watch simulators by name (and, in the
reference, paired destinations: `device-pairing.md` §6). Build with the
`watchsimulator` SDK (platform `WatchSimulator`, triple
`arm64-apple-watchos27.0-simulator`; our probe built and ran with it);
`UIDeviceFamily` [4]; a single-target watch app carries `WKApplication`
true and `WKCompanionAppBundleIdentifier`. The Devices window and Device
Hub show watch simulators with Ycode's own round-rect outline.
*Since W6 (`device-pairing.md` §13):* Ycode's watches are run
destinations of watchOS schemes, and so is each Ycode iPhone with an active
paired watch; watch apps are installed and opened through the pairing
agent (`specs/ide/run.md` §Watch apps).

## 9. Open questions

1. The cause of the 145 s stall in one first paired boot (load is
   likely; `device-pairing.md` §9 Q1).
2. Crown: what backboardd/Carousel receive from
   `MainScreenDigitalCrownService` (event type, fields, units of the delta,
   detents), and how a crown **press** is sent (which button source or
   usage).
   **Rotation answered (§5.1)**: a Scroll event to the keyboard focus, the
   signed delta unchanged, detents in the guest. **Press open**: buttons go
   through dtuhidd in Xcode 27.1, which was not driven.
   **Press answered (§5.2)**: Indigo button source 0, usage 0x0C/0x40 from
   the buttons service; app grid from the face, face from an app, Siri
   when held.
3. Side button and Action button: sources/usages and effects on watchOS
   (Home, Lock and Side sources 0, 1, 3000 changed nothing in our runs).
   **Still open (§5.1)**: the legacy button path is suppressed while
   dtuhidd is active, which it always was; needs Device Hub (owner's
   approval) or a dtuhidd client.
   **Answered (§5.2)** with dtuhidd kept from starting in a test watch: side
   = source 3000, 0x0C/0x95 (Control Center; held: power-off sheet);
   Action (Ultra types only) = 0xFF01/0x200, no Indigo source (the device
   chrome's `left-side-button`); source 1 (0x0C/0x30) toggles the screen.
4. Watch gestures: the numbering of `IndigoHIDMessageForWatchGesture`'s
   argument and what `watchgesturesd` does with it; wrist-down and
   always-on dimming (`display.aot`) controls in Device Hub.
   **Numbering answered (§5.1)**: 0 double tap, 1 flick, 2 single tap,
   3–5 unused. Wrist-down and always-on controls still open (GUI).
   *Under Ycode (§12):* the numbering reaches Ycode's bundle; the route on
   to the guest is Q15.
5. The app grid and the dock: their processes and first-boot layout files
   (not reached without crown input).
6. Whether Carousel uses the SimFramebuffer library for anything other than
   a query (it maps it). *Under Ycode (§11.1):* Carousel connects, copies
   the display list, reads the display's type and sets its brightness
   factor (seven calls in a boot); it makes no swapchain.
7. Lean-boot candidates on watchOS (what can be left out for development).
   *Partly answered (§10.5, Ycode decision):* the iOS list minus the pairing
   daemons; it saved nothing measurable under Ycode, because the face waits
   for datamigrator, not for background jobs (Q12).
8. *(W1)* `main-screen-orientation` of the types other than Series 12 46 mm
   (Ycode writes 3π/2 where the display's `nativeRotation` is 90, 0
   elsewhere), and `memoryClass`, `graphicsFeatureSetClass`, `ModelNumber`
   and `CompatibleDeviceFallback` per type (Ycode: 3/APPLE11 on the 27.0
   generation, 2/APPLE8 on the others; the rest only for Series 12 46 mm).
   *(W2, §11.1)* Under Ycode the face draws upright at the type's size with
   either value (SE 3 40 mm: 0, 324 × 394; Ultra 4: 3π/2, 422 × 514), so
   the picture does not decide it; the reference's value is still open.
9. *(W1)* Does a new reference device have `DEV/data/Library/Caches` before
   its first boot? Under Ycode the first nanoregistryd spawn of a new
   device fails ("Unable to set current working directory", exit 78) and
   launchd retries it 10 s later (§10.3).
10. *(W1)* What demands `powerexperienced` in the reference, which fails to
    spawn it every boot? Under Ycode no client asked for it in a 10-minute
    first boot; a `launchctl kickstart` fails exactly as §2.4 says (§10.2).
11. *(W1)* Does `AppIntentsLiveEntityService` stop in the reference with the
    runtime's own fatal error "XPC Peer Requirement isn't implemented on
    simulators yet"? Under Ycode it does on most repeat boots (also seen in
    Ycode's iOS boots).
12. *(W1)* How long does datamigrator run on a **repeat** boot in the
    reference, and does backboardd (or Carousel) hold the face until it
    exits? Under Ycode it runs 14–16 s on every repeat boot, and ClockFace
    starts within about 1 s of its exit (§10.4). *(W2, §11.4)* The 10 s
    from ClockFace's start to the face are ClockFace's own start-up work.
13. *(W2)* Which process makes the two **compute pipelines with a stage
    input** (`air.stage_in` in a kernel; compute pipeline descriptor keys 2
    and 3, first values 13 and 16, not modelled by Ycode's Metal host) on a
    first boot, and what keys 2 and 3 carry (the stage-input descriptor:
    attributes and layouts?). Ycode's translator refuses them
    ("unsupported-feature: argument kind air.stage_in"); nothing visible
    failed (§11.2). Needs the descriptor's wire format (dirty room).
14. *(W2)* Is `apsd` busy in an idle reference watch? Under Ycode it uses
    about a quarter of a core all the time and diagnosticd a tenth
    (§11.5); the host service `com.apple.CoreSimulator.SimIdentityService`,
    which apsd asks for (`launchd-sim.md`), is one Ycode does not provide.
15. *(W3b)* How a watch gesture reaches the guest: the message the
    reference's HID bundle sends to watchgesturesd's
    `com.apple.WatchGestures.WatchGesturesSimulatorServer` (XPC keys and
    values), or the GenericGesture event watchgesturesd dispatches (the HID
    gesture-type values of HandTap and HandFlick, and any other fields), so
    that Ycode's bundle can send either (§12.2).
    **Answered (§5.2)**: GenericGesture, event type 39; field 0 the gesture
    type (HandTap 2, HandFlick 8), field 1 the tap count (2 for a double
    tap); phase Ended, flags 0x4000000. The XPC message was not recorded
    (not needed).
16. *(W3b)* Which axis of the scroll event carries the crown's delta in the
    reference (Ycode chose y, which works, §12.2), and whether the event
    carries anything else (a flag, a phase) that changes how far the guest
    moves per event (§12.3: Ycode's list moved further per event than
    §5.1's).
    *Still open (§5.2)*: no guest log we enabled prints the scroll event's
    fields.

## 10. Round W1 under Ycode (agent WATCH-BOOT, 2026-10-29)

Clean-room implementation notes and Ycode boot results (level 3: Ycode's
own simulator on the Thor with the copied 24R362 runtime; `launchd.log`
from TMP, one-shot `launchctl` runs, Ycode's frame record). No Apple
simulator, Xcode or reference tool was run or opened for this round.

### 10.1 What `ycode-simd` does for a watchOS runtime

- **Device types (W-1).** The thirteen types of §3.1, ids as in W-1
  (`apple-watch-series-12-46mm` … `apple-watch-se-3-40mm`;
  `ycode-simd --list-device-types`), family `watch`, platform watchOS, with
  the §3.1 model, class, screen (scale 2, pitch 326), corner radius,
  oldest runtime and the §3.3 capability values (`WatchDeviceTypes.swift`).
  **Ycode decisions** where §3 gives one type's value or a selection: the
  27.0 generation (Series 12, Ultra 4) has `memoryClass` 3 and APPLE11,
  the others 2 and APPLE8; `main-screen-orientation` is 3π/2 where the
  display's `nativeRotation` is 90 (Series 12, Ultra 4, Ultra 3, Ultra 2)
  and 0 elsewhere; `ModelNumber` and `CompatibleDeviceFallback` are written
  only for Series 12 46 mm; the software keys every other record has
  (accessibility, application installation, international settings) are
  true; `displays` is kept in the record for W2 but not written (as for
  every type without a second display). Each type also records its
  hardware features (§3.2: always-on display, Digital Crown, touch screen;
  the Action button on the three Ultras) for W-9. A watch type on an iOS or
  visionOS runtime, and any other type on a watchOS runtime, is refused
  before anything is written. The default on watchOS is Series 12 46 mm
  (on an older runtime: the first §3.1 type that runs on it).
- **Runtime detection (W-2).** `ProductName` "Watch OS" (with the space;
  "watchOS" is not taken) makes a runtime a watchOS runtime: Mach-O
  platform 9, `proc_info` platform 9, Ycode's guest images (host
  libraries, framebuffer library, HID bundle, settings agent) retagged to
  platform 9 as for visionOS (`GuestImagePlatform.swift`). Per-runtime
  state keeps the two-word name (`DEV/ycode-runtime`: "Watch OS 27.0
  24R362"), and the snapshot fingerprint already includes `ProductName`
  and the build.
- **Platform 9 and `EBADARCH` (W-3).** The kernel's spawn check already
  took platforms 7, 8, 9 and 12; the image launcher's second check took
  only 7 and 12 and would have refused every watchOS executable. Both now
  use one rule (`MachOImage.isRunnableInSimulator`): plain arm64 (subtype
  ALL or V8) for a simulator platform. A fat file's plain arm64 slice is
  taken over an arm64e one; arm64e alone, or a device platform, is
  `EBADARCH` (the guest CPU has no pointer authentication,
  `cpu-features.md`). dyld_sim, the shared cache and `dyld-sim-handoff.md`
  needed no change: the platform checks of the cache and images are
  dyld_sim's own, in the guest.
- **Bootstrap (W-4).** `Child` is the iOS set minus
  `SIMULATOR_EXTENDED_DISPLAY_PROPERTIES` and
  `IPHONE_TVOUT_EXTENDED_PROPERTIES` (no variable added);
  `SIMULATOR_VERSION_INFO` names "watchOS 27.0 (24R362)"; the host library
  paths are Ycode's own.
- **Host names (W-5).** No change was needed: Ycode never registered
  `FileProvider.sim2host`, and its 701s land in the `system` domain on this
  runtime (§10.2).
- **Lean boot (W-6).** `YCODE_LEAN_BOOT` on a watchOS runtime uses the iOS
  list minus `nanoregistrylaunchd` and `pairedsyncd` (the pairing path);
  21 labels (**Ycode decision**, development only; parity runs boot
  everything).
- **Diagnostics.** `YCODE_CONTROL_CHECK=1` (or `=name,name`) runs, after the
  registrations, 702 on a host name and the given guest names, 703 on an
  unset variable, and 701 → 702 → 709 → 702 → 709 on a test name, one log
  line each.

### 10.2 The control channel and the domain (risk 3)

On this runtime `launchd_sim` puts everything Ycode asks for into the
**`system`** domain; no code path of Ycode's had to change:

| Operation | Result under Ycode on watchOS 27.0 |
|---|---|
| 700 bind | as on iOS; `system` jobs start at the bind |
| 701 register (7 names: configd, configd_host, IOSurface.Remote, metal.simulator, PowerManagement.control, audiohald, FSEvents) | all succeed; `launchctl print system` shows them as `host-side` dynamic endpoints of `com.apple.xpc.launchd.simhost` in **`system`**; guest look-ups find them (backboardd, Carousel and ClockFace use `com.apple.metal.simulator` and `IOSurface.Remote`) |
| 702 find | finds a host-side endpoint and the `MachServices` name of a `system` job (`com.apple.powerexperienced.powermodes`); `com.apple.PurpleSystemAppPort` is not found (3) |
| 703 getenv (unset variable) | 3 ("not set"), as on iOS: the snapshot-restore liveness probe works |
| 701 → 702 → 709 → 702 → 709 (test name) | ok, found, ok, 3, 3 |
| 704 spawn / 705 waitpid | work; the one-shot job is created in **`system`** (`system/com.apple.xpc.launchd.oneshot.0x1000000N.<name>`) |

The per-process Metal names (`…backboardd`, `…Carousel`, **`…ClockFace`**,
**`…NTKFaceSnapshotService`**, chronod, nanotimekitd, widget extensions)
are looked up, not found, and each process falls back to the plain name
(`metal-sim-protocol.md` §1.1), as on iOS; the optional names of W-5 were
not needed for the face.

**powerexperienced.** In a 10-minute first boot nothing demanded it
(on-demand job, never spawned; §9 Q10). Asked for with `launchctl kickstart
-p system/com.apple.powerexperienced`, launchd_sim logs "Could not find
and/or execute program specified by service: 86: Bad CPU type in
executable", "posix_spawn(…) EBADARCH", exit 78, "will not launch until it
fires" (no retry), and the boot carries on. A 704 spawn of the same file
fails with 111. No Ycode crash, no guest fault.

### 10.3 What a boot reaches (done-criterion)

| Criterion | Result |
|---|---|
| `LastSystemVersion` 24R362 | yes: `com.apple.migration.plist` has `LastSystemVersion` 24R362, `DMLastMigrationResults` {24R362, success **true**}, **24** plugin results (as §6); `-0LaunchServicesMigrator` 10.9 s, `addressbook.migrator` 4.1 s, `appleaccount.migrator` 3.6 s, the others under 3 s |
| LaunchServices store | yes: `DEV/data/var/db/lsd/com.apple.LaunchServices-33554481-v2.csstore` (3.8 MB) and its `SystemDataOnly-` twin, written 30 s into the first boot |
| Carousel, backboardd, ClockFace, nanoregistryd, ids_simd running | yes (`launchctl list` one-shot, 420 s into the first boot and 150 s into a repeat boot), with gizmoappd, nanotimekitd, watchgesturesd, nanoregistrylaunchd and NTKFaceSnapshotService; 134 jobs with a pid (124 on a repeat boot) |
| powerexperienced refused as in the reference | yes (§10.2) |
| No Ycode-only crash report | no crash report in `DEV/data/Library/Logs` and no `ycode-simd` crash in 6 watch boots (every one exited 0); guest faults: none in the two first boots; `AppIntentsLiveEntityService` stops with the runtime's own Swift fatal error "XPC Peer Requirement isn't implemented on simulators yet" (exit 70, twice per boot) in 2 of 4 repeat boots — the same fault appears in Ycode's iOS boots (§9 Q11) |
| Face (not required in W1) | **the face draws**: the 416 × 496 frame record shows backboardd's logo during migration, then the default face (a large two-colour digital time, in UTC), which changes each minute (§4.1) |

Other first-boot log lines worth knowing: nanoregistryd's first spawn on a
new device fails because `DEV/data/Library/Caches` does not exist yet (exit
78; up 10 s later; §9 Q9). `tipsd`, `nanophotosd` and `resourcegrabberd`
have launchd plists but no executables in the runtime (exit 78, "Invalid or
missing Program"); this is the runtime's content, not Ycode's.

### 10.4 Boot times (Thor, `timed.sh`: load 1.0–1.7 at the start, no other simulator running)

Seconds from `ycode-simd`'s start (`launchd.log` UTC times against the
start time; frames every 2 s from the frame record):

| Milestone | Cold first boot (new device) | Repeat boots (same device) |
|---|---|---|
| launchd_sim "hello" | 0.6 | 0.5, 0.5 |
| Carousel, backboardd spawned | 0.8 | 0.8, 0.8 |
| ids_simd up | 2.7 | 2.1, 2.1 |
| nanoregistryd up | 11.6 (first spawn fails, §10.3) | 1.3, 1.3 |
| datamigrator exits | 28.5 | 18.3, 17.0 |
| ClockFace spawned | 29.0 | 17.6, 18.4 |
| **first face frame** | **40** | **28, 28** |
| Peak RSS of `ycode-simd` | 15.0 GiB | 11.3, 11.1 GiB |

Reference (§6, Mac under heavy load): first boot 30.3 s to `bootstatus`
terminal, repeat 13.9–15.7 s, the face 1.5 s after terminal, so about 32 s
and 15–17 s to the face. Ycode is about 1.25× the reference on a first boot
and about 1.6–1.9× on a repeat boot. On a repeat boot datamigrator is
alive for 15 s although nothing needs migrating, and ClockFace started
within about 1 s of its exit in the timed runs (whether one waits for the
other is §9 Q12; under load the two drift apart); then come 10 s between
ClockFace's start and its first frame (its Metal pipelines through the
translator, with a warm GPU cache). A lean boot (§10.1) gave
the face at 30 s: the background jobs are not the bottleneck.

Earlier boots under load (Thor load 110–130): first boot face at 80 s
(frames every 20 s), ClockFace at 50 s.

### 10.5 Other runtimes after these changes

| Boot | Result |
|---|---|
| iOS 27.1, iPhone 18 Pro (a device first booted on 27.1) | home screen at 197 s (run beside the visionOS boot and a debug test build); the end frame is the home screen; guest faults: PosterBoard once (seen in earlier Ycode iOS runs) |
| visionOS 27.0, Apple Vision Pro | the room with the home view in the end frame; guest faults: intelligencetasksd (8, seen before) |

No `EBADARCH` spawn failure appeared in either log. After merging the
main line (with `--macos`), a repeat watch boot (Thor load 29) still
reached the face at 54 s with Carousel, backboardd, ClockFace,
nanoregistryd and ids_simd running.

### 10.6 What remains for W2, W4 and W5

- **W2 (display).** The iOS framebuffer path already serves the watch: the
  face is drawn and updates (§10.3). Left for W2: the viewer's frame and
  scale for 416 × 496 and the round-rect outline from §3.1 radii (the
  `displays` entry and `features` are in the type records), whether
  `main-screen-orientation` 3π/2 is right for the other types (§9 Q8), the
  10 s from ClockFace's start to its first frame, idle CPU, and a
  screenshot test.
- **W4 (pairing, host side).** Not blocked: 701, 702 and 709 work in
  `system` (§10.2), so `com.apple.IDSSimRPC.remote.<peer>` can be
  registered and removed in the watch's domain with the same
  `LaunchSimControl` calls as on iOS (in `user/501` there). One-shots also
  run in `system`, so a Ycode guest agent can be started the same way.
  nanoregistryd and ids_simd run; the lean list keeps them. Still to
  build: pair records, the CLI, the guest agent and its entitlement
  (`device-pairing.md` P-1 … P-5).
- **W5 (relay).** Nothing in W1 bears on it; it needs W4.
- **Speed round.** datamigrator on repeat boots (§9 Q12) and nanoregistryd's
  first spawn (§9 Q9).

## 11. Round W2 under Ycode (agent WATCH-DISPLAY, 2026-10-29)

Clean-room implementation notes and measurements (level 3: Ycode's own
simulator on the Thor with the copied 24R362 runtime, Ycode's own windows
on the Mac captured with `screencapture -l` of their window ids). No Apple
simulator, Xcode, Device Hub or reference tool was run, opened or
observed for this round. Runs: `work/ide-remote/watch-display/runs/`
(d1 a cold first boot, d2–d5 repeat boots of the same Series 12 46 mm
device, d6 SE 3 40 mm and d7 Ultra 4 cold first boots). A second agent
(WATCH-DISPLAY2, 2026-10-30) checked the round again after merging the
main line: r1, a cold first boot of a new Series 12 46 mm device (960 s,
Ycode's viewer connected at 630–645 s), and r2, a repeat boot of it
(420 s); the Thor's load was 3.7 at r1's start and 25–45 during both
(other agents' boots).

### 11.1 The display (W-7)

Ycode's headless framebuffer library already served the watch from W1
(§10.3). Checked against W-7 with its call log (`YCODE_FRAMEBUFFER_CALLS=1`)
and the frame record:

| W-7 item | Under Ycode |
|---|---|
| one display, id 1, `LCD` / `primary`, built-in | yes; with no second display the library publishes display 1 only |
| size per type, scale 2, pitch 326 | from `SIMULATOR_MAINSCREEN_*` (W1's type records): 416 × 496 (Series 12 46 mm), 324 × 394 (SE 3 40 mm), 422 × 514 (Ultra 4); frames of those sizes, the face upright on all three |
| 60 Hz, `'BGRA'` | the mode record's refresh 6000 and `'BGRA'` |
| a unique id per device | **changed this round**: a watch's display 1 has an id derived from the device's UDID (`DeviceLayout.displayUID`: stable across boots, different per device, first group `59434F44`); the HID bundle's touch service reads it from the display as before. The iOS types keep the library's constant (**Ycode decision**: their saved devices and snapshots stay as they are); the Vision Pro keeps its fixed id |
| backboardd and Carousel | backboardd: connect, copy displays, name, device name, unique id, dot pitch, device size, current mode, canvas size, one swapchain, every swap. Carousel: connect, copy displays, display type, `SetBrightnessFactor` (seven calls in a boot), no swapchain (§9 Q6) |

`main-screen-orientation` (§9 Q8): the SE 3 40 mm (0) and the Ultra 4
(3π/2) both show the face upright at their own size; the value is kept as
W1 wrote it.

### 11.2 Metal on Vulkan (W-8)

`YCODE_METAL_STATS` in a repeat boot (d2, 420 s): 12 Metal client
processes, 517 submissions, all completed, **0 backend errors**; 1 525
render and 9 compute pipelines, none broken.

| Process | Submissions (420 s) | Note |
|---|---|---|
| backboardd | 107 | composites the face (one swap a minute) |
| NTKFaceSnapshotService | 202 | face snapshots |
| iconservicesagent | 161 | icons, early |
| WidgetRenderer_Snapshots | 46 | complication (WidgetKit) snapshots |
| Carousel | 1 | |
| ClockFace | 0 | connects to the plain Metal name and submits nothing: its face is Core Animation layers that backboardd draws |

No Metal op or host name was missing for these processes (the
per-process names of §4.3 fall back to the plain name, §10.2). A cold
first boot (d1) with a GPU cache from before W1 compiled one render
pipeline (`com.apple.coreanimation.PBGRA_Xgc`) in 10.4 s once (cached
afterwards), and refused two **compute pipelines with a stage input**
("ycode-airc: unsupported-feature: argument kind air.stage_in"; compute
descriptor keys 2 and 3 not modelled), 70–80 s into the boot; nothing on
the screen or in the summaries failed. What makes them and the
descriptor's stage-input keys are §9 Q13 (needs the wire format; not
built).

Rechecked (r2, repeat boot, `YCODE_METAL_STATS=5`, 420 s): the same 12
clients, 370 submissions, all completed, **0 backend errors**, 1 515 render
and 1 compute pipelines, none broken (backboardd 91, iconservicesagent 161,
WidgetRenderer_Snapshots 100, NTKFaceSnapshotService 17, Carousel 1,
ClockFace 0; the per-process counts vary from boot to boot). The cold
first boot r1 refused the same two compute pipelines with a stage input,
and nothing else.

**Other faces.** The default face is the only one reached: choosing a face
needs input (a long press on the face) or the face library's file format;
both are W3's. The crown press of §11.3 opens the app grid and returns to
the face.

### 11.3 Viewer and IDE

- **Frames** (`YcodeDeviceModel`): the thirteen watch types in
  `DeviceFrameSpec` (ids, models, screen pixels at scale 2, 326 pixels per
  inch, the §3.1 corner radius on all four corners, the Action button on
  the Ultras) and the family `watch`. `DeviceFrameGeometry` draws a watch
  (**Ycode decision**, Ycode's own artwork, the `device-hub.md` §4.3 rule:
  a band of even width, outer corners concentric with the screen's): a
  16-point band, body radii = screen radius + 16; the **Digital Crown** a
  rounded cylinder 8 points out of the right edge at 22–37 % of the body's
  height, drawn with ridges across it; the **side button** a 3-point bar
  on the right edge at 47–71 %; on an Ultra the Action button on the left
  edge at 30–43 %. Series 12 46 mm: 256 × 296 points with the frame, the
  screen 208 × 248 at its centre.
- **Buttons**: crown → the stream's `home`, side button → `lock`, Ultra
  Action → `side` (**Ycode decision until W3**, §9 Q2–Q3). Under Ycode a
  crown click opens the app grid and a second click returns to the face
  (d4, d5).
- **Control row**: [Screenshot · Record] (no Home: the crown is the
  watch's Home; no Rotate: no rotation feature, §2.2). Volume Up / Down
  and App Switcher are hidden in the menus and refused; Action Button is
  offered on the Ultras. Show / Hide Bezels leaves the screen with its
  rounded corners; zoom (fit, steps, Physical Size: one point is
  2 ÷ 326 inch) as for the other families.
- **Compact window**: the device fills the width less 17 points a side;
  the default is the minimum width (340 points: the watch at 1.195 points
  a device point, a 340 × 465 window). **Fixed this round**: a window
  opened before the hello (the viewer's) kept the default phone's scale
  when the hello named a watch (218 points wide); a device type named by
  the hello now opens at its own saved or default scale, and no reshape
  goes below the minimum width. **Fixed in the recheck**: hiding the
  bezels at the minimum width (the screen alone is 283 points at that
  scale, so the window stays at 340) and showing them again left the
  watch at the larger scale (411 points wide); the window now keeps the
  scale the user chose through a shape change (bezels, rotation), so the
  round trip returns to 340 × 465. And an expanded window opened from a
  saved size smaller than the expanded minimum (219 points, saved by an
  older build) is raised to the minimum (420 × 420), so the zoom controls
  stay in the toolbar.
- **Screenshot** (⇧⌘S, the control): "Screenshot Saved", a 416 × 496 PNG
  "Screenshot Apple Watch Series 12 (46mm) <time>.png" (the server's
  full-resolution picture).
- **Sidebar**: a neutral **wrist-watch glyph** (a rounded face, a short
  strap above and below, a small knob; Ycode's own template image, no
  product symbol), lit while running. Rows of other simulators whose
  platform is watchOS or whose name says "Watch" get it and a watch-sized
  placeholder frame.
- **Ycode's watches in Device Hub**: the IDE reads a runtime root's
  platform with its version (`SystemVersion.plist` `ProductName` "Watch
  OS"; else "watchOS" in the path). A watchOS root gives **no run
  destination** (*until W6: since `device-pairing.md` §13 its watches are
  run destinations of watchOS schemes*) **and no preview device** (Ycode's runs build for the iOS
  simulator; watch destinations are W6); Device Hub lists the watch types
  the runtime creates by default (**Ycode decision** from §3.1's "default
  create" column: on 27.0 Series 12 46 and 42 mm, Ultra 4, SE 3 44 and
  40 mm), each with its own device directory, platform watchOS, and Start
  with `--device-type`.

### 11.4 ClockFace's 10 s (§9 Q12)

Repeat boots (d2, Thor load about 1 at the start): datamigrator exits at
16.0 s, ClockFace is spawned at 18.5 s, the first face frame is at 28 s
(frames every 2 s); cold first boot (d1, load falling from 61): 63.6 s and
75 s. The 9.5 s between are ClockFace's own start-up, CPU-bound:

| Measure (boot profile, `YCODE_BOOT_PROFILE`) | Value |
|---|---|
| Whole device, 18.5–28 s | 4.05 cores busy of 14; ClockFace 1.26 cores (12.0 core-seconds), nanotimekitd 0.59, BundleComplicationMigrationService 0.17, Carousel 0.14 |
| ClockFace's first 57 s (d3, load 17) | CPU 14.5 s: guest code 8.95 s (62 %), VMM trap handling 3.3 s (23 %), host kernel 2.1 s (15 %); 274 k exits to the VMM; 3.8 s runnable but waiting for a host CPU; libSystem milestone 1.4 s after launch |
| Where its guest time goes (PC samples, 100 Hz) | about half in `dyld_sim` (the just-in-time loader of `boot-profile.md` §5: the loader's own algorithm at native speed), then libswiftCore |
| Metal | none: ClockFace submits no GPU work; no pipeline is compiled for it on a repeat boot |

Rechecked with the timing ring (`YCODE_DISPLAY_TIMING`, guest ticks
placed on the host clock with the display trace's `sync` lines), from
ClockFace's spawn (`launchd.log`) to the first swap of the face's
appearing animation:

| Boot | ClockFace spawned | First face swap | ClockFace's time to first frame |
|---|---|---|---|
| d2 repeat (load about 1) | 18.5 s | 28 s (frames every 2 s) | 9.5 s |
| r2 repeat (load 36–44) | 22.8 s (datamigrator exits at 21.0 s) | 31.9 s | **9.1 s** |
| d1 cold first (load falling from 61) | 63.6 s | 75 s (frames) | 11.4 s |
| r1 cold first (load 25–31) | 72.3 s (datamigrator exits at 56.6 s) | 82.4 s | **10.1 s** |

So the delay is ClockFace loading its code (bundles through `dyld_sim`)
and setting up, not the display path or the translator. Ycode's share is
the trap handling (about a quarter of ClockFace's CPU), which is the
general cost of traps (`boot-profile.md`), nothing watch-specific; no
change was made this round. The face itself appears with a 48-frame
animation in 0.76 s (62 fps). The lever that would hide the 10 s is
starting ClockFace before datamigrator ends, which depends on §9 Q12.

### 11.5 Idle CPU, frame rate, minute updates

| Measure | Value |
|---|---|
| Face updates (timing ring `YCODE_DISPLAY_TIMING`: d4 15 minutes, d5 14 minutes) | one presented swap a minute, 60.0 s apart (±0.03 s; one 1.9 s late in d4), each a single swap; the minute digits change in the frames (d1, d4, d5) |
| Frame rate while the face animates | 55–62 fps (the face appearing: 48 swaps in 0.76 s, 44 in 0.78 s); the crown presses with a viewer connected: 50–51 swaps a second (133 in 2.6 s, 110 in 2.1 s) and one burst of 134 swaps in 1.5 s (87 a second: swaps are not held to 60 Hz) |
| Idle CPU of `ycode-simd` (d4, 120–600 s after start, no viewer) | **0.62 of a core** (`/proc` utime + stime; 0.61–0.65 in 3-minute windows; 0.67 at 700–990 s); RSS 11.0 GiB |
| Who uses it (d2 boot profile, 120–240 and 300–418 s) | apsd 0.23–0.26 cores, diagnosticd 0.10–0.12, NTKFaceSnapshotService 0.02–0.03, trustd, WidgetRenderer_Snapshots, ClockFace, securityd, logd about 0.01 each; split guest 0.25, host kernel 0.17, VMM 0.27–0.32 cores |
| Reference (§6, Mac under heavy load) | 0.7 % of a core for the whole guest |

Rechecked in r1 (cold first boot, 960 s):

| Measure | Value |
|---|---|
| Face updates | 14 single presented swaps from 130 s to 910 s, **60.0 s apart (59.98–60.01 s)**, the viewer's session in between included; the frames show 8:02, 8:03, 8:04 and 8:05 between 90 and 300 s (UTC, 12-hour face) |
| Idle CPU of `ycode-simd` (no viewer) | **0.645 of a core** over 150–625 s (3-minute windows 0.69, 0.62, 0.62); 0.64 at 680–955 s after the viewer left; 0.85 at 82–150 s, just after the face appeared; RSS 14.0 GiB (a cold first boot; peak 15.0 GiB) |
| Frame rate while the face animates | the face appearing: 44 swaps in 0.77 s (**55.8 fps**; r2: 48 in 0.76 s, **62.1 fps**); a crown press to the app grid: 106 swaps in 1.98 s (53.1 fps); back to the face: 124 in 1.52 s (81 a second, not held to 60 Hz) |
| Ycode's viewer (Mac, the display socket forwarded over ssh, JPEG) | received 19–20 fps of those animations; crown press to the first change on the Mac 46–69 ms |

The face itself costs almost nothing (one swap a minute). The difference
from the reference is apsd's and diagnosticd's constant activity (§9 Q14)
and the VMM's share of their traps.

### 11.6 Tests

`WatchFrameTests` (YcodeDeviceModel: the thirteen specs, the hello's
match, the frame's body, crown, side and Action buttons, every type's
radii, bezels off, compact window and zoom sizes, the watch family),
`WatchWindowTests` (YcodeDeviceUI: hello, compact window size and
aspect, a window opened before the hello, the expanded form, the row,
the hub canvas's commands and zoom, crown and side-button hits and their
stream buttons, the Ultra, the glyph), `WatchHubTests` (YcodeUI: watch
types per runtime version, hub targets without run destinations or
previews, rows, `ProductName` and the per-root platform in scratch
preferences), `WatchDeviceTypeTests.watchEnvironment` (the per-device
display id). `swift build && swift test` on the Mac and on x86 Linux;
lint clean.

Recheck (2026-10-30, after the merge): `WatchWindowTests` also covers the
bezel round trip at the minimum width and the expanded window opened from
a too-small saved size. Mac: 1 190 tests, all passing except two that ran
out of time under other agents' load and passed alone
(`LanguageWindowTests`, `DebuggerDepthTests`); `MacPayloadPreviewTests`
was skipped in the full run because it hangs there in
`MacPreviewHostProcess.terminateAll` (`waitUntilExit` on a host that has
already gone; another branch's run hung the same way) and passes alone.
x86 Linux: 1 172 tests, 0 failures. Thor debug suites
(`YCODE_LOCK_ORDER_CHECK=1 YCODE_IPC_LOCKS_TESTS=1`, the branch changes
`ycode-simd`): 1 176 tests, 0 failures. Lint: 0 violations.

### 11.7 What remains for W3

- The crown's rotation, its press as the reference sends it, the side and
  Action buttons, watch gestures (§9 Q2–Q4); the frame's crown and side
  button are mapped provisionally (§11.3), and the crown press already
  opens the app grid under Ycode.
- Choosing other faces (long press, swipe) and an animated face for a
  sustained frame-rate measure (an analog face's seconds hand).
- §9 Q13 (compute stage input) if an app or complication needs it, and
  §9 Q14 (apsd, diagnosticd) in a speed round.

## 12. Round W3b under Ycode (agent WATCH-W3B, 2026-10-30)

Clean-room implementation of the input that §5.1 specifies: W-9 for the
Digital Crown and W-10 for crown rotation. Evidence is level 3: Ycode's own
simulator on the arm64 Linux host (Series 12 46 mm, watchOS 27.0 24R362,
paired with an iPhone 18 Pro on iOS 27.0), Ycode's frame captures
(`--control screenshot`), the HID bundle's log and our own watch app's log.
No Apple simulator, Xcode or reference tool was run or opened for this
round.

### 12.1 What was added

| Piece | Where | Status |
|---|---|---|
| Digital Crown service (W-9) | `SimGuestFrameworks/SimHID/simhid.c`: service ID `0x59434F4400000006`, `PrimaryUsagePage` 0xFF0B, `PrimaryUsage` 1, `DeviceUsagePairs` [that pair], `Built-In` true, `Product` "Ycode Digital Crown"; published when `YCODE_SIMHID_DIGITAL_CROWN=1`, which `ycode-simd` sets for every device type with the feature `com.apple.hid.digital-crown` (§3.2: all watches) | **done** |
| Crown rotation (W-10) | transport kind **8** (`hid-input.md` §7.3, §16): f64 signed delta, u32 axis (0: the bundle's own; 1 x, 2 y, 3 z for diagnostics), u32 0; body 32 bytes. The bundle dispatches one scroll event per message from the crown service, the delta unchanged | **done**: opens the Smart Stack on the face and scrolls a list (§12.3) |
| Watch gestures | transport kind **9**: u32 gesture (§5.1's numbering: 0 double tap, 1 flick, 2 single tap; 3–5 accepted), u32 0; body 24 bytes | **host side only**: the bundle logs and drops them (§12.2, Q15) |
| Commands | control socket `crown <delta> [count [interval-ms [x\|y\|z]]]` and `gesture double-tap\|flick\|tap\|<n>` (`ycode-simd/WatchInput.swift`); `ycode-simd --device D --crown <delta> [count]`, `--gesture <g>`; `ycode-sim --device D --crown …`, `--gesture …` (passed straight through) | **done** |
| Viewer | `YcodeDeviceUI`: on a watch the scroll wheel and the trackpad turn the crown (`DeviceInputHandler.rotateCrown(by:)`, the device's `crown` command over the display stream's commands) instead of dragging a finger | **done** |
| HID bundle by default | a watch device gets the HID bundle with or without `--display-server`, as a foldable does (its crown is HID input) | **done** |
| Crown press, side button, Action button | unchanged: the provisional buttons of §11.3 (crown → `home`, side → `lock`, Action → `side`) | **open** (§9 Q2, Q3) |

### 12.2 Ycode decisions

- **The scroll event.** The bundle creates it with IOKit's public scroll
  event constructor (`IOHIDEventCreateScrollEvent`: allocator, timestamp,
  x, y, z as `IOHIDFloat` (a double on 64-bit), options; looked up with
  `dlsym`, so a runtime without it still loads the bundle) and dispatches
  it from the crown service. §5.1 gives the event type and that the delta
  is unchanged, not the axis: Ycode puts the delta on **y** (x and z 0).
  With y the first burst opened the Smart Stack and the list scrolled both
  ways (§12.3). `YCODE_SIMHID_CROWN_AXIS` (x, y, z) and the message's axis
  word exist for diagnostics only. Timestamps are the guest's ticks as for
  every other event (`hid-input.md` §5.1).
- **Sign and units.** The delta is passed as received: positive scrolls a
  list forward and opens the Smart Stack on the face, negative the other
  way (§5.1). The guest does the detents and acceleration; the host adds
  none.
- **The viewer's mapping.** One crown command per scroll event (momentum
  events are ignored: the guest makes its own); delta = −`scrollingDeltaY`
  × factor, a wheel's line counting 10 points; so scrolling down a list
  with the wheel, or two fingers up on a trackpad with natural scrolling,
  is positive. The factor defaults to 2 and is the user default
  `YcodeCrownScrollFactor` (W-10's "user-adjustable factor"). A phone or
  any other family keeps the one-finger drag.
- **Gestures.** §5.1 names the reference's route (the bundle forwards the
  number to watchgesturesd's `WatchGesturesSimulatorServer`, which makes a
  GenericGesture event) but not the XPC message, nor the HID gesture-type
  values (HandTap, HandFlick) that a bundle would need to make the event
  itself; IOHIDFamily's open source has the GenericGesture event and its
  `IOHIDGenericGestureType` field but no such values. Ycode therefore
  carries the gesture to the bundle and stops there (one log line per
  gesture, "no guest route in the spec"); Q15 asks for either piece.
- **Buttons.** No change: the crown press, the side button and the Action
  button keep their provisional mapping (§11.3) until Q2/Q3 are answered.

### 12.3 Runs (2026-10-30)

Run a1 (the first paired boot of `device-pairing.md` §12.3; Thor 1-min load
4.7 at the start, 140–170 during it). The watch face showed 116 s after the
start; the input steps came after both home screens, the pairing and a
20 s settle. Each crown step is `crown <delta> <count> 16`, then a frame
capture after 0.3 s and 2 s.

| Step | Result |
|---|---|
| Bundle start | the crown service added 2.95 s into the watch's backboardd start, with the buttons and keyboard services; the touch screen 0.8 s later (display id found) |
| `crown 20 30` on the face | **the Smart Stack opened** (the face moved up into the date/time header, the stack of widgets and "Edit" below; `watch-w3b-smart-stack.png`); the bundle dispatched the 30 events 13–21 ms apart, as sent |
| bursts of 50 × 60, 200 × 60, 1000 × 30 | the stack stayed open (it was already open) |
| `crown -20 30` on the face (run c1, a repeat boot of the same watch) | **Notification Center opened** ("No Notifications" over the blurred face; `watch-w3b-notification-center.png`); `crown 20 30` from there went on to the Smart Stack |
| `gesture double-tap`, `gesture flick` | no change on the screen; the bundle logged both and dropped them (§12.2) |
| `crown 20 30` in our watch app's list (60 rows) | the list scrolled **forward**: offset −46.5 → 1 119.5 points, rows 19–23 shown (`watch-w3b-list-scrolled.png`; before: `watch-w3b-list-top.png`) |
| `crown -20 15` in the list | the list scrolled **back**: rows 8–12 shown |

The scroll offsets are the app's own (`onScrollGeometryChange`, logged at
most every 0.5 s): the guest's own deceleration ran over about 0.5 s after
the last event. Against §5.1's reference (30 events of +20 went from the
top to the end of the watch Settings list; on the face, bursts of that size
sprang back short of the threshold), Ycode's list moved about 19 rows for
the same burst and the face crossed the threshold at once; the guest does
the detents, so the difference is in what reaches it per event (the axis,
§12.2) or in timing, and is not tuned here.

### 12.4 Tests

`HIDHostServiceTests.watchInputBodies` (kinds 8 and 9: layout, the axis
word, a non-finite delta sent as 0, gesture names),
`WatchDeviceTypeTests.watchEnvironment` (the crown variable on a watch, not
on a phone), `WatchWindowTests.scrollingTurnsTheCrownOnAWatchOnly` (the
viewer's mapping, wheel and trackpad, the factor, a phone keeps the drag).
The bundle has no host unit test (guest code); run a1 exercised it.

### 12.5 What remains

- **Q15** (new, dirty room): the message the reference's bundle sends to
  `WatchGesturesSimulatorServer` for a gesture, or the HID gesture-type
  values of HandTap and HandFlick and the GenericGesture event's fields, so
  that gestures 0–2 reach the guest.
- §9 Q2, Q3: the crown press, the side button and the Action button.
- The crown axis is chosen, not observed: if the reference's records carry
  the delta on another axis the reference's per-event travel may differ
  (Q16, dirty room: which axis of the scroll event carries the crown's
  delta).
- W6 (IDE): the Devices window could offer gestures as menu items once Q15
  is answered.

## 13. Round W7 under Ycode: buttons, the Action button and gestures (agent WATCH-W7, 2026-10-31)

Clean-room implementation of §5.2. Evidence is level 3: Ycode's own
simulator on the arm64 Linux host (Apple Watch Ultra 4 49 mm on watchOS
27.0 24R362, paired with an iPhone 18 Pro on iOS 27.0), `--control
screenshot` captures, the HID bundle's log, the guest's own logs and our
WCProbe's log. No Apple simulator, Xcode, Device Hub or reference tool was
run or opened; the GenericGesture constructor's signature is from
IOHIDFamily's open source (APSL 2.0: `IOHIDFamily/IOHIDEvent.cpp`
`genericGestureEvent`, `HID/Headers/HIDEventAccessors.h`).

### 13.1 What was added (Ycode implementation of §5.2)

| Piece | Where | Status |
|---|---|---|
| One button table | `YcodeDisplayStream/ButtonUsages.swift` (`DeviceButtonTable`): a display-stream button or a named watch button → usage pair, per family. Watch: `home` → 0x0C/0x40 (crown press), `side` → 0x0C/0x95 (side button), `lock` → 0x0C/0x30 (screen toggle), `action` → 0xFF01/0x200 on the Ultra types only, no volume buttons; other families unchanged (a phone's Action keeps 0x0C/0x95). `ycode-simd`'s input bridge, its hello's `buttons` and the `button` command use it | **done**; replaces §11.3's provisional crown → `home`, side → `lock`, Action → `side` |
| Display stream | button value **6** `action` (`display-stream.md` §5.3); the viewer sends it only when the hello lists "action" | **done** |
| HID bundle, buttons | `simhid.c`: on a watch (`YCODE_SIMHID_DIGITAL_CROWN=1`) the buttons service dispatches only the watch's pairs (above; 0xFF01/0x200 only with `YCODE_SIMHID_ACTION_BUTTON=1`, which `ycode-simd` sets for types with the Action-button feature); anything else is logged and ignored (§5.2: never crash). Keyboard events from the buttons service, down and up as sent (the guest times holds) | **done** |
| HID bundle, gestures | kind 9 → one GenericGesture event (type 39) from a new **watch-gestures service** (`0x59434F4400000007`, primary page and usage 0, Built-In, "Ycode Watch Gestures"): double tap (0) = gesture type 2 with tap count 2 (field (39 << 16) + 1), flick (1) = type 8, created with options 0 (relative), then the event flags set to 0x4000000 (phase Ended; `IOHIDEventSetEventFlags`, else `IOHIDEventSetPhase`, else the options). Single tap (2) and unknown numbers: no event. The constructors are looked up with `dlsym` (`IOHIDEventCreateGenericGestureEvent`, else `IOHIDEventCreate` and the type field) | **done** |
| Commands | control socket `button crown\|side\|action\|screen [hold-ms]` (`WatchInput.swift`; default hold 100 ms, up to 10 s); `ycode-simd --device D --button <name> [hold]`, `ycode-sim --device D --button …` | **done** |
| Viewer | `DeviceLiveSession.displayButton(for:)`: on a watch the crown is `home`, the side button `side`, an Ultra's Action `action` (or `side` to an older server); Controls ▸ Lock is the screen toggle (`device-hub.md` §I.10) | **done** |
| Test app | WCProbe's watch list starts with a "Primary action" button marked `.handGestureShortcut(.primaryAction)` (public SwiftUI API); it logs "primary action <n> (hand gesture shortcut)" | **done** |

### 13.2 Ycode decisions

- **Gesture service.** The reference's event comes from watchgesturesd's
  own HID service; Ycode's bundle makes it from a service of its own with
  §5.2's primary pair 0/0. backboardd routes GenericGesture to the
  keyboard focus by its event type (its dispatch rules list GenericGesture
  for the focus; run a1), so the service's pair does not matter for routing.
- **No forwarding to watchgesturesd.** §5.2 says the XPC message is not
  needed; Ycode creates the event itself.
- **Hold times** are the host's: `button side 3000` holds 3 s (§5.2's
  2.5 s threshold); the guest decides what a hold is.
- **The screen toggle** is offered as `button screen` and Controls ▸ Lock;
  it is not drawn on the frame (not a watch hardware button).

### 13.3 Run a1 (2026-10-31, Thor; load 7–30, other agents' boots running)

Paired Ultra 4 + iPhone 18 Pro, both on their home screens; each step is
one `button`/`gesture` command, then a capture 3–4 s later. Screenshots
outside the repository (`.claude/worktrees/watch-w7-*.png`).

| Step | Result |
|---|---|
| `button crown` on the face | **the app grid** (`watch-w7-crown-app-grid.png`) |
| `button crown` in the grid | **the face** (`watch-w7-crown-back-to-face.png`) |
| `button side` | **Control Center** (`watch-w7-side-control-center.png`); `button crown` closed it |
| `button side 3000` | **the power-off sheet**: Cancel, the power button, "SOS Emergency Call" (`watch-w7-side-held-power-off.png`); `button crown` closed it |
| `button action` (Ultra) | **"Choose what you'd like the Action button to do."** with Choose Action and Cancel (`watch-w7-ultra-action-sheet.png`), as §5.2; `button crown` closed it |
| `button screen`, twice | the screen went to its dimmed always-on face (`watch-w7-screen-off.png`), then back to the full face |
| WCProbe's watch app in front, `gesture double-tap` × 2 | **"primary action 1", "primary action 2"** in WCProbe's log, 0.4 s after each command (`watch-w7-wcprobe-primary-action.png` before) |
| `gesture tap` | no event (the bundle logs "no event … single tap"), as the reference |
| `gesture flick` in the app | the app was dismissed to the face (`watch-w7-after-flick-face.png`); then `button crown` opened the app grid from the face |

The bundle's log shows each pair down and up as sent (the side button's
3 000 ms apart), the Action button's 0xFF01/0x200, and the gesture
constructor and setters found (`IOHIDEventCreateGenericGestureEvent`,
`IOHIDEventCreate`, `IOHIDEventSetEventFlags`, `IOHIDEventSetPhase`). Both
devices booted to their home screens with the new bundle (the iOS 27.0
phone's buttons keep their usages).

### 13.4 Tests

`ButtonUsageTests` (YcodeDisplayStreamTests: phone and watch pairs, the
Ultra's Action only on Ultras, the hello's buttons, the pairs a watch
accepts and §5.2's refused sources, the named buttons, value 6 on the
wire); `HIDHostServiceTests.watchGestureEventsAndButtons` (the gesture
event's type, tap count, field numbers and flags; single tap and unknown
numbers make none; the Action button's message); `WatchDeviceTypeTests`
(`YCODE_SIMHID_ACTION_BUTTON` only on an Ultra); `WatchWindowTests` (the
frame's crown, side and Action buttons). The bundle itself has no host
unit test (guest code); run a1 exercised it.

### 13.5 What remains

- Q16 (the crown's scroll axis) is still open.
- The viewer offers no gesture controls (menu items or keys for double tap
  and flick); `ycode-sim --gesture` and the control socket send them.
- Shorter holds than §5.2's thresholds were not tried (on the reference
  either).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Identification, bundle values, `SystemVersion.plist` (§2.1) | 2 | `plutil -p` of the runtime bundle and RR files |
| Packaging, sealed, not encrypted (§2.6) | 2, 3 | `simctl runtime list -v`; `diskutil info`; `mount` |
| Profile differences (§2.2) | 2 | `profile.plist` of both runtimes via `plutil` |
| Architecture, platform, cache header and image count, sizes (§2.3) | 2, 4 | `file`, `lipo`, `otool -l` (`LC_BUILD_VERSION`), the cache's first bytes, `.map` line count, `ls -l` |
| `powerexperienced` fails with bad CPU type (§2.3, §2.4) | 3 | launchd_sim log lines in two boots |
| Job sets, Mach services, Nano directories (§2.4) | 2, 3 | our `jobs.py`-style script over the plists of both runtimes; `launchctl print system/<label>` in the guest |
| Jobs in the `system` domain; `user/501` refused (§2.4) | 3 | `launchctl print` in the watch and the phone |
| Host endpoints, ports, four SimMetalHost (§2.5) | 3 | `launchctl print system` (simhost block); `ps` |
| Copy, counts, unreadable directory (§2.6) | 3 | rsync log; `find | wc -l` on both sides; `ls -ld` |
| Device types and capabilities (§3.1–3.3) | 2 | the thirteen bundles via `plutil` and our script |
| Bootstrap plist and environment (§3.4) | 3 | `DEV/data/var/run/launchd_bootstrap.plist` |
| Screen content (§4.1) | 3 | `simctl io screenshot` (in `research/dirty/watch/`) |
| Framebuffer owners, display facts (§4.2, §4.4) | 3 | `lsof` of guest processes; backboardd log; `simctl io enumerate` |
| HID services (§5) | 3 | backboardd log ("Connecting service" lines) |
| Crown and gesture builder records (§5) | 3, 4 | exported names (`nm -gU` of SimulatorKit); our `watchhid probe` hex dumps |
| Input effects not observed (§5) | 3 | `watchhid` sends, screenshots, `log show --info --debug` |
| Boot times, migration, processes, footprint, CPU (§6) | 3 | `simctl bootstatus`, our screenshot poller, migration plist, `ps`, `footprint`, `top` |
| Requirements, rounds, risks (§7–8) | — | Ycode decisions from the above |
| W1 implementation, decisions (§10.1) | — | Ycode decisions; unit tests (`WatchDeviceTypeTests`, `MachOImageTests.runnableInSimulator`, `ProcessTests`) |
| Control operations and domain under Ycode (§10.2) | 3 | `YCODE_CONTROL_CHECK` log lines; `launchctl print system` and `launchctl list` one-shots; `launchd.log` |
| powerexperienced under Ycode (§10.2) | 3 | `launchctl kickstart` and 704 one-shots; `launchd.log` |
| Done-criterion, faults, frames (§10.3) | 3 | `DEV` files read as formats (migration plist, LaunchServices store); `ycode-simd` logs; Ycode frame record screenshots |
| Boot times (§10.4) | 3 | `timed.sh` runs on the Thor; `launchd.log` times against the start time; frames every 2 s |
| Regression boots (§10.5) | 3 | iOS 27.1 and visionOS boots on the Thor with the W1 build; end frames |
| W2 display facts, callers (§11.1) | 3 | `YCODE_FRAMEBUFFER_CALLS` logs of backboardd and Carousel; frame records of three types (d1, d6, d7) |
| W2 Metal clients and pipelines (§11.2) | 3 | `YCODE_METAL_STATS` summaries; `ycode-simd` logs (d1, d2) |
| W2 viewer and IDE (§11.3) | — | Ycode decisions; unit tests; Ycode's own viewer windows captured with `screencapture -l` (d4, d5) |
| W2 ClockFace start-up (§11.4) | 3 | boot profiles with PC samples and the per-image table (`boot-profile.md` §1; d2, d3); `launchd.log` times |
| W2 idle CPU, frame rate, minute updates (§11.5) | 3 | `/proc/<pid>/stat` of `ycode-simd`; boot-profile samples; the framebuffer library's timing ring (d4) |
| W2 recheck: Metal clients, ClockFace's time to first frame (§11.2, §11.4) | 3 | `YCODE_METAL_STATS` summary (r2); the timing ring placed on the host clock with the display trace's `sync` lines and `launchd.log` spawn times (r1, r2) |
| W2 recheck: minute updates, idle CPU, frame rate (§11.5) | 3 | the timing ring and the frame record (r1); `/proc/<pid>/stat` of `ycode-simd` every 5 s (r1); Ycode's viewer script statistics |
| W2 recheck: bezel round trip and expanded minimum (§11.3) | — | Ycode decisions; `WatchWindowTests`; Ycode's own viewer window captured with `screencapture -l` (r1, r2) |
| Watch input paths, suppression by dtuhidd, crown and gesture events, routing and effects (§5.1) | 3 | `watchhid`/`hidsend` (ours) through `SimDeviceLegacyHIDClient`; the watch's backboardd, Carousel, ClockFace, watchgesturesd and app logs at debug level; `simctl io` screenshots; `notifyutil`, `launchctl print` in the guest |
| Builder signatures, the gesture union member, service and dtuhidd names (§5.1) | 4 | strings and type encodings of SimulatorKit, the watchOS SimulatorHID bundle and dtuhidd |
| W3b crown service, transport kinds 8 and 9, commands, viewer mapping, gestures' stop (§12.1, §12.2) | — | Ycode decisions; unit tests `HIDHostServiceTests.watchInputBodies`, `WatchDeviceTypeTests.watchEnvironment`, `WatchWindowTests.scrollingTurnsTheCrownOnAWatchOnly` |
| The scroll event constructor, `IOHIDFloat`, the GenericGesture event without gesture values (§12.2) | 1 | IOHIDFamily open source (APSL 2.0): `IOHIDFamily/IOHIDEvent.h`, `HID/Headers/HIDEventAccessors.h` |
| W3b crown on the face and in a list, gestures without effect (§12.3) | 3 | Ycode's own simulator on the arm64 Linux host (run a1): `--control screenshot` captures, the HID bundle's log, WCProbe's scroll-offset log |
| dtuhidd kept from starting; buttons, usages and effects; the Action button's arrival and sheet; the gesture events' fields as printed by watchgesturesd; the backboardd crash on source 0x400002 (§5.2) | 3 | `watchhid`, `watchhid3`, `hidsend` (ours) through `SimDeviceLegacyHIDClient` on two test watches; backboardd, Carousel and watchgesturesd logs at debug level; `simctl io` screenshots; `notifyutil`, `launchctl` in the guest; the host's crash report (frame names only) |
| Device chromes and their inputs, the types that use them (§5.2) | 2 | `chromeIdentifier` in each watch type's `profile.plist`; `chrome.json` of the nine watch chromes read with a JSON reader |
| Gesture-type values and the field indices of the GenericGesture event (§5.2) | 3 | our `gestprobe` / `gestfields` inside the watch: the exported constructor called with chosen values, the events' own descriptions and integer fields read back; nothing dispatched |
| Requirements for buttons, Action and gestures (§5.2) | — | Ycode decisions from the above |
| Round W7: the button table, the gesture event's construction, the gestures service, commands (§13.1, §13.2) | 1, — | IOHIDFamily open source (APSL 2.0: `IOHIDEvent.cpp` `genericGestureEvent`, `setPhase`; `HIDEventAccessors.h`); the rest Ycode decisions; unit tests `ButtonUsageTests`, `HIDHostServiceTests.watchGestureEventsAndButtons`, `WatchDeviceTypeTests`, `WatchWindowTests` |
| Run a1: buttons, Action sheet, screen toggle, double tap reaching an app, flick (§13.3) | 3 | Ycode's own simulator on the arm64 Linux host: `--control screenshot` captures, the HID bundle's log, backboardd's and Carousel's logs, WCProbe's log |
