# watchOS simulator observations (agent OBS-WATCH, 2026-10-29)

Dirty-room notes behind `specs/simulator/watchos.md`. Prose only. Raw logs,
screenshots, plists and tables stay in `research/dirty/watch/` (git-ignored).
No disassembly and no decompilation were used; Ghidra and the reference
tools folder were not opened. Method levels as in AGENTS.md rule 4. The
pairing work of the same round is in `pairing-observations.md`.

## Setup

- The same Mac as the visionOS rounds (macOS 27.2, Xcode 27.1 at
  `/Applications/Xcode.app`). Xcode 27 has no Simulator.app; device windows
  are DeviceHub's. No GUI was driven: no clicks, no screen takeover.
- The Mac was heavily loaded the whole session by other work (Swift builds,
  another agent's iOS 26.5 simulator, a QEMU VM): load average 190 at the
  first paired boot, 350–840 during the WatchConnectivity and HID runs.
  Every time below is an upper bound, and the latency figures are dominated
  by that load.
- Devices, all created with `xcrun simctl create` and deleted at the end:
  `ycode-test-watch-1` (Apple Watch Series 12 (46mm), watchOS 27.0
  24R362), `ycode-test-watch-2` (Apple Watch SE 3 (40mm), pairing limits
  only, never booted), `ycode-test-phone-1` (iPhone Duo, iOS 27.1
  24A94401), `ycode-test-phone-2` (iPhone 18 Pro, iOS 27.0, pairing limits
  only, never booted), and for a second, lighter-load pairing run
  `ycode-test-phone-3` (iPhone Duo, 27.1) with `ycode-test-watch-3`
  (Series 12 46 mm). At most one phone and one watch were booted at a
  time.
- Our code: `research/experiments/watch/` — `WCProbe` (an iOS app with an
  embedded watchOS app, WatchConnectivity both ways), `hid/watchhid.m`
  (SimulatorKit's exported Indigo builders driven from a Mac tool, after
  `../simulator/hid/hidsend.m`), `idsrelay/idsrelay.m` (a host-side
  man-in-the-middle on the pairing transport, using CoreSimulator's
  `lookup:error:`/`registerPort:service:error:`), `idsmsg/idsmsg.c` (an
  in-guest `mach_msg` recorder; it never loaded, see below). Built samples
  live under `<samples>/` (the inbox folder for this round).

## Runtime as files (levels 2 and 4)

- Runtime bundle `watchOS 27.0.simruntime`, identifier
  `com.apple.CoreSimulator.SimRuntime.watchOS-27-0`, bundle version 392,
  `DTXcodeBuild` 27A200c. One build installed (24R362); watchOS 26.5
  (23T570) is also installed and was not used.
- `simctl runtime list -v`: "Patchable Cryptex Disk Image", 3.6 GB, mount
  mode Cryptex, supported architectures arm64. `diskutil info` of the
  mounted volume "WatchOS 27.0 Simulator": APFS, Sealed yes, Encrypted no,
  FileVault no, read-only, container 9.3 GB, 9.0 GB used. Same packaging
  as iOS 27.1 and visionOS 27.0. Nothing was or needed to be decrypted.
- `SystemVersion.plist`: ProductName "Watch OS", ProductVersion 27.0,
  ProductBuildVersion 24R362.
- Architecture: every Mach-O in the root is plain **arm64**, built for
  platform 9 (watchOS simulator) — 594 executables, 507 bundles, 30 dylibs,
  `dyld_sim`, `launchd_sim`. **No arm64_32** anywhere (arm64_32 is the
  device ABI; the simulator runtime is LP64 arm64). The shared cache is
  `dyld_sim_shared_cache_arm64` (+ `.01`, `.atlas`, `.map`), magic
  "dyld_v1   arm64", 2 306 images in the map (iOS 27.1: 1 819). One odd
  file: `/usr/libexec/powerexperienced` is a fat **arm64e / arm64e.x1
  device binary (platform 4)**. Its job fails at every boot in the
  reference with "Bad CPU type in executable" (launchd_sim, posix_spawn
  error 86) and launchd_sim does not retry it.
- `profile.plist` differences from iOS 27.1 and the layout are tabled in the
  spec (§2.2, §2.3). Notable: `pairingRequirements` {maxPairs 1,
  minOSVersion 12.0, supportedProductFamilies [1]} (iOS 27.1:
  {100, 3.2, [4]}); `supportedProductFamilyIDs` [4]; no pasteboard, no
  `userInterfaceStyleMode`, no rotation feature; `com.apple.watch.pairing.qws`
  is unconditional; `supportedFeaturesConditionalOnDeviceType` has
  `hid.watch.gestures`, `location.nearby-interaction`, `motion.fall-detection`;
  `requiredHostServices` drops `FileProvider.sim2host` and
  `ist.ds.appleconnect.service.sim2host`.
- launchd plists: 227 in `LaunchDaemons` (iOS 329), 2 in `LaunchAngels`
  (25), 0 in `LaunchAgents` (9), 1 in `Developer/Library/LaunchDaemons`;
  plus `NanoLaunchDaemons` (4), `NanoLaunchDaemonsAltAccount` (6),
  `NanoLaunchDaemonsAltAccountOnly` (1). Over the four standard directories:
  229 labels, 208 shared with iOS, 21 only on watchOS, 155 only on iOS. The
  Nano directories are not in `Bootstrap.Paths` but their jobs are loaded
  at run time (`launchctl print system/com.apple.appconduitd` names
  `…/NanoLaunchDaemonsAltAccount/com.apple.appconduitd.plist`; the four
  `NanoLaunchDaemons` jobs are present; the AltAccountOnly job is not). The
  same holds on iOS (its three AltAccount jobs are present), consistent with
  `lean-boot.md` §1.1 (nanoregistrylaunchd enables them).
- watchOS-only labels (21): Carousel (the system app: `PurpleSystemAppPort`
  and 131 other Mach services), SensorKitALSHelper, addressbooksyncd,
  appaudiod, appleidsetupd, cache_delete and deleted_helper, carouselecomoded,
  corespotlightd, eventkitsyncd, gizmoappd (WatchKit app manager, services
  `com.apple.gizmoappd{,.appmanager,.dtsupport}`), lightlayerd,
  messagesregistrationd, nanomediaremoted, nanopassd, nanotimekitd,
  nanoweatherd, powerexperienced, relevanced, servicetowerd, watchgesturesd
  (with `com.apple.WatchGestures.WatchGesturesSimulatorServer`).
- `DataClassMigrators`: 24 (iOS 35). App bundles (`Applications` +
  `CoreServices`): 102 (iOS 267).

## Device types (level 2)

- Thirteen Apple Watch types accept watchOS 27.0 (max runtime ≥ 27):
  Series 12 (42/46 mm), Ultra 4 (49), Series 11 (42/46), Series 10 (42/46),
  Series 9 (41/45), Ultra 3 (49), Ultra 2 (49), SE 3 (40/44). Their
  identifiers, models, product classes, screen sizes, corner radii, chrome
  ids and default-creation/pairing ranges are in spec §3.
- All share: scale 2, pitch 326, 60 Hz, P3, `integrated` display,
  `display.aot` (always-on), `hid.digital-crown`, `hid.touch-screen`,
  family [4], `springBoardConfigName` `iPhone4Simulator`, legacy asset suffix
  "". Ultra types add `hid.sting` (the Action button) and
  `WatchAppButtonCapability` true. Series 12 / Ultra 4 / Series 11 and Ultra
  3 have `nativeRotation`/`nativeOrientation` 90 in their display entry;
  Series 12 and Ultra 4 also `main-screen-orientation` 4.712389 (3π/2).
- `capabilities.plist` (Series 12 46 mm): idiom `watch`, `metal` **false**,
  `graphicsFeatureSetClass` APPLE11 (APPLE8 on the older types),
  `memoryClass` 3 (2 on older types), `DeviceCornerRadius` 50,
  `device-name` "Watch Simulator", `marketing-name` "Apple Watch Series 12",
  `always-on-time`, `hardware-detents`, `GPSCapability`, `magnetometer`,
  `DeviceSupportsSwimmingWorkouts` true; `watch-companion`, `telephony`,
  `touch-id`, `pearl-id` false (cellular ones per model).
- Every type has a framebuffer-mask PDF (by UUID) and a DeviceKit chrome id
  (`com.apple.dt.devicekit.chrome.watch{2,2b,3s,3b,4,5s,5b,6}`).

## A booted watch (level 3)

- First boot (unpaired, Series 12 46 mm): `bootstatus` terminal at 30.3 s
  ("Waiting on BackBoard" at 2 s, data migration 24 plugins, 12.3 s summed,
  `success` true, slowest `managedconfiguration.migrator` 6.5 s and
  LaunchServices 4.3 s, then "Waiting on System App"). Repeat boot: terminal
  13.9–15.7 s; the face is in the screenshot 1.5 s after terminal (polled
  every 0.25–1.2 s). Before the face: the Apple-logo boot overlay
  (backboardd's `BKDisplayRenderOverlayAppleLogo`).
- Home: Carousel is the system app; the face is rendered in a separate
  process, **ClockFace**, with **NTKFaceSnapshotService** and the
  WidgetKit/ChronoKit extensions for complications. Default face after the
  first boot: a large two-colour digital time (yellow hour, salmon minutes).
  The app grid was not reached (no crown press took effect, see Input).
- 177–178 guest processes at idle after the first boot; summed
  `phys_footprint` 5.3 GiB (iOS 27.1 iPhone Duo: 227 processes in the same
  state). Idle CPU over 10 s: 0.7 % summed over the guest — the face is not
  redrawn continuously (minute updates). Five MTLCompilerService instances.
- Host side per device: `launchd_sim`, one `SimRenderServer`, **four**
  `SimMetalHost` (one per distinct Metal port, below).
- launchd domain: the watch's jobs live in the **system** domain
  (`launchctl print system`: 266 services; `print user/501` is refused,
  "Unrecognized target specifier"). The iPhone's live in `user/501` (382
  services, its `system` domain holds 7). The simhost endpoint block is under
  `system` → unmanaged processes → `com.apple.xpc.launchd.simhost`.
- Host endpoints registered in the watch (28): the iPhone set minus
  `com.apple.FileProvider.sim2host`, plus `com.apple.metal.simulator.ClockFace`
  and `.NTKFaceSnapshotService` (sharing one port), with
  `com.apple.metal.simulator.{Carousel,HeadBoard,PineBoard,SBRendererService,SpringBoard}`
  on one port, `…backboardd` on its own and the plain name on its own; and
  `com.apple.CoreSimulator.NearbyInteraction` (present on watchOS). No
  pairing endpoint exists while the watch is unpaired or its phone is down.
- Framebuffer: `simctl io enumerate` — one display port
  `com.apple.framebuffer.display`, 416 × 496 `'BGRA'`, 1 664 bytes per row,
  835 584 bytes; the framebuffer server lists one screen: id 1, "LCD",
  `primary`, integrated, 416 × 496, pitch 326, scale 2, DCI-P3, SDR,
  refresh 6000, UI orientation "Ambiguous", **mask URL** (the device type's
  PDF) and chrome id. The display unique id is per device (not fixed in the
  capabilities file as on visionOS). Plus `com.apple.display.captureservice`,
  accelerator ports `metal` and `iosurface`, `LegacyHID`, and a
  `SimStreamProcessor` port.
- Processes that map SimFramebuffer: **backboardd**, **Carousel** and
  CoreSimulatorBridge. backboardd also maps SimulatorHID. (On visionOS only
  wakeboardd maps the framebuffer.) backboardd: "StartWindowServer: initial
  main screen size:{416, 496} scale:2", nativeRotation 0, "SimDisplay :
  unsupported SimColorSpace" (an error line, harmless).
- Host libraries come from CoreSimulator's `Platforms/watchos/…`
  (`SIMULATOR_FRAMEBUFFER_FRAMEWORK`, `SIMULATOR_HID_SYSTEM_MANAGER`).
- Bootstrap plist `Child`: 31 keys, no `SIMULATOR_EXTENDED_DISPLAY_PROPERTIES`
  or `IPHONE_TVOUT_EXTENDED_PROPERTIES`; model `Watch8,3`, class `N237b`,
  416 × 496 @2, pitch 326, runtime 27.0 / 24R362. Host plists in
  `DEV/data/Library/LaunchDaemons`: 8 (the bridge and seven CoreDevice
  `dt*` daemons); the iPhone's ninth, `dtpasteboardd`, is absent (no
  pasteboard feature on watchOS).

