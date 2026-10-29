# Spec: the visionOS simulator (visionOS 27.0, Apple Vision Pro) — what differs from iOS, and what Ycode must add

Status: **draft, round 0** (agent VISIONOS-SPEC, 2026-10-26); round R1 results under Ycode in §10 (VISIONOS-R1/R1b, 2026-10-27); round R2a in §10.7 (VISIONOS-R2a, 2026-10-27); reference observations for R2b's questions in §10.10 (VISIONOS-OBS3, 2026-10-27); round R3 in §10.11 (VISIONOS-R3, 2026-10-27); reference observations for R3's questions Q18–Q20 in §10.12 (VISIONOS-OBS4, 2026-10-27); round R4b in §10.14 (VISIONOS-R4b, 2026-10-27; new Q21); reference observations for Q21 in §10.15 (VISIONOS-OBS5, 2026-10-27); round R5 in §10.16 (VISIONOS-R5, 2026-10-27; new Q22); round R4a (the GPU hang, the broken pipelines) in §10.13 (VISIONOS-R4a, 2026-10-27; new Q23, Q24); reference observations for Q22 in §10.17 (VISIONOS-OBS6, 2026-10-27); guest audio under Ycode in §10.19 (AUDIO-HOST, 2026-10-27). It describes
the observable behavior and file formats of Xcode 27.1's visionOS 27.0
simulator runtime and its Apple Vision Pro device type, as deltas from the
iOS 27.1 runtime that `ycode-simd` boots today, and it states what Ycode
must add, in rounds sized for one agent each. Facts come from the runtime
and device-type files read as formats (level 2), black-box runs of
throwaway devices on this Mac (level 3), bundle metadata (level 4: names of
Mach services, exported symbols, linked libraries, strings) and Apple's
public Device Hub documentation (level 1). No disassembly or decompilation
was used; the reference tools folder, Ghidra and `research/dirty/` notes of
other agents were not opened. Raw logs and screenshots are in
`research/dirty/visionos/` (git-ignored); prose observations in
`research/notes/visionos-observations.md`; our probes in
`research/experiments/visionos/`.

