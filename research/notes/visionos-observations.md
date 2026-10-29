# visionOS simulator observations (agent VISIONOS-SPEC, 2026-10-26)

Dirty-room notes behind `specs/simulator/visionos.md`. Prose only. Raw logs,
screenshots and tables stay in `research/dirty/visionos/` (git-ignored).
No disassembly, no decompilation; Ghidra and the reference tools folder were
not opened. Method levels as in AGENTS.md rule 4.

## Setup

- Mac15,10 (M3 Max, 36 GiB), macOS 27.2 (26B5112a), Xcode 27.1 at
  `/Applications/Xcode.app`. Xcode 27 has no Simulator.app: simulator windows
  live in **DeviceHub** (`Contents/Applications/DeviceHub.app`, bundle id
  `com.apple.dt.Devices`).
- Two visionOS 27.0 runtimes share the identifier
  `com.apple.CoreSimulator.SimRuntime.xrOS-27-0`: **24M362** (release,
  Xcode build 27A200c) and **24M5291p** (beta, 27A161h). Their
  `profile.plist` files are identical. `simctl runtime match list` shows
  CoreSimulator chooses 24M362 for the `xros27.0` SDK (SDK build 24M361);
  `simctl create … xrOS-27-0` therefore made 24M362 devices without any
  override. Older runtimes 26.4.1 (23O249a) and 26.5 (23O470) are also
  installed and were not used.
- Devices: `ycode-test-visionos-1` (first boot, app launches, probe, repeat
  boots) and `ycode-test-visionos-2` (a second timed first boot), device
  type "Apple Vision Pro" (`…SimDeviceType.Apple-Vision-Pro-4K`). One booted
  at a time; both deleted at the end.
- Our probe: `research/experiments/visionos/VisionProbe/` (SwiftUI app,
  built with `swiftc` for `arm64-apple-xros27.0-simulator`). Helper scripts
  `jobs.py`, `simprocs.py`, `simfootprint.sh`, `boottimer.sh` in the same
  directory.
- The owner declined computer-use access to DeviceHub for this session, so
  no GUI-driven input was observed. Input facts are level 1 (Apple's Device
  Hub documentation), level 4 (bundle metadata of the DeviceHub plug-in) and
  level 3 guest-side observations (HID services, ARKit pose).

## Runtime as files (level 2/4)

- Runtime bundle `xrOS 27.0.simruntime`, `CFBundleName` "visionOS 27.0",
  `shortName` xrOS, `platformIdentifier` `com.apple.platform.xrsimulator`,
  `equivalentIOSVersion` 27.0, `supportedProductFamilyIDs` [7]. No
  `restrictedToDeviceTypes` (iOS 27.1 has `[V68]`). Requires one more host
  service than iOS 27.1: `com.apple.xrserverd`, plus
  `com.apple.identityservicesd.desktop.sim2host`. Supported features add
  `com.apple.visionProSim.display.4K` (the device type's
  `requiredRuntimeFeatures`), `com.apple.a11y.system-app-based`; drop
  rotation, CarPlay, pairing, resizable scene, ambient overlay, touch-id.
- `SystemVersion.plist`: ProductName **xrOS**, 27.0, 24M362,
  `iOSSupportVersion` 27.0.
- Disk image: "Patchable Cryptex Disk Image", 7.0 GB compressed, mounted
  read-only at `/Library/Developer/CoreSimulator/Volumes/xrOS_24M362`
  (volume name "XROS 27.0 Simulator"), APFS **sealed, not encrypted**,
  15.2 GB container, 14 GiB used. Same packaging as iOS 27.1 (24A94401,
  17 GiB volume, 16 GiB used). Files are readable like the iOS ones.
- `RR/System/Library/Caches/com.apple.dyld/`: `dyld_sim_shared_cache_arm64`
  2 039 676 928 B + `.01` 1 767 817 216 B + `.atlas` + `.map`; the map lists
  2907 image paths (iOS 27.1: 2 035 384 320 + 1 748 582 400 B, 1819).
  `usr/lib/dyld_sim` (705 136 B) and `sbin/launchd_sim` (469 824 B) and
  `launchd_sim_trampoline` present; hashes differ from iOS 27.1's.
