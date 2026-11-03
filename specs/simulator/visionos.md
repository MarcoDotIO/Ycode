# Spec: the visionOS simulator (visionOS 27.0, Apple Vision Pro) — what differs from iOS, and what Ycode must add

Status: **draft, round 0** (agent VISIONOS-SPEC, 2026-10-26); round R1 results under Ycode in §10 (VISIONOS-R1/R1b, 2026-10-27); round R2a in §10.7 (VISIONOS-R2a, 2026-10-27); reference observations for R2b's questions in §10.10 (VISIONOS-OBS3, 2026-10-27); round R3 in §10.11 (VISIONOS-R3, 2026-10-27); reference observations for R3's questions Q18–Q20 in §10.12 (VISIONOS-OBS4, 2026-10-27); round R4b in §10.14 (VISIONOS-R4b, 2026-10-27; new Q21); reference observations for Q21 in §10.15 (VISIONOS-OBS5, 2026-10-27); round R5 in §10.16 (VISIONOS-R5, 2026-10-27; new Q22); round R4a (the GPU hang, the broken pipelines) in §10.13 (VISIONOS-R4a, 2026-10-27; new Q23, Q24); reference observations for Q22 in §10.17 (VISIONOS-OBS6, 2026-10-27); guest audio under Ycode in §10.19 (AUDIO-HOST, 2026-10-27); round R8 (the home view's launch, app compatibility, sRGB storage, snapshot slots) in §10.21 (VISIONOS-R8, 2026-10-29; new Q27); argument buffers by op 16's description and the visibility results behind the missing room parts in §10.22 (ARGBUF-IMPL, 2026-10-30); input formats, the ARKit pose, vhmdd's protocol (§9 Q1–Q3) in §5.5 and the reference's glass and metal in §10.23 (OBS-VISION-INPUT, 2026-10-31); the Digital Crown, immersion and recentering in §5.5.9 (OBS-VISION-CROWN, 2026-11-01); views and stereo in §5.6 (OBS-VISION-STEREO, 2026-11-01); rasterization rate maps and foveation in §5.6.7 (OBS-VISION-RRM, 2026-11-01); round R11 (the home view in every boot, Photos' free space) in §10.26 (VISIONOS-R11, 2026-11-01; new Q28). It describes
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
   rasterization-rate maps) (§4.5). Nothing in the guest uses rate maps and
   no host input enables them (§5.6.7).
3. **Input** reaches the guest through the same HID bundle path as on iOS
   (`SIMULATOR_HID_SYSTEM_MANAGER`, Indigo messages to
   `IndigoHIDRegistrationPort`), with visionOS-specific vendor services
   already published by the bundle: **PalomaPose** (head/camera pose),
   **SelectionStream** (gaze + pinch), **Manipulator**, plus a
   **DigitalDial** (Digital Crown). The Mac side (a DeviceHub plug-in)
   turns pointer, keyboard, trackpad and game controller into those
   messages and also talks to a guest daemon, **vhmdd**, for camera and
   simulated-room control (§5). The payloads, the guest events, the frame
   they use and vhmdd's protocol are in §5.5.
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

### 5.5 Input formats and delivery (agent OBS-VISION-INPUT, 2026-10-31)

Answers §9 Q1–Q3. Observed on the reference without Device Hub: our own
Indigo messages through SimulatorKit's legacy HID client, our own vhmdd
client, a recorder of the events the HID bundle dispatches inside
backboardd, and our probe app. Details and raw numbers: §10.23 and
`research/notes/obs-vision-input-2026-10-31.md`.

#### 5.5.1 One frame for camera, gaze and hands

- **Stage frame**: metres, right-handed, y up, −Z forward, origin at the
  default eye point. In an app's immersive space that point is ARKit world
  (0, 1.6, 0) (vhmdd: the app's "stage transform" is a translation by
  (0, 1.6, 0)).
- The camera pose, the gaze ray and both hand poses are all given in the
  stage frame. The guest does **not** apply the camera pose to the gaze ray
  or the hands: the host must transform a viewer-space ray by the current
  camera pose (origin = camera position, direction = camera rotation ×
  view-space direction) and place the hands relative to the camera.
- View projection (3840 × 2160): horizontal field of view 90°, focal length
  1920 px, square pixels, principal point at the centre. A viewer pixel
  (u, v) maps to the view-space direction ((u − 1920)/1920, −(v − 1080)/1920, −1).
- The camera pose is **absolute**: identity is the default eye looking along
  −Z; the same pose sent twice gives identical frames.

#### 5.5.2 Events the guest receives (what Ycode's HID bundle must dispatch)

All vendor-defined events below have usage page **0xFF00** and version
**13**. "Translation", "Orientation" (quaternion, orientation type 3),
"Rotation" and "Scroll" are the IOHIDFamily event types of those names;
children are attached with `IOHIDEventAppendEvent`. Flags are the event
flags as the event prints them (bit 0 = absolute value type).
An "Orientation (type 3)" child must be **made by the quaternion
constructor**; an Orientation event made any other way stays type 0 and
drops the quaternion, and the guest then ignores the rotation. The field
numbers, values and construction are in §5.5.10.

| Service (§5.3) | Host input | Event |
|---|---|---|
| 05 PalomaPose | camera pose | VendorDefined usage **0x72**, no data, flags 0x1; children in this order: Translation (relative, flags 0; x, y, z = camera position, m) and Orientation (relative, flags 0, type 3 from the quaternion constructor; w, x, y, z = camera rotation; §5.5.10) |
| 06 SelectionStream | gaze, pinch, hands | VendorDefined usage **0x6F**, no data, flags 0x2000003, phase **Changed**; children: left hand, right hand (omitted when the host marks the message selection-only), then gaze — below |
| — left / right hand | | VendorDefined usage **0x70**, data 3 bytes `{pinching 0/1, chirality (2 left, 1 right), allowDirect 0/1}`, flags `extra << 24 \| 3` (left) and `extra << 24 \| 1` (right) as observed (`extra` is a per-hand 16-bit host value whose meaning is unknown; send 0); children: Translation (relative; hand position, m, stage frame) and Orientation (relative, type 3, made as in §5.5.10) |
| — gaze | | VendorDefined usage **0x71**, no data, flags 0x3; children: Translation (absolute, flags 0x1; ray origin) and **Rotation** (absolute, flags 0x1; x, y, z = ray direction, need not be unit length) |
| 07 Manipulator | — | the reference dispatches the same 0x6F event from this service for a target-302 message; nothing in the guest reacted. Ycode need not send it. |
| 02 DigitalDial | Digital Crown | Scroll (relative, flags 0x10), y = the turn delta |
| 01 buttons, 03 keyboard | Home, keys | as on iOS (`hid-input.md` §5.4–5.5); Home toggles the home view (SurfBoard "reason: Crown") |

backboardd's hand provider reads the 0x6F event from service 06 only,
re-runs its hit test with the last ray every frame (hover persists without
new messages), shows the system hover highlight on the gazed element, and
turns pinches into contacts: source 2 (left) / 12 (right) for an indirect
pinch, 11 (right) for a direct touch (the hand inside an element with
`allowDirect` set, no pinch), 13 (right) for a direct pinch. The Rotation
fields are carried in 16.16 fixed point (0.05 arrives as 0.049988); the
other fields arrive as sent.

#### 5.5.3 ARKit's device pose comes from vhmdd, not from HID

`WorldTrackingProvider.queryDeviceAnchor` returns the app's stage transform
times **vhmdd's pose** (the matrix last given by the host's `set_pose`;
identity after boot). PalomaPose events move only the rendered view;
`set_pose` moves only the anchor. The Mac side therefore sends **both** on
every camera change (Device Hub's plug-in has both paths, level 4: a
camera HID message and vhmdd's `setPose:`), and the matrices must
agree: `set_pose` = the camera pose of §5.5.2 as a column-major float4x4 in
the stage frame. (§5.4's start orientation of 12.5° was Device Hub's
initial camera; without Device Hub vhmdd's pose stays identity.)

#### 5.5.4 The vhmdd host protocol

- Reachable **only from the host**: CoreSimulator's lookup of the guest
  name `com.apple.vhmdd`, an XPC endpoint from that send right, the
  connection marked sim-to-host. Guest clients of `com.apple.vhmdd` or
  `com.apple.vhmdd-sim` are accepted, but their requests are dropped (the
  client sees "Connection interrupted").
- XPC dictionaries; the command is the string under **`cmd`**. vhmdd adds
  `majorVersion` 1 and `minorVersion` 1 to what it sends; requests without
  them were accepted.

| `cmd` (host → vhmdd) | Other keys | Reply, then events (vhmdd → host, same connection) |
|---|---|---|
| `get_pose` | — | `{pose: data(64)}`: float4x4, column-major |
| `set_pose` | `pose`: data(64) | empty |
| `request_environments` | — | empty; event `{cmd: environments_changed, environments_data: string}`: JSON object keyed by room key (`KitchenDay`, `KitchenNight`, `LivingRoomDay`, `LivingRoomNight`, `MuseumDay`, `MuseumNight`), each `{displayName, thumbnailURL}` |
| `set_active_environment` | `environment_id`: room key | empty; `active_environment_changed {environment_id}` (sent twice), then 1–3 s later `synthetic_environment_did_load {environment_id, load_error}` (`""` on success). The room changes live and `activeSyntheticEnvironment` is written to the preference file |
| exercised in §5.5.9 (OBS-VISION-CROWN), except `simulate_facetime_session` | | `set_controls_enabled`/`get_controls_enabled` (`controls_enabled`), `observe_hand_mode`/`set_hand_mode` (`hand_mode`; event `hand_mode_changed`), `change_immersion_level` (`immersion_level`, `absolute`), `get_immersion_level`, `set_cursor_visible` (`visible`), `recenter_open_apps`, `simulate_facetime_session` (`standard_participant_count`, `spatial_participant_count`); events `keyboard_editing_active_changed` (`keyboard_editing_active`), `immersion_level_did_change`, `immersion_style_did_change` (`immersion_style`) |

**Room before boot**: writing `activeSyntheticEnvironment` (e.g.
`MuseumDay`) into `DEV/data/Library/Preferences/com.apple.RealityEnvironment.plist`
while the device is shut down selects that room at the next boot (V-13).

#### 5.5.5 What an app receives (end-to-end checks)

| Host input (§5.5.2) | SwiftUI / UIKit / RealityKit result |
|---|---|
| gaze on the element, right pinch ~100 ms, release | `Button` action; `onTapGesture`; `SpatialTapGesture` with the point in the view (points) and `location3D` z ≈ 0; UIKit `touchesBegan`/`Ended` with touch type 0 (direct), tap count 1 |
| pinch, hand moved, release | `DragGesture` changes and end (window: 0.1 m of hand → about 70 pt at 2 m; entity in a volume: 0.1 m → 136 pt = 1360 pt/m); `predictedEndTranslation` set |
| both hands pinched, separation s₀ → s₁ | `MagnifyGesture` s₁/s₀ |
| both hands pinched, turned by θ counter-clockwise as the user sees it | `RotateGesture` −θ; one hand turning gives nothing |
| gaze only | the system hover highlight is drawn; no `onContinuousHover`, no UIKit hover callback |
| keys after focusing a text field | `onKeyPress` and text, as on iOS |
| gaze + pinch on an entity with `InputTargetComponent` and collision | `SpatialTapGesture().targetedToAnyEntity()` with the hit point (immersive sphere of radius 0.2 at (0, 1.5, −2): (0, 1.51, −1.8)) |
| hand moved into an entity with `allowDirect`, no pinch | entity tap (direct touch) |

#### 5.5.6 Indigo wire format (reference only; Ycode does not implement Indigo, `hid-input.md` §7)

192-byte message, offsets from its start: 0x18 inner size 0xA0, 0x1C type
byte 1, record from 0x20: kind (32 bits, 1), host `mach_absolute_time`
(64 bits, at 0x24), a zero word, **target** (32 bits, 0x30): 300 → service
05, 301 → 06, 302 → 07; target 0 makes backboardd raise an exception and
exit. Float3 values occupy 16-byte slots (x, y, z, 0).

| Message | Fields (offset: content) |
|---|---|
| pose | 0x54 translation; 0x64 quaternion x, y, z, w |
| collection | 0x34 3; 0x38 left pinch, 0x39 2, 0x3A left direct (bytes); 0x3B 3; 0x3F right pinch, 0x40 1, 0x41 right direct; 0x42 selection-only byte; 0x43 left extra, 0x45 right extra (16 bits); 0x47 ray origin; 0x57 ray direction; 0x67 left translation; 0x77 left quaternion; 0x87 right translation; 0x97 right quaternion |
| digital dial | record kind 6, delta as a double at 0x3C, target 200 at 0x4C |

The builders that write them are exported by Xcode's visionOS DeviceKit
plug-in (`IndigoHIDMessageForPalomaPose`, `…Selection` = a collection with
the selection-only byte set and identity hands, `…Collection`) and by
SimulatorKit (`IndigoHIDMessageForDigitalDialEvent`).

#### 5.5.7 What Ycode must do

1. **HID bundle (V-10)**: publish DigitalDial, PalomaPose, SelectionStream
   and Manipulator with §5.3's usages; dispatch the §5.5.2 events with the
   runtime's IOKit constructors (vendor-defined, translation, quaternion
   orientation, rotation, scroll; `IOHIDEventAppendEvent`,
   `IOHIDEventSetEventFlags`, `IOHIDEventSetPhase`), from service 05 for the
   pose and service 06 for gaze and hands. Guest timestamps as in
   `hid-input.md` §5.1.
2. **Transport (V-11)**: add kinds to `hid-input.md` §7.3 for camera pose
   (translation, quaternion), selection (ray origin and direction, a
   hands-present flag, per hand: pinch, allowDirect, translation,
   quaternion) and dial delta; all values in the stage frame of §5.5.1.
3. **ARKit pose**: Ycode's guest needs a vhmdd that answers `get_pose`/
   `set_pose` (the runtime's own vhmdd does, if Ycode's host can open the
   sim-to-host XPC connection of §5.5.4), and the host sends `set_pose`
   with every camera pose. Without it `DeviceAnchor` stays at (0, 1.6, 0).
4. **Viewer (V-12)**: keep the camera pose; map the pointer to a gaze ray
   with §5.5.1's projection and transform it by the camera pose; click =
   right-hand pinch with the hands at a fixed offset below the camera
   (e.g. (±0.15, −0.35, −0.4) in camera space, transformed); drag = the
   right hand moved with the pointer while pinched; two-hand gestures move
   both hands; Home = button source 0; send the pose and the selection about
   once per frame while they change. Never send target 0 or an unknown
   service.
5. **Rooms (V-13)**: before boot, write the preference; live, use
   `set_active_environment` and wait for `synthetic_environment_did_load`.

#### 5.5.8 Ycode implementation (round R9, agent VISIONOS-R9, 2026-10-31)

Results and runs: §10.25. Code: `SpatialInput.swift` (YcodeDisplayStream:
the stage-frame math and `SpatialInteraction`, shared by every viewer and
by `ycode-simd`), `HIDHostService.swift` (kinds 10, 11), `simhid.c` (the
four services and the events), `VisionHMDClient.swift` (the host end of
vhmdd), `VisionInput.swift` (ycode-simd: delivery, `vision …` commands,
rooms), `DeviceView+Spatial.swift` (macOS viewer and IDE canvas),
`RemoteDeviceSession.swift` (Linux viewer).

1. **HID bundle (V-10).** On a visionOS device the bundle publishes
   DigitalDial, Pose, SelectionStream and Manipulator with §5.3's usage
   pairs and dispatches §5.5.2's events (`hid-input.md` §17). Only those
   services are used; a message for a service the device lacks is dropped.
2. **Transport (V-11).** Display stream: pose 0x8A, selection 0x8B, dial
   0x8C, negotiated by the hello's `spatial` (`display-stream.md` §17).
   HID transport: kinds 10 and 11, the crown's kind 8
   (`hid-input.md` §17). Values are in the stage frame of §5.5.1.
3. **ARKit pose.** `ycode-simd` opens the host connection to the guest's
   `com.apple.vhmdd` itself: the name's send right from launchd_sim's
   control channel (702), the XPC hand-shake of `iosurface-remote.md` §2.2
   (a receive right for the connection, a send right to an event port of
   ours), and requests in the sim-to-host encoding (`!CPX`). vhmdd accepts
   it as a host connection: `get_pose`, `set_pose`, `request_environments`
   and `set_active_environment` are answered and the events arrive on the
   event port. Every camera pose goes to the HID bundle **and** to
   `set_pose` with the same matrix (§5.5.3); `set_pose` is latest-wins on
   its own thread, so a camera drag never waits for the guest. The
   connection is opened on first use and again after a failure.
4. **Ycode's choices for the viewers (V-12).** Hands rest at camera-space
   (±0.15, −0.35, −0.4) (§5.5.7's example), with the camera's rotation.
   The hand moves 1/700 m per point of pointer motion (0.1 m ≈ 70 points,
   the reference's window drag at 2 m, §5.5.5). The gaze stays at the
   press point while a pinch is held. Selections are coalesced to one per
   16 ms while the pinch state is unchanged; pinch changes, poses and
   dials are never dropped. The camera has no roll: yaw about +Y (positive
   turns left), pitch ±89°. Mapping (macOS viewer, IDE device canvas and
   live preview tiles, Linux viewer):

   | Input | Effect |
   |---|---|
   | pointer moves | the gaze (selection-only) |
   | click, drag, release | right-hand pinch at the gaze, the hand follows the pointer, release |
   | Shift-drag | the pinched hand forward (pointer up) / back |
   | Option-drag (Alt on Linux) | both hands pinch about the press point; spreading = magnify, turning = rotate (counter-clockwise as seen = the right hand up) |
   | Control-drag | mouse-look (0.2° per point) |
   | scroll / two-finger swipe | camera left/right, up/down (macOS 0.004 m per point, Linux 0.04 m per line) |
   | trackpad pinch (macOS) | camera forward/back (1 m per unit of magnification) |
   | Option-scroll (Alt) | the Digital Crown (the watch's scroll factor) |
   | Option + W/S, A/D, E/Q, arrows (Alt on Linux) | camera forward/back, left/right, up/down, 0.05 m a press |
   | Option + R, Controls ▸ Reset Camera | the default eye (identity) |
   | other keys | the keyboard, as on iOS (text fields) |
   | Home (frame button, ⇧⌘H) | button home (0x0C/0x40) |

   A camera move sends the pose, then the gaze again (it is in the stage
   frame and moves with the camera). The keys go to the device unless
   Option is held, so text fields need no capture mode (the reference's
   plain W/A/S/D needs Capture Keyboard to type, §5.1; Ycode decision).
5. **Scripted driver.** The control socket (and `ycode-simd --device DEV
   --vision …`, `ycode-sim --vision …`) takes `vision state | pose x y z
   [yaw [pitch]] | move f r [u] | turn yaw [pitch] | reset | gaze x y | tap
   x y [hold-ms] | pinch x y | drag x y [steps [ms]] [depth] | release |
   magnify x y factor [steps [ms]] | rotate x y degrees [steps [ms]] | dial
   delta [count [ms]] | home | type text | get-pose | rooms | room key`
   (points of the 1920 × 1080 display, metres, degrees). It runs the same
   `SpatialInteraction`; a pose from a viewer becomes the camera it goes
   on from.
6. **Rooms (V-13).** Before the boot: `ycode-simd --room <key>` (also
   `ycode-sim --room`) writes `activeSyntheticEnvironment` into
   `DEV/data/Library/Preferences/com.apple.RealityEnvironment.plist`
   (other keys kept); on a stopped device `--vision room <key>` does the
   same. Live: `vision room <key>` sends `set_active_environment` and waits
   up to 15 s for `synthetic_environment_did_load`. A warm start that
   restores a snapshot switches live once vhmdd answers (the saved run had
   read the preference). `ycode-sim --room` is not part of the snapshot's
   fingerprint. Viewers: Device ▸ Room (the six rooms) in the macOS viewer
   and the IDE's device menus.
7. **Previews.** The live preview canvas uses the device stream, so a
   visionOS preview tile forwards the same gaze and pinch as the viewer
   (the mouse is the gaze; click, drag and Option-drag as above); camera
   keys and scroll are not offered on tiles.

#### 5.5.9 The Digital Crown, immersion and recentering (agent OBS-VISION-CROWN, 2026-11-01)

Answers why the crown does nothing under R9 (§10.25.4 item 3). Observed on
the reference with our own vhmdd client, our own Indigo button and dial
messages, the HID recorder and our probe app `CrownProbe` (a window plus
progressive, ranged progressive (0.2…0.8, initial 0.5), full and mixed
immersive spaces; it logs `onImmersionChange`, `onWorldRecenter`, scene
phases and the ARKit anchor). Run on **visionOS 27.2 (24N120)**: this
day's CoreSimulator refused to create any 27.0 device ("runtime path not
found"; two 27.0 builds share one identifier); vhmdd's string list is
identical in 27.0 (24M362) and 27.2. Details:
`research/notes/obs-vision-crown-2026-11-01.md`.

**On a device (level 1).** Turn = immersion (an Environment or an app's
progressive space) or volume; press = Home View; press and hold =
recenter; double press = view of the surroundings; triple press = the
Accessibility Shortcut; crown + top button = screenshot, held = Force
Quit. SwiftUI reports immersion as `ImmersionChangeContext.amount`
(`onImmersionChange`) and recentering as `onWorldRecenter` (`began`,
`ended`). Device Hub documents no crown control for visionOS (Home,
Control Center, volume through Device > Sound).

**Turning: immersion is a vhmdd command, not a HID event.** DigitalDial
scroll events (§5.5.2) reach the guest and change nothing, with any space
open, before or after `set_controls_enabled`. Immersion changes only
through vhmdd (§5.5.4):

| `cmd` (host → vhmdd) | Keys | Reply, then events |
|---|---|---|
| `change_immersion_level` | `immersion_level` double, `absolute` bool | empty; then ~28 `immersion_level_did_change {immersion_level}` events, one per ~11 ms over ~0.30 s, easing (slow–fast–slow) from the old to the new level |
| `get_immersion_level` | — | `{immersion_level: double}` |

Two quantities:

- the **amount** a ∈ [0, 1]: what the app's `onImmersionChange` reports
  and what an absolute request carries;
- the **level** L that vhmdd reports (replies and events): **L = a²**.

Rules (level 3):

1. Absolute: a = clamp(value, the open space's range). The progressive
   style without a range opens at a = 0.5477 (L 0.30) and never goes below
   it; a ranged style opens at its initial amount and is clamped to its
   range. A request that clamps to the current amount sends no events. The
   app's amount follows the same 0.3 s ease (25–28 callbacks) and ends
   exactly at a.
2. Relative (`absolute` false): a = clamp(**L** + delta) — the delta is
   added to the squared level, not to the amount (0.25 + 0.1 → a 0.35, L
   0.1225; in a 0.2…0.8 space, +0.1 steps from L 0.04 stay at 0.2 for
   ever). Do not use it for a crown.
3. With no immersive space the level still moves (the system's level); at
   1.0 the home view's glass turns dark, the room stays.
4. Full space: opens at a = 1; lowering a fades the space's content to
   black (a = 0: black scene, dark-grey window), the room does not return.
   Mixed space: the app reports nothing; the level moves without a visible
   change.
5. Events go only to host connections that have sent vhmdd at least one
   message. Besides the level events: `immersion_style_did_change
   {immersion_style: int}` = **2** when a progressive space opens, **−1**
   when it closes (mixed and full sent none); a full space unloads the
   room (`active_environment_changed {environment_id: ""}`) and reloads it
   on exit (`active_environment_changed`, `environments_changed`,
   `synthetic_environment_did_load`). When the app exits, the level goes
   back to the system's.

Device Hub's plug-in names increase/decrease and set-to-0/25/50/75/100 %
immersion actions, an immersion controller fed by the two events, and also
logs sending dial events of ±1 (level 4); which action uses which path was
not observed (no GUI). Only the vhmdd path changes anything.

**Presses: the Home button, timed by the guest.** The crown is button
source 0 (0x0C/0x40, §5.5.2). SurfBoard classifies the raw down/up timing
itself (level 3):

| Host sends | SurfBoard gesture | Result |
|---|---|---|
| down, up after ≤ 400 ms | tap | toggles the home view ("reason: Crown"); with a progressive space open it **closes the space** (the window stays, home view not shown) |
| two taps, 80 ms down, 150 ms apart | double tap | logged, no visible change (no surroundings view in the simulator) |
| three taps, 70 ms down, 120 ms apart | double tap, then tap | no triple-press gesture |
| down, held ≥ 500 ms | long press, recognised **~0.49 s after the down while still held** | **recenter** (below); the release is logged and ignored |
| source 1 (0x0C/0x30) tap | top-button tap | Capture (refused in the simulator) |
| sources 1 and 0 down together, up after 150 ms | both tapped | screenshot ("Taking screenshot…") |
| sources 1 and 0 held | both long-pressed at ~1.5 s | the Force Quit Applications panel |

**Recentering.** vhmdd's `recenter_open_apps` is a no-op in this runtime
(it logs that recentering moved elsewhere and sends no reply; the client
gets "Connection interrupted" at once and the connection stays usable).
The working path is the crown hold: SurfBoard plays its recenter sound and
asks backboardd's placement to recenter; windows, the home view and the
immersive content fade and reappear in front of the **rendered camera**
(the PalomaPose pose — with the render camera and vhmdd's pose made to
disagree, placement followed the render camera); the app gets
`onWorldRecenter` `began` then `ended` (window and space); and vhmdd sets
the app's stage transform to T(0, 1.6, 0) × pose⁻¹, so
`queryDeviceAnchor` reads (0, 1.6, 0) looking along −Z again (pose =
(0.5, 0, 0) turned 70° left gave a −70° rotation and translation
(−0.171, 1.6, −0.470)). The stage transform outlives the app.

**Other vhmdd commands (level 3).** `set_controls_enabled
{controls_enabled}` / `get_controls_enabled` (false after boot): a stored
flag with no visible effect. `observe_hand_mode`, `set_hand_mode
{hand_mode: string}`: any string is echoed as `hand_mode_changed
{hand_mode}`, nothing visible; a non-string gets no reply.
`set_cursor_visible {visible: bool}`: draws or removes a grey ring
(~22 px at 3840 × 2160) at the gaze point (the view centre without gaze).
Commands vhmdd does not answer produce an immediate "Connection
interrupted" reply; send them without waiting.

**What Ycode must do.**

1. **Crown turn → vhmdd, not only the dial.** Ycode's host vhmdd client
   (§5.5.8 item 3) adds `change_immersion_level` and `get_immersion_level`.
   The viewer keeps an amount a: each crown step (Option-scroll and every
   other crown input of §5.5.8 item 4) changes a by a fixed step (Ycode
   choice: 0.05 per wheel notch, clockwise/up = more), clamps it to [0, 1]
   and sends **absolute** a, latest-wins like `set_pose`. Ycode may keep
   sending the dial scroll event too; it has no effect in the reference.
2. **Read back.** Send one message (e.g. `get_immersion_level`) when the
   connection opens so that vhmdd sends events; on every
   `immersion_level_did_change` set a = √level, so the viewer follows
   clamping by the app's range, the space's own open and close, and other
   sources. Expose the amount (√level) and the style (2 progressive, −1
   none) as viewer state and in the scripted driver (e.g. `vision
   immersion [amount]`), and offer set-to-0/25/50/75/100 % as the
   reference plug-in does.
3. **Crown press = button source 0 with real timing.** Send down and up as
   separate events with the hold the user makes: a click is a tap (Home,
   closes a progressive space); a hold ≥ 0.5 s is the recenter; two clicks
   within ~150 ms a double press. The viewer must not synthesise a fixed
   100 ms click for a held button. A "Recenter" control = source 0 held
   for 0.6–1.0 s.
4. **Top button.** On a visionOS device the buttons service must accept
   source 1 (0x0C/0x30). Screenshot = sources 1 and 0 pressed together;
   Force Quit = both held ≥ 1.5 s (offer it as a menu item).
5. **Recenter needs the camera.** Placement uses the rendered camera, and
   the ARKit stage uses the pose; Ycode already sends both with the same
   matrix (§5.5.3), which keeps them consistent. Do not use
   `recenter_open_apps`.
6. Optional: `set_cursor_visible` as a viewer toggle (the plug-in keeps a
   user-requested cursor visibility, level 4; which menu item drives it
   was not observed). `set_hand_mode` and `set_controls_enabled` have
   no observable effect; Ycode need not send them.

#### 5.5.10 The pose's rotation: the Orientation child at the field level (agent OBS-VISION-POSE, 2026-11-01)

Question from the Quest viewer (XR-VIEWER): under Ycode the camera follows
the pose's translation but not its rotation at the plain home view. Answer
(run on visionOS 27.2 (24N120), the 27.0 runtime could not create a device;
details in `research/notes/obs-vision-pose-2026-11-01.md`):

1. **The reference turns the view at the plain home view.** A PalomaPose
   message (target 300) with yaw +30° (quaternion w 0.965926, y 0.258819)
   turned the view left: the room and the home view moved right in the
   frame; −30° turned it right; pitch +20° (w 0.984808, x 0.173648) looked
   up; identity brought the default view back. The home view stays where it
   is in the room (it does not follow the head). The same holds with an app
   window open and inside mixed, progressive and full immersive spaces
   (level 3). Cause (a) of the question is ruled out.
2. **Nothing else is needed.** vhmdd was never sent `set_pose` in these
   runs and `get_pose` still answered identity at the end; the view turned
   from the HID event alone (level 3). `set_pose` (§5.5.3) moves only
   ARKit's device anchor; it is still sent for apps, but it does not turn
   the view.
3. **The encoding the reference dispatches for a rotated pose** (level 3,
   our recorder in backboardd, each field read back by number). IOHIDFamily
   field numbers are `(event type << 16) | index`.

   | Event | Type | Event flags | Fields |
   |---|---|---|---|
   | parent | VendorDefined (1) | 0x1 (absolute) | page 0xFF00 (`1<<16\|0`), usage 0x72 (`1<<16\|1`), version 13 (`1<<16\|2`), data length 0 |
   | child 1 | Translation (4) | 0x0 (relative) | x, y, z = `4<<16\|0`, `\|1`, `\|2` (metres) |
   | child 2 | Orientation (10) | 0x0 (relative) | orientation type **3** in `10<<16\|3`; **w** `10<<16\|8`, **x** `\|9`, **y** `\|10`, **z** `\|11` (a unit quaternion, the camera's rotation in the stage frame; positive y = turn left, positive x = look up) |

   No other Orientation field is non-zero. The quaternion arrives in 16.16
   fixed point (0.965926 → 0.965912, 0.258819 → 0.258804). Exactly two
   children, Translation first.
4. **Why Ycode's event loses the rotation** (cause (b), level 3). Ycode's
   field numbers and order were already right; its *construction* is not.
   An Orientation event made with the generic constructor
   (`IOHIDEventCreate` with type 10) has orientation type 0 (polar), and
   the type cannot be changed afterwards: setting `10<<16|3` (as an integer
   or a float) leaves it 0, and the float setter then ignores fields 8–11
   (they read back 0, and the event prints "Orientation type: 0"). Only
   `IOHIDEventCreateQuaternionOrientationEvent(allocator, timestamp, w, x,
   y, z, options)` makes a type-3 event (argument order checked by reading
   the fields back; the runtime's IOKit also exports
   `IOHIDEventCreateOrientationEvent`, `IOHIDEventCreatePolarOrientationEvent`
   and `IOHIDEventCreateDeviceOrientationEventWithUsage`, level 4). Once
   made that way, the float setter does change fields 8–11. Replaying the
   reference's own pose events inside its backboardd with the Orientation
   child rebuilt Ycode's way (translation kept) gave, at the home view,
   frames byte-identical to identity for yaw +30° and pitch +20°; inside a
   mixed immersive space the window and the space's cube stayed centred,
   and a matching `set_pose` did not turn the view either: exactly
   XR-VIEWER's symptom. (R9's turned view in a mixed space, §10.25.1, was
   not reproduced this way; it is not explained by the HID event.) The hands' Orientation children
   (event 0x70) are built the same way in Ycode and lose their rotation
   too.

**What Ycode must do.** In the HID bundle, make every Orientation child
(the pose's and both hands') with the runtime's
`IOHIDEventCreateQuaternionOrientationEvent` (looked up by name like the
other constructors), arguments w, x, y, z of a normalised quaternion,
options 0, then set the event flags to 0; append it after the Translation
child. Do not build it with the generic constructor plus setters. If the
constructor is missing, log it and dispatch the pose without rotation
(that is what the guest would see anyway). No change to vhmdd's
`set_pose`, the transport, or the host's w, x, y, z order is needed. A
check: the bundle's log (or a read-back of field `10<<16|3` before
dispatch) must show orientation type 3, and a yaw pose at the plain home
view must change the frame.

#### 5.5.11 Ycode implementation: the pose's rotation and the headset viewer (agent XR-VIEWER, 2026-11-01)

- **Rotation.** The HID bundle makes the pose's and both hands'
  Orientation children with `IOHIDEventCreateQuaternionOrientationEvent`
  (looked up by name; w, x, y, z of the normalised quaternion, options 0,
  flags 0, after the Translation child; `SimHID/vision_orientation.h`, host
  test `SimHID/tests/orientation_test.c`, run by
  `SimGuestFrameworks/build.sh`). Without the constructor the event goes
  without its rotation and the bundle logs it once. Checked on the Thor at
  the plain home view: `vision pose 0 0 0 30 0` turns the view left and
  `vision pose 0 0 0 0 20` looks up (the frames differ from identity;
  before the fix they were byte-identical).
- **The guest's camera is smoothed** (level 3, Ycode's simulator): after a
  new pose the picture first changes about 170 ms later and converges over
  about 250 ms more (`xr-viewer.md` §6). Whether the reference does the
  same is `xr-viewer.md` Q-XR5.
- **Headset viewing** (`xr-viewer.md`): the head pose drives the camera
  (the views message, `display-stream.md` §18); the eye gaze, the hands'
  joints and the controllers become the §5.5.2 selection; the crown is a
  controller's A/X with real timing and the thumbstick drives
  `change_immersion_level` (absolute amounts, `vision immersion <a>`,
  §5.5.9); recentring is the crown hold. Stereo follows §5.6.5 (the eyes'
  poses in turn, each picture tagged), adapted to the smoothing: mono while
  the head moves, the eyes in turn while it is still.

#### 5.5.12 Camera smoothing and pose timing (agent OBS-VISION-FOV, 2026-11-01)

Questions from the headset viewer (XR-VIEWER, `xr-viewer.md` Q-XR5): does
the reference also smooth its camera between PalomaPose events, can a host
shorten it, and what timestamp does the pose carry? Observed on **visionOS
27.2 (24N120)** (27.0 could not create a device) with our recorder in
backboardd (each pose event at dispatch) and wakeboardd (the time of every
presented surface and three sampled rows of it), and our sender (`vhid`,
§5.5.6) printing its send times. The camera's yaw in each presented frame
is measured from the frame's middle row (view-angle resampling, 90°
horizontal, best match against a reference frame). All times are on the
host's mach clock, which the guest shares. Details:
`research/notes/obs-vision-fov-2026-11-01.md`.

1. **The reference smooths its camera too** (level 3). After an isolated
   pose (no pose for ≥ 1.5 s before) the picture moves by the same fraction
   of the step in every presented 60 Hz frame, for any step size (5°, 30°)
   and for translation (0.3 m) alike:

   | Presented frame (0 = first that changed) | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
   |---|---|---|---|---|---|---|---|---|---|
   | Fraction of the step | 0.274 | 0.548 | 0.822 | 0.871 | 0.919 | 0.968 | 0.977 | 0.985 | 0.994 |

   i.e. three-frame linear segments whose end points close 82.2 % of the
   remaining distance (the remainder shrinks by 0.178 every 50 ms).
   Measured from the host's send (27 isolated 30° steps): first changed
   frame 53–75 ms (mean 62), 50 % at 69–91 ms (79), 90 % at 119–141 ms
   (128), within 0.1° at 219–241 ms (229). The first changed frame is the
   pipeline (3–4 presented frames); the smoothing adds about 50 ms to 82 %
   and 100 ms to 97 %.
2. **The smoothing runs on time, not on presented frames** (level 3). With
   wakeboardd's `hmd.compositor.fps` set to 30, and with a test device type
   whose display runs at 30 Hz, each presented frame (33 ms apart) shows
   every second value of the 60 Hz sequence (0.548, 0.871, 0.968, 0.985,
   …); only the first change moves later (113 ms and 159 ms), because the
   pipeline's frames are longer.
3. **Continuous motion** (level 3): a 1 Hz ±15° yaw sine is shown as the
   command delayed by **98–100 ms** with gain 0.95–0.96, at 27 and at 76
   poses per second alike. A 30° ramp over 0.5 s trails by about 100 ms.
   The pose rate does not change the delay.
4. **It is not a linear filter of the poses** (level 3). Repeating an
   unchanged pose at 30 or 90 Hz after a step makes the step converge
   **slower** (90 % at 160–180 ms, within 0.1° at 300–390 ms, against
   about 130 and 230 ms for a single event). A pose replaced within ~16 ms
   by another has no effect of its own. A second pose 33–150 ms after the
   first changes the motion from the next three-frame segment on. An
   overshoot sent first (36.5° then 30° 50 ms later) reaches 30° two frames
   after the correction but then falls back to 24.7° and settles like a
   plain step (within 0.1° at 217 ms): pre-compensation gains nothing and
   shows a bounce.
5. **Timestamps** (level 3). The record's host time (offset 0x24 of the
   Indigo message, §5.5.6; written by the builder from
   `mach_absolute_time` immediately before the send) becomes the
   IOHIDEvent's timestamp unchanged; backboardd dispatches the event about
   3 ms after the send. The camera **ignores the timestamp's value**:
   constant offsets of ±200 ms and ±3 s, and times compressed or stretched
   by 10× from the first message (up to 30 s in the future), all gave the
   same trajectory to 0.01°. Only two consecutive events with the *same*
   timestamp misbehaved: the second did not take effect and the picture
   jumped about 420 ms later to an intermediate value, where it stayed.
   No field marks a pose as already predicted: parent flags 0 or 3 and
   child flags 1 (rewritten before dispatch) changed nothing.
6. **No host-side input turns it off** (level 3, one boot each): backboardd
   `SimulatedHeadset` YES; `enableHeadPoseLateLatching` NO (the trajectory
   is unchanged, the first change came 70 and 82 ms after the send in two
   boots, perhaps one frame later than normal); `useLegacyHeadPoseLateLatching`
   YES; wakeboardd `hmd.pov.time-warp.enabled` NO; the timestamps, flags
   and rates above. None of the ~1 640 preference keys backboardd reads
   names a head-pose smoothing, filter or prediction time (level 3, the
   OBS-VISION-STEREO read log). wakeboardd's layer record carries a layer
   pose of type "invalid" (identity) for backboardd's layers: the motion is
   rendered in backboardd, not re-projected by wakeboardd. Where the filter
   sits was not determined (level 4 names only: RealitySimulation asks for
   "a head pose for time" t at a compositor-predicted time; no level 5).
7. **Ycode compared** (`xr-viewer.md` §6: first change about 170 ms, settled
   about 250 ms later, at 23.5 pictures/s). The reference's first change is
   3–4 presented frames; at Ycode's 44 ms per picture that is 130–175 ms,
   so Ycode's extra delay is its frame time, and its convergence (about
   250 ms after the first change) matches the reference's time-based
   smoothing (about 170 ms after the first change to within 0.1°) seen
   through coarser frames. Ycode's smoothing is the guest's own, as in the
   reference.

**What Ycode must do.**
1. Keep the guest's smoothing: it is the reference's behaviour (parity) and
   no host input changes it. Do not try overshoot or timestamp tricks.
2. To cut motion-to-picture time, shorten the pipeline: it is 3–4 of the
   guest's presented frames, so the guest's frame rate is the lever
   (60 Hz: ~62 ms to the first change, ~100 ms delay in continuous motion;
   23.5 Hz: ~170 ms to the first change). The smoothing itself costs about
   40–50 ms of delay in continuous motion at any rate.
3. Send a pose only when it changed (beyond a small threshold) and stop
   when the head is still: repeating an unchanged pose slows the settle
   from about 230 ms to 300–390 ms. Any rate from 27 to 90 per second gives
   the same delay in motion.
4. Event timestamps must strictly increase (Ycode's bundle uses guest
   ticks: keep it so); their value is otherwise irrelevant. No event field
   or flag is needed or helps.
5. For the headset viewer's tags and reprojection: a picture in continuous
   motion shows the pose sent about 100 ms (60 Hz guest) earlier; after an
   isolated step it follows item 1's table from the first changed frame.
   Tagging with "the pose sent one pipeline plus ~40 ms ago", or a host
   model of item 1, is closer than the latest pose.

### 5.6 Views and stereo (agent OBS-VISION-STEREO, 2026-11-01)

Answers XR-VIEWER's questions (a Quest Pro as a stereo viewer): can the
reference render two views, and what decides it? Observed on **visionOS
27.2 (24N120)** (no 27.0 device could be created, as in §5.5.9) with our
probe app `StereoProbe` (a CompositorServices layer that logs what it is
given), our recorder `stereopeek` (layer textures, two-slice passes,
slice read-backs, `SFBSwapchainSwapAddSurface` rectangles, wakeboardd's
and backboardd's `NSUserDefaults` reads), the runtime's own
`wakeboardctl status` (run with `simctl spawn`), preference experiments
(nine boots) and our vhmdd client. Details:
`research/notes/obs-vision-stereo-2026-11-01.md`.

#### 5.6.1 The reference renders one view, and nothing outside the guest changes that

- **Apps get one view (level 1, 3).** The SDK says so ("you typically
  render only one view in Simulator"). A `CompositorLayer` in every layout
  gets: view count 1; one texture topology (array length 1); per frame one
  drawable, one view, `drawableTargetViewCount` 1; colour and depth
  textures 3840 × 2160, array length 1; foveation unsupported; layouts
  dedicated, shared, layered (0, 1, 2) offered.
- **System layers have one view (level 3).** wakeboardd makes each layer
  texture as a 2D array of length 1 (3840 × 2160, colour 81, depth 252);
  in the dedicated layout it makes only "Color (Left)" textures.
  `wakeboardctl status` shows an HMD of type **Sim** whose per-frame record
  per chain link has a **Left** and a **Right** block: Left filled (below),
  **Right all zero** (tangents, projection, viewport 0 × 0), for
  backboardd's layers (slots Top and Synthetic Passthrough) and for an
  app's layer (slot Bottom).
- **The camera of the one view (level 3):** view transform **identity**
  (the eye is the device origin: no eye offset, no IPD); tangents (left,
  right, top, bottom) = **(1, 1, 0.5625, 0.5625)**, i.e. 90° × 58.7°;
  depth range {∞, 0.1}; projection reverse-Z with infinite far plane and
  near 0.1 (columns (1, 0, 0, 0), (0, 1.7778, 0, 0), (0, 0, 0, −1),
  (0, 0, 0.1, 0)); viewport (0, 0, 3840, 2160). 0.5625 = 2160 / 3840; the
  vertical tangent is the display's height / width and the horizontal one
  stays 1 (tested with test device types of other sizes, §5.6.6).
- **What decides the layer's configuration (level 3).** wakeboardd reads
  its settings with `NSUserDefaults` (domain `com.apple.wakeboardd`,
  `DEV/data/Library/Preferences/com.apple.wakeboardd.plist`, which holds
  only `hmd.preferred-languages`). The controlled-layer configuration that
  backboardd receives (colour 81, depth 252, layout 2, §10.10.2) comes from
  `hmd.input.texture-color-format` (81), `hmd.input.texture-depth-format`
  (252) and `hmd.input.texture-layout` (2), values read when unset.
  Setting `hmd.input.texture-layout` before boot changes backboardd's
  layers: 0 → layout Dedicated (2D textures labelled "Color (Left)"),
  1 → Shared (2D, still 3840 × 2160). **No key changes the view count:**
  `hmd.input.texture-layout` 0/1/2, `hmd.display.texture-layout` 0–4,
  `hmd.display.mode` 0–3, and backboardd's `SimulatedHeadset` YES all
  left one view (StereoProbe view count 1, Right block zero, second slice
  empty). None of the ~500 keys wakeboardd reads, nor the ~2 200 reads of
  backboardd, names a view count, mono/stereo, an eye offset or an IPD.
- **Other inputs, none of which carries a view count:** wakeboardd reads
  only the standard simulator environment variables and asks no
  MobileGestalt question (level 3); of SimFramebuffer it uses only the
  display list, the display's type, current mode and device size, swapchain
  creation and the swap calls (level 4, imports) — not layer or swapchain
  counts or extended properties; the device type's plists have no such key
  (level 2); vhmdd has no such command (§5.6.3).
- **So the view count is fixed inside the guest's HMD implementation**
  (wakeboardd's Sim HMD; names `SimHMD`, "Mono Composite Buffer",
  CompositorServices' `is_mono` are level 4). **No host-settable input
  gives the reference two views.** XR-VIEWER keeps alternate-eye stereo.
  Q-XR2 (what two native views would look like) cannot be observed.

#### 5.6.2 The two-slice passes draw one view (Q-XR3, level 3)

backboardd's RealityKit allocates some targets as two-slice arrays:
`SyntheticColor`/`SyntheticDepth` 160 × 128 × 2 (`RGBA16Float`,
`Depth32Float`), 224 × 192 × 2 with `VCADepthStencil`, and 40 × 32 × 2 and
56 × 48 × 2 compute targets. In the `SyntheticColor` pass: render-target
array length 2, one viewport (0, 0, 160, 128); the clear is a 4-vertex
strip drawn with **instance count 2** (one instance per slice, i.e.
layered rendering with the slice chosen per instance); the room is five
indexed draws **without an instance count** (one instance). No pass calls
`setVertexAmplificationCount:`. Read back after the pass (146 read-backs over 15 boots): in 51 slice 0
holds the room (mean RGBA 0.370, 0.353, 0.313, 1.0), in the rest both
slices are zero; **slice 1 is all zero (alpha 0) in every one**. The second slice is RealityKit's room
for a second view, never drawn: there is no second camera and no offset.

#### 5.6.3 vhmdd has no stereo command (Q-XR4)

vhmdd's command strings are exactly those of §5.5.4 and §5.5.9 (level 4);
its pose is one device matrix. In 27.2 an unknown command gets a reply
`{error: "Unknown command: <cmd>"}` (level 3: `set_ipd`, `get_ipd`,
`set_stereo`, `set_view_count`, `get_view_count`, `set_eye_offset`,
`get_display_info`), so a host can tell that a command does not exist.

#### 5.6.4 Presentation

One `SFBSwapchainSwapAddSurface` per swap, source and destination (0, 0,
3840, 2160), two surfaces alternating (§10.6.6), in every experiment.

#### 5.6.5 What Ycode must do

1. **Parity is one view.** Ycode runs the reference's wakeboardd,
   backboardd and CompositorServices unchanged, so the guest decides one
   view by itself; Ycode must not try to change it, and needs no defaults,
   environment or SimFramebuffer property for it. Ycode's SimFramebuffer
   replacement must keep answering the display type (integrated), current
   mode and device size (3840 × 2160) that wakeboardd asks for.
2. **Metal for the one-view passes.** The Metal→Vulkan layer must support
   2D-array textures of length 2 as render targets with render-target
   array length 2, a vertex shader that selects the slice per instance
   (Vulkan multiview is not required: no amplification is used), and must
   write slice 1 with the two-instance clear; slice 1 is otherwise never
   read for the picture.
3. **Stereo is a Ycode feature, not parity (XR-VIEWER).** The guest's
   camera is the device pose with an identity eye transform, so a stereo
   viewer gets its two eyes by moving the device pose: alternate frames
   between pose × T(−d/2, 0, 0) and pose × T(+d/2, 0, 0) (d = the viewer's
   IPD, along the device's x axis) through vhmdd `set_pose` and the
   rendered camera together (§5.5.3, §5.5.9 item 5), and tag each presented
   frame with the eye whose pose it was rendered for. Each eye then updates
   at half the 60 Hz rate. The guest's field of view is 90° × 58.7°
   (tangents 1, 1, 0.5625, 0.5625); the viewer must map it onto each eye's
   own projection (crop or scale). The guest takes no FOV request, but
   the display size Ycode reports sets the vertical FOV (horizontal fixed
   at 90°, §5.6.6). Ycode must not send vhmdd commands for IPD, stereo or view
   count: they do not exist (an error reply).
4. **Diagnostics.** `simctl spawn <dev> wakeboardctl status` (reference)
   prints the HMD type, each layer's layout, textures and per-eye blocks;
   use it for parity checks of Ycode boots (Right block zero, layout
   Layered, 3840 × 2160).

#### 5.6.6 Field of view (agent OBS-VISION-FOV, 2026-11-01)

Question from the headset viewer: what decides the camera's tangents, and
can a host widen them (up to a fully surrounding view)? Observed on
visionOS 27.2 with `wakeboardctl status` (the per-eye tangents and
projection), `StereoProbe` (what an app's CompositorLayer is given),
screenshots, and **test device types of our own** (copies of the 4K type
with only the integrated display's width, height and refresh rate
changed in `capabilities.plist`; CoreSimulator accepts them without a
restart). The installed 2732 × 2048 type cannot be used: its profile
limits it to runtimes up to 2.99 and 27.2, 26.5 and 26.4 refuse it
("Incompatible device"). Details: `research/notes/obs-vision-fov-2026-11-01.md`.

1. **The display's size decides the vertical field of view; the
   horizontal one is always 90°** (level 3). Tangents (left, right, top,
   bottom) = (1, 1, h/w, h/w) for a display of w × h pixels:

   | Display w × h | Tangents | Projection y scale | Field of view h × v |
   |---|---|---|---|
   | 3840 × 2160 (the 4K type) | 1, 1, 0.5625, 0.5625 | 1.7778 | 90° × 58.7° |
   | 7680 × 2160 | 1, 1, 0.28125, 0.28125 | 3.5556 | 90° × 31.4° |
   | 3840 × 3840 | 1, 1, 1, 1 | 1 | 90° × 90° |
   | 2160 × 3840 | 1, 1, 1.7778, 1.7778 | 0.5625 | 90° × 121.3° |
   | 1024 × 8192 | 1, 1, 8, 8 | 0.125 | 90° × 165.8° |

   The projection's x scale stays 1; reverse-Z, infinite far, near 0.1 as
   in §5.6.1. The layer textures, the swapchain and the presented surface
   take the display's size; one view as before.
2. **Nothing is cropped, scaled or distorted** (level 3, screenshots): the
   room and the home view are rendered with a plain pinhole projection at
   every size (straight lines stay straight; at 165.8° the edges are
   stretched as any rectilinear projection is); the home view keeps its
   size relative to the width. **Apps see the same projection**: a
   CompositorLayer gets the display's tangents, a viewport and textures of
   the display's size, view count 1. The camera smoothing (§5.5.12) is the
   same at every size.
3. **No preference widens it** (level 3, one boot each, tangents from
   `wakeboardctl status`, screenshots compared with the baseline: no
   pixel changed): backboardd `CameraScale` 2 (three domains); wakeboardd
   `hmd.mesh.override-rectilinear-fov` as four numbers ((2, 2, 1, 1) and
   (60, 60, 45, 45)); `hmd.cvcalibration.field-of-view-degree-delta` as
   four numbers (30 each); `hmd.input.remote-compositor-extended-fov-delta`
   0.5, `hmd.display-tap.extra-rendered-fov` 3,
   `hmd.cvcalibration.use-nominal-mcam-fov` YES. A **single number** in
   either four-number key makes wakeboardd abort at start, again and
   again; the boot then waits on BackBoard forever. backboardd's
   `Fov*AngleThresholdDegrees` keys (80/45, extended 110/65) are window
   placement thresholds, not the camera.
4. **The horizontal field of view cannot exceed 90°** through any host
   input found (display size, device type, preferences, vhmdd, §5.6.3).

**What Ycode must do.**
1. Ycode's display size *is* its field-of-view control: what Ycode's
   SimFramebuffer replacement reports as the integrated display's size
   (in the tests the device type's `ScreenDimensionsCapability` was
   changed with it) sets the vertical
   tangent to h/w with the horizontal fixed at 1. Parity for the Apple
   Vision Pro device is 3840 × 2160 (90° × 58.7°). For the headset viewer,
   a taller display widens the vertical view: 1:1 gives 90° × 90°,
   2160 × 3840 gives 90° × 121°; the GPU cost grows with the pixel count,
   so keep the width and raise only the height, or lower both.
2. Treat the horizontal 90° as fixed. A view wider than 90° can only be
   assembled by the viewer from several pictures taken at different camera
   yaws (for example −90°, 0°, +90°): each turn costs a settle (90 % at
   about 130 ms, within 0.1° at about 230 ms, §5.5.12), so this suits a
   still head and a still scene only.
3. Never write a single number to `hmd.mesh.override-rectilinear-fov` or
   `hmd.cvcalibration.field-of-view-degree-delta` (wakeboardd aborts); the
   preferences have no effect anyway.

#### 5.6.7 Rasterization rate maps and foveation (agent OBS-VISION-RRM, 2026-11-01)

Question from the headset viewer (a Quest Pro with eye tracking): does the
reference ever render with Metal rasterization rate maps (variable
rasterization rate, the mechanism behind visionOS's foveated rendering),
what decides it, and can a host turn it on? Observed on **visionOS 27.2
(24N120)** (no 27.0 device could be created) with our recorder
`rrmpeek` in every guest job (the device's rate-map calls with their
answers and calling image, every rate-map creation, every rate map set on
a render pass, and the foveation and VRR accessors of the compositor and
RealityKit images), our probe `rrmcli` (the device's answers, the Mach
messages they cost, map creation), `StereoProbe` with foveation forced
on, the Metal-protocol recorder and test server of `metal-sim-protocol.md`
Appendix A, `wakeboardctl status`, the guest log, and six boots with
preferences. Details: `research/notes/obs-vision-rrm-2026-11-01.md`.

**Answer: nothing in the simulator ever uses rate maps, and no host input
enables them.**

1. **No guest process makes or uses a rate map** (level 3, five boots,
   every job recorded). No call to `newRasterizationRateMapWithDescriptor:`
   except our probe's, no render pass with a non-nil
   `rasterizationRateMap`, no app drawable with a rate map
   (`rasterizationRateMaps` count 0), and every layer link in
   `wakeboardctl status` reads "Layered VRR Not Enabled", with
   "supports eye tracking: Disabled" and "AX Static Foveation: Disabled".
   The per-link VRR decoder buffers are absent (read as nil in
   wakeboardd, backboardd and apps). wakeboardd presents the whole
   3840 × 2160 image (§5.6.4); no map or warp data leaves the guest.
2. **Who asks.** RealityKit's engine asks the device
   `supportsRasterizationRateMapWithLayerCount:` **2** once per process
   that loads it (backboardd, RealityEnvironment, pointeruid,
   datamigrator, the system apps and any RealityKit app) and gets NO.
   wakeboardd never asks it; its compositor's VRR accessors were never
   called. CompositorServices tells apps **foveation unsupported**
   (`supportsFoveation` false; with the foveation option the offered
   layouts are dedicated and layered).
3. **The Metal device's answers are constants of the guest driver**
   (level 3, plus level 4 for which class defines them). The simulator
   device defines the rate-map methods itself
   (`supportsVariableRateRasterization` comes from Metal's base device
   class): `supportsRasterizationRateMapWithLayerCount:` NO for 0–4,
   `maxRasterizationRateLayerCount` 0, `supportsVariableRateRasterization`
   NO, and `newRasterizationRateMapWithDescriptor:` returns **nil** for a
   valid one-layer and two-layer descriptor (screen 3840 × 2160, 5 × 3
   zones); no exception. **None of these sends a message to the host**
   (Mach messages counted around 1000 calls: only the counter's own;
   the Metal-protocol recorder shows only the hand-shake and op 37).
   With our test server as host, `hostFeatureProfile` 0, 1, 5, 10, 11, 12,
   20 or 100 and `version` 11 changed none of the answers. A host cannot
   make the device support rate maps.
4. **Even a device that said yes would not be used** (diagnostic, not a
   host input: our recorder forced `supportsRasterizationRateMap…` to YES
   in every process). RealityKit then still made no map and set none,
   and nothing in the picture changed; its rate maps would come from the
   compositor's drawables, which carry none.
5. **The compositor's decision** belongs to wakeboardd's simulator HMD
   (one view, no eye tracking, §5.6.1). wakeboardd's foveation
   preferences are read but change nothing (one boot, all at once, level
   3; screenshot equal to the baseline except the probe's new icon):
   `hmd.foveation.recommendation-mode` 1, `hmd.foveation.use-constant-cr`,
   `hmd.foveation.vrr.use-max-ppd-of-clients`, `hmd.foveation.vrr.show`,
   `hmd.foveation.gaze.show`, `hmd.foveation.eyetracking.show`,
   `hmd.foveation.pixel-grouping.override-enabled`,
   `hmd.foveation.enable-static-foveation-detail-enhancement`,
   `hmd.motion-to-photon-measurements.eye.foveation-enabled` (all YES),
   and backboardd's `CAREVisualizeVRRRateZones` YES. **Setting
   `com.apple.compositor.foveation.custom` YES (in wakeboardd's domain,
   without further keys) makes wakeboardd abort each time a layer is
   created** (crash loop; `wakeboardctl` shows "HMD State: Configuring…");
   never set it.
6. **Apps that ask for foveation anyway** (`isFoveationEnabled` true
   although unsupported): `LayerRenderer.Properties(configuration:)`
   throws `variableRasterizationRateIsNotSupported` (C code −16), the
   layer renderer is never delivered, and our probe's process was gone
   within 15 s. Apps must keep foveation off when it is unsupported.
7. **Gaze.** No gaze reaches rendering: backboardd's headset object
   polls eye tracking about 150 times a second and always gets NO; the
   layers report eye tracking disabled. The selection gaze of §5.5
   (SelectionStream) is input only, and vhmdd has no gaze-for-rendering
   command. Q2's "which gaze source" therefore has no answer in the
   reference.

**The interface as Metal defines it** (level 1, public headers; for the
record, since the reference never exercises it): a descriptor has a
screen size and one `MTLRasterizationRateLayerDescriptor` per layer (a
zone grid with one horizontal and one vertical rate per column and row,
rates in (0, 1]); the device turns it into a map whose
`physicalSizeForLayer:` is smaller than the screen size and which maps
screen ↔ physical coordinates; a render pass sets `rasterizationRateMap`
and renders into a physical-size texture; shaders that read such a
texture decode it with `rasterization_rate_map_data` /
`rasterization_rate_map_decoder` from a parameter buffer
(`parameterBufferSizeAndAlign`, `copyParameterDataToBuffer:offset:`);
CompositorServices hands an app one map per drawable view group
(`cp_drawable_get_rasterization_rate_map`, flipped variants on request)
only when foveation is enabled. In the simulator the shading-language
side compiles (our decoder shader built in the guest), but no map can be
created, so none reaches the host: the render-pass record
(`metal-sim-protocol.md` §8.6) has no known field for one.

**What Ycode must do.**
1. **Parity: nothing.** Ycode runs the reference's guest Metal driver,
   which answers every rate-map question itself (NO, 0, nil); Ycode's
   host needs no rate-map support and must not try to advertise any (it
   cannot: no message carries it). The Metal→Vulkan layer needs no
   variable-rate feature. Keep the compositor's answers as they are:
   foveation unsupported, eye tracking disabled.
2. **Never set `com.apple.compositor.foveation.custom`** in a Ycode
   device's preferences (wakeboardd crash loop).
3. **Foveation for the headset viewer is a Ycode feature on the host
   side, not a guest feature.** Rate maps cannot be used: the guest will
   not make them. Two host-side options remain, both off by default and
   off in parity runs:
   - *Foveated shading in the Metal→Vulkan layer*: Ycode may apply
     Vulkan fragment shading rate (an attachment-based rate, for example
     `VK_KHR_fragment_shading_rate`) to the guest's render passes into
     the 3840 × 2160 layer colour textures (the textures wakeboardd shares
     with backboardd, §5.6.1), centred on the viewer's gaze. Unlike Metal
     rate maps this keeps the texture full-size, so the guest's later
     passes and wakeboardd's composition read it unchanged. The viewer's
     gaze direction maps to the layer's pixels through the guest camera
     (tangents 1, 1, h/w, h/w, §5.6.6; identity eye transform); with
     alternate-eye stereo (§5.6.5 item 3) each frame uses the gaze of the
     eye it is rendered for. Whether the Thor's GPU and driver offer the
     extension must be checked there.
   - *Foveated streaming*: lower the quality of the periphery when the
     display stream encodes the presented 3840 × 2160 frame, from the
     viewer's gaze. This saves bandwidth and latency, not guest GPU time.
   The only host input that lowers the guest's own GPU cost is the
   display size (§5.6.6), which applies everywhere, not around the gaze.

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
  §5.5.2, §5.5.7), carried by Ycode's HID host service (`hid-input.md` §7);
  plus vhmdd's `set_pose` for ARKit (§5.5.3).
- **V-12** Viewer mapping as in §5.1 (interact / pan / dolly / tilt
  modes, WASD/arrows + E/Q, Control-drag, reset camera, pointer and
  keyboard capture with Escape, Home, game controller later).
- **V-13** Room selection: the six rooms of §2.6 by key; first by the
  `activeSyntheticEnvironment` preference before boot (verified, §5.5.4),
  later live through vhmdd's `set_active_environment` (§5.5.4).

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

1. *(Answered, §5.5.2, §5.5.6, level 3.)* The Indigo payload layouts of the Paloma pose, selection and collection
   messages, and the HID event types and fields backboardd receives from
   the PalomaPose, SelectionStream and Manipulator services.
2. *(Answered, §5.5.1, §5.5.3, level 3: PalomaPose moves only the view;
   ARKit's anchor is the app's stage transform times vhmdd's pose, which
   only the host's `set_pose` changes; the host sends both.)* Whether camera movement reaches the guest only as PalomaPose HID events,
   or also through vhmdd (`setPose:`/`setCamera`), and which component turns
   the pose into the `DeviceAnchor` that ARKit returns (`com.apple.vhmdd-sim`
   was contacted by the app).
3. *(Answered, §5.5.4, level 3: XPC dictionaries keyed by `cmd`, host
   only; the preference before boot selects the room. Reset is a host-side
   `set_pose` plus a pose message with the start pose.)* The vhmdd host protocol (environment list, selection, pose, reset) and
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
   *(OBS-WATCH, 2026-10-29: not observed. The round's reference work went
   to watchOS and pairing; the Mac's load average stayed at 190–840 from
   other work, and the round's rule allowed at most one phone and one
   watch booted, so no reference visionOS boot with `mslog` was made.
   What Ycode must do meanwhile: keep reading op 29's base instance as the
   low 16 bits of the last word (§10.20.2); a reference capture remains
   the only confirmation.)*
   *(Answered, OBS-ARGBUF, 2026-10-30, level 3, reference.)* In the
   reference's backboardd (visionOS 27.0, cold first boot, `mslog` in
   backboardd, 148 s of the room) the 36-index depth-only draws arrive as
   **op 29**: 7 845 records with 8 instances and 300 with 3, base vertex 0,
   **low half of the last word 0** (base instance 0), high half `0x0000`
   in 7 591 records and stale bytes in the rest: `0x3FF0` (280), `0x40AE`
   (259), `0x40A0` (8), `0x0003` (7), the very values Ycode had decoded as
   base instances 0x3FF00000, 0x40AE0000 and 0x40A00000. Our probe on the
   iOS 27.0 reference (`argprobe draw2`) settles what the host does with
   them: a first command buffer left viewport records (doubles) in the
   segment, a second sent `drawIndexedPrimitives…instanceCount:2
   baseVertex:0 baseInstance:5` whose op-29 record landed on them with last
   word `0x66660005`, and the vertex function saw `base_instance` 5 and
   `instance_id` 5 and 6 (six invocations). **What Ycode must do:** read
   op 29's base instance as the low 16 bits and ignore the high half
   (`metal-sim-protocol.md` §8.3), which it already does since §10.20.2.
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
   *(OBS-WATCH, 2026-10-29: not observed, for the reason given under Q24.
   What Ycode must do meanwhile: keep member n at 8 × n (it covers every
   layout seen so far, all with dense ids) and log any op-16 layout whose
   member ids are not 0…n−1, so the first sparse layout is found under
   Ycode before a reference capture exists.)*
   *(Answered, OBS-ARGBUF, 2026-10-30, level 3, reference;
   `metal-sim-protocol.md` §4.3.)* (a) **The host writes the members**: the
   bytes are in the argument buffer when op 19 returns, and with the
   recorder's test server (which writes nothing) no byte changes. Values: a
   buffer's `gpuAddress` plus the call's offset; for a texture an 8-byte
   handle of the host's own choosing; for a sampler its op-39 resource ID;
   0 for `nil`. (b) Member *n* is at **the offset that op 16's layout
   description gives for it**, which is its position in the struct (8 bytes
   per buffer, texture or sampler; inline data at its own size and
   alignment), not 8 × *n*: our ids 0, 5, 9 landed at 0, 8, 16 and ids 200,
   201, 230, 231 at 0, 8, 16, 24. (c) Op 17's reply is u32 ref, u32 0,
   **u16 alignment, u16 encoded length** (the earlier reading had the halves
   swapped); the alignment is the largest member alignment and the length
   the end of the last member rounded up to it. (d) The words after the
   kind are a 24-bit first index, then a 24-bit count for range calls
   (`setBuffers:offsets:withRange:` and the like) and a zero u64. The
   reference's home view (backboardd, boot `x1`) makes **one** encoder in
   the whole boot, from argument descriptors: 15 read-only device buffers
   with indices 0–14 at offsets 0, 8, …, 112, op-17 reply alignment 8 and
   length 120, then 60 kind-0 calls and 58 set calls for each of the 15
   indices in the 3 minutes captured. That layout is dense, so Ycode's
   8 × *n* happened to be right for it; WeatherPoster's ids 200, 201, 230 and 231 are not (the
   reference's cold iOS 27.0 boot made no encoder in WeatherPoster, so its
   own description was not captured). **What Ycode must do:** parse op 16
   (`metal-sim-protocol.md` §4.3.1) into an index → offset table, answer
   op 17 with the computed alignment and length in that order, write op-19
   members at the table's offsets (range forms included), and answer op 35
   (`constantDataAtIndex:`) with the argument-buffer offset plus the member
   offset (§4.3.8).
   *(Implemented, ARGBUF-IMPL, 2026-10-30: §10.22.1,
   `metal-sim-protocol.md` §4.3.9.)*
26. *(New, R7b.)* The room's parts left out of some frames (§10.20.9).
   Under Ycode backboardd draws the room 30 times a second and, in a fixed
   cycle of 16 room frames that starts with a 768 × 432
   `fsLinearizedDepthAsColor` pass, leaves the 41 520-index part out of
   three frames and the 162 624-index part (the walls) out of two. On the
   reference, with Metal's frame capture or `mslog` in backboardd while the
   room shows: (a) does the room pass ever lack one of its five draws, and
   (b) is there a 768 × 432 linearized-depth pass, how often, and which
   attachments does it write?
   *(OBS-WATCH, 2026-10-29: not observed, for the reason given under Q24.
   What Ycode must do meanwhile: no renderer workaround (the parts are
   left out by the guest's own draw stream, §10.20.9); keep §10.20.11
   item 1 open and look under Ycode for what the 768 × 432 pass's results
   feed (the guest's visibility decision) until a reference capture
   says whether the reference leaves parts out too.)*
   *(Answered, OBS-ARGBUF, 2026-10-30, level 3, reference.)* (a) **No.**
   In the reference's backboardd (cold first boot, `mslog` in backboardd,
   22–170 s after boot) all 10 114 room passes (one cleared colour
   attachment, store) hold all five draws (41 520, 57 543, 162 624, 20 328
   and 48 indices); not one lacks a part. The room pass ran at a median
   interval of 16.5 ms. (b) **Yes**, the same 768 × 432 pass exists: 280
   passes at a median interval of 517 ms (so it is timed, about twice a
   second, not every *n* room frames), four colour attachments of
   768 × 432 (`R16Float`, `RGBA16Float`, `RGBA16Float`, `R16Float`, load
   don't-care, store) and a 768 × 432 `Depth32Float_Stencil8` depth
   attachment, with seven draws: one of 6 indices, one of 612, and the five
   room parts. Four earlier passes of the same attachments with only the
   five parts ran once a second at 22–25 s. So the reference draws the same
   linearized-depth pass and still never leaves a room part out. **What
   Ycode must do:** treat the parts left out under Ycode as a Ycode
   difference in what the guest reads back, not as guest behavior: the
   decision is the guest's and its inputs come from the host, most likely
   the results of this 768 × 432 pass (read back after its blits) or the
   boolean visibility results (§10.20.8). Compare those values with the
   reference next (a probe that reads the four targets after the pass, as
   `v12` did under Ycode).
   *(Fixed, ARGBUF-IMPL, 2026-10-30, §10.22.2. It was the visibility
   results. Under Ycode every occlusion result was zero, because the
   Vulkan back end did not rasterize pipelines without a fragment function,
   and the occlusion boxes are such pipelines. With these pipelines drawn
   as depth- and stencil-only, the results are non-zero and no room frame
   misses a part.)*
27. *(New, R8.)* The order of Siri's orb pre-warm and the home view's
   first appearance (§10.21.1). Under Ycode, at the end of a first boot,
   assistantd logs "finished post launch setup", then `_prewarmOrb` sends
   SurfBoard an open request for `com.apple.MRSiri` (URL
   `#orb_graphics_prewarm_orb`). When SurfBoard handles it while the
   device is still locked, it is refused ("Failed to validate open
   application request", `RequestDenied`) and assistantd tries again
   much later; when SurfBoard handles it after "Attempting to unlock system
   … User presence detected", it is allowed, Siri's pre-warm scene is
   created in the foreground, and at "Cover sheet child layouts updated to
   unlocked" SurfBoard logs "HomeUI wants to resume from unlock, but there
   will be foreground scenes running" and never launches RealityLauncher.
   In the reference, in a few first boots of a new device (log stream of
   SurfBoard and assistantd): (a) the times of assistantd's "finished post
   launch setup" and "Sending request to open \"com.apple.MRSiri\"",
   SurfBoard's "Received request to open" and its validation result
   (refused or allowed), "Data migration completed", "Attempting to unlock
   system", "Cover sheet child layouts updated to unlocked" and "HomeUI
   wants to resume from unlock, but there are/will be …"; (b) whether the
   request is ever allowed before the home view resumes, and if so whether
   the home view appears anyway (and what brings it up); (c) whether
   assistantd's later retry (Ycode: after "Service loaded:
   com.apple.siri.applications", 60–90 s later) also happens.
   *(Answered, OBS-ARGBUF, 2026-10-30, level 3, reference.)* Three first
   boots of a new Apple Vision Pro device on the reference (visionOS 27.0,
   `ycode-test-argbuf-xr`, erased before each; `x1` with the recorder in
   backboardd, `x2` and `x3` without), guest `log stream` of SurfBoard and
   assistantd from the boot command; seconds from the boot command:

   | Event | `x1` | `x2` | `x3` |
   |---|---|---|---|
   | SurfBoard "Data migration completed" | 21.6 | 23.1 | 22.1 |
   | "Attempting to unlock system … User presence detected" | 22.3 | 24.0 | 22.9 |
   | "Cover sheet child layouts updated to unlocked" | 22.6 | 24.3 | 23.2 |
   | "HomeUI wants to resume from unlock, but there are **no** foreground scenes running" | 22.6 | 24.3 | 23.2 |
   | "Attempting to launch process com.apple.RealityLauncher" | 22.6 | 24.3 | 23.3 |
   | assistantd "Service loaded: … com.apple.siri.applications" | — | 205.5 | 108.6 |
   | assistantd "finished post launch setup", `_prewarmOrb`, "Sending request to open \"com.apple.MRSiri\"" | — | — | 111.7 |
   | SurfBoard "Received request to open" MRSiri (`#orb_graphics_prewarm_orb`), validation | — | — | 111.7, **allowed** ("Allowing application launch") |
   | end of the capture | 175 | 241 | 241 |

   (a) as in the table. (b) The pre-warm request never came before the
   unlock: the reference unlocks and resumes the home view about 23 s into
   the boot, while assistantd finishes its post-launch setup only after
   its services load, 112 s into `x3` and not within 241 s in `x2`. The
   request was allowed (the device was unlocked), MRSiri was launched with
   intent "foreground-support", and the home view stayed on screen
   (screenshots at 123 s and 227 s of `x3`); the "there will be foreground
   scenes running" branch never occurred. (c) No retry: the one request of
   `x3` was allowed at once, and nothing was refused, so there was nothing
   to retry. In the reference the post-launch setup followed "Service
   loaded: com.apple.siri.applications" by 3 s. **What decides it** is
   the order: unlock and home resume depend on data migration (about 22 s
   on the reference), the pre-warm on assistantd's service loading (110 s
   or more); under Ycode the slow boot moves the unlock past the pre-warm.
   **What Ycode must do:** keep the home guard of §10.21.2 (it gives the
   reference's outcome: the home view up, Siri pre-warmed behind it); the
   lasting fix is a boot whose unlock comes before assistantd's
   post-launch setup, as on the reference.
   *(R11, 2026-11-01: Ycode now holds assistantd's start until the shell
   is ready, which gives the reference's order, §10.26.1; the guard stays
   as a logged fallback.)*
28. *(New, R11.)* Why assistantd's post-launch setup comes so late on the
   reference (§10.26.1). Under Ycode assistantd is started 2–4 s after its
   spawn by a boost from apsd (message id 473000, which also starts
   amsaccountsd, parsecd and remindd), and finishes its post-launch setup
   about 23 s later; on the iOS 27.1 reference (`scheduling-policy.md` §3)
   assistantd and amsaccountsd start 4.6–5.4 s in, but parsecd only at
   255 s and remindd at 19–22 s. In a first boot of a new Apple Vision Pro
   device on the reference, with the log stream of assistantd and apsd:
   (a) when assistantd's process starts ("assistantd launched build …")
   and when its `xpcproxy_sim` waits (priority 4 in `ps`, as in
   `scheduling-policy.md` §3); (b) the times of its main-thread lines
   between that and "finished post launch setup" (the BGST submissions
   "Starting submission of task …speech-audio-sampled." and "Successfully
   submitted …", "Server posting darwin notification for state transition")
   and its priority meanwhile; (c) whether apsd's "Delivering
   connectionStatusChange" reaches assistantd, amsaccountsd, parsecd and
   remindd early in the boot, and when.
29. *(New, VISION-FPS, §10.28.)* At the reference's home view with the gaze
   moving over the icons: pictures per second; IOSurface requests per second
   by method and process (under Ycode about 1,950 from the home view and 970
   from backboardd); and whether backboardd stays at 30 pictures/s for a while
   after missed frames, as it does under Ycode.

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
1a. *(Fixed in R11, §10.26.1.)* RealityLauncher's home view is sometimes not launched before the end of
   a 300 to 420 s boot (`v5`, `f1`, `f3`; R7's `e1`, `v1`, `v3`), mostly
   under a high load average; why SurfBoard does not create its scene was
   not examined.
2. Direct kernel writes to sRGB textures (no view): no storage view, the
   writes are lost and logged (§10.20.4 item 1). A faithful version encodes
   linear to sRGB in the translated function, which needs the format of the
   bound texture at run time (none seen in these boots).
3. *(Answered, §9 Q24; R11 §10.26.3.)* §9 Q24 asks the reference to confirm op 29's last word with a non-zero
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

### 10.21 Round R8 under Ycode (agent VISIONOS-R8, 2026-10-29)

Clean-room work on Ycode's own simulator on the Thor (branch `vis8` on the
main line 5a127ff; the visionOS device copied from R7b's, booted on 24M362;
the iPhone 18 Pro device of the iOS 27.0/27.1 rounds). Boots: `b1`, `b2`
(main line, a guest log stream that adds assistantd and Siri), `h1`–`h3`
(Home pressed through the display stream), `g1`–`g6` and `k1`–`k4` (the
home guard), `a1`–`a10` and `a6b` (apps), iOS `s1` (cold boot with a stop
snapshot, then a restore) and `i1`. Two to four of these boots ran at once and
other agents' boots ran beside them: load averages of 50 to 240 on the
Thor's 14 cores, the room's first frame 117–378 s after the start (R7b:
50–120 s). No Apple simulator, Xcode, Device Hub or reference tool was run
or opened, nothing under `research/` was read, nothing was disassembled,
and the guest's shader logic was not read. Level 3 throughout, level 1 for
the sRGB formulas and the Info.plist keys.

#### 10.21.1 Why the home view is sometimes not launched (§10.20.11 item 1a)

The guest log of every visionOS boot since R7 (27 of R7/R7b, 11 of this
round; SurfBoard, assistantd, Siri) shows one guest race, decided in
SurfBoard:

1. When assistantd logs "finished post launch setup" it pre-warms Siri's
   orb: `_prewarmOrb` sends SurfBoard an open request for `com.apple.MRSiri`
   (process "Siri", URL `#orb_graphics_prewarm_orb`).
2. SurfBoard validates the request on its main queue. While the device is
   still locked it refuses it ("Failed to validate open application
   request …", assistantd: `RequestDenied`, "Unable to prewarm UI"), and
   assistantd tries again much later (after "Service loaded:
   com.apple.siri.applications", 60–90 s on). After "Attempting to unlock
   system … User presence detected" it allows it ("Allowing open
   application request due to unlocked device"): Siri launches and its
   pre-warm scene is made in the foreground.
3. When the cover sheet is gone ("Cover sheet child layouts updated to
   unlocked"), SurfBoard decides whether to bring up the home view: "HomeUI
   wants to resume from unlock, but there are no foreground scenes running"
   is followed by "Requesting an app launch for com.apple.RealityLauncher";
   "… but there will be foreground scenes running" by "Home UI will not show
   since there are still blocking foreground scenes when pressed", and
   nothing brings the home view up later, also after Siri's pre-warm scene
   is destroyed (`b2`: 22 s later).

| Boots (R7, R7b, R8 before the guard) | 38 |
|---|---|
| home view brought up at the resume | 23 |
| home view not brought up ("will be foreground scenes running") | 15 (`e1`, `f1`, `f3`, `p1`–`p5` (R7's probe boots, whose runs share one guest log), `v1`, `v3`, `v5`, `v7`, `b2`, `h1`, `h3`) |
| of these, Siri's pre-warm allowed before the resume | **15 of 15** |
| Siri's pre-warm allowed before the resume and the home view brought up all the same | 3 (`v6`, `g4`, `h2`: its scene was not in the foreground yet) |

Whether the request is handled before or after the unlock is a matter of
timing: SurfBoard's main queue runs its own start-up in long stretches
(`b2`: the request arrived at 32.9 s guest time, during the stretch that
ends with the unlock at 38.1 s, and was validated at 43.9 s; `b1`: it
arrived 10 s after it was sent, while SurfBoard waited for data migration,
and was refused at 39.4 s, before the unlock at 42.5 s). The window
between the unlock and the resume, in which an allowed request blocks the
home view, was 2 to 48 s under Ycode (median 18 s), mostly backboardd's
display reveal (the boot logo's three stages when the shell finishes after
the unblank, about 10 s) and SurfBoard's work after it. The reference shows
the room and the home view about 7 s after Run (§10.12.3); whether its
pre-warm can fall into that window is §9 Q27. In every boot the resume
decision came 4 to 84 s *before* the room's first presented frame (the
first lit frame waits for backboardd's first composed room).

What it is not: no guest process crashed or was refused by Ycode, no Metal
or kernel error is involved, and the start hold (`scheduling-policy.md`
§4.2) released assistantd by a boost in every boot. It is the shell's own
decision on an order of events that Ycode's slower, unevenly loaded guest
produces in about 40 % of boots.

**A Home press brings the home view up.** In `h1` and `h3` (both "will be
foreground scenes running"), one Home press through the display stream 60 s
after the room's first frame (`ycode-display-probe … button home`;
consumer page 0x0C usage 0x40, backboardd: "Home page:0xC usage:0x40")
made SurfBoard request RealityLauncher at once.

#### 10.21.2 The home guard (change 1)

`ycode-simd` (VisionHomeGuard.swift), visionOS device runs only: from the
boot on it watches the presented frames; when no RealityLauncher process
exists 60 s after the first lit frame (the room's), it presses Home through
the HID service and logs "visionOS home guard: … pressing Home"; when there
is still none 60 s later it presses once more; it stops as soon as
RealityLauncher runs. It never presses while RealityLauncher runs (a press
would close the home view), and it is off in runs that launch an app
(`--launch`: the app is the foreground) and with
`YCODE_VISIONOS_HOME_GUARD=0`; `YCODE_VISIONOS_HOME_GUARD_S` sets the delay.
The delay is safe: the resume decision precedes the room's first frame in
every boot (§10.21.1). This is Ycode's stand-in for a user who presses Home
when the home view did not come up, as on the reference a user of Device
Hub would; it compensates for a race that Ycode's speed loses more often
than the reference (Q27), and it is logged in every boot where it acts.
Test `VisionHomeGuardTests`.

| Series | Boots | Load average | Room (first lit frame) | Home view launched | Guard |
|---|---|---|---|---|---|
| R7, R7b, R8 before the guard | 38 | 10–240 | 50–378 s | 23 (61 %) | — |
| `g1`–`g6` (guard, 4 at once, other agents' boots) | 6 | 70–238 | 165–379 s | **6 of 6** (resume "no foreground scenes") | not needed |
| `k1`–`k3` (guard, 3 at once and other agents' boots) | 3 | 110–150 | 196–274 s | **3 of 3** | not needed |
| `h1`, `h3` (no guard; Home pressed by hand 60 s after the room) | 2 | 50–70 | 222–237 s | 2 of 2, at the press | — |

So the home view came up in all 9 cold boots with the guard (`g1`–`g6`,
`k1`–`k3`, under load averages of 70 to 238), against 23 of 38 before;
in these 9 the race happened to go the shell's way, so the guard did not
have to press, and its press is the one shown to work in `h1` and `h3`
(the same HID event, consumer page 0x0C usage 0x40, sent from the host
instead of the display stream). The home view with its icons and names:
`.claude/worktrees/vis8-home.png` (outside git; `g5` at 400 s).

#### 10.21.3 App compatibility

**Build.** Ycode's own path: `ycode build <project> -scheme <target>
-destination 'generic/platform=visionOS Simulator' --engine swift-build`
(swift-build's `swbuild`, built from `Tools/ycode-swb`). Two gaps were found
and handled: the swift-build engine sent no simulator SDK for a simulator
destination, so a project with `SDKROOT = xros` was built for the device;
it now adds `SDKROOT=xrsimulator` (`iphonesimulator`, …) unless the command
line sets one (`build-pif.md`, change 2, test
`simulatorDestinationsChooseTheSimulatorSDK`). Ycode's PIF generator does not
yet expand Xcode 16's synchronized folders (`PBXFileSystemSynchronizedRootGroup`):
a target that uses one is built without sources (an app bundle with no
executable, "BUILD succeeded"); the samples use ordinary groups. The
samples: `ycode/Samples/VisionSamples` (our own code), three app targets
with explicit Info.plists (`UIApplicationPreferredDefaultSceneSessionRole`
`UIWindowSceneSessionRoleApplication`, or
`UIWindowSceneSessionRoleVolumetricApplication` for the volume;
`UIApplicationSupportsMultipleScenes`):

- `VisionWindow`: a SwiftUI window (symbol image, text, a button with a
  counter, a toggle);
- `VisionVolume`: a volumetric window (0.6 m) with a RealityKit box
  (`InputTargetComponent`, collision shape, turned by a tap) and a metallic
  sphere;
- `VisionImmersive`: a window that opens an `ImmersiveSpace` (mixed) at
  launch, with a sphere (tap gesture recolours it) and a ring of eight
  cubes.

They log through `os.Logger` (subsystem `org.ycode.samples`).

**Install and launch.** `ycode-simd --install-app <App.app> --launch <id>
--guest-tools <dir with ylaunch>` (`app-install-launch.md`) works on the
visionOS runtime unchanged: ylaunch installs (`installed
org.ycode.samples.window`) and SurfBoard launches through the open request
(0.5–9.2 s under load). The app steps were held until 40 s after the
room's first frame (`YCODE_SNAPSHOT_WHEN_FILE`, as the iOS app runs do).

| App | Launches | Renders | Input | What is missing |
|---|---|---|---|---|
| VisionWindow (ours) | yes (`a1`, `a8`; open request 9.2 s under load) | yes: the window at its place in the room, symbol, text, button, toggle (`vis8-window.png`) | no: a touch through the display stream's touch screen on the button (`a8`) was not delivered to the app (no "window tap") | the window's glass is drawn as an opaque dark grey panel; visionOS input (§9 Q1–Q3) |
| VisionVolume (ours) | yes (`a2`, 4.0 s) | yes: the blue box (`vis8-volume.png`); the metallic sphere is drawn in some frames and not in others, and reflects black | not tried (no visionOS input) | the reflections (environment cube, §10.20.11 item 4); the sphere's missing frames like §10.20.9 |
| VisionImmersive (ours) | yes (`a3`, `a9`): `openImmersiveSpace` → `opened`, "immersive space appeared", "immersive content made" | yes: the lit sphere and the ring of eight cubes in the room (mixed style), the app's window stays (`vis8-immersive.png`) | not tried | — |
| Safari | yes (`a4`, 0.5 s) | yes: the window with its toolbar ornament, the start page behind a "what's new" sheet with Continue, and the system keyboard (RealityKeyboard) with some keys drawn without their key cap (`vis8-safari.png`) | not tried | the missing key caps (as single home-view icons, §10.20.7) |
| Settings | yes (`a6b`, 1.4 s; `a6` did not reach the room in 480 s at a load of 110–190) | yes: sidebar (Apple Account, General, Apps, People, Environments, …) and the General pane (`vis8-settings.png`) | not tried | — |
| Files | yes (`a7`, 2.7 s) | yes: sidebar (Recents, Shared, On My Apple Vision Pro, Recently Deleted, tags), "No Recents" (`vis8-files.png`) | not tried | — |
| Photos | starts (`a5`, `a10`; 1.2 s), then ends with a Swift fatal error | no | — | "Volume containing photo library …/data/Media/ has insufficient free space 0", then `PHPhotosErrorDomain` 3305 in `PhotoLibraryManager` (fatal). A trace of Photos (`a10`) shows no local call that could report the 0 (a `getattrlist` walk of the path with common attributes, then the error's logging): the value reaches it in a reply from a daemon. Not fixed |

The guest's other fatal conditions in these boots were the known ones
(intelligencetasksd, dasd, AppIntentsLiveEntityService).

#### 10.21.4 sRGB storage writes and reads (§10.20.11 item 2; change 3)

The faithful version: the translator allows it cleanly, because a texture's
64-bit value only needs its low 32 bits for the heap index. An sRGB texture
with `shaderWrite` (`RGBA8Unorm_sRGB`, `BGRA8Unorm_sRGB`, the packed ABGR,
`R8`, `RG8` forms) now gets storage views in the unorm format of its layout
(the image already had storage usage and `VK_IMAGE_CREATE_EXTENDED_USAGE_BIT`
for R7's unorm views), and bit 32 of its value marks it. ycode-airc's float
storage writes encode linear to sRGB and its storage reads decode when the
bit is set, computing both forms and selecting with `OpSelect`
(`metal-shaders.md` §4.4). Views in another format (R7's `RGBA8Unorm` views
of the room's textures) are unchanged: their bytes land as written. GPU test
`SRGBStorageGPUTests` (a kernel of ours from `interface-forms.sh` case 6):
linear (0.5, 0.25, 2⁻⁹, 0.5) written into an `RGBA8Unorm_sRGB` texture
stores (188, 137, 6, 128) and reads back (0.503, 0.250, 0.0018, 0.498); into
an `RGBA8Unorm` texture (128, 64, 0, 128). Without the change the sRGB
texture had no storage view and kept zeros. No guest kernel that writes an
sRGB texture directly was seen in R7/R7b (§10.20.4); this round did not look
for one, so the change is so far exercised by the test only.

#### 10.21.5 Snapshots and argument buffers (§10.20.11 item 6; change 4)

`snapshot.md` §8 (2026-10-29 paragraph): the snapshot records each live
texture's heap run and each sampler's slot; the restore reserves them on
the fresh back end before the replay (`IndexAllocator.claim`), so every
texture, view and sampler gets its old ID in any creation order; it also
records every argument-encoder member the host wrote (argument buffer,
offset, kind, object, the call's offset, the value) and after the replay
writes again each member whose value changed (buffer GPU addresses, which a
new Vulkan device chooses, cannot be kept). The 8 × index rule is unchanged
(Q25 not answered). Tests `SnapshotReplayTests.restoreKeepsSlotsAndRewritesArgumentMembers`
(NullBackend with different IDs before and after),
`VulkanBackendTests.reservedHeapSlotsGoBackToTheirObjects` (on the Thor's
GPU: a texture and a sampler of other handles made first get other slots;
the reserved ones, made in reverse order, get exactly theirs),
`IndexAllocatorTests`.

A warm boot of the visionOS room is not possible yet for another reason:
the Metal service refuses a snapshot while shared-event handles are exported
or shared-texture handles opened (`snapshotBusyReason`), and wakeboardd's
layers always have both (§10.12.2, §10.11.3). So the visionOS device boots
cold every time; the change makes the restore's argument buffers right
once those handles can be saved.

On iOS 27.1 the restore path with the change works (`s1`, iPhone 18 Pro,
load average about 150): cold boot to the home screen in 358.7 s, stop
snapshot; the restore reached the home screen in 15.7 s ("restore: Metal: 9
processes, 167 objects … heap slots 40 kept, 0 texture IDs changed;
argument-encoder members 0 …"; 50 buffer GPU addresses changed, as before)
and launched Settings, which drew its list.

#### 10.21.6 iOS 27.1 check

Shared code changed (the Vulkan back end's slots and sRGB views, the
translator's storage reads and writes, the Metal service's snapshot):
`s1`/`s1-r` above (cold boot, stop snapshot, restore, Settings launched and
drawn) and `i1` (cold boot, home screen at 272.2 s under a load average of
174, Safari launched through ylaunch 20 s later). No GPU hang report, device
loss or Vulkan error in either; guest fatal conditions intelligencetasksd
and AppIntentsLiveEntityService only (known).

#### 10.21.7 What remains

1. §9 Q27: whether the reference's order differs; until then the home guard
   stays on for visionOS device runs. *(Answered by Q27; fixed in R11,
   §10.26.1: assistantd waits for the shell; the guard is a logged
   fallback.)*
2. The window's glass background renders as an opaque dark grey panel (the
   room does not show through or blur behind it); the reference draws
   windows as glass panels (§4.1). Not examined. *(Reference appearance:
   §10.23.3. Done in §10.24.)*
3. Metallic surfaces reflect black (the volume sample's sphere): most
   likely the `RGBA16Float` cube of `generateClampedMap` that R7 read as zero
   (§10.20.11 item 4). Not examined further. *(Reference: §10.23.4. Done
   in §10.24.)*
4. Input: visionOS apps cannot be operated yet (pose, selection and
   manipulation messages, §9 Q1–Q3; V-10 to V-12). A touch on the display
   stream's touch screen does not reach a visionOS app (`a8`). *(Formats
   and what Ycode must do: §5.5.)*
5. Ycode's PIF generator: synchronized folders (Xcode 16 projects) are built
   without their sources.
6. Photos ends at start: the free space it is told is 0 (§10.21.3); the
   next step is a trace of the photo library daemon's answer. *(Fixed in
   R11, §10.26.2: getattrlist's volume sizes on "/".)*
7. Shared-event and shared-texture handles in snapshots (§10.21.5): needed
   for a visionOS warm boot.
8. §10.20.11 items 1 (parts of the room missing in some frames; seen again
   in `a2`), 3 and 5 are unchanged; the room's frame rate and pacing and the
   visionOS canvas controls (`device-hub.md` §I.8) were not worked on.

### 10.22 Round ARGBUF-IMPL: argument buffers by the layout description; the room's missing parts (agent ARGBUF-IMPL, 2026-10-30)

Clean-room work on Ycode's own simulator on the Thor: branch `argbuf-impl`
on the main line `e27c4e9c`, Ycode's simulator only, no reference tool,
nothing under `research/`. The visionOS device was a fresh copy of R7b's
device for each boot. Boots `v1` to `v7` were cold, frames every 5 s, and
other agents' boots kept the load average at 15 to 100.

#### 10.22.1 Q25: argument encoders by op 16's description

Ycode now builds argument buffers as `metal-sim-protocol.md` §4.3.8 says
(implementation in §4.3.9). Op 16's description is parsed into a member
table, op 17 answers alignment then length, op 19 writes each member at
its table offset (24-bit index, range forms), and op 35 answers the
member's offset. This replaces R7b's rule (§10.20.7), which put member
*n* at 8 × *n* and answered op 17 with the halves swapped, so that every
encoder looked 8 bytes long with an alignment of 24. Under Ycode,
backboardd's one layout and those of its RealityKit clients parse as the
reference's: 15 buffers, indices 0–14 at 0–112, length 120, alignment 8.
That layout is dense, so the members land where R7b's rule put them. The
home view came up with its icons and names in `v1`, `v2`, `v3`, `v5` and
`v7`
(`v4` did not reach the room in its 450 s, at a load average near 100).
As before, a single icon is missing in some frames (§10.20.10, `f2`). No
op-19 write failed and no index fell outside a table. §10.20.11 item 6 is
done. A restore still writes the recorded members again at their byte
offsets (`snapshot.md` §8). Layouts and encoders now keep their
description in the snapshot, so encoders keep their tables across a
restore.

#### 10.22.2 Q26: the room's missing parts follow the visibility results (fixed)

OBS-ARGBUF found that the reference never leaves a room part out (§9 Q26).
Ycode's argument-buffer change did not change the cycle: `v1` lost parts
in 5 of 29 room frames. The guest decides from what the host gives back,
so two diagnostic switches were added to the Vulkan back end
(`VulkanVisibility.swift`, default off):

- `YCODE_DEBUG_VISIBILITY_FORCE=<u32>` writes this value into both words of
  every counted visibility slot instead of the query's count.
- `YCODE_DEBUG_VISIBILITY_STATS=1` reads every segment's query result back
  after its command buffer completes and logs, every 20 s, how many were
  zero. The counts are kept per pass (its size, attachments, the depth
  attachment's actions and clear value, its depth states, its kinds of
  draws), slot and segment length.

Frames with parts missing were counted from the 240 × 135 thumbnails as
before (§10.20.9). About 34 % near-black means the walls are missing;
about 5 % means the furniture is missing.

| Boot | Switch | Room frames | With parts missing |
|---|---|---|---|
| `v1` | none | 29 (290–430 s) | 5 (walls 4, furniture 1) |
| `v2` | force 1 (every slot "visible") | 34 (280–445 s) | **0** |
| `v3` | force 0 (every slot "not visible") | 36 (270–445 s) | 7 (walls 4, furniture 3) |
| `v5` | statistics | 83 (185–595 s) | 20 (walls 7, furniture 13) |
| `v7` | statistics, **with the fix below** | 68 (260–595 s) | **0** |

**Every visibility result Ycode produced was zero.** In `v5`, all counted
segments were in backboardd's 3840 × 2160 4× pass: one colour attachment
and a 4× `Depth32Float_Stencil8` depth attachment, cleared to 0.0 and not
stored. Its depth states compare Greater, GreaterEqual or Equal (reverse
depth), some with stencil. Each segment was one draw into slots 0 to 32 of
16- to 40-byte buffers. The last summary listed 7 875 results, and none
was non-zero. Forcing them to zero changed nothing, because they were
already zero. Forcing them non-zero removed every missing part. So the
guest culls a part whose occlusion box it believes hidden. For a few
frames it leaves that part out, then draws it again. The reference
reports the boxes visible, because it never leaves a part out. Ycode's
boxes passed no samples.

**Cause and fix.** `v6` added each draw's depth state, cull mode and
pipeline formats to the `YCODE_DEBUG_PASS_DRAWS=3840x2160` lines. Every
counted segment is one draw of 36 indices with `vsOcclusionQuery` and **no
fragment function**. The draw uses depth compare GreaterEqual with no
write, back-face culling, and a pipeline with one colour attachment and
`Depth32Float_Stencil8` at 4 samples. The same pass has other draws
without a fragment function: stencil masks (`fullScreen2Vert`, depth
Equal, stencil replace), `vsMeshShadowPatchReceiver`, `vsUnlit` and
`vsManualInstancing`. Ycode's Vulkan back end built every pipeline without
a fragment shader with rasterizer discard on. So these draws made no
fragments: no depth or stencil writes, and no occlusion samples. In Metal,
a pipeline without a fragment function still rasterizes (`fragmentFunction`
nil is depth- and stencil-only rendering; only `rasterizationEnabled` NO
turns rasterization off; Metal documentation, level 1). No render pipeline
in these boots sent a descriptor key that Ycode does not model (no
"descriptor key … is not modelled" line), so none turned rasterization
off. Now a pipeline without a fragment function, and with a depth or stencil
attachment format, is rasterized with colour writes off. A pipeline
with neither stays discarded, since it can only be a vertex function that
writes buffers. This covers monolithic pipelines and pipeline libraries
(the fragment-shader part then has no stage).
`YCODE_VULKAN_VERTEX_ONLY_DISCARD=1` restores the old behaviour. GPU test
`VulkanBackendTests.depthOnlyPipelinesRasterize` checks a depth-only draw:
its visibility slot is not zero and the colour attachment is unchanged.
The test fails with the switch. In `v7`, every result in the statistics
was non-zero (the last summary: 54 non-zero, 0 zero) and no room frame
missed a part. The stencil masks and depth-only draws now take effect too.
Their visible effect (shadow receivers, masked regions) was not studied.

#### 10.22.3 What remains

1. §10.20.11 item 1 (the missing parts) is fixed (§10.22.2). Still to
   check: what the newly drawn stencil masks and depth-only draws change on
   screen against the reference (shadows under the furniture, masked
   regions), and how the extra draws affect the frame rate.
2. `metal-sim-protocol.md` §13 item 9: the member type codes inside a
   pointee struct (iOS WeatherPoster). Ycode skips such pointees.
3. `metal-sim-protocol.md` §13 item 10: the pipeline key, if any, for
   `rasterizationEnabled` NO.
4. §10.20.11 items 1a–5 are unchanged; items 1 and 6 are done.

### 10.23 The reference answers Q1–Q3: input, ARKit pose, rooms; glass and metal for R10 (agent OBS-VISION-INPUT, 2026-10-31)

Dirty-room work on the Mac: Xcode 27.1, visionOS 27.0 (24M362), one test
device `ycode-test-vision3-a` (Apple Vision Pro 4K), created with `simctl`,
booted twice (the second time with our HID recorder inserted and the
Museum room preset), then deleted. No Device Hub window, no GUI clicks;
Ghidra, the IPSW and the reference tools folder were not opened; no
disassembly. The results are in §5.5; this section records how they were
found and adds the reference appearance of glass and metal.

#### 10.23.1 Method

| Tool (ours) | Where it runs | What it showed |
|---|---|---|
| `vhid` | Mac | sends Indigo messages built by the exported builders, through SimulatorKit's legacy HID client; `script` mode for timed sequences |
| `bprobe` | Mac | the builders' argument order: each builder called in a child process with recognisable values in every argument register, the result hex-dumped |
| `vhm` | Mac | vhmdd's protocol over a sim-to-host XPC connection |
| `hidrec.dylib` | guest, inserted at boot | the events the HID bundle dispatches, printed by the events themselves |
| `InputProbe.app` | guest | every SwiftUI/UIKit/RealityKit input callback and the ARKit device anchor |

Sources: `research/experiments/visionos/input/` and
`research/experiments/visionos/InputProbe/`.

#### 10.23.2 Findings in order

1. A message with target 0 made backboardd raise an exception listing its
   known targets (50, 13, 11, 51, 302, 300, 200, 14, 12, 60, 100,
   0x40000001, 301) and exit; the UI restarted. Targets 300, 301, 302 select
   services 05, 06, 07.
2. A pose message moved the view; translation (0, 1.6, 0) lifted the eye
   1.6 m above the default (above the ceiling); identity gave the default
   view; repeated messages gave identical frames; the home view was
   dismissed "out of bounds" after the jump and Home brought it back.
3. A selection message with the ray along (0.05, 0.04, −1) hovered the home
   view's window; backboardd logged the ray and both manipulators inactive.
4. A collection message mapped its flags to "Pinching", "Allow direct
   interactions" and chirality per hand; a pinch began a contact at the
   ray's hit point (stage frame, 2 m in front for the app window).
5. Our app received every gesture of §5.5.5. With the camera at (1, 0.5, 2)
   turned 30° left, a camera-space ray missed and the stage-frame ray hit
   (§5.5.1).
6. ARKit's anchor ignored four pose messages and followed vhmdd's
   `set_pose` exactly; `set_pose` did not move the view (§5.5.3).
7. Guest clients of vhmdd are refused; the host connection answered
   `get_pose`, `request_environments` and `set_active_environment`
   (Kitchen (Night) loaded live) (§5.5.4).
8. The room preference set to `MuseumDay` before the second boot gave the
   Museum (Day) room (§5.5.4).
9. The recorder printed the events of §5.5.2 for a pose, a selection, a
   collection with both hands and a dial turn.

#### 10.23.3 Glass: what the reference window looks like (for VISIONOS-R10)

Screenshots of the same camera pose with and without our app's window
(Living Room (Day)), compared inside the panel:

- The panel is **translucent**, never opaque: inside it each colour channel
  is ≈ 0.58 × the background blurred with a Gaussian of σ ≈ 128 px (at
  3840 px width; the window was about 2.6 px per point) + 49 (8-bit sRGB);
  R² 0.99 on a strip in front of the television, where the background has
  contrast. Smaller or larger blurs fit worse. The television shows through
  as a soft dark area; wall edges behind the panel become soft gradients.
- A thin light rim (2–4 px) follows the panel's rounded edge.
- The parameters match CoreMaterial's content-glass recipe file
  (`platformContentGlass.materialrecipe`, a property list, level 2):
  backdrop **blur radius 45** (points) and a 4 × 5 **colour matrix** whose
  rows sum to 0.629 with an offset of 0.235 in each colour row (a
  slightly desaturating darken-and-lift: grey g ↦ 0.629 g + 0.235). 45 pt ≈
  116 px at the measured scale; 0.629 and 0.235 (= 60/255) agree with the
  fitted 0.58 and 49 within the sRGB/P3 and blur-shape differences.
  Variants `…Darker`, `…Lighter`, `…UltraDarker` exist beside it.
- The glass is made in the guest: the host receives only the composed frame
  (§4.2). The backdrop it blurs is the rendered room (and anything behind
  the window). CoreRE also ships a RealityKit glass material
  (`glass.rematerialdefinition`, JSON: technique "Glass", fragment entry
  `fsBlurTransparent`, base colour from the render graph's input colour);
  which of the two paths draws app windows was not determined.

**What R10 should match:** blurred (σ about 45 pt in window points),
darkened-and-lifted backdrop per the matrix above, thin bright rim; an
opaque grey panel is wrong.

#### 10.23.4 Metal: what the reference reflects

- In a volume, a white metallic sphere with roughness 0 mirrors a room
  image (walls, ceiling lights, floor), not black and not the app window
  beside it; with roughness 0.5 it is a soft white. In Kitchen (Night) the
  reflections are dark and warm.
- Each room ships one image-based-lighting probe,
  `AssetData/0/*_IBL_Linear_Display-P3_envProbeMap.ktx` (level 2): KTX 1,
  **cube** (6 faces), **256 × 256, 9 mip levels**, `GL_RGBA16F`
  (= **`MTLPixelFormatRGBA16Float`**), key/value `ToolVersion` "1" and
  `PositiveZForward` "true"; linear HDR Display-P3 (Living Room (Day):
  face means 0.39–1.14, maximum 27.2); the file's mips are plain averages.
  It is the only RGBA16Float cube in a room asset, so it is the expected
  input of the `generateClampedMap` kernel that R7 saw writing an
  RGBA16Float cube (§10.20.1), followed by `generateMipmaps`. This was not
  observed directly (no Metal recorder in the reference this round).
- Room albedo textures: KTX 1 2D, `GL_COMPRESSED_SRGB8_ALPHA8_ASTC_6x6`
  (0x93D4), 4096² with 13 levels or 1024² with 11.

**What R10 should check:** that the probe's six faces and nine levels reach
the RGBA16Float cube (half-float uploads per face and level), and that the
clamp kernel's output is non-zero; a correct cube makes the mirror sphere
show the room.

#### 10.23.5 Not answered

1. The meaning of the per-hand 16-bit `extra` value and of the flag bits
   above bit 0 (send what §5.5.2 lists).
2. Whether the Manipulator service's events are used by anything.
3. What the Digital Crown changes (no consumer reacted to a dial event at
   the home view or with a mixed immersive space).
4. Device Hub's own message rate and hand placement (not observed; Ycode
   decides, §5.5.7 item 4).
5. Which path (Core Animation backdrop or RealityKit glass) draws window
   glass, and a Metal-level confirmation of the cube's source.

### 10.24 Round R10 under Ycode: glass and metal (agents VISIONOS-R10 and VISIONOS-R10b, 2026-10-31)

Clean-room work on Ycode's own simulator on the Thor (branch `visionos-r10`;
R10 stopped overnight with one work-in-progress commit, R10b reviewed it,
merged the main line 117eee37 and finished the round). Boots: R10's `w1`–`w3`
(the window sample, `org.ycode.samples.window`) and `m1`–`m3` (the volume
sample, `org.ycode.samples.volume`: a blue box and an orange metallic sphere
of roughness 0.2), R10b's `b1` (window) and `b2` (volume), each a cold boot
of a fresh copy of R7b's device with the app installed and launched 40 s
after the home view; iOS 27.0 `i0`, iOS 27.1 `i1`, watchOS 27.0 `wa1`.
No Apple simulator, Xcode, Device Hub or reference tool was run or opened,
nothing under `research/` was read, nothing was disassembled, and the
guest's shader logic was not read: guest functions were seen through
ycode-airc's reflection (names, binding types, access, constexpr sampler
states), the pass probe's read-backs (§10.20.3) and the new frame map.
The reference's appearance is §10.23.3–§10.23.4. Level 3 throughout.

Screenshots (not committed; beside the worktrees on the Mac):
`visionos-r10-before-{window,volume}.png` (the main line before R10),
`visionos-r10-wip-{window,volume}.png` (R10's commit, `w3`, `m3`),
`visionos-r10-after-{window,volume,home}.png` (`b1`, `b2`).

#### 10.24.1 The glass pipeline under Ycode

A frame map (§10.24.5) of backboardd's frame command buffer with an app
window gave the glass's data flow (`w1`, `w3`):

| Pass | What it does |
|---|---|
| 5 | the room into backboardd's 3840 × 2160 target (§10.20.1) |
| 8 | `kernelSFBPassthroughDownsample` into a 40 × 32 × 2 `RGBA16Float` array |
| 11 | the room again, at 160 × 128 × 2 (one layer per eye) |
| 14 | `kernelSFBBilerpDownsample4xWithPassthrough` (160 × 128 → 40 × 32), `kernelSFBNoReprojectAndNoBlend`, then `kernelSFBBlurAndFilter` into a 40 × 32 × 2 `RGBA16Float` array (and three more of that size) |
| 17 | the 4× pass: `fsCALayer` draws of the window sample the blurred 40 × 32 array (`passthroughBlurColor`, `vcaBlurColor`, `vcOnlyBlurColor`) |

So the window's glass is a 40 × 32 blur of the room per eye, sampled
under the window: one texel covers 96 × 67.5 pixels of the 3840 × 2160 view.

#### 10.24.2 Causes and fixes

1. **The blur kernel wrote nothing (R10).** `kernelSFBBlurAndFilter` has a
   threadgroup argument whose metadata node gives no `air.address_space`
   (only its pointer is in address space 3) and the location index of a
   real device buffer. ycode-airc took the node's default (device) and
   bound it as a second buffer 0, so the kernel's threadgroup strip was a
   device buffer and its output was never formed: the panel was an opaque
   dark grey (the `fsCALayer` tint over zeros). A buffer argument whose
   pointer is in address space 3 is now threadgroup memory whatever its
   node says (reflection `by_pointer_address_space`). After the fix the
   probe read the blur's output non-zero (`w3`: means 0.53, 0.51, 0.47 on
   the left eye's layer) and the panel showed the room, but in visible
   blocks of 96 × 67 pixels (`visionos-r10-wip-window.png`).
2. **Every guest constexpr sampler was nearest, clamp to zero, LOD 0
   (R10b).** The blocks are the 40 × 32 texels sampled without filtering.
   `fsCALayer`'s samplers are constexpr samplers, and ycode-airc's
   reflection gave every constexpr sampler of every guest function state
   0 (818 in R10's translation cache, 404 in an iOS 27.0 cache). The
   functions the guest sends hold the state as a plain `i64` global, not
   the `[2 x i64]` of our toolchain, and ycode-airc read element 0 of an
   aggregate only (`metal-shaders.md` §3.7). Every guest constexpr sampler,
   on every platform, was therefore nearest, clamp to zero (transparent
   black outside the texture) and LOD maximum 0 (level 0 only). Now the
   state is read as bytes through the data layout from any initializer
   form. Re-translating visionOS RealityKit's dumped functions gives the
   real states (`fsCALayer`: linear clamp-to-edge `0x807bff0000082a49`,
   repeat, anisotropic, and bicubic `0x807bff0000081449`; `fsUnlit`: linear
   repeat). Filter value 2 is `filter::bicubic` (our own shader); Ycode
   samples it linearly.
3. **Metal reflected black (R10).** The volume's sphere samples the
   environment cube that `generateClampedMap` writes from the room's
   probe (§10.23.4). The kernel reads the probe cube with `read()`, which
   ycode-airc does through the storage view (Vulkan cannot fetch a cube
   face from a sampled view). The probe cube is `shaderRead` only, so it had
   no storage view and the kernel read the dummy image: zeros. Cube
   textures now always get storage usage and views when their format
   allows (`YCODE_GPU_CUBE_STORAGE=0`: the old rule). Probe `m3`: the
   source cube (256², 9 levels, `RGBA16Float`, usage `shaderRead`) has
   face means 0.39 to 1.14 and a maximum of 27.2, the reference's numbers
   for Living Room (Day) (§10.23.4); the clamp kernel's output holds them
   clamped to 16. With R10's fix alone the sphere reflected the room
   sharply, with saturated green and blue specks at its rim; with the
   sampler fix (mip levels and filtering now take effect) the reflection
   is the soft one a roughness of 0.2 gives and the specks are gone.

The first `generateClampedMap` dispatch covers 300 714 threads (its
constants: 0, 300 714, 256, 3, 0, 16.0) of the 393 216 texels of level 0,
and in `m3`'s probe of that command buffer faces 0–3 were written, face 4
in part and face 5 not. The sphere shows the room in every direction a
few frames later, so the rest is presumably done by later dispatches;
this was not traced.

#### 10.24.3 Against the reference

| | Reference (§10.23.3–4) | Ycode before | Ycode after (`b1`, `b2`) |
|---|---|---|---|
| Window panel | translucent; each channel ≈ 0.58 × Gaussian(σ ≈ 128 px) of the background + 49, R² 0.99 | opaque dark grey, uniform (38, 38, 38) | translucent: on a strip in front of the television stand (x 1100–2700, y 1480–1640 of 3840 × 2160) against `b2`'s frame of the same pose, best fit at σ 128–160 px: 0.50–0.54 × + 50–57 (red), 0.58–0.64 × + 34–44 (green), 0.65–0.74 × + 16–29 (blue), R² 0.97–0.995 |
| Rim | thin light rim, 2–4 px | none | a light line along the rounded top edge and a 2–3 px brighter band at the sides (≈ +10 over the panel) |
| Metal sphere (roughness 0.2) | mirrors the room; rough metal soft | black | orange-tinted soft reflection of the room |

The blur width and the darken-and-lift match within the fit's
uncertainty; Ycode's panel is somewhat warmer (a lower blue offset). The
recipe's colour matrix is applied in the guest's functions, so the
difference may come from the P3/sRGB handling of the composed frame or
from the room's own colours under the fit; it was not pursued.

The stencil masks and depth-only draws that §10.22 enabled: in `b1` and
`b2` the room, the home view (`visionos-r10-after-home.png`, its tab bar
now on glass too) and the samples show no masked-out region and no
artefact; the box and sphere cast no visible shadow on the room. The
reference facts (§10.23) say nothing about shadows, so whether one is
missing is not known (§10.24.6 item 2).

#### 10.24.4 Changes

1. Translator: threadgroup buffers by the pointer's address space (R10;
   `interface-forms.sh` case 7).
2. Translator: constexpr sampler states read through the data layout from
   any initializer form; `state_source` and `state_type` in the reflection;
   filter value 2 named `bicubic` (`interface-forms.sh` case 8: a plain
   `i64` and a `[2 x i64]` sampler in one kernel). Host: bicubic filtered
   linearly (`VulkanBackendTests.reflectionDecodes`).
3. Vulkan back end: storage usage and views for every cube texture whose
   format allows (R10; `VulkanBackendTests.readOnlyCubesGetStorageViews`).
4. Diagnostics: the frame map (§10.24.5).

#### 10.24.5 Frame map (off by default)

`YCODE_GPU_FRAME_MAP=<after s>,<count>[,<min commands>]`: from that many
seconds after the first submission, the next *count* command buffers with
at least *min commands* (default 1) draws, dispatches and blits are
described as in a hang report (passes, attachments, functions, bound
buffers and textures), before their replay. Nothing is copied, so unlike a
probe it does not delay the guest; use it to find the passes, then probe
one function by name.

`YCODE_GPU_FRAME_MAP_FILE=<path>` (XR-ICONS, §10.29) asks at any moment: when
the file appears, its first word is how many command buffers to describe
(default 40), its second the least commands each must have (default 1); the
file is removed. A script or a headset run can ask for the frame on screen now.

#### 10.24.6 Other platforms

The sampler change touches every platform's guest functions. Cold boots
with the round's build, under a load average of 50 to 165 from other
agents' boots: iOS 27.0 `i0` (iPhone 18 Pro, a copy of `ios27/devices/p18`)
home screen at 292.9 s; iOS 27.1 `i1` (the `duo271` device) at 270.2 s;
watchOS 27.0 `wa1` (a new Apple Watch Series 12 46 mm) at 111.7 s. No GPU
hang report, device loss or Vulkan error; guest fatal conditions in
intelligencetasksd and SettingsSearchReindexService only (known). The
iOS dock and search-field glass, the widgets and the watch face render as
in earlier rounds' frames (iOS 27.0 compared with `ios27`'s `c1-p18-first`
at the same crop: the dock glass is unchanged, the Maps widget now shows
its map where the earlier boot still had the placeholder grid).

#### 10.24.7 What remains

1. Ycode's glass is a little warmer than the reference's (§10.24.3), and
   the rim was compared by eye only.
2. Shadows: whether the reference's volume content casts shadows on the
   room (`vsMeshShadowPatchReceiver`, `ksShadowOcclusionReproject` run under
   Ycode); a dirty-room look at a volume over the floor would settle it.
3. Whether the reference's `generateClampedMap` covers the cube in one
   dispatch (§10.24.2, end).
4. Bicubic samplers are filtered linearly; `VK_EXT_filter_cubic` where the
   driver has it would match better.
5. `metal-sim-protocol.md` §13 items 9 and 10 are unchanged: no visionOS
   boot of this round logged an argument layout it did not parse or a
   render-pipeline key it does not model (only compute keys 1 and 2, as
   before).
6. §10.21.7 items 2 and 3 are done; items 1, 4 (R9b), 5–8 are unchanged.

### 10.25 Round R9 under Ycode: visionOS input, the ARKit pose and the rooms (agent VISIONOS-R9, 2026-10-31)

Clean-room work from §5.5 and §10.23 (implementation: §5.5.8), on Ycode's
own simulator on the Thor: the Apple Vision Pro device of R11 (24M362),
the round's build of `ycode-simd` and the HID bundle, and our own probe
app `VisionInput` (`ycode/Samples/VisionSamples/VisionInput`, built with
`xcodebuild -sdk xrsimulator`): a window with a Button, `onTapGesture`,
`SpatialTapGesture`, `DragGesture`, `MagnifyGesture`, `RotateGesture`
tiles, a `TextField` and a RealityKit box (`InputTargetComponent`,
collision), and a mixed immersive space opened at launch with a sphere
(radius 0.2 m at (−1, 1, −1.6)) and an `ARKitSession` with
`WorldTrackingProvider` that logs `queryDeviceAnchor` every 0.5 s when it
moves. Each callback logs through `os.Logger` (subsystem
`org.ycode.samples`); a guest log stream records them. Boots: `r1`
(Living Room (Day), driven with the control socket's `vision` commands),
`r2` (`--room MuseumNight`), `r3` (the Linux viewer under a private X
server, driven with real X pointer and key events). No Apple simulator,
Xcode GUI, Device Hub or reference tool was run or opened; nothing under
`research/` was read; nothing was disassembled. Level 3 throughout.

#### 10.25.1 Results (run r1, scripted driver)

| Input (`vision …`, display points) | What the app logged | §5.5.5 expectation |
|---|---|---|
| `tap 712 470` (Button) | `button action 1` | Button action |
| `tap 960 468` (tile) | `onTapGesture` | `onTapGesture` |
| `tap 1206 468` | `spatialTap location 169.243 97.882 location3D z 0.005` | location in the view, z ≈ 0 |
| `pinch 712 620`, `drag 782 620` (+70 points ≈ 0.1 m), `release` | `drag ended translation 70.195 0.000 predicted 162.326 0.000` | about 70 pt per 0.1 m at 2 m; predicted set |
| `magnify 960 620 1.5` | `magnify ended 1.500` | s₁/s₀ |
| `rotate 1206 620 30` | `rotate ended -30.000 degrees` | −θ |
| `tap 1195 810` (the box) | `entity tap window-box …` | entity tap |
| `tap 345 885` (the immersive sphere) | `entity tap space-sphere …` | `targetedToAnyEntity` tap |
| `tap 744 758`, `type hello` | `text "H"`, … `text "Hello"` (auto-capitalised); the system keyboard appeared | keys as on iOS |
| `gaze 1206 468` | the tile's hover highlight; no callback | system hover only |
| `pose 0.3 0 0.2 15 0` | `device anchor position 0.300 1.600 0.200 forward -0.259 0.000 -0.966` (the view turned and moved at the same time); `get-pose` returned the same matrix | anchor = stage transform × `set_pose` |
| `reset` | `device anchor position 0.000 1.600 0.000 forward 0.000 0.000 -1.000` | identity |
| `room MuseumDay` | `synthetic_environment_did_load` within 1.6 s; the room changed live; vhmdd logged "bridge changed environments" for `rooms` | §5.5.4 |
| `home`, `home` | the immersive space closed, then the home view | Home toggles the home view |
| `dial ±5` ×5 | Scroll events from DigitalDial (bundle log); no consumer reacted | as the reference (§10.23.5 item 3) |

The bundle found every IOHIDFamily function it looks up (vendor-defined,
generic, scroll, translation, rotation constructors; float, flags and
phase setters). vhmdd accepted Ycode's host connection on the first try:
`get_pose` answered identity after boot, as in the reference.

Screenshots: `visionos-r9-gestures-camera-moved.png` (after the gestures,
camera at (0.3, 0, 0.2) turned 15° left: Button 1, Drag 70 × 0, Magnify
1.50, Rotate −30°, "Hello" with the system keyboard),
`visionos-r9-room-museum-live.png` (Museum (Day) after the live switch).

#### 10.25.2 The room before the boot (run r2)

`ycode-simd --room MuseumNight` wrote the preference; the boot came up in
Museum (Night) (`visionos-r9-room-before-boot.png`), and a tap on the
Button reached the app. `vision rooms` listed the six rooms.
On a stopped device, `ycode-simd --device DEV --vision room KitchenNight`
wrote `{activeSyntheticEnvironment: KitchenNight}` into the preference file
(checked with `plistlib`).

#### 10.25.3 The Linux viewer with real pointer input (run r3)

The Linux `ycode-sim-viewer` (SDL 3) ran on a private X server on the Thor
(TigerVNC's `Xtigervnc` with no listening port, our own display), its
window 1660 × 1000 (scale 0.852), connected to the run's display server.
`xdotool` sent X pointer motion, button and key events at the targets'
window points (our `xdrive.py`), so the viewer's own `SpatialInteraction`
made every message:

| X input | The app |
|---|---|
| click Button / tile / SpatialTap tile | `button action 1`, `onTapGesture`, `spatialTap location 169.906 98.481 location3D z 0.005` |
| drag 70 display points | `drag ended translation 69.435 0.000 predicted 89.663 0.000` |
| Alt-drag 52.5 points right | `magnify ended 1.503` |
| Alt-drag along a 30° arc | `rotate ended -30.151 degrees` |
| click the box | `entity tap window-box …` |
| click the text field, type "viewer" | `text "Viewer"` |
| Alt+W twice | anchor z −0.050, then −0.100 |
| Ctrl-drag 50 points right | anchor forward (0.175, 0, −0.985) (10° right) |
| wheel up | anchor y 1.640 (0.04 m up) |
| Alt + wheel down ×2 | two dial events of 20 (bundle log) |
| Alt+R | anchor back to (0, 1.6, 0), forward −Z |

Input-to-picture latency in the viewer's status line: about 330 ms under a
load average of 40–60. Screenshot of the viewer window:
`visionos-r9-linux-viewer.png`. The macOS viewer and the IDE canvas use
the same `SpatialInteraction` through `DeviceView+Spatial.swift`; they were
built and unit-tested on the Mac but not driven with a pointer this round
(no GUI automation on the Mac).

**Tests.** Unit tests for the messages, the stage-frame math, the
interaction, the HID bodies and the vhmdd client (against a fake vhmdd in
a second host task): `SpatialInputTests`, `HIDHostServiceTests.visionBodies`,
`VisionHMDClientTests`. Thor debug suites DarwinABI, DarwinKernel, Simd,
SimFeatures, HostServices pass; the x86 full suite passes; the Mac full
suite passes except `RunTestTextsR42Tests.remoteSimulatorRunSequence`
(the remote destination's name on this Mac; fails alone too, untouched by
this round); `lint.sh` exits 0. iOS and watchOS input paths are unchanged
(their HID and button tests pass).

#### 10.25.4 What remains

1. (Fixed after r3: the Linux viewer's control row shows Reset Camera
   instead of Rotate on a Vision Pro.) The reference's interaction modes, Capture Pointer and Simulated Scenes
   inspector are not reproduced (Ycode uses modifiers, §5.5.8 item 4).
2. `extra` and the flag bits above bit 0 are sent as §5.5.2 lists them
   (meaning unknown, §10.23.5 item 1); the Manipulator service is
   published and never used.
3. No consumer of the Digital Crown was found (as in the reference).
   *(Answered in §5.5.9: crown rotation is vhmdd's
   `change_immersion_level`; presses are button source 0 with real timing.)*
4. Hand orientation is the camera's; a hand's own turn (wrist roll) is not
   offered by any viewer.

### 10.26 Round R11 under Ycode: the home view in every boot; Photos' free space (agent VISIONOS-R11, 2026-11-01)

Clean-room work on Ycode's own simulator on the Thor (branch `visionos-r11`
on the main line 117eee37; the visionOS device of R10, booted on 24M362;
the iPhone 18 Pro device of the iOS 27.0 rounds). One of this round's
devices was booted at a time; other agents' boots ran beside them (load
averages 2 to 60). Boots: `p1` (Photos), `e1` (background CPUs), `s1`,
`c1`–`c10` (the series), iOS `i1`, watchOS `w1` and visionOS `m1` (after
merging the main line). No Apple simulator, Xcode, Device Hub
or reference tool was run or opened, nothing under `research/` was read
and no Apple binary was inspected. Level 3 throughout (Ycode's own boots:
guest `log stream`, Ycode traces, host log), level 1 for `sys/attr.h`.

#### 10.26.1 Why the home view was sometimes not launched, and the fix (§10.20.11 item 1a, §10.21.7 item 1)

R8's guest race (§10.21.1), timed in guest seconds over 15 earlier boots
(R7b `v*`, `b*`, `e*`, `f*`; R8 `b1`, `b2`, `g1`–`g6`, `h1`–`h3`,
`k1`–`k3`) with our script `order.py` (SurfBoard's "Data migration
completed", assistantd's BGST submissions and "finished post launch setup",
SurfBoard's receipt and validation of the MRSiri request, the unlock, the
cover sheet, the resume):

1. **What decides it.** SurfBoard's main queue is busy until data
   migration completes; an open request received before that is validated
   right after it, before the unlock, and refused (the home view then
   resumes; assistantd tries again 60–120 s later, harmless). A request
   received *after* migration waits on the main queue behind the unlock
   work and is allowed (`b2`: received 2.5 s after migration, validated
   5.8 s after the unlock), and Siri's pre-warm scene is in the foreground
   at the resume. In every boot of the table with the request received
   after migration, Siri was allowed before the resume.
2. **Which side is late.** The window from migration to the resume is
   1 s on the reference (§9 Q27: 21.6–23.1 s → 22.6–24.3 s) and 20–60 s
   under Ycode (`b2` 73.3 → 102.6 s, `p1` 76.1 → 145.5 s): the shell's
   work after migration (unlock, the display reveal, the cover sheet) runs
   slowly. assistantd is the early one: under Ycode it is started 2–11 s
   after its spawn by a boost from apsd (diagnostic below; message id
   473000) and finishes its post-launch setup about 20–25 s later, at or
   around data migration (`b2` 74.6 s, `p1` 68.7 s, `e1` 41.2 s); on the
   reference that setup ends 112 s into the boot or later (none within
   175 s and 241 s in two of three boots), 90 s after the resume. Why
   it is so late there is §9 Q28 (on the iOS reference assistantd itself
   starts 5 s in, `scheduling-policy.md` §3, so the time goes inside its
   start-up).
3. **Ruled out.** assistantd's BGST submissions (dasd) are not gated by
   migration (0.1–36 s, ending before or after it); apsd's connection
   status reaches assistantd before and after its setup alike. Background
   CPUs (`scheduling-policy.md` §4.7, `YCODE_HOST_SCHED_BG_CPUS=2`, boot
   `e1`): class-bg threads on 2 of 14 CPUs did not delay assistantd
   (setup at 41.2 s, migration 49.6 s); it stays opt-in.

**The fix (Ycode design).** assistantd's start hold lasts until the shell
is ready (`scheduling-policy.md` §4.2 "shell-ready holds"): boosts and the
quiet test do not release it; `ycode-simd` marks the shell ready when
RealityLauncher runs or at the room's first lit frame, whichever comes
first (the resume precedes the room's first frame in every boot,
§10.21.1), in every visionOS device run (also with `--launch`). This
gives the reference's order: the home view resumes first, and Siri's
pre-warm request comes later and is allowed with the home view on screen,
as in the reference's `x3` (MRSiri launched with intent
"foreground-support", the home view stayed). `YCODE_VISIONOS_SHELL_HOLD`
names other jobs, `0` none (then R8's race returns). The hold's release
line says which boosts it outlived ("boosted while waiting for the shell,
last from pid 140 notifyd …").

**The guard** (§10.21.2) stays as a fallback that logs when it acts; the
same thread (`VisionHomeGuard.swift`, now the visionOS shell watch) marks
the shell ready. It did not act in any boot of this round.

Guest seconds (from launchd_sim's first line) except the home watch
(seconds after `ycode-simd` started) and the hold (host seconds):

| Boot | Migration | Unlock | Resume ("no foreground scenes") | RealityLauncher requested | assistantd released (shell ready by) | Siri's request validated | Home watch | Guard presses |
|---|---|---|---|---|---|---|---|---|
| `s1` | 45.6 | 51.1 | 66.3 | 69.6 | the home view runs, after 71 s | 79.4, allowed | 72.9 s | 0 |
| `c1` | 67.4 | 71.8 | 89.5 | 94.6 | the home view runs, after 95 s | 106.5, allowed | 100.4 s | 0 |
| `c2` | 41.7 | 48.3 | 64.0 | 67.9 | the home view runs, after 69 s | 77.3, allowed | 71.0 s | 0 |
| `c3` | 39.7 | 42.8 | 58.9 | 61.9 | the home view runs, after 62 s | 72.5, allowed | 66.0 s | 0 |
| `c4` | 38.5 | 44.8 | 60.5 | 64.7 | the room's first lit frame, after 64 s | 74.3, allowed | 65.0 s | 0 |
| `c5` | 76.2 | 82.0 | 100.0 | 103.6 | the room's first lit frame, after 103 s | 110.7, allowed | 103.6 s | 0 |
| `c6` | 44.9 | 50.1 | 67.9 | 70.4 | the room's first lit frame, after 70 s | 77.5, allowed | 70.8 s | 0 |
| `c7` | 44.1 | 47.5 | 65.7 | 69.4 | the home view runs, after 70 s | 78.3, allowed | 73.2 s | 0 |
| `c8` | 68.2 | 74.7 | 91.9 | 94.9 | the home view runs, after 95 s | 103.8, allowed | 98.5 s | 0 |
| `c9` | 47.0 | 49.9 | 63.6 | 65.1 | the home view runs, after 66 s | 74.2, allowed | 69.2 s | 0 |
| `c10` | 61.9 | 64.3 | 81.1 | 84.7 | the home view runs, after 86 s | 94.7, allowed | 91.7 s | 0 |

**10 consecutive cold boots `c1`–`c10`** (and `s1` before them; 330 s each,
one at a time, other agents' boots beside them, load averages 2–25): in
every boot SurfBoard resumed the home view ("no foreground scenes
running") and launched RealityLauncher, assistantd was released only
after that or at the room's first frame, Siri's pre-warm request was
validated and allowed 7–11 s after the resume (the reference's outcome:
MRSiri launched, the home view stayed), and **the guard never pressed**.
Before the change the home view came up in 23 of 38 boots (R7–R8); this
round's two boots without it (`p1`, `e1`) went the shell's way, `e1` by
1.1 s (request received 48.5 s, migration 49.6 s). The home
view with its icons: `.claude/worktrees/visionos-r11-home.png` (`c10` at
300 s; outside git). Warm boots: none for visionOS yet (§10.21.5), not
checked.

**Diagnostic** (`scheduling-policy.md` §4.2): a hold released by a boost
logs the sender. In `p1`: runningboardd by vhmdd, biomed by sleepd, tccd
by securityd, accountsd by locationd (all XPC, 1999646836);
amsaccountsd, assistantd, parsecd and remindd within 0.2 s by apsd
(473000); ids_simd by amsaccountsd, healthd and eligibilityd by dasd,
ManagedSettingsAgent by sharingd, mediaremoted by rapportd, peopled by
notifyd.

#### 10.26.2 Photos told 0 bytes free (§10.21.7 item 6)

R8 found no local call that could report the 0. There is one: right before
its error PhotoKit in Photos asks getattrlist on "/" for
`ATTR_VOL_INFO | SIZE | SPACEAVAIL | FILECOUNT | DIRCOUNT` (volume
attributes `0x80000614`, 28 bytes; `a10`), after finding the library's
volume ("/", the device directory being part of "/"'s volume since
`home-screen.md` §6) by `ATTR_CMN_FSID` and `getfsstat64`. Ycode packed a
fixed 64 GiB size and **0 bytes free for any read-only path**, "/"
included, and 32 GiB for a writable one; statfs used the host's sizes of
the prefix itself. No daemon is involved (no CacheDelete call, no reply).

**Fix.** getattrlist's volume sizes (`SIZE`, `SPACEFREE`, `SPACEAVAIL`,
`SPACEUSED`) and statfs's `f_blocks`, `f_bfree`, `f_bavail`, `f_files`,
`f_ffree` are the host file system's real values, the same for every
path of a guest volume: taken from the host directory of the volume's
first writable prefix (for "/"'s volume the device directory), else of
the prefix mounted there; an APFS volume reports its container's free
space for its read-only parts too. Test `VolumeSpaceTests` (device-like
prefixes: "/", a path under the device directory and the read-only
`/System` report the device directory's host sizes; the runtime root its
own).

**Result.** visionOS (`p1`, Photos launched through ylaunch 40 s after the
room): no "insufficient free space", Photos stays up and shows its window
"Library", "No Photos or Videos", the Years/Months/All control and its
tab ornament (`.claude/worktrees/visionos-r11-photos.png`; the visionOS
device has no sample photos). iOS 27.0 (`i1`, iPhone 18 Pro, cold
boot, home screen at 86.8 s, Photos launched through ylaunch 20 s later):
Photos starts, shows its "What's New in Photos" sheet with Continue and
stays up until the run's stop (`.claude/worktrees/visionos-r11-ios-photos.png`).
iOS asks the same "/" volume, so it most likely shared the cause; a boot
without the fix was not made.

#### 10.26.3 Other items

- §10.20.11 item 3 (Q24, op 29's base instance) is answered by the
  reference (§9 Q24: base instance 0, stale high halves; Ycode's reading
  stands); nothing to change.
- §10.20.11 item 5 (§10.13.5 items 3–5, §10.19.4 items 2–5) was not on
  this path and is unchanged.
- The boot is faster with assistantd held: home view 65–104 s after the
  start in `c1`–`c10` (R8: 117–378 s under heavier load; this round's `p1`
  152.7 s and `e1` 99.3 s without the hold). Whether that is the hold or
  the lighter load was not separated.

- Other platforms after merging the main line (fedb2bcf): iOS 27.0 `i1`
  home screen at 86.8 s; watchOS 27.0 `w1` (a new device) at 48.9 s;
  visionOS `m1` home view launched, guard idle (64.8 s). Tests: Mac full
  suite (one failure, `RunTestTextsR42Tests.remoteSimulatorRunSequence`,
  also before this round's changes and outside them), x86 full suite (the
  known flaky `BSDFastPathTests.smallTrapsMatchTheLockedPath`, passing
  alone three times), the Thor's debug suites DarwinABI, DarwinKernel,
  Simd, SimFeatures and HostServices with the lock-order checks (all
  pass), lint.

#### 10.26.4 What remains

1. §9 Q28: why the reference's assistantd finishes its start-up so late;
   if it is a Ycode difference (for example apsd's early message, or
   darwin-bg I/O throttling, `scheduling-policy.md` §4.8), the shell-ready
   hold can give way to that.
2. §10.21.7 items 2–5, 7, 8 are unchanged.

### 10.27 Round GPU-SIRI under Ycode: Siri and immersion stopped the GPU; the watchdog and device recovery (agent GPU-SIRI, 2026-11-01)

Clean-room work on Ycode's own simulator on the Thor (branch `gpu-siri` on
the main line dbc9ad5c; the visionOS 27.0 device of XR-VIEWER, booted on
24M362). No Apple simulator, Xcode, Device Hub or reference tool was run
or opened, nothing under `research/` was read and no Apple binary was
inspected; the guest's shaders were seen only through ycode-airc's
reflection and the hang reports. Level 3 throughout (Ycode's boots and
logs, the host kernel log, our probes), level 1 for the Vulkan
specification.

#### 10.27.1 What was wrong

1. **Siri (XR-VIEWER's run `x7`, the owner's headset session).** Tapping
   Siri on the home view starts SiriApp and the orb renderer
   `com.apple.campo`; campo's first command buffer runs the kernel
   `affordanceDynamicPointLight` six times (one per cube face, 4 × 8
   threadgroups of 32 × 16). The kernel reads ten buffers; the command
   buffer binds one (the face index, by `setBytes`). Ycode left the nine
   other argument-table entries at 0, the kernel's loads read address 0,
   and on the Thor such a read never completes (metal-shaders.md §4.11).
   80 s later another GPU client made the driver kill the context: device
   lost; every pending and held command buffer failed, backboardd aborted
   ("Command buffer SharedEventSignalBuffer failed to execute"), and since
   the Vulkan device stays lost, every new backboardd aborted again every
   50–70 s.
2. **Immersion (XR-VIEWER's run `x8`).** `change_immersion_level` starts
   backboardd's immersion transition, whose command buffer clears and
   draws into a 172 × 172 and a 16 × 16 attachment in one pass. Ycode's
   render area was the first attachment's; the writes past the small image
   never completed (metal-sim-protocol.md §8.7). The threadgroup size both
   reports shared (32 × 16) was not involved: in both cases the GPU was
   stopped by a memory access outside any allocation, a host-side mistake.

#### 10.27.2 Fixes

- Unbound buffer slots a function reads point at the dummy buffer (zeros),
  metal-shaders.md §4.11; a pass is rendered at its smallest attachment's
  size, metal-sim-protocol.md §8.7.
- **GPU watchdog** (10 s) and **device recovery**: the stuck command buffer
  fails, the Vulkan device is made again with every object rebuilt in
  place (handles, heap slots and — with capture replay — device addresses
  kept), and every other command buffer is recorded again, so the render
  server does not see the loss (metal-sim-protocol.md §8.7).

#### 10.27.3 Runs

| Run | Setting | Result |
|---|---|---|
| `r2` | as built | Siri tapped 3 times (each time `Home` in between): "Get Started with Siri" shown each time, campo ran, no GPU report; the host log names the kernel's unbound slots 1–9 once (`.claude/worktrees/gpu-siri-visionos-siri*.png`, outside git) |
| `r1` | `YCODE_GPU_UNBOUND_DUMMY=0` (the old behaviour) | Siri's kernel hung; watchdog at 10 s; device made again in 2.9 s, 0 of 951 buffers at a new address, 1 command buffer failed, 10 recorded again; backboardd kept running and Siri opened again; the room and icon images stayed black (GPU-only contents are lost) |
| `s1`, `s2` | capture replay off / on | both boot to the room; same GPU statistics |
| `m-ios270`, `m-ios271`, `i-watch` (and `i-ios27*`, `j-ios270` under load 90–110) | iOS 27.0 (iPhone 18 Pro), iOS 27.1 (iPhone Duo), watchOS 27.0 | each reached its home screen and rendered (iOS 27.0 at 201 s, 27.1 at 168 s, watchOS at 137 s); on iOS 27.0 the Siri app was opened twice from its home-screen icon (its screens came up blank, black then white, in this round's screenshots; a held side button did not start Siri while the boot was still settling); the watch's held crown showed no Siri screen; no GPU report, watchdog or reset in any of them |

The immersion pass itself was not driven in a boot of this round (the
`vision immersion` command is XR-VIEWER's, not yet on the main line); the
unit test reproduces its pass and its hang.

Tests: `GPURecoveryTests` (unbound slots read zeros; the watchdog ends a
spinning kernel, the queued command buffer runs again on the new device
with the same buffer address and heap slot; recovery off keeps the old
behaviour; mixed-size attachments) and the Thor's Vulkan and Metal host
suites (109 tests); the Mac and x86 full suites; lint.

#### 10.27.4 What remains

1. Textures whose contents only the GPU held come back zeroed after a
   reset (the room, icon images). Restarting the render server after a
   reset would bring them back at the cost of a shell restart.
2. metal-shaders.md §8 item 9 and metal-sim-protocol.md §13 items 11 and
   12 (the reference's behaviour for unbound slots, timed-out command
   buffers and mixed-size passes) are open for a dirty-room observation.
3. A command buffer split at an event wait whose first part had already
   run runs that part again after a reset.
4. Viewport arrays (the immersion pass's vertex function writes
   `viewport_array_index`): Ycode's pipelines have one viewport.

### 10.28 Round VISION-FPS under Ycode: the presented frame rate, what limits it, and the numbers for foveation (agents VISION-FPS and VISION-FPS-2, 2026-11-01/02)

Clean-room work on Ycode's own simulator on the Thor (branch `vision-fps`,
main line d73ad5a3; the visionOS 27.0 base device of `visionos9`, a fresh
copy for every cold boot; level 3 throughout). No Apple simulator, Xcode,
Device Hub or reference tool was run or opened, nothing under `research/`
was read, nothing was disassembled or symbolized. The owner's goal is lower
latency in the headset viewer: the guest's camera pipeline is 3–4 presented
frames (§5.5.12), so the frame rate is the main lever.

Words used below: a **present** is the presenter's (wakeboardd's) swap, 60
a second whether or not the picture changed; a **picture** is a frame the
render server (backboardd) drew (a command buffer with its 4× pass). Only
pictures carry new content. "23.5 pictures/s", the rate in `xr-viewer.md` §6
and `display-stream.md` §18, was measured before item 1 of §10.28.1.

The host is shared and its load matters more than anything else here
(§10.28.5): each result gives its load average, and only comparisons made
close together in alternating sessions are treated as differences.

#### 10.28.1 The clock of Metal completion events

Completion events carried the GPU start and end times on the host's uptime;
the guest compares them with its own media time, its mach time in seconds.
The two differ by the guest clock's offset (about 19 days here), so every
frame seemed to end far in the future and backboardd held itself at 30 Hz.
They now carry the guest's mach time in seconds
(`metal-sim-protocol.md` §8.5; `YCODE_METAL_EVENT_CLOCK=host`: the old
clock). Same build, cold boots, alternating:

| Scene, 3840 × 2160 | Measure | Old clock | Guest clock |
|---|---|---|---|
| Home view, at rest | pictures/s (`hB3`, `h3`; `s8`) | 30 | 55 at load 30, 60 at load 10 |
| Window app, at rest | pictures/s (`wB3`, `w3`) | 18–30 (stalls up to 0.9 s) | 59.8 |
| Window app, head motion | new frames received/s | 20.0 | 54.2 |
| Window app, an isolated 5° pose step | to the first changed frame received, p50 (min, max) | 142 ms (111, 179) | **75 ms** (71, 91) |

The step latency includes the stream (a few ms, Unix socket, ¼ scale JPEG)
and agrees with §5.5.12's 3–4 presented frames at 60 Hz.

#### 10.28.2 Frame rates with the guest clock

Pictures per second, at rest and with the camera moving. "Motion": a ±20°
yaw sine at 0.4 Hz with ±5° pitch and ±5 cm sideways, sent at 90 Hz, each pose
with a selection (`vision pose`), unless the row says otherwise. Presents were
60/s in every row except where noted (58–59 under load).

| Scene | Run, load | At rest | GPU busy at rest (ms per present) | Motion |
|---|---|---|---|---|
| Home view, 3840 × 2160, poses only (0x8A, no gaze) at 30, 60, 90 Hz | `s1`, 8–17 | 60 | 24.5 % (4.08) | **54–60** (frames received 56–59/s) |
| Home view, gaze moving over the icons, no head motion | `s7`, `s11`: 6–14 | 60 | | **16–37, mean 28** |
| Home view, head motion and gaze at 60 Hz | the same sessions | 60 | | **16–39, mean 29** |
| The same two under another device's boot | `h3` load 30–50, `s2`, `s5` | 30–60 | | 0–30 |
| Home view, 2160 × 3840 (motion with gaze) | `t3`, 25 | 59.0 | 20.5 % (3.45) | 11–32, mean 22 |
| Home view, 3840 × 3840 (1.78 × the pixels) | `q2`, 11–18 | 56.8 | 33.7 % (5.79) | 12 |
| Window app, 3840 × 2160 | `w3`, 17 | 59.8 | 23 % (3.9) | **45–59, mean 55** |
| Window app, 2160 × 3840 | `v3`, 18–30 | 53 | 21.6 % (3.72) | 30–59, mean 46; presents 54/s |
| Volume app (box, metal sphere), 3840 × 2160 | `y3`, 10 | 59 | 19.8 % (3.30) | 37–53, mean 46 |

So 60 Hz is sustained at rest, with an app open, on the tall display and
under head motion, on a quiet host. The display's shape costs nothing beyond
its pixels. **The exception is a gaze that moves over the home view's icons**:
about 28 pictures/s (below). A gaze on the empty room or a constant ray does
not cost this (`sky60`: 58.8/s; `n60`, a constant ray at 60/s: 54.7/s;
`s2`), and neither does its rate (`s15` at 15/s: as `s60b` at 60/s): it is
the hover state changing, not the number of events.

After frames are missed backboardd stays at exactly 30 pictures/s for a
while (`s7`, `s11`: up to about 6 s after the motion; `h3`: about 20 s, with
isolated pose steps continuing) and then returns to 60. Ycode has no part in that choice that this
round could find; whether the reference does the same is §9 Q29.

#### 10.28.3 Where the time goes

Per picture, from the frame profile (`frame-profile.md` §10) and the GPU
timestamps of the frame trace:

| ms per picture | Window app, head motion (`w3`, load 16, 57 pictures/s) | Home view, gaze over the icons (`s7`, `s8`, load 10, 30 pictures/s) |
|---|---|---|
| Render thread: guest code | 7.1 | 13.4 |
| Render thread: trap service | 3.4 | 9.1 |
| Render thread: asleep (replies, the GPU's completions, locks) | 7.0 | 11.9 |
| Home view's main thread: guest, trap, asleep | not running | 12.7, 7.0, 14.8 |
| GPU, union of all clients | 3.9 (22 % busy) | 5.4 (17 % busy) |
| of it passes that scale with pixels (§10.28.4) | ≈ 3.0 | ≈ 4.3 |
| Metal host recording (p50, p90) | 0.10, 0.46 | 0.07, 0.66 |

The window app has slack: the render thread is about 60 % busy. Hovering
over icons doubles the per-picture work on threads that wait for each other.
One backboardd thread makes about 290 synchronous calls a second into the
home view's main thread (2 ms on average, up to 27 ms), and the render thread
is seen waiting (`ulock_wait2`, up to 12 ms) until that thread wakes it. The
home view makes about 1,950 IOSurface requests a second and backboardd about
970 (`YCODE_IOSURFACE_STATS`: copy values 700/s, get attachments 490/s, make
port 240/s, purgeable 240/s, remove value 235/s; backboardd looks up about 240
surfaces a second, gets their attachments, marks and releases them). Each is a
round trip through the host service's thread: 120 µs on a quiet host, about
200 µs at load 25. About 13 ms per picture of guest code on the render thread
alone is 80 % of a 60 Hz budget; that is the guest's work on this CPU and
Ycode does not change it.

**A change that did not help (removed).** The round trips looked like the
biggest cost Ycode owns, so host services were made to run on the caller's
thread (the trap served the IOSurface service and short Metal device-ops
inline, after the send). The home view's round trip halved (120 → 60 µs;
its share of the main thread 38 % → 26 %, and it got through 35 % more
requests a second). Pictures per second did not move in alternating
sessions (load 6–14; means per run): gaze sweep 29, 31, 29 with inline
against 29, 27 without; small gaze moves 32, 49, 27 against 49, 35; head and
gaze 25, 25 against 27, 30. A kernel path with that complexity needs a gain to pay for it, so it was
taken out. What came out of the experiment is the diagnostic
(`YCODE_IOSURFACE_STATS`) and the finding that the render thread, not the
home view's RPC rate, sets the pace.

#### 10.28.4 Numbers for foveated rendering

**The share of frame time that is GPU fragment work.** Vulkan timestamps per
pass at three display sizes (home view at rest, ms per present; `d3` 1920 ×
1080, `s8` 3840 × 2160, `q2` 3840 × 3840):

| Pass | 2.07 Mpx | 8.29 Mpx | 14.75 Mpx |
|---|---|---|---|
| Render server's 4× UI pass and resolve | 0.24 | 1.59 | 2.29 |
| The room (two passes) | 0.22 | 0.98 | 1.24 |
| Render server's load pass | 0.07 | 0.28 | 0.47 |
| Presenter's composition | 0.08 | 0.28 | 0.47 |
| Copy to the host surface (33 MB at 3840 × 2160) | 0.08 | 0.34 | 0.64 |
| Blits, kernels, small passes | 0.34 | 0.44 | 0.49 |
| Between passes (barriers) | 0.31 | 0.18 | 0.19 |
| **Total (union)** | **1.35** | **4.08** | **5.79** |

The first five rows scale with pixels. Fragment shading, MSAA resolve and
attachment loads together (the first four) are at most **3.1 ms of the 16.67
ms frame (19 %)** at 3840 × 2160, and the GPU is idle 75–87 % of the time in
every scene measured at that size. These timestamps do not separate vertex
from fragment work, or shading from resolve and load; the near-proportional
growth with pixels says vertex work is small. CPU, guest code and waits are
the remainder: on the render thread alone 7–13 ms per picture of guest code
and 3–9 ms of traps. No frame waits for the GPU: its work overlaps the CPU's.

**The driver** (Thor, NVIDIA 580.00, Vulkan 1.4.315, `vulkaninfo`):

| Feature | Offered |
|---|---|
| `VK_KHR_fragment_shading_rate`, `attachmentFragmentShadingRate` | **yes** (also pipeline and primitive rates); attachment texel 16 × 16 only; fragment sizes up to 4 × 4, aspect ratio up to 2; up to 16 samples, so the 4× pass qualifies; layered attachments |
| `VK_EXT_fragment_density_map` | **no** |
| `VK_NV_shading_rate_image`, `VK_NV_fragment_shading_rate_enums` | yes |

**Reading.** Foveated rendering would not raise the frame rate of these
scenes: nothing here waits for the GPU. Its best case can be bounded: 2 × 2
shading over three quarters of the picture saves 56 % of the shading in the
UI and room passes, about 1.4 ms of 16.67 (9 %), less whatever of those passes
is resolve and load, and only by putting a rate attachment into render
passes the guest defines. A guest scene that really loads the GPU would
change this; the volume sample does not (15–20 % busy). It was not built.

#### 10.28.5 Host load

Another device's boot on the 14 cores (load 30–50) takes the home view with
gaze from about 28 to 0–30 pictures/s and the window app's presents below 60
(`v3`, `s5`, `s10`), far more than any difference above. Within the device
apsd and diagnosticd cost 0.75–1.2 cores and half of all traps at rest (17,000
of 33,000 a second, `s2`; on watchOS too, `watchos.md` §9 Q14).
Latency tests in a headset are best run with no other device booting.

#### 10.28.6 Other platforms

Whether the clock change matters elsewhere: cold boots of a fresh device on a
quiet host (no other device booting), the old clock
(`YCODE_METAL_EVENT_CLOCK=host`) alternating with the guest clock, the same
settle time, no trace or profile. Three phases per boot of ten home-screen
swipes (6 s each); guest frames per second over the phases.

| Platform, settle | Guest clock | Old clock |
|---|---|---|
| iOS 27.0, iPhone 18 Pro, 60 s (`cG1`–`cG3`, `cH1`–`cH3`, load 14–30 from the device's own settling) | 51.3, 39.5, 64.2: **mean 51.7** | 50.4, 44.4, 51.0: **mean 48.6** |
| watchOS 27.0, Series 12 46 mm, 100 s (`wG2`, `wH2`, load 2–3) | 102.6 | 101.0 |
| watchOS 27.0, 40 s (`wG1`, load 6–7) | 101.1 | not run |

**iOS: no regression, and no gain.** The difference is +3.1 frames/s for the
guest clock (phase SD 18 and 12; permutation test over the 18 phases p = 0.67,
though phases of one boot are not independent). Three boots per arm can only
exclude a large effect: a difference of about 14 frames/s or more, not a small
one. The earlier pair that favoured the old clock by nearly a factor of two
(`iA2` 20.2 against `iB2` 38.1) had the guest arm at load 41 against 29, with
a trace and frame profile on, and did not recur. Both arms vary the same way
between phases: the first phase of a boot is about 40/s in every run (38–43),
later ones 36–80/s; `cG1`, `cG3` and `cH1` reached 70–80. That spread was not
explained. The iOS path needs no different clock. Nothing here shows that iOS
ever paced on these times as visionOS does.

**watchOS: the same in all three**, with active intervals of 8.4 ms (p50), so
no sign of the bug there either. `wtA2`'s 39.6 frames/s (one boot, with a trace
and frame profile, load 14) did not recur with the same settle time; its cause
was not found. Every boot of this section reached its home screen and none
crashed ycode-simd (GPU reports were not compared).

#### 10.28.7 A crash in the frame profile

A frame-profile window's close set `KernelTrace.wake` and its siblings to
nil while other threads called them: a closure released while being read.
ycode-simd died in `WaitQueue.Waiter.finish` as window 1 closed in `s9`, one
crash in about 50 profiled sessions, the only one this round. The hooks are
now installed once before the root process and record only while a window is
open (`frame-profile.md` §10).

#### 10.28.8 What remains

1. A gaze moving over home-view icons: about 28 pictures/s on a quiet host.
   Most of it is guest code on the render thread and the home view's main
   thread; Ycode's own share (trap service, round trips) did not turn out to
   be the limit.
2. §9 Q29: the reference's rate and its IOSurface request rate in the same
   hover, and whether it also falls to and stays at 30 Hz after a miss.
3. apsd's and diagnosticd's constant traffic (`watchos.md` §9 Q14).
4. A volume-app stall: one isolated pose step took 2.95 s to change the
   picture in `y3` (pictures fell to 20–27/s around it); not reproduced or
   explained.
5. The 3840 × 3840 home view with gaze motion stays low (12 pictures/s at
   load 11–18, one run).
6. Why iOS swipes vary between about 40 and 80 frames/s within one boot
   (§10.28.6), in both clock arms.
7. Measured with the display probe (¼ scale JPEG), not the headset viewer;
   XR-QUALITY's default stream (HEVC 4:4:4) came to the main line after these
   runs. The guest-side rates do not depend on the viewer's codec except
   through host load; the end-to-end latency in a headset was not measured.

Tests: Mac full suite (2,597 tests; `MacPreviewHostLifetimeTests`' timing
limits failed under the full run's load and pass alone), x86 full suite (2,096
tests), lint. Thor, debug, with the main line merged:
`YCODE_LOCK_ORDER_CHECK=1 YCODE_IPC_LOCKS_TESTS=1` YcodeDarwinABITests (154),
YcodeDarwinKernelTests (443), YcodeSimdTests (100), YcodeSimFeaturesTests (67),
YcodeHostServicesTests (77); YcodeMetalHostTests, YcodeVulkanTests,
YcodeDisplayStreamTests, YcodeXRViewerTests and YcodeXRReprojectionTests (225
in all); translator texture forms (17), control flow (7), interface forms (24):
all pass. `run-thor.sh`'s tests against the Metal oracle were not run (they
need the Mac's metallibs; the translator did not change in this round).

### 10.29 Round XR-ICONS under Ycode: "a glitchy cylinder from the home icons to the back wall" (agent XR-ICONS, 2026-11-02)

Clean-room work on Ycode's own simulator on the Thor (branch `xr-icons`; visionOS
27.0, 2160 × 3840). No Apple simulator, Xcode, Device Hub or reference tool was
run or opened, nothing under `research/` was read and no Apple binary was
inspected. Level 3 throughout.

**Report.** The owner, in the Quest Pro, run 8: a cylinder from the home icons to
the back wall, also ticked for the session with `--stereo adaptive --reproject off`.

**Run 8's build.** Its translator was from 2026-10-13: `SX/bin/build.sh` kept a
prepped tree's copied binary unless asked, and in such a tree the rebuild itself failed
on the copied CMake cache (seen in this round's tree). r8's log has pipelines failing on
`calculate_clamped_lod`, `get_num_samples` and unlinked inputs, all fixed since. The
harness now rebuilds, clears a mismatched cache and fails loudly. Run 7 used the 11-01
translator.

**The guest's own picture.** No cylinder in any full-resolution capture:

| Arm | Hover | Head offsets | Pinch | Direct hand | Headset views (0x8D) |
|---|---|---|---|---|---|
| Stale translator (`s1`) | every icon row, with and without hands | up to 15 cm, yaw 15°, 20 cm nearer | short and long (edit mode) | 5 depths | eye yaw 7°, with sway and roll; Safari had opened by then |
| Current (`c1`–`c5`) | yes | up to 15 cm, yaw 15°, 20 cm nearer | a tap opens Settings | not run | through the real viewer offscreen: steps, holds, a turn |

So no guest draw was found to fix; the current tree logged 0 translator failures. Settings at full
resolution draws correctly (its glass, list, tab bar). A large camera jump hides the
home view, and `vision home` toggles it: captures must allow for both.

**With depth re-projection** the same device shows bands and blocks reaching from
each icon towards the wall, from any eye offset, including half the eye separation
with a still head. Cause and fix: `xr-depth.md` §3.1 and §5.6. **The owner confirmed
these are what they saw**: shown a crop of the bands (`xr-icons-reprojected-icons.png`),
"Yes, actually". Their tick for the flat session stays unresolved: a flat picture has no
warp, and no guest picture showed such a shape, and that session had an 11 s queue, so
the tick may belong to another session.

**Open:** see `xr-viewer.md` §9.3 for what to ask of the owner. Run 7's complaint
("artifacting and aliasing" on the scene and the UI) was not separately checked: run 7
had depth 1/4, so the same bands and the depth's stepped edges (`xr-depth.md` §5.6) were
on screen, but how much of the complaint they explain is not known.

Tests: Mac full suite (2671 tests), x86 full suite (2,169 tests), lint; Thor, debug:
YcodeVulkanTests (51, with the new `DepthTapGPUTests`) and YcodeMetalHostTests (59). The
tap's test fails with `YCODE_XR_DEPTH_ALPHA=0`; `theWindowsLayerStaysOutOfTheCache` and
`aStretchedEdgeIsNotStoredInTheCache` fail against the old viewer code. The environment's
depth clear (§5.6) has no test of its own. No frame-rate figure comes from this round.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Siri's and immersion's GPU hangs, their causes, the watchdog and recovery in boots (§10.27) | 3 | Ycode's boots on the Thor (`ide-remote/gpu-siri/runs/r1`, `r2`, `s1`, `s2`; XR-VIEWER's `x7`, `x8`), ycode-airc's reflection, hang reports and checkpoints, `GPURecoveryTests`, `scripts/gpu-probes/hangkick.c`, `car.c` |
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
| One view for apps: SDK statement, layouts (§5.6.1) | 1 | CompositorServices headers in the visionOS simulator SDK (`drawable.h`, `layer_renderer_layout.h`) |
| One view, identity eye transform, tangents, projection, texture shapes (§5.6.1) | 3 | `StereoProbe` (CompositorLayer, layouts 0, 1, 2); `stereopeek` texture descriptors; `wakeboardctl status` (runtime tool via `simctl spawn`), visionOS 27.2 |
| Layer configuration from `hmd.input.*` defaults; no key, variable or answer changes the view count (§5.6.1) | 3 | `stereopeek` `NSUserDefaults` log in wakeboardd and backboardd; the look-up recorder (environment, preferences, MobileGestalt); nine boots with preference keys written before boot (`exp.sh`) |
| wakeboardd's SimFramebuffer calls; `SimHMD`, "Mono Composite", `is_mono` names (§5.6.1) | 4 | `nm -u` of wakeboardd; `strings` of wakeboardd and of CompositorNonUI's image in the shared cache |
| Two-slice passes: instance counts, no amplification, slice 1 empty (§5.6.2) | 3 | `stereopeek` pass log and slice read-backs in backboardd |
| vhmdd command list and error reply (§5.6.3) | 3, 4 | `strings` of vhmdd; our vhmdd client (`vhm`) with candidate commands |
| Presentation rectangles (§5.6.4) | 3 | `stereopeek` interposer of `SFBSwapchainSwapAddSurface` |
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
| R8: the race between Siri's orb pre-warm and the home view's resume; counts over 38 boots; timings; the resume before the room's first frame (§10.21.1) | 3 | guest `log stream` of SurfBoard, assistantd, Siri, backboardd (R7/R7b boots and R8 `b1`, `b2`, `h1`–`h3`, `g1`–`g6`), our script `race.py` over them; host start times (`/proc/uptime` at the start) and home-watch lines |
| R8: a Home press brings the home view up (§10.21.1) | 3 | boots `h1`, `h3`: `ycode-display-probe … button home` through the display server; backboardd's button lines and SurfBoard's RealityLauncher request |
| R8: the home guard and its boots (§10.21.2) | — / 3 | Ycode design; `VisionHomeGuardTests`; boots `g1`–`g6`, `k1`–`k3` (screenshots, guest log, the guard's log lines) |
| R8: visionOS apps built with Ycode's swift-build engine; the simulator SDK override; synchronized folders not expanded (§10.21.3, `build-pif.md`) | 1, 3 | swift-build (open source) built from `Tools/ycode-swb`; `ycode build` of `Samples/VisionSamples` on the Mac; `SwiftBuildEngineTests.simulatorDestinationsChooseTheSimulatorSDK`; Info.plist keys from Apple's public documentation |
| R8: install, launch and rendering of the samples and the runtime's apps; the touch that did not reach the window; Photos' abort (§10.21.3) | 3 | Ycode boots `a1`–`a10`, `a6b` on the Thor: ylaunch lines, guest `log stream` (the samples' `org.ycode.samples` lines), Ycode fault reports, screenshots, `--trace-name Photos` |
| R8: sRGB storage writes and reads (§10.21.4, `metal-shaders.md` §4.4) | 1, 3 | IEC 61966-2-1 transfer functions (as in the Metal Shading Language specification's sRGB conversion); `SRGBStorageGPUTests` and `interface-forms.sh` case 6 on the Thor's GPU |
| R8: heap slots kept and argument-encoder members written again at a restore; visionOS snapshots refused while shared handles exist (§10.21.5, `snapshot.md` §8) | — / 3 | Ycode design; `SnapshotReplayTests.restoreKeepsSlotsAndRewritesArgumentMembers`, `VulkanBackendTests.reservedHeapSlotsGoBackToTheirObjects`, `IndexAllocatorTests`; `MetalHostCore.snapshotBusyReason`; iOS boot `s1`/`s1-r` (stop snapshot and restore) |
| R8: iOS 27.1 check (§10.21.6) | 3 | Ycode boots `s1`, `s1-r`, `i1` (home watch, `ylaunch`, host log) |
| Q24: op 29 carries backboardd's 36-index instanced depth draws with base instance 0 and stale high halves; the host ignores the high half (§9 Q24) | 3 | OBS-ARGBUF, 2026-10-30: `mslog` in backboardd during reference boot `x1` (visionOS 27.0), 8 145 op-29 records; our probe `argprobe draw2` on the iOS 27.0 reference |
| Q25: argument encoders: host-written members at the offsets op 16 describes, op 17's reply order, op 19's forms; the home view's one descriptor-built encoder (§9 Q25, `metal-sim-protocol.md` §4.3) | 3 | OBS-ARGBUF: `argprobe.m` (32 layouts) under `mslog` and its test server on the iOS 27.0 reference; backboardd's op 16, 17 and 19 records in boot `x1`; `msargbuf.py` |
| Q26: every reference room pass holds all five draws; the 768 × 432 pass every 0.52 s with its seven draws and attachments (§9 Q26) | 3 | OBS-ARGBUF: backboardd's command-buffer segments in boot `x1` (10 114 room passes, 280 linearized-depth passes, texture creation records for the attachment sizes and formats) |
| ARGBUF-IMPL: argument encoders by op 16's description; backboardd's layout as parsed; icons in the home view (§10.22.1) | — / 3 | Ycode design from `metal-sim-protocol.md` §4.3; `ArgumentLayoutTests`; Ycode boots `v1`–`v5` on the Thor (host "argument layout" and "argument encoder" lines, screenshots) |
| ARGBUF-IMPL: the missing parts follow the visibility results; every result zero; the 4× pass's attachments and depth states (§10.22.2) | 3 | Ycode boots `v1` (none), `v2` (`YCODE_DEBUG_VISIBILITY_FORCE=1`), `v3` (`=0`), `v5` (`YCODE_DEBUG_VISIBILITY_STATS=1`) on the Thor: frame thumbnails counted with `dark.py`, the statistics lines |
| ARGBUF-IMPL: the box draws have no fragment function; Ycode discarded such pipelines; the fix and `v7` (§10.22.2) | 1, 3 | Metal documentation (`MTLRenderPipelineDescriptor.fragmentFunction`, `rasterizationEnabled`); Vulkan specification (rasterizer discard, pipelines without a fragment shader, graphics pipeline libraries); boot `v6` (`YCODE_DEBUG_PASS_DRAWS` lines), boot `v7`; `VulkanBackendTests.depthOnlyPipelinesRasterize` (fails with `YCODE_VULKAN_VERTEX_ONLY_DISCARD=1`) |
| Q27: unlock, home resume and Siri's pre-warm on the reference (§9 Q27) | 3 | OBS-ARGBUF: guest `log stream` (SurfBoard, assistantd) of first boots `x1`–`x3`; `simctl io` screenshots |
| Builders' argument order and the Indigo layout of pose, selection, collection and dial messages (§5.5.6) | 3 | OBS-VISION-INPUT, 2026-10-31: our `bprobe` (marker values in every argument register, results hex-dumped) and `vhid` dumps; offsets confirmed by the values backboardd logged |
| Target word → service; target 0 aborts backboardd (§5.5.6) | 3 | `vhid` messages to `ycode-test-vision3-a`; backboardd's sender IDs and exception text in the guest log |
| Events dispatched for pose, selection, collection, dial: types, usages, version, data, flags, children (§5.5.2) | 3 | our `hidrec.dylib` in backboardd (event descriptions and vendor-event arguments) |
| Constructors the HID bundle uses (§5.5.7 item 1) | 4 | `nm -u` of CoreSimulator's xros `SimulatorHID` |
| Hand provider's reading: pinch, direct, chirality, contacts and their sources, hover (§5.5.2) | 3 | backboardd log (RealitySystemSupport hand provider, remote-effect hit test); screenshots |
| Stage frame, absolute camera pose, host-side ray transform, 90° field of view (§5.5.1) | 3 | screenshots at known poses; taps with camera-space and stage-space rays at a moved camera; a marker entity at a known position |
| ARKit anchor = stage transform × vhmdd pose; PalomaPose does not change it; `set_pose` does not move the view (§5.5.3) | 3 | `InputProbe` anchor log under pose messages and `set_pose`; vhmdd's "stage transform" log; whole-screen comparison |
| vhmdd protocol: host only, `cmd` key, replies and events (§5.5.4) | 3 (names of unexercised commands 4) | our `vhm` (host) and guest client; `strings` of vhmdd and the DeviceKit plug-in |
| Crown actions on a device; `ImmersionChangeContext`, `onWorldRecenter`, progressive style; Device Hub has no visionOS crown control (§5.5.9) | 1 | Apple Vision Pro User Guide ("Basic gestures and controls", "Digital Crown"); SwiftUI documentation and the xrsimulator SDK's SwiftUI interface; "Interacting with your visionOS app in Device Hub" |
| Immersion through `change_immersion_level`/`get_immersion_level`: L = a², clamping, relative = L + delta, the 0.3 s eased event stream, events only after a first message, style values (§5.5.9) | 3 | OBS-VISION-CROWN, 2026-11-01: our `vhm` (one connection, timed events) against `CrownProbe`'s `onImmersionChange` log in four space styles; screenshots |
| DigitalDial scroll changes no immersion (§5.5.9) | 3 | our `vhid dial` with a progressive space open; `hidrec` dispatch log; vhmdd events; app log |
| Crown press, double, triple, hold thresholds; top button, screenshot and Force Quit chords (§5.5.9) | 3 | our `vhid bdown`/`bup` scripts; SurfBoard's gesture log lines; screenshots; app scene-phase log |
| Recenter: crown hold, placement follows the rendered camera, `onWorldRecenter`, new stage transform; `recenter_open_apps` a no-op (§5.5.9) | 3 (the sound file name 2) | screenshots with matched and mismatched render camera and vhmdd pose; app log; vhmdd and backboardd log lines; SurfBoard bundle listing |
| Controls, hand mode, cursor commands (§5.5.9) | 3 | our `vhm`; vhmdd log; screenshot differences |
| Device Hub plug-in immersion actions and dial log strings; vhmdd's SurfBoard immersion client; vhmdd strings identical in 27.0 and 27.2 (§5.5.9) | 4 | `strings`, `nm -m` of `VisionDeviceKitExtension`; `strings` of both runtimes' `vhmdd` |
| Room preference before boot selects the room (§5.5.4) | 3 | plist edited while shut down; boot screenshot (Museum (Day)) |
| App results per input (§5.5.5) | 3 | `InputProbe` logs |
| R9: the probe's callbacks for each host input, DeviceAnchor following `set_pose`, live and pre-boot rooms, Home, the viewers' mappings (§5.5.8, §10.25) | 3 | Ycode boots r1–r3 on the Thor with our `VisionInput` app (guest log stream, screenshots); IOHIDFamily public sources (APSL 2.0) for the event constructors and field numbers (level 1) |
| Glass: blur, gain, offset, rim (§10.23.3) | 3 | screenshot pairs with and without the window, least-squares fit against blurred backgrounds |
| Content-glass recipe values; CoreRE glass material (§10.23.3) | 2 | `plutil -p` of the recipe; JSON keys of the material definition |
| Mirror and rough metal appearance (§10.23.4) | 3 | screenshots of `InputProbe`'s volume |
| Environment probe and albedo texture formats (§10.23.4) | 2 | KTX 1 headers, key/value data and level data read with our script |
| R10: glass data flow, the threadgroup argument known by its pointer, the read-only probe cube without a storage view; probe statistics (§10.24.1–2) | 3 | Ycode boots `w1`–`w3`, `m1`–`m3` on the Thor: frame map (`YCODE_GPU_FRAME_MAP`), pass probes of `kernelSFBBlurAndFilter` and `generateClampedMap`, ycode-airc reflection |
| Guest constexpr samplers held as a plain `i64`, all read as 0 before (§10.24.2 item 2) | 3 | ycode-airc reflection (`state_type`, `state_source`) of visionOS functions dumped in earlier rounds (`vision5-h6`), translation caches of R10 and an iOS 27.0 area; `tests/ir/interface-forms.sh` case 8 |
| Glass fit and rim, sphere appearance, home view (§10.24.3) | 3 | frames of `b1`, `b2` (460 s) and `b1` (160 s); our least-squares fit of the panel against a Gaussian blur of `b2`'s frame (numpy, Pillow) |
| Other platforms unchanged (§10.24.6) | 3 | boots `i0`, `i1`, `wa1`; `ios27` run `c1-p18-first` for comparison |
| R11: the race decided by the request's arrival before or after data migration; the window from migration to the resume; assistantd's start by apsd's boost and its post-launch timing (§10.26.1) | 3 | guest `log stream` of R7b and R8 boots and R11 `p1`, `e1`, `s1`, `c1`–`c10`, our script `order.py`; the hold release lines with their senders (`p1`) |
| R11: shell-ready holds, the shell watch, the guard as fallback; the boot series (§10.26.1, `scheduling-policy.md` §4.2) | — / 3 | Ycode design; `SchedPolicyTests.shellReadyHoldWaitsForTheShell`, `VisionHomeGuardTests`; boots `s1`, `c1`–`c10` (hold and guard lines, home watch, screenshots) |
| R11: PhotoKit's getattrlist on "/" and the 0 bytes free; the fix and Photos' empty library (§10.26.2) | 1, 3 | `sys/attr.h` (volume attribute bits); Ycode traces of Photos (`a10`, `p1`); `VolumeSpaceTests`; screenshots of `p1` and iOS `i1` |
| Pose rotation turns the reference's view at the plain home view, with a window, in mixed, progressive and full spaces; no `set_pose` needed (§5.5.10 items 1–2) | 3 | `vhid pose` on visionOS 27.2, `simctl io` screenshots, `vhm get_pose`; our `CrownProbe` for the window and spaces |
| The pose event's fields: parent and child types, flags, child order, Orientation type 3 in field 3, w/x/y/z in fields 8–11, 16.16 values (§5.5.10 item 3) | 3 | our `hidrec2.dylib` in backboardd: each field read back by number |
| A generic Orientation event stays type 0 and drops fields 8–11; the quaternion constructor's argument order (§5.5.10 item 4) | 3 | our `oprobe` (guest, `simctl spawn`): construct, read back, print |
| The runtime IOKit's Orientation constructors by name (§5.5.10 item 4) | 4 | `dlsym` presence in our `oprobe` |
| Ycode's construction reproduces the lost rotation in the reference (§5.5.10 item 4) | 3 | `hidrec2.dylib` with `HIDREC_REWRITE=1`, screenshots |
| The reference smooths its camera: per-frame fractions, times from the send, translation alike (§5.5.12 item 1) | 3 | our `camrec.dylib` (pose events at dispatch in backboardd; presented surfaces' times and sampled rows in wakeboardd), `vhid` with send times, `camstep.py`/`stepsum.py`; 27 isolated steps on visionOS 27.2 |
| Smoothing on time, not frames (§5.5.12 item 2) | 3 | `hmd.compositor.fps` 30 before boot; a test device type with a 30 Hz display |
| Continuous-motion delay and gain, rate independence; repeats, pairs, overshoot (§5.5.12 items 3–4) | 3 | sine, ramp, repeat, pair and overshoot scripts (`posegen.py`, `series1.sh`), `lagfit.py` |
| The message's host time becomes the event timestamp; offsets and scaling ignored; equal timestamps; flags (§5.5.12 item 5) | 3 | `vhid` `STAMP`/`TS_OFFSET_MS`/`TS_SCALE`/`TS_ABS`; `camrec.dylib` timestamps and flag rewrites |
| Preferences that do not change the smoothing; layer pose "invalid" (§5.5.12 item 6) | 3 | `pexp.sh` (keys written before boot), `wakeboardctl status` |
| "head pose for time" and `InputPoseProvider` names (§5.5.12 item 6) | 4 | printable strings of the RealitySimulation and RealitySystemSupport images in the shared cache (file format) |
| Ycode's own timings for comparison (§5.5.12 item 7) | — | `xr-viewer.md` §6 (Ycode's measurements) |
| Frame rates, pass costs, per-thread times, the inline experiment, iOS and watchOS comparisons (§10.28) | 3 | Ycode's simulator on the Thor, `ide-remote/vision-fps/runs/` (`h2`–`h3`, `hB3`, `t2`, `t3`, `w2`, `w3`, `wB3`, `v2`, `v3`, `y3`, `q2`, `d3`, `s1`–`s12`, `iA1`–`iB2`, `wtA1`–`wtA2`, `cG1`–`cH3`, `wG1`, `wG2`, `wH2`): frame trace with GPU timestamps, frame profile, `YCODE_IOSURFACE_STATS` |
| The Thor driver's shading-rate features (§10.28.4) | 1 | `vulkaninfo`, Vulkan 1.4 specification |
| Tangents = (1, 1, h/w, h/w) for five display sizes; textures and surface sizes; apps' tangents and viewport (§5.6.6 item 1–2) | 3 | test device types (`mktype.py`), `wakeboardctl status`, `StereoProbe`, `camrec` swap log, screenshots |
| The 2732 × 2048 type is limited to runtimes ≤ 2.99 and refused (§5.6.6) | 2, 3 | its `profile.plist`; `simctl create` on 27.2, 26.5, 26.4 |
| No preference widens the FOV; the two four-number keys abort wakeboardd when given a number (§5.6.6 item 3) | 3 | `pexp.sh`, screenshot comparison, `wakeboardctl status`, wakeboardd crash reports (exception at start, while reading preferences) |
| No guest process makes, sets or receives a rate map; layers "VRR Not Enabled", eye tracking disabled; whole image presented (§5.6.7 items 1, 7) | 3 | `rrmpeek` in every job (five boots), `StereoProbe` (`rasterizationRateMaps` count), `wakeboardctl status` |
| RealityKit asks `supportsRasterizationRateMapWithLayerCount:` 2 once per process; wakeboardd never asks; CompositorServices reports foveation unsupported (§5.6.7 item 2) | 3, 4 | `rrmpeek` (answers and calling image); `StereoProbe` capabilities; class and method names from the Objective-C runtime (level 4) |
| The device's rate-map answers are guest constants: NO / 0 / nil, no host message, unchanged by the host's hand-shake values (§5.6.7 item 3) | 3, 4 | `rrmcli` (answers, Mach message counts); Metal-protocol recorder and test server (`mslog`, `hostFeatureProfile` 0–100); defining class and image from the runtime (level 4) |
| A device forced to say yes still gets no rate map used (§5.6.7 item 4) | 3 | `rrmpeek` with `RP_FORCE_RRM` (diagnostic), screenshots |
| Foveation preferences change nothing; `com.apple.compositor.foveation.custom` YES makes wakeboardd abort at each layer creation (§5.6.7 item 5) | 3, 4 | `exp.sh` boots, `stereopeek` read log (values read), screenshot comparison, `wakeboardctl status`, wakeboardd crash reports (abort while the layer reads its defaults); key names from `strings` (level 4) |
| Forced foveation in an app fails with `variableRasterizationRateIsNotSupported` (§5.6.7 item 6) | 1, 3 | CompositorServices headers (`cp_error.h`); `StereoProbe -fovforce` |
| The rate-map interface, the decoder, CompositorServices' per-drawable maps (§5.6.7) | 1, 3 | Metal and CompositorServices headers of the XRSimulator 27.0 SDK; our decoder shader compiled in the guest (`rrmcli`) |
| Foveated shading or streaming as a host-side Ycode feature (§5.6.7 item 3 of "What Ycode must do") | — | design consequence, not an observation; Vulkan specification for fragment shading rate |

For §5.5.10 (OBS-VISION-POSE, 2026-11-01) only `ycode-test-vision6-pose`
(visionOS 27.2, 24N120; 27.0 could not create a device: "runtime path not
found") was used and then deleted; no other simulator was booted or
touched. Only `simctl`, our sender, vhmdd client, recorder and probes
drove it: no clicks, no screen takeover, no disassembly, nothing
decrypted, no level 5. Logs and screenshots stayed in the agent's scratch
folder.
For §5.5.12 and §5.6.6 (OBS-VISION-FOV, 2026-11-01) only
`ycode-test-vision7-*` devices were used, one booted at a time (visionOS
27.2; 27.0 could not create a device; the 2732 × 2048 type was refused),
and all were deleted at the end, as were the five test device types in
`~/Library/Developer/CoreSimulator/Profiles/DeviceTypes/` and the 15
default devices CoreSimulator had created for them on its own (a copied
profile must drop `createByDefaultForRuntimeVersions`). Only `simctl`,
the runtime's `wakeboardctl`, our sender, recorder and probe drove them:
no clicks, no screen takeover, no disassembly, nothing decrypted, no
level 5. Level 4 was limited to printable strings of four images of the
shared cache. Frame samples, logs and screenshots stayed in the agent's
scratch folder.
For §5.6.7 (OBS-VISION-RRM, 2026-11-01) only `ycode-test-vision8-rrm`
(visionOS 27.2; `ycode-test-vision8-rrm27` on 27.0 could not be created)
was used, one boot at a time, and then deleted; `device_set.plist` was
identical before and after, and no device type was created. Only
`simctl`, the runtime's `wakeboardctl` and our own recorders and probes
drove it: no clicks, no screen takeover. Ghidra, the IPSW and the
reference tools folder were not opened, nothing was disassembled (level 5
not used) and nothing was decrypted. Level 4 was limited to `strings` of
the guest Metal driver, printable strings of six shared-cache images, and
Objective-C class, method and type-encoding names read from the running
processes' runtime. One boot (with `com.apple.compositor.foveation.custom`)
left 18 wakeboardd crash reports in the host's diagnostic-reports folder.
Tool sources are in `research/experiments/visionos/rrm/` (and the
`-fovforce` option of `StereoProbe`); raw logs, screenshots and the
crash report copy stayed in the agent's scratch folder.
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
For §10.21 (VISIONOS-R8) only Ycode's own simulator was booted, on the
Thor; no Apple simulator, Xcode, Device Hub or reference tool was used,
nothing under `research/` was read, nothing was disassembled, and the
guest's shader logic was not read.
For §9 Q24–Q27 (OBS-ARGBUF, 2026-10-30) only `ycode-test-argbuf-ios27`
(iOS 27.0) and `ycode-test-argbuf-xr` (visionOS 27.0) were used, one
booted at a time, and both were deleted afterwards. Only `simctl` and the
guest log were used: no clicks, no screen takeover. Ghidra, the IPSW and
the reference tools folder were not opened, nothing was disassembled
(level 5 not used; level 4 only to find which runtime shader library
names a function) and nothing was decrypted. The probe and recorder
binaries, scripts and raw captures stay in `research/dirty/argbuf/`; no
image was committed.

For §5.5 and §10.23 (OBS-VISION-INPUT, 2026-10-31) only
`ycode-test-vision3-a` was used and then deleted. Ghidra, the IPSW and the
reference tools folder were not opened, nothing was disassembled (level 5
not used) and nothing was decrypted. Level 4 was limited to `nm`, `strings`
and Objective-C type encodings of the DeviceKit plug-in, CoreSimulator's
xros HID bundle and vhmdd. The sender, client, recorder and probe sources
are in `research/experiments/visionos/`; binaries, logs, screenshots and
recorder output stay in `research/dirty/vision3/`; no image was committed.

For §5.5.9 (OBS-VISION-CROWN, 2026-11-01) only `ycode-test-vision4-c`
(visionOS 27.2, because no 27.0 device could be created that day) was
used and then deleted; `device_set.plist` was byte-identical before and
after. Only `simctl` and our own host tools drove it: no clicks, no screen
takeover, no Device Hub. Ghidra, the IPSW and the reference tools folder
were not opened, nothing was disassembled (level 5 not used) and nothing
was decrypted. Level 4 was limited to `strings` and `nm -m` of the
DeviceKit plug-in, `strings` of vhmdd, DeviceHub, DeviceKit and
SimulatorKit, and a listing of SurfBoard's bundle. Tool and probe sources
are in `research/experiments/visionos/`; binaries, raw exchanges, logs and
screenshots stay in `research/dirty/vision4/`; no image was committed.

For §5.6 (OBS-VISION-STEREO, 2026-11-01) only `ycode-test-vision5-a`
(visionOS 27.2; no 27.0 device could be created, and a
`ycode-test-vision5-b` of the 2732 × 2048 type was refused by 27.2 and
never existed) was used and then deleted; `device_set.plist` was
byte-identical before and after. Only `simctl`, the runtime's
`wakeboardctl`, and our own probe, recorder and vhmdd client drove it: no
clicks, no screen takeover. Ghidra, the IPSW and the reference tools
folder were not opened, nothing was disassembled (level 5 not used) and
nothing was decrypted. Level 4 was limited to `strings` of wakeboardd,
wakeboardctl and vhmdd, printable strings of three images of the shared
cache, and `nm -u`/`otool -L` of wakeboardd. Probe and recorder sources are
in `research/experiments/visionos/` (`StereoProbe/`, `stereo/`); raw
output, read-backs and screenshots stayed in the agent's scratch folder;
no image was committed.