Terms as in `launchd-sim.md`: **RR** (a runtime's `RuntimeRoot`), **DEV**
(the device directory; `DEV/data` is the guest's writable world).

## 1. Answers in brief

1. **Compositing happens in the guest.** The whole picture — the simulated
   room, the home view, app windows, volumes and immersive content — is
   rendered and composed by guest processes (backboardd running the
   RealitySimulation compositor and the RealityKit renderer, then
   wakeboardd, the head-mounted-display presenter) through the same
   simulator Metal host protocol that iOS uses. The host receives only the
   final 3840 × 2160 BGRA image through the ordinary SimFramebuffer
   display. Ycode's guest-renders-into-a-framebuffer design therefore
   suffices; **no host-side compositor is needed** (§4).
2. The picture is **mono**: one view, one display, 3840 × 2160 at scale 2,
   60 Hz. No stereo, no per-eye rendering, no foveation; the guest's Metal
   device is the same conservative simulator device as on iOS
   (Apple1/Apple2/Common1, vertex amplification count 1 only, no
   rasterization-rate maps) (§4.5).
3. **Input** reaches the guest through the same HID bundle path as on iOS
   (`SIMULATOR_HID_SYSTEM_MANAGER`, Indigo messages to
   `IndigoHIDRegistrationPort`), with visionOS-specific vendor services
   already published by the bundle: **PalomaPose** (head/camera pose),
   **SelectionStream** (gaze + pinch), **Manipulator**, plus a
   **DigitalDial** (Digital Crown). The Mac side (a DeviceHub plug-in)
   turns pointer, keyboard, trackpad and game controller into those
   messages and also talks to a guest daemon, **vhmdd**, for camera and
   simulated-room control (§5). The payload layouts of the new messages
   are not yet observed (§9).
4. **Boot** on the Mac: first boot `bootstatus` terminal 18–22 s, room
   visible at 30 s; repeat boot terminal 9–12 s, room visible at 20 s;
   about 160 processes, 6.4 GiB summed footprint at idle (§6).
5. **The runtime can be copied like iOS's**: a sealed, unencrypted,
   read-only APFS volume (14 GiB used) mounted from a cryptex disk image;
   files are plainly readable. Nothing needs (or may be) decrypted (§2.7).

## 2. The runtime

### 2.1 Identification

`xcrun simctl list runtimes` shows two visionOS 27.0 runtimes with the
**same** identifier `com.apple.CoreSimulator.SimRuntime.xrOS-27-0`:

| Build | Kind | Bundle `DTXcodeBuild` | Mount point |
|---|---|---|---|
| **24M362** | release (use this one) | 27A200c | `/Library/Developer/CoreSimulator/Volumes/xrOS_24M362` |
| 24M5291p | beta | 27A161h | `/Library/Developer/CoreSimulator/Volumes/xrOS_24M5291p` |

Their `profile.plist` files are identical. CoreSimulator picks 24M362 for
the `xros27.0` SDK (SDK build 24M361; `simctl runtime match list`), so
`simctl create … xrOS-27-0` produces 24M362 devices without an override.
Anything keyed by runtime identifier alone (IDE destination lists, golden
devices, snapshots) must also key by build (`ipad.md` §2.2 rule).

`RR/System/Library/CoreServices/SystemVersion.plist`: `ProductName`
**`xrOS`**, `ProductVersion` 27.0, `ProductBuildVersion` 24M362,
`iOSSupportVersion` 27.0. (UIKit reports the system name "visionOS", §3.4.)

### 2.2 `profile.plist` (runtime bundle, `Contents/Resources/`)

Differences from iOS 27.1 (24A94401); keys not listed are equal:

| Key | iOS 27.1 | visionOS 27.0 |
|---|---|---|
| `platformIdentifier` | `com.apple.platform.iphonesimulator` | `com.apple.platform.xrsimulator` |
| `shortName` | – | `xrOS` |
| `devicePlatformFolderName`, `simulatorPlatformFolderName` | – | `XROS.platform`, `XRSimulator.platform` |
| `equivalentIOSVersion` | – | 27.0 |
| `supportedProductFamilyIDs` | [2, 1] | **[7]** |
| `restrictedToDeviceTypes` | [`…V68`] | absent |
| `pairingRequirements` | present (watch pairing) | absent |
| `requiredHostServices` | 15 names | the same + `com.apple.identityservicesd.desktop.sim2host`, **`com.apple.xrserverd`** |
| `conditionalFeatures` | metal, deviceIdentity | + `com.apple.accelerator.iosurface` (host ≥ 10.14.4); metal also needs host ≥ 10.15 |
| `supportedFeatures` added | | `com.apple.a11y.system-app-based`, **`com.apple.visionProSim.display.4K`** |
| `supportedFeatures` removed | `accelerator.iosurface`, `carplay.sessionController`, `CoreSimulator.display.rotation` | |
| `supportedFeaturesConditionalOnDeviceType` removed | `carplay`, `display.resizableScene`, `CoreSimulator.pairing`, `display.ambient-overlay`, `touch-id`, `watch.pairing.qws` | |
| `supportedArchs` | arm64, x86_64 | arm64, x86_64 (the runtime itself is arm64-only: `simctl` reports `supportedArchitectures` [arm64], and the cache is arm64 only) |

Family 7 is the Apple Vision device family (`UIDeviceFamily` 7).

### 2.3 Layout relative to iOS 27.1

| Item | iOS 27.1 (24A94401) | visionOS 27.0 (24M362) | Consequence for `ycode-simd` |
|---|---|---|---|
| RR top level | `Applications`, `Developer`, `Library`, `System`, `bin`, `sbin`, `usr`, `private`, `etc` → `private/etc` | same structure | the prefix/volume code applies unchanged |
| Shared cache | `dyld_sim_shared_cache_arm64` 2 035 384 320 B + `.01` 1 748 582 400 B + `.atlas`, `.map`; 1819 images | same file names; 2 039 676 928 B + 1 767 817 216 B; **2907** images in the map | same loader path (`dyld-sim-handoff.md`); different build, so UUIDs, offsets and recorded addresses differ |
| `usr/lib/dyld_sim` | 701 824 B | 705 136 B (different build) | re-check the handoff facts (`dyld-sim-handoff.md`) on this build |
| `sbin/launchd_sim`, `launchd_sim_trampoline` | present | present (different builds) | re-check `launchd-sim.md`, `bootstrap-wire.md` |
| Apps with Info.plist (`Applications`, `System/Library/CoreServices`) | 163 | 133 | lsd seeds fewer apps on the first boot |
| DataClassMigrators | 35 | 34 | |
| Runtime volume (used) | 16 GiB | 14 GiB | disk on `$YCODE_DATA` |
| Simulated rooms (§2.6) | none | 6, 254 MB | runtime content, used by backboardd |

### 2.4 launchd jobs

`Bootstrap.Paths` has the same four entries as on iOS (`launchd-sim.md`
§4.1): `RR/System/Library/LaunchDaemons` (**310** plists; iOS 329),
`RR/System/Library/LaunchAngels` (**18**; iOS 25),
`RR/Developer/Library/LaunchDaemons` (1, testmanagerd), and
`DEV/data/Library/LaunchDaemons` (the same 9 host plists). Over the three
system directories (LaunchAgents included, 7 on visionOS, which
launchd_sim is not given) there are 335 labels (iOS 363): 319 shared, 16
only on visionOS, 44 only on iOS. In a booted device `launchctl list`
printed 358 jobs, 153 with a pid; the `user/501` domain had 356 services.

Only on visionOS:

| Label | Program | Role (from names and logs) |
|---|---|---|
| `com.apple.SurfBoard` | `/System/Library/CoreServices/SurfBoard.app` | the system shell (FrontBoard host) in place of SpringBoard; vends `PurpleSystemAppPort`, `com.apple.frontboard.systemappservices` and 30 `com.apple.surfboard.*` services (compositorservice, immersionservice, placementservice, sceneunderstandingservice, entityinteractionservice, launcherservice, scenesessionservice, keyboardservice, …) |
| `com.apple.RealityEnvironment` (angel) | `/Applications/RealityEnvironment.app` | immersive Environments; vends `com.apple.surfboard.environmentservice`; has its own Metal name (§4.3) |
| `com.apple.vhmdd` | `/usr/libexec/vhmdd` | the **virtual head-mounted display** daemon of the simulator; vends `com.apple.vhmdd` and `com.apple.vhmdd-sim`; bridges the simulated-room list and selection between SurfBoard, backboardd ("reality simulation bridge") and the Mac (§5.2) |
| `com.apple.wakeboardd` | `/usr/libexec/wakeboardd` | the HMD presenter: owns the framebuffer (§4.2); vends `com.apple.wakeboard.hmdpresentable{,.owner,.postprocess}`, `…hmdproperties`, `…hmdsystemsetter`, `…watchdog`, `com.apple.wakeboardd.system` |
| `com.apple.royad` | `Roya.framework/royad/royad` | vends `com.apple.royad`, `…clientarkitservice`, `…developerservice`, `…screenshotservice`, `…statusservice`, `…usereventservice` |
| `com.apple.MRSiri` (angel), `personacamerad`, `presenced`, `togetherd`, `userexperiencemanagerd`, `appleidsetupd`, `languageassetd`, `swtransparencyd`, `transparencyd`, `transparencyStaticKey`, `CopresenceUI.FaceTimeSupportService` | | Siri orb, Persona camera, SharePlay presence, transparency logging, UX manager |

Only on iOS (selection): `com.apple.SpringBoard`, `PosterBoard`,
`CarPlayApp`, `InputUI`, `CameraOverlayAngel`, `ProximityReaderSceneUI`,
`healthappd`, `weatherd`, `liveactivitiesd`, `carkitd`, `companiond`,
`nanoregistrylaunchd`, `nanotimekitcompaniond`, `assistivetouchd`,
`photosface`, `merchantd`, `musicd`.

backboardd's plist on visionOS keeps every iOS Mach service (including
`com.apple.CARenderServer` and `com.apple.backboardd.virtualframebuffer`)
and adds 20: `com.apple.dmm.service`,
`com.apple.realitysystemsupport.hid_server_backboard` and 18
`com.apple.realitysimulation.*` names (`access`, `animation-service`,
`apps`, `bounds`, `break`, `connect`, `data`, `debug`, `display`,
`effects`, `host`, `interaction`, `naturalinput`, `performance`,
`renderedcontentservice`, `scene`, `transitions`, `vi`).

Running after boot (selection): backboardd, SurfBoard, wakeboardd, vhmdd,
RealityLauncher (the home view), RealityHUD, RealityChrome (window bars and
ornaments), RealityKeyboard, RealityNotifications, RealityEnvironment,
pointeruid, three MTLCompilerService instances, and the usual daemons.
Lean-boot lists (`lean-boot.md`) are keyed by label and need a visionOS set.

### 2.5 Host services

The host registers its services in the guest's `user/<uid>` domain under
the pseudo-process `com.apple.xpc.launchd.simhost` as on iOS
(`launchd-sim.md` §6.3). A visionOS boot registered **25** names:

| Group | Names | Difference from iOS 27.1 (27 names) |
|---|---|---|
| CoreSimulator | `host.bootstrap_port`, `SimFramebufferServer`, `SimCaptureService`, `SimIdentityService`, `IndigoHIDRegistrationPort` | no `com.apple.CoreSimulator.NearbyInteraction` |
| GPU | `com.apple.metal.simulator`; **`…metal.simulator.backboardd`, `.wakeboardd`, `.RealityEnvironment`, `.pointeruid`**, each on its **own** port; `com.apple.IOSurface.Remote`; `com.apple.gputools.service.simulator` | iOS registered `.SpringBoard`, `.SBRendererService`, `.backboardd`, `.PineBoard`, `.HeadBoard`, `.Carousel`, all on one shared port |
| Audio, System, Other | as on iOS | + `com.apple.identityservicesd.desktop.sim2host` |

Five `SimMetalHost` processes served the device (one for the plain name,
one per per-process name). `com.apple.xrserverd`, although listed in
`requiredHostServices`, was **not** registered: no job or binary on this
Mac provides it (it was looked up by name in the system launchd
directories, CoreSimulator, Xcode's frameworks and DeviceHub), and the
boot did not need it. As on iOS, a required name with no host service is
skipped.

### 2.6 The simulated rooms (runtime content)

`RR/System/Library/Assets/SystemEnvironments/SyntheticEnvironments/` holds
six rooms, 254 MB in all: `KitchenDay`, `KitchenNight`, `LivingRoomDay`,
`LivingRoomNight`, `MuseumDay`, `MuseumNight`. Format of each:

| File | Content |
|---|---|
| `Info.plist` | `CFBundleIdentifier` `com.apple.MobileAsset.SystemEnvironmentAsset`, `MobileAssetProperties` = {`__AppleSyntheticEnvironment` true, `EnvironmentKey` (e.g. `LivingRoomDay`), `ContentMajorVersion`, `ContentMinorVersion`, `_CompatibilityVersion`} |
| `AssetData/Config.plist` | `combinedScene` (file name of a binary USD scene, `.usdc`), `icons` {`light`: a PNG name}, `audioTracks` (empty array) |
| `AssetData/<scene>.usdc` | the room geometry and materials (1–2.5 MB) |
| `AssetData/0/*.ktx` | textures (KTX, about 9.5 MB each, Display-P3 named `…_RE-P3.ktx`) and an image-based-lighting probe (`…_IBL_Linear_Display-P3_envProbeMap.ktx`) |

The display names the guest reports are "Kitchen (Day)", … "Museum
(Night)". The active room is a preference of the RealityEnvironment
domain (`DEV/data/Library/Preferences/com.apple.RealityEnvironment.plist`,
key `activeSyntheticEnvironment`, default `LivingRoomDay`; the same file
holds `activeEnvironment` = `Wolf` for immersive Environments). PHASE ships
matching acoustic presets (`ReverbPresets/{Kitchen,LivingRoom,Museum}.bin`).
These assets are Apple content: Ycode reads them from the owner's runtime
copy and never redistributes them.

### 2.7 Copying the runtime

`simctl runtime list -v`: image kind "Patchable Cryptex Disk Image",
7.0 GB, mounted read-only (mount mode "Cryptex"). `diskutil info`: APFS,
**Sealed: Yes, Encrypted: No, FileVault: No**, volume name "XROS 27.0
Simulator", container 15.2 GB, 14 GiB used. This is the same packaging as
the iOS 27.1 runtime. The RuntimeRoot tree can be copied the way the iOS
root was (symlinks, modes and extended attributes preserved) to
`$YCODE_DATA/runtimes/xrOS-27.0-24M362/RuntimeRoot` (about 14 GiB). No
decryption is involved. (Nothing was copied for this spec.)

## 3. The device type

### 3.1 Bundles

| Device type | Identifier | Runtimes | Display |
|---|---|---|---|
| **Apple Vision Pro** | `com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro-4K` | `minRuntimeVersion` 3.0; `requiredRuntimeFeatures` {`com.apple.visionProSim.display.4K`: true} | 3840 × 2160 |
| Apple Vision Pro (at 2732x2048) | `…SimDeviceType.Apple-Vision-Pro` | 1.0–2.99 | 2732 × 2048 |

Only the first applies to visionOS 27. Same bundle layout as iPhone and
iPad types (`ipad.md` §3.1), without framebuffer-mask PDFs.

### 3.2 `profile.plist`

| Key | Value |
|---|---|
| `modelIdentifier`, `representedModelIdentifiers` | `RealityDevice14,1` |
| `productClass` | `N301` |
| `supportedProductFamilyIDs` | 7, 2, 1 |
| `environment` | `SIMULATOR_LEGACY_ASSET_SUFFIX` = "" (empty) |
| `springBoardConfigName` | `iPadSimulatorHiDPI` |
| `userInterfaceIdentifier` | `com.apple.CoreSimulator.SimDeviceUserInterface.XROS` (selects the host UI, §5.2) |
| `supportedFeatures` | `display.integrated`, `display.supports-external` = **false**, `hid.digital-dial`, `hid.gamecontroller.capture`, `hid.hoverboard.95880941`, `hid.keyboard`, `hid.touch-screen`, `oyster-id` |
| `supportedFeaturesConditionalOnRuntime` | `CoreSimulator.pairing` "1", `hid.applepay.authorize`, `hid.pointer.system` |
| `createByDefaultForRuntimeVersions` | 3.0–99.99 |

### 3.3 `capabilities.plist` (`SIMULATOR_CAPABILITIES`)

Same structure as on iPhone and iPad (`device-capabilities.md` §1). Values
that differ in kind from the iPhone Duo file:

| Key | Value |
|---|---|
| `idiom` | `vision` |
| `ArtworkTraits` | idiom `vision`, product description "Apple Vision Pro", scale 2, subtype 3648, gamut P3, `CompatibleDeviceFallback` `iPad13,4`, memory class 16, `GraphicsFeatureSetClass` `APPLE8`, fallbacks `APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0` |
| `ScreenDimensionsCapability` | class 11, 3840 × 2160, orientation 0, pitch 264, scale 2 |
| `modelIdentifier` | `RealityDevice14,1`; `ModelNumber`, `RegulatoryModelNumber` `A2117`; `marketing-name` "Apple Vision Pro"; `device-name` "Apple Vision Simulator" |
| numbers | `DeviceCornerRadius` 0, `HomeButtonType` 0, `memoryClass` 16, `subtype` 3648, `graphicsClass` 3, `software-dimming-alpha` 0 |
| true (selection) | `OysterCapability`, `DeviceIsMuseCapable`, `FloatingLiveAppOverlay`, `PiPOverlay`, `PiPPinned`, `DeviceSupports3DImagery`, `DeviceSupports3DMaps`, `metal`, `ASTC`, `hidpi`, `microphone`, `wifi`, `bluetooth`, `location-services`, `accelerometer`, `multitasking`, the HEVC keys, and one obfuscated key `VGDDUFPWHbX/Ie9RSI0yDQ` |
| false (selection) | `telephony`, `sms`, `GPSCapability`, `magnetometer`, `touch-id`, `pearl-id`, `ipad`, `HasThinBezel`, `always-on-time`, `contains-cellular-radio`, `watch-companion`, `DeviceSupportsEnhancedMultitasking` |
| `displays` | one entry: `primary` / `LCD`, `integrated`, 3840 × 2160, scale 2, 264 × 264 dpi, `refreshRate` 60, `colorspace` P3, corner radii 0, `hasDigitizer` true, `screenID` 1, `uniqueId` `731F1373-97EF-4DCA-BC31-14C516B3E06F` |

The display `uniqueId` is fixed in the file and was the framebuffer
display's unique id and part of the touch service's identifier in the
boot (§5.3); on iOS the display UIDs changed per boot.

### 3.4 Launch environment and bootstrap plist

The bootstrap plist (`DEV/data/var/run/launchd_bootstrap.plist`) has the
same top-level keys and the same `Bootstrap` keys as on iOS
(`launchd-sim.md` §3). `Child` has **31** keys: the iOS set minus
`SIMULATOR_EXTENDED_DISPLAY_PROPERTIES` and
`IPHONE_TVOUT_EXTENDED_PROPERTIES` (no external display). Values that
differ:

| Variable | Value |
|---|---|
| `SIMULATOR_MODEL_IDENTIFIER`, `SIMULATOR_PRODUCT_CLASS` | `RealityDevice14,1`, `N301` |
| `SIMULATOR_LEGACY_ASSET_SUFFIX` | empty string |
| `SIMULATOR_MAINSCREEN_WIDTH`, `…_HEIGHT`, `…_SCALE`, `…_PITCH` | 3840, 2160, `2.000000`, `264.000000` |
| `SIMULATOR_RUNTIME_VERSION`, `…_BUILD_VERSION` | 27.0, 24M362 |
| `SIMULATOR_FRAMEBUFFER_FRAMEWORK`, `SIMULATOR_HID_SYSTEM_MANAGER` | host paths under CoreSimulator's `Platforms/xros/…` (separate builds of the same two libraries, platform visionOS-simulator, same exported names as the `iphoneos` copies) |
| `SIMULATOR_VERSION_INFO` | "… Runtime: visionOS 27.0 (24M362) - DeviceType: Apple Vision Pro" |

What the guest reports (our probe, level 3): `UIDevice` model "Apple
Vision Pro", `systemName` **"visionOS"**, `systemVersion` 27.0,
`userInterfaceIdiom` raw value 6 (vision). A SwiftUI `WindowGroup`'s first
window measured 348.5 × 250.5 points.

## 4. How the reference simulator renders

### 4.1 What is shown

The DeviceHub canvas shows one 3840 × 2160 view from a simulated eye
position inside a simulated room. `simctl io <dev> screenshot` captures
exactly that view as a 3840 × 2160 PNG: the room (default "Living Room
(Day)"), the home view (app icons floating in front of the user, a tab
bar on the left with Apps, People and Environments), app windows as glass
panels at their 3D positions, volumes as 3D content, and immersive content.
When an app opens an ImmersiveSpace in the default (mixed) style, the
room stays visible, other apps' windows are hidden, and the app's entities
render in the room. At the end of boot, before the shell is up, the view
is a grey rounded card with the Apple logo on black (wakeboardd's boot
"pulse").

### 4.2 Where the picture is made

```
apps (UIKit/SwiftUI, RealityKit)                       guest
  │ Core Animation layer trees, RealityKit entities (network sync)
  ▼
backboardd
  ├─ CAWindowServer on a VIRTUAL display "Virtual-0" (2732 × 2048 @2)
  │    ("StartWindowServer: headless; not starting render server")
  ├─ RealitySimulation: compositor controller, scene/placement/immersion
  │    servers, natural input, synthetic environment (the room)
  └─ RealityKit engine (com.apple.re): render loop RSXRRenderLoop,
       render graphs renderSyntheticEnvironment / composeSyntheticEnvironment
         │  swapchain uid 1 → slot "Top"
         │  swapchain uid 2 → slot "SyntheticPassthrough"
         ▼
wakeboardd (HMD presenter, real-time thread)
         │  SimFramebuffer display 1 (LCD, 3840 × 2160, BGRA, 60 Hz)
=========│=========================================== host
         ▼
SimFramebufferServer → DeviceHub canvas, simctl io screenshot
(all GPU work of backboardd, wakeboardd, RealityEnvironment, pointeruid and
 apps goes through com.apple.metal.simulator[.<process>] → SimMetalHost)
```

Evidence for each arrow (§Evidence lists levels):

- **wakeboardd, not backboardd, is the framebuffer client.** Of all guest
  processes only wakeboardd (and CoreSimulatorBridge, as on iOS) maps
  `SimFramebuffer`; backboardd maps `SimulatorHID` only. On iOS backboardd
  maps both (`simframebuffer.md` §5.1).
- **backboardd's Core Animation server has no physical display.** It logs
  "StartWindowServer: headless; not starting render server", then
  RealitySimulation "Initializing CAWindowServer", "Initializing virtual
  display", and the main display becomes `CADisplay:Virtual-0` of
  2732 × 2048 at scale 2.
- **backboardd renders the 3D scene.** Its log shows the RealitySimulation
  set-up sequence (compositor controller, scene understanding, immersion,
  scene, entity interaction, placement, natural input, application,
  breakthrough and rendered-content servers), "Starting render loop:
  <RSXRRenderLoop>", "Reloading run loops for connected headsets", "Updated
  display mode successfully to MR", the RealityKit categories
  (`com.apple.re:Graphics`, `:Network`, `:Assets`, `:RealityFusion`,
  `:ECS.CARE`, `:CAProtocol`), and "loading synthetic environment
  'LivingRoomDay'" from the runtime path of §2.6.
- **wakeboardd composes backboardd's swapchains and presents.** "This the
  first boot of wakeboardd, keeping the display pulsing until system shell
  (backboardd) comes up", "First frame displayed" (before backboardd's
  render loop starts), then "moving swapchain uid=1 from backboardd to slot
  Top" and "uid=2 … to slot SyntheticPassthrough", "creating real time
  thread", state Pulse → RealTimeStarting → Run.
- **Apps are clients, not renderers.** A RealityKit app process (our probe)
  logs `com.apple.re:Network` "NetworkSyncManager: initialized" and
  registers about 100 component types for synchronization; its entities
  appear in the composed screenshot.
- **The host does not composite.** The host-side endpoints (§2.5) are the
  iOS set; no host compositor service was registered (`com.apple.xrserverd`
  was not); `simctl io` enumerates one display port; the screenshot of
  that port already contains the room and every layer. Host processes per
  device: `launchd_sim`, one `SimRenderServer`, five `SimMetalHost`.
  (DeviceHub's visionOS plug-in links the macOS RealityKit frameworks, §5.2;
  what it renders with them, if anything, is not part of the device's
  picture, which exists without a DeviceHub window.)

### 4.3 Metal host names

Per-process names that the host registered: `com.apple.metal.simulator.backboardd`,
`.wakeboardd`, `.RealityEnvironment`, `.pointeruid`, each with its own
host process. Every other process uses `com.apple.metal.simulator`. The
client behavior is that of `metal-sim-protocol.md` §1.1 (look up the
per-process name, fall back to the plain name), so a host that registers
none of the per-process names still serves everyone through the plain
name.

### 4.4 Display and framebuffer

`simctl io <dev> enumerate`: one display port (`com.apple.framebuffer.display`,
default 3840 × 2160, `'BGRA'`, 15 360 bytes per row, 33 177 600 bytes per
surface) and the framebuffer server with one connected screen: id 1,
"LCD", device name `primary`, unique id as in §3.3, integrated, 3840 ×
2160, dot pitch 264, preferred UI scale 2, `'BGRA'`, DCI-P3, SDR, refresh
6000 (hundredths, = 60 Hz), UI orientation "Ambiguous", no mask, no chrome.
iPhone Duo on iOS 27.1 had five screens (`simframebuffer.md` §4). There is
no rotation feature (§2.2).

### 4.5 Metal as the guest sees it

Our probe (`MTLCreateSystemDefaultDevice` in an app): name "Apple xrOS
simulator GPU"; `supportsFamily` true only for Apple1, Apple2, Common1;
`maxThreadsPerThreadgroup` 512³; `maxThreadgroupMemoryLength` 16 384;
`maxBufferLength` 256 MiB; `hasUnifiedMemory` false;
`recommendedMaxWorkingSetSize` 0; argument buffers tier 1; read-write
textures none; no ray tracing, dynamic libraries, function pointers, BC
formats, 32-bit float filtering, barycentrics, pull-model interpolation;
`supportsVertexAmplificationCount` 1 true, **2 false**;
`supportsRasterizationRateMap` false (1 and 2 layers); sample count 4 true.
This is the iOS simulator's profile (`metal-sim-protocol.md` §4.1). The
system renderer works within it, so Ycode's Metal→Vulkan layer needs no
stereo, multiview or variable-rate features for parity.

### 4.6 What this means for Ycode

- The existing path — guest renders through Ycode's Metal host, a
  headless SimFramebuffer replacement receives presented IOSurfaces, the
  display stream sends them to the viewer — **is the right path**. No host
  compositor, no host scene graph.
- The framebuffer client is **wakeboardd**. Its swap pattern (a real-time
  presentation thread at 60 Hz after "RealTimeStarting") may depend on the
  swap-completion callbacks and their target times more than backboardd
  does (`simframebuffer.md` §7 item 7); this is the first thing to check
  in R1.
- The GPU load is much higher than iOS: a physically based 3D room, glass
  materials and depth composition at 3840 × 2160, continuously. On the Mac
  backboardd used about a third of a core and one SimMetalHost about a
  fifth at an idle home view, and the backboardd SimMetalHost held about
  1.7 GB (top's MEM). This is the main risk for the Thor (§7.3).
- Frames move between guest processes as IOSurfaces (backboardd's
  swapchains handed to wakeboardd). Ycode's IOSurface service must support
  surfaces created in one process and presented by another
  (`iosurface-remote.md`).

## 5. Input and camera

### 5.1 What the user does (Device Hub, level 1)

Apple's "Interacting with your visionOS app in Device Hub":

| Mode or control | Mac input | visionOS meaning |
|---|---|---|
| Interact ("Select to interact with the visionOS content") | pointer position | where the eyes look (gaze) |
| | click | tap (look + pinch) |
| | click and hold | pinch and hold |
| | drag left/right/up/down | pinch and drag |
| | Shift-drag up/down | pinch and drag forward/back |
| | click and swipe | swipe |
| Viewpoint, any mode | W/S or Up/Down; trackpad pinch out/in | move forward/back |
| | A/D or Left/Right; scroll left/right | move left/right |
| | E/Q; scroll up/down | move up/down |
| | Control-drag | change the viewing angle (tilt/look) |
| Segmented control | "Drag to pan the camera" / "… dolly …" / "… tilt …" | drag moves the viewpoint sideways/vertically, forward/back, or turns it |
| Reset Camera button | | viewpoint and angle back to the start |
| Capture Pointer; Device > Keyboard > Keyboard Capture | Escape releases | pointer/keyboard go to the device instead of driving the camera |
| Game controller | left stick, L2/R2, right stick | move, down/up, look |
| Home button / Controls > Home | | open the home view |
| hover + click the top indicator | | Control Center |
| Settings inspector > Simulated Scenes | | choose the room |

Trackpad gestures follow the Mac's natural-scrolling setting. Two-handed
gestures are not listed for the visionOS canvas.

### 5.2 The host side (level 4)

The visionOS canvas is implemented by a DeviceKit plug-in inside Xcode,
`SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/VisionDeviceKitExtension.devicekitplugin`
(project name "PalomaSimService", version 85.0.7). From its metadata:

- It links SimulatorKit, CoreSimulator, GameController and (macOS)
  RealityFoundation/CoreRE/SwiftUI.
- It **exports three Indigo message builders of its own**:
  `IndigoHIDMessageForPalomaPose`, `IndigoHIDMessageForPalomaSelection`,
  `IndigoHIDMessageForPalomaCollection`, and imports SimulatorKit's
  `IndigoHIDMessageForButton`, `…ForDigitalDialEvent`,
  `…ForGameControllerEvent`. So pose, selection (gaze/pinch) and a
  "collection" (multi-part, presumably the manipulator) are Indigo HID
  messages to the guest's `IndigoHIDRegistrationPort`, like iOS touches
  (`hid-input.md` §1 item 4).
- It names a second channel to the guest daemon **vhmdd** ("Connecting to
  vhmdd service", `com.apple.vhmdd`) with operations
  `requestEnvironments`, `setActiveSyntheticEnvironmentAsync`, `getPose:`,
  `setPose:`, `setCamera`, `resetCamera`, and notifications for
  environment-list changes and "synthetic environment did load". vhmdd's
  log shows the other end: it forwards the installed environments and the
  active one between SurfBoard's environment service and the host.
- Camera-control mode names: `interact`, `pan`, `orbit`, `dolly`,
  `freeLook`, plus tilt; settings `panTiltSensitivity`,
  `PanDefaultDeadzone`, `InvertPanDirectionOnButtonDrag`; gaze options
  "Show Gaze Target", `toggleGazeFollowsMouse`, `invertGazeFollowsMouse`;
  pinch states `mouseOverPinch`, `mouseDownPinch`; "Hand Manipulator";
  pointer capture; capturing game controller
  (`com.apple.GameController.CapturingGameController`, device feature
  `hid.gamecontroller.capture`).

### 5.3 The guest side (level 3)

backboardd loads the HID bundle from `SIMULATOR_HID_SYSTEM_MANAGER` exactly
as on iOS and logs each virtual service:

| ID (`0xACEFADE0000000…`) | Identifier (`com.apple.SimulatorHID.…`) | Usage page / usage | Notes | iOS 27.1 |
|---|---|---|---|---|
| 00 | `GamePadService` | 1 / 5 | | same |
| 01 | `MainScreenButtonsService` | 0x0B / 1 | Built-In, Authenticated, PressCountTracking | same |
| 02 | **`DigitalDialService`** | 1 / 0x37 (Dial) | Built-In | absent |
| 03 | `ExternalKeyboardService` | 1 / 6 | | same (ID 02) |
| 04 | `ProximitySensorService` | 0xFF00 / 8 | Built-In, Placement 1 | same |
| 05 | **`PalomaPoseService`** | 0xFF00 / 0x72 | Built-In | present, unused by iOS |
| 06 | **`SelectionStreamService`** | 0xFF00 / 0x71 | Built-In | present |
| 07 | **`ManipulatorService`** | 0xFF00 / 0x6F | Built-In | present |
| 08 | `ScreenTouchService.731F1373-97EF-4DCA-BC31-14C516B3E06F` | 0x0D / 4 | DisplayIntegrated, `displayUUID` = the LCD | three on iOS (one per display) |

All carry `DeviceUsagePairs` equal to the primary pair, as on iOS
(`hid-input.md` §4.3). backboardd vends `com.apple.realitysimulation.naturalinput`
and `com.apple.realitysystemsupport.hid_server_backboard`; apps log
`com.apple.MRUIKit:MRUIRealityKitSimulationEventSourceLog` while
interacting. The event types and payloads the bundle dispatches for the
three vendor services were not observed (§9).

### 5.4 Pose and ARKit as an app sees it (level 3)

| Provider (`isSupported`) | Value |
|---|---|
| `WorldTrackingProvider` | **true** (no authorization required) |
| `HandTrackingProvider`, `PlaneDetectionProvider`, `SceneReconstructionProvider`, `ImageTrackingProvider`, `ObjectTrackingProvider`, `RoomTrackingProvider`, `EnvironmentLightEstimationProvider`, `StereoPropertiesProvider`, `VisualFidelityProvider`, `AccessoryTrackingProvider`, `SharedCoordinateSpaceProvider`, `BarcodeDetectionProvider`, `CameraFrameProvider`, `CameraRegionProvider` | false |

`queryAuthorization` for hand tracking and world sensing: notDetermined.
In an open ImmersiveSpace, `ARKitSession.run([WorldTrackingProvider()])`
succeeds, the provider state is `running`, and
`queryDeviceAnchor(atTimestamp: CACurrentMediaTime())` returns a tracked
`DeviceAnchor` every time. With the camera untouched after boot, the device
transform was position (0, 1.6, 0) m and forward vector (−0.216, 0,
−0.976): eye height 1.6 m, turned about 12.5° to the left of −Z; it stayed
constant for 30 s. The app process opened a connection to
`com.apple.vhmdd-sim` in that run. So the simulated head pose is the
camera pose; how camera movement reaches it (PalomaPose HID events, vhmdd
`setPose:`, or both) is open (§9).

## 6. Boot and run (Mac, level 3)

| Measure | visionOS 27.0, Apple Vision Pro | iOS 27.1, iPhone Duo (`first-boot.md`) |
|---|---|---|
| First boot, `bootstatus` terminal | 21.8 s and 18.0 s (two devices) | 22 s |
| First boot, room visible in a screenshot | 30.3 s | – |
| Migration | 34 plugins, 6–7 s; `success` **true**; slowest LaunchServices 3.9 s | 35 plugins, 17 s; `success` false |
| LaunchServices store | 4.8 MB, same schema 33554481 | 7.8 MB |
| Repeat boot, `bootstatus` terminal | 8.7 s, 12.2 s | 2 s |
| Repeat boot, room visible | 20.3 s | – |
| Processes after boot | 159–163 | – |
| Memory (sum of `phys_footprint`) | 6.4 GiB idle after first boot; 7.9 GiB after launching the apps below | – |
| Idle CPU | backboardd ≈ 33–38 % of a core, one SimMetalHost ≈ 17–19 % | – |

`bootstatus` reports "Waiting on BackBoard", then "Waiting on Data
Migration"; at "terminal" the screen still shows the boot card, the room
follows about 8 s later. The Mac was in normal use (browsers, Steam) during
the runs; times are indicative.

**Home view** (`DEV/data/Library/Preferences/com.apple.RealityLauncher.plist`,
key `ApplicationArrangement`, a JSON string of pages → elements, each
`{"application":{"_0":<bundle id>}}` or `{"folder":{"_0":{name, pages}}}`):
one page with Widgets (`com.apple.RealityWidgets`), Siri
(`com.apple.SiriApp`), Safari, Photos (`com.apple.mobileslideshow`), a
folder (Calendar, Maps, News, Reminders, Shortcuts), Settings, Files
(`com.apple.DocumentsApp`), Passwords. `simctl listapps`: 20 apps.

**Launches** (`simctl launch`): Settings, Safari, Photos, Files, Passwords,
Calendar, Maps, Reminders, News, Shortcuts, Widgets and Siri all started
and showed windows in the room (Maps asked for location). Launch calls
returned in 0.4–2.3 s, except the very first launch after the first boot
(Settings), which took 143 s: SurfBoard took the request at once and
runningboardd's spawn took 133 s ("Creating and launching job" →
"Bootstrap success"); the cause is unknown. After a repeat boot the first
launch took 2.3 s.

**Our app** (`research/experiments/visionos/VisionProbe`): a SwiftUI
window, a volumetric window with a RealityKit box (`RealityView`,
`InputTargetComponent`, collision shape), and an `ImmersiveSpace` with a
RealityKit sphere at (0, 1.5, −1.5). Installed with `simctl install`
(ad-hoc signed, `UIDeviceFamily` [7], `CFBundleSupportedPlatforms`
[XRSimulator]); window, volume and immersive space all opened
(`openImmersiveSpace` result `opened`), both entities rendered, ARKit as in
§5.4. Taps on entities were not tested (no GUI input).

## 7. What Ycode must add

### 7.1 Requirements

Identity and boot:

- **V-1** A device type `vision-pro`: model `RealityDevice14,1`, class
  `N301`, legacy asset suffix "", main screen 3840 × 2160, scale 2, pitch
  264; a capabilities file with the §3.3 answers (Ycode's own data, as for
  iPad, `ipad.md` §4); refused on non-xrOS runtimes and vice versa.
- **V-2** Runtime detection by `SystemVersion.plist` `ProductName`
  (`xrOS`) and build; per-runtime state keyed by build (24M362 and
  24M5291p share an identifier).
- **V-3** Bootstrap `Child` without the two extended-display variables;
  everything else as for iOS (§3.4).
- **V-4** Host names in the guest bootstrap: the iOS set minus
  NearbyInteraction, plus (optionally) the four per-process Metal names of
  §4.3; `com.apple.identityservicesd.desktop.sim2host` and
  `com.apple.xrserverd` may be skipped (the reference skips xrserverd).
- **V-5** A visionOS lean-boot list, by label (§2.4), if lean boot is used
  during development; parity benchmarks boot everything.

Rendering:

- **V-6** The headless framebuffer library serves **wakeboardd**: one
  display (id 1, `LCD`, `primary`, UID `731F1373-97EF-4DCA-BC31-14C516B3E06F`,
  3840 × 2160, scale 2, pitch 264, 60 Hz, `'BGRA'`), swap completion with
  plausible 60 Hz target times.
- **V-7** The Metal→Vulkan layer runs backboardd's RealityKit renderer and
  wakeboardd's presenter: their metallibs (`RealitySimulation.framework`,
  `CoreComposite.framework/default-cc.metallib`, `Hands.framework`, CoreRE's
  shaders in the shared cache), KTX/ASTC textures in Display-P3, the render
  graphs of §4.2, at 4K, continuously.
- **V-8** IOSurfaces shared from backboardd (swapchain producer) to
  wakeboardd (presenter), and from apps to backboardd (CA and RealityKit
  content).
- **V-9** The display stream at 3840 × 2160 (33 MB per raw frame): the
  viewer's default downscale should be 2 (1920 × 1080) or more; whole-frame
  damage is the normal case whenever the camera moves.

Input and camera:

- **V-10** The Ycode HID bundle publishes, in addition to the iOS
  services, DigitalDial (1/0x37), PalomaPose (0xFF00/0x72),
  SelectionStream (0xFF00/0x71) and Manipulator (0xFF00/0x6F), with the
  IDs and properties of §5.3, and one touch screen for the single display.
- **V-11** Host messages for pose, selection and manipulation (formats:
  §9 question 1), carried by Ycode's HID host service (`hid-input.md` §7).
- **V-12** Viewer mapping as in §5.1 (interact / pan / dolly / tilt
  modes, WASD/arrows + E/Q, Control-drag, reset camera, pointer and
  keyboard capture with Escape, Home, game controller later).
- **V-13** Room selection: the six rooms of §2.6 by key; first by the
  `activeSyntheticEnvironment` preference before boot (to be verified),
  later live through a vhmdd-equivalent channel (§9 question 3).

Apps:

- **V-14** Install and launch of `XRSimulator` apps (`UIDeviceFamily` 7)
  through the existing app paths (`app-install-launch.md`), with
  `WorldTrackingProvider` returning the camera pose and all other ARKit
  providers reporting unsupported (reference parity).

### 7.2 Rounds (one agent each)

| Round | Name | Work | Done when |
|---|---|---|---|
| R0 | VOS-COPY (owner or ops) | copy RR 24M362 to `$YCODE_DATA/runtimes/xrOS-27.0-24M362/RuntimeRoot` as in §2.7 | tree present, read-only, `SystemVersion.plist` reads 24M362 |
| R1 | **VOS-BOOT** | V-1…V-5 and the parts of V-6 that boot needs; re-check `dyld_sim` handoff, `launchd_sim` bootstrap and host-library imports on this build; first boot runs 34 migration plugins | DEV has `LastSystemVersion` 24M362 and a LaunchServices store; SurfBoard, backboardd, wakeboardd, vhmdd, RealityLauncher running; backboardd logs "Starting render loop"; wakeboardd reaches state Run; the framebuffer receives frames (the boot card at least); no Ycode-only crash reports |
| R2 | **VOS-RENDER** | V-6…V-8: whatever the Vulkan layer, IOSurface service and framebuffer library lack for the RealityKit renderer and wakeboardd; GPU instruments as in `stage8-contract.md` §14–15 | a Ycode screenshot shows the Living Room (Day) and the home view, structurally like the reference (§4.1); frame time measured at idle |
| R3a | VOS-INPUT-R (dirty side) | observe the Indigo payloads of pose/selection/collection and their guest delivery (DeviceHub driven with the owner's GUI approval, or the plug-in's exported builders called from our own Mac tool, as `hidsend` did for iOS); answer §9 questions 1–3 | an input section in this spec with formats and a test plan |
| R3b | **VOS-INPUT** | V-10, V-11 from R3a's spec | in Ycode: a tap on a home icon opens the app; camera moves change the pose our probe reads |
| R4 | **VOS-VIEWER** | V-9, V-12, V-13 in `ycode-sim-viewer` and the display stream | the viewer shows the 4K view downscaled, camera modes and keys work, Reset Camera returns to (0, 1.6, 0); room choice works |
| R5 | **VOS-APPS** | V-14; run VisionProbe and the default apps of §6 under Ycode; record differences | VisionProbe output matches §4.5/§5.4; window, volume and immersive space render |
| R6 | VOS-AR (Ycode design, later) | the roadmap's AR environment (`docs/FUTURE.md`): Ycode's own providers beyond the reference (planes, meshes from the room geometry, hand pose) and the virtual iPhone in the room (`specs/frameworks/arkit/simulated-world.md`) | its own design note; not reference parity |

R1 and R2 can overlap only after R1's boot reaches backboardd's render
loop. R3a is dirty-room work and must not be given to a clean agent.

### 7.3 Risks

1. **GPU load and shader coverage.** The system renderer is RealityKit
   (PBR materials, image-based lighting, glass, depth composition) at
   3840 × 2160 in backboardd, all the time. Through the Vulkan layer on the
   Thor this is far heavier than the iOS home screen; expect new shader
   translation gaps (render graphs, compute passes), more `astc`-like hangs
   (`stage8-contract.md` §13.5, §15.5) and memory pressure (the reference's
   backboardd SimMetalHost held about 1.7 GB).
2. **wakeboardd's real-time presenter.** It creates a real-time thread and
   paces by the display; if swap callbacks or target times are wrong it may
   spin, starve or drop frames (`scheduling-policy.md`, `thread-latency.md`).
3. **Cross-process surfaces** from backboardd to wakeboardd (V-8).
4. **Vendor HID formats unknown** (R3a needed before any camera input).
5. **Stream bandwidth** at 4K; the viewer must downscale (V-9).
6. **Boot cost**: about 160 processes and 6–8 GiB of footprint on the Mac;
   the Thor has room (122 GB) but boot time under Ycode will be several
   times the Mac's (iPad first boot under Ycode: 200 s, `ipad.md` §9.1).
7. **The 133 s first launch** after the first boot (§6) may also appear in
   Ycode; it is a reference behavior until explained.
8. **Two runtimes with one identifier** (§2.1).

Not risks: stereo, foveation, vertex amplification, eye tracking, hand
tracking — none is used by the reference simulator.

## 8. IDE notes

The destination list must offer "Apple Vision Pro" for the xrOS runtime
(families [7, 2, 1] on the device type, [7] on the runtime; no
`restrictedToDeviceTypes`), build with the `xrsimulator` SDK (platform
`XRSimulator`, target triple `arm64-apple-xros27.0-simulator`), and show
the canvas controls of §5.1 in Ycode's own design.

## 9. Open questions

1. The Indigo payload layouts of the Paloma pose, selection and collection
   messages, and the HID event types and fields backboardd receives from
   the PalomaPose, SelectionStream and Manipulator services.
2. Whether camera movement reaches the guest only as PalomaPose HID events,
   or also through vhmdd (`setPose:`/`setCamera`), and which component turns
   the pose into the `DeviceAnchor` that ARKit returns (`com.apple.vhmdd-sim`
   was contacted by the app).
3. The vhmdd host protocol (environment list, selection, pose, reset) and
   whether writing `activeSyntheticEnvironment` before boot selects a room.
4. Which host service `com.apple.xrserverd` is, and whether anything
   degrades without it (nothing visible did).
5. *(Answered, §10.6.6, level 3.)* Exactly which SimFramebuffer calls
   wakeboardd makes (number of swapchains and layers, presentation modes,
   callback timing): one swapchain, mode 2, no options; one surface per
   swap, two surfaces alternating; 60 swaps per second with target time
   0; callback 1–20 ms after the submit.
6. The cause of the 133 s first app launch after the first boot.
7. The reference's frame rate and GPU time per frame at an idle home view
   and during camera motion.
8. What DeviceHub's plug-in renders with the macOS RealityKit frameworks it
   links (gaze target or camera gizmo overlays are likely; not needed for
   the device picture).
9. *(Answered, §10.6.4, level 3: only default-level messages, the same
   ones Ycode shows; "Device doesn't suport light clustering" is logged in
   the reference too; no debug-level message falls in the window; the
   Metal connections, MTLCompilerService and cfprefsd are the only
   services used.)* **(R1 blocker)** In a reference boot, what backboardd logs (debug level;
   subsystems `com.apple.re`, `com.apple.Metal`,
   `com.apple.RealitySimulation`) between "Initializing shared simulation
   and host server" and "Starting render loop" — is "Device doesn't suport
   light clustering" logged there too? — and which Metal host messages
   (types, ops, reply contents) and other host or guest services backboardd
   uses in that window. Under Ycode RealityKit's render manager aborts there
   ("Render manager was requested but failed to initialize", §10.4) in
   backboardd and in datamigrator alike.
10. *(Answered, §10.6.1–§10.6.3, level 3: the same selectors in the same
   order with the same answers as under Ycode, apart from the z thread
   limit; the cause of the abort is therefore not a capability answer and
   is still open, Q12.)* Which `MTLDevice` selectors backboardd calls in the reference and their
   answers (a recorder like Ycode's `mtlwatch.dylib`, §10.3), to compare
   with §10.4's list, including `supportsSeparateDepthStencil` and
   `supportsLayeredRendering`.
11. *(Answered, §10.6.6, level 3: no swap at all during Pulse; the first
   swap comes from the real-time thread when Pulse ends, which follows
   SurfBoard's "headset in use"; Ycode's behavior matches.)* Whether wakeboardd submits swaps (`SFBSwapchainSwapBegin` …
   `SwapSubmit`) while it is in the Pulse state before backboardd's
   swapchains arrive, or only from the real-time thread; under Ycode it
   creates a mode-2 swapchain and never swaps (§10.2). (Extends Q5.)
12. **(R1 blocker, narrowed in §10.7, still open.)** Which step of the render-manager start
   (§10.6.2 steps 1–9) returns failure under Ycode. The reference shows it
   is not a capability answer, a missing device-level object, a failed
   command buffer or slowness (§10.6.3); §10.6.7 lists what Ycode should
   record to find it. Under Ycode (§10.7.2) every Metal call of the start
   succeeds, all steps 1–9 happen, and the start then runs further stages
   (shadows, primitive shapes) and returns failure **without any further
   Metal call, system call or library look-up**, before the VFX command
   queue of step 9 is asked for. The decision uses state the process
   already has. *(Narrowed again in §10.8, level 3: with the same recorder,
   every stage of the reference start up to the shadow render manager
   matches Ycode's in its calls, counts and answers apart from two heap
   sizes, and those sizes are shown not to matter. The first stage that
   differs is the next one, the VFX manager joining the render manager:
   the reference reads one default and creates a 64-buffer command queue
   there; under Ycode that stage does not happen. Why it does not is §9
   Q14.)*
13. *(Answered, §10.8, level 3; offsets and symbol names level 4.)* In
   the reference, with the same tools as
   §10.7.1 (call recorder with caller chains, allocation window after the
   primitive-shape stage): which calls follow the last primitive-shape
   buffer (6144 bytes, the hemisphere) up to the VFX command queue, and
   does the reference create those primitive-shape buffers before or after
   that queue? A side-by-side list names the stage whose result differs.
   **Answer:** in the reference the VFX command queue comes **before** the
   primitive-shape buffers, not after them. The order is: shadow render
   manager, then the VFX manager joins the render manager (it reads
   `com.apple.re.enableVFXUseRERenderCommandQueue`, which is unset, and
   creates a command queue with `newCommandQueue`, 64 buffers), then the
   23 primitive-shape buffers (sizes identical to Ycode's), then the reads
   of `com.apple.re.enableCascadedShadowMaps`, `…enableDecals` and
   `…enableSoftShadows` (all unset). The start then returns success and
   "ImportGraphicsResources" is logged about 3 ms later. So nothing follows
   the last primitive-shape buffer before the queue. The reference logs
   "Compiling PSO RT name=computeSDFGradient tgsimotew=0 fc=" too (5 of 5
   boots). It reads 128 distinct `com.apple.re.*` defaults before
   "ImportGraphicsResources", and none of them has a value. The first stage
   that differs is the VFX manager's hookup (§10.8.2).
14. *(Answered on the clean side, §10.9.2–§10.9.3, level 3; the input
   behind it is Q15.)* Why the render-manager start under
   Ycode skips the VFX manager's hookup (§10.8.2 row 10), and with it
   returns failure. §10.8.4 lists the measurements that answer it under
   Ycode with Ycode's own recorder: whether the VFX manager is constructed
   and initialized in the engine start, whether the hookup is entered,
   and whether it reads its default. **Answer:** the VFX manager is
   constructed and initialized as in the reference; the hookup is entered
   (it stores the render manager) and returns before its default read,
   because two flag bytes of the render manager are 0. With those two
   bytes set to 1 before the hookup, the hookup reads its default, creates
   its 64-buffer queue, and the start succeeds ("ImportGraphicsResources",
   "Starting render loop"). The bytes are 1 after the render manager's
   constructor and are cleared inside its start, between the render
   context manager's creation and the CPU-count query, from an input not
   yet found (Q15).
15. *(Answered, §10.10.1, level 3; the place of the buffer level 5.)* In the reference's backboardd,
   with Ycode's recorder as in §10.9.1 (`MTLREC_WINDOW_AFTER=MeshManager4init`,
   `MTLREC_WINDOW_MATCH=NoSuchFrame`, `MTLREC_SCAN_AT="Ebb+1984 |,Ebb+2072 |,CALayerContentsCacheC2"`,
   `MTLREC_SCAN_FRAME=RenderManager4init`, `MTLREC_SCAN_BLOCK_SIZE=512`;
   the render manager is the 512-byte block whose word +0x10 points at a
   CoreRE string, `MTLREC_BLOCK_MATCH=0x10=<that address>`, 0x1b073c978
   under Ycode, where the shared cache is not slid): what are the render manager's
   bytes +0xd0 to +0xd7 at those three points? Under Ycode they are
   `01 00 00 00 01 01 00 00` at +1984 and `01 00 00 00 00 00 00 00` after
   (+0xd0 is a u32 that becomes `hw.physicalcpu`). If the reference keeps
   +0xd4 and +0xd5 at 1: which input does the render manager's start read
   between return offsets +1984 and +2028 (no call, look-up, preference
   read, system call or Metal call happens there under Ycode, §10.9.3), and
   what is its value in the reference? If the reference clears them too:
   what sets them to 1 again before return offset +2996.
   **Answer:** the reference keeps them at 1: `01 00 00 00 01 01 00 00`
   at +1984, `0e 00 00 00 01 01 00 00` at +2072 and at the CA layer
   contents cache (14 is the Mac's `hw.physicalcpu`). The input is the
   width of the `hw.physicalcpu` answer. The start asks for it with
   `sysctlbyname`, an 8-byte buffer length, and its own u32 at +0xd0 as
   the buffer, so the flag bytes are bytes 4 and 5 of that buffer. The
   reference writes 4 bytes; Ycode writes 8, and their zero upper half
   clears the flags. An 8-byte answer given to backboardd in the
   reference clears them too and causes the same abort.
16. *(Answered, §10.10.2, level 3.)* Shared textures
   (`metal-sim-protocol.md` §5.10): the reference host's full reply to
   `messageType` 19 (keys, `replyData` layout) and the creation
   properties of the IOSurface it makes, above all the value under the
   key `MetalSharedTexture` (`kIOSurfaceMetalSharedTexture`), which the
   guest needs to make a shared-texture handle; whether
   `newSharedTextureWithHandle:` in a second process sends a message to
   the host, and which. In the reference: wakeboardd makes its layers with
   `newSharedTextureWithDescriptor:` and sends their handles to backboardd
   inside its swapchain description (`cp_swapchain`).
   **Answer:** the reply has exactly `iosurfaceXPCObject` (a Mach send
   right) and `replyData` (u32 texture ref, u32 0). The surface carries
   **no** `MetalSharedTexture` value. What a handle needs is the creation
   property `kMetalRegistryID` equal to the device's `registryID`; the
   surface's creation properties also describe the texture with
   `kMetal…` keys. Opening a handle, in the same or a second process,
   sends `messageType` 20 (`command` op 43, `iosurface`, optional
   `label`); the reply's `replyData` is the texture ref and descriptor.
   The handles reach backboardd inside an NSXPC message, each surface as
   an XPC object (a Mach send right).
17. *(New, OBS3.)* The format of the power-management assertion requests
   that backboardd's DisplayReveal sends to the host-side Mach service
   `com.apple.PowerManagement.control` (MIG, not XPC), and the reply
   that makes "Acquiring wake assertion … Initial Boot User Active"
   succeed (§10.10.3). Under Ycode it fails with -536870199.
   *(Resolved without the reference, §10.11.4: the message format is the
   MIG subsystem `powermanagement` of Apple's open-source IOKitUser
   (`powermanagement.defs`, level 1); Ycode now serves it and grants every
   assertion. The reference's own replies stay unrecorded; they are not
   needed while the guest accepts Ycode's.)*
18. *(Answered, §10.12.1, level 3: 24 is `updateFence:afterStages:` and
   25 `waitForFence:beforeStages:` (u32 fence ref, u32 render stages; `04
   00 00 00 02 00 00 00` is fence 4, fragment stage); 132 is
   `setVisibilityResultMode:offset:` (u64 offset, u64 mode); 212 and 213
   are the compute encoder's `updateFence:` and `waitForFence:` (u32 fence
   ref). Other unlisted records and corrections to §8 are in
   `metal-sim-protocol.md` §8.)* Render-encoder records 24, 25 and 132 and compute-encoder
   records 212 and 213, which `metal-sim-protocol.md` §8 does not list.
   Under Ycode, backboardd sends them in every frame (one 24 and one 25 per
   draw, about 5 000 and 7 600 in 130 s; 132 about 300; 212/213 a few):
   op 24 and op 25 bodies are 8 bytes, `04 00 00 00 02 00 00 00` in the
   first records; op 132 is 16 bytes of zeros; ops 212 and 213 are 4
   bytes (`0x34`, `0x10`). With Ycode's recorder or `mslog` in the
   reference's backboardd during the render loop: which encoder call each
   op records (for example `setVertexAmplificationCount:viewMappings:`,
   `setVertexBytes:length:atIndex:`, `setThreadgroupMemoryLength:`,
   `setScissorRects:count:`), and the field layout (what 4 and 2 mean).
19. *(Answered, §10.12.2, level 3: per layer one 17 by wakeboardd and two
   18 by the opening process; the second 18 does carry `eventPort`
   MACH_PORT_NULL in the reference too, because the opener calls
   `newSharedEventWithHandle:` with a nil handle; the host replies to it
   with an empty dictionary and the call returns nil. The first 18 has
   the real right and a label, and gets `replyData` (event ref, 0).)* Shared events of wakeboardd's swapchain layers
   (`messageType` 17/18). Under Ycode, for each of wakeboardd's three
   layers, wakeboardd exports one event (17) and the opening process sends
   two 18s right after each other: one with the exported event's right and
   one whose `eventPort` is MACH_PORT_NULL (§10.11.3). In the reference,
   with `mslog` on backboardd's and wakeboardd's Metal connections during
   the layer set-up: how many 17s and 18s per layer, whether an 18 ever
   carries a null `eventPort`, and what the host replies to it (an event
   ref, an empty reply, or an `error`).
20. *(Answered, §10.12.3, level 3: in a pulsing reference boot the swapped
   surfaces are all zero for the first 0.75 s after Run, then show only a
   faint boot logo, and stay black until about 7.25 s after Run, when the
   room and home view fade in within 1 s, about 50 ms after backboardd's
   "Compiling PSO … name=composeSyntheticEnvironmentDefinition …" line.
   backboardd's layer textures are all zero (alpha included) from their
   opening until Run in the reference too; after Run layer 1 holds the
   logo, and from the room's appearance layer 1 holds the home view and
   layer 2 the opaque room.)* The first frames after wakeboardd enters Run (§10.6.6). In
   the reference, with Ycode's recorder's SimFramebuffer interposition in a
   first boot: do the first swapped surfaces already show the room, or are
   they black for some seconds (how long, until which backboardd or
   RealityEnvironment log line)? And in backboardd's layer textures
   (wakeboardd-layer 1 and 2, `BGRA8Unorm_sRGB`): is the content after the
   first render-loop frames non-zero (any read-back the recorder can make,
   for example a blit of slice 0 into a shared buffer)? Under Ycode both
   layers read back as all zero bytes (alpha included) for 2 minutes
   (§10.11.2).
21. *(Answered, §10.15, level 3: the rooms come from the runtime, not
   from MobileAsset or the network. (a) "Catalog assets [28]" lists each
   of the six rooms twice, `state=installed version=1.1.19…1.1.23
   path=RR/System/Library/Assets/SystemEnvironments/SyntheticEnvironments/<room>/AssetData`
   and `state=unavailable version=1.0.0`; the installed entries are
   chosen. (b) mobileassetd answers exactly as under Ycode: result 2,
   "0 listed in the catalog and 0 local (0/0 downloaded, 0 preinstalled)
   … 0 installedWithOS"; after the catalog download, 21 server-only assets,
   none of them a room. (c) With the guest's network refused the room
   appears as usual; the catalog download fails with 60 and is retried.
   (d) `AssetsV2/com_apple_MobileAsset_SystemEnvironmentAsset/` holds only
   the downloaded catalog XML and a `.xml.purged` copy (nothing without the
   network); RealityEnvironment reads `<room>/Info.plist` and
   `<room>/AssetData/Config.plist` under RR, backboardd reads the `.usdc`
   and the `AssetData/0/*.ktx` files under RR. Ycode's guest misses the
   rooms because Ycode's `getattrlistbulk` packs `ATTR_CMN_ERROR` in every
   record; the same record form makes the reference fail the same way.)*
   How the reference's RealityEnvironment gets the room's
   asset. Under Ycode (§10.14.3) RealityEnvironment's SystemEnvironments
   asks mobileassetd for `com.apple.MobileAsset.SystemEnvironmentAsset`
   (MA_QUERY_ASSET_TYPE, return type 2, MAUnionOfCatalogInstalled);
   mobileassetd answers result 2 (MAQueryCatalogNotDownloaded, "0 local
   (0/0 downloaded, 0 preinstalled)", no catalog under
   `DEV/data/private/var/MobileAsset/AssetsV2/`), the catalog download
   fails (59, MADownloadCannotFindHost: the guest has no network), and
   SystemEnvironments then lists the six synthetic rooms (and `Starfish`)
   as `state=unavailable`; "Loading environment asset LivingRoomDay into
   entity" ends in "setSyntheticSceneAsset: Error loading asset:
   SystemEnvironments.EnvironmentAssetError.configurationError", and
   backboardd never compiles `composeSyntheticEnvironmentDefinition`.
   RealityEnvironment enumerates `RR/System/Library/Assets/SystemEnvironments/SyntheticEnvironments`
   (six entries) but opens nothing inside it. In the reference, in a first
   boot of a new device: (a) the `Catalog assets [N]` block that
   RealityEnvironment logs (subsystem `com.apple.SystemEnvironments`,
   category `asset`): the `state=` of `LivingRoomDay` and the other
   synthetic rooms; (b) mobileassetd's `determineAssets: … SystemEnvironmentAsset …`
   line (result, how many catalog, local, preinstalled and installedWithOS
   assets); (c) whether the room still appears with the Mac's network
   off (no catalog download) and, if not, what RealityEnvironment logs
   instead; (d) after the boot, which files exist under
   `DEV/data/private/var/MobileAsset/AssetsV2/` for
   `com_apple_MobileAsset_SystemEnvironmentAsset` (catalog XML, asset
   folders) and which path RealityEnvironment opens to read the room's
   `Config.plist` and `.usdc` (a `fs_usage`-style list of opens is
   enough).

22. *(Answered, §10.17 and `audio-host.md`, level 3 (level 1 for the
   CoreAudio codes and records): (a) yes. In a first reference boot
   backboardd logs "Initializing Phase audio engine... update mode =
   manual", builds the private aggregate `iOSSimulatorAudioDevice-<pid>-0`
   over the default output ("Built valid aggregate"), "Hardware output: 2
   channels", "engine@…: created with mode default, sr 48000 Hz" and
   "Initializing Phase audio engine complete." 7.7 s later, with no
   failure. The default output device the guest sees is the Mac's own
   (the guest talks to the Mac's audio daemon): here a Bluetooth headset,
   UID `<address>:output`, 44 100 Hz, one output stream of 2 channels
   (Float32, 8 bytes per frame), buffer 512 frames (range 14…1024),
   latency 8 961 frames, no input. (b) Only `com.apple.audio.audiohald` is
   used, never `com.apple.audio.coreaudiod`. The protocol is MIG-style:
   requests 1010000 + n, replies + 100, 30 s timeouts; about 25 message
   kinds (register, get object, has/settable/get/set property by data type,
   listeners, create IO context, create aggregate, start/stop IO,
   workgroup port, property-changed notification); per-object send
   rights; IO through a shared region and a pair of 24-byte messages per
   cycle. The smallest service that starts PHASE and runs IO, tested by
   rewriting the reference's replies inside the guest: one output device
   with one stream, empty plug-in, box, clock, tap and process lists, no
   controls, no custom properties, no notifications, aggregate creation
   (required), IO contexts, and the IO protocol with a real workgroup
   port. (c) `DEV/data/var/run/simulatoraudio/audiosettings.plist`
   (`SIMULATOR_AUDIO_SETTINGS_PATH`), keys `sim_input_device_uid`,
   `sim_output_device_uid`, `sim_ringer_state` (1), `sim_volume` (60). The
   guest's CoreSimulatorBridge writes it from the host's
   `com.apple.coresimulator.audio.plist` about a second after it starts,
   after backboardd's first open: "Failed to open audio settings plist!"
   appears in the reference too and is harmless. (d) Yes: with both
   look-ups refused inside the guest the reference logs Ycode's errors and
   aborts with 'API Misuse', "Cannot create a PHASEMaterial with nil or
   invalid PHASEEngine", 0.4 to 0.8 s after the room's PSO line, 12 times
   in 150 s.)*
   **(R5 blocker, §10.16.3.)** What the host's audio services answer.
   Under Ycode backboardd's PHASE engine never initializes (no HAL system
   object, no default output device) and, once the room loads, backboardd
   aborts with "Cannot create a PHASEMaterial with nil or invalid
   PHASEEngine". In the reference visionOS 27.0 boot: (a) does backboardd
   log "Initializing Phase audio engine complete" without "PHASEEngine …
   Failed to initialize", and which default output device does the HAL
   report (name, sample rate, channels)? (b) Which messages do guest
   processes (backboardd first) send to the host-side endpoints
   `com.apple.audio.audiohald` and `com.apple.audio.coreaudiod` up to the
   engine's start: message ids or MIG subsystem, the objects and property
   selectors asked, and the replies (the minimum a host must give for one
   output device)? (c) The "audio settings plist" that
   SimulatorDeviceSettings opens: its path and keys, and whether it exists
   in the reference. (d) With those host services unreachable, does the
   reference backboardd abort the same way once the room loads?
23. *(New, R4a.)* The result of `air.atomic.global.cmpxchg.weak.i32`.
   RealityKit's compute functions send it as
   `i32 (ptr addrspace(1), ptr, i32, i32, i32, i32, i1)` (§10.13.3).
   Ycode reads the result as the success flag (1 or 0) and the second
   operand as `expected`, written back with the value found. With a probe
   shader of ours compiled for the simulator (a kernel that calls
   `atomic_compare_exchange_weak_explicit` once on a known value and once
   on a different one, and stores the call's result, `expected` and the
   object), run on the reference: is the i32 the success flag (and which
   value on success), and what are the three i32 operands (the two memory
   orders and the scope, in which order)?
24. *(Answered on the clean side, §10.20.2, level 3; a reference capture
   would confirm it: op 29, whose last word carries the base instance in
   its low half and stale bytes in its high half.)* The base instance of backboardd's `vsUnlit` draws. Under
   Ycode (after R4b's decoder corrections) backboardd's depth-only draws
   with `vsUnlit` (indexed, 36 indices, 6 to 8 instances) decode with base
   instances 1 072 693 248, 1 084 227 584 and 1 085 145 088 (0x3FF00000,
   0x40A00000, 0x40AE0000: float or double bit patterns), and earlier
   `vsManualInstancing` draws with 2 359 296 (§10.13.2). With `mslog` in
   the reference's backboardd during the room's frames: which record op
   carries these draws, its body bytes, and the base instance the
   encoder call passed.
25. *(New, R7.)* Argument encoders (`messageType` 12 ops 16, 17, 19;
   `metal-sim-protocol.md` §4.2). visionOS RealityKit binds its material
   parameters through tier-1 argument buffers (`fsCALayer`'s buffer 13 is
   an `indirect_buffer` of type `re::RealityKitParametersTier1`). Under
   Ycode, which answers op 17 with an encoded length of 24 for every layout
   and refuses op 19, the 264-byte argument buffer bound to every icon
   draw of the home view stays all zero (§10.20.7), and backboardd sends
   op 19 set calls with encoder ref 1, kind 0 (argument buffer, offset 0)
   followed by kind 1 (buffer) for indices 0–14 (the four words after the
   index are always 0, 0x100, 0, 0). With `mslog` and a probe of ours in the
   reference (a layout of a buffer, a texture and a sampler member with ids
   0, 1, 2 and one with ids 0, 5, 9, and an encoder writing into a shared
   argument buffer at offsets 0 and 256): (a) after op 19 returns, are the
   member bytes already in the guest's argument buffer, i.e. does the host
   write them (and which value for each kind: the buffer's `gpuAddress`
   plus the offset; for a texture the texture's ref or another ID; for a
   sampler the op-39 ID)? (b) at which offset is member id n (n × 8, or the
   position among the layout's members)? (c) how does the reply to op 17
   (encoded length and alignment) follow from the layout's members? (d)
   what do the four words of op 19 hold (an array index or a member offset)?
   *(R7b, §10.20.7: Ycode now writes the members from the host, member n at
   8n; the icons appear. The questions stand for the exact layout.)*
26. *(New, R7b.)* The room's parts left out of some frames (§10.20.9).
   Under Ycode backboardd draws the room 30 times a second and, in a fixed
   cycle of 16 room frames that starts with a 768 × 432
   `fsLinearizedDepthAsColor` pass, leaves the 41 520-index part out of
   three frames and the 162 624-index part (the walls) out of two. On the
   reference, with Metal's frame capture or `mslog` in backboardd while the
   room shows: (a) does the room pass ever lack one of its five draws, and
   (b) is there a 768 × 432 linearized-depth pass, how often, and which
   attachments does it write?

## 10. Round R1 under Ycode (agents VISIONOS-R1 and R1b, 2026-10-26/27)

Clean-room implementation notes and Ycode boot results (level 3: Ycode's
own simulator on the Thor with the copied 24M362 runtime; guest
`log stream` one-shots, Ycode traces and thread reports, our probes). No
Apple simulator, Xcode or reference tool was run or opened for this round.

### 10.1 What `ycode-simd` does for a visionOS runtime

- **Runtime and device type (V-1, V-2).** `SystemVersion.plist`
  `ProductName` `xrOS` makes a runtime a visionOS runtime; the type
  `vision-pro` (`RealityDevice14,1`, `N301`, 3840 × 2160 @2, pitch 264,
  idiom `vision`, the fixed display UID of §3.3) is the default there and
  is refused on iOS runtimes, and the iOS types on visionOS runtimes.
  `proc_info`'s platform answer is 12 (visionOS simulator) on such a
  runtime. The device keeps its type (`DEV/ycode-device-type`).
- **Bootstrap (V-3).** `Child` has no extended-display variables;
  `SIMULATOR_VERSION_INFO` names "visionOS 27.0 (24M362)";
  `YCODE_FRAMEBUFFER_DISPLAY_UID` carries the fixed display UID to Ycode's
  framebuffer library (§10.3).
- **Ycode's own guest images.** dyld_sim loads only images of the
  process's platform into visionOS processes, so the three host libraries,
  the framebuffer library and the HID bundle get copies whose
  `LC_BUILD_VERSION` names visionOS simulator 27.0 (in
  `DEV/ycode-frameworks/`; `GuestImagePlatform.swift`). They load:
  wakeboardd maps the framebuffer copy, backboardd the HID copy
  ("Initialized Simulator HID System Manager"), as §4.2 and §5.3 say.
- **Host services (V-4).** No change was needed: the host registers the
  same Mach names as for iOS (configd, `com.apple.IOSurface.Remote`,
  `com.apple.metal.simulator`, the HID service). backboardd looks up
  `com.apple.metal.simulator.backboardd` three times (one per connection),
  gets nothing and falls back to the plain name (`metal-sim-protocol.md`
  §1.1); `com.apple.xrserverd` and
  `com.apple.identityservicesd.desktop.sim2host` were not looked up by the
  processes that ran.
- **Snapshots and golden devices (§2.1).** The warm-boot launcher's
  snapshot fingerprint includes the runtime's `ProductName` and
  `ProductBuildVersion` by value (besides its path), and a golden device
  is refused for another device type and warned about for another runtime
  build (`DeviceLayout.checkTemplate`), so 24M362 and 24M5291p state never
  mix.
- **Lean boot (V-5).** Not used in R1. The iOS list is label-based; its
  labels that the visionOS runtime lacks (`nanoregistrylaunchd`) are inert.
  A visionOS-specific list is left to a speed round.
- **`private/var/db/modelmanagerd`** (absent from the copy, unreadable at
  the source): not needed. `com.apple.modelmanagerd` spawned and ran
  ("job state = running"); nothing was created for it.

### 10.2 How far a cold boot gets

Device `d1`: one first boot, then twelve short repeat boots (diagnostics), release build of the
`visionos-r1` branch, frames every 10 s, the Thor shared with other agents'
runs.

| Step | Result |
|---|---|
| launchd_sim, bootstrap, host bind | as on iOS |
| wakeboardd | starts about 1.5 s after launchd_sim; "This the first boot of wakeboardd, keeping the display pulsing until system shell (backboardd) comes up"; Metal pipelines compiled (MTLCompilerService spawned for it on the first boot); "State transition HMD completed (Config -> Pulse)"; "First frame displayed" **4.4 s** after `ycode-simd` started (cold first boot) |
| lsd | seeded the LaunchServices store on the first boot ("LSNotificationDatabaseSeedingComplete" 62 s after start; store 3.8 MB, schema 33554481) |
| backboardd | HID system up (Ycode's bundle), AttentionAwareness, "StartWindowServer: headless; not starting render server", RealitySimulation "Initializing CAWindowServer", "Initializing virtual display", "Initializing shared simulation and host server", RealityKit's Metal set-up (CoreRE metallibs, compute pipeline `computeSDFGradient`, "Device doesn't suport light clustering"), then **aborts**: CoreRE "assertion failure: 'renderManagerInitSuccessful' (init:line 702) Render manager was requested but failed to initialize." launchd restarts it every ~10 s; each instance ends the same way (38 s into the first boot, 10–13 s per later instance) |
| datamigrator | started by backboardd's request; **aborts with the same CoreRE assertion** after about 60 s (three times in the first boot), so the first-boot migration never completes and `com.apple.migration.plist` is not written |
| SurfBoard | starts, then exits 255 when backboardd dies ("FATAL: CARenderServer mach port died") |
| vhmdd | starts and stays up |
| RealityLauncher, RealityEnvironment, pointeruid | never started (they follow SurfBoard) |
| fileindexerd | the iOS ENODEV fatal error (as on every Ycode iOS type) |
| Host | no `ycode-simd` crash in 13 boots |

**No frame reached the host.** wakeboardd's framebuffer calls (Ycode's
call log, §10.3) are, in order: `SFBConnectionCreate`, `Connect`,
`CopyDisplays`, `SFBDisplayGetType`, `GetDeviceSize`,
`SFBDisplayCreateSwapchain` with presentation mode **2**, `GetDeviceSize`,
`GetCurrentMode`, and nothing else: no `SwapSetCallback`, no
`SwapBegin`/`AddSurface`/`Submit`. Its two 3840 × 2160 IOSurfaces
(33 177 600 bytes each, `BGRA8Unorm_sRGB` textures over them) and its
compositor pipelines ("Compositor mixed reality render pipeline for layer
0", `composite_N_layers_frag_func`) exist, but it submits no Metal command
buffer. Its compositor thread then waits on its own command port (a
receive with no timeout), its main thread vends the `com.apple.wakeboard.*`
services, and an `mk_timer` is created but never armed: the process waits
for its clients (backboardd's swapchains), so "First frame displayed" does
not mean a swap under Ycode. `--screenshot` therefore reports "no surface
to capture"; the display server would show nothing.

**Boot time.** Time to the last reachable milestone (wakeboardd "First
frame displayed"): 4.4 s cold, first boot. Time to a frame or to the home
view: not reached.

### 10.3 Ycode changes made while finding this

- **Heap texture ops (fixed).** Device ops 21 and 22 carry the texture
  descriptor without its leading zero word (`metal-sim-protocol.md` §4.2
  correction): op 22 had been refused as malformed (RealityKit then saw a
  size of 0) and op 21 created textures of pixel format 0. Both forms are
  accepted now; unit tests cover the 32- and 52-byte bodies. This also
  affected iOS boots (op 22 refusals in iOS logs).
- **Diagnostics (off by default; the iPhone Duo's files and environment
  are unchanged):** `YCODE_METAL_DUMP_OPS=op[:n],…` (hex of device-op
  request bodies), `YCODE_METAL_LIMITS=x,y,z,mem` (another op-37 reply),
  `YCODE_IOSURFACE_LOG=1` (failed IOSurface requests),
  `YCODE_FRAMEBUFFER_CALLS=1` (per-process call log of the framebuffer
  library in `DEV/data/tmp/ycode-framebuffer.calls.<pid>`; no lock is taken
  when off), `YCODE_CHILD_ENV="K=V;…"` (extra job environment, for example
  a recorder in `DYLD_INSERT_LIBRARIES`), and a frame-pointer call chain in
  every guest fault report.
- **Probes** (`SimShim/guest-tests/build-visionos.sh`): `vprobe` (UIDevice
  and MTLDevice answers), `mtlwatch.dylib` (records every MTLDevice selector
  a process calls through public forwarding), `rkprobe` (creates a
  RealityKit `RealityRenderer`).

### 10.4 What the R1 blocker is, and what was ruled out

The blocker is RealityKit's render manager failing to initialize, in
every process that asks for one (backboardd, datamigrator). Its call chain
at the abort (Ycode's fault report) is backboardd `main` → RealitySimulation
(through `dispatch_sync`) → CoreRE. Ruled out under Ycode:

| Hypothesis | Check | Result |
|---|---|---|
| Metal requests refused or malformed | host refusals; `YCODE_METAL_DUMP_OPS` | ops 21/22 were malformed (fixed, §10.3); none remain; the abort persists |
| A Metal object the device fails to create | `mtlwatch` in backboardd | every device call returned an object (buffers, samplers, heap of 69 632 bytes, libraries, queues, fences, events, textures, compute pipeline); none nil |
| Device capability answers | `vprobe` vs §4.5 | equal: "Apple xrOS simulator GPU", Apple1/Apple2/Common1 only, 512 × 512 threads (z 64, see below), 16 384 threadgroup memory, 256 MiB buffers, no unified memory, vertex amplification 1 only, no rasterization-rate maps, sample counts 1 and 4; heap sizing and heap textures work |
| The z limit of `maxThreadsPerThreadgroup` (Ycode 64 from Vulkan, reference 512) | `YCODE_METAL_LIMITS=512,512,512,16384` | same abort |
| IOSurface creation | `YCODE_IOSURFACE_LOG=1` | no failed IOSurface request |
| A missing service | backboardd's bootstrap look-ups (trace) | only the per-process Metal name fails (expected); no RealitySimulation or wakeboard service is looked up before the abort |
| `memorystatus_control` self-query EPERM | xnu `memorystatus_control` (level 1) | EPERM is xnu's answer to an unprivileged caller too, so the reference sees it as well |
| Specific to backboardd | datamigrator aborts the same way; our `rkprobe` (a RealityKit `RealityRenderer` in a one-shot) did not return within 45 s (its main thread waits for a reply, as `vprobe`'s `UIDevice.currentDevice` does while backboardd keeps restarting) | the failure is RealityKit's, in any process that starts a render manager |

What the device calls show of RealityKit's checks: `supportsFamily:` for
Apple5 (1005) and others → NO, `supportsRasterizationRateMapWithLayerCount:2`
→ NO, `areProgrammableSamplePositionsSupported` → NO,
`supportsVertexAmplificationCount:2` → NO, `supportsLayeredRendering` →
YES, `supportsSeparateDepthStencil` → NO; then a second
`MTLCreateSystemDefaultDevice` and the abort.

### 10.5 What R2 needs (and what R1 still lacks)

1. **The render-manager abort** (§10.4) — needs reference facts (§9 Q9,
   Q10) before Ycode can supply what is missing; it gates everything else.
   Q9 and Q10 are answered in §10.6: the device answers are not the cause;
   the failing step is open (§9 Q12, §10.6.7).
2. **Surfaces between processes (V-8):** backboardd's swapchains (uid 1
   "Top", uid 2 "SyntheticPassthrough") handed to wakeboardd; Ycode's
   IOSurface service must serve a surface created in backboardd to
   wakeboardd's Metal textures (`iosurface-remote.md`), and wakeboardd's
   swaps (mode-2 swapchain) to the frame record.
3. **4K rendering through Metal→Vulkan (V-7):** RealityKit's render graphs,
   CoreComposite and wakeboardd's compositor pipelines at 3840 × 2160,
   KTX/ASTC room textures; GPU memory (two 33 MB presentation surfaces in
   wakeboardd alone).
4. **wakeboardd's presentation:** whether it swaps during Pulse in the
   reference (§9 Q5, Q11; answered in §10.6.6: it does not) and with which callback timing; Ycode's
   framebuffer library reports `max swapchains 1`, `max layers 1`, modes 3.
5. **First-boot migration:** completes only once datamigrator no longer
   aborts (same cause as 1).
6. `maxThreadsPerThreadgroup` z: Ycode reports 64 (Vulkan's limit on the
   Thor's GPU) where the reference reports 512; harmless so far.

### 10.6 The reference during the same start (agent VISIONOS-OBS, 2026-10-27)

Observed on the Mac with Apple's visionOS 27.0 (24M362) simulator, device
type Apple Vision Pro, with our own recorder inserted into the boot and our
own probe (`research/notes/visionos-renderer-observations.md`). The
recorder did not change the outcome: the boot reached the home view in the
room. Level 3 unless marked.

#### 10.6.1 Device answers: reference and Ycode

The questions RealityKit's render-manager start asks in backboardd, in
order, and the answers. datamigrator asks the same questions in the same
order with the same answers.

| Question (in order) | Reference | Ycode (§10.4, §4.5) |
|---|---|---|
| `supportsFamily:` 1005 (Apple5), 2002 (Mac2) | NO, NO | NO, NO |
| `supportsRasterizationRateMapWithLayerCount:` 2 | NO | NO |
| `areProgrammableSamplePositionsSupported` | NO | NO |
| `supportsVertexAmplificationCount:` 2 | NO | NO |
| `supportsFamily:` 1004, 1002 | NO, YES | NO, YES |
| `supportsLayeredRendering` | YES | YES |
| `supportsFamily:` 1004, 1007, 2002, 0 | all NO | all NO |
| `supportsSeparateDepthStencil` | NO | NO |
| `supportsFamily:` 2002, 1003, 3002, 5001, 1006 | all NO | all NO |
| texture limits: 2D, cube, 1D 8192; 3D 2048; layers 2048; texture buffer 67 108 864 | as listed | same driver |
| `supportsNonPrivateDepthStencilTextures`, `supportsNonPrivateMSAATextures` | NO, NO | same driver |
| `supportsMemorylessRenderTargets`, `supportsTextureSwizzle` | YES, YES | same driver |
| `supportsFamily:` 1001, 1008, 1010 | YES, NO, NO | same driver |
| `supportsFunctionPointers`, `supportsShaderBarycentricCoordinates`, `supportsRaytracing` | NO | same driver |
| `argumentBuffersSupport` (0 = tier 1), `maxBufferLength` | 0, 268 435 456 | 0, 268 435 456 |
| `maxTotalComputeThreadsPerThreadgroup` | 512 | not recorded |
| `deserializerSupportsSharedEvents`, `supportsSharedTextureHandles` | YES, YES | not recorded |
| `supportsBufferWithIOSurface` | NO | not recorded |
| (not asked by the start; probe) `maxThreadsPerThreadgroup`, the driver's cap of the host's op-37 reply | 512 × 512 × **512** (the host replied 1024, 1024, 1024, 32 768) | 512 × 512 × **64** (the only difference; 512 tested in R1, same abort) |

All these answers except the thread and threadgroup-memory limits are
computed inside the guest driver; no family, feature or pixel-format
question reaches the host (`metal-sim-protocol.md` §4.2: op 37 is the only
capability query). A host therefore cannot make them differ, and they do
not differ. **The render-manager abort is not caused by a device answer.**
For parity Ycode's op-37 reply should still give at least 512 for z.

#### 10.6.2 The reference order of the start

backboardd, cold first boot, times from its first device creation:

| Step | What happens (Metal objects) | Time |
|---|---|---|
| 1 | the questions of §10.6.1 | 0–1 ms |
| 2 | four 16-byte shared buffers created with initial bytes; four sampler states | 1–5 ms |
| 3 | texture manager: a command queue; a private untracked heap asked for 28 032 bytes (the host grants 32 768); four 1 × 1 RGBA8 fallback textures (three 2D, one 3D) from that heap and a 64 × 64 texture with seven levels; one blit command buffer uploads them, is committed and **waited for**; it completes without error in about 14 ms | 20–90 ms |
| 4 | three metallibs from CoreRE's bundle (`default`, `mvf`, `custom`); the bundle's binary archive is missing (error-level message, normal) | 100 ms |
| 5 | two more command queues; three fences, two shared events, one event; three RGBA16Float textures; a 64-byte buffer; one more fence | 110 ms |
| 6 | a private tracked heap asked for 67 633 280 bytes (granted 67 649 536); nothing is placed in it during the start | 120 ms |
| 7 | the compute function `computeSDFGradient` is specialized and its pipeline built (1.6 s through MTLCompilerService when not cached) | to 1.9 s |
| 8 | message "Device doesn't suport light clustering" | |
| 9 | one more device creation (CA layer contents cache), no other Metal call; a command queue for the VFX manager. **The render-manager start ends here.** | +1 ms |
| 10 | messages "ImportGraphicsResources: initializing …", "MRLightingService being added", "NetworkSyncManager: initialized"; then an argument encoder of two pointers (encoded length 16, alignment 8); a shared event and its **shared-event handle** (§10.6.5); the image presentation, MPS and audio start | +2–12 ms |

Under Ycode the last things seen before the abort were steps 8 and 9 and
"ImportGraphicsResources" never appeared, so the start returned failure
within steps 1–9. The assertion text sits among the engine's own strings,
consistent with a check made by the engine right after the render-manager
start returns (level 4).

*(Corrected by §10.8.1. This list came from a recorder that saw fewer
calls. With Ycode's own recorder the reference makes the same calls in
the same counts as Ycode: steps 2 and 3 have 15 buffers, 10 samplers
and 29 heap textures. Step 9 is not the end of the start. After the CA
layer contents cache's device come the shadow render manager, the VFX
command queue, the 23 primitive-shape buffers and three defaults reads.
The "Compiling PSO RT" line of step 7 is logged on repeat boots as well.)*

#### 10.6.3 What the reference start tolerates

One fault injected per boot in backboardd and datamigrator; "completed"
means "ImportGraphicsResources" and "Starting render loop" followed.

| Injected fault | Reference outcome |
|---|---|
| every command buffer reports an error (status and error object) | completed |
| compute pipeline creation returns nothing | completed; fails later (restarts), no render loop |
| no argument encoder; no second device; no command queues; no heap; no shared event; no fence; no texture (device or heap); no sampler | completed |
| shared-event handle missing | completed, home view |
| shared-event handle with event port 0 | completed; later the host's command-buffer decoding failed and backboardd aborted |
| 15 ms added to each Metal method call (start stretched to 8.2 s) | completed |
| no metallib | a different failure: error messages "newLibraryWithURL failed." and "makeFunctionWithDescriptor error", then an exception in the drawing manager |
| no shared buffer | a different failure: a crash in the drawing manager |

None produced "Render manager was requested but failed to initialize". The
start is not sensitive to the device's answers, to single missing objects,
to command-buffer errors or to slowness of several seconds. What makes it
fail under Ycode is open (§9 Q12).

#### 10.6.4 Logs in the window (§9 Q9)

With debug level enabled and persisted for `com.apple.re`,
`com.apple.Metal`, `com.apple.RealitySimulation`,
`com.apple.RealitySystemSupport` and `com.apple.coreanimation`, backboardd
logs between "Initializing shared simulation and host server" and
"ImportGraphicsResources" only default-level messages: the three Metal
connections, "EntitlementManager initialized", "MTLCounter API disabled …",
one "MTLLibrary … newLibraryWithURL" per metallib, the missing binary
archive (error), "API function cache initialized", "DebugSettingsManager
has been disabled and not initialized",
"com.apple.re.enableSynchronousCommandQueue is enabled", "Encoder Split:
Logging Disabled.", "Vertex fetch functions compiled", "Function
specialization completed for function computeSDFGradient", "PSO
compilation completed for compute pipeline computeSDFGradient" and "Device
doesn't suport light clustering". No debug-level message falls there. The
only error-level messages of the whole engine start are the missing
binary archive and an asset path parse error for
`engine:throttleGhosted.rematerial`; any other error-level `com.apple.re`
message under Ycode is a lead.

#### 10.6.5 Shared-event handles on the wire

Two message types that `metal-sim-protocol.md` §2.4 does not list; the
engine uses them right after the render-manager check (step 10), and
datamigrator as well.

| `messageType` | Connection | Request | Reply |
|---|---|---|---|
| 17 (`newSharedEventHandle`) | type 1 | `eventRef` (uint64, the shared event's ref) | `eventPort`: a Mach send right for that event; `labelTraceID`: uint64 0 |
| 18 (`newSharedEventWithHandle:`) | type 1 | `eventPort` (the send right); `command`: op 40 record with a zero u32 | `replyData`: u32 new event ref, u32 0 |

Both refs name one event: a value set through the first (op 30) is read
through the second (op 41). Ycode's host answers unknown message types
with an empty dictionary, so the guest gets no port; in the reference a
handle with port 0 later broke command-buffer decoding (§10.6.3).

#### 10.6.6 wakeboardd's presentation (§9 Q5, Q11)

- Calls before the first swap: exactly R1's list (§10.2), one swapchain,
  presentation mode 2, no options.
- **Pulse is entered only on a "first boot"**, which wakeboardd decides by
  creating a POSIX named semaphore `wakeboardd.first-boot` (levels 3, 4). On
  macOS the semaphore is host-wide and outlives the device, so the reference
  pulses only on the first visionOS boot after the host starts; otherwise
  the state goes Config → Ready → RealTimeStarting → Run at once. Ycode
  starts with no such semaphore and always pulses; either is acceptable.
- **During Pulse there is no swap at all.** In a pulsing reference boot:
  swapchain at 0.32 s, "First frame displayed" at 0.61 s without a swap,
  backboardd's render loop at 4.9 s, backboardd's swapchains moved to slots
  Top and SyntheticPassthrough at 8.4 s, the first `SwapBegin` at 19.9 s in
  the same millisecond as "creating real time thread" and Pulse →
  RealTimeStarting → Run. That transition follows SurfBoard's "User
  presence detected", "Transitioning headset to in use..." and "Attempting
  to set hmd state to 2". **Ycode's wakeboardd, which never swaps while
  SurfBoard is down, behaves as the reference does**; it is not a second
  blocker.
- **In Run**, one thread per frame: `SwapBegin` with target time **0**,
  one `SwapAddSurface` with source and destination (0, 0, 3840, 2160) and
  trailing integers 0, 0, `SwapSetCallback` with context NULL and a
  **non-zero** pointer-sized third argument that stays constant in the
  process (`simframebuffer.md` §9 item 3), `SwapSubmit`. Two IOSurfaces
  alternate. Exactly 60 swaps per second, before and after backboardd's
  swapchains arrive. The callback runs on another thread 1–20 ms after the
  submit, without error, with A = 0 and B = completion time.

#### 10.6.7 What Ycode must change

1. **Device answers: no change needed** for the render-manager start
   (§10.6.1). For parity the op-37 reply should allow z = 512.
2. **Find the failing start step (§9 Q12)** by recording under Ycode what
   §10.6.2 lists, and comparing step by step: whether each of the 28 032-
   and 67 633 280-byte heaps, the five heap textures, the blit upload's
   completion (status and error), the three metallibs, the fences and
   events and the VFX command queue (step 9) exist and succeed; every
   error-level `com.apple.re` message (§10.6.4); and the results of calls on
   non-device objects (heaps, queues, command buffers, libraries), which a
   proxy around the device cannot see. The recorder should not wrap the
   device in a proxy: in the reference wakeboardd changes the device's
   class at run time, and object identity matters to such code.
3. **Shared-event handles:** the host must answer `messageType` 17 with a
   send right for the event, and `messageType` 18 by opening the event
   named by that right as a new ref sharing its value (§10.6.5). The engine
   needs them right after the render-manager check, so this becomes the
   next blocker once Q12 is fixed.
4. **wakeboardd:** no change for Pulse. After Pulse, the framebuffer
   library must accept 60 swaps per second with target time 0, one surface
   per swap from two alternating IOSurfaces, a non-zero third argument to
   `SwapSetCallback`, and must call each completion once with A = 0 and B =
   the completion time.

### 10.7 Round R2a under Ycode (agent VISIONOS-R2a, 2026-10-27)

Clean-room work on Ycode's own simulator on the Thor (device copied from
R1's `d1`, release build of the `visionos-r2` branch). No Apple simulator,
Xcode or reference tool was run or opened; level 3 for observations of
Ycode's guest, level 4 for exported symbol names (Ycode's recorder names
return addresses with `dladdr`, which only knows exported names).

#### 10.7.1 New diagnostics (all off by default)

- **`mtlrec.dylib`** (`SimShim/guest-tests/visionos/mtlrec.m`, built by
  `build-visionos.sh`): a Metal call recorder that wraps nothing. It
  reroutes, in place, the methods the Metal protocols declare on the
  classes that implement them (the device's class first, then the class of
  every object a recorded method returns), logs each call with arguments,
  result, `NSError` out-parameters and duration, wraps completion blocks to
  log their arguments (command-buffer status and error), and logs the
  status after `waitUntilCompleted`. Object identity and classes are
  unchanged. Options: `MTLREC_PROCS` (process names), `MTLREC_LIMIT`
  (calls per class and selector in full), `MTLREC_ALL=1` (frequent
  accessors too), `MTLREC_STACK=<n>` (caller chain of each call as
  image+offset and the nearest exported symbol), `MTLREC_DL=1` (`dlopen`
  and `dlsym` with result), `MTLREC_WINDOW_AFTER=<text>` (once a recorded
  call's chain contains <text>, every allocation and lock call of the main
  thread is logged with its chain, `MTLREC_WINDOW_MAX` lines,
  `MTLREC_WINDOW_MATCH` filter). Inserted with
  `YCODE_CHILD_ENV="DYLD_INSERT_LIBRARIES=<guest path>/mtlrec.dylib;MTLREC_DIR=<guest dir>;…"`;
  the guest path of a copied device is the path its data carries
  (`ycode-simd` prints it).
- **PC timeline** (`YCODE_BOOT_PROFILE=<path> YCODE_BOOT_PROFILE_PC_HZ=<n>
  YCODE_BOOT_PROFILE_PC_RAW=<program>`): instead of the by-image table,
  each guest PC sample of that program, with its frame-pointer chain, is
  written to `<path>.pcraw` ("ns pid pc lr ra…"). About 200–400 samples per
  second reach a busy main thread on the Thor; too sparse for windows of a
  few milliseconds.
- **`symaddr`** (`SimShim/guest-tests/visionos/symaddr.c`): a one-shot that
  names addresses with `dladdr` after loading given images. Ycode maps the
  simulator's shared cache at its unslid address in every process, so
  addresses sampled in one process can be named in another.
- **`YCODE_GUEST_MEMSIZE=<bytes>`**: another `hw.memsize` and commpage
  memory size (default 1 GiB). Tested at 16 GiB for visionOS: no change
  (§10.7.2).

#### 10.7.2 Q12: what the render-manager start does under Ycode

backboardd, repeat boots of the device; the same in every instance.

| Reference step (§10.6.2) | Under Ycode |
|---|---|
| 1 device questions | as listed in §10.6.1 |
| 2 shared buffers with bytes, samplers | yes (more 16-byte to 128 KiB buffers; ten sampler states) |
| 3 queue, private untracked heap, fallback textures, blit upload **waited for** | queue; heap asked for **69 632** bytes (reference 28 032; the size follows the host's op-22 answers, §10.7.4); 29 heap textures (1D, 1D array, 2D, 2D array, cube, 3D, texture buffer; RGBA8, RGBA16Float, RGBA8Uint; the 64 × 64 seven-level texture); one blit command buffer, `commit`, `waitUntilCompleted` returns after 37 ms with status 4 (completed) and no error |
| 4 three metallibs | `default`, `mvf`, `custom` load (`newLibraryWithURL:error:` returns a library, no error); the missing binary archive is reported as in the reference |
| 5 queues, fences, events, textures | three more queues (64, 1024, 1024 buffers), 67 fences, shared events and events, RGBA16Float textures; the clipping SDF texture array (from `ClippingSDFTextureArray.bin` of CoreRE's bundle) uploaded with 262 `replaceRegion` calls |
| 6 private tracked 64 MiB heap | asked for **67 108 992** bytes (reference 67 633 280; again from op 22) |
| 7 compute pipeline `computeSDFGradient` | created; no error; then the message "Compiling PSO RT name=computeSDFGradient tgsimotew=0 fc=" (not in the reference's list, §10.6.4) |
| 8 "Device doesn't suport light clustering" | yes |
| 9 second device (CA layer contents cache), VFX queue | the second `MTLCreateSystemDefaultDevice` (same device object), called from the CA layer contents cache's constructor, then **no VFX command queue** |
| — | then, still inside the render-manager start: the shadow render manager is constructed, and the primitive-shape stage creates 23 buffers with bytes (cube, cylinder, unit box, rectangle, UV sphere, cone, capsule, bone bipyramid, hemisphere; 12 to 8 224 bytes each); the defaults `com.apple.re.enableCascadedShadowMaps`, `…enableDecals`, `…enableSoftShadows` are read (none set) |
| — | the start returns failure; the engine asserts "Render manager was requested but failed to initialize" |

Between the last primitive-shape buffer (the hemisphere's second 6 144-byte
buffer) and the assertion, the main thread makes no Metal call, no system
call (R1's trap trace) and no `dlopen`/`dlsym`; its only allocations and
locks are the three defaults reads and then the assertion's own message.
No Metal call of the whole start returns `nil` or an error, no command
buffer completes with an error, and the Metal host refuses nothing.
Setting the three defaults to NO (in `com.apple.backboardd`) and
reporting 16 GiB of memory change nothing. So the render-manager start
returns failure from state it computed earlier; the step that differs from
the reference is not a Metal request. Its place is after the
primitive-shape stage and before the VFX queue, the reference's last
step.

Where the reference and Ycode are known to differ in that start: the two
heap sizes (from the host's op-22 answers), the "Compiling PSO RT" message,
and the absent VFX queue. §10.6.2 reports no Metal call between the CA
layer contents cache's device and the VFX queue, while under Ycode the
shadow stage and the 23 primitive-shape buffers follow that device; if
the reference's list is complete, its VFX queue comes before the
primitive-shape stage, and under Ycode the stage that would create it is
skipped or fails silently there, the start continuing to its end and
then reporting failure. Ycode's guest makes no `dlopen` of the VFX
frameworks in the whole start (they load fine in a one-shot), and five
more defaults experiments (`com.apple.re.clipping.SDFTextures.usePregenerated`
YES and NO, `…disableColorPipeline`, `…CAREEnableHistogramAndGlow` NO,
`…DepthMitigation.Enabled` NO) did not change the outcome. §9 Q13 asks for the reference's list with the
same recorder so that the two can be compared stage by stage.

#### 10.7.3 Changes

- **`messageType` 17 and 18** (shared-event handles, §10.6.5,
  `metal-sim-protocol.md` §5.8): implemented. A port per exported event,
  MAKE_SEND rights in the reply, an alias of the same backend event for 18
  (Vulkan: the same timeline semaphore), the port destroyed with the event's
  last ref. Unit tests: `CoreTests.sharedEventHandlesNameOneEventAcrossProcesses`,
  `exportedEventPortEndsWithTheLastRef`, `MachServiceTests.sharedEventHandleTravelsAsARight`.
  Not yet exercised by a visionOS boot (the engine stops before step 10).
- **Op-37 z limit**: the reply's z is at least 512, so the guest keeps its
  cap of 512 (parity with §10.6.1; iOS sees the same change). The Vulkan
  device's own z limit (64 on the Thor) stays the backend's limit; a
  dispatch with more than 64 threads in z would need folding (none seen).
- **visionOS launch regression fixed**: the header-only executable check
  added on the main line after R1 accepted only iOS-simulator executables,
  so `launchd_sim` of the visionOS runtime failed with `EBADARCH` (86) and
  no visionOS boot started. It accepts visionOS-simulator executables
  again, like the full check.

#### 10.7.4 What remains for R2

1. Q12 (§9 Q12, Q13): the reference's call list for the window of
   §10.7.2, then the Ycode change it points to. Candidates on Ycode's
   side: heap sizing answers (op 22 rounds each level to 1 KiB; the
   reference's sizes are smaller for small textures and larger for the
   4096 × 4096 texture; op 31 reports the requested heap size, the
   reference grants a multiple of 16 KiB), and the PSO path that logs
   "Compiling PSO RT". *(§10.8: neither is the cause. The reference
   logs the same PSO line, and it starts normally when it is made to
   answer the heap sizes as Ycode does. The first differing stage is the
   VFX manager's hookup.)*
2. After that, unchanged from §10.5: shared-event handles in use (step 10),
   SurfBoard "in use", RealityLauncher, wakeboardd leaving Pulse and
   swapping (mode 2, 60 Hz, two alternating 3840 × 2160 surfaces,
   callback 1–20 ms after submit), backboardd's surfaces handed to
   wakeboardd, a first frame with `--screenshot`, and cold boot to first
   frame. None of these was reached in R2a.

### 10.8 The reference start with Ycode's recorder (agent VISIONOS-OBS2, 2026-10-27)

Observed on the Mac with Apple's visionOS 27.0 (24M362) simulator, device
type Apple Vision Pro, test device `ycode-test-visionos-obs2`, five boots
(one cold). Ycode's own `mtlrec.dylib` (§10.7.1) was built for the
visionOS simulator SDK and inserted into backboardd with
`SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`. The options were caller chains
(`MTLREC_STACK`), `MTLREC_DL=1`, and allocation windows opened at the CA
layer contents cache and at the render server. The copy adds three
things. It logs preference reads (key, domain, value). It writes the wall
clock at load, so that recorder times can be matched with `log show`. It
can, when asked, replace the heap-size answers (§10.8.3). Every boot
completed (`simctl bootstatus`) and logged "ImportGraphicsResources" and
"Starting render loop". Level 3, except the caller-chain offsets and
symbol names, which are binary metadata (level 4). Notes:
`research/notes/visionos-renderer-observations.md` (OBS2 section).

#### 10.8.1 The two lists agree up to the shadow render manager

With the same recorder the reference start makes the same calls in the
same counts as Ycode's (§10.7.2). There are 15 buffers with bytes (ten
of 16 bytes, then 64, 128, 1024, 2048 and 131 072), ten sampler states,
29 heap size queries and 29 heap textures. There is one blit upload that
is waited for and ends with status 4. There are three metallibs, then
command queues of 64, 1024 and 1024 buffers, 67 fences, two shared
events and two events. The clipping SDF texture array gets 262
`replaceRegion` calls. The only differences in answers are the heap sizes
(§10.8.3). No call of the start returns `nil` or an error. The engine reads
no heap property (`size`, `usedSize`, `currentAllocatedSize`,
`maxAvailableSizeWithAlignment:`). It reads no device memory property
(`recommendedMaxWorkingSetSize`, `hasUnifiedMemory`, `maxBufferLength`,
`currentAllocatedSize`) and no resource `gpuAddress` or
`allocatedSize` before the VFX queue. The only device property read
that is not a capability question is `name` ("Apple xrOS simulator
GPU"), once, while the `computeSDFGradient` pipeline is made.

#### 10.8.2 Side by side

Reference: cold boot, milliseconds from the recorder's load in backboardd.
Ycode: §10.7.2. "Return offset" is the place in the render manager's start
(`re::RenderManager::init`, an exported symbol of CoreRE) from which the
stage is called, as Ycode's recorder prints it. Both systems run the same
dyld shared cache, so the offsets can be compared directly.

| # | Stage | Return offset | Reference | Ycode | Result |
|---|---|---|---|---|---|
| 1 | device questions (§10.6.1) | — | 371 ms | same | same |
| 2 | material manager: 15 buffers with bytes, 10 samplers | +1116, +1208 | 379–395 ms | same | same |
| 3 | texture manager: queue (64), 29 size queries, untracked heap, 29 heap textures, blit upload waited for (status 4, no error) | +1392 | 397–971 ms; heap asked for **28 032** | heap asked for **69 632** | sizes differ; not the cause (§10.8.3) |
| 4 | shader manager: `default`, `mvf`, `custom` metallibs (binary archive missing) | +1448 | 978–993 ms | same | same |
| 5 | mesh manager queue (64) | +1580 | 1924 ms | same | same |
| 6 | drawing manager: two queues (1024), fences, events, textures, clipping SDF array, 1024 × 1024 R8Uint size query | +2100 | 1935–2088 ms | same | same |
| 7 | CA render persistent data: 4096 × 4096 BGRA8 size query, tracked heap | +2100 | 3003 ms; heap **67 633 280** | heap **67 108 992** | sizes differ; not the cause |
| 8 | `computeSDFGradient` pipeline; "Compiling PSO RT name=computeSDFGradient tgsimotew=0 fc=" logged | +2100 | 3715 ms, line at 3719 ms (also on repeat boots, 5 of 5) | same, line logged | same |
| 9 | CA layer contents cache device; defaults `com.apple.re.CAREEnableHistogramAndGlow`, `com.apple.re.enableLightClustering` (unset); "Device doesn't suport light clustering" | +2100 | 3743–3749 ms | same | same |
| 10a | shadow render manager constructed (no Metal call) | +2968 | 3750 ms | yes | same |
| **10b** | **the VFX manager joins the render manager: reads `com.apple.re.enableVFXUseRERenderCommandQueue` (unset, once per process), then creates its command queue (`newCommandQueue`; the descriptor has 64 buffers, QoS medium)** | **+2996** | **3750–3757 ms** | **absent** | **first difference** |
| 11 | text array capacity (allocation only) | +3168 | — | not recorded | — |
| 12 | primitive renderer: 23 buffers with bytes (576, 576, 768, 768, 576, 576, 64, 12, 64, 3072, 3072, 7712, 5760, 7712, 1536, 1536, 8224, 6144, 8224, 384, 384, 6144, 6144) | +3344 | 3761–3787 ms | same 23 | same |
| 13 | defaults `com.apple.re.enableCascadedShadowMaps`, `…enableDecals`, `…enableSoftShadows` (unset) | +3364, +3400, +3440 | 3787–3791 ms | same | same |
| 14 | start returns | — | **success**: deformation manager, focus-level manager, …, "ImportGraphicsResources" at about 3794 ms | **failure**: "Render manager was requested but failed to initialize" | differs |

So the VFX command queue that §10.6.2 put at the end of the start comes
before the primitive-shape stage. Under Ycode, stages 10a and 12 run
but 10b does not. The render manager's result already differs when it
reaches row 10b: under Ycode either the hookup is skipped or it ends
before it asks for its queue. The failure is returned at row 14 from
state that is already set. The reference does not fail when the VFX
queue itself is missing (§10.6.3: `newCommandQueue` returning `nil`
leaves the start complete), so the missing queue is a symptom of the
decision, not its cause.

Also in the reference: the VFX manager is constructed in the engine start
before the render manager (`re::VFXManager` constructor, then its `init`,
which makes three dispatch queues and no Metal or preference call). After
the render manager the engine reads `com.apple.re.enableVFXClientSideRendering`
(unset). No VFX framework is loaded with `dlopen` in the whole start,
because VFX, VFXBase and VFXAssets are already loaded. Before
"ImportGraphicsResources" backboardd reads 128 distinct `com.apple.re.*`
defaults, and all of them are unset. The keys that do have values in that
window (`VirtualDisplayWidth` 2732, `…Height` 2048, `…RefreshRate` 90,
`PointsPerMeter` 1000, `CurrentMaxNits` 108 and similar) are registered
defaults read by the render server. They are not stored in the device's
preference files.

#### 10.8.3 Size-and-align answers (interop facts)

**The answers the start receives.** All descriptors are private storage.
"Usage 0" means `MTLTextureUsageUnknown`. The Ycode column is R2a's host
(op 22: each level rounded up to 1 KiB).

| `heapTextureSizeAndAlignWithDescriptor:` descriptor (in the order asked, count) | Reference size, align | Ycode R2a |
|---|---|---|
| 2D RGBA8Unorm 1 × 1, 1 level, usage 0 (6) | 128, 128 | 1024, 128 |
| Cube RGBA16Float 1 × 1, ShaderRead (2) | 768, 128 | 6144, 128 |
| 3D RGBA8Unorm 1 × 1 × 1, ShaderRead (2) | 128, 128 | 1024, 128 |
| 2D RGBA8Unorm 64 × 64, 7 levels, ShaderRead (1) | 22 528, 128 | 25 600, 128 |
| 2D RGBA8Unorm 1 × 1, usage 0 (3) | 128, 128 | 1024, 128 |
| 2DArray RGBA16Float 1 × 1 × 1 slice, ShaderRead (2) | 128, 128 | 1024, 128 |
| Cube RGBA16Float 1 × 1, ShaderRead (1) | 768, 128 | 6144, 128 |
| 1D RGBA8Unorm 1, ShaderRead (1); 1DArray RGBA8Unorm 1 × 1 slice, ShaderRead (1) | 128, 128 each | 1024, 128 |
| TextureBuffer RGBA8Unorm 1, ShaderRead (1) | **4, 16** | 1024, 128 |
| 2DArray RGBA16Float 1 × 1, ShaderRead (1); 1D RGBA8Unorm 1, ShaderRead (1) | 128, 128 each | 1024, 128 |
| 2D RGBA8Unorm 1 × 1, ShaderRead + ShaderWrite (1) | 128, 128 | 1024, 128 |
| 2DArray RGBA16Float 1 × 1, ShaderRead (2); 2D RGBA16Float 1 × 1, ShaderRead (1); 2DArray RGBA16Float (1) | 128, 128 each | 1024, 128 |
| 2D RGBA8Uint 1 × 1, usage 0 (1); 2DArray RGBA16Float 1 × 1, ShaderRead (1) | 128, 128 each | 1024, 128 |
| 2D R8Uint 1024 × 1024, ShaderRead + RenderTarget (drawing manager) | 1 081 344, 128 | 1 048 576, 128 |
| 2D BGRA8Unorm 4096 × 4096, ShaderRead + RenderTarget (CA render persistent data) | 67 633 152, 128 | 67 108 864, 128 |

The engine sizes each heap from these answers. The texture-manager heap is
the 29 answers placed one after another, each at its alignment (the
4-byte texture buffer is followed by 124 bytes of padding): 28 032. The
CA heap is the 4096 × 4096 answer plus its alignment: 67 633 280. Ycode's
answers give 69 632 and 67 108 992, which are exactly R2a's numbers.

**Experiment: the heap sizes are not the cause.** The reference was
booted with every `heapTextureSizeAndAlignWithDescriptor:` answer replaced
by R2a's formula. The engine then asked for heaps of 69 632 and
67 108 992 bytes, as under Ycode, and the start completed normally: VFX
queue, primitive shapes, "ImportGraphicsResources", "Starting render
loop", boot completed.

**Other answers and properties** (our size probe in the reference device,
level 3):

| Query | Reference answer |
|---|---|
| `heapBufferSizeAndAlignWithLength:options:` (1 B to 64 MiB; private, shared, untracked) | length, 256 |
| heap `size` and `currentAllocatedSize` after `newHeapWithDescriptor:` | the requested size rounded up to a multiple of 16 384 (1 → 16 384; 28 032 → 32 768; 69 632 → 81 920; 100 000 → 114 688; 1 MiB, 2 MiB unchanged; 67 108 992 → 67 125 248; 67 633 280 → 67 649 536); the same for tracked and untracked heaps |
| heap `usedSize` | 0 when empty; after a 64 × 64 seven-level RGBA8 texture is placed in the 28 032-byte heap, 22 528 |
| `maxAvailableSizeWithAlignment:` | `size` − `usedSize`, a multiple of the alignment (10 240 in the case above) |
| heap texture `allocatedSize` | 0 |
| `minimumLinearTextureAlignmentForPixelFormat:`, `minimumTextureBufferAlignmentForPixelFormat:` | 16 for every format tested (R8, R16Float, RG8, R32Float, RGBA8, RGBA8Uint, BGRA8, RGB10A2, RG16Float, RGBA16Float, RG32Float, RGBA32Float) |
| device `recommendedMaxWorkingSetSize`, `hasUnifiedMemory`, `maxBufferLength`, `currentAllocatedSize` | 0, NO, 268 435 456, 0 |

**The rule behind the texture answers.** We fitted a rule to the probe's
4 170 texture answers. It reproduces all 1 943 single-level 2D answers
and all 1 005 mipmapped 2D answers whose sizes are powers of two. It
also reproduces 1D, 1D array, 2D array, cube, 3D and texture-buffer
answers (336 of 351 rows; the 15 others are 4× multisample). It does not
cover the 871 mipmapped 2D answers whose sizes are not powers of two.

- Bytes per pixel *b* by format. The tile is 16 KiB: 128 × 128 pixels
  for *b* = 1, 128 × 64 for 2, 64 × 64 for 4, 64 × 32 for 8, 32 × 32 for 16.
- Padding: a dimension smaller than the tile's dimension is rounded up to
  the next power of two. A larger dimension is rounded up to a multiple
  of the tile's dimension.
- A 2D level takes padded width × padded height × *b*, rounded up to 128.
- Compression metadata: when the usage is not 0, does not include
  ShaderWrite, and the level's width and height are both at least 16,
  add (next power of two of width × next power of two of height) / 32,
  rounded up to 128. ShaderRead and RenderTarget both get metadata. Usage
  0 and ShaderRead + ShaderWrite do not.
- A mipmapped 2D texture is the sum of its levels (width and height
  halved per level, minimum 1). This is verified for power-of-two sizes.
  For other sizes the reference's chains are somewhat larger, for example
  RGBA8 17 × 17 with 5 levels: 5 632 (usage 0) or 5 888 (ShaderRead); RGBA8
  100 × 100 with 7 levels: 87 552 or 88 320; RGBA8 1920 × 1080 with 11
  levels: 11 687 424 or 11 862 272.
- Cube: 6 × the 2D level. 3D: depth × the 2D slice (depth is not padded).
  2D array: array length × the 2D level. 1D: the width padded the same
  way (against the tile's width) × *b*, rounded up to 128. 1D array:
  array length × that. Texture buffer: width × *b* exactly, alignment 16.
- Alignment is 128 for every texture that is not a texture buffer.
- Examples: RGBA8 4096 × 4096 is 67 108 864 with usage 0 or ShaderWrite
  and 67 633 152 with ShaderRead or RenderTarget. RGBA8 1920 × 1080 is
  8 355 840 (1920 × 1088 × 4) or 8 486 912. RGBA16Float 3840 × 2160
  RenderTarget is 67 371 008. RGBA8 1000 × 1000 ShaderRead is 4 227 072.
  4× multisample RGBA8 RenderTarget: 1 × 1 128, 8 × 8 1 152, 16 × 16
  4 224 (not fitted).

#### 10.8.4 What Ycode must change

1. **No Metal answer has to change to clear the abort.** The device
   answers are identical (§10.6.1). The call lists are identical up to the
   shadow render manager. With Ycode's heap sizes the reference still
   starts. For parity, a Ycode host should still answer as §10.8.3 says:
   - op 22 by the fitted rule;
   - heap size and current allocated size rounded up to 16 KiB (op 31);
   - available size equal to size − used, rounded down to the alignment
     (op 32; already so);
   - heap buffers length, 256 (op 23; already so).
2. **Make the engine reach the VFX manager's hookup (row 10b).** Behavior
   required: after the shadow render manager is constructed, the
   render-manager start under Ycode must read
   `com.apple.re.enableVFXUseRERenderCommandQueue` and create one command
   queue (64 buffers) before the primitive-shape buffers. The cause is
   not yet known (§9 Q14). Measure it under Ycode with Ycode's own
   recorder, which needs no reference tool:
   - (a) A window from the first device creation
     (`MTLREC_WINDOW_AFTER=RSRenderServer`) with
     `MTLREC_WINDOW_MATCH=VFXManager`. This shows whether the VFX
     manager's constructor and its `init` (three dispatch queues) run in
     the engine start, before the texture manager. In the reference they
     run at return offsets +11440 and +11452 of the engine start
     (`re::Engine::init`); the render manager is called at +12152.
   - (b) A window from `CALayerContentsCache` with the same match. This
     shows whether the hookup (`re::VFXManager::setRenderManager`) is
     entered, from the render manager's +2996.
   - (c) A preference-read log (CFPreferences and `NSUserDefaults`
     reads with key and value, as in this round's copy of the recorder)
     shows whether the hookup's default is read.

   Then: if (a) is missing, the cause lies in the engine start before the
   render manager. If (a) is present and (b) is missing, the render
   manager decided between +2100 (drawing manager) and +2996 from state
   set earlier. If (b) is present, the hookup returned before asking for
   its queue. Each outcome narrows Q14 to one stage that can then be
   compared with the reference.
3. §10.7.4 item 2 (shared-event handles in use, SurfBoard, wakeboardd
   presentation) is unchanged.


### 10.9 Round R2b under Ycode (agent VISIONOS-R2b, 2026-10-27)

Clean-room work on Ycode's own simulator on the Thor (device copied from
R2a's, release build of the `visionos-r2b` branch, runs `a1`–`a15`,
`b1`–`b20`, `c1`, `f*`, `g*`, `p1`–`p11`, `x*`). No Apple simulator,
Xcode or reference tool was run or opened; nothing was disassembled.
Level 3 for observations of Ycode's guest and for black-box experiments
in it; level 4 for symbol names (`dladdr`, the images' symbol tables).
Offsets "RM+n" are return offsets in the render manager's start
(`re::RenderManager::init`) as in §10.8.2; "RM +0xNN" (with a space) are
byte offsets in the render manager object (a 512-byte heap block).

#### 10.9.1 New diagnostics (all off by default)

`mtlrec.dylib` (`SimShim/guest-tests/visionos/mtlrec.m`) gained:

- **Look-ups** (`MTLREC_LOOKUPS=1` or a list of process names;
  `MTLREC_LOOKUP_LIMIT`, `MTLREC_LOOKUP_MATCH`): class look-ups by name,
  feature flags (`_os_feature_enabled_impl`), MobileGestalt answers, OS
  variant checks, `sysctl`/`sysctlbyname`/`sysctlnametomib`, `getenv`,
  C-API preference reads, dispatch queues created (label), IOSurface
  look-ups, property reads and XPC objects, and XPC dictionary reads
  (key and value), each with its caller chain.
- **Queue work** (`MTLREC_QUEUE_MATCH`): work submitted to queues whose
  label matches, and when it runs.
- **Scans** (`MTLREC_SCAN_AT=a,b,…`, one scan at the first caller chain
  containing each text in turn; triggered by recorded calls, look-ups and
  allocation-window notes): `MTLREC_SCAN_QUEUES` (find the heap block
  that owns remembered queues, e.g. the VFX manager), `MTLREC_SCAN_FRAME`
  (dump the frame of a named function), `MTLREC_SCAN_BLOCK_SIZE` and
  `MTLREC_BLOCK_MATCH` (dump the heap blocks of that size the frame's
  registers refer to, e.g. the render manager), `MTLREC_SCAN_CHILDREN`,
  `MTLREC_SCAN_DEREF`, `MTLREC_SCAN_ARGS`, `MTLREC_SCAN_PATTERN`.
- **Black-box experiments**: `MTLREC_BLOCK_POKE` (write bytes into a
  dumped block), `MTLREC_BLOCK_CALL` and `MTLREC_CALL`/`MTLREC_POKE`/
  `MTLREC_FLIP` (call a function found by name in the symbol tables with
  a dumped block, after changing bytes, and record what it does),
  `MTLREC_CONFIG`/`MTLREC_CONFIG_SET` (read the engine configuration with
  its public getters, and change it, also at `REEngineInitWithConfiguration`
  before the engine reads it), `MTLREC_VPOKE` (write bytes into heap
  blocks found by the name of their vtable).
- `MTLREC_ALL_METHODS` (record every method of named Metal classes, SPI
  included), `MTLREC_PRECALL` (log matching calls before they run),
  `MTLREC_NO_METAL` (look-ups only in named processes).

Also: `exports` (export-trie and symbol-table names of a loaded image
containing a text), `shtex` (a shared texture, its surface and its
handle), and Ycode's Metal host now logs the keys and short values of the
first request of each unknown `messageType`.

#### 10.9.2 Q14: the three measurements of §10.8.4

| Measurement | Under Ycode |
|---|---|
| (a) VFX manager constructed and initialized in the engine start | **yes**: `re::VFXManager::init` from `re::Engine::init`+11452 (as in the reference) creates three serial queues, `VFXRuntimeLoadingQueue`, `VFXDispatchRuntimeMergeQueue`, `VFXXPCDeliveryQueue`; no other look-up; no work is ever submitted to them during the start |
| (b) hookup entered | **yes**: the VFX manager object (448 bytes; the block holding the three queues at +0x28, +0x30, +0x40) gets the render manager's address at +0x10 between the drawing manager (RM+2100) and the primitive renderer (RM+3344), as `re::VFXManager::setRenderManager` would store it; the render manager's own frame holds the VFX manager's address, so the start was given a VFX manager |
| (c) default read | **no**: `com.apple.re.enableVFXUseRERenderCommandQueue` is not read (debug log of preference reads), and no queue is created |

So the hookup returns early. Called again by the recorder after the
primitive-shape stage (same arguments), it returns in under 0.1 ms
without a read or a queue.

#### 10.9.3 What the hookup decides on

Flipping, one at a time, every byte of the VFX manager and of the render
manager whose value is 0 or 1 (and whose word is not a pointer) and
calling the hookup again: only **render manager byte +0xd5 from 0 to 1**
makes it read `com.apple.re.enableVFXUseRERenderCommandQueue` and create
its command queue (`maxCommandBufferCount` 64, `MTLQosMedium`), as the
reference does at RM+2996.

Setting bytes **+0xd4 and +0xd5 to 1** in the render manager before the
hookup (at the CA layer contents cache's device creation) makes the whole
start succeed: VFX queue, primitive shapes, the three defaults, then
"ImportGraphicsResources", `com.apple.re.enableVFXClientSideRendering`,
"Main Camera set", "Starting render loop: <RSXRRenderLoop>". Nothing else
was changed. **The abort is caused by these two bytes being 0.**

Where they change (render manager dumps at successive points):

| Point | RM +0xd0 … +0xd7 |
|---|---|
| start of the render-manager start (RM+432) up to the mesh manager (RM+1580) | `01 00 00 00 01 01 00 00` |
| inside the render context manager's constructor (RM+1984) | same |
| at the CPU-count query (`sysctlbyname("hw.physicalcpu")`, RM+2028) | `01 00 00 00 00 00 00 00` |
| after it (RM+2072) and later | the u32 at +0xd0 is the CPU count (1, or 16 with `YCODE_GUEST_CPUS=16`); +0xd4, +0xd5 stay 0 |

Between RM+1984 and RM+2028 the main thread makes no recorded call after
the render context manager's own allocations: no Metal call (every
method of the device and queue classes recorded, SPI included), no
look-up, preference read, `sysctl`, allocation or lock.
The same span stores the render context manager, frame manager and job
service pointers into the render manager (+0x68, +0x98, +0xa0). The
render context manager's constructor, called alone by the recorder on a
render manager with the bytes set to 1, leaves them at 1.

Ruled out as the input (each: bytes still cleared, abort unchanged):

| Candidate | How |
|---|---|
| CPU count | `YCODE_GUEST_CPUS=8` and 16 (`hw.physicalcpu` 16; the u32 at +0xd0 becomes 16) |
| `com.apple.re.enableSynchronousCommandQueue` (unset; the engine logs "… is enabled", as in the reference, §10.6.4) | set to NO in `com.apple.backboardd`: "… is disabled" |
| engine configuration | changed at `REEngineInitWithConfiguration`, before the engine reads it: `EnableCommitSynchronously` 0; `ServicesToCreate`, `ServicesToUpdate` all bits; `RenderFlags` 0 and all bits; `RenderFrameOverlap` 2; `ClockMode` 0 with `RenderSkippingEnabled` 1 |
| the render manager's copy of its configuration | every byte 0 set to 1, and (separately) every byte 1 set to 0, in RM +0x130 … +0x167 and +0x1c0 … +0x1c7, at RM+1984 |
| the start's two trailing `bool` arguments | both 1 (read from the caller's outgoing stack arguments) |
| the frame manager's and the job service's flag bytes | frame manager +0x28 and job manager +0xa8 (both 1) set to 0 at RM+1984 |

The engine configuration under Ycode (public getters, before the engine
reads it): `UseMetal` 1, `EnableCommitSynchronously` 1, `RenderFlags`
`0x20000`, `RenderFrameOverlap` 3, `RenderThreadPriority` 40,
`ClockMode` 2, `RenderSkippingEnabled` 0, `ServicesToCreate` and
`ServicesToUpdate` `0xffffafff`, `CALayerServiceType` 1,
`IsHostingSharedAudioSimulation` 1, `RealityFusionSessionNeeded` 1,
`EnableVideoSupport` 1, `ShareAssetStates` 1, `UseRealityIO` 1,
`UsePhysicsSceneSystem` 1, `AllowOutOfProcessImageDecode` 1,
`LiteHUDTabs` 15; the others 0. backboardd's feature flags in the start
include `RealityKit/SeparateDepthStencil` and `RealityKit/ResourceSharing`
YES; MobileGestalt `InternalBuild` NO; every OS-variant internal check
NO. The input that clears the two bytes is not found; §9 Q15 asks the
reference for the bytes at the same points.

#### 10.9.4 Beyond the abort (diagnostic only)

With the two bytes set by the recorder in every backboardd (not a fix:
an experiment to see what follows), the boot goes on:

1. backboardd's engine starts, its render loop starts, SurfBoard
   bootstraps its services and registers RealityLauncher (Home View).
   backboardd logs a fault "Failed to acquire IOPM assertion for reason:
   Initial Boot User Active, error: -536870199" (DisplayReveal) and
   CoreAudio "no system object" errors (not yet looked at).
2. wakeboardd crashed (`CFRelease(NULL)`, from an NSXPC message of
   backboardd's swapchain owner connection) because
   `newSharedTextureWithDescriptor:` sends **`messageType` 19**, which
   Ycode's host refused: the driver then got no IOSurface. Ycode now
   answers it (`metal-sim-protocol.md` §5.10); wakeboardd's six layers
   (3840 × 2160) get surfaces and it no longer crashes.
3. backboardd then crashed in `xpc_release(NULL)` inside
   `newSharedTextureWithHandle:` with a **nil handle**, while decoding
   wakeboardd's swapchain description (`cp_swapchain_link`,
   `wbxr_decodeFlatTextureOnDevice:forKey:`): wakeboardd's
   `newSharedTextureHandle` returns nil, because the handle is made from
   the surface's creation properties and needs a value under
   `MetalSharedTexture` that Ycode's host-made surface does not carry
   (our probe `shtex`: the shared texture and its surface exist, the
   handle is nil). The value is a reference fact (§9 Q16). A restarted
   backboardd did not hit it in the same boot, but wakeboardd stayed in
   Pulse.
4. wakeboardd never left Pulse in these boots (no swap; framebuffer call
   log as in §10.2), so no frame reached the host and `--screenshot`
   found no surface. Cold boot to a first frame: not reached.

#### 10.9.5 Changes

- **Op 22** answers by the rule of §10.8.3 (tiles, padding, compression
  metadata, mip sums, cube/3D/array factors, texture buffers exact with
  alignment 16); formats without a fitted tile keep the earlier estimate.
  **Op 20** grants heaps rounded up to 16 KiB, so op 31 answers size and
  current allocated size as the reference does and op 32 follows.
  iOS sees the same answers.
- **`messageType` 19** (shared textures): answered with a host-made
  IOSurface (`IOSurfaceHostService.makeSurface`) and the texture over it;
  replayed from its recipe after a snapshot like op 47.
- The Metal host logs the keys of the first request of an unknown
  `messageType`.
- Diagnostics of §10.9.1.

#### 10.9.6 What remains

1. §9 Q15 (the input that clears the render manager's two bytes), then the
   Ycode change it points to. Until then the visionOS boot aborts as in
   §10.7. *(Answered in §10.10.1: the 8-byte `hw.physicalcpu` answer;
   change in §10.10.4 item 1.)*
2. §9 Q16 (shared-texture handles), then backboardd's swapchains handed
   to wakeboardd (§10.5 item 2). *(Answered in §10.10.2; changes in
   §10.10.4 items 2 and 3.)*
3. Unchanged from §10.7.4 item 2: SurfBoard "in use", wakeboardd leaving
   Pulse and swapping, a first frame, cold boot to first frame; and the
   IOPM assertion fault of §10.9.4.

### 10.10 The reference answers Q15 and Q16 (agent VISIONOS-OBS3, 2026-10-27)

Observed on the Mac with Apple's visionOS 27.0 (24M362) simulator, test
device `ycode-test-visionos-obs3` (Apple Vision Pro, 4K), twelve boots
and probe runs. Tools: Ycode's `mtlrec.dylib` built with
`build-visionos.sh` (one copy adds an answer substitution for
`sysctlbyname`, used in two boots), the Metal message recorder `mslog`
(`metal-sim-protocol.md` Appendix A) and our probes. Level 3 unless
marked; symbol names from caller chains are level 4. Level 5 was used
once (§10.10.1). Notes: `research/notes/visionos-renderer-observations.md`
(OBS3 section). The shared cache was not slid against Ycode's: the render
manager's +0x10 word was `0x1b073c978` here too.

#### 10.10.1 Q15: the CPU-count answer must be 4 bytes wide

| Point (Q15's settings) | Reference RM +0xd0 … +0xd7 | Ycode (§10.9.3) |
|---|---|---|
| RM+1984 | `01 00 00 00 01 01 00 00` | `01 00 00 00 01 01 00 00` |
| RM+2072 | `0e 00 00 00 01 01 00 00` | `01 00 00 00 00 00 00 00` |
| CA layer contents cache | `0e 00 00 00 01 01 00 00` | `01 00 00 00 00 00 00 00` |

- **The reference never clears the two flag bytes.** The u32 at +0xd0
  becomes 14, the Mac's `hw.physicalcpu`.
- **The bytes decide the start in the reference too.** With +0xd4 and
  +0xd5 set to 0 at RM+1984, they stayed 0 and the reference backboardd
  aborted with "Render manager was requested but failed to initialize"
  on every restart. Nothing in the start sets them back to 1.
- **The input.** In the span RM+1984 … RM+2028 the start makes one call,
  the first CPU-count query of the process: `sysctlbyname` for
  `hw.physicalcpu`. It passes a buffer length of **8**, and the buffer is
  the render manager's own u32 at +0xd0. The flag bytes are bytes 4 and 5
  of that buffer. The length is seen at level 3 (the recorder receives
  8). Which buffer is used was found at level 5, because the black-box
  levels had nothing to change: the span makes no other call, and R2b had
  ruled out every input that a recorder can change. Only 36 instructions
  were read; the extract stays in `research/dirty/visionos-obs3/`.
- **Confirmed at level 3.** The reference returns a 4-byte integer
  sysctl as 4 bytes, and returns length 4, also when the buffer is 8 or
  16 bytes (table below). Ycode's sysctl table gives a caller with an
  exactly 8-byte buffer an 8-byte value, so the upper half (zero) of the
  count overwrites +0xd4 … +0xd7. In the reference, a recorder answer of
  `hw.physicalcpu` widened to 8 bytes (in backboardd only) gave
  `0e 00 00 00 00 00 00 00` at RM+2072, and gave the abort on every
  restart (13 in one boot). The same recorder build without the widening
  started normally. **So the start clears the flags when the
  `hw.physicalcpu` answer is written 8 bytes wide.**

How the reference writes integer sysctls (`sysctlbyname`, buffers filled
with 0xaa first; our probe `sysctlsize` in the reference device):

| Names | Size query | Buffer 2 | Buffer 4 | Buffer 8 or 16 |
|---|---|---|---|---|
| 4-byte integers: `hw.ncpu`, `hw.activecpu`, `hw.logicalcpu`, `hw.logicalcpu_max`, `hw.physicalcpu`, `hw.physicalcpu_max`, `hw.nperflevels`, `hw.perflevel0.physicalcpu`, `hw.cpufamily`, `hw.cputype`, `hw.byteorder`, `hw.cpu64bit_capable`, `hw.physmem`, `hw.usermem`, `kern.maxproc`, `kern.osrevision`, `kern.argmax`, `kern.hv_vmm_present`, `vm.pagesize` | 4 | −1, ENOMEM; nothing written; length reads 0 | 4 bytes, length 4 | **4 bytes, length 4; the rest of the buffer untouched** |
| 8-byte values: `hw.memsize`, `kern.usrstack64`, `hw.pagesize` (by name) | 8 | −1, ENOMEM | 4 bytes, length 4 if the value fits in 32 bits (`hw.pagesize`); otherwise −1, ERANGE, nothing written, length 4 | 8 bytes, length 8 |
| 8-byte values without narrowing: `hw.cachelinesize`, `hw.l2cachesize` | 8 | −1, ENOMEM | −1, ENOMEM | 8 bytes, length 8 |

By MIB (`sysctl`), `{6, 3}` (`hw.ncpu`) and `{6, 7}` (HW_PAGESIZE) answer
4 bytes with length 4 to an 8-byte buffer, and `{6, 24}` (`hw.memsize`)
answers 8. So HW_PAGESIZE by number is a 4-byte integer, while the name
`hw.pagesize` answers 8 bytes. (Ycode's table gives `hw.pagesize` the MIB
`{6, 7}` and 8 bytes.)

#### 10.10.2 Q16: shared textures

**`messageType` 19 reply** (16 of 16 in a boot from wakeboardd, and in
our probe): exactly two keys, `iosurfaceXPCObject` (a Mach send right)
and `replyData` (u32 texture ref, u32 0). There was no `fatalError` and
no `error` key. Details are in `metal-sim-protocol.md` §5.10. In one boot
wakeboardd made 16 shared textures: two frames for its own layer 1 and
three each for layers 2 and 3. Each frame has a colour texture
(`BGRA8Unorm_sRGB`) and a depth texture (`Depth32Float`). All are
3840 × 2160, 2D arrays of length 1, private, ShaderRead + RenderTarget.

**The surface the guest gets** (`IOSurfaceLookupFromXPCObject` of the
reply's right):

| Property | Value |
|---|---|
| width, height, bytes per row, pixel format, plane count | 0 |
| bytes per element | 1 |
| allocation size | the heap size answer for the same descriptor + 16 (33 947 664 for the 3840 × 2160 layers, whose heap answer is 33 947 648; 16 528 for 64 × 64 BGRA8 ShaderRead; 144 for 1 × 1) |
| values (`IOSurfaceCopyAllValues`) | `CreationProperties`, `HorizontalDisparityAdjustment` 0, `IOSurfaceName` "Metal" |
| `CreationProperties` | `IOSurfaceAllocSize` (as above), `IOSurfaceName` "Metal", `IOSurfacePixelSizeCastingAllowed` 1, `IOSurfaceProtectionOptions` 0, `kAGXCompressionMode` 0, and the texture: `kMetalRegistryID` (the device's `registryID`, 0x100000455 on this Mac), `kMetalTextureType`, `…PixelFormat`, `…Width`, `…Height`, `…Depth`, `…ArrayLength`, `…MipmapLevelCount`, `…SampleCount`, `…Usage`, `…ResourceOptions`, `…GPUOptimization`, `…SwizzleKey` (0x05040302 for the identity swizzle), `…Rotation` 0, `…CSCMatrix` 0, `…Footprint` 0, `…SparseValue` 0, `…ResourceIndex` 0, `…WriteAccessPattern` 0 (all numbers) |
| `MetalSharedTexture` | **absent**, both in the creation properties and among the values |

The heap answer for these 3840 × 2160 2D-array textures has alignment
**16 384**, not the 128 that §10.8.3 gives for every texture. 2D textures
of 1920 × 1080 (RGBA16Float) and smaller still answer 128. The rule that
decides between the two is open.

**What a handle needs.** `newSharedTextureHandle` (and
`-[MTLSharedTextureHandle initWithIOSurface:label:]`) reads the surface's
`CreationProperties` and looks for the Metal device whose `registryID`
equals **`kMetalRegistryID`** (read as an unsigned 64-bit number). Our
probe made surfaces with chosen creation properties:

| Creation properties | Handle | `newSharedTextureWithHandle:` |
|---|---|---|
| width, height, format only | none (the probe crashed in the initializer) | — |
| + `kMetalRegistryID` = the device's | made, device = the simulator GPU | nil (host reply empty) |
| + `kMetalRegistryID` = another number | none (crash) | — |
| + `kMetalRegistryID` as a string | exception (unsigned 64-bit value expected) | — |
| + the full `kMetal…` set | made | a texture (64 × 64, format and type as in the properties) |
| + the full set without `kMetalRegistryID` | none (crash) | — |
| + `MetalSharedTexture` = registry ID | none (crash) | — |

So R2b's guess (`MetalSharedTexture`) was wrong. Under Ycode the
handle is nil because the host-made surface has no `kMetalRegistryID`.

**Opening a handle sends `messageType` 20**, in the creating process and
in a second process alike. The request has `command` (op 43, body u32 0),
`iosurface` (the surface's Mach send right) and `label` when the handle
has one. The reply's `replyData` is 36 bytes: the texture ref and the
descriptor (`metal-sim-protocol.md` §5.11). In one boot backboardd sent
twelve of these, for wakeboardd's layers 2 and 3. Their labels have the
form "wakeboardd-layer N [frame i/3 protection:0 size:3840x2160
recorder:False]: Color (Layered)" (or "Depth (Layered)"). wakeboardd sent
four, for its own layer 1.

**How wakeboardd's handles reach backboardd** (observed traffic; names
from caller chains are level 4):

1. backboardd sends the NSXPC message
   `newControlledLayerWithObserver:channelRequest:completionHandler:` to
   wakeboardd's `com.apple.wakeboard.hmdpresentable.owner`, with a ring-buffer
   channel request (shared memory and two notify rights) in the
   out-of-line objects. The reply carries an `NSXPCListenerEndpoint`, the
   channel reply and a proxy for the owned layer (`WBOwnedLayer`).
2. wakeboardd calls back
   `ownedLayerDidStartWithLayerID:configuration:clientOwnerSharedMemory:postProcessOwnerChannelRequest:postProcessSwapchain:completionHandler:`
   with the layer configuration: colour format 81, depth format 252,
   usage 5 for both, layout 2, frame count 3.
3. The swapchain description reaches backboardd as an NSXPC argument: a
   `cp_swapchain` with an array of `cp_swapchain_link` objects. Each link
   decodes its textures as `MTLSharedTextureHandle` objects, and each
   handle carries its IOSurface as an XPC object (a Mach send right). The
   handle cannot be keyed-archived ("may only be encoded by an
   NSXPCCoder").
4. backboardd makes the surface from that right through the IOSurface
   service (reply keys `Limits`, `MemoryObject`, `SurfaceState`,
   `PropertiesDictionary`, `iosurface-remote.md`). It reads
   `CreationProperties` (the device check above) and calls
   `newSharedTextureWithHandle:`. That gets a right for the surface from
   the IOSurface service (`MachPort`) and sends `messageType` 20 with it.

#### 10.10.3 Presence and the IOPM assertion (§9 Q17; §10.9.4 item 1)

- **SurfBoard simulates user presence itself.** During its own start,
  after it starts its inactivity shutdown scheduler, SurfBoard logs
  "Acquiring simulated user presence assertion". It takes an idle-timer
  assertion with reason "SurfBoard Simulated User Presence" and user
  presence requested. Then it logs "User presence detected",
  "Transitioning headset to in use...", "Attempting to set hmd state to
  2" and "Set hmd state to 2 (wb:2), resulting state 2". Nothing from the
  host or the user is needed. Under Ycode, SurfBoard has to get this far
  in its own start, and wakeboardd then leaves Pulse as §10.6.6 describes.
- **The reference backboardd logs no "Failed to acquire IOPM assertion".**
  Its DisplayReveal logs "Acquiring wake assertion with identifier: …,
  reason: Initial Boot User Active" during backboardd's start, and
  "Relinquishing wake assertion …" about 40 s later. The service behind
  it in the device is host-side: `launchctl print user/501` lists
  `com.apple.PowerManagement.control` as host-side, beside
  `com.apple.metal.simulator` and `com.apple.IOSurface.Remote`. It is a
  MIG service; its message format was not recorded (§9 Q17). Under Ycode
  the request fails with -536870199 (`kIOReturnInternalError`).

#### 10.10.4 What Ycode must change

1. **sysctl integer width (clears the R1 abort).** Write each integer
   sysctl with its natural width, whatever the caller's buffer size.
   4-byte integers (every CPU-count name of `darwin-process-start.md`'s
   guest CPU list, and the other 4-byte names in the table of §10.10.1)
   are written as 4 bytes and return length 4 when the buffer has 4 or
   more bytes. Bytes after the fourth are left untouched. 8-byte values
   are written as 8 bytes to buffers of 8 or more. A 4-byte buffer gets 4
   bytes if the value fits in 32 bits, otherwise ERANGE with nothing
   written (`hw.memsize`, `kern.usrstack64`, `hw.pagesize`). The cache
   sizes get ENOMEM instead. A buffer smaller than 4 bytes gets ENOMEM.
   Expected effect: the render manager's flag bytes stay 1, the VFX
   hookup reads its default and makes its queue, and the start succeeds
   without the recorder (as in R2b's experiment, §10.9.3). The fast-path
   library's kept answers (`fast-traps.md` §5) must follow the same rule.
   Also check the HW_PAGESIZE MIB (`{6, 7}`, 4 bytes) against the name
   `hw.pagesize` (8 bytes).
2. **`messageType` 19.** The host-made surface's creation properties
   must include `kMetalRegistryID` equal to the `registryID` of the
   hand-shake reply. Give them the full `kMetal…` description of the
   texture, `IOSurfaceName` "Metal" and `IOSurfaceAllocSize` too. The
   reply needs only `iosurfaceXPCObject` and `replyData`. No
   `MetalSharedTexture` value is needed. Every process must get the same
   properties through the IOSurface service, because backboardd looks the
   surface up from wakeboardd's right.
3. **`messageType` 20** (new to Ycode): find the surface by the request's
   `iosurface` right and make a texture over it. The surface can come from
   any process: a message-19 surface or a guest surface with `kMetal…`
   properties. Answer with the 36-byte `replyData` of
   `metal-sim-protocol.md` §5.11. Keep the `label`. If the reply is empty,
   `newSharedTextureWithHandle:` returns nil.
4. **Power assertions**: make the assertion-create request on
   `com.apple.PowerManagement.control` succeed (§9 Q17), so that
   DisplayReveal's "Initial Boot User Active" wake assertion is granted as
   in the reference.
5. SurfBoard needs no extra input for presence (§10.10.3).

### 10.11 Round R3 under Ycode (agent VISIONOS-R3, 2026-10-27)

Clean-room work on Ycode's own simulator on the Thor (device copied from
R2b's, release build of the `visionos-r3` branch, boots `s1`–`s15`; iOS
27.1 boots `ios1`, `ios2`). No Apple simulator, Xcode or reference tool
was run or opened, the recorder was not used, and nothing was
disassembled. Level 3 for observations of Ycode's guest; level 1 for
xnu, IOKitUser and the Metal Shading Language.

#### 10.11.1 The render-manager abort is cleared

With the integer sysctls answered at their natural width (§10.10.4 item
1; `darwin-process-start.md`, `stage3-contract.md` §8), the first boot
(`s1`), with no recorder and no byte poke, logged in every backboardd:
"ImportGraphicsResources: initializing …", "Main Camera set" and
"[com.apple.RealitySimulation:Setup] Starting render loop:
<RSXRRenderLoop: …>"; "renderManagerInitSuccessful" no longer appears, in backboardd or in
datamigrator (which then aborted on the identity token of §10.11.3).

Rules now in Ycode's sysctl answers (xnu `sysctl_io_number`,
`sysctl_old_user`, and the reference's table of §10.10.1): a 4-byte
integer is 4 bytes with length 4 into any buffer of 4 or more bytes,
the bytes after the fourth untouched; a buffer under 4 bytes is ENOMEM,
nothing written, length 0. An 8-byte value is 8 bytes into 8 or more;
into exactly 4 bytes it is narrowed when it fits an `int` (`hw.pagesize`,
`hw.memsize` with Ycode's 1 GiB guest, `hw.memsize_usable`,
`hw.tbfrequency`, `kern.osvariant_status`), otherwise ERANGE with nothing
written and the length unchanged (`kern.usrstack64`); other short buffers
ENOMEM. The cache sizes (`hw.cachelinesize`, `hw.l1icachesize`,
`hw.l1dcachesize`, `hw.l2cachesize`) are never narrowed: a 4-byte buffer
gets ENOMEM (the reference's table names the line and L2 sizes; the L1
sizes follow them, a Ycode choice). HW_PAGESIZE by number (`{6, 7}`) is a
4-byte integer; the name `hw.pagesize` now translates to its own MIB
(`{6, 1025}`) that answers 8 bytes, so both forms answer as in the
reference whichever way libc resolves the name. The library's kept
answers (`fast-traps.md` §5a) are byte strings (OIDs, `kern.boottime`),
not integers, so the rule does not change them.

#### 10.11.2 How far the boot gets

| Step | Result (boot `s5`, start = `ycode-simd` start) |
|---|---|
| wakeboardd | Config → Pulse at +7 s ("First frame displayed", no swap, as before) |
| backboardd | one instance for the whole boot; render loop at +32.6 s; it opens wakeboardd's layer handles (`messageType` 20, labels logged, §10.11.3) |
| wakeboardd | "moving swapchain uid=1 from backboardd to slot Top", "uid=2 … SyntheticPassthrough" at +34 s |
| SurfBoard | "Initializing SFBInactivityShutdownScheduler", "Acquiring simulated user presence assertion", "Acquired user presence wake assertion", "User presence detected", "Transitioning headset to in use...", "Attempting to set hmd state to 2", "Set hmd state to 2 (wb:2), resulting state 2" at +34.7 s (§10.10.3) |
| wakeboardd | "creating real time thread", Pulse → RealTimeStarting → Run at +34.7 s; then 60 swaps per second (1 585 command buffers in 110 s with one composite draw each, alternating surfaces 1 and 2) |
| `--screenshot` | from the 40 s capture on: "presented surface 1 (wakeboard SimDisplay Texture), 3840x2160 … all black" |
| RealityLauncher, RealityChrome, RealityEnvironment, RealityHUD, RealityKeyboard, RealityNotifications, pointeruid | start and stay up (they crashed in a loop in `s2`, §10.11.3); they draw nothing themselves (only blits): their layers are rendered by backboardd |
| fileindexerd | the iOS ENODEV fatal error (unchanged) |

**First frame: a black one.** The first presented surface (3840 × 2160)
is captured at the 40 s screenshot and stays all black to the end of the
boot (230 s in `s5`; the PNGs stay with the runs on the Thor's data
volume). Cold boot to wakeboardd's first swap: about 35 s
(`s5` 34.7 s, `s13` 35.6 s; untimed boots with other agents' work on the
machine; `timed.sh` was not used because the frame is not a real one).

Why it is black (diagnostic `YCODE_METAL_SHARED_CONTENT`, §10.11.5):
backboardd's six colour layer textures (wakeboardd-layer 1 and 2, three
frames each) read back as all zero bytes, alpha included, through two
minutes of the render loop, so wakeboardd composites transparent layers.
backboardd renders its scene into its own 4× MSAA target and resolve
texture (3840 × 2160), not directly into the layers; what fills the
layers from there is not known. Open on the Ycode side: the unknown
render records 24, 25, 132 and compute records 212, 213 that backboardd
sends every frame (skipped by the back end; §9 Q18), the null-port
shared events of §10.11.3 (§9 Q19), and the reference's first frames
(§9 Q20). In two of the long boots (`s6`, `s11`) backboardd's command
buffer hung on the GPU in a `drawIndexed` (6 132 indices) of the 4× MSAA
pass, the device was lost after 50 s and backboardd aborted; the hang
report now names the pipeline and textures at the checkpoint (§10.11.5).

#### 10.11.3 Shared textures and the other changes on the way

- **`messageType` 19** now makes the surface as §10.10.2 describes
  (`metal-sim-protocol.md` §5.10): width, height, bytes per row and
  format 0, bytes per element 1, allocation size = op 22's size + 16
  (33 947 664 for wakeboardd's layers), name "Metal", and the full
  `kMetal…` creation properties with `kMetalRegistryID` = the hand-shake
  `registryID`. The reply has exactly `iosurfaceXPCObject` and
  `replyData`. The texture is host GPU memory (the surface memory is not
  linked to it). In `s2`, backboardd no longer crashed in
  `newSharedTextureWithHandle:` (R2b's `xpc_release(NULL)`): the handle is
  made and sent.
- **`messageType` 20** is new (`metal-sim-protocol.md` §5.11): the host
  finds the surface by the `iosurface` right through the IOSurface
  service, reads the `kMetal…` creation properties, and makes a new ref
  that names the same GPU image as the surface's live texture in any
  process (a view of it; for a surface a guest made itself, a texture
  over the surface memory). The reply is the 36-byte `replyData` with
  hazard tracking "tracked" (`0x0220`). Labels are logged: backboardd
  opened "wakeboardd-layer 1 [frame 1/3 …]: Color (Layered)" … "layer 2
  [frame 3/3 …]: Depth (Layered)" (12), wakeboardd its own layer 3 (4,
  "frame 1/2", "2/2"), as in the reference.
- **Task identity tokens.** RealityKit (CoreRE) calls
  `task_create_identity_token` in every process that starts a render
  client and aborts when it fails. Ycode's `libsystem_kernel` had only the
  unimplemented stub (KERN_NOT_SUPPORTED): datamigrator, RealityChrome,
  RealityEnvironment, RealityHUD, RealityKeyboard, RealityNotifications
  and pointeruid aborted in a loop (`s2`: 180 calls, 30–37 aborts each).
  The library now answers it and `task_identity_token_get_task_port`
  (xnu `task.defs`, level 1; the token is a send right to the task port,
  a Ycode choice, `SimHostLibs/kernel/appsupport.c`). None of them aborts
  since.
- **Range binding records.** wakeboardd's compositor binds its layer
  textures with render record 114 and a count of 2 (16-byte body: index
  0, count 2, two refs); Ycode decoded only count 1 and skipped the
  record. Records 110/125, 112/127 and 114/129 with a count above 1, and
  record 131 (`setViewports:count:`: a count, then that many viewports of
  six doubles; backboardd sends count 1, 0, 0, 3840, 2160, 0, 1) are now
  decoded (`metal-sim-protocol.md` §8.3).
- **Translator.** RealityKit's material pipelines (MXI*, `uiCALayer`)
  failed with `air.calculate_clamped_lod_texture_2d` unsupported. The
  guest sends it as (texture, sampler, float2 coordinate, i32) → float,
  the operand order and trailing i32 of the sampling intrinsics
  (`metal-shaders.md` §3.9); ycode-airc now translates
  `calculate_clamped_lod` and `calculate_unclamped_lod` to
  `OpImageQueryLod` in fragment functions, and `air.get_num_samples.i32`
  as `air.get_num_samples`. 136 render pipelines compiled in `s15`, two
  broken (`BreakthroughTechniques`: imageblock outputs; one `uiCALayer`
  with a vertex/fragment interface mismatch), one compute pipeline
  (`air.atomic.global.cmpxchg.weak.i32`).
- **Shared events.** Each layer's set-up sends 18 twice from the opening
  process: once with the right wakeboardd's 17 made, and once with
  `eventPort` MACH_PORT_NULL, for which Ycode makes a fresh event (counted
  as refused). A host-side test showed Ycode's kernel keeps a right that
  appears twice in one message; where the null comes from is §9 Q19.

#### 10.11.4 Power assertions (§9 Q17)

`com.apple.PowerManagement.control` was not served, so
`IOPMAssertionCreateWithProperties` failed in the guest (IOKitUser's
client returns kIOReturnInternalError, -536870199, when it cannot reach
the server). SurfBoard's simulated presence then failed: "Failed to
acquire a prevent sleep assertion. The system is being forced to sleep.
… Code=210", "Set hmd state to 1 (wb:3)", and wakeboardd went Pulse →
Ready → Idle → DisplayOff (`s3`). Ycode now serves the MIG subsystem
`powermanagement` (base 73000) of Apple's open-source IOKitUser
(`PowerManagementHostService`): assertion create (73007) returns a fresh
id and success, set-properties, retain/release, user/system/network
activity declarations, connections and notification scheduling succeed,
capability bits are CPU|video|audio|network, value reads are 0, other
routines MIG_BAD_ID. With it SurfBoard acquired its assertion and the
headset went in use (§10.11.2). backboardd's first requests were 73022
(power-source info; answered MIG_BAD_ID) and 73003.

The control channel's queue holds five messages before launchd_sim reads
it, and a visionOS boot registers six host-side names; the sixth (the
Metal service, in `s4`) could not be queued ("701 register
com.apple.metal.simulator could not be queued: … 0x10000004"), so
wakeboardd's pipelines failed ("Error creating composite 0 layer render
pipeline state") and it crashed in a loop. Names that do not fit are now
registered by the session thread once the queued ones are answered, and
the power-management name is queued last (`DeviceSession`).

#### 10.11.5 Diagnostics added (off by default)

- Metal host: the first body (96 bytes) and process of each unknown
  command record op; a log of the first 32 shared-event exports and
  openings (17/18) and the first 64 shared-texture openings (20, with
  label); `YCODE_METAL_SHARED_CONTENT=1` (with `YCODE_METAL_STATS`):
  read-back statistics of every shared colour texture (pixels not black,
  mean bytes).
- Vulkan hang report: the checkpoint's command now names the render
  pipeline and fragment textures in effect.
- ycode-airc: an unmatched `calculate_*_lod` form reports its operand
  types.

#### 10.11.6 iOS 27.1 check

Two functional boots of the iOS device (copied from R2b's) with this
build: home screen at 36.4 s (`ios1`, Settings launched, loadavg 11) and
35.8 s (`ios2`, Safari launched, loadavg 15), against 32–35 s on a quiet
machine; the guest's fatal conditions are the usual fileindexerd and
intelligencetasksd ones, as in R2b's runs. The power-management service
is registered on iOS too (it fits the queue there).

#### 10.11.7 What remains

1. §9 Q18–Q20: the unknown records, the null-port shared events and the
   reference's first frames; then whatever puts content into backboardd's
   layers. *(Answered by the reference in §10.12; the changes are
   §10.12.5.)*
2. The GPU hang in backboardd's 4× MSAA pass (`s6`, `s11`): the pipeline
   is named by the next hang report.
3. The broken pipelines of §10.11.3 (imageblock outputs, the weak
   compare-exchange atomic).
4. A real first frame and its cold-boot time with `timed.sh`.

### 10.12 The reference answers Q18–Q20 (agent VISIONOS-OBS4, 2026-10-27)

Observed on the Mac with Apple's visionOS 27.0 (24M362) simulator, test
device `ycode-test-visionos-obs4` (Apple Vision Pro, 4K), four boots and
two probe runs. Three boots were **pulsing** boots (the host-wide
semaphore of §10.6.6 removed first), so that wakeboardd left Pulse at
SurfBoard's presence as it does under Ycode. Tools: our probes `encprobe`
and `encprobe2` (each encoder call between two separator records), the
Metal message recorder `mslog` (printing port names too), a copy of
Ycode's `mtlrec.dylib` that also records render-encoder calls, and our
read-back library `layerpeek` (statistics of the surfaces wakeboardd
swaps, and blits of backboardd's layer textures into a shared buffer).
Level 3 throughout; nothing was disassembled. Notes:
`research/notes/visionos-renderer-observations.md` (OBS4 section).

#### 10.12.1 Q18: the unknown records

| Op | Encoder call | Body |
|---|---|---|
| 24 | render `updateFence:afterStages:` | u32 fence ref, u32 `MTLRenderStages` (1 vertex, 2 fragment, 3 both) |
| 25 | render `waitForFence:beforeStages:` | u32 fence ref, u32 `MTLRenderStages` |
| 132 | `setVisibilityResultMode:offset:` | u64 offset, u64 mode (0 disabled, 1 boolean, 2 counting) |
| 212 | compute `updateFence:` | u32 fence ref |
| 213 | compute `waitForFence:` | u32 fence ref |

`04 00 00 00 02 00 00 00` is "fence 4, fragment stage". Fence refs come
from `newFence` (`messageType` 12 op 13); fences have their own counter.
backboardd uses only the fragment stage, sends 132 as disabled with
offset 0, and creates and releases fences continuously (14 652 `newFence`
requests in a 50 s boot; the refs are reused and stay small). The
mapping was confirmed in backboardd itself: in one command buffer, the
recorded calls of a compute encoder and of the next render encoder
correspond one for one, in order, to the records of their segments.
Counts in one boot: 24: 11 690, 25: 29 893, 132: 15 139, 212: 2 890,
213: 28 042. backboardd and wakeboardd send no other record that
`metal-sim-protocol.md` §8 did not list. The probes found further
records (22, 27, 103, 105, 106, 118, 120, 121, 134), and three corrections
to §8 (the buffer range form, 102, 209); all are in
`metal-sim-protocol.md` §8.

#### 10.12.2 Q19: the layer events

| Process | `messageType` 17 | `messageType` 18 |
|---|---|---|
| wakeboardd | 3: one per layer (event refs 1 and 2 for the layers it hands to backboardd, 3 for its own logo layer) | 2: one pair, for its own logo layer |
| backboardd | 1: its own event, at start-up (not a layer event) | 4: one pair per layer it opens (2 layers) |

Per layer the opening process sends, within half a millisecond:

1. 18 with the right that wakeboardd's 17 returned, `command` op 40 (u32
   0) and `label` "Did all render event for layer=N pid=P <process>".
   Reply: `replyData`, u32 event ref, u32 0.
2. 18 with **`eventPort` MACH_PORT_NULL**, `command` op 40, no `label`.
   Reply: **an empty dictionary** (no `replyData`, no `error`).

The second request is the driver's form of `newSharedEventWithHandle:`
with a **nil** handle, which backboardd (and wakeboardd for its own layer)
calls once per layer after the real one. In the reference the call
returns **nil**. Under Ycode the host answers with a fresh event
(§10.11.3), so the process gets an event object where the reference gets
nil.

**What the layer events carry.** Each presented frame of backboardd is
one command buffer followed by a small command buffer of event records
only: signal own event 1 = n, signal own event 2 = n, wait layer-1 event
= n − 1, signal layer-1 event = n, wait layer-2 event = m − 1, signal
layer-2 event = m (n and m count the frames each layer received). The
frame's command buffer starts with a wait for own event 2 = n − 1.
wakeboardd does not wait for these events on the GPU. It reads their
values with the CPU query (`messageType` 12 op 41 on its own exported
refs) once per swap and layer, about 60 times per second each, and the
values it reads follow backboardd's GPU signals. The value v of a layer
event announces the layer's frame slot (v − 1) mod 3 (frame i/3 of the
handle labels, i = slot + 1). The warm-up frames of the render loop
signal only backboardd's own events; the first layer-event signals come
with the first frame after Run (in that boot layer 1 = 12, layer 2 = 1).

#### 10.12.3 Q20: the first frames after Run

Pulsing reference boot, times relative to Run (SurfBoard's "User presence
detected" and wakeboardd's Run in the same millisecond):

| Time after Run | Swapped surfaces (3840 × 2160 `BGRA`, two alternating) | backboardd's layer textures |
|---|---|---|
| before Run | no swaps (Pulse) | all bytes zero, alpha included, from their opening (70 ms after "Starting render loop") |
| 0 to 0.75 s | all bytes zero | layer 1 (Top): the boot logo, small, at the centre, alpha at most 41 of 255; layer 2 (SyntheticPassthrough): zero |
| 0.75 to 7.25 s | the logo at the centre, alpha at most 3 of 255, otherwise zero: a black picture | unchanged |
| 7.25 to 8.2 s | the room and home view fade in (mean alpha 11 → 255) | — |
| from 8.2 s | the room with the home view, opaque | layer 1: the home view's icons on a transparent background; layer 2: the room, opaque |

The fade-in begins about 50 ms after backboardd logs "Compiling PSO …
name=composeSyntheticEnvironmentDefinition
tech=ComposeWithSyntheticEnvironment vtx=fullScreen2Vert frag=fsCompose".
That follows RealityEnvironment's "Active synthetic environment changed
to LivingRoomDay" (about 5.1 s after Run), backboardd's asset load of
`composeSyntheticEnvironment.rerendergraph` and RealityLauncher's "Reveal
transition appearance state changed [isVisible: true, … newValue:
appearing]". A non-pulsing boot shows a different start (an opaque black
DisplayReveal curtain in the Top layer that fades out over about 5 s, then
the boot logo with a progress bar on screen) and is not the case Ycode
reproduces.

So under Ycode, all-zero layers are expected **until Run** and black
swaps for a few seconds after it. All-zero layers after the room's
compose pass has started (two minutes in §10.11.2) are not reference
behavior.

**Reference frame.** `research/dirty/visionos-obs4/reference-frame-swap600-960x540.png`
(not committed) is the 600th swapped surface, 10 s after Run, downsampled
4×. It shows the simulated living room by day, seen from the sofa: a low
table, a television on a sideboard against the back wall, framed plant
prints on the left wall, two floor lamps, a shelf unit on the right, a
curtained window. The home view floats in front of the back wall: two
rows of four round app icons with names below them, and a small vertical
tab bar at the left of the rows.

#### 10.12.4 How backboardd writes the layers (level 3)

backboardd writes wakeboardd's layers only through render passes whose
attachments are the refs that `messageType` 20 returned to it:

| Layer (slot) | Pass |
|---|---|
| 1 (Top) | the layer's colour texture is the **resolve attachment** of colour attachment 0. Colour 0 is backboardd's own 2D-multisample texture (`BGRA8Unorm_sRGB`, 4 samples, 3840 × 2160, private), depth a 4-sample `Depth32Float_Stencil8` texture. Load action Clear with (0, 0, 0, 0), store action **MultisampleResolve**, resolve level 0, slice 0; depth store DontCare. This is the pass with many draws (19 in a steady frame, most of them indexed draws of 6 132 indices); it is the 4× pass of §10.11.2 |
| 2 (SyntheticPassthrough) | the layer's colour texture is **colour attachment 0** itself, with the layer's depth texture as depth attachment: load Clear (0, 0, 0, 0), store Store, one draw. Later in the same frame a second pass loads and stores the same colour texture (no depth, one indexed draw of 6 indices) |

A steady frame on backboardd's main render queue, in order: wait for own
event 2; layer 2 frame k (clear, one draw); an own 3840 × 2160
`BGRA8Unorm_sRGB` target with `Depth32Float` (clear (0, 0, 0, 1), six
draws); an own 160 × 128 two-slice `RGBA16Float` target (one draw); a
compute encoder; the 4× pass resolving into layer 1 frame k; layer 2
frame k again (load, one draw). Fences (24/25, 212/213) chain the
encoders; small blit encoders (buffer fills, fence updates) sit between
them; the event-only command buffer of §10.12.2 follows.

**Cadence.** backboardd does not render every display frame: eleven
warm-up frames when the render loop starts (each the 4× pass resolving
into layer 1's frames 1/3, 2/3, 3/3 in turn, cleared to (0, 0, 0, 0), one
draw), none until Run, one frame at Run (layer 2 frame 1/3 and layer 1
frame 3/3, one draw each: the logo), almost none for the next 7 s, then
60 frames per second once the compose pass of the room is ready.
wakeboardd swaps 60 times per second throughout and shows, per layer, the
frame that the layer event last announced.

#### 10.12.5 What Ycode must change

1. **Decode records 24, 25, 132, 212 and 213** (§10.12.1). Fence waits
   and updates order the encoders of backboardd's frame (each render and
   compute encoder waits for the fences of the encoders whose output it
   reads). Executing a command buffer's encoders strictly in order also
   satisfies them; a back end that reorders or overlaps encoders must
   honour them. 132 with mode 0 needs no action.
2. **Buffer range bindings**: read the range form of 110/125/203 as
   (ref, u64 offset) pairs per slot (`metal-sim-protocol.md` §8.3
   correction). Also read 209 as size before origin.
3. **`messageType` 18 with `eventPort` MACH_PORT_NULL**: reply with an
   empty dictionary, make no event, and do not count it as an opened
   event. Then `newSharedEventWithHandle:nil` returns nil as in the
   reference.
4. **The resolve into the layer must land in the shared image.** The Top
   layer receives content only as the MultisampleResolve target of
   backboardd's 4× pass, and the passthrough layer only as a colour
   attachment. Both name refs that `messageType` 20 opened in backboardd.
   Ycode's message-20 ref is a view of the image that the message-19
   texture in wakeboardd names (§10.11.3). Check, with Ycode's read-back
   diagnostic applied to backboardd's message-20 refs as well as to the
   message-19 textures, that (a) a resolve whose target is a 2D-array
   texture with array length 1 (resolve level 0, slice 0) writes that
   image, and (b) a colour attachment that is such a ref writes it. The
   reference shows the layer textures non-zero after the room's compose
   pass starts. Under Ycode, before that point, zero is correct.
5. **The layer events must connect the two processes.** backboardd
   signals its message-18 event ref on the GPU once per frame;
   wakeboardd reads the value of its message-17 ref with op 41 before
   every swap. The value it reads must be the value that backboardd's
   GPU last signalled (Ycode's alias of §5.8), and a GPU wait in
   backboardd for value v − 1 on the same event must be satisfied by its
   own earlier signal. If wakeboardd reads 0, it never takes a new frame
   of that layer.
6. **Expect the reference's cadence when judging a boot.** Black swaps up
   to about 7 s after Run and zero layers before Run are normal. A real
   first frame is the room fading in after "Compiling PSO …
   composeSyntheticEnvironmentDefinition …"; time it from there.

### 10.13 Round R4a under Ycode: the GPU hang and the broken pipelines (agent VISIONOS-R4a, 2026-10-27)

Clean-room work on Ycode's own simulator on the Thor (device copied from
R3's, release builds of the `visionos-r4a` branch, from boot `s1` on with
R4b's decoder corrections of §10.14 under it, and for `c1`–`c4` also
R5's of §10.16; 68 visionOS boots `h1`–`c4` of 70 to 400 s; iOS 27.1
boots `ios1`, `ios2`). No Apple simulator, Xcode or
reference tool was run or opened, the recorder was not used, and nothing
was disassembled. The logic of the guest's shaders was not read: the
hang was located with switches that change how Ycode records or
translates whole classes of operations, and the guest functions were
looked at only through ycode-airc's reflection, declared intrinsic
signatures and opcode counts. Level 3 throughout.

#### 10.13.1 The hang

**When.** backboardd's command buffer stops on the GPU about 2 s after
its first compute fence records (212/213) appear, which is when the
system UI's layers start to be drawn (§10.14.4: 10–100 s after Run). Of
the R3 boots that ran that long, 7 of 8 hung (R3 counted the device losses
only: `s6`, `s9`, `s11`); of this round's boots without a remedy, every
one that reached that point. On a GPU nobody else needs, the submission
runs forever ("still running after 60 s"); with another client (another
simulator, the desktop) the driver kills the context after about 50 s
(Xid 109, CTX SWITCH TIMEOUT, in the host's kernel log; no MMU fault),
every later submission fails and backboardd aborts.

**Where.** The checkpoints of the device-loss reports name draws of
`vsCALayer`+`fsCALayer` (RealityKit's UI-layer material) in the 4× pass
and, with R4b's decoder, in a 224 × 192 `RGBA16Float` pass, plus, in a
few boots, depth-only `vsManualInstancing` and `vsUnlit` draws at the top
of the pipe. The checks the hang report now makes per draw (pipeline
against pass sample count, index range against the vertex buffers, per
instance buffers, §10.13.2) found no mismatch except one: `vsUnlit` and
`vsManualInstancing` draws with base instances of 1 072 693 248,
1 084 227 584, 1 085 145 088 and 2 359 296 (float or double bit
patterns, §9 Q24).

**Bisection** (each line: boots, result; `YCODE_GPU_SKIP_SHADERS` skips
draws whose vertex or fragment function has that name,
`YCODE_GPU_DROP_FRAGMENT` builds the pipeline without its fragment
function, `AIRC_EXP` changes the translation of `fsCALayer` only):

| Variant | Boots | Hung |
|---|---|---|
| as built | many | all that reached the UI |
| vertex `viewport_array_index` not written (§10.13.3) | `v1`–`v3` | 3 |
| skip `vsCALayer` | `h8`, `t2` | 2 (top of pipe at `vsUnlit` with base instance 1 072 693 248, or `vsManualInstancing` with 2 359 296) |
| skip `vsManualInstancing`, `vsUnlit`, `vsOcclusionQuery` | `e2` | 1 (`vsCALayer` draw at top and bottom) |
| skip those and `vsCALayer` | `e3`, `t3` | 0 |
| draws whose base instance + count > 2²⁰ skipped | `g1` | 1 (`fsCALayer`) |
| that, and skip `vsCALayer` | `g3` | 0 |
| that, and `fsCALayer` left out of its pipelines | `g2` | 0 |
| `fsCALayer`: every device load reads 0 | `k1`, `m3` | 0 |
| `fsCALayer`: texture reads and samples return 0 | `k2` | 1 |
| `fsCALayer`: discard and SIMD reductions neutral | `k3` | 1 |
| `fsCALayer`: loads through bound buffers read 0 | `m2` | 1 |
| `fsCALayer`: loads through pointers read from memory read 0 | `m1` | 0 |
| … only those whose pointer came from fragment buffers 0–7 | `q2`, `u3` | 0 |
| … from buffers 8–15, 28 | `q3` | 1 |
| … from 0–3; 4, 5, 7; 6; 3, 6; 0–2, 6; 3–5, 7 | `s1`–`s3`, `w1`–`w3` | 6 |
| `fsCALayer`: loads through pointers read from memory skipped when the address is below 64 KiB | `n1`, `n2` | 0 |
| `fsCALayer`: every device load so guarded | `n3` | 0 |
| null guard on, base-instance check at 2²⁰ | `z1`–`z8` | 3 (`z5`, `z7`, `z8`: after the home view appeared; top of the pipe at `vsUnlit`, base instances 0 and 196 608) |
| that, and skip `vsUnlit`, `vsManualInstancing`, `vsOcclusionQuery` | `y1`, `y2` | 0 (home view appeared in both) |
| **as built now** (null guard; base instance checked against the vertex buffers; unread stage-in attributes not declared) | `a1`–`a4`, `b1`–`b4` | **0** (home view in 4 of 8) |
| the same on the main line with R5's room loading (§10.16) | `c1`–`c4` | 3, all in compute: §10.13.1 "A third family" |

**Cause.** `fsCALayer` reads through pointers it takes from its argument
buffers (fragment buffers 0–7), and in some invocations such a pointer is
null: guarding only the reads whose address is below 64 KiB (a null
pointer plus a field offset) removes the hang. On the Thor a read of
unmapped GPU memory neither faults nor returns: the GPU waits until the
driver kills the context (stage8-contract.md §15.6). More than one of the
eight argument buffers supplies such a pointer (removing the reads of any
subset left a hang). Ycode's hang-report scan of those buffers' CPU-visible
bytes found no 16-byte-aligned addresses of live buffers and no addresses
of released buffers in them, so the
pointers are most likely null in memory as the guest wrote them; which
fields they are and whether the reference reads them was not examined
(that would mean reading the function's logic).

The second, independent cause is the base instance of the depth-only
draws above: a Metal instance ID includes the base instance, so a vertex
function that reads per-instance data with it reads about a billion
elements past its buffer. The values look like the bit patterns of
floating-point fields, i.e. a record decoded with the wrong layout (§9
Q24, for VISIONOS-R4b's decoder).

**Fix.**

- ycode-airc **null guard** (`metal-shaders.md` §4.3): every load from a
  device or constant pointer that is not derived from a bound buffer, a
  table entry, a global or a private allocation compares the address with
  64 KiB; below it, the load reads the argument table instead and yields
  zero. The guest's functions have 1–81 such loads (`fsCALayer` 22–58 per
  variant, `fsVideoColorPlayback` 81, `fsRealityPbr` 47); the reflection
  counts them (`null_guarded_loads`). `AIRC_NULL_GUARD=0` turns it off.
- Vulkan back end: a draw is skipped (the first eight logged as "draw
  skipped: base instance …") when its base instance plus instance count
  exceeds 2²⁰, or when its vertex function reads `instance_id` or
  `base_instance` and the base instance times 4 bytes reaches past the
  largest vertex-stage buffer binding (even 4 bytes per instance would
  index beyond every buffer). The first rule alone (`z1`–`z8`) let
  base instances such as 196 608 through, and `z7`, `z8` hung on them.
  Unit test `VulkanBackendTests.implausibleBaseInstanceIsSkipped`.

**Result.** With the null guard, the base-instance check and the vertex
input rule of §10.13.3, 8 of 8 boots (`a1`–`a4`, `b1`–`b4`, 360–400 s;
the home view appeared in four, where `z5`, `z7` and `z8` had hung) ran
without a hang report past 2 s, device loss or backboardd abort, and
every draw of the two families ran or was skipped by the check (8 logged
per boot). Before this round, every boot that got as far as the system
UI hung. The first content in layer 1 under Ycode was read back in
`z5` after RealityLauncher's home-view reveal (about 230 of 518 400
sampled pixels not black, 7 800–10 000 not zero, in all three frames),
before that boot's `vsUnlit` hang: the home view's icons do reach layer 1
(§10.14.6 item 3).

**vsUnlit with base instance 0.** `z5` and `z8` hung at `vsUnlit` draws
whose base instance was 0. `vsUnlit` declares 15 stage-in attributes and
reads 2 (position and texcoord); the pipeline's vertex descriptor
describes those 2, and Ycode declared Vulkan input variables for all 15,
13 of them with no vertex attribute behind them (undefined in Vulkan).
ycode-airc no longer declares stage-in attributes a function does not
read (`metal-shaders.md` §4.5); `a1`–`b4` include it. Which of the two
changes after `z8` (this one, or the tighter base-instance check) ended
those hangs was not separated.

**A third family (not this round's).** With R5's room loading, 3 of 4
boots (`c1`–`c3`) hung in compute work of backboardd (or a restarted
backboardd): the mip chain of RealityKit's ASTC decoder kernel `astc`
(`acedd39a`, `dispatchThreads` of 683² … 1² threads in 32 × 16
threadgroups, lane-isolated as in `stage8-contract.md` §15.5), the room's
textures. R5's boots on the main line without this round's changes hung
the same way (`visionos7/runs/v3`, the same dispatch pattern) and once in
`generatePrefilteredSpecularMapFast` (`v2`). It is the `astc` hang of
`stage8-contract.md` §15.5 with new data (lane isolation does not prevent
it here); not investigated in this round.

#### 10.13.2 What the hang reports now show (diagnostics)

- Per draw, in braces: the pipeline's sample count against the pass's
  (`SAMPLES pipeline 1 pass 4` on a mismatch); the vertex function's
  `viewport_array_index`, `render_target_array_index`, `clip_distance`,
  `amplification_id`, `instance_id`, `base_instance` outputs and inputs;
  the range of indices the CPU can read now; for each Vulkan vertex
  buffer (per vertex and per instance) how many vertices or instances it
  holds against what the draw reaches (`VB4 stride 12 holds …` on an
  overflow); base vertex and base instance of indexed draws.
- A pointer scan of the buffers each draw binds (and one level down):
  words that are addresses of live buffers, of released buffers (the
  last 16 384 releases are remembered) or in Ycode's synthetic address
  range (§10.13.1), and 64 KiB-aligned words in the live range that no
  buffer owns.
- The command budget of a report is 240 commands (was 48: the 4× pass
  sat beyond it).
- Experiment switches: `YCODE_GPU_SKIP_SHADERS`, `YCODE_GPU_DROP_FRAGMENT`
  (host); `AIRC_EXP` = `psb`, `psbdir`, `psbind`, `psbslot`, `psbindslot`
  (with `AIRC_EXP_SLOTS`), `psbnull`, `psbnullall`, `tex`, `demote`,
  `simd`, limited to the function `AIRC_EXP_FN` (translator; use a fresh
  `--gpu-cache-dir`, the translation cache does not key on them).

#### 10.13.3 The three broken pipelines

All three now translate and validate; the boots `z1`–`z6` report
`broken 0 / 0` render and compute pipelines (R3: 2 render, 1 compute).
The guest's functions (dumps of boot `h6`, kept on the Thor) were the
test input; translator tests of our own AIR modules
(`Translator/tests/ir/interface-forms.sh`) and two GPU tests cover the
forms.

- **Compute, `air.atomic.global.cmpxchg.weak.i32`.** The guest's form is
  `i32 (ptr addrspace(1) object, ptr expected, i32 desired, i32, i32, i32, i1)`.
  ycode-airc loads `*expected`, does `OpAtomicCompareExchange`, writes the
  value found back to `*expected` and returns 1 on success, 0 on failure
  (`metal-shaders.md` §3.9; the meaning of the i32 result is Ycode's
  reading, §9 Q23). GPU test `CompareExchangeGPUTests` (a compare-exchange
  increment loop over 64 and 4 096 threads counts every thread).
- **Render, `BreakthroughTechniques`** (`fsBreakthroughMeshClearImageBlock`
  and its relatives): a fragment function that returns an explicit
  imageblock member (`air.imageblock_data`) and takes the pixel's
  imageblock as an argument. Ycode keeps no tile memory in render passes,
  so the member is not written and the argument reads as zeros; the
  other outputs are kept (`metal-shaders.md` §4.9). Whether backboardd's
  passes need the imageblock contents (tile functions, which Ycode does
  not run) is open.
- **Render, `uiCALayer`/`fsSFBStencilBreakthrough`, "fragment input
  generated(6normalDv3_f) is not an output of the linked vertex
  function"**: the fragment function declares ten inputs, the linked
  `vsUnlit` writes four, and the six others are never read. An input the
  function does not read and the vertex function does not write now gets
  no interface variable (`metal-shaders.md` §4.5); one that is read stays
  an error.
- Also: a vertex function's `viewport_array_index` output is not written
  any more (`metal-shaders.md` §4.5). Ycode's passes have one viewport
  and scissor, so an index of 1 or more selected undefined Vulkan state;
  RealityKit's stereo pipelines write it from the instance. It was not the
  hang (`v1`–`v3`) but is undefined behaviour either way.

#### 10.13.4 iOS 27.1 check

Two functional boots of the iOS 27.1 device (copied from R2b's) with this
build (null guard and vertex-input rule on): home screen at 247.9 s
(`ios1`, load average 137 at the time) and 51.8 s (`ios2`, load 56), the
home watch saw rendered frames, Settings (`ios1`) and Safari (`ios2`)
launched through `ylaunch`; no hang report, device loss or Metal backend
error; guest fatal conditions only fileindexerd and intelligencetasksd,
as in R3 and R4b.

#### 10.13.5 What remains

1. §9 Q24 (VISIONOS-R4b): the record layout that yields float-like base
   instances for `vsUnlit` and `vsManualInstancing` (still present after
   R4b's corrections: 1 072 693 248, 1 084 227 584, 1 085 145 088,
   2 359 296, 196 608); until then those draws are skipped. A garbage
   primitive type (196 612) was also seen on a `vertexShaderClearAll` draw.
2. ~~The compute hangs of §10.13.1 "A third family" (`astc` mip chains,
   `generatePrefilteredSpecularMapFast`) that the rooms bring.~~ Done
   (§10.18: kernels wrote texture views through stale heap slots).
3. §9 Q23: confirm the compare-exchange result.
4. Out-of-bounds reads through non-null pointers and through bound
   buffers stay unguarded (stage8-contract.md §15.8 item 1).
5. Fragment imageblocks and tile functions in render passes (BreakthroughTechniques).
6. backboardd's abort in PHASE without guest audio (§9 Q22, §10.16) and a real first frame.

### 10.14 Round R4b under Ycode (agent VISIONOS-R4b, 2026-10-27)

Clean-room work on Ycode's own simulator on the Thor (device copied from
R3's, release builds of the `visionos-r4b` branch; boots `r1`–`r3`, and
`x1` with VISIONOS-R4a's translator and Vulkan commit merged in for one
experiment; iOS 27.1 boots `ios1`, `ios2`). No Apple simulator, Xcode or
reference tool was run or opened, and nothing was disassembled. Level 3
for observations of Ycode's guest (guest `log stream`, Ycode's host log,
`--trace-name RealityEnvironment`, `YCODE_METAL_STATS` with
`YCODE_METAL_SHARED_CONTENT`, `YCODE_METAL_TRACE`); the items are those of
§10.12.5.

#### 10.14.1 Changes

- **Records** (§10.12.5 items 1, 2; `metal-sim-protocol.md` §8.3, §8.4).
  The decoder now turns render records 22, 24, 25, 27, 102, 103, 105, 106,
  118, 120, 121, 132, 134 and compute records 134, 212, 213 into commands;
  with them backboardd's and wakeboardd's command buffers decode with no
  unknown record (the `YCODE_METAL_STATS` summaries of every boot list
  none; R3's listed 24, 25, 132, 212, 213 in every frame). The buffer
  range form of 110, 125 and 203 is read as (ref, u64 offset) pairs per
  slot; 204 and 206 with a count above 1 as one ref per slot. Op 102 is
  action, then index; op 209 is size, then origin. A deferred store
  action (102, 105, 120) is also written into the open pass's descriptor
  (the attachment of that index; none: no change), because the Vulkan
  back end fixes store operations when a pass begins.
- **Fences.** The Vulkan back end already runs a command buffer's encoders
  in order with a full memory barrier between encoders, and a queue's
  command buffers in submission order (one held for an event holds the
  later ones), so every fence wait is satisfied when it is reached; fence
  records need no work and a reused fence ref needs nothing. 132 with mode
  0 needs nothing (other modes are not implemented). No render-pass or
  resolve set-up was changed.
- **Null-port 18** (§10.12.5 item 3). An 18 whose `eventPort` is
  MACH_PORT_NULL (or absent) gets an empty dictionary, makes no event, is
  not counted as refused (it is counted on its own), so
  `newSharedEventWithHandle:nil` returns nil as in the reference. In R3's
  long boot `s5` RealityEnvironment never logged "Active synthetic
  environment changed to LivingRoomDay"; in all four R4b boots it did,
  8.6 to 22.8 s after Run (whether the change is the cause was not
  isolated).
- **Diagnostics.** `YCODE_METAL_SHARED_CONTENT` reads every live ref of a
  shared-texture surface (the message-19 texture and each message-20
  opening, named by process and label) and prints each exported shared
  event's value with its number of refs. The `YCODE_METAL_STATS` summary
  now runs on a thread of its own: in `r1` the read-back, which waits for
  the GPU, ran on the Metal service's receive thread and waited behind a
  hung command buffer (no summary came after it), which holds every
  Metal client's messages.

#### 10.14.2 The layers and their events (§10.12.5 items 4, 5)

- On the GPU (unit tests `VulkanBackendTests.sharedLayerViewTakesResolveAndAttachmentWrites`,
  `layerEventAliasCarriesGPUSignals`): a 2D-array texture of array length
  1 in `BGRA8Unorm_sRGB` and a view of it (Ycode's message-19 texture and
  message-20 ref) — a 4× pass that clears and resolves into the view
  (MultisampleResolve, level 0, slice 0) writes the image the message-19
  handle reads, and so does the view as colour attachment 0. An event and
  its message-18 alias: GPU signals n on the alias, each frame's wait for
  n − 1 on the alias is satisfied by the previous frame's signal, and the
  value read through the original is the last signalled one.
- In the boots: wakeboardd's layer events have two refs (wakeboardd's and
  backboardd's), and the values wakeboardd can read rise with
  backboardd's frames (`r3`: layer 1 156 → 247 → 528 → 700, layer 2
  1 → 92 → 373 → 545 at 10-s summaries). The layers do receive
  backboardd's writes: from before Run (layer-1 event still 0 in `x1`)
  until Display Reveal's "Did Reveal" (backboardd, 1.9 s after Run in
  `r3`, 15 s in `x1`) every pixel of all three frames of layer 1 reads
  (0, 0, 0, 255), written as the resolve target of the 4× pass through
  backboardd's own message-20 refs. That is the opaque black curtain of
  §10.12.3's non-pulsing reference boot (backboardd logs "Set start color
  to (0.00,0.00,0.00,1.00)" and "Continuing to obscure display due to
  outstanding assertions" before Run); the pulsing reference boot has zero
  layers until Run instead. wakeboardd's own
  layer 3 holds the faint logo (about 1 070 to 1 090 of 518 400 sampled
  pixels not zero, with small alpha). After "Did Reveal", layer 1 and layer 2
  read all zero again, alpha included, to the end of each boot; the
  swapped surfaces stay black.

#### 10.14.3 Why the room does not appear: no SystemEnvironmentAsset

After "Active synthetic environment changed to LivingRoomDay",
RealityEnvironment logs "Updating synthetic scene asset LivingRoomDay",
"Loading environment asset LivingRoomDay into entity", "Attempting to load
environment layer" (Passthrough, Audio, Environment), then
"setSyntheticSceneAsset: Error loading asset:
SystemEnvironments.EnvironmentAssetError.configurationError". backboardd
never compiles `composeSyntheticEnvironmentDefinition`, so layer 2 stays
empty (§10.12.3). The asset is missing because:

1. RealityEnvironment's SystemEnvironments queries mobileassetd for
   `com.apple.MobileAsset.SystemEnvironmentAsset` (MA_QUERY_ASSET_TYPE,
   return type 2). mobileassetd answers result 2,
   MAQueryCatalogNotDownloaded: "0 listed in the catalog and 0 local (0/0
   downloaded, 0 preinstalled) … 0 installedWithOS". Its look-up of
   preinstalled assets reads `DEV/data/System/Library/AssetsV2/PreinstalledAssetsV2/InstallWithOs`,
   which does not exist (ENOENT; every other asset type it is asked for
   in the boot also has no catalog).
2. SystemEnvironments then lists the six synthetic rooms and `Starfish`
   as `state=unavailable`, the immersive Environments as
   `state=notPresent`, and "Waiting 60s for MA daemon before downloading
   catalog"; the download fails 60 s later with 59
   (MADownloadCannotFindHost; the guest has no network) and is retried
   every 60 s.
3. RealityEnvironment enumerates
   `RR/System/Library/Assets/SystemEnvironments/SyntheticEnvironments`
   (getattrlistbulk: six entries) but opens nothing inside it
   (`--trace-name RealityEnvironment`, boot `r3`).

How the reference obtains the room's asset (a cached or downloaded
catalog, or a preinstalled entry) is reference-only: §9 Q21 (answered in
§10.15: neither; the cause is Ycode's `getattrlistbulk` record form).

#### 10.14.4 The GPU hang (VISIONOS-R4a's)

In every boot one of backboardd's command buffers stopped on the GPU some
tens of seconds after Run ("serial … still running after 10 s", then 20,
30 …); in `r2`, `r3` and `x1` the device was lost later, backboardd
aborted and restarted, and every later submission failed. `x1` (R4a's commit `fdc0a01`
merged in) hung too; its hang report puts the checkpoint in a 224 × 192
`RGBA16Float` pass with `Depth32Float_Stencil8` (pass 5 of backboardd's
command buffer, `vsCALayer` + `fsCALayer` indexed draws of 612 indices,
commands 89 to 207), not in the 4× pass; layer contents in `x1` were the
same as in `r3`. RealityLauncher's home view reveal ("Reveal transition
appearance state changed … appeared") came 22 to 41 s after Run (in the
reference, "appearing" comes before the room's fade-in at 7.25 s); no read-back of these boots shows layer 1 with
content after it, but the host log does not tell whether a read-back fell
between the reveal and the hang, so whether the home view's icons reach
layer 1 is open.

#### 10.14.5 iOS 27.1 check

Two functional boots of the iOS device (copied from R3's) with this
build, on a heavily loaded machine: home screen at 142.6 s (`ios1`,
loadavg 132, Settings launched) and 78.1 s (`ios2`, loadavg 69, Safari
launched); the home watch saw rendered frames in both, and the Metal host
logged no backend error and no unknown record. Guest fatal conditions:
fileindexerd and intelligencetasksd as in R3 (more of them in the slower
boot), and once in `ios2` PosterBoard ("Invalid condition not satisfying:
versionsURL", a PosterFoundation file check, not Metal).

#### 10.14.6 What remains

1. §9 Q21: the room's asset (answered in §10.15; the fix is §10.15.3
   item 1); then layer 2, `composeSyntheticEnvironmentDefinition`
   and the first real frame (time it with `timed.sh` from Run).
2. The GPU hang of §10.14.4 (VISIONOS-R4a).
3. Whether the home view's icons reach layer 1 once the GPU no longer hangs.
4. A diagnostic crash: `YCODE_THREAD_REPORT_AT_S` crashed `ycode-simd` in
   `DarwinKernel.blockedThreadReportLocked()` (a Swift trap) at its
   second report (180 s) in `r1`; the first (90 s) was fine.

### 10.15 The reference answers Q21: the room comes from the runtime (agent VISIONOS-OBS5, 2026-10-27)

Observed on the Mac with Apple's visionOS 27.0 (24M362) simulator, test
device `ycode-test-visionos-obs5` (Apple Vision Pro, 4K), five first boots
(erased before each): b1 plain; b2–b5 with our file-call recorder `fsrec`
(an interposing library that logs file calls with paths, flags, results
and the records `getattrlistbulk` returns); b3 with every guest process's
connections to non-loopback addresses refused by the same library (the
Mac's network and settings unchanged); b5 with one experiment (below).
Also our probe `bulkprobe` (one `getattrlistbulk` call per request and
option set), on the Mac and in the guest. Level 3 throughout; nothing was
disassembled. Notes: `research/notes/visionos-renderer-observations.md`
(OBS5 section). Terms: `SE` =
`RR/System/Library/Assets/SystemEnvironments/SyntheticEnvironments`.

#### 10.15.1 Where the room comes from

From the runtime root, read in place. RealityEnvironment's
SystemEnvironments finds the six rooms itself by listing `SE` (the folder
of §2.6) and adds them to its asset list as installed; MobileAsset and the
network play no part:

| | Reference | Ycode (§10.14.3) |
|---|---|---|
| mobileassetd's `determineAssets` for `com.apple.MobileAsset.SystemEnvironmentAsset` | result 2 (MAQueryCatalogNotDownloaded), 0 catalog, 0 local (0/0 downloaded, 0 preinstalled), 0 installedWithOS, 0 requiredByOS; `DEV/data/System/Library/AssetsV2/PreinstalledAssetsV2/InstallWithOs` → ENOENT | the same |
| Listing of `SE` | depth-first into every room folder (§10.15.2) | `SE` listed (six records), nothing below it opened |
| `Info.plist` reads | `SE/<room>/Info.plist`, six ("Loading tuning data. { name='Info.plist' … }") | none |
| "Catalog assets [N]" | 28: each room twice, `state=installed version=V path=SE/<room>/AssetData` and `state=unavailable version=1.0.0` (no path); `Starfish` unavailable; 15 immersive Environments `notPresent` | 22: the rooms only as `unavailable` |
| Chosen entry for each room | the installed one | the unavailable one |
| `LivingRoomDay` | "Attempting to configure environment. { … state=installed }", `SE/LivingRoomDay/AssetData/Config.plist` read, "Setting synthetic environment asset { …, path=SE/LivingRoomDay/AssetData/livingroom_day.usdc }", backboardd compiles `composeSyntheticEnvironmentDefinition` about 0.6 s later | "setSyntheticSceneAsset: … EnvironmentAssetError.configurationError" |

The version `V` is the room `Info.plist`'s `MobileAssetProperties` values
`_CompatibilityVersion`.`ContentMajorVersion`.`ContentMinorVersion`
(`1.1.20` for LivingRoomDay). The installed entries keep their place after
a catalog download.

Who reads which room file (all under `SE`, read-only):

| Process | Files | Calls |
|---|---|---|
| RealityEnvironment | every directory of the tree | `getattrlist`, `open` with `O_DIRECTORY`, `getattrlistbulk` |
| RealityEnvironment | `<room>/Info.plist` (six), `<room>/AssetData/Config.plist` (six) | `open` read-only, non-blocking; `getattrlist` before `Config.plist` |
| RealityEnvironment | the active room's scene (`Config.plist` `combinedScene`) | `stat`, `getattrlist` only |
| backboardd | the active room's scene and its `AssetData/0/*.ktx` textures | `stat`/`lstat`, `fopen` "rb", read-only `mmap` of the whole file (10 MB textures) |

No environment variable or host folder names an asset location (the guest
processes see the usual `SIMULATOR_ROOT`, `IPHONE_SIMULATOR_ROOT`, `HOME`,
`CFFIXED_USER_HOME`, `SIMULATOR_SHARED_RESOURCES_DIRECTORY` and the other
CoreSimulator variables); no host service, mount or shared folder is
involved. Before listing `SE`, RealityEnvironment `lstat`s
`RR/AppleInternal/Assets/SystemEnvironments/` `KnownEnvironmentsInternal.plist`,
`EphemeralEnvironments`, `InternalEnvironments` and `ExternalEnvironments`;
all four are absent (ENOENT) in the reference too.

**Network (Q21 c).** With the guest's network refused (b3) the room was
active 0.1 s after the catalog block and composed 0.5 s later; screenshots
42 s and 119 s after boot show the living room. The catalog download
begins 60 s after the first query ("Waiting 60s for MA daemon before
downloading catalog") and with no network ends in download result 60
(MADownloadCannotConnectToHost); RealityEnvironment logs "Refreshing assets
failed: …downloadError(…mobileAsset(60)), retrying in 60…" and repeats
every 60 s. Nothing else changes. With the network (b1) the download comes
from the Pallas service (`https://gdmf.apple.com/v2/assets`, through the
guest's own mobileassetd using the Mac's network) and lists 21 assets
under 16 `EnvironmentKey` values (immersive Environments and `Starfish`),
**no room**; the room had been shown for a minute by then. Under Ycode the
error is 59 (MADownloadCannotFindHost) instead of 60; the difference does
not matter.

**Files in the device (Q21 d).** After a boot with the network,
`DEV/data/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_SystemEnvironmentAsset/`
holds `com_apple_MobileAsset_SystemEnvironmentAsset.xml` (the catalog)
and a same-size copy `com_apple_MobileAsset_SystemEnvironmentAsset.xml.purged`;
no `.asset` folder. Without the network the folder does not exist. No
room is downloaded or copied into the device at any time, so there is
nothing to hand a clean device beyond the runtime itself.

#### 10.15.2 The listing that finds the rooms

RealityEnvironment, on one thread, in about 7 ms:

1. `getattrlist(SE)` with `ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_FULLPATH |
   ATTR_CMN_OBJTYPE | ATTR_CMN_DEVID`, options `FSOPT_NOFOLLOW |
   FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED`; `getattrlist(SE)`
   with the set of step 3, options `FSOPT_NOFOLLOW | FSOPT_REPORT_FULLSIZE
   | FSOPT_ATTR_CMN_EXTENDED`; `getattrlist(SE)` with `ATTR_VOL_INFO |
   ATTR_VOL_CAPABILITIES`.
2. `open(SE, O_RDONLY | O_DIRECTORY | O_CLOEXEC)`.
3. `getattrlistbulk`, buffer 18 600 bytes, options
   `FSOPT_ATTR_CMN_EXTENDED` (0x20), request: common `0xf01f9e0d`
   (`RETURNED_ATTRS`, `NAME`, `FSID`, `OBJTYPE`, `CRTIME`, `MODTIME`,
   `CHGTIME`, `ACCTIME`, `OWNERID`, `GRPID`, `ACCESSMASK`, `FLAGS`,
   `GEN_COUNT`, `DOCUMENT_ID`, `ADDEDTIME`, `ERROR`,
   `DATA_PROTECT_FLAGS`), dir `0x5` (`LINKCOUNT`, `MOUNTSTATUS`), file
   `0x1` (`LINKCOUNT`), extended `0x240` (`ATTR_CMNEXT_REALDEVID`,
   `ATTR_CMNEXT_EXT_FLAGS`).
4. Depth-first: for each record whose object type is VDIR, before the
   next record, open that directory by its full path (flags of step 2) and
   list it the same way, each listing until `getattrlistbulk` returns 0.
   Per room: the room folder (2 records: `AssetData`, `Info.plist`),
   `AssetData` (4: the scene, the icon PNG, `Config.plist`, `0`),
   `AssetData/0` (5 or 6 textures).
5. After the tree: `open` of the six `Info.plist` files.

**The reference's records.** Every record carries returned common set
`0xd01f9e0d`: everything requested **except `ATTR_CMN_ERROR`**, and **no
error word**: the `ATTR_CMN_NAME` reference follows the 20-byte attribute
set directly. Directories: dir `0x5`, file 0; files: dir 0, file `0x1`;
extended `0x240` in both. Object type 2 (VDIR) for directories, 1 (VREG)
for files. Record lengths are multiples of 8 (184 to 232 bytes here).

**When `ATTR_CMN_ERROR` is packed** (bulkprobe, APFS: the runtime's sealed
volume, the device's data volume, from the guest and from the Mac): with
`FSOPT_PACK_INVAL_ATTRS` in the options the returned common set equals the
requested set, `ATTR_CMN_ERROR` included, and a zero error word follows
the attribute set; without `FSOPT_PACK_INVAL_ATTRS` an object without an
error gets neither the bit nor the word. This corrects
`first-boot.md` §3 item 2, whose probe saw the word with
`FSOPT_PACK_INVAL_ATTRS`. What an object *with* an error returns was not
observed.

**Experiment b5: Ycode's record form in the reference.** Our library
rewrote only the records of the two listings of `SE`: `ATTR_CMN_ERROR`
added to each returned set, a zero word inserted after the set, each
record padded to 8 bytes (the form Ycode's `getattrlistbulk` produces when
the bit is requested). RealityEnvironment then listed `SE`, opened no room
folder and no `Info.plist`, logged "Catalog assets [22]" with
`[LivingRoomDay] { state=unavailable version=1.0.0 … }` only, "Active
synthetic environment changed to LivingRoomDay", and 62 ms later
"setSyntheticSceneAsset: Error loading asset:
SystemEnvironments.EnvironmentAssetError.configurationError"; backboardd
never compiled `composeSyntheticEnvironmentDefinition`. The screen showed
the home view's icons on black. That is R4b's sequence under Ycode
(§10.14.3).

#### 10.15.3 What Ycode must do

1. **`getattrlistbulk` and `ATTR_CMN_ERROR`.** Put `ATTR_CMN_ERROR` in a
   record's returned common set, and its u32 right after the attribute
   set, only when the caller passed `FSOPT_PACK_INVAL_ATTRS` (then as a
   zero word, with every requested bit returned) or when the object has
   an error. Otherwise omit both, so the name reference follows the
   attribute set. Keep the record length a multiple of 8.
2. **Depth-first listings must work.** A directory record carries object
   type VDIR and dir attributes (`LINKCOUNT`, `MOUNTSTATUS` 0 for a plain
   directory); the caller then opens that directory by full path with
   `O_DIRECTORY` while its parent's listing is still open, and each
   listing ends with a 0 return. Up to four directory descriptors are open
   at once here.
3. **Expected result** in a first boot: RealityEnvironment logs six
   "Loading tuning data. { name='Info.plist' …}" lines for `SE/<room>/Info.plist`,
   then "Catalog assets [28]" with six `state=installed` entries whose
   `path` is `SE/<room>/AssetData`, "Attempting to configure environment.
   { name='LivingRoomDay' … state=installed }", "Setting synthetic
   environment asset { name=LivingRoomDay, path=…/livingroom_day.usdc }",
   "Done loading synthetic environment asset"; backboardd opens the scene
   and the textures under `SE/LivingRoomDay/AssetData/` and logs
   "Compiling PSO … name=composeSyntheticEnvironmentDefinition …".
4. **backboardd's reads.** It reads the scene and the 0.6 to 10 MB
   textures with `fopen` and a read-only, whole-file `mmap`; Ycode's file
   mapping of RR files must serve that.
5. **Nothing else is needed.** No MobileAsset catalog, preinstalled entry,
   network, host service, shared folder or environment variable. Ycode's
   mobileassetd answers already match the reference without a network;
   the failing catalog download every 60 s is reference behavior too.
6. **No Apple asset is shipped.** The rooms are files of the runtime that
   the owner installed with Xcode, and Ycode's runtime copy (§2.7)
   already contains them at `SE`. Ycode reads them there at run time and
   never copies them into its repository or a device.
7. A side effect worth knowing: other Foundation directory listings in the
   guest that request `ATTR_CMN_ERROR` without `FSOPT_PACK_INVAL_ATTRS`
   are affected by the same fix (it is the deep-listing request of
   step 3 of §10.15.2), so other symptoms of directories that seemed empty
   may change with it.

### 10.16 Round R5 under Ycode: the rooms load; backboardd aborts in PHASE (agent VISIONOS-R5, 2026-10-27)

Clean-room work on Ycode's own simulator on the Thor (branch `visionos-r5`,
device copied from R4b's; visionOS boots `v1`–`v3`, iOS 27.1 boots
`i0`, `i1`). No Apple simulator, Xcode or reference tool was run or opened,
nothing under `research/` was read, nothing was disassembled. Level 3
(guest `log stream`, Ycode's host log, `YCODE_METAL_STATS` with
`YCODE_METAL_SHARED_CONTENT`, screenshots), level 1 for xnu.

#### 10.16.1 Change (§10.15.3 items 1, 2, 4)

- `getattrlistbulk` puts `ATTR_CMN_ERROR` in a record's returned common
  set, and its zero word after the attribute set, only with
  `FSOPT_PACK_INVAL_ATTRS` (then the returned common set is the requested
  set). Without it a requested `ATTR_CMN_ERROR` is dropped from both, so
  the name reference follows the 20-byte set (xnu `attr_pack_common`
  agrees). Records stay multiples of 8. An entry Ycode cannot `lstat`
  (removed since the directory was read) is still skipped; Ycode never
  makes an error record (the reference's was not observed).
- Depth-first listings needed no change: directory records are VDIR with
  dir `LINKCOUNT` 1 and `MOUNTSTATUS` 0, and cursors are per descriptor,
  so a child opened by full path is listed while the parent's listing is
  open. backboardd's whole-file read-only mapping of RR files is Ycode's
  existing private file mapping; no file error was logged while the room
  loaded (backboardd's opens were not traced).
- Tests: `AttributeListBulkTests` (error omitted without the option,
  packed with it, not requested, RealityEnvironment's whole request
  `0xf01f9e0d/0/5/1/0x240` with and without the option, and the
  depth-first walk of a two-room tree with an 18 600-byte and a one-record
  buffer, four listings open at once); `SandboxExtensionTests.attributeListBulk`
  now asks for the word with `FSOPT_PACK_INVAL_ATTRS`.
- Diagnostics: `YCODE_DEBUG_BULK_ERROR_WORD=1` restores the old form (for
  A/B); `YCODE_DEBUG_BULK_LISTINGS=1` prints one stderr line per listing
  that requests `ATTR_CMN_ERROR` (process, directory, options, request).

#### 10.16.2 The rooms load (§10.15.3 item 3)

Boot `v2`, times after wakeboardd's Run: RealityEnvironment lists `SE`
depth-first (19 listings: `SE`, then each room, its `AssetData` and
`AssetData/0`), logs six "Loading tuning data. { name='Info.plist' …}"
(+14.8 s) and "Catalog assets [28]" (+15.0 s) with exactly §10.15.1's
entries: each room `state=installed` (KitchenDay, KitchenNight 1.1.23,
LivingRoomDay 1.1.20, LivingRoomNight 1.1.19, MuseumDay 1.1.21,
MuseumNight 1.1.20, `path=SE/<room>/AssetData`) and `state=unavailable
version=1.0.0`, `Starfish` unavailable, 15 immersive Environments
`notPresent`. It reads the six `Config.plist`, logs "Attempting to
configure environment. { name='LivingRoomDay' … state=installed }",
"Active synthetic environment changed to LivingRoomDay" (+17.0 s),
"Loading environment asset LivingRoomDay into entity.", the three layer
loads, "Setting synthetic environment asset { name=LivingRoomDay,
path=SE/LivingRoomDay/AssetData/livingroom_day.usdc }" and "Done loading
synthetic environment asset" (+17.1 s); no configurationError. backboardd
logs SceneUnderstanding's "loading synthetic environment 'LivingRoomDay'",
loads `composeSyntheticEnvironment.rerendergraph` and logs "Compiling PSO …
name=composeSyntheticEnvironmentDefinition tech=ComposeWithSyntheticEnvironment
vtx=fullScreen2Vert frag=fsCompose" (+19.5 s; +46 s in the slower `v3`).
The catalog download still waits 60 s and fails, as in the reference.

#### 10.16.3 First frame: backboardd aborts (new blocker)

After the PSO line, layer 2 (SyntheticPassthrough) reads (0, 0, 0, 255) in
all three frames (zero before), layer 1 zero, and every swapped surface
black (`v3`: a screenshot each second from 60 s). 0.45 to 6.8 s after the
PSO line backboardd aborts with an uncaught NSException 'API Misuse',
"Cannot create a PHASEMaterial with nil or invalid PHASEEngine" (stack
CoreRE → PHASE → CoreFoundation, on a dispatch worker). launchd restarts
backboardd, RealityEnvironment reloads the room, and it aborts again:
eight cycles in `v2`, two in `v3`; afterwards the GPU hang of §10.14.4
(`v2`: a command buffer still running after 10, 20, 30 s; `v3`: device
lost, then backboardd aborts on "Command buffer SharedEventSignalBuffer
failed to execute"). No frame showed the room.

The engine is nil because backboardd's PHASE engine never initializes
under Ycode, in every boot (R4b's `r3` too: 92 failures, harmless while no
room loaded): "HALC_ProxyObjectMap::_CreateSystemObject: there is no
system object", "Failed to open audio settings plist!"
(SimulatorDeviceSettings), "Could not find default device for dOut",
AQMEIO −66680, AURemoteIO −10851, "Failed to Initialize Controller Voice
Manager", "PHASEEngine … Failed to initialize with mode default, sr
48000 Hz". The guest's CoreAudio has no audio system: the reference host
registers `com.apple.audio.coreaudiod` and `com.apple.audio.audiohald` in
the guest (launchd-sim.md §6.3); Ycode registers neither. What the host
must answer is reference-only: §9 Q22.

#### 10.16.4 Other listings the fix changes (§10.15.3 item 7)

No guest listing seen passed `FSOPT_PACK_INVAL_ATTRS`; every request with
`ATTR_CMN_ERROR` (options `0x20` or 0) now gets the reference form. In
`v2` (7.5 minutes) that was 936 listings by 58 processes, mostly with
Foundation's deep request (common `0xf01f9e0d`, or `0xf01fde0d` with
`ATTR_CMN_USERACCESS`; `0xa004000d` and `0xa2000009` are the other two
forms): spotlightknowledged 335 (`DEV/data/Library/Biome/sets/…`),
RealityEnvironment 152 (19 per start, eight starts), axassetsd 151 and
sirittsd 100 (`TextToSpeechMauiSupport.framework/TTSResources/<locale>`),
RealityHUD 53, SurfBoard 40 (`DEV/data/Library/UserNotifications`,
`RR/System/Library/UserNotifications/Bundles`), and 2 to 13 each for
assistantd, searchd (`SpotlightResources.framework/RequiredAssets_root.bundle/AssetData/<n>/…`),
routined, passd, assetsd, sharingd, linkd, lsd, parsec-fbf, remindd, maild,
promotedcontent, nsurlsessiond, fileproviderd and a dozen daemons listing
`RR/System/Library/Preferences/ProtectedCloudStorage/Identities`. Not
every caller depended on the form: the iOS A/B (§10.16.5) shows which
listings go deeper with it.

#### 10.16.5 iOS 27.1 check

Same build, the iOS 27.1 device copied from R4b's, each boot launching an
app 20 s after the home screen, with a guest log stream of error and fault
messages; `i0` ran with `YCODE_DEBUG_BULK_ERROR_WORD=1` (the old record
form) as the pre-fix comparison, `i1` and `i2` with the fix, all with
`YCODE_DEBUG_BULK_LISTINGS=1`.

| | `i0` old form, Settings | `i1` fix, Settings |
|---|---|---|
| Home screen | 57.0 s (load average 60–116) | 156.7 s (72–90) |
| ycode-simd CPU seconds at the home screen | 405 | 502 |
| App launched | yes | yes |
| Listings requesting `ATTR_CMN_ERROR` (directories) | 935 (662) | 2 024 (1 382) |
| Guest fatal conditions | fileindexerd 4, intelligencetasksd 2, PosterBoard 1 | fileindexerd 1, intelligencetasksd 13 |

What the fix changes on iOS:

- **PosterBoard** walks its poster store
  (`DEV/data/Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/<extension>/descriptors/<id>/versions/<n>/…`):
  1 131 listings of 785 directories, against 504 with the old form.
  PosterBoard's fatal "Invalid condition not satisfying: versionsURL"
  (a BaseBoard condition), seen in R4b's `ios2` (§10.14.5) and in `i0`,
  did not occur with the fix (one boot each; most likely the same cause:
  a descriptor's `versions` folder was not found through the listing).
- **biomed** walks its stream and session folders (`DEV/data/Library/Biome/…`):
  414 listings, none with the old form; it now logs "Failed to determine
  class for stream …" faults for the streams it finds (165 faults against
  6). Whether the reference logs these too was not checked.
- assetsd (24 against 6), searchd and Spotlight (10 against 4),
  parsec-fbf (4 against 0), MercuryPoster (6 against 2), assistantd,
  linkd, clipserviced and nanoappregistry list more. axassetsd and sirittsd
  (151 and 100) list the same with either form, so not every caller
  depended on it.
- The home-screen time is dominated by the machine's load (R4b's two
  pre-fix boots: 142.6 s and 78.1 s, CPU 489 and 395); the extra listings
  show no clear cost. No Metal backend error in either boot.

Safari (`i2`, with the fix): home screen at 99.8 s (load average 65,
CPU 583 s), Safari launched; 1 546 listings of 922 directories (PosterBoard
1 000); guest fatal conditions fileindexerd 1 and intelligencetasksd 6, no
PosterBoard condition; no Metal backend error.

#### 10.16.6 What remains

1. §9 Q22: guest audio (the HAL's system object and a default output
   device) so that PHASE initializes; then the room's fade-in.
2. The GPU hang of §10.14.4 (VISIONOS-R4a). (The compute hangs the
   rooms brought: found and fixed, §10.18.)

### 10.18 Round R6 under Ycode: the compute hangs (agent VISIONOS-R6, 2026-10-27)

Clean-room work on Ycode's own simulator on the Thor (branch
`visionos-r6` on the main line 688f365; the device copied from R5's;
visionOS boots `r1`–`r6`, `x-psb`, `x-imgwrite`, `f1`–`f6`, each from a
fresh copy, two at a time; iOS 27.1 boots `i1`–`i3`; one iPad (A16)
first boot `p1`). No Apple simulator, Xcode or reference tool was run or
opened, nothing under `research/` was read, nothing was disassembled, and
the logic of the guest's kernels was not read: they were seen through
ycode-airc's reflection, Ycode's hang reports and captures, and by
switching classes of their operations off. Level 3 throughout.

#### 10.18.1 The hang and its cause

With the rooms loading (§10.16) every boot hung within 2–3 minutes
(`r1`–`r6`: 6 of 6, first report 120–180 s after start; R4a's `c1`–`c3`
and R5's `v3` the same), always in `backboardd`'s compute work right after
a room load: the mip chains of RealityKit's ASTC decoder `astc`, which
decodes each level of the room's ASTC textures (4096² with 13 levels,
1024² with 11, block size 6 × 6) into a one-level texture view. The
queue's checkpoints, now read while a submission runs, put the GPU in one
`astc` dispatch — a different level each time — and the dispatch's
argument table named live buffers and textures only. The same dispatches
replayed offline with the captured bytes finish in milliseconds
(stage8-contract.md §15.9 lists what was ruled out). Switching the
decoder's loads (`AIRC_EXP=psb`) or texture writes (`imgwrite`) off made
it stop hanging, and the next kernel hung instead:
`generatePrefilteredSpecularMapFast`, writing one cube-map level per
dispatch through a texture view, every written view reported "no storage
view".

Cause (Ycode): texture views never had a storage view. The back end
compared a view's composed component mapping, which spells the identity
out as R, G, B, A, with the all-`IDENTITY` constant, so the test failed
for every view. A kernel that wrote a view wrote through the storage
descriptor its heap slot had kept from the slot's previous owner, a
released texture whose image memory was freed, and on the Thor such a
write never completes. Which slot a view got, and whether its previous
owner's memory was already freed, decided whether a dispatch hung — hence
the random level and the hundreds of good dispatches before. It was not
the decoder, its data or the subgroup behaviour of stage8-contract.md
§15.5; lane isolation could not help. Two related holes are closed with
it: a kernel's explicit-level storage access (slot *h* + L) reached other
textures' slots, and the storage array was a quarter of the sampled one.

#### 10.18.2 Changes

- Texture views get storage views (identity test by meaning).
- Every slot a texture gets has a sampled and a storage entry (the dummy
  image for a missing view), and released slots go back to the dummy
  image; a texture with a storage view and n levels owns n slots, with
  one-level storage views for the explicit-level form; the storage array
  is as large as the sampled one (65,536).
- Diagnostics: running checkpoints, after-dispatch markers, dispatch
  tables in hang reports, a log of kernel writes to textures without
  `shaderWrite` (none seen), `YCODE_GPU_STORAGE_USAGE=all`, ycode-airc
  `AIRC_EXP=imgwrite`; probes `areplay`, `pollute`, `imgoob`, `pinprobe`.
- Tests: `VulkanBackendTests.kernelWritesAViewInAReusedSlot` (does not
  finish in 8 s on the code before; passes now),
  `kernelWritesTextureWithoutShaderWriteUsage`,
  `mipmappedStorageTextureOwnsOneSlotPerLevel`; opt-in `CaptureReplayTests`.

#### 10.18.3 Boots with the change

`f1`–`f6` (two of 400 s, four of 600 s, 3 200 s in all): 6 of 6 ran to
their limit without a GPU hang. No hang report
(none past 2 s), no device loss, no Xid in the host's kernel log for them;
637–919 `astc` dispatches per boot (before: 13–361 until the hang). The
boots now run until their time limit: backboardd loads the room and
aborts in PHASE (§10.16.3) again and again — 13–15 aborts per boot, one
every 30–45 s, each followed by a restart and a new room load (39–45
`fsCompose` pipeline compiles per boot against 9–18 before the hang).

What the layers show (`YCODE_METAL_SHARED_CONTENT`, every 30 s): of each
backboardd's two layers (three frames each), one stays zero and the other
reads opaque black, (0, 0, 0, 255), in every sampled pixel once the room
is composed (as in §10.16.3; once half of its pixels); wakeboardd's own
layers (two frames) are zero except about 1 080 of 518 400 sampled pixels
(the curtain or logo of §10.14.2); every presented 3840 × 2160 surface is
black. No frame shows the room: backboardd dies in PHASE before a composed
frame with content each time (§9 Q22).

#### 10.18.4 iOS 27.1 and iPad checks

Three boots of the iOS 27.1 device (copied from R5's) with this build,
each launching an app through `ylaunch` 20 s after the home screen: `i1`
Settings (home screen at 238.4 s, load average 84–102), `i2` and `i3`
Safari (90.9 s and 110.8 s, load 56–75). Every app launched; `i3`'s
screenshots show the home screen at 120 s and Safari's Start Page drawn at
195 s. No hang report, device loss or Metal backend error in any of them;
guest fatal conditions fileindexerd and intelligencetasksd as in earlier
rounds, plus replicatord once (`i1`) and PosterBoard once (`i2`).

The iPad (A16) case of stage8-contract.md §15.5 (WeatherPoster decoding
an ASTC poster at a device's first boot): one first boot of a new iPad
(A16) device (`p1`, 900 s, home screen at 293 s) ran WeatherPoster but no
`astc` dispatch at all (0 dispatches; WeatherPoster was stopped with
signal 15), so the case was not exercised. Whether WeatherPoster's poster
target is a texture view (which would make that 2026-10-19 hang this
round's cause too) remains open.

#### 10.18.5 What remains

1. §9 Q22: guest audio so that PHASE initializes; then a first frame with
   the room.
2. §10.13.5 items 1, 3–5 (VISIONOS-R4a's open items) are unchanged.
3. Lane isolation (stage8-contract.md §15.5) is no longer needed for the
   visionOS decoder; it stays on by default (it costs little) until the
   iPad case is checked.

### 10.17 The reference answers Q22: guest audio comes from the host's audio daemon (agent VISIONOS-OBS6, 2026-10-27)

Observed on the Mac with Apple's visionOS 27.0 (24M362) and iOS 27.1
(24A94401) simulators, test devices `ycode-test-vos-audio-1` (nine
visionOS first boots `b1`–`b8`) and `ycode-test-ios-audio-1` (boot `i1`),
both deleted at the end. Our Mach message recorder `audrec`, inserted into
every guest process, logged the audio service traffic, relayed
notifications, dumped the IO region, and in some boots rewrote the
service's replies inside the guest to test what is needed; our probe
`audprobe` used the public CoreAudio property API and ran an output IOProc
in the guest. No Mac setting was changed. Level 3; level 1 for the
CoreAudio codes and records. The wire protocol is specified in
`audio-host.md`; notes in `research/notes/visionos-renderer-observations.md`
(OBS6 section).

#### 10.17.1 Findings

- The guest's CoreAudio talks to the Mac's own audio daemon through the
  host-side endpoint `com.apple.audio.audiohald`, sees the Mac's devices
  and plays to the Mac's default output. `com.apple.audio.coreaudiod` is
  registered by the reference but no guest process used it.
- Every guest audio client (eleven processes in a visionOS first boot)
  registers, walks every object the service lists and makes one IO
  context per device. backboardd's AVAudioSession (simulator
  implementation) asks the service to create a private aggregate device
  over the default output, and PHASE runs its IO on that aggregate: the
  IO starts about 0.5 s after "Initializing Phase audio engine complete."
  and runs for the life of backboardd, one cycle per 512 frames.
- The audio settings plist that backboardd fails to open is written by
  the guest's CoreSimulatorBridge one second later; the failure is the
  reference's too (§9 Q22 c).
- With the service unreachable the reference fails exactly as Ycode does
  (§9 Q22 d). With the aggregate creation refused it fails the same way.
- The service can be much smaller than the Mac's: one output device with
  one stream and no controls, no plug-ins, boxes, clocks, taps or process
  objects, no custom properties and no notifications was enough for PHASE
  to start, IO to run and the room to load without an abort (boots
  `b4b`, `b6`, `b8`). The aggregate must appear in the system object's
  device list, and the IO context's workgroup port must be a real
  workgroup port (a null port or an error fails AudioDeviceStart).
- iOS 27.1 uses the same name and protocol (SpringBoard registers at
  boot; systemsoundserver-simd creates an aggregate and runs IO to play a
  system sound). Ycode's iOS guests have had no audio too.

#### 10.17.2 What Ycode must do

1. **Serve `com.apple.audio.audiohald`.** Register it as a host-side
   endpoint in the guest's `user/<uid>` domain (`launchd-sim.md` §6.3),
   backed by a Ycode host service. `com.apple.audio.coreaudiod` may stay
   unregistered (1102).
2. **Speak the protocol of `audio-host.md` §2–§3** for messages 71, 2,
   13, 14, 16, 25, 19, 26, 21, 27, 15, 20, 30, 31, 46, 29, 35, 36, 3, 5,
   10, 63, 59 and 12: the NDR record, reply ID = request ID + 100, the
   exact reply sizes (the client's receive buffers are exact), complex
   replies without a return code, replies well within the client's 30 s
   timeout. Message 35 and 36 need no reply; message 500 need never be
   sent.
3. **Objects** (`audio-host.md` §4, §5, §9): the system object (ID 1)
   with empty `'plg#'`, `'box#'`, `'clk#'`, `'tps#'`, `'prs#'`, `'dev#'` =
   the output device plus every aggregate the client created, `'dOut'` and
   `'sOut'` = the device, `'dIn '` = 0, `'vers'` 1, `'mlkf'` 2, `'powh'`
   settable; one output device (class `'adev'`) with a fixed UID and name,
   48 000 Hz, one 2-channel Float32 stream, empty `'ctrl'`, `'ioct'`
   property list, `'dch2'` [1, 2], a 2-channel `'srnd'` layout; IO contexts
   made from the `'ioct'` list (message 3) with `'grid'`, `'fsiz'` 512,
   `'fsz#'`, settable `'guse'`; aggregates made by message 5 (class
   `'aagg'`, the UID and name the client gave, one stream, one subdevice
   of class `'asub'` reached through qualified `'ownd'`, `'acom'`, `'agrp'`,
   settable `'dch2'` and `'srnd'`, `'tran'` `'grup'`). Answer "has
   property" with 0 for anything not listed; no error reply was ever
   needed.
4. **IO** (`audio-host.md` §10): on message 63 make a shared region of
   the observed size (65 536 bytes for a device's context, 245 760 for an
   aggregate's) with the observed layout, hand the guest a memory entry
   for it, an IO port and the size; on each cycle message write the next
   cycle's timestamps (sample time advancing by the buffer size, host
   time in the guest's own `mach_absolute_time` units, the ticks-per-frame
   record at offset 0 consistent with that clock) and the cycle number,
   then send the wake with ID + 1 to the client's wake port, paced at the
   nominal period (512 frames at 48 kHz: 10.67 ms) on the guest clock; on
   message 12 stop. The output data can be discarded at first.
5. **Workgroup port.** Message 59 must return a port that the guest's
   os_workgroup_create_with_port accepts and that the IO thread can join:
   Ycode's guest kernel needs workgroup (work-interval) ports for this, the
   kind os_workgroup_copy_port hands out. Check first what Ycode's kernel
   personality does for those calls; a null port or an error fails the
   start.
6. **Settings files.** Keep preparing `DEV/data/var/run/com.apple.coresimulator.audio.plist`
   (its UIDs set to Ycode's device UID) and the empty `simulatoraudio/`
   directory before boot; CoreSimulatorBridge writes the rest.
7. **Expected result.** backboardd logs "Built valid aggregate",
   "Hardware output: 2 channels …", "engine@…: created with mode default,
   sr 48000 Hz" and "Initializing Phase audio engine complete." without
   "Failed to initialize"; IO cycles run for the life of backboardd; no
   'API Misuse' abort after "Compiling PSO … composeSyntheticEnvironmentDefinition".
   The same service gives iOS guests audio (SpringBoard, system sounds).

#### 10.17.3 Open questions

1. How the client finds the output data offset (0x8000) in the region,
   and the layout of input buffers; Ycode should copy the observed layout.
2. Whether pacing faster or slower than the timestamps, or never
   consuming the data, disturbs PHASE (the reference's pacing could not be
   varied).
3. What the guest runtime checks when it turns the workgroup port into a
   workgroup (and so what Ycode's kernel must model).
4. Whether the `'tran'` value changes PHASE's output mode (the reference
   was a Bluetooth headset, which PHASE logged as headphones).
5. Messages for destroying IO contexts and aggregates, and the service's
   duty when a client dies (dead-name of the port of message 71), were not
   seen in 150 s boots.

### 10.19 Round AUDIO-HOST under Ycode: the guests get audio (agent AUDIO-HOST, 2026-10-27)

Clean-room work for §10.17.2 (branch `audio-host`). No Apple simulator,
Xcode or reference tool was run or opened, nothing under `research/` was
read, nothing was disassembled. Level 3 (Ycode boots on the Thor: guest
`log stream`, Ycode's host log, `YCODE_AUDIO_CAPTURE`, screenshots), level 1
for CoreAudio's public codes and records and xnu's work intervals. The
service is `audio-host.md` §13; the kernel side `work-intervals.md`.
visionOS boots `v1`–`v9` on a copy of R5's device (`v2` is void: the
translator binary was missing), iOS 27.1 boots `a1`–`a5` on a copy of R5's
iOS device.

#### 10.19.1 Changes

1. **`com.apple.audio.audiohald`** is a host-side endpoint served by
   Ycode's audio service (`audio-host.md` §13.1–§13.4): the 1010000 + n
   protocol with exact reply sizes, one 48 kHz stereo Float32 output device
   with one stream, IO contexts, private aggregates in the creator's
   `'dev#'`, "has property" 0 for everything else, the shared IO region and
   the host-paced cycle with wake-0 restarts, a workgroup port per IO
   context, `YCODE_AUDIO_CAPTURE`, snapshots. `coreaudiod` stays
   unregistered.
2. **Work intervals** in the kernel (BSD 499: get flags, join, leave,
   destroy, notify; host-made joinable work-interval ports), and the guest
   library's port-based work-interval calls ask the kernel first
   (`work-intervals.md`).
3. **`mlock`/`munlock`** succeed on mapped ranges. Without them the HAL
   client could not wire its IO region ("HALB_SharedBuffer::Lock: mlock
   failed … byte size 245760") and gave up every start after one cycle
   (`v1` and `a1`: 104 starts each).
4. **Normal pthread mutexes** (SimHostLibs): an unlock by a thread other
   than the holder releases the mutex, and a relock by the holder waits,
   as Darwin does; Ycode used to answer EPERM and EDEADLK. With audio
   running, PHASE's engine stop (`PHASEEngine stop`, about 15–25 s after
   the room's PSO line in `v3`, `v4`, `v6`, `v7`) was followed within a
   second by backboardd's abort: "terminating due to uncaught exception of
   type std::__1::system_error: mutex lock failed: Resource deadlock
   avoided" (a caulk messenger thread in `v3`, `v4`, `v6`; a PHASE dispatch
   worker in `v7`, after the unlock change alone). With both changes the
   stop is harmless (`v8`, `v9`).
5. The audio settings files are written before boot (`audio-host.md`
   §13.5): backboardd's first open of `audiosettings.plist` succeeds.
6. **Control channel:** a host-side name that does not fit the control
   channel's queue fails to queue at once instead of after a 5 s send
   timeout (§10.19.3: that wait delayed every boot with more than five host
   names by 5 s).

#### 10.19.2 visionOS 27.0

| Boot | Build | PHASE engine | IO (backboardd's aggregate) | backboardd |
|---|---|---|---|---|
| `v1` | service only | "Built valid aggregate 35", "Hardware output: 2 channels with layout UseChannelDescriptions", "engine@…: created with mode default, sr 48000 Hz", "Initializing Phase audio engine complete." | 104 starts, 1 cycle each (mlock) | lived the whole boot (300 s); no 'API Misuse' |
| `v3` | + mlock, work intervals | as `v1`, in each of three backboardd instances | 6 857 cycles, 90 restarts | aborted twice (EDEADLK after `PHASEEngine stop`), the third instance lived |
| `v4`, `v6`, `v7` | + diagnostics; `v7` + the unlock change | as `v1` | 7 179, 3 769 and 3 734 cycles (172, 10, 12 restarts) before the abort; the restarted instance 16 162, 20 995 and 21 302 cycles (1, 0, 0 restarts) to the end | aborted once each, after `PHASEEngine stop` |
| `v5` | as `v4` | as `v1`; no engine stop | 24 505 cycles, 61 restarts | lived the whole boot |
| `v8`, `v9` | final | as `v1`; `PHASEEngine start`, then `stop` | 24 217 and 23 138 cycles (60 and 48 restarts), until the shutdown | lived the whole boot; no abort |

In every boot the room loads as in R5 (RealityEnvironment's "Done loading
synthetic environment asset { name=LivingRoomDay }", backboardd's
"Compiling PSO … composeSyntheticEnvironmentDefinition") and **no 'API
Misuse' / "Cannot create a PHASEMaterial with nil or invalid PHASEEngine"
abort occurs**: §10.16.3's blocker is gone. Twelve processes register as
audio clients (backboardd, SurfBoard, RealityEnvironment, RealityHUD,
RealityLauncher, RealityChrome, RealityKeyboard, RealityNotifications,
RealityWidgets, pointeruid, MRSiri, mobilecal); backboardd and
RealityEnvironment each make their `iOSSimulatorAudioDevice-<pid>-0`
aggregate, as in the reference (`audio-host.md` §5); backboardd's IO
thread joins the context's workgroup ("join … -> ok: joined #2"). PHASE
plays one short, quiet sound about 60 s after its IO starts (captured:
peak 0.016 for about a second); otherwise its output is silence. With the final build the
screenshots show the home view's icon outlines from 110–120 s onward
(`v8`, `v9`) on a black background (no room); R5's frames were black. The
room's composition is the GPU work of VISIONOS-R6 (§10.14.4, §10.13); no GPU
hang line appeared in `v8`/`v9`'s 300 s.

The IO numbering restarts (wake 0) 50–90 times in four minutes: under the
Thor's load backboardd's IO thread is often more than a cycle late
(`audio-host.md` §13.4). HAL logs "IOWorkLoop: skipping cycle due to
overload" for some of them; nothing else follows from it.

#### 10.19.3 iOS 27.1

| Boot | Build | Home screen | Audio | Guest fatal conditions |
|---|---|---|---|---|
| `a1` | service only | 185.9 s (load 72) | SpringBoard registers (`com.apple.springboard`), walks the objects, makes one IO context; Lock: systemsoundserver-simd registers, makes `iOSSimulatorAudioDevice-385-0`, 104 starts fail (mlock) | fileindexerd 5, intelligencetasksd 5 |
| `a3` | + mlock, work intervals | 102.1 s (load 56) | Lock, Home, Home, Lock: one IO run on the aggregate, 3 918 cycles (42 s, until the shutdown), 2 restarts, workgroup joined; capture: 42.0 s, 57 264 samples not zero, peak 0.293, two bursts of about 0.25 s at 0.0 s and 5.8 s (the two Lock presses: the lock sound) | fileindexerd 6, intelligencetasksd 12, PosterBoard 1 |
| `a4` | `YCODE_DEBUG_NO_AUDIO=1` (as before) | 98.5 s (load 60) | none | fileindexerd 5, intelligencetasksd 4 |
| `a5` | final | 46.8 s (load 22) | as `a3`: SpringBoard's walk; systemsoundserver-simd's aggregate and one IO run, 3 881 cycles, 0 restarts, workgroup joined; the same two lock sounds (57 264 samples not zero, peak 0.293) | fileindexerd 5, intelligencetasksd 8 |

`a2` is void (the translator binary was missing). The fatal conditions are
the known ones (§10.16.5: fileindexerd, intelligencetasksd, PosterBoard's
"versionsURL"); none is an audio client, and their counts vary as much
between boots without audio. `a1` ended with a host crash in
`VCPUPool.joinThreads` during the teardown after the guest had exited
(once in five boots; not seen again).

Boot time to the home screen (`timed.sh`, fresh copies of the golden
device `9-J/dev-pristine`, one build, "before" = `YCODE_DEBUG_NO_AUDIO=1`):

| Pair | Before (no audio) | After (audio) |
|---|---|---|
| 1 | 52.9 s (CPU 515 s) | 62.3 s (542 s) |
| 2 (reverse order) | 55.8 s (528 s) | 66.2 s (574 s) |
| 3, with the queue fix below | 63.5 s (522 s) | 55.1 s (524 s) |

The first two pairs showed a real cost of about 10 s. A boot profile of
each (`YCODE_BOOT_PROFILE`, 100 s) found launchd_sim's first job spawn at
5.37 s with audio against 0.38 s without: the audio name is the sixth
host-side name, the control channel's queue holds five, and the host's
attempt to queue the sixth waited out a 5 s send timeout before the 708
reply that hands launchd_sim its port (`launchd-sim.md` §6.3). The queue
attempt now fails at once and the name is registered after the bind (as
R3 intended); pair 3 shows no cost (the spread between boots is ±6 s). The
same 5 s were spent by every boot that had more than five host names
before this round (a visionOS boot, or an iOS boot with the HID bundle).
SpringBoard's whole client walk takes 0.13 s (51 requests).

#### 10.19.4 What remains

1. The room's composition and the GPU (VISIONOS-R6).
2. Real playback: the blocks reach `AudioHostService.deliver` with their
   host play time; a PipeWire/PulseAudio sink on Linux, or a stream to the
   IDE beside the display stream, is not written (`audio-host.md` §13.4).
3. Reference-only questions: `audio-host.md` §13.8 (`'tran'`, pacing and
   restarts, the zero time stamp's period, the workgroup's flags).
4. The restarts: a service that lets the device clock slip instead of
   restarting when the client is late would need the reference's
   tolerance (§13.8 Q2) to choose.
5. Guests still cannot make work intervals of their own (`work-intervals.md`
   §4); the library keeps answering for them.

### 10.20 Round R7 under Ycode: the room appears (agent VISIONOS-R7, 2026-10-27)

Clean-room work on Ycode's own simulator on the Thor (branch `visionos-r7`
on the main line 96491af, which includes AUDIO-HOST; the device copied from
R5's; visionOS boots `b0`, `p1`–`p5`, `v1`–`v4` and the timing boot `t1`,
each from a fresh copy; iOS 27.1 boot `i1`). No Apple simulator, Xcode or
reference tool was run or opened, nothing under `research/` was read,
nothing was disassembled, and the guest's shader logic was not read: the
guest's functions were seen through ycode-airc's reflection (names, binding
types, access), Ycode's read-backs of the textures and buffers they bind,
and one offline replay of a dumped dispatch. Level 3 throughout.

#### 10.20.1 Where the room's pixels were lost

Boot `b0` (the main line as it was) reproduced §10.19.2: from the room's
PSO line on, all three frames of layer 2 read (0, 0, 0, 255) in every
sampled pixel, layer 1 the home view's outlines (about 9 000 of 518 400
sampled pixels not zero, mean alpha 4), every presented surface black but
for the outlines.

A pass probe (§10.20.3) of backboardd's command buffers that draw with
`fsCompose` (boot `p1`) gave the frame's data flow. A steady frame matches
§10.12.4: layer 2 cleared (pass 2); backboardd's own 3840 × 2160
`BGRA8Unorm_sRGB` target with `Depth32Float` cleared to (0, 0, 0, 1) and
the room drawn into it (pass 5: `vsUnlit` + `fsUnlit` indexed draws, one per
part of the room, each sampling one of four 4096² and one 1024²
`RGBA8Unorm_sRGB` textures with 13 or 11 levels and two 1024 × 1 `R32Float`
tables); the 4× pass resolving into layer 1; then `fullScreen2Vert` +
`fsCompose` loading layer 2 and sampling the room target (texture slot 0;
the function reads a `texture2d_array<half>` with `viewport_array_index`
and position, per its reflection). Every stage ran:

| Pass (`p1`, probe 2) | Read back |
|---|---|
| 5, depth | 8 294 399 of 8 294 400 texels written (the room's geometry was rasterized) |
| 5, room textures (all levels 0) | **0 texels not zero**, in all five |
| 5, colour | (0, 0, 0, 255) everywhere: the room drawn with zero textures |
| 11 (`fsCompose`), layer 2 | (0, 0, 0, 255) everywhere: a faithful copy of pass 5 |

So the compose pass, the layer write, the layer events and wakeboardd's
composition were correct; the room's textures were empty. They are
written by RealityKit's ASTC decoder `astc` (§10.13.1, §10.18): probes of
its command buffers (`p2`–`p5`) showed one compute pass per level, each a
`dispatchThreads` into a one-level texture, with non-zero inputs (block
data, the partition tables, the 56-byte parameters) and **every written
texture zero afterwards**, at every level. The texture facts the probe now
prints named the cause: each target is an `RGBA8Unorm` (70) view
(Vulkan `R8G8B8A8_UNORM`) of an `RGBA8Unorm_sRGB` (71) texture
(`R8G8B8A8_SRGB`) created with usage `0x13` (shaderRead | shaderWrite |
pixelFormatView), and the view had **no storage view**. Metal lets a kernel
write an sRGB texture through a view in the matching unorm format; Vulkan's
`R8G8B8A8_SRGB` has no storage-image feature on the Thor, and Ycode gave an
image storage usage only when its own format had that feature, so neither
the image nor its unorm views could be written: every decoded texel went to
the dummy image (§10.18.2). The decoded rooms had never reached their
textures; R6 only had to stop the decoder from hanging.

An offline replay (`ProbeReplayTests`) of one dumped dispatch (level 12 of
an 8184² texture: one void-extent block whose colour is 0x4545, 0x4545,
0x4545, 0x7C7C) through Ycode's back end with the cached translation wrote
`45 45 45 7c` into a plain RGBA8Unorm texture and into a one-level view of
a 13-level one: the translation and the dispatch were right, only the
target was missing.

Ruled out on the way, with the probe: skipped draws in the room pass (none
in the probed command buffers), pipelines that failed to build (none),
multisampling and resolve (the room pass is single-sampled; the resolve
into layer 1 is §10.14.2's), the compose pass and wakeboardd's
composition (layer 2 holds exactly the room target). The `RGBA16Float`
cube maps of the same command buffers (`generateClampedMap`, then
`generateMipmaps`) were not examined further: level 0 of the written cube
read almost all zero in `p1`'s first probe, but the room pass binds no
cube, and the room looks right without them (§10.20.7 item 4).

#### 10.20.2 Second cause: op 29's base instance

With the decoder's writes landing (`v1`, `v2`) the room appeared, but in
boots where the home view came up, parts of it were black and changed from
frame to frame (`v2`: at 60 s the rug, the television and the books; at
290 s the back and right walls, the pictures and the lamps), the icons
were black discs, and R4a's guard logged "draw skipped: base instance
196608 (6 instances) with vsUnlit" and "804257792 (2 instances) with
vsOcclusionQuery". The room target is cleared to opaque black, so a part
whose draw is skipped shows black.

Every implausible base instance seen since R4a (196 608, 2 359 296,
804 257 792, 1 072 693 248, 1 084 227 584, 1 085 145 088) has a zero low
half. Op-29 bodies logged in `v4` (§9 Q24):

```
0300 0000 6300 0000 0000 2400 0300 0000 0000 f02f
0300 0000 6300 0000 0000 2400 0800 0000 0000 2400
```

(triangles, 16-bit indices, index buffer ref 99, offset 0, 36 indices, 3 or
8 instances, base vertex 0, then the last word). Op 29 is the short form,
used only when every value fits in 16 bits (§8.3 of
`metal-sim-protocol.md`); the base instance is the low half of the last
word and the high half holds stale bytes (here 0x2FF0, or the index count
0x0024 again). Ycode read the word as one u32. Ycode now reads the low half
(§10.20.4); `v4` logged no skipped draw, and every frame from the room's
first to the end of the boot shows the whole room.

#### 10.20.3 Diagnostics (off by default)

- **Pass probes** (`YCODE_GPU_PROBE=<function names>`,
  `VulkanPassProbe.swift`): a command buffer with a draw or dispatch of a
  named function is described (as in a hang report) and, recorded into a
  host buffer of the probe's own, the textures each pass reads (before it:
  bound textures, level 0 of the binding, up to six layers; loaded
  attachments) and writes (after it: stored and resolved attachments,
  textures a kernel may write, blit destinations), and for compute and
  blit passes the buffers (bound, copied). When the GPU is done, one line
  per copy: texels not zero, then per format the channel means, alpha
  counts, NaN or infinite values and ranges, and the texture's facts (heap
  slot, sampled and storage views, Metal usage and type, the levels of a
  view, a view format that differs from the image's); draws the replay
  skipped, with the line that skipped them. `YCODE_GPU_PROBE_MAX`,
  `_INTERVAL_S`, `_AFTER_S`, `_MB`, `_BUFFER_KB`; `YCODE_GPU_PROBE_DUMP=<dir>`
  writes each copy's bytes. A probe copies hundreds of MiB and delays
  backboardd: in `p1`, `v1` and `v3` (probes from Run on) RealityLauncher
  never launched; start them late (`_AFTER_S`).
- `ProbeReplayTests` (opt-in): one dumped dispatch replayed through the
  back end with a cached translation.
- A kernel write to a texture without a storage view is now logged with the
  texture's Vulkan format (R6's log covered missing `shaderWrite` only).
- Op-29 records with bytes in the high half of the base-instance word are
  logged (the first eight, with their body).
- Argument-encoder set calls write their member into the argument buffer
  from the host (an experiment in R7, the default since R7b: §10.20.7;
  `YCODE_METAL_ARGUMENT_ENCODER=0` refuses them); the first 24 writes are
  logged.
- (R7b) Visibility results: the first modes and passes are logged
  (`visibility: mode 1 at offset 0 of #h`, `pass with n queries into m
  slots`), and slots counted by several segments of one pass.
- (R7b) `YCODE_DEBUG_PASS_DRAWS=<w>x<h>`: each render pass of that size
  whose draw list differs from the previous one of its kind is logged with
  the host's monotonic time, load and store actions, the visibility buffer's
  first slots, and per draw the functions, index count, instances, base
  instance, index buffer and first fragment texture;
  `YCODE_DEBUG_PASS_DRAWS_ALL=<s>` logs every such pass from that many
  seconds after the first, `YCODE_DEBUG_PASS_DRAWS_BUFFERS=1` adds the
  fragment buffers. At most 20 000 lines.

#### 10.20.4 Changes

1. **sRGB images get storage usage for their unorm views.** When Metal
   asks for `shaderWrite` (or gives no usage) and the format cannot be a
   storage image but its unorm sibling can (`R8G8B8A8_SRGB`,
   `B8G8R8A8_SRGB`, `A8B8G8R8_SRGB_PACK32`, `R8_SRGB`, `R8G8_SRGB`), the
   image is created with storage usage and `VK_IMAGE_CREATE_EXTENDED_USAGE_BIT`
   (each view restricts its usage to what its own format supports, as Ycode's
   views already did). Views in the unorm format then get storage views; the
   bytes a kernel writes through them land unchanged, as Metal stores them.
   A kernel that writes the sRGB texture itself (not through a view) still
   has no storage view (Vulkan cannot encode sRGB on a storage write); such
   writes go to the dummy image and are logged. None was seen in `v1`–`v4`.
   GPU test `VulkanBackendTests.kernelWritesUnormViewsOfAnSRGBTexture`
   (every texel of both levels unwritten without the change).
2. **Op 29's base instance is 16 bits** (`metal-sim-protocol.md` §8.3).
   Test `CommandDecoderTests.shortIndexedDrawBaseInstanceIsSixteenBits`.
   R4a's base-instance guard (§10.13.1) stays; it no longer fires in these
   boots.
3. *(R7b)* **Argument-encoder set calls write their members** (§10.20.7).
4. *(R7b)* **Visibility results** (record 132) are counted with occlusion
   queries (§10.20.8).

#### 10.20.5 Boots with the changes

| Boot | Changes | First lit frame (home watch) | Result |
|---|---|---|---|
| `v1` | 1, probes | 68.8 s | the whole room from 100 s; no home view (the probe, §10.20.3) |
| `v2` | 1 | 49.7 s | the room, with parts black that change over time; home view as black discs |
| `v3` | 1, probes | 65.6 s | the whole room; no home view |
| `v4` | 1, 2 | 52.4 s | the whole room; home view as black discs; 2 of 26 frames with parts of the room missing (§10.20.9; R7 first read this boot as "every frame") |

Layer 2 in `v1`–`v4`: 518 396 of 518 400 sampled pixels not black, mean
bytes (144, 155, 159, 255), alpha 255 everywhere, in all three frames; the
swapped surfaces show the room. The picture matches §10.12.3's reference
frame: the living room by day seen from the sofa, the low table, the
television on its sideboard against the back wall with a framed print
above it, three plant prints on the left wall, two floor lamps, the shelf
unit on the right, the curtained window. Ycode's home watch (the first
presented surface that is not dark) fires on the room's first frame, since
every frame before it is black. RealityLauncher presented the home view
about 10 s after the PSO line; its icons show as black discs and its tab
bar as a black pill, without names (layer 1: about 10 000 of 518 400
sampled pixels not zero, mean alpha 4; §10.20.7 item 1). No GPU hang
report, device loss or backboardd abort in `v1`–`v4`.

Cold boot to the room's first frame (`timed.sh`, boot `t1`, a fresh copy
of the device, the build with both changes, no diagnostics): **45.7 s**
from `ycode-simd`'s start to the first presented surface that is not dark
(frame 778; 7.7 CPU-minutes of `ycode-simd` by then; the machine otherwise
idle). The reference shows the room about 7.3 s after Run (§10.12.3);
Ycode's time is measured from the host process's start, so it includes
the boot before Run.

#### 10.20.6 iOS 27.1 check

Two functional boots of the iOS 27.1 device (copied from AUDIO-HOST's)
with the final build (both changes), each launching an app through
`ylaunch` 20 s after the home screen: `i1` Settings (home screen at
43.4 s, load average 18), `i2` Safari (61.6 s, load 49). Both apps
launched, the home watch saw rendered frames, no GPU hang report, device
loss or Metal back-end error was logged, no op-29 high half and no kernel
write without a storage view were logged; guest fatal conditions only
fileindexerd and intelligencetasksd, as in earlier rounds.

#### 10.20.7 Round R7b: the home view's icons (argument encoders)

Agent VISIONOS-R7b continued R7 on 2026-10-28 (same rules: only Ycode's
simulator was booted, on the Thor; no reference tool, nothing under
`research/`, no disassembly, the guest's shader logic not read). It merged
the main line (NET-IMPL, CAMERA-HOST, IDE-GLASS and the observation rounds)
first. Boots: `m1`, `m2` (merged build), `e3` (argument encoders), `v5`,
`v6` (visibility results, without and with argument encoders), `v7`–`v12`
(diagnostics), `f1` (final build), iOS `i3`–`i5`.

What R7 found (kept here as it stood): the home view's icons draw as black discs with no names (the
   reference: icons and names on a transparent layer 1). A probe of
   `fsCALayer` 150 s into a boot (`q1`, `d1`) found the icon draws of the
   4× pass binding icon textures with content (256² `RGBA16Float`, means
   0.6–0.8) and still writing (0, 0, 0, 1). Every icon draw binds the same
   264-byte argument buffer as fragment buffer 13 (`indirect_buffer`
   `re::RealityKitParametersTier1`), and it is **all zero**; the hang
   report's pointer scan finds no address of a live buffer in any buffer
   these draws bind. backboardd fills such buffers through argument
   encoders (op 19, 146–194 set calls per boot, kind 0 then kind 1 for
   indices 0–14), which Ycode refuses, so `fsCALayer`'s parameter loads go
   through null pointers that R4a's guard turns into zeros: most likely
   the black icons, and the null pointers of R4a's hang. Who writes the
   members, and where, is §9 Q25. An experiment that writes them from the
   host (`YCODE_METAL_ARGUMENT_ENCODER=1`: member n at offset 8n; a buffer's
   GPU address plus the call's offset, a texture's heap index, a sampler's
   resource ID) wrote every member of boot `e1`'s set calls into CPU-visible
   memory; in that boot RealityLauncher did not present the home view
   before the end (as in the probed boots `v1`, `v3`), and two more boots
   (`e2` with it, `c1` without) ran under a load average of 144 and reached
   neither the room nor the home view, so its effect on the icons was not
   known.

R7b repeated the experiment in boots that ran long enough: `e3` (600 s, a
load average of 50 to 140 from other agents' boots), `v6`, `v7`, `v9`, `v10`
(load 10 to 60). In every one the home view came up with its icons and
names: Widgets, Siri, Safari, Photos, the folder of other apps, Settings,
Files and Passwords on the room, the tab bar on the left with its three
glyphs (`.claude/worktrees/visionos-room.png`, outside git: `v6` at 450 s,
downscaled to 960 × 540). Before it every icon was a black disc. The
argument buffers' members are now written by the host and the icons sample
their parameters; R4a's null guard no longer turns the parameter loads into
zeros. So the writes are now the default (`MetalHostCore`,
`YCODE_METAL_ARGUMENT_ENCODER=0` refuses the calls as before): kind 0
names the argument buffer and offset; kind 1 writes the buffer's GPU address
plus the call's offset, kind 2 the texture's heap index (Ycode's
`gpuResourceID`), kind 3 the sampler's resource ID, each as 8 bytes at the
argument buffer's offset plus 8 × the member index, the layout ycode-airc
reads (`metal-shaders.md` §3.6: every member 8 bytes, in id order). A
member index whose layout puts inline data or sparse ids before it would
land elsewhere; op 16's layout description is still not parsed (§9 Q25).
Test `CoreTests.argumentEncoderSetCallsWriteTheirMembers` (no write without
the change). One icon (Widgets in `v6`) still drew only its name in some
frames.

#### 10.20.8 Round R7b: visibility results

visionOS backboardd sets visibility-result modes (record 132): boolean mode
at offsets 0 to 128 of 8- to 136-byte buffers, around `vsOcclusionQuery`
draws of boxes (36 indices) in the 4× pass and in small passes of their
own. Ycode ignored non-zero modes (`metal-sim-protocol.md` §8.3), so the
slots kept whatever the guest left there. They are now counted: each run of
draws with one non-zero mode and offset in a pass is one Vulkan occlusion
query (precise in counting mode when the device has
`occlusionQueryPrecise`), begun before its first draw and ended at the next
mode change, at a feedback snapshot (which ends rendering) and at the end
of the pass; after the pass each slot receives its query's 64-bit result
(`vkCmdCopyQueryPoolResults`). Slots the pass does not count keep their
bytes. A slot counted by more than one segment in a pass gets the last
segment's count where Metal sums them (logged; not seen). Pools of 1 024
queries are recycled once their recording completes
(`VulkanVisibility.swift`). GPU test
`VulkanBackendTests.visibilityResultsCountSamples` (slots keep the filler
without the change). It changed nothing visible in `v5`–`v12`: the parts
missing in some frames (§10.20.9) are not culled by these results.

#### 10.20.9 Round R7b: parts of the room missing in some frames

In all but one of the boots since R7's fixes, 5 to 40 % of the screenshots show the room
with parts missing: either the back and right walls, the pictures, the
lamps and the shelf frame (the black clear colour shows, about 34 % of the
frame dark), or the sofa, armchair, tables, rug and plant (the floor shows
through, about 5 % dark). Counted with 240 × 135 thumbnails: `v2` 10 of 26,
`v4` 2 of 24, `m2` 3 of 11, `e3` 3 of 16, `v5` 6 of 27, `v6` 9 of 36, `v7`
8 of 48, `v9` 0 of 43, `v10` 4 of 52.

The room is one pass of backboardd's (3840 × 2160, cleared, five
`vsUnlit` + `fsUnlit` indexed draws of 41 520, 57 543, 162 624, 20 328 and
48 indices) about 30 times a second, and `fsCompose` copies it into layer 2.
The draw logs (`YCODE_DEBUG_PASS_DRAWS`, boots `v9`, `v10`) show that **the
guest leaves draws out**: 967 of 2 705 room passes in `v10` lack one or two
of the three large parts, with their index buffers and textures unchanged,
in a fixed cycle of 16 room frames (0.533 s): the 41 520-index part is
missing for three frames, the 57 543-index part for one of them, and the
162 624-index part (the walls) for two frames eight frames later. The
screenshot of `v10`'s logged window with the walls missing (98 s) follows a
room pass without the 162 624-index draw. Ycode skips none of these draws (no skip lines, no
probe-listed skips). The cycle matches a 768 × 432 pass that backboardd
runs once every 16 room frames (`v7`'s Metal trace: 440 such passes, median
interval 0.533 s): a clear-all draw, then the same five parts with
`vsLinearizedDepthOnly` + `fsLinearizedDepthAsColor` into four colour
attachments (`R16Float`, `RGBA16Float`, `RGBA16Float`, `R16Float`, loaded
and stored as don't-care/store) and a don't-care depth, followed by blits
and a pass reading the four targets and many small parameter blocks. A
probe of it (`v12`) read attachment 0 as linear depth in metres (1.6 to
5.4, every texel written), attachment 1 almost empty (611 texels not zero),
attachment 2 the clear value 10 000 and attachment 3 infinite in every
texel; the two cached variants of `fsLinearizedDepthAsColor` write render
target 0 or 2 (ycode-airc's reflection), so attachments 1 to 3 hold clear
values as drawn. Which result of that work makes the guest leave a part
out, and whether the reference does the same (at 90 frames a second a
part missing for one frame would hardly be seen), is open (§9 Q26).
Visibility results (§10.20.8) and argument encoders (§10.20.7) did not
change the cycle.

#### 10.20.10 Round R7b: boots and the iOS 27.1 check

| Boot | Build and switches | Room (home watch) | Home view | Frames with parts missing |
|---|---|---|---|---|
| `m1` | R7 + first merge | not reached in 270 s (load average about 100 from other agents' boots) | — | — |
| `m2` | R7 + first merge, 600 s | 264 s (same load) | black discs | 3 of 11 |
| `e3` | + argument encoders (switch) | 118 s | icons and names | 3 of 16 |
| `v5` | + visibility results | 179 s | not launched | 6 of 27 |
| `v6` | + both | 73 s | icons and names | 9 of 36 |
| `v7`–`v12` | + both, diagnostics | 75–150 s | icons and names in `v7`, `v9`, `v10` | §10.20.9 |
| `f1` | final, before the second merge | 83 s (load about 80) | not launched in 330 s | 3 of 16 |
| `f2` | final, after the second merge (FS-HOST, FEAT-IMPL, FOLD-IMPL2), no switches | 74 s | icons and names (single icons missing in some frames) | 3 of 23 |
| `f3` | final, after the third merge (HUB-UI), 300 s | 121 s (load about 110) | not launched | 3 of 6 |

RealityLauncher's scene was not created before the end of `v5`, `f1`, `f3` (and,
in R7, `e1`, `v1`, `v3`): a launch that sometimes does not happen under
load, seen with and without each change. No GPU hang report, device loss or
skipped draw in any of these boots.

iOS 27.1 (`ios.sh`, the device of R7's `i1`, an app launched through
`ylaunch` 20 s after the home screen): `i3` (first merge, R7's changes,
load average 145) home screen at 214.6 s, Settings launched, the stop timed
out (the guest did not shut down within 30 s under that load); `i4`
(final, before the second merge) Settings, home screen at 51.0 s; `i5` Safari,
41.1 s; `i6` (after the second merge) Settings, 85.4 s (load 74); `i7` (after
the third merge) Safari, 129.7 s (load 110). Every app
launched, frames rendered, no GPU hang report or device loss; no op-19 set
call or visibility mode appeared in these iOS boots. Guest fatal conditions:
intelligencetasksd (all), and in `i3` also amsaccountsd and
amsengagementd once each and fileindexerd (fixed on the main line by
FS-HOST).

#### 10.20.11 What remains

1. The parts of the room missing in some frames (§10.20.9, §9 Q26).
1a. RealityLauncher's home view is sometimes not launched before the end of
   a 300 to 420 s boot (`v5`, `f1`, `f3`; R7's `e1`, `v1`, `v3`), mostly
   under a high load average; why SurfBoard does not create its scene was
   not examined.
2. Direct kernel writes to sRGB textures (no view): no storage view, the
   writes are lost and logged (§10.20.4 item 1). A faithful version encodes
   linear to sRGB in the translated function, which needs the format of the
   bound texture at run time (none seen in these boots).
3. §9 Q24 asks the reference to confirm op 29's last word with a non-zero
   base instance (Ycode's reading rests on the short form's 16-bit rule and
   the zero low halves).
4. The `RGBA16Float` cube of `generateClampedMap` (an environment map,
   most likely for reflections) read almost all zero at level 0 after the
   kernel in the one frame probed; whether its other levels or later frames
   hold data was not checked.
5. §10.13.5 items 3–5 and §10.19.4 items 2–5 are unchanged.
6. Argument-buffer layouts (op 16) are not parsed: members land at 8 × the
   index, which holds for layouts of resources with dense ids (§10.20.7,
   §9 Q25). A snapshot restore that gives textures new heap indices leaves
   stale texture IDs in argument buffers until the guest encodes them
   again.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Two runtimes, one identifier, profiles identical; match list (§2.1) | 2, 3 | runtime `Info.plist`/`profile.plist` via `plutil`; `simctl list runtimes -j`; `simctl runtime match list` |
| `SystemVersion.plist` values | 2 | file read |
| Profile differences (§2.2) | 2 | `profile.plist` diff against iOS 27.1 |
| Layout, cache sizes, image counts, app and migrator counts (§2.3) | 2 | `ls`, `.map` line count, Info.plist presence |
| Job sets and Mach services (§2.4) | 2 | our `jobs.py` over the launchd plists of both runtimes |
| Running jobs and processes | 3 | `launchctl list`, `launchctl print user/501` in the guest; `ps` (our `simprocs.py`) |
| Host-side endpoints, five SimMetalHost, no xrserverd (§2.5) | 3, 4 | `launchctl print user/501` (simhost block); `ps`; name search of the host's launchd directories and Xcode/CoreSimulator bundles |
| Simulated rooms format (§2.6) | 2 | `Info.plist`, `Config.plist`, file listing; preference file read |
| Packaging, sealed, not encrypted (§2.7) | 2, 3 | `simctl runtime list -v`; `diskutil info`; `mount`; `df` |
| Device type and capabilities (§3.1–3.3) | 2 | device-type bundles via `plutil` |
| Bootstrap plist and environment (§3.4) | 3 | `DEV/data/var/run/launchd_bootstrap.plist`; `ps -E` of backboardd and wakeboardd |
| Libraries are separate builds with the same exports | 4 | `vtool -show-build`, `nm -gU` |
| UIDevice values, window size | 3 | VisionProbe |
| What the screen shows (§4.1) | 3 | `simctl io screenshot` (kept in `research/dirty/visionos/`) |
| Render pipeline (§4.2) | 3, 4 | `lsof` of guest processes (mapped host libraries); backboardd, wakeboardd, vhmdd and VisionProbe logs (`simctl spawn … log show`) |
| Display (§4.4) | 3 | `simctl io enumerate` |
| Metal profile (§4.5) | 3 | VisionProbe |
| CPU and memory (§4.6, §6) | 3 | `top`, `footprint` per process (our `simfootprint.sh`) |
| Device Hub input mapping (§5.1) | 1 | Apple, "Interacting with your visionOS app in Device Hub" (developer.apple.com, Xcode documentation) |
| DeviceHub plug-in facts (§5.2) | 4 | `otool -L`, `nm -gU`/`nm -u`, `strings` of `VisionDeviceKitExtension` |
| Guest HID services (§5.3) | 3 | backboardd log ("Connecting service" lines) |
| ARKit providers and pose (§5.4) | 3 | VisionProbe |
| Boot times, migration, launches (§6) | 3 | `simctl boot`/`bootstatus`, our `boottimer.sh`, migration plist, runningboardd and SurfBoard logs |
| Home layout | 2, 3 | `com.apple.RealityLauncher.plist` read with `plistlib` |
| Requirements, rounds, risks (§7–8) | — | Ycode decisions from the above |
| Ycode R1 results (§10.2), the abort and what was ruled out (§10.4) | 3 | Ycode boots c1–c13 on the Thor (device `d1`, 24M362): `log stream` one-shots, `--trace-name` traces of wakeboardd and backboardd, thread reports, Ycode fault reports with call chains, our probes `vprobe`, `mtlwatch.dylib`, `rkprobe`, Ycode's `YCODE_FRAMEBUFFER_CALLS`, `YCODE_METAL_DUMP_OPS`, `YCODE_IOSURFACE_LOG` diagnostics |
| `memorystatus_control` answers EPERM to unprivileged callers (§10.4) | 1 | xnu `bsd/kern/kern_memorystatus.c`, `memorystatus_control` |
| Ycode implementation (§10.1, §10.3) | — | Ycode decisions |
| Reference device questions, order and answers in backboardd and datamigrator (§10.6.1) | 3 | our recorder inserted into reference boots (methods of the device class and of the Metal objects it returns rerouted and logged; no proxy); our capability probe |
| Only op 37 reaches the host; reference op-37 reply (§10.6.1) | 3 | our probe with our Metal message recorder (`research/experiments/simulator/metal-sim/`) |
| Order of the reference start (§10.6.2) | 3 | our recorder, cold and repeat boots |
| Assertion text among the engine's strings (§10.6.2) | 4 | `strings` of the runtime's dyld cache |
| Fault tolerance of the start (§10.6.3) | 3 | 15 reference boots with one fault injected by our recorder each |
| Log window at debug level (§10.6.4) | 3 | `log config` (debug, persisted) and `log show --debug` in the reference device |
| `messageType` 17 and 18 (§10.6.5) | 3 | our probe with our Metal message recorder |
| First-boot semaphore and Pulse (§10.6.6) | 3, 4 | wakeboardd's imported symbols and strings; boots with and without the semaphore present |
| wakeboardd swap pattern and timing (§10.6.6) | 3 | our recorder's SimFramebuffer interposition in five reference first boots; wakeboardd, backboardd and SurfBoard logs |

| R2a recorder results, start order under Ycode, no call or system call after the primitive-shape stage (§10.7.2) | 3, 4 | Ycode boots r1–r18 on the Thor (device copied from `d1`): `mtlrec.dylib` logs (with caller chains named by `dladdr`, exported symbols only), the boot profile's PC timeline named by `symaddr`, guest `log stream` at debug level, R1's trap trace c5 |
| Defaults and memory-size experiments (§10.7.2) | 3 | Ycode boots r13 (`YCODE_GUEST_MEMSIZE` 16 GiB), r17 (three defaults set to NO) |
| `memorystatus_control` self-query of memory-limit properties is refused without privilege (§10.4 row confirmed) | 1 | xnu `bsd/kern/kern_memorystatus.c`, `memorystatus_control` (only the freezer queries skip the check on release kernels) |
| Shared-event handles, op-37 z, launch fix (§10.7.3) | — | Ycode decisions; unit tests |
| Reference start order, counts and answers with Ycode's recorder; VFX queue before the primitive-shape stage; defaults read and their values; "Compiling PSO RT" in the reference (§9 Q13, §10.8.1, §10.8.2) | 3 | Ycode's `mtlrec.dylib`, built for the visionOS simulator SDK, with our preference-read log, in five reference boots of `ycode-test-visionos-obs2` (one cold); `log show` of backboardd matched by the wall clock |
| Return offsets in the render manager's and the engine's start; names of the engine's components (§10.8.2, §10.8.4) | 4 | caller chains from the same recordings, named by `dladdr` (exported symbols of CoreRE) |
| Heap sizes are not the cause (§10.8.3) | 3 | reference boot with every `heapTextureSizeAndAlignWithDescriptor:` answer replaced by R2a's formula: heaps of 69 632 and 67 108 992 bytes, start completed |
| Size-and-align answers, heap size rounding, available size, alignments, the fitted rule (§10.8.3) | 3 | the start's own queries (recorder) and our size probe (4 170 texture descriptors, 45 buffer queries, 26 heaps) run with `simctl spawn` in the reference device; the rule checked by our script against every probe row |
| VFX manager construction, its queues, the hookup entered and returning early, no default read (§9 Q14, §10.9.2) | 3, 4 | Ycode boots a2–a15, b1–b3 on the Thor (device copied from R2a's): `mtlrec.dylib` look-ups (dispatch queue labels with caller chains), owner-block scans and dumps, the guest's debug log of preference reads; function names from `dladdr` and the images' symbol tables (our `exports`) |
| The two render-manager bytes decide the hookup and the start; where they change; candidates ruled out (§10.9.3) | 3 | black-box experiments in Ycode's guest with `mtlrec.dylib` (byte flips with the hookup called again, b4; bytes set before the hookup, b12; dumps at successive points, a12, a14, b10; isolated constructor call, b13; engine configuration read and changed, b8, b9, b18, g1–g5; configuration byte bisection, f0, fA–fD; frame and job manager bytes, h1, h2; CPU count c1, a10, a15; preference b6) |
| What follows the abort with the bytes set; wakeboardd's and backboardd's crashes; `messageType` 19 (§10.9.4) | 3, 4 | Ycode boots p1–p11 (guest `log stream`, Ycode fault reports with call chains named by our `symaddr`, `mtlrec.dylib` IOSurface and XPC reads in wakeboardd and pre-call logs in backboardd, Ycode's host log); probe `shtex`; the constant `kIOSurfaceMetalSharedTexture` read in the guest |
| Op 22 rule, 16 KiB heaps, `messageType` 19 answer (§10.9.5) | — | Ycode design; unit tests `CoreTests.heapSizesFollowTheReferenceRule`, `sharedTextureGetsAHostSurface`; iOS 27.1 boots with Settings and Safari launched (Ycode, R2b) |
| Reference RM +0xd0 … +0xd7 at the three points; clearing +0xd4/+0xd5 in the reference reproduces the abort (§9 Q15, §10.10.1) | 3 | Ycode's `mtlrec.dylib` (unchanged build) in reference boots q1, q3, q5 of `ycode-test-visionos-obs3`; `log show` of backboardd |
| The span's only call is the first `hw.physicalcpu` query of the process, with an 8-byte buffer length (§10.10.1) | 3 | recorder look-ups with caller chains, boots q2, q4, q6 |
| The query's buffer is the render manager's +0xd0 (§10.10.1) | 5 | 36 instructions of the loaded image read in the reference device and disassembled; done because black-box levels could not reach a decision without calls; kept in `research/dirty/visionos-obs3/` |
| An 8-byte `hw.physicalcpu` answer clears the bytes and causes the abort in the reference; control boot (§10.10.1) | 3 | recorder copy with an answer substitution, boots q6, q7; boot h1 without it |
| Integer sysctl widths, errors and lengths (§10.10.1) | 3 | our probe `sysctlsize` in the reference device |
| `messageType` 19 and 20 requests and replies, counts and labels in a boot (§9 Q16, §10.10.2) | 3 | `mslog` in our probes `shtex2`, `shtex3` and in backboardd and wakeboardd during boot m1 |
| Surface values, creation properties, allocation size, heap alignment 16 384 (§10.10.2) | 3 | our probes `shtex2`, `shtex4` |
| What a handle needs (§10.10.2) | 3 | our probe `shtex3`, seven cases, each in its own process |
| How handles travel (§10.10.2) | 3, 4 | `mslog` on the `com.apple.wakeboard*` connections in backboardd and wakeboardd (boot m2: message names, signatures, keys); recorder look-ups in backboardd (boot h1: XPC and IOSurface reads with caller chains named by `dladdr`) |
| SurfBoard's simulated presence; DisplayReveal's wake assertion; the host-side power service (§10.10.3) | 3 | `log show` of SurfBoard, wakeboardd and backboardd (boots q2, h1); `launchctl print user/501` in the device; `mslog` boot m3 |
| R3: abort cleared by the sysctl widths; boot progress, presence, Run, black frames (§10.11.1, §10.11.2) | 3 | Ycode boots s1–s15 on the Thor (guest `log stream`, Ycode's host log, `--screenshot`, `YCODE_METAL_STATS`, `YCODE_METAL_TRACE`, `YCODE_METAL_SHARED_CONTENT`) |
| sysctl width rules (§10.11.1) | 1, 3 | xnu `bsd/kern/kern_sysctl.c` (`sysctl_io_number`, `sysctl_old_user`, `sysctl` copying out `oldlen`); the reference table of §10.10.1; unit tests `SysctlTests.naturalWidths`, `pagesizeByNumberAndByName` |
| `messageType` 19/20 implementation (§10.11.3) | — | Ycode design from §10.10.2; unit tests `CoreTests.sharedTextureGetsAHostSurface`, `sharedTextureHandleOpensTheSameImage`, `sharedTextureHandleOfAGuestSurface`, `IOSurfaceServiceTests.sharedTextureSurface` |
| Task identity tokens (§10.11.3) | 1, 3 | xnu `osfmk/mach/task.defs` (routine and flavors); Ycode's fault reports (CoreRE caller) and host log of unimplemented library functions |
| Range binding records, op 131 (§10.11.3) | 3 | first bodies logged by Ycode's Metal host (wakeboardd 114: 16 bytes; backboardd 131: 52 bytes); unit test `CommandDecoderTests.rangeBindingsAndViewportArrays` |
| `calculate_clamped_lod` operand form (§10.11.3) | 1, 3 | Metal Shading Language specification (texture member functions); operand types reported by ycode-airc for the guest's functions |
| Power-management server (§10.11.4) | 1, 3 | IOKitUser `pwr_mgt.subproj/powermanagement.defs` (routines and order) and the IOPMLib client's behaviour without a server; SurfBoard and wakeboardd logs of boots s3, s5; unit test `PowerManagementHostServiceTests` |
| Registration queue overflow (§10.11.4) | 3 | Ycode's host log of boot s4 |
| Records 24, 25, 132, 212, 213 and their fields (§9 Q18, §10.12.1) | 3 | our probes `encprobe`, `encprobe2` (separator records) under `mslog` with port names, in `ycode-test-visionos-obs4` |
| The same calls make those records in backboardd's command buffers; counts; fence traffic (§10.12.1) | 3 | boot m2 (copy of Ycode's `mtlrec.dylib` recording render-encoder calls, with `mslog`, in backboardd); boot m1 (`mslog`) |
| 17/18 per layer, the null port, the empty reply, nil from `newSharedEventWithHandle:` (§9 Q19, §10.12.2) | 3 | `mslog` in backboardd and wakeboardd, boot m1; the recorder copy in backboardd, boot m2; VISIONOS-OBS3's capture (same pattern) |
| Layer events: GPU signals and waits in backboardd, CPU reads in wakeboardd, value and frame slot (§10.12.2) | 3 | `mslog` segment dumps and messages of boot m1, decoded with our scripts |
| Swapped surfaces and layer textures over time, log lines, reference frame (§9 Q20, §10.12.3) | 3 | our `layerpeek` library in wakeboardd and backboardd, boots f1 and f2 (pulsing); `simctl io screenshot`; `log show` |
| How backboardd writes the layers; frame structure and cadence (§10.12.4) | 3 | `mslog` segment dumps of boot m1 (render pass descriptors, texture descriptors of the refs, event records) |
| What Ycode must change (§10.12.5) | — | derived from the above |
| R4b decoder, fence handling, null-port 18, diagnostics (§10.14.1) | — | Ycode design from §10.12.1–§10.12.2 and `metal-sim-protocol.md` §8; unit tests `CommandDecoderTests.fenceVisibilityAndDeferredStoreRecords`, `computeFencesAndRangeBindings`, `CoreTests.sharedEventHandlesNameOneEventAcrossProcesses`; summaries of boots r1–r3 without unknown records |
| Resolve and colour-attachment writes through a message-20 view land in the shared image; layer-event alias semantics (§10.14.2) | 3 | unit tests `VulkanBackendTests.sharedLayerViewTakesResolveAndAttachmentWrites`, `layerEventAliasCarriesGPUSignals` on the Thor's GPU |
| Layer contents and event values in boots; curtain, logo, zero after "Did Reveal" (§10.14.2) | 3 | Ycode boots r1–r3, x1 on the Thor: `YCODE_METAL_STATS` with `YCODE_METAL_SHARED_CONTENT`, guest `log stream` (backboardd DisplayReveal lines) |
| The room's asset: MA query result, catalog download failure, `state=unavailable`, configurationError, the directory enumeration (§10.14.3, §9 Q21) | 3 | guest `log stream` of RealityEnvironment and mobileassetd in boots r1–r3; `--trace-name RealityEnvironment` (boot r3); the device's `data/private/var/MobileAsset/AssetsV2` listing |
| GPU hang location in x1 (§10.14.4) | 3 | Ycode's Vulkan hang report (checkpoints) in boot x1 |
| The reference's catalog block, chosen entries, versions and paths; mobileassetd's answers before and after the catalog download (§9 Q21 a, b; §10.15.1) | 3 | `log show` of RealityEnvironment and mobileassetd in first boots b1–b4 of `ycode-test-visionos-obs5`; our recorder `fsrec` in mobileassetd (b2) |
| The downloaded catalog lists no room (§10.15.1) | 3 | the device's catalog file read for key names and `EnvironmentKey` values only |
| The room without the guest's network; download error 60 and retry (§9 Q21 c) | 3 | boot b3 (`fsrec` refusing guest connects), `log show`, screenshots |
| Files under `AssetsV2` after a boot; which process reads which room file and how (§9 Q21 d, §10.15.1) | 3 | `find` of `DEV/data` after b1–b4; `fsrec` in RealityEnvironment and backboardd (b2–b4) |
| No asset variable, host folder or mount; network hosts (§10.15.1) | 3 | `ps eww` of guest processes; `mount`; `lsof -i`; mobileassetd log lines |
| The listing sequence, request sets and returned records (§10.15.2) | 1, 3 | `fsrec` records decoded with our script (b2, b4); bit names from xnu `sys/attr.h` and getattrlistbulk(2) |
| When `ATTR_CMN_ERROR` is packed (§10.15.2) | 3 | our probe `bulkprobe` on the Mac and in the guest |
| Ycode's record form makes the reference fail as Ycode does (§10.15.2) | 3 | boot b5 (`fsrec` rewriting the records of the rooms folder) |
| What Ycode must do (§10.15.3) | — | derived from the above |
| R5: the fix, the room's load sequence, the abort and audio errors, other listings (§10.16) | 1, 3 | xnu `vfs_attrlist.c`; Ycode boots `v1`–`v3`, `i0`–`i2` on the Thor: guest `log stream`, host log, `YCODE_DEBUG_BULK_LISTINGS`, `YCODE_METAL_SHARED_CONTENT`, screenshots |
| R4a: when and where backboardd's GPU hang happens; checkpoints; Xid 109 without MMU faults (§10.13.1) | 3 | Ycode boots h1–c4 on the Thor: Ycode's Vulkan hang reports (checkpoints, per-draw checks), the host's kernel log (`journalctl -k`); R3's runs s1–s16 |
| R4a bisection: which draws, stages and loads cause the hang (§10.13.1) | 3 | Ycode boots with `YCODE_GPU_SKIP_SHADERS`, `YCODE_GPU_DROP_FRAGMENT` and ycode-airc's `AIRC_EXP` switches (table of §10.13.1); no shader logic read |
| Guest functions' interfaces: cmpxchg operand types, imageblock members, inputs and outputs, used stage-in attributes, guarded-load counts (§10.13.1, §10.13.3) | 3, 4 | ycode-airc `list`, `decls` and reflection of the functions dumped in boot h6 (kept on the Thor) |
| Null guard, base-instance check, vertex-input rule, the three pipelines' translation (§10.13.1, §10.13.3) | — | Ycode design; tests `Translator/tests/ir/interface-forms.sh`, `CompareExchangeGPUTests`, `NullPointerGPUTests`, `VulkanBackendTests.implausibleBaseInstanceIsSkipped`; boots a1–a4, b1–b4 |
| Layer 1 content after the home-view reveal (§10.13.1) | 3 | `YCODE_METAL_SHARED_CONTENT` in boots z5, b4, c4 |
| iOS 27.1 check (§10.13.4) | 3 | Ycode boots ios1, ios2 (home watch, `ylaunch`) |
| Q22 (a)–(d), the service's protocol, the minimal service, iOS (§9 Q22, §10.17, `audio-host.md`) | 1, 3 | our recorder `audrec` and probe `audprobe` in the reference guests of `ycode-test-vos-audio-1` (first boots b1–b8, probe runs p1–p6) and `ycode-test-ios-audio-1` (boot i1, probe runs ip1–ip3); reply rewriting inside the guest (b3–b8, ip3); `log show`; CoreAudio codes and records from the macOS SDK headers |
| R6: where backboardd's compute hangs stop, what was ruled out, the bisection, the cause and the result (§10.18) | 3 | Ycode boots `r1`–`r6`, `x-psb`, `x-imgwrite`, `f1`–`f6` on the Thor: hang reports with running checkpoints and dispatch tables, captures, the host's kernel log; probes `areplay`, `pollute`, `imgoob`, `pinprobe` (our GLSL, ycode-airc's own SPIR-V, captured bytes); `CaptureReplayTests`; `VulkanBackendTests.kernelWritesAViewInAReusedSlot` on the code before and after |
| R6: room loads, PHASE aborts and layer contents after the fix (§10.18.3) | 3 | the same boots: guest `log stream`, `YCODE_METAL_SHARED_CONTENT`, screenshots |
| R6: iOS 27.1 and iPad checks (§10.18.4) | 3 | Ycode boots `i1`–`i3` (home watch, `ylaunch`, screenshots), `p1` |
| AUDIO-HOST: the service, work intervals, mlock, pthread mutex semantics, settings files (§10.19.1) | 1, 3 | `audio-host.md` §13, `work-intervals.md`; CoreAudio header codes; xnu `sys_work_interval.c`, `work_interval.c`, libsyscall `work_interval.c`; Ycode tests `AudioHostServiceTests`, `WorkIntervalTests`, `Stage3bTests.mlockChecks`, SimHostLibs pthread host tests |
| AUDIO-HOST: visionOS results — PHASE starts, IO runs, no PHASE abort, the EDEADLK abort after an engine stop and its fix, frames (§10.19.2) | 3 | Ycode boots `v1`–`v9` on the Thor: guest `log stream` (backboardd, SurfBoard, RealityEnvironment, …), host log (`audio:` lines, `YCODE_DEBUG_AUDIO`, `YCODE_DEBUG_WORK_INTERVALS`, `YCODE_DEBUG_SEMAPHORES`), `YCODE_AUDIO_CAPTURE`, screenshots |
| AUDIO-HOST: iOS results — clients, the lock sound captured, fatal conditions, boot time and the control-queue wait (§10.19.3) | 3 | Ycode boots `a1`–`a5`, timing pairs `t`, `t2`, `t3` (`timed.sh`) and boot profiles `p-audio`/`p-noaudio` (`YCODE_BOOT_PROFILE`) on the Thor: host log, guest log stream of errors and faults, captured WAV, Lock/Home presses through the display server |
| R7: the room's data flow, the compose pass and layer 2 correct, the room textures zero, the decoder's inputs non-zero and outputs zero, the targets unorm views of sRGB textures without storage views (§10.20.1) | 3 | Ycode boots `b0`, `p1`–`p5` on the Thor: pass probes (`YCODE_GPU_PROBE`) of `fsCompose` and `astc` command buffers, `YCODE_METAL_SHARED_CONTENT`; ycode-airc's reflection of `fsCompose` and `astc` (names, binding types and access only) |
| R7: the dumped dispatch decodes correctly offline (§10.20.1) | 3 | `ProbeReplayTests` on the Thor with `p4`'s dumps and the cached translation |
| R7: op 29's last word, the stale high half, the black parts and skipped draws (§10.20.2, §9 Q24) | 3 | op-29 bodies logged in boot `v4`; skipped-draw lines and screenshots of `b0`, `v2`; `metal-sim-protocol.md` §8.3 (the short forms carry 16-bit values) |
| R7: the changes and their tests; boots with them; the room in the frames; layer contents (§10.20.4, §10.20.5) | 1, 3 | Vulkan specification (`VK_IMAGE_CREATE_EXTENDED_USAGE_BIT`, `VkImageViewUsageCreateInfo`, format features); `VulkanBackendTests.kernelWritesUnormViewsOfAnSRGBTexture` (fails without the change), `CommandDecoderTests.shortIndexedDrawBaseInstanceIsSixteenBits`; Ycode boots `v1`–`v4`, `t1` (home watch, screenshots, `YCODE_METAL_SHARED_CONTENT`, guest `log stream`) |
| R7b: argument-encoder writes and the icons (§10.20.7) | 3 | Ycode boots `e3`, `v6`, `v7`, `v9`, `v10`, `f2` on the Thor (screenshots, `argument encoder` log lines); `CoreTests.argumentEncoderSetCallsWriteTheirMembers`; ycode-airc's argument-buffer model (`metal-shaders.md` §3.6) |
| R7b: visibility-result modes used by backboardd; occlusion queries (§10.20.8) | 1, 3 | Vulkan specification (occlusion queries, `vkCmdCopyQueryPoolResults`, queries inside dynamic rendering); Ycode boots `v5`–`v10` (`visibility:` lines, `YCODE_DEBUG_PASS_DRAWS`); `VulkanBackendTests.visibilityResultsCountSamples` |
| R7b: parts of the room left out by the guest in a 16-frame cycle; the 768 × 432 linearized-depth pass and its attachments (§10.20.9, §9 Q26) | 3 | Ycode boots `v2`, `v4`, `m2`, `e3`, `v5`–`v12`: screenshot thumbnails, `YCODE_DEBUG_PASS_DRAWS(_ALL, _BUFFERS)` logs, `v7`'s Metal trace (`YCODE_METAL_TRACE_SEGMENTS`), a pass probe of `fsLinearizedDepthAsColor` (`v12`); ycode-airc's reflection (render-target indices only) |
| R7b: merged-build boots and iOS 27.1 (§10.20.10) | 3 | Ycode boots `m1`, `m2`, `f1`, `f2`, iOS `i3`–`i6` on the Thor (home watch, `ylaunch`, host log) |

Level 5 was not used. Nothing was decrypted; no Apple resources (images,
rooms, models, metallibs) were copied into the repository. The test
devices `ycode-test-visionos-1` and `ycode-test-visionos-2` were deleted. For §10.6 (VISIONOS-OBS) only the test device
`ycode-test-visionos-obs` was used and then deleted; the recorder, probe,
raw logs and screenshots stay in `research/dirty/visionos-obs/`. For §10.8
(VISIONOS-OBS2) only `ycode-test-visionos-obs2` was used and then deleted;
Ghidra, the IPSW and the reference tools folder were not opened; the
recorder copy, probe, scripts and raw logs stay in
`research/dirty/visionos-obs2/`.
For §10.10 (VISIONOS-OBS3) only `ycode-test-visionos-obs3` was used and
then deleted. Ghidra, the IPSW and the reference tools folder were not
opened, and nothing was decrypted. Level 5 was used once: 36
instructions of the render manager's start, read from the image loaded
in the reference device and disassembled. This was done after the
black-box levels had failed (§10.10.1), and the result was then confirmed
at level 3 (boots q6, q7). The extract, the recorder copy, the probes,
the scripts and the raw logs stay in `research/dirty/visionos-obs3/`.
Only behavior and interop names are stated here.
For §10.12 (VISIONOS-OBS4) only `ycode-test-visionos-obs4` was used and
then deleted. The host-wide semaphore `wakeboardd.first-boot` was removed
before three of its boots so that they pulsed; wakeboardd makes it again
at each boot. Ghidra, the IPSW and the reference tools folder were not
opened, nothing was disassembled (level 5 not used) and nothing was
decrypted. The probes, recorder copies, scripts, raw logs and frames stay
in `research/dirty/visionos-obs4/`; no image was committed.
For §10.14 (VISIONOS-R4b) only Ycode's own simulator was booted, on the
Thor; no Apple simulator, Xcode, Ghidra, IPSW or reference tools folder
was used or opened, nothing under `research/` was read, and nothing was
disassembled.
For §10.15 (VISIONOS-OBS5) only `ycode-test-visionos-obs5` was used and
then deleted. No Mac-wide state was changed (the `wakeboardd.first-boot`
semaphore was left as it was; the guest's network was refused by our
library inside the guest, not by a setting). Ghidra, the IPSW and the
reference tools folder were not opened, nothing was disassembled (level 5
not used) and nothing was decrypted or downloaded by us. The recorder, the
probe, scripts, raw logs, listings and screenshots stay in
`research/dirty/visionos-obs5/`; no Apple file was copied into the
repository.
For §10.16 (VISIONOS-R5) only Ycode's own simulator was booted, on the
Thor; no Apple simulator, Xcode or reference tool was used, nothing under
`research/` was read, and nothing was disassembled.
For §10.17 (VISIONOS-OBS6) only `ycode-test-vos-audio-1` and
`ycode-test-ios-audio-1` were used and then deleted. No Mac-wide state
was changed (the audio services were made unreachable by our library
inside the guest, not by a setting). Ghidra, the IPSW and the reference
tools folder were not opened, nothing was disassembled or decrypted, and
levels 4 and 5 were not used. The recorder, probe, scripts and raw logs
stay in `research/dirty/visionos-obs6/`.
For §10.18 (VISIONOS-R6) only Ycode's own simulator was booted, on the
Thor; no Apple simulator, Xcode or reference tool was used, nothing under
`research/` was read, and nothing was disassembled.
For §10.20 (VISIONOS-R7 and R7b) only Ycode's own simulator was booted, on the
Thor; no Apple simulator, Xcode or reference tool was used, nothing under
`research/` was read, nothing was disassembled, and the guest's shader
logic was not read.