- Apps with an Info.plist in `Applications` + `System/Library/CoreServices`:
  133 (iOS 27.1: 163). DataClassMigrators: 34 (iOS: 35).
- launchd plists: LaunchDaemons 310, LaunchAngels 18, LaunchAgents 7 (not
  passed to launchd_sim), Developer/LaunchDaemons 1 (testmanagerd). Labels
  over the three system directories: 335 (iOS 27.1: 363). 319 labels in
  common, 16 only in visionOS, 44 only in iOS (33 daemons, 9 angels, 2
  agents).
- Only in visionOS: SurfBoard (the system shell), RealityEnvironment
  (angel; vends `com.apple.surfboard.environmentservice`), MRSiri (angel),
  vhmdd, wakeboardd, royad, personacamerad, presenced, togetherd,
  userexperiencemanagerd, appleidsetupd, languageassetd, swtransparencyd,
  transparencyd, transparencyStaticKey, CopresenceUI.FaceTimeSupportService.
- Only in iOS (examples): SpringBoard, PosterBoard, CarPlayApp, InputUI,
  CameraOverlayAngel, healthappd, weatherd, liveactivitiesd, carkitd,
  companiond, nanoregistrylaunchd, assistivetouchd, photosface.
- backboardd's plist on visionOS declares 20 Mach services more than on
  iOS: `com.apple.dmm.service`, 18 `com.apple.realitysimulation.*` names
  (access, animation-service, apps, bounds, break, connect, data, debug,
  display, effects, host, interaction, naturalinput, performance,
  renderedcontentservice, scene, transitions, vi) and
  `com.apple.realitysystemsupport.hid_server_backboard`. Every iOS
  backboardd service is also there (including `com.apple.CARenderServer`
  and `com.apple.backboardd.virtualframebuffer`).
- SurfBoard vends `com.apple.surfboard.*` services, among them
  compositorservice, immersionservice, placementservice,
  sceneunderstandingservice, entityinteractionservice, eyesightservice,
  launcherservice, scenesessionservice.
- vhmdd vends `com.apple.vhmdd` and `com.apple.vhmdd-sim`. wakeboardd vends
  `com.apple.wakeboard.hmdpresentable{,.owner,.postprocess}`,
  `…hmdproperties`, `…hmdsystemsetter`, `…watchdog`,
  `com.apple.wakeboardd.system`. royad vends `com.apple.royad` and
  `…clientarkitservice`, `…developerservice`, `…screenshotservice`,
  `…statusservice`, `…usereventservice`.
- 130+ private frameworks exist only in visionOS; relevant names:
  RealitySimulation, RealitySimulationServices, RealitySystemSupport,
  CoreComposite, CompositorNonUI(+RE), CompositorServices,
  RemoteCompositorServices, BreakthroughServerSupportSimulator,
  PalomaSimService, NaturalInputSupport, Hands, SystemEnvironments,
  SpatialComputingCore, wakeboard, SurfBoardServices/UI, MRUIKit.
- Simulated rooms: `RR/System/Library/Assets/SystemEnvironments/
  SyntheticEnvironments/{KitchenDay,KitchenNight,LivingRoomDay,
  LivingRoomNight,MuseumDay,MuseumNight}`, 254 MB in total. Each is a
  MobileAsset-style folder: `Info.plist` (`MobileAssetProperties` with
  `__AppleSyntheticEnvironment` true and `EnvironmentKey`), `AssetData/
  Config.plist` (`combinedScene` = a `.usdc` file name, `icons.light` = a
  `.png`, `audioTracks` = []), the `.usdc` (1–2.5 MB) and a folder `0/`
  of `.ktx` textures (about 9.5 MB each, names ending `_RE-P3.ktx`, plus an
  `…_IBL_Linear_Display-P3_envProbeMap.ktx`). PHASE ships matching reverb
  presets (`ReverbPresets/{Kitchen,LivingRoom,Museum}.bin`). Nothing was
  copied.
- `SystemEnvironments.framework/KnownEnvironments.plist` lists the
  immersive (non-simulated) Environments with categories and icon names.

