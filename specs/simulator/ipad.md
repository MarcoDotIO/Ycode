# Spec: iPad device types in the Ycode simulator

Status: **proposed** (IPAD-SPEC, 2026-10-19); rounds 1 (DEVTYPE) and 2
(IPAD-BOOT) **done** on the 27.1 runtime (IPAD-DEVTYPE, 2026-10-20; results
in §9.1). It says what an iPad device
type is as a file format, which simulator runtime can run one, how a booted
iPad differs from an iPhone, and what Ycode must change so that
`ycode-simd` boots and runs an iPad. Observations behind it:
`research/notes/ipad-observations.md`. It builds on
`device-capabilities.md`, `first-boot.md`, `home-screen.md`, `home-apps.md`,
`hid-input.md`, `display-stream.md` and `simframebuffer.md`; it does not
repeat them.

Facts come from device-type and runtime bundles read as file formats (level
2), throwaway simulators on this Mac and our own probes run in them (level
3), and bundle structure and shared-cache image lists (level 4). No
disassembly or decompilation was used. **Ycode decision** marks design
choices.

Terms: **RR** (RuntimeRoot), **DEV** (device directory), as in
`launchd-sim.md`. "Device type" is CoreSimulator's `.simdevicetype` bundle;
"identity" is the set of values the host gives the guest for one device
type (§3).

## 1. Summary

1. **An iPad uses the same kind of runtime as an iPhone; only the identity
   differs.** The guest learns that it is an iPad from the host: the
   capabilities plist (`SIMULATOR_CAPABILITIES`, MobileGestalt answers such
   as `idiom` = pad), the main-screen variables, the model identifier,
   product class and asset suffix. No iPad-only host service, launchd job
   or environment variable exists (§5).
2. **The iOS 27.1 runtime (24A94401) that Ycode runs is restricted by
   CoreSimulator to the iPhone Duo device type** (§2). Xcode's simulator
   cannot create an iPad on it, so there is no Apple reference for an iPad
   on 27.1. The newest runtime that accepts iPads is iOS 27.0 (24A434).
3. **The 27.1 runtime's content does run as an iPad** when the host gives
   it an iPad identity (level 3, §2.3): iPadOS system name, iPad home-screen
   layout, the iPad-only dock folder service, no crashes. Its app set is the
   reduced 27.1 set (Settings, Safari; `home-apps.md`).
4. **Recommendation (Ycode decision):** implement device types in
   `ycode-simd` first and boot the iPad identity on the 27.1 runtime that
   the Thor already has (rounds 1–4, §9). In parallel, bring up the 27.0
   runtime on the Thor as a second runtime (round 5), because only 27.0 has
   an Apple reference for iPad behavior and the full app set; parity
   claims for iPad are made against 27.0.
5. Everything iPad-specific that the user sees — the dock, the larger
   home-screen grid, multitasking (windowed apps, Slide Over, Stage
   Manager), the pointer, keyboard shortcuts — is drawn and decided by
   SpringBoard and UIKit inside the guest. The host's parts are: the right
   identity (§3–§4), a larger display (§6), more input kinds (pointer,
   more fingers, keyboard shortcuts; §7), and rotation (§7.4).
6. The simulator has **no 120 Hz mode**, even for iPad Pro: every iPad
   device type declares 60 Hz and a booted iPad Pro reports 60 fps (§5.4).

## 2. Runtimes

### 2.1 Which runtime accepts which device types

`xcrun simctl list runtimes -j` (`supportedDeviceTypes`), Xcode 27.1:

| Runtime | Build | Device types | iPad types |
|---|---|---|---|
| iOS 26.5 | 23F77 | 65 | 34 |
| iOS 27.0 | 24A434 | 62 | 29 |
| iOS 27.1 | 24A94401 | 1 (iPhone Duo) | 0 |