## Input (levels 3 and 4)

- backboardd connects these SimulatorHID services (identifiers
  `0xACEFADE0000000xx`): 00 `MainScreenButtonsService` (page 0x0B usage 1,
  Authenticated, Built-In), 01 **`MainScreenDigitalCrownService`** (page
  **0xFF0B** usage **1**, Built-In; not the visionOS DigitalDial 1/0x37),
  02 `ExternalKeyboardService` (1/6), 03 `PalomaPoseService`, 04
  `SelectionStreamService`, 05 `ManipulatorService` (the three visionOS
  vendor services are present here too, unused), 06
  `ScreenTouchService.<display UID>` (0x0D/4). No proximity sensor, no game
  pad (iOS has both).
- About 5 s after backboardd connects them, buttons, keyboard and touch are
  disconnected ("dtuhidd-suppressed") and come back on the first Indigo
  event ("Connecting dtuhidd-suppressed service due to IndigoHID event"),
  as on iOS (`hid-input.md` §1).
- SimulatorKit exports `IndigoHIDMessageForDigitalCrownEvent` and
  `IndigoHIDMessageForWatchGesture` besides the iOS builders. Black-box
  calls with marker values (our `watchhid probe`): both return 192-byte
  messages (24-byte header area, inner size 0xA0, one record).
  - Crown: record kind **6**, host timestamp, field 0x10, the **first
    floating-point argument as a double at byte 0x3C** (1.5 and −7.25 seen
    exactly), 0x34 at 0x4C; the integer arguments and the other doubles are
    ignored. So a crown event is one signed delta.
  - Watch gesture: record kind **1** (the button/key kind), field 0x46 at
    0x30 and the **first integer argument at 0x34** (0, 1, 2, 3 seen).
- Effects: buttons (sources 0, 1, 3000), page 0x0C usage 0x40, a crown
  rotation burst (20 × +0.25) and a centre tap changed nothing in the
  screenshots, and backboardd logged no button lines even at debug level.
  The only sign of delivery was the service reconnect above. Not
  conclusive: the guest was under extreme load, and the watch app in front
  did not leave when Home was sent. Open question (spec §9).

## Things to remember

- `simctl io` screenshots are unmasked 416 × 496 rectangles (the mask is a
  separate PDF).
- The `powerexperienced` launch failure is reference behaviour; Ycode must
  fail it the same way (bad CPU type), not crash.
- The first app launch, appconduitd and the watch-app install path are in
  `pairing-observations.md`.
- `idsmsg.dylib` (our `mach_msg` recorder) was never loaded: with
  `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` set for a boot of the iOS 27.1
  phone, `ps -E` showed the variable in ids_simd's environment and
  `DYLD_PRINT_LIBRARIES` worked through `simctl spawn`, but no guest process
  mapped the library (from the inbox volume or from a local folder). Earlier
  rounds' recorders loaded this way; the difference was not found. The
  host-side relay (`idsrelay`) was used instead.