## Device type as files (level 2)

- Two device types: "Apple Vision Pro" (`…Apple-Vision-Pro-4K`,
  `minRuntimeVersion` 3.0, `requiredRuntimeFeatures`
  `{com.apple.visionProSim.display.4K: true}`) and "Apple Vision Pro (at
  2732x2048)" (`…Apple-Vision-Pro`, runtime 1.0–2.99, the old display).
  Both: model `RealityDevice14,1`, product class `N301`, families [7, 2, 1],
  `springBoardConfigName` iPadSimulatorHiDPI, legacy asset suffix "",
  `userInterfaceIdentifier` `com.apple.CoreSimulator.SimDeviceUserInterface.XROS`,
  supported features display.integrated, display.supports-external =
  false, hid.digital-dial, hid.gamecontroller.capture,
  hid.hoverboard.95880941, hid.keyboard, hid.touch-screen, oyster-id;
  conditional on runtime: pairing, applepay.authorize, pointer.system.
- `capabilities.plist`: `displays` has one entry: `primary`/`LCD`,
  integrated, 3840 × 2160, scale 2, 264 dpi, 60 Hz, P3, corner radii 0,
  `hasDigitizer` true, uniqueId `731F1373-97EF-4DCA-BC31-14C516B3E06F`
  (the same UUID appeared as the framebuffer display's unique id and in the
  touch service name, so it is fixed, not per boot). The old type differs
  only in 2732 × 2048.
- MobileGestalt answers: idiom "vision"; ArtworkTraits idiom vision, scale
  2, subtype 3648, fallback iPad13,4, memory class 16, APPLE8 with fallbacks
  APPLE7…GLES2,0; ScreenDimensions class 11, 3840 × 2160 @2, pitch 264;
  `device-name` "Apple Vision Simulator"; ModelNumber A2117;
  HomeButtonType 0; DeviceCornerRadius 0; OysterCapability, PiPOverlay,
  PiPPinned, FloatingLiveAppOverlay, DeviceIsMuseCapable true;
  telephony, sms, GPS, magnetometer, touch-id, pearl-id, ipad false; one
  obfuscated key `VGDDUFPWHbX/Ie9RSI0yDQ` true. Legacy `iconState` present
  (an old iPad layout, unused).

## Boot (level 3)