The file-format reason: the runtime bundle's
`Contents/Resources/profile.plist` has the key **`restrictedToDeviceTypes`**,
an array of device-type identifiers; for 27.1 it is
`[com.apple.CoreSimulator.SimDeviceType.V68]` (V68 = iPhone Duo, through the
device type's `aliases`). Runtimes without the key accept every device type
whose `minRuntimeVersion` ≤ the runtime version ≤ `maxRuntimeVersion` (when
present) and whose `supportedProductFamilyIDs` intersect the runtime's.
`simctl create` of an iPad on 27.1 fails with CoreSimulator error 403
"Incompatible device".

The restriction is CoreSimulator policy, not runtime content: the same 27.1
profile lists `supportedProductFamilyIDs` = [2, 1] (iPad, iPhone), every app
that 27.0 and 27.1 both ship has the same `UIDeviceFamily`, and 27.1 keeps
its `~ipad` resources (1981 files; 2113 in 27.0, the rest belonging to the
17 apps 27.1 lacks).

### 2.2 Runtime layout differences that matter to `ycode-simd` (27.0 vs 27.1)

| Item | 27.0 (24A434) | 27.1 (24A94401) | Consequence for Ycode |
|---|---|---|---|
| `restrictedToDeviceTypes` | absent | [V68] | none for `ycode-simd` (it does not read the profile); the IDE's destination list must not hide iPads because of it when Ycode runs its own identity (§8) |
| Apps with Info.plist (`Applications`, `CoreServices`) | 180 | 163 | the first boot registers 17 more apps (lsd seeding, `first-boot.md` §1 item 5) and builds more icons and widgets; expect a longer first boot on the Thor |
| launchd job labels (LaunchDaemons/Agents/Angels) | 363 | 363, identical set | job handling is unchanged; lean-boot lists (`lean-boot.md`) apply by label |
| `RR/System/Library/Caches/com.apple.dyld/` | `dyld_sim_shared_cache_arm64` (2.04 GB) + `.01` (1.79 GB) + `.atlas` + `.map`; 1826 images | same file names; 2.04 GB + 1.75 GB; 1819 images | same layout and names (`dyld-sim-handoff.md`); the cache is a different build, so cache UUIDs, image offsets and any recorded addresses differ |
| `usr/lib/dyld_sim`, `sbin/launchd_sim` | present | present | different builds (file hashes differ). Everything Ycode learned from 27.1's `dyld_sim` and `launchd_sim` (`dyld-sim-handoff.md`, `launchd-sim.md`, `bootstrap-wire.md`) must be re-checked on 27.0 |
| `GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib` | inside the shared cache, no file | a 39 MB file on disk, not in the cache | the Metal compiler service loads it from a different place; Ycode's file prefixes and memory accounting must cope with both |
| Images only in one cache | 12 (Mail, Notes, Maps, Calendar support; `libLLVM`) | 5 (clock-face and calendar posters, ShellSceneKit) | none known |
| Runtime volume size (used) | 17 GiB | 16 GiB | disk on `$YCODE_DATA` |
| `SystemVersion.plist` | 27.0 / 24A434 | 27.1 / 24A94401 | `ycode-simd` already reads version and build from it (`SIMULATOR_RUNTIME_*`, migration marker) |

Per-runtime state that Ycode keeps must be keyed by runtime build: golden
devices (`lean-boot.md` §5), warm-start snapshots (`snapshot.md` §12, which
already boots cold on a new runtime), the LaunchServices store in DEV
(`first-boot.md` §2: a device migrates when `LastSystemVersion` changes).

### 2.3 The 27.1 runtime with an iPad identity (level 3)

An iPhone Duo device on 27.1 was booted on the Mac with its identity
replaced through the launch environment (CoreSimulator passes
`SIMCTL_CHILD_*` variables into the device's launchd; checked in
backboardd's environment): the iPad Pro 13-inch (M5) capabilities file, its
main-screen values, model `iPad17,4`, class `J821`, asset suffix `ipad`, and
our headless framebuffer prototype sized from `SIMULATOR_MAINSCREEN_*`.

| Observation | Value |
|---|---|
| First boot to `bootstatus` terminal | 20.6 s (35 migration plugins) |
| backboardd main screen | 2064 × 2752, scale 2, native rotation 0 |
| UIKit (`UIDevice`, `UIScreen`, our probe) | idiom 1 (pad), model "iPad", system name **"iPadOS"**, 27.1; 1032 × 1376 points; 60 fps |
| MobileGestalt (our probe) | DeviceClass iPad, ProductType iPad17,4, `DeviceSupportsEnhancedMultitasking` 1 |
| `DEV/data/Library/SpringBoard/IconState.plist` | an iPad layout: page 1 = a large `files` element and Settings; dock Safari; iPad-only keys `dockUtilities` and `listMetadata` (§5.2) |
| Running | SpringBoard, PosterBoard and poster extensions, **DockFolderViewService**, fileproviderd |
| Crash reports for the device | none |

This is what Ycode's iPad on 27.1 is expected to show, with no Apple
reference to compare pixels against.

## 3. The device-type file format

### 3.1 Bundle

`/Library/Developer/CoreSimulator/Profiles/DeviceTypes/<Name>.simdevicetype/Contents/`
holds `Info.plist` (`CFBundleIdentifier` =
`com.apple.CoreSimulator.SimDeviceType.<id>`), `Resources/profile.plist`,
`Resources/capabilities.plist`, framebuffer-mask PDFs named by UUID (host
chrome; Ycode does not need them) and a localized name. Ycode reads none of
these files at run time and ships none of them; it carries the values it
needs as its own data (§4).

### 3.2 profile.plist keys

| Key | Type | Meaning | iPad (A16) | iPad Pro 13-inch (M5) | iPhone Duo |
|---|---|---|---|---|---|
| `modelIdentifier` | string | `SIMULATOR_MODEL_IDENTIFIER` | iPad15,7 | iPad17,4 | iPhone19,4 |
| `productClass` | string | `SIMULATOR_PRODUCT_CLASS` | J481 | J821 | V68 |
| `representedModelIdentifiers` | [string] | real models this type stands for | iPad15,7, iPad15,8 | iPad17,3, iPad17,4 | iPhone19,4 |
| `environment` | dict | extra launch variables | `SIMULATOR_LEGACY_ASSET_SUFFIX` = ipad | ipad | iphone |
| `supportedProductFamilyIDs` | [int] | device families (1 iPhone, 2 iPad) | 2, 1 | 2, 1 | 1 |
| `minRuntimeVersion`, `maxRuntimeVersion` | string | runtime range | 18.3, – | 26.0, – | 27.1, – |
| `createByDefaultForRuntimeVersions` | {versionMin, versionMax} | Xcode creates one by default | 18.3–99.99 | 26.0–99.99 | 27.1–99.99 |
| `springBoardConfigName` | string | | iPadSimulatorHiDPI | iPadSimulatorHiDPI | iPhone4Simulator |
| `supportedFeatures` | dict of bool | host features | display.integrated, display.supports-external, hid.keyboard, hid.touch-screen | the same + pearl-id | the same + framebuffer.27, display.aot, hid.staccato, touch-id |
| `supportedFeaturesConditionalOnRuntime` | dict of bool | features if the runtime also lists them | deviceIdentity, hid.applepay.authorize, **hid.pointer.system**, touch-id | deviceIdentity, hid.applepay.authorize, **hid.pointer.system** | carplay, resizableScene, pairing, ambient-overlay, … |
| `chromeIdentifier`, `framebufferMask`, `sensorBarImage` | string | host window chrome | tablet4, a UUID, – | tablet5, a UUID, – | phone15, a UUID, sensor_bar_class_04 |

`com.apple.hid.pointer.system` is declared by every iPad device type and by
no iPhone type checked; the 27.x runtimes list it among their
`supportedFeaturesConditionalOnDeviceType`. It marks the device types for
which the host offers pointer (mouse/trackpad) input (§7.2).

### 3.3 capabilities.plist

Same structure as for the iPhone (`device-capabilities.md` §1): a
`capabilities` dictionary of MobileGestalt answers, a `displays` array (host
display list) and a legacy `iconState` that the runtime does not use. The
types of numbers matter as a format: `ArtworkDeviceScaleFactor`,
`main-screen-scale`, `main-screen-orientation` and `DeviceCornerRadius` are
reals; the other numbers are integers (also true of the iPhone Duo file).

Key-set differences against iPhone Duo: the iPad files have no
`DeviceIsMuseCapable`, `IsLargeFormatPhone`, `MainScreenClass`,
`bluetooth-le`, `cellular-data`, **`hardware-keyboard`** or `shoebox`; the
iPad (A16) and iPad Pro 13-inch (M5) files add `graphicsClass` = 3.

## 4. The two device types Ycode supports first

**Ycode decision:** iPad (A16) — Xcode's default iPad: created by default
for every 27.x runtime, no enhanced multitasking, Touch ID, sRGB — and
iPad Pro 13-inch (M5) (12 GB) — the largest current screen, Face ID,
enhanced multitasking (Stage Manager), P3. Others (iPad Pro 11-inch (M5),
iPad Air (M4), iPad mini (A17 Pro)) differ only in the values of the
observations note's table §2.2 and can be added as data.

### 4.1 Identity (launch environment)

| Variable | iPad (A16) | iPad Pro 13-inch (M5) | iPhone Duo (today) |
|---|---|---|---|
| `SIMULATOR_MODEL_IDENTIFIER` | iPad15,7 | iPad17,4 | iPhone19,4 |
| `SIMULATOR_PRODUCT_CLASS` | J481 | J821 | V68 |
| `SIMULATOR_LEGACY_ASSET_SUFFIX` | ipad | ipad | iphone |
| `SIMULATOR_MAINSCREEN_WIDTH` / `HEIGHT` | 1640 / 2360 | 2064 / 2752 | 1398 / 2034 |
| `SIMULATOR_MAINSCREEN_SCALE` | 2.000000 | 2.000000 | 3.000000 |
| `SIMULATOR_MAINSCREEN_PITCH` | 264.000000 | 264.000000 | 460.000000 |
| `SIMULATOR_EXTENDED_DISPLAY_PROPERTIES`, `IPHONE_TVOUT_EXTENDED_PROPERTIES` | **not set** | **not set** | set (DEV path of `extended_display.plist`) |

Every other variable (`launchd-sim.md` §3) is the same for both idioms.
`SIMULATOR_VERSION_INFO` names the model identifier, as today.

### 4.2 Capabilities (`DEV/ycode-capabilities.plist`, written every boot)

`capabilities` dictionary for the two types (values as in the device type's
file, level 2; Ycode leaves out `displays`, `iconState` and
`marketing-name` as it does for the iPhone):

| Key | iPad (A16) | iPad Pro 13-inch (M5) |
|---|---|---|
| `ArtworkTraits` | `ArtworkDeviceIdiom` "pad", `ArtworkDeviceProductDescription` "iPad (A16)", `ArtworkDeviceScaleFactor` 2.0, `ArtworkDeviceSubType` 2360, `ArtworkDisplayGamut` "sRGB", `ArtworkDynamicDisplayMode` "0", `CompatibleDeviceFallback` "iPad13,18", `DevicePerformanceMemoryClass` 6, `GraphicsFeatureSetClass` "APPLE8", `GraphicsFeatureSetFallbacks` "APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0" | "pad", "iPad Pro 13-inch (M5)", 2.0, 2752, "P3", "0", "iPad16,6-A", 12, "APPLE10", "APPLE9:APPLE8:APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0" |
| `ScreenDimensionsCapability` | `main-screen-class` 23, `-height` 2360, `-orientation` 0.0, `-pitch` 264, `-scale` 2.0, `-width` 1640 | 32, 2752, **1.5707963705062866**, 264, 2.0, 2064 |
| `idiom` | "pad" | "pad" |
| `modelIdentifier` | "iPad15,7" | "iPad17,4" |
| `ThinningProductType` | "iPad15,7" | "iPad17,4-A" |
| `ModelNumber`, `RegulatoryModelNumber` | "A3354" | "A3361" |
| `device-name` | "iPad Simulator" | "iPad Simulator" |
| `DeviceCornerRadius` | 25.0 | 30.0 |
| `HomeButtonType` | 2 | 2 |
| `memoryClass` | 6 | 12 |
| `subtype` | 2360 | 2752 |
| `software-dimming-alpha` | 0 | 0 |
| `graphicsClass` | 3 | 3 |
| `displayGamut` | "sRGB" | "P3" |
| `graphicsFeatureSetClass`, `graphicsFeatureSetFallbacks` | as in `ArtworkTraits` | as in `ArtworkTraits` |

True in both: `720p`, `accelerometer`, `accessibility`,
`applicationInstallation`, `arm64`, `armv6`, `armv7`, `armv7s`, `ASTC`,
`bluetooth`, `DeviceSupports3DImagery`, `DeviceSupports3DMaps`,
`DeviceSupportsAdaptiveMapsUI`, `DeviceSupportsAdvancedMapRendering`,
`DeviceSupportsHiResBuildings`, `displayport`, `encrypted-data-partition`,
`FloatingLiveAppOverlay`, `full-6`, `gamekit`, `gas-gauge-battery`,
`HasThinBezel`, `HEVCDecoder8bitSupported`, `HEVCDecoder10bitSupported`,
`HEVCDecoder12bitSupported`, `HEVCEncodingCapability`,
`hide-non-default-apps`, `hidpi`, `homescreen-wallpaper`,
`international-settings`, `ipad`, `load-thumbnails-while-scrolling`,
`location-services`, `magnetometer`, `metal`, `microphone`, `multitasking`,
`opengles-1`, `opengles-2`, `peer-peer`, `PiPOverlay`, `PiPPinned`,
`screenrecorder`, `stand-alone-contacts`, `wifi`.

False in both: `always-on-time`, `DeviceSupportsDynamicIsland`,
`DeviceSupportsElton`, `DeviceSupportsSingleDisplayEnhancedMultitasking`,
`MLEHW`, `OysterCapability`, `ringer-switch`, `RingerButtonCapability`,
`sms`, `SupportsForceTouch`, `telephony`, `unified-ipod`, `watch-companion`.

Differing booleans:

| Key | iPad (A16) | iPad Pro 13-inch (M5) |
|---|---|---|
| `touch-id` | true | false |
| `pearl-id` | false | true |
| `DeviceSupportsEnhancedMultitasking` | false | true |
| `GPSCapability` | false | true |
| `contains-cellular-radio` | false | true |
| `reverse-zoom` | false | true |

Absent (not false) in both: `hardware-keyboard`, `MainScreenClass`,
`IsLargeFormatPhone`, `shoebox`, `bluetooth-le`, `cellular-data`,
`DeviceIsMuseCapable`. MobileGestalt then answers `hardware-keyboard` = 0 on
the reference iPad; that is the reference behavior, and a hardware keyboard
is still attached through HID (§7.3).

### 4.3 Required changes in `ycode-simd` (observable requirements)

R1. `ycode-simd --device` accepts a device-type choice (**Ycode decision**:
`--device-type <id>` with ids `iphone-duo` (default), `ipad-a16`,
`ipad-pro-13-m5`), and every value of §4.1–§4.2 comes from that type's
data. The guest's environment and capabilities file then equal the
reference's for that type, key for key, with number types as in §3.3.

R2. A device keeps its type. **Ycode decision:** `ycode-simd` records the
type in DEV (for example `DEV/ycode-device-type`) on the first boot and
refuses to boot an existing DEV as another type (the LaunchServices store,
`IconState.plist` and migrated data are per idiom). Golden devices and
snapshots are keyed by (runtime build, device type).

R3. The headless framebuffer (`simframebuffer.md`) needs no new code: it
takes its geometry from `SIMULATOR_MAINSCREEN_*` (checked with the
research prototype, §2.3). Its mode record keeps refresh 6000 (60 Hz) and
scale 2 comes from the variable. Native rotation stays 0 for every type,
including the iPad Pro whose capabilities say `main-screen-orientation`
π/2: the reference backboardd reports "nativeRotation:0" and
"digitizerToPanelRotation=0" on that model.

R4. Expected guest results of an iPad boot (the acceptance checks of round
2): backboardd "initial main screen size:{W, H} scale:2"; `UIDevice` idiom
pad and system name "iPadOS"; `IconState.plist` with `dockUtilities` and
`listMetadata`; `DockFolderViewService` running; no "can't load simulator
capabilities dictionary"; the home screen drawn with wallpaper and icons.

## 5. Booted iPad: reference behavior (iOS 27.0, level 3)

### 5.1 Boot

The first boot runs the same 35 migration plugins as the iPhone and takes
about the same time (iPhone 18 Pro 49 s, iPad (A16) 54 s, iPad Pro 13 M5
55 s on a heavily loaded Mac; 22 s for the iPhone Duo on a quiet one,
`first-boot.md` §1). A second boot of the iPad Pro took 16.6 s. A new
device directory is identical for both idioms before the first boot.

### 5.2 Home screen

- **Portrait** by default (screenshots 1640 × 2360 and 2064 × 2752).
- Layout (`IconState.plist`, `home-apps.md` §5 for the item list): pages of
  a 4-column × 6-row grid for widget placement (`listMetadata`
  `fixedLocationsGridColumns` 4, `fixedLocationsGridRows` 6), widgets on
  page 1, a **dock** of up to five apps plus a folder of recent/suggested
  apps served by `DockFolderViewService`, page dots above the dock.
- The layout has a second, landscape order per page (`rotatedOrder`,
  `rotatedFixedLocations`): the iPad home screen rotates; the iPhone's
  `IconState.plist` has no such keys.
- SpringBoard preferences that only the iPad writes:
  `SBBottomLeftCornerGestureTouchTypes` = 3,
  `SBBottomRightCornerGestureTouchTypes` = 3 (bottom-corner gestures,
  e.g. Quick Note and screenshot), `SBGestureRequiresEducation-Corner` = 1.

### 5.3 Services

- The launchd job set is identical: the same 363 labels exist in both
  runtimes, and no job plist is limited by device class or idiom (the
  load-limiting keys present are about variants, recovery, developer mode
  and Clarity mode).
- Started on the iPad and not on the iPhone: `DockFolderViewService` (the
  dock folder), `fileproviderd`, the iCloud Drive file provider and `bird`
  (the Files widget). Started on the iPhone only: `nanoregistryd` (watch
  pairing). These are on-demand starts, so Ycode needs nothing special for
  them beyond what any job needs.
- No iPad-only host service: the iPad's environment has no variable the
  iPhone lacks (it lacks two, §4.1), and no new host Mach name was seen.

### 5.4 Display and refresh rate

- Every iPad device type declares `refreshRate` 60 in its displays list.
- The booted iPad Pro 13 M5 reports `maximumFramesPerSecond` 60, display
  configuration "1032x1376@2x 60Hz p3 SDR", and the framebuffer mode record
  has refresh 6000 (1/100 Hz), as the iPhone.
- The reference iPad has two displays: `LCD` (built-in, digitizer) and
  `TVOut` (720 × 480, no digitizer, powered off). Ycode keeps one display
  (`simframebuffer.md` §8); an external display for Stage Manager is a
  later feature (§10).

### 5.5 Multitasking

All multitasking UI (full-screen apps, windowed apps with resizable
windows, Slide Over, Stage Manager, the app switcher; SpringBoard logs
switcher events of kind `ContinuousExposeIdentifiersChanged`) is
SpringBoard's. Which modes are offered depends on the MobileGestalt answers
`DeviceSupportsEnhancedMultitasking` (Stage Manager on the device's own
display), `DeviceSupportsSingleDisplayEnhancedMultitasking`, `multitasking`,
`PiPOverlay`, `PiPPinned`, `FloatingLiveAppOverlay` (level 1: Apple's
iPadOS user guide lists Stage Manager only for M-series iPads). The host
must only supply the identity and the input to drive it (touch drags on
window edges, multi-finger gestures, pointer, keyboard shortcuts).
Multiple scenes per app (`UIApplicationSupportsMultipleScenes`) need no host
support.

## 6. Display stream and viewer: what changes for iPad

| Item | iPhone Duo | iPad (A16) | iPad Pro 13 M5 | Requirement |
|---|---|---|---|---|
| Pixels | 1398 × 2034 (2.8 MP) | 1640 × 2360 (3.9 MP) | 2064 × 2752 (5.7 MP) | none in the protocol (sizes are u16; hello carries them, `display-stream.md` §3.1) |
| Points (touch space) | 466 × 678 | 820 × 1180 | 1032 × 1376 | from hello `pointWidth/Height` |
| Full-frame encode | 10–15 ms | ≈ 1.4 × | ≈ 2 × | **Ycode decision:** the viewer's default `downscale` is 2 for iPad types; full resolution on request |
| IOSurface rows | 5632 B | 6592 B | 8256 B | none (`iosurface-remote.md` alignment rule) |

V1. The viewer window takes the device's aspect ratio from hello and must
fit a 13-inch iPad on a laptop screen (initial size limited to the screen;
⌘1/⌘2/⌘3 as today).

V2. Hello gains `deviceFamily` ("phone" / "pad") and `pointer` (boolean:
the server accepts pointer messages, §7.2). Unknown fields are ignored by
older viewers (`display-stream.md` §2).

V3. Rotation (§7.4) is needed for iPad: the home screen and most apps
rotate. Until it exists the viewer keeps the Rotate control disabled.

## 7. Input

### 7.1 Touch (unchanged contract, larger use)

- Coordinates stay normalized to the native portrait display
  (`hid-input.md` §5.3); nothing changes for the larger screen.
- **More fingers.** iPadOS system gestures use four and five fingers
  (pinch to Home, swipe between apps; level 1, iPad user guide). The host
  transport allows 1…5 contacts (`hid-input.md` §7 item 3); that is enough.
  **Ycode decision:** the viewer gets a way to produce 3-, 4- and
  5-finger pinch and swipe (for example a modifier that turns a mouse drag
  into n parallel contacts, or n contacts converging on the pointer for a
  pinch).
- **Corners.** The iPad uses the bottom corners for gestures (§5.2) and the
  top-right edge for Control Center. Edge marking (`hid-input.md` §8.2)
  applies unchanged; the viewer must let a drag start exactly in a corner.
- The reference publishes one touch screen for the iPad (one display with a
  digitizer); Ycode's single touch service matches.

### 7.2 Pointer (new; iPad device types only)

Observed (level 3): backboardd runs a mouse-pointer controller on both
idioms that matches HID services with `DeviceUsagePage` 1 /
`DeviceUsage` 2 (Generic Desktop, Mouse); the reference publishes no such
service at boot ("Services discovered: []"), so the pointer appears only
when the host adds a pointer device. Device types that support it declare
`com.apple.hid.pointer.system` (§3.2).

Requirements (Ycode decision, to be confirmed by round 4's prototype):

P1. The Ycode HID bundle gains a **pointer service** (fixed service ID
`0x59434F4400000004`, `PrimaryUsagePage` 1, `PrimaryUsage` 2,
`DeviceUsagePairs` [{1, 2}], `Built-In` false, `Product` any). It is added
when the host enables the pointer and removed when it disables it (like
the keyboard, `hid-input.md` §9).

P2. Events from it, built with the runtime's IOKit event constructors (names
and argument orders from IOHIDFamily's open source, level 1): relative
pointer events (dx, dy, button mask) and scroll events (dx, dy), with
timestamps as in `hid-input.md` §5.1.

P3. Transport (`hid-input.md` §7) new kinds: 6 pointer-attach (attached
1/0), 7 pointer move (f64 dx, f64 dy in points, u32 button mask), 8 scroll
(f64 dx, f64 dy in points, u32 phase). Display stream: client messages
0x89 pointer (u32 sequence, f32 dx, f32 dy, u8 buttons) and 0x8A scroll
(u32 sequence, f32 dx, f32 dy, u8 phase), only when hello says `pointer`.

P4. Viewer: a "capture pointer" mode (toggle by a menu item and a shortcut
the viewer reserves): in it, mouse motion is sent as relative pointer
motion and the system cursor is hidden and locked to the window; trackpad
scroll is sent as scroll events; the mode ends on the shortcut or on focus
loss. Outside it, the mouse stays a finger (`hid-input.md` §8.1).

P5. Acceptance: with the pointer attached, SpringBoard draws the pointer;
hovering an app icon or a button shows the hover effect; a click opens an
app; two-finger trackpad scroll scrolls; moving to the bottom edge reveals
the dock in an app.

### 7.3 Hardware keyboard

- The reference iPad attaches the same external-keyboard service as the
  iPhone ("Hardware keyboard attached (countryCode:0 type:-1 layout:US)"),
  although MobileGestalt answers `hardware-keyboard` = 0 (key absent). Ycode
  already attaches its keyboard at boot (`hid-input.md` §9); no change.
- iPadOS gives ⌘, ⌥, ⌃ and Globe combinations system meaning (⌘-Space
  search, ⌘-Tab app switcher, ⌘-H home, holding ⌘ for the shortcut
  overlay; level 1, iPad user guide). The viewer keeps ⌘ shortcuts for
  itself today (`display-stream.md` §7). **Ycode decision:** K1: in pointer
  capture mode (§7.2 P4) and in a "send ⌘ to device" toggle, every key
  combination except the viewer's release shortcut goes to the guest as
  page-7 usages; K2: the Globe key is sent as Keyboard/Keypad usage of the
  host's Fn key mapping chosen in round 3 (see §10 item 4).

### 7.4 Rotation

The iPad needs rotation more than the iPhone: the home screen has a
landscape layout (§5.2) and SpringBoard runs its scenes with
`orientationMode=dynamic`. The guest-side mechanism is open
(`hid-input.md` §10, §13 item 3) and is being worked on separately.
Requirements that hold whatever the mechanism:

O1. The framebuffer stays in the native portrait size; the digitizer stays
in native portrait coordinates (`hid-input.md` §5.3).

O2. Display stream: status (or hello) carries the current interface
orientation; the viewer rotates the shown image and maps touches and
pointer motion back to native portrait coordinates before sending.

O3. Whether the reference's rotated framebuffer content is drawn rotated
inside a portrait buffer, and whether `simctl io screenshot` returns a
rotated image, is to be checked on 27.0 with an iPad (§10 item 2).

## 8. IDE

D1. The run-destination list shows iPad (A16) and iPad Pro 13-inch (M5) for
Ycode's simulator, with the runtime they run on. **Ycode decision:** on the
27.1 runtime they are labeled as Ycode identities without an Apple
reference (CoreSimulator refuses them, §2.1); on 27.0 (round 5) they are
ordinary.

D2. An app whose `UIDeviceFamily` lacks 2 still runs on an iPad (the
iPhone app in compatibility mode is the guest's behavior; no host work).
`TARGETED_DEVICE_FAMILY` and the destination's family must agree as
Xcode's do (build-setting behavior is outside this spec).

## 9. Implementation plan (rounds sized for one agent each)

Clean-room agents implement from this spec and the specs it cites; they do
not open the reference tools or `research/dirty/`.

1. **DEVTYPE** (`ycode-simd`, unit tests): device-type data for
   `iphone-duo`, `ipad-a16`, `ipad-pro-13-m5` (§4.1, §4.2, §3.3 number
   types); `--device-type`; capabilities writer and environment from the
   type; the extended-display variables only for iPhone; R2 (type recorded
   in DEV, mismatch refused; golden-device and snapshot keys include the
   type); `ycode-sim.sh` / `ycode-sim-serve` pass the type. Done when unit
   tests compare the written plist and environment with §4 key by key, and
   the iPhone output is unchanged byte for byte.
2. **IPAD-BOOT** (Thor, 27.1 runtime): boot `ipad-pro-13-m5` and `ipad-a16`
   to the home screen, cold and warm; check R4; record boot times next to
   the iPhone's (`boot-profile.md`); fix what the larger display or the
   iPad-only services (DockFolderViewService, fileproviderd, the Files
   widget) need from the kernel/VMM. Done when the viewer shows the iPad
   home screen with wallpaper and icons and a tap opens Settings.
3. **VIEWER-IPAD** (viewer and display server): hello fields V2;
   window sizing V1; default downscale 2 for iPad; 3/4/5-finger gestures
   (§7.1); corner starts; "send ⌘ to device" (K1). Done when a 4-finger
   pinch from an app returns home and ⌘-Space opens search on the iPad.
4. **POINTER** (two parts): (a) analysis side: extend the research HID
   prototype (`research/experiments/simulator/hid/hidproto.m`) with a 1/2
   service on the Mac's iPad simulator and confirm P5, recording the event
   fields that matter in a short addendum to this spec; (b) implementation:
   P1–P4 in the Ycode HID bundle, transport and viewer. Done when P5 holds
   on the Thor.
5. **RUNTIME-27.0** (Thor): add iOS 27.0 (24A434) as a second runtime (copy
   plan below); boot an iPhone 18 Pro identity and an iPad on it; re-check
   the 27.1-derived behaviors (§2.2: `dyld_sim` handoff, `launchd_sim`
   bootstrap routines, host-library imports, Metal compiler load path with
   `libLLVM` in the cache); record differences in the affected specs. Done
   when both reach the home screen and Ycode screenshots can be compared
   with the Mac's 27.0 simulator.
6. **ROTATION-IPAD**: after the orientation mechanism is specified, O1–O3
   for iPad in landscape (home screen and Settings); viewer Rotate enabled.

**Copy plan for round 5 (recommendation; nobody copies anything as part of
this spec):** copy the 27.0 `RuntimeRoot` tree — the runtime volume
`/Library/Developer/CoreSimulator/Volumes/iOS_24A434/…/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot`
on the Mac, including `System/Library/Caches/com.apple.dyld/` — the same
way the 27.1 root was copied, to `$YCODE_DATA/runtimes/iOS-27.0-24A434/RuntimeRoot`
(about 17 GiB; symlinks, modes and extended attributes preserved; read-only
afterwards). Never into the repository. `ycode-simd` already takes the root
from `--runtime-root` / `YCODE_SIM_RUNTIME` and the version from its
`SystemVersion.plist`.

### 9.1 Round results (Ycode, 27.1 runtime 24A94401, the Thor)

Observed behaviour of Ycode's own simulator (level 3: Ycode boots, our
`devprobe` guest probe, the guest's `log stream` and `launchctl list`
run as one-shots, Ycode screenshots). The host was shared with other boots
(load average 10–21 during the first boots), so absolute times are upper
bounds.

**Round 1 (DEVTYPE).** `--device-type iphone-duo | ipad-a16 |
ipad-pro-13-m5`; an unknown id is refused (exit 64) with the list of ids.
The type is recorded in `DEV/ycode-device-type` (one line, the id) at the
first prepare. A DEV with no record counts as `iphone-duo` only when it was
booted before (it has `data/var/run/launchd_bootstrap.plist`); files put
into a new DEV's `data` before its first boot (a probe in `data/tmp`) do not
make it an older device. A DEV, a restore and a golden device of another
type are refused before anything in DEV is written (exit 66, "… has the
device type ipad-a16; it cannot boot as iphone-duo (use another device
directory, or --device-type ipad-a16)"); the launcher's snapshot
fingerprint includes the type.

**iPhone Duo unchanged.** For the default type, everything `prepare`
writes into a new DEV (`ycode-capabilities.plist`,
`launchd_bootstrap.plist`, the audio plist, the memory-warning file) and
the Child, Self and launchd environments are byte-identical to main line
391af58; the only new file is `ycode-device-type` (`iphone-duo`). A full
boot of the pristine iPhone Duo device reaches the home screen at 75 s
(benchmark criterion, frames every 5 s), as before.

**Round 2 (IPAD-BOOT).** Both iPad types boot to the home screen on 27.1,
with no host crash and no guest crash report that the iPhone does not also
have (FileIndexerDaemon's ENODEV fatal error occurs on every type).

| Check | iPad (A16) | iPad Pro 13-inch (M5) |
|---|---|---|
| First boot of a new DEV (35 migration plugins) to home | 200 s (wallpaper 230 s) | 210 s (wallpaper 240 s) |
| Second boot (cold, booted DEV), launcher criterion | 45.4 s | 45.4 s |
| Save at stop / restore to home | pause 2.2–2.7 s / 5.5 s | saved / 5.7 s |
| Snapshot size, DEV size | 2.4 GiB, 0.5 GiB | 2.6 GiB, 0.8 GiB |
| backboardd | "initial main screen size:{1640, 2360} scale:2" | "{2064, 2752} scale:2" |
| "can't load simulator capabilities dictionary" | absent | absent |
| `UIDevice` | idiom 1, model "iPad", "iPadOS" 27.1 | same |
| `UIScreen` points, native, scale, max fps | 820 × 1180, 1640 × 2360, 2.0, 60 | 1032 × 1376, 2064 × 2752, 2.0, 60 |
| MobileGestalt DeviceClass, ProductType | iPad, iPad15,7 | iPad, iPad17,4 |
| MG `DeviceSupportsEnhancedMultitasking`, `ipad`, `telephony`, `hardware-keyboard` | 0, 1, 0, 0 | 1, 1, 0, 0 |
| MG `ArtworkTraits` | as §4.2 (sRGB, APPLE8, 6) | as §4.2 (P3, APPLE10, 12) |
| Display-stream hello | 1640 × 2360 px, 820 × 1180 pt, scale 2, model iPad15,7 | 2064 × 2752 px, 1032 × 1376 pt, scale 2, model iPad17,4 |
| Running after home | DockFolderViewService, `com.apple.bird` | same |
| Tap on Settings (492, 126 / 614, 134 pt) | Settings opens: sidebar and General side by side | same |

The iPhone Duo with the same probe: idiom 0, "iOS", 466 × 678 pt at scale 3,
DeviceClass iPhone, `telephony` 1, `hardware-keyboard` 1.

Home screen (both types, portrait, screenshots): wallpaper; page 1 with a
large `files` widget and Settings; a dock with Safari and the dock folder
(DockFolderViewService); after Settings was used, the dock shows it as a
recent app between Safari and the folder. `IconState.plist`: keys
`buttonBar` (Safari), `dockUtilities` (empty array), `listMetadata` (one
page entry with `rotatedOrder`), `iconLists`, `listUniqueIdentifiers`,
`today`; this is the §2.3 layout. The clock's date read "Tue 20 Oct" on the
A16's first boot and "Tue Oct 20" on later boots and on the Pro (§10 Q8).

Not yet done in round 2: a viewer session (round 3 sizes its window); the
`fileproviderd` job was not identified by label in `launchctl list`.

**fileproviderd's label (reference, answered 2026-10-20).** CoreSimulator
refuses an iPad (A16) on the 27.1 runtime (`simctl create`: error 403
"Incompatible device", §2.1), so the closest allowed check was an iPad (A16)
on 27.0 (24A434). There `launchctl list` (through `simctl spawn`) shows the
job **`com.apple.FileProvider`**, running with a pid after the first boot;
that pid's executable is
`/System/Library/Frameworks/FileProvider.framework/Support/fileproviderd`
under the runtime root. The job file is
`System/Library/LaunchDaemons/com.apple.FileProvider.plist`, and it is the
same in 27.0 and 27.1: `Label` `com.apple.FileProvider`, `Program` the path
above, `POSIXSpawnType` Adaptive, `EnableTransactions` and
`EnablePressuredExit` true, no `RunAtLoad`/`KeepAlive`; Mach services
`com.apple.FileProvider`, `com.apple.FileProvider.cache-delete`,
`com.apple.corespotlight.daemon.fileprovider`,
`com.apple.fileprovider.extension.push`,
`com.apple.fileprovider.extension.push.development`,
`com.apple.fileprovider.pushkit`. So in Ycode's `launchctl list` look for
`com.apple.FileProvider`, not a label containing "fileproviderd".

## 10. Open questions

1. Does anything in the 27.1 runtime behave differently for an iPad in ways
   the Mac test of §2.3 could not show (it used a headless framebuffer, so
   no pixels; it ran under heavy host load)? Round 2 on the Thor (§9.1)
   found nothing iPad-specific: pixels, layout and services as §2.3.
2. Rotation on iPad: how the reference rotates (§7.4 O3), and whether the
   landscape home screen needs anything from the host.
3. Pointer: whether a virtual 1/2 service added from inside backboardd is
   enough for the pointer, hover effects and scrolling, or whether the
   reference uses another path (relative vs absolute positions, a
   trackpad/digitizer service for gestures). Round 4a.
4. Which key the reference sends for Globe (Fn) and how ⌘ shortcuts reach
   the guest from Simulator.app.
5. Units of `DeviceCornerRadius` (points or pixels); needed only if the
   viewer draws rounded corners.
6. Stage Manager on an external display (`TVOut` / `displayport`):
   needs a second display in Ycode's framebuffer; not planned.
7. Whether the 27.1 runtime's missing apps (Files in particular) matter for
   iPad features that refer to them (the `files` home-screen element of
   §2.3 exists although `Files.app` does not).
8. (Dirty side) Is the date format of the status bar on a new iPad device
   expected to change after the first boot ("Tue 20 Oct" then "Tue Oct
   20", §9.1), and which region a new reference device starts with?
   **Answered (2026-10-20, level 2 and 3).** No. A new reference iPad (A16)
   (27.0, the closest runtime CoreSimulator allows; 27.1 refuses iPads)
   showed "7:14 PM  Tue Oct 20" on its first boot and "7:16 PM  Tue Oct 20"
   after a reboot: US region (12-hour clock, weekday-month-day) from the
   first boot on. The region is already set before the first boot:
   `simctl create` writes `DEV/data/Library/Preferences/.GlobalPreferences.plist`
   (XML, 307 bytes) with only `AppleLanguages` = [`en-US`] and
   `AppleLocale` = `en_US` (on a Mac whose own `AppleLocale` is `en_US` and
   `AppleLanguages` [`en-US`]; whether CoreSimulator copies the Mac's values
   was not varied). After the first boot the file also holds
   `AKLastLocale` `en_US` and `AppleLanguagesSchemaVersion` 5400; the
   region does not change. Ycode's "Tue 20 Oct" on a first boot is
   therefore a difference: the device then had no `AppleLocale` before
   its first boot (or the value arrived only later). The reference
   behavior is a device that starts with the two keys above.
   **Ycode (APP-FIX, 2026-10-20): implemented.** `prepare` writes that
   file (XML; `AppleLanguages` [`en-US`], `AppleLocale` `en_US`, nothing
   else) into a device that never booted, unless the file exists; a
   booted device and a golden-device copy are left as they are
   (`DeviceTypeTests.firstBootLocaleOnlyForNewDevices`; the iPhone
   device-directory test now expects the file). On a new iPhone Duo's
   first boot (run a1) the file afterwards also held `AKLastLocale`
   `en_US` and `AppleLanguagesSchemaVersion` 5400, as on the reference,
   and the status bar showed the time in 12-hour form ("11:47" at 23:47
   UTC). The iPad's first-boot date was not rechecked (no iPad boot in this
   round).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Runtime device-type support, 403 on create (§2.1) | 3 | `simctl list runtimes -j`, `simctl create` on this Mac |
| `restrictedToDeviceTypes`, families, features of runtimes (§2.1, §3.2) | 2 | runtime `profile.plist` read with `plutil` |
| `UIDeviceFamily` of apps, `~ipad` resource counts, app counts (§2.1, §2.2) | 4 | Info.plist keys and file listing of both RuntimeRoots |
| Runtime layout differences (§2.2) | 2, 4 | `SystemVersion.plist`, runtime `Info.plist`, launchd plist `Label`s, shared-cache `.map` image lists, file sizes and hashes |
| 27.1 with an iPad identity (§2.3) | 3 | throwaway iPhone Duo device on 27.1 booted with `SIMCTL_CHILD_` identity overrides and our headless framebuffer prototype; our probe `screenprobe`; `IconState.plist`; `ps`; backboardd log; DiagnosticReports |
| Device-type keys and values (§3, §4) | 2 | `profile.plist`, `capabilities.plist` of the device types, read with `plutil` |
| Environment differences (§4.1) | 3 | `ps -E` of backboardd in iPad and iPhone devices on 27.0 |
| Native rotation 0 on iPad Pro (R3) | 3 | backboardd log "StartWindowServer" on 27.0 and on 27.1 with the iPad identity |
| Boot times, home-screen layout and keys, SpringBoard preferences (§5.1, §5.2) | 2, 3 | `simctl bootstatus`, screenshots (scratch only), `IconState.plist` and `com.apple.springboard.plist` read with `plutil` |
| Job set, load-limiting keys, on-demand services (§5.3) | 2, 3 | launchd plists read as files; `launchctl list`; host `ps` by `SIMULATOR_UDID` |
| 60 Hz, two displays, mode record (§5.4) | 2, 3 | device-type `displays`; our probes `screenprobe` and `sfbprobe`; SpringBoard log display configuration |
| Multitasking modes by device (§5.5) | 1, 2 | Apple iPad User Guide (Stage Manager, multitasking gestures); capabilities keys |
| Pointer matching, no pointer service at boot, HID service list (§7.2, §7.3) | 3 | backboardd log on 27.0 (iPad and iPhone) |
| Pointer and scroll event constructors (§7.2 P2) | 1 | Apple IOHIDFamily open source |
| Multi-finger and keyboard gestures of iPadOS (§7.1, §7.3) | 1 | Apple iPad User Guide |
| Ycode round 1 and 2 results (§9.1) | 3 | Ycode boots on the Thor; `devprobe`, `log stream` and `launchctl list` one-shots; Ycode screenshots; byte comparison of `prepare` output with main line 391af58 |
| fileproviderd's label and job file (§9.1) | 2, 3 | `launchctl list` and host `ps` on a new iPad (A16) on 27.0; the job plist of both runtimes read with `plutil` (2026-10-20) |
| Status-bar date on first and later boots, preferences before the first boot (§10 Q8) | 2, 3 | screenshots (scratch only) of a new iPad (A16) on 27.0 before and after a reboot; `.GlobalPreferences.plist` of a new, never-booted device and after its first boot |
| Ycode's first-boot global preferences (§10 Q8) | 3 | unit tests; Ycode run a1 on the Thor (the device's `.GlobalPreferences.plist` read with `plistlib` after the first boot; screenshot, scratch only), 2026-10-20 |
| Device-type choice, `--device-type`, pointer service and transport, viewer behavior, rounds, copy plan | — | Ycode decisions |

Level 5 was not used. The reference tools (the Xcode copy, Ghidra, the
IPSWs) and `research/dirty/` were not opened; restore IPSWs were not
touched.