- First boot of device 1: `simctl boot` returned in 1.1 s, `bootstatus`
  terminal at 21.8 s ("Waiting on BackBoard", then "Waiting on Data
  Migration" from 11 s; migration took 7 s). Device 2: bootstatus 18.0 s,
  first screenshot showing the room at 30.3 s (screenshots polled about
  once a second).
- Migration: 34 plugins, `DMLastMigrationResults.success` **true** (iOS
  27.1 reported false because of the progress-window incident). Slowest:
  LaunchServices migrator 3.9 s, appleaccount 2.3 s, WebBookmarks 2.0 s.
  LaunchServices store 4.8 MB (`com.apple.LaunchServices-33554481-v2.csstore`,
  same schema number as iOS).
- Repeat boots of device 1: bootstatus 8.7 s and 12.2 s; room visible at
  20.3 s. At bootstatus terminal the screen still shows the boot card (a
  grey rounded rectangle with the Apple logo on black); the room appears
  about 8 s later.
- After boot: 159–163 processes; sum of `phys_footprint` 6.4 GiB (fresh
  device, idle) and 7.9 GiB (device 1 after app launches, widgets
  running); sum of RSS 10–12 GiB (counts shared pages many times).
  Largest: backboardd 274 MiB, RealityLauncher 150, RealityHUD 148,
  SurfBoard 129, RealityChrome 128, RealityKeyboard 106 MiB.
- Steady state with the home view: backboardd about 33–38 % of one core,
  one SimMetalHost about 17–19 % (top over 5 s; the Mac was busy with other
  apps).

## Rendering and compositing (level 3 + 4)

- Host processes for the device: one `launchd_sim`, one `SimRenderServer`,
  **five** `SimMetalHost` processes (iOS observation: three distinct ones,
  `metal-sim-protocol.md` §1.2).
- Host-side endpoints registered in the guest's `user/501` domain under
  `com.apple.xpc.launchd.simhost` (from `launchctl print user/501`): 25
  names. Compared with iOS 27.1's 27: `com.apple.CoreSimulator.NearbyInteraction`
  absent; `com.apple.identityservicesd.desktop.sim2host` added; the
  per-process Metal names are `com.apple.metal.simulator.backboardd`,
  `.wakeboardd`, `.RealityEnvironment`, `.pointeruid`, each on its **own**
  port (four different port names), while iOS's six per-process names
  shared one port. `com.apple.xrserverd`, required by the profile, was not
  registered; no job or binary on this Mac provides it (searched
  `/System/Library/Launch*`, CoreSimulator, Xcode's frameworks and
  DeviceHub by name).
- `simctl io enumerate`: one display port (`com.apple.framebuffer.display`,
  3840 × 2160, BGRA, 15 360 bytes per row), the framebuffer server with
  **one** connected screen (LCD, `primary`, 3840 × 2160, dot pitch 264,
  preferred UI scale 2, DCI-P3, SDR, refresh 6000 = 60 Hz, orientation
  "Ambiguous", no mask, no chrome), Metal and IOSurface accelerators,
  LegacyHID, three stream processors, audio, capture service, GPU tools.
  iOS iPhone Duo had five screens.
- `simctl io screenshot` (no display option; it defaulted to screenID 1)
  produced a 3840 × 2160 PNG of the full composed view: the Living Room
  (Day) synthetic room, the home view (Widgets, Siri, Safari, Photos, a
  "More Apps" folder, Settings, Files, Passwords) and the left tab bar.
  App windows appear as glass panels at different depths in the room.
- Which guest process maps which host library (`lsof` of the guest
  processes): `SimFramebuffer` is mapped by **wakeboardd** (and by
  CoreSimulatorBridge); `SimulatorHID` is mapped by **backboardd**. On iOS
  backboardd loads both.
- backboardd log (one boot, `log show`): at 16.959 "StartWindowServer:
  headless; not starting render server"; RealitySimulation "Initializing
  CAWindowServer", "Initializing virtual display", "Initializing shared
  simulation and host server"; later "Display is active <CADisplay:Virtual-0
  Virtual-0>" and "main display info … size:{2732,2048} scale:2 …
  display:<CADisplay:Virtual-0>". Then compositor controller, scene
  understanding server, immersion server, scene server, entity interaction,
  placement, natural input, application server, breakthrough server,
  RSRenderedContentServer; "Starting render loop: <RSXRRenderLoop>", "1
  render loops started", "Reloading run loops for connected headsets",
  "Updated display mode successfully to MR", compositor layers for the
  scenes `com.apple.realitysimulation.system-scene` and
  `…environment-scene`.
- Log categories in backboardd's first minutes: `com.apple.re:*`
  (Graphics, Network, Assets, Audio, RealityFusion, CAProtocol, ECS.CARE),
  `com.apple.RealitySimulation:*` (SceneEntityManager,
  RSScenePlacementManager, SharedSimulationHost, CompositorController,
  DisplayReveal), PHASE room simulation, Metal. So the RealityKit engine
  runs inside backboardd.
- backboardd loads the room: "loading synthetic environment
  'LivingRoomDay'…" (RealitySimulation:SceneUnderstanding) and the
  framework render graphs `com.apple.RealityFusion/renderSyntheticEnvironment.rerendergraph`
  and `…/composeSyntheticEnvironment.rerendergraph`.
- wakeboardd log: "This the first boot of wakeboardd, keeping the display
  pulsing until system shell (backboardd) comes up"; HMD state machine
  Config → Pulse ("First frame displayed" at 14.469, before backboardd's
  render loop), then "moving swapchain uid=1 from backboardd to slot Top",
  "moving swapchain uid=2 from backboardd to slot SyntheticPassthrough",
  later "creating real time thread", Pulse → RealTimeStarting → Run.
- vhmdd log: monitors RealityEnvironment, bridges SurfBoard's environment
  service, "forwarding installed environments: [Kitchen (Day), … Museum
  (Night)]", "SurfBoard changed active synthetic environment to
  'LivingRoomDay'", "environment loaded 'LivingRoomDay' with error: <no
  error>", "Initializing reality simulation bridge… setting end point
  result: success".
- Preferences `com.apple.RealityEnvironment`: `activeSyntheticEnvironment`
  LivingRoomDay, `activeEnvironment` Wolf.
- Our app's process (VisionProbe) logs `com.apple.re:Network`
  "NetworkSyncManager: initialized" and registers about 100 component sync
  types; it is a RealityKit network-sync client. It still opens three
  `com.apple.metal.simulator` connections (our own `MTLCreateSystemDefaultDevice`).
  It also connected once to `com.apple.vhmdd-sim` in a run with an
  `ARKitSession`.
- Conclusion drawn in the spec: all compositing (room, windows, volumes,
  immersive content) happens in the guest (backboardd's RealitySimulation +
  RealityKit renderer, then wakeboardd), through the same simulator Metal
  host protocol; the host only receives the final 3840 × 2160 image through
  SimFramebuffer.

## Metal as the guest sees it (level 3, our probe)

`MTLCreateSystemDefaultDevice` name "Apple xrOS simulator GPU";
`hasUnifiedMemory` false; families apple1, apple2, common1 only (not
apple3–10, common2–3, mac2, metal3); maxThreadsPerThreadgroup 512³;
maxBufferLength 268 435 456; recommendedMaxWorkingSetSize 0;
maxThreadgroupMemoryLength 16 384; argument buffers tier 1 (raw 0);
read-write texture tier none; no ray tracing, dynamic libraries, function
pointers, BC, 32-bit float filtering, barycentrics, pull-model
interpolation; vertex amplification count 1 yes, **2 no**; rasterization
rate maps no (1 or 2 layers); sample count 4 yes. Identical to the iOS
simulator profile in `metal-sim-protocol.md` §4.1.

## Identity and ARKit (level 3, our probe)

- `UIDevice`: model "Apple Vision Pro", systemName "visionOS", 27.0,
  idiom raw 6 (vision). Main window default size 348.5 × 250.5 (points, as
  reported by `onGeometryChange` in our window).
- ARKit `isSupported`: WorldTracking **true**; HandTracking,
  PlaneDetection, SceneReconstruction, ImageTracking, ObjectTracking,
  RoomTracking, EnvironmentLightEstimation, StereoProperties,
  VisualFidelity, AccessoryTracking, SharedCoordinateSpace,
  BarcodeDetection, CameraFrame, CameraRegion all **false**.
  `queryAuthorization` for handTracking and worldSensing: notDetermined.
- Inside an open ImmersiveSpace, `session.run([WorldTrackingProvider])`
  succeeded; `queryDeviceAnchor(atTimestamp: CACurrentMediaTime())`
  returned a tracked anchor every second for 30 s with position (0, 1.6, 0)
  m and forward (−0.216, 0, −0.976), i.e. 1.6 m eye height, yawed about
  12.5° to the left of −Z. Nothing moved the camera during the run, so the
  values stayed constant.
- Window + volume + immersive space: `openWindow(id:)` of a volumetric
  window and `openImmersiveSpace(id:)` (result `opened`) both worked; the
  screenshot shows the room still visible (mixed immersion), the other
  apps' windows hidden, our sphere (immersive) and our metallic box
  (volume) rendered, and a pending Maps location alert.

## Default apps (level 3)

- Home layout (`DEV/data/Library/Preferences/com.apple.RealityLauncher.plist`,
  key `ApplicationArrangement`, a JSON string): one page: RealityWidgets
  ("Widgets"), SiriApp, mobilesafari, mobileslideshow (Photos), a folder
  (mobilecal, Maps, news, reminders, shortcuts), Preferences, DocumentsApp
  (Files), Passwords.
- `simctl listapps`: 20 apps (those plus system ones such as PreviewShell,
  VoiceOverTouch, livetranscriptionui).
- `simctl launch` of Settings, Safari, Photos, Files, Passwords, Calendar,
  Maps, Reminders, News, Shortcuts, Widgets, Siri: all returned a pid.
  The first launch after the first boot (Settings) took **143 s**: SurfBoard
  received the request at once, runningboardd logged "Creating and
  launching job" at 12:48:35.41 and "Bootstrap success" at 12:50:48.46
  (the spawn itself took 133 s); the cause was not found. Every later
  launch returned in 0.4–2.3 s, and the first launch after a repeat boot
  took 2.3 s. All launched windows stack in front of the user at varying
  depths; Maps showed its location alert.

## Input (level 1, 3, 4)

- Guest HID services (backboardd log, "Connecting service" lines): IDs
  `0xACEFADE0000000…`: 01 MainScreenButtons (0x0B/1), 02 **DigitalDial**
  (1/0x37), 03 ExternalKeyboard (1/6), 04 ProximitySensor (0xFF00/8,
  Placement 1), 05 PalomaPose (0xFF00/0x72), 06 SelectionStream
  (0xFF00/0x71), 07 Manipulator (0xFF00/0x6F), 08
  ScreenTouchService.731F1373-… (0x0D/4, DisplayIntegrated, displayUUID =
  the LCD), and 00 GamePad, nine services in all. The iOS run (`hid-input-observations.md` §3) listed the same
  vendor services (Paloma pose, selection stream, manipulator) but no
  digital dial; iOS has three touch services, visionOS one.
- The xros copies of SimulatorHID and SimFramebuffer in CoreSimulator are
  separate builds (platform VISIONOSSIMULATOR, minos 1.0) with the same
  exported names as the iphoneos copies.
- DeviceHub's plug-in `VisionDeviceKitExtension.devicekitplugin` (in
  `DeviceKit.framework/PlugIns`, project string "PalomaSimService-85.0.7")
  links SimulatorKit, CoreSimulator, GameController, RealityFoundation,
  CoreRE and SwiftUI. Its exported symbols include three Indigo message
  builders of its own: `IndigoHIDMessageForPalomaPose`,
  `IndigoHIDMessageForPalomaSelection`, `IndigoHIDMessageForPalomaCollection`;
  it imports SimulatorKit's `IndigoHIDMessageForButton`,
  `…ForDigitalDialEvent`, `…ForGameControllerEvent` and `SimHIDCaptureManager`.
  Its strings name: "Connecting to vhmdd service", `com.apple.vhmdd`,
  `requestEnvironments`, `setActiveSyntheticEnvironmentAsync`,
  `getPose:`, `setPose:`, `resetCamera`, `setCamera`, camera-control modes
  `interact`, `pan`, `orbit`, `dolly`, `freeLook`, tilt, "Show Gaze Target",
  `toggleGazeFollowsMouse`, `invertGazeFollowsMouse`, `mouseOverPinch`,
  `mouseDownPinch`, "Hand Manipulator", `panTiltSensitivity`,
  `PanDefaultDeadzone`, `kHIDUsage_AppleVendor_PalomaPose`, pointer
  capture, `com.apple.GameController.CapturingGameController`.
- Apple's documentation "Interacting with your visionOS app in Device Hub"
  (developer.apple.com, retrieved 2026-10-26) gives the user-facing
  mapping: interact mode (pointer = where the eyes look; click = tap;
  click-and-hold = pinch and hold; drag = pinch-drag; Shift-drag up/down =
  pinch-drag forward/back; click-and-swipe = swipe); W/A/S/D or arrows,
  E/Q, trackpad pinch/scroll to move the viewpoint; segmented control modes
  "Drag to pan / dolly / tilt the camera"; Control-drag to change the
  viewing angle; Reset Camera button; Capture Pointer and Keyboard Capture
  (Escape releases); game controller (left stick move, L2/R2 down/up,
  right stick look); Home button (Controls > Home); Control Center by
  hovering the top indicator; Simulated Scenes chosen in the Settings
  inspector.

## Not done / open

- No GUI-driven input (access declined): the Indigo payload layouts of the
  Paloma pose / selection / collection messages, which HID event types the
  guest bundle dispatches for them, and whether the camera reaches apps
  only through the PalomaPose service or also through vhmdd's setPose, were
  not observed.
- The 133 s first app launch after the first boot is unexplained.
- No measurement of the reference's frame rate.
