# iPad device types in the simulator: observations (IPAD-SPEC, 2026-10-19)

Dirty-room observations behind `specs/simulator/ipad.md`. Methods: device
type and runtime bundles read as file formats with `plutil` (level 2);
throwaway devices created, booted, probed and deleted with `xcrun simctl`
(level 3); bundle structure, Info.plist keys and the shared-cache `.map`
image lists (level 4). No disassembly or decompilation. No Apple file was
copied into the repository; screenshots stayed in the session scratch area.

Devices used (all deleted at the end): `ycode-test-ipad-a16` (iPad (A16),
iOS 27.0), `ycode-test-ipad-pro13` (iPad Pro 13-inch (M5), iOS 27.0),
`ycode-test-iphone-cmp` (iPhone 18 Pro, iOS 27.0), `ycode-test-ipad-on271`
(iPhone Duo device type on iOS 27.1, booted with an iPad identity, §6).

Host conditions: the Mac was heavily loaded during most runs (load average
600–1000 from other agents' builds and simulators, swap 36–40 GB of 42 GB
used). Timings below are therefore upper bounds, and one effect of the load
(stalled process launches, §3.4) must not be read as iPad behavior.

## 1. Runtimes and which device types they accept

`xcrun simctl list runtimes -v` / `-j` (`supportedDeviceTypes`):

| Runtime | Build | Device types | iPads | iPhones |
|---|---|---|---|---|
| iOS 26.5 | 23F77 | 65 | 34 | 31 |
| iOS 27.0 | 24A434 | 62 | 29 | 33 |
| iOS 27.1 | 24A94401 | **1** | **0** | 1 (iPhone Duo) |

The reason is in the 27.1 runtime's `Contents/Resources/profile.plist`:
`restrictedToDeviceTypes = [com.apple.CoreSimulator.SimDeviceType.V68]`
(V68 is iPhone Duo's alias, its `profile.plist` `aliases`). The 27.0 and
26.5 profiles have no such key. `simctl create … iPad-A16 … iOS-27-1` fails:
`domain=com.apple.CoreSimulator.SimError, code=403`, "Incompatible device".

Yet the same 27.1 profile says `supportedProductFamilyIDs = [2, 1]` (iPad and
iPhone), and its content is not iPhone-only:

- every app bundle that 27.0 and 27.1 both ship has the same `UIDeviceFamily`
  (no difference in the 163 common `.app` bundles of `Applications` and
  `System/Library/CoreServices`);
- `~ipad` resources: 1981 files in 27.1, 2113 in 27.0 (the difference is the
  17 apps 27.1 lacks: Bridge, Contacts, Files, Fitness, Health, Maps,
  MobileCal, MobileSMS, News, Passbook, Passwords, Photos, Preview,
  Reminders, Shortcuts, SiriApp, TVRemote — also in `home-apps.md` §4).

Other 27.1 profile keys of interest (unchanged from 27.0 unless noted):
`supportedFeaturesConditionalOnDeviceType` lists `com.apple.hid.pointer.system`
and `com.apple.hid.touch-pressure`; `supportedFeatures` lists
`com.apple.CoreSimulator.display.rotation`.

## 2. Device type bundles (level 2)

Bundle: `/Library/Developer/CoreSimulator/Profiles/DeviceTypes/<name>.simdevicetype/Contents/`:
`Info.plist` (package type `BNDL`, `CFBundleIdentifier`
`com.apple.CoreSimulator.SimDeviceType.<id>`), a `MacOS/<name>` executable
(not examined), `Resources/profile.plist`, `Resources/capabilities.plist`,
one or two PDFs named by UUID (framebuffer masks; iPhone Duo also a
`sensor_bar_class_04.pdf`), `en.lproj/InfoPlist.strings`.

### 2.1 profile.plist

| Key | iPad (A16) | iPad Pro 13-inch (M5) | iPhone Duo |
|---|---|---|---|
| `modelIdentifier` | iPad15,7 | iPad17,4 | iPhone19,4 |
| `representedModelIdentifiers` | iPad15,7, iPad15,8 | iPad17,3, iPad17,4 | iPhone19,4 |
| `productClass` | J481 | J821 | V68 |
| `aliases` | — | — | `…SimDeviceType.V68` |
| `minRuntimeVersion` | 18.3 | 26.0 | 27.1 |
| `createByDefaultForRuntimeVersions` | 18.3–99.99 | 26.0–99.99 | 27.1–99.99 |
| `pairByDefaultForRuntimeVersions` | — | — | 27.1–99.99 |
| `environment` | `SIMULATOR_LEGACY_ASSET_SUFFIX` = ipad | ipad | iphone |
| `springBoardConfigName` | iPadSimulatorHiDPI | iPadSimulatorHiDPI | iPhone4Simulator |
| `chromeIdentifier` | …chrome.tablet4 | …chrome.tablet5 | …chrome.phone15 |
| `framebufferMask` | a UUID (PDF in Resources) | a UUID | a UUID |
| `sensorBarImage` | — | — | sensor_bar_class_04 |
| `supportedArchs` | arm64, x86_64 | same | same |
| `supportedProductFamilyIDs` | 2, 1 | 2, 1 | 1 |
| `supportedFeatures` | display.integrated, display.supports-external, hid.keyboard, hid.touch-screen | the same + `pearl-id` | the same + `CoreSimulator.framebuffer.27`, `display.aot`, `hid.staccato`, `touch-id` |
| `supportedFeaturesConditionalOnRuntime` | deviceIdentity, hid.applepay.authorize, **hid.pointer.system**, touch-id | deviceIdentity, hid.applepay.authorize, **hid.pointer.system** | carplay, display.resizableScene, pairing, deviceIdentity, display.ambient-overlay, hid.applepay.authorize, location.nearby-interaction, watch.pairing.companion, watch.pairing.qws |

`hid.pointer.system` appears in every iPad device type and in no iPhone
device type of the list checked (iPhone Duo, iPhone 18 Pro).

### 2.2 All iPad device types (from `profile.plist` + `capabilities.plist`)

Screen = `ScreenDimensionsCapability` width × height @ scale; ppi =
`main-screen-pitch`; msc = `main-screen-class`; mso =
`main-screen-orientation` (radians); Hz = `displays[0].refreshRate`;
bio = `pearl-id` (Face ID) or `touch-id`; EMT =
`DeviceSupportsEnhancedMultitasking`. Rows for runtimes older than 26 are
omitted except to note that their pattern is the same.

| Name | Model | Class | min RT | default for | Screen | ppi | msc | mso | corner | Hz | Home btn | bio | EMT | mem | GPU family | gamut |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| iPad Pro 13-inch (M5) | iPad17,4 | J821 | 26.0 | 26.0–99.99 | 2064×2752@2 | 264 | 32 | π/2 | 30 | 60 | 2 | pearl | yes | 12 | APPLE10 | P3 |
| iPad Pro 13-inch (M5) (16GB) | iPad17,4 | J821 | 26.0 | — | same | | | | | | | | | 16 | | |
| iPad Pro 11-inch (M5) | iPad17,2 | J818 | 26.0 | 26.0–99.99 | 1668×2420@2 | 264 | 33 | π/2 | 30 | 60 | 2 | pearl | yes | 12 | APPLE10 | P3 |
| iPad Pro 11-inch (M4) | iPad16,4 | J718 | 17.4 | 17.4–18.99 | 1668×2420@2 | 264 | 33 | π/2 | 30 | 60 | 2 | pearl | yes | 8 | APPLE9 | P3 |
| iPad Pro 13-inch (M4) | iPad16,6 | J721 | 17.4 | 17.4–18.99 | 2064×2752@2 | 264 | 32 | π/2 | 30 | 60 | 2 | pearl | yes | 8 | APPLE9 | P3 |
| iPad Air 13-inch (M4) | iPad16,11 | J738 | 26.3 | 26.3–99.99 | 2048×2732@2 | 264 | 11 | π/2 | 18 | 60 | 2 | touch | yes | 12 | APPLE9 | P3 |
| iPad Air 11-inch (M4) | iPad16,9 | J708 | 26.3 | 26.3–99.99 | 1640×2360@2 | 264 | 23 | 0 | 18 | 60 | 2 | touch | yes | 12 | APPLE9 | P3 |
| **iPad (A16)** | iPad15,7 | J481 | 18.3 | 18.3–99.99 | 1640×2360@2 | 264 | 23 | 0 | 25 | 60 | 2 | touch | **no** | 6 | APPLE8 | sRGB |
| iPad mini (A17 Pro) | iPad16,2 | J411 | 18.1 | 18.1–99.99 | 1488×2266@2 | 326 | 28 | π/2 | 21.5 | 60 | 2 | touch | no | 8 | APPLE9 | P3 |
| iPad Air 11/13-inch (M3) | iPad15,3 / 15,5 | J607 / J637 | 18.3 | 18.3–26.2 | 1640×2360 / 2048×2732 @2 | 264 | 23 / 11 | 0 / π/2 | 18 | 60 | 2 | touch | yes | 8 | APPLE9 | P3 |
| iPad (9th generation) | iPad12,2 | J182 | 15.0 | 15.0–16.0 | 1620×2160@2 | 264 | 21 | 0 | 0 | 60 | **0** | touch | — | 4 | APPLE6 | sRGB |

Every iPad device type has scale 2, refresh rate 60 and the
`springBoardConfigName` iPadSimulatorHiDPI. Six device types are created by
default for 27.x runtimes (the `createByDefault` ranges that include 27.x):
iPad Pro 13-inch (M5), iPad Pro 11-inch (M5), iPad Air 13-inch (M4),
iPad Air 11-inch (M4), iPad (A16), iPad mini (A17 Pro).

### 2.3 capabilities.plist, iPad against iPhone Duo

Same structure as `device-capabilities.md` §1 (`capabilities`, legacy
`iconState`). Key set differences:

- keys only in iPhone Duo: `DeviceIsMuseCapable`, `IsLargeFormatPhone`,
  `MainScreenClass`, `bluetooth-le`, `cellular-data`, `hardware-keyboard`,
  `shoebox`;
- key only in the iPad files: `graphicsClass` = 3 (in iPad (A16) and
  iPad Pro 13-inch (M5); absent from iPad Pro 11-inch (M5)).

In both iPad files `ArtworkDeviceScaleFactor`, `main-screen-scale`,
`DeviceCornerRadius` and `main-screen-orientation` are reals (`2.0`, `25.0`,
…); the other numbers are integers.

Value differences (iPad (A16) / iPad Pro 13-inch (M5) / iPhone Duo):

| Key | A16 | Pro 13 M5 | iPhone Duo |
|---|---|---|---|
| `idiom`, `ArtworkTraits.ArtworkDeviceIdiom` | pad | pad | phone |
| `ipad` | true | true | false |
| `device-name` | iPad Simulator | iPad Simulator | iPhone Simulator |
| `marketing-name` | iPad (A16) | iPad Pro 13-inch (M5) | iPhone Duo |
| `ArtworkDeviceProductDescription` | iPad (A16) | iPad Pro 13-inch (M5) | iPhone |
| `ArtworkDeviceScaleFactor`, `main-screen-scale` | 2 | 2 | 3 |
| `ArtworkDeviceSubType`, `subtype`, `main-screen-height` | 2360 | 2752 | 2034 |
| `main-screen-width` | 1640 | 2064 | 1398 |
| `main-screen-pitch` | 264 | 264 | 460 |
| `main-screen-class` | 23 | 32 | 36 |
| `main-screen-orientation` | 0 | 1.5707963705062866 | 0 |
| `ArtworkDisplayGamut`, `displayGamut` | sRGB | P3 | P3 |
| `CompatibleDeviceFallback` | iPad13,18 | iPad16,6-A | iPhone18,3 |
| `DevicePerformanceMemoryClass`, `memoryClass` | 6 | 12 | 12 |
| `GraphicsFeatureSetClass` / `graphicsFeatureSetClass` | APPLE8 | APPLE10 | APPLE11 |
| `GraphicsFeatureSetFallbacks` | APPLE7:…:GLES2,0 | APPLE9:…:GLES2,0 | APPLE10:…:GLES2,0 |
| `DeviceCornerRadius` | 25 | 30 | 59 |
| `HomeButtonType` | 2 | 2 | 2 |
| `ModelNumber`, `RegulatoryModelNumber` | A3354 | A3361 | A3447 |
| `ThinningProductType` | iPad15,7 | iPad17,4-A | iPhone19,4 |
| `DeviceSupportsEnhancedMultitasking` | false | true | false |
| `DeviceSupportsSingleDisplayEnhancedMultitasking` | false | false | false |
| `DeviceSupportsDynamicIsland` | false | false | true |
| `FloatingLiveAppOverlay`, `PiPOverlay`, `PiPPinned`, `hide-non-default-apps` | true | true | false |
| `reverse-zoom` | false | true | false |
| `pearl-id` / `touch-id` | false / true | true / false | false / true |
| `GPSCapability` | false | true | true |
| `contains-cellular-radio` | false | true | true |
| `always-on-time`, `sms`, `telephony`, `unified-ipod`, `watch-companion` | false | false | true |

`displays` (CoreSimulator's host-side display list): iPads list two —
`LCD`/`primary` (integrated, digitizer, `refreshRate` 60, `nativeOrientation`
and `nativeRotation` 0 for A16, 270 for Pro 13 M5) and `TVOut`/`external-0`
(720×480, scale 1, no digitizer, power 0). iPhone Duo lists five (`LCD`,
`LCD-1` second integrated panel, `TVOut`, `Wireless` CarPlay, `Resizable`).

The legacy `iconState` of the iPad file lists an old iPad layout (Safari,
Mail, Photos, Music dock); like the iPhone's it is not used (§3.3).

## 3. Booted devices on iOS 27.0 (level 3)

### 3.1 First boot and second boot

Sequential first boots (`simctl bootstatus -b`, host load ~900):
iPhone 18 Pro 49.1 s, iPad (A16) 54.2 s, iPad Pro 13 M5 55.0 s. All three
ran the 35 data-migration plugins (same chain as `first-boot.md` §1; the
LaunchServices migrator dominated). Second boot of the iPad Pro (host load
~600): 16.6 s. Before the first boot the iPad and iPhone device
directories were identical (88 entries, same paths).

### 3.2 Environment of guest processes

`ps -E` of backboardd. Same variable set for iPad and iPhone except that
the **iPad lacks** `SIMULATOR_EXTENDED_DISPLAY_PROPERTIES` and
`IPHONE_TVOUT_EXTENDED_PROPERTIES` (iPhone 18 Pro has both, pointing at
`DEV/data/Library/Application Support/Simulator/extended_display.plist`).
Values that change: `SIMULATOR_MODEL_IDENTIFIER` (iPad15,7 / iPad17,4),
`SIMULATOR_PRODUCT_CLASS` (J481 / J821), `SIMULATOR_LEGACY_ASSET_SUFFIX`
(ipad), `SIMULATOR_MAINSCREEN_WIDTH/HEIGHT/SCALE/PITCH` (1640/2360/2.000000/
264.000000 and 2064/2752/2.000000/264.000000), `SIMULATOR_CAPABILITIES`
(the device type's file). No iPad-only variable exists; no iPad-only host
service was seen.

### 3.3 Home screen

Screenshots: portrait, 1640 × 2360 and 2064 × 2752. Layout from
`IconState.plist` (same for both iPad models; `home-apps.md` §5 has the
item list): page 1 with a large widget stack (News, Maps, Photos), a large
stack (Reminders + a `files` element), a medium Calendar widget, then
Files, Reminders, Maps, News, Settings; page 2 with seven apps; dock
(`buttonBar`) Messages, Safari, Calendar, Photos, Siri plus the dock's
recent/App Library folder. iPad-only keys: `dockUtilities` (empty) and
`listMetadata` per page (`fixedLocationsGridColumns` 4,
`fixedLocationsGridRows` 6, `rotatedFixedLocations`, `rotatedOrder` — the
landscape order). The iPhone layout has neither key.

SpringBoard preferences: the iPad has `SBBottomLeftCornerGestureTouchTypes`
= 3, `SBBottomRightCornerGestureTouchTypes` = 3, `SBGestureRequiresEducation-Corner`
= 1, `SBDefaultKeyCommandTabPlistRepresentation` = [] which the iPhone lacks.

SpringBoard's log on the iPad: `FBSDisplayConfiguration … Main; mode:
"1032x1376@2x 60Hz p3 SDR"`, `orientationMode=dynamic` for its scene
participants, "Animating wallpaper orientation to portrait (1)", and
app-switcher events of kind `ContinuousExposeIdentifiersChanged`.

### 3.4 Processes and jobs

- launchd job set: 363 labels in both runtimes' LaunchDaemons/Agents/Angels
  (identical label sets, §5). No job plist is limited by device class: the
  only load-limiting keys are `_LimitLoadToVariant`, `LimitLoadFromHardware`
  (`osenvironment` recovery/diagnostics), `LimitLoadToDeveloperMode`,
  `_LimitLoadFromVariant`, `_LimitLoadFromDeviceTree`,
  `_LimitLoadFromClarityMode`, `MinimalBootProfile`, `EmbeddedHomeScreen`.
  So the loaded job set is the same for iPad and iPhone.
- `launchctl list` on the iPad Pro (second boot): 380 lines, 144 running.
  The iPhone's could not be taken (§3.6).
- Running only on the iPads (host `ps` by `SIMULATOR_UDID`):
  **`DockFolderViewService`** (`Applications/DockFolderViewService.app`,
  bundle `com.apple.DocumentManager.DockFolderViewService`, hosted as a
  scene by SpringBoard — the dock folder), `fileproviderd`,
  `iCloudDriveFileProvider`, `bird` (the Files widget). Running only on the
  iPhone: `nanoregistryd` (watch pairing), `healthd`; the many poster
  extensions ran later on the iPads too (second boot), so they are not
  iPhone-only.

### 3.5 Display, refresh rate, screen

Our probe `screenprobe` (UIKit + MobileGestalt by name, `simctl spawn`) on
the iPad Pro 13 M5: `idiom=1`, `model=iPad`, `systemName=iPadOS`, bounds
1032 × 1376 points, nativeBounds 2064 × 2752, scale 2,
`maximumFramesPerSecond` **60**; `MGCopyAnswer`: DeviceClass iPad,
ProductType iPad17,4, `DeviceSupportsEnhancedMultitasking` 1, `ipad` 1,
`hardware-keyboard` 0 (key absent from the file), `DeviceCornerRadius` 30,
`HomeButtonType` 2, `DeviceSupportsDynamicIsland` 0.

Our probe `sfbprobe` (the framebuffer client library, `simframebuffer.md`
§3) on the same device: two displays.

| Display | Type | Name / device name | Mode record (§3.5 of simframebuffer.md), hex words |
|---|---|---|---|
| 0 | 0 | LCD / primary | `1, 0x810 (2064), 0xAC0 (2752), 2, 1, 'BGRA', 2, 0x1770 (6000), bytes 01 01 01` |
| 1 | 1 | TVOut / external-0 | `2, 720, 480, 1, 1, 'BGRA', 1, 6000, bytes 00 01 01` |

Device size 2064 × 2752, dot pitch 264, mask path = the device type's
framebuffer-mask PDF (`/Library/Developer/DeviceKit/FramebufferMasks/<UUID>.pdf`).
Offset 28 is 6000 on the iPad Pro as on the iPhone: no 120 Hz mode in the
simulator. backboardd: "StartWindowServer: digitizerToPanelRotation=0
layoutRotation=0", "main display info … size:{2064,2752} scale:2
nativeRotation:0" — although the capabilities file says
`nativeOrientation` 270 and `main-screen-orientation` π/2 for this model.

### 3.6 HID (backboardd log)

The reference HID bundle publishes the same services on the iPad as on the
iPhone (IDs `0xACEFADE0000000nn`): 0 GamePad, 1 MainScreenButtons,
2 ExternalKeyboard, 3 ProximitySensor, 4 PalomaPose, 5 SelectionStream,
6 Manipulator, then one `ScreenTouchService.<display UUID>` per display
with a digitizer — one on the iPad (ID 7), two on the iPhone 18 Pro (7, 8).
"Hardware keyboard attached (countryCode:0 type:-1 layout:US)" on both.

backboardd registers `BKHIDMousePointerEventProcessor` and starts a
`BKMousePointerController` on **both** idioms. The controller matches
services with `DeviceUsagePage` 1 / `DeviceUsage` 2 (mouse); at boot it
finds none ("Services discovered: [] …", "devices:NO"). So the reference
publishes no pointer service at boot; a pointer service appears only when
the host offers pointer input (not exercised here).

### 3.7 What failed and why (host, not iPad)

While the host was at load ~900 with swap almost full, every new process
launch in the 27.0 devices stalled: 85 guest processes and
`xpcproxy_sim … oneshot …launchctl` sat in state U for 25 minutes;
`simctl spawn` timed out; the iPads (booted after the iPhone) showed grey
icon placeholders and a black wallpaper because MTLCompilerService and the
poster extensions could not start. After shutting the devices down and
rebooting one iPad when the load fell, the same iPad showed the wallpaper
and icons within seconds and `spawn` worked. Thirteen crash reports
(AppIntentsLiveEntityService, chronod, tccd, …) name the 27.0 devices; they
came from both idioms around the shutdowns and are not iPad-specific.

## 4. Not observed

- Rotation of a booted iPad (no Simulator.app; another agent is working on
  the orientation path, `hid-input.md` §10).
- Pointer input and pointer hover effects (needs the host pointer path).
- The multitasking mode switch (Settings › Multitasking & Gestures) and
  Stage Manager on the TVOut display.

## 5. Runtime layout: 27.0 (24A434) against 27.1 (24A94401)

| Item | 27.0 | 27.1 |
|---|---|---|
| Runtime bundle `CFBundleVersion` | 392 | 394.1 |
| `SystemVersion.plist` | iPhone OS 27.0, 24A434 | iPhone OS 27.1, 24A94401 |
| `restrictedToDeviceTypes` | absent | [V68] |
| Runtime volume (APFS disk image, used) | 17 GiB | 16 GiB |
| Apps (`Applications` + `CoreServices` `.app` with Info.plist) | 180 | 163 |
| launchd job labels | 363 | 363 (same set) |
| `RR/System/Library/Caches/com.apple.dyld/` | `dyld_sim_shared_cache_arm64` 2 043 297 792 B, `.01` 1 786 019 840 B, `.atlas`, `.map` | 2 035 384 320 B, `.01` 1 748 582 400 B, `.atlas`, `.map` |
| Images in the cache (`.map`) | 1826 | 1819 |
| Only in one cache | 12 in 27.0 only (Maps/MobileCal/MobileMail accessibility bundles, MailUI, NotesEditor, CallsAppServices, icloudMCCKit, …, and `GPUCompiler…/32023/Libraries/libLLVM.dylib`) | 5 in 27.1 only (CalendarPoster, ClockFacePosters, ClockFacePostersUI, ShellSceneKit, SimpleClockFacePosters) |
| `GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib` | in the shared cache, no file | a 39 MB file on disk, not in the cache |
| `usr/lib/dyld_sim`, `sbin/launchd_sim` | present; different files (SHA-256 differ) | present |

## 6. The 27.1 runtime with an iPad identity (level 3)

CoreSimulator refuses an iPad device on 27.1, but Ycode does not use
CoreSimulator. To see whether the runtime itself runs as an iPad, an
iPhone Duo device on 27.1 was booted with `SIMCTL_CHILD_` overrides of the
device identity (CoreSimulator passes them into the device's launchd
environment; checked with `ps -E` of backboardd):
`SIMULATOR_CAPABILITIES` = the iPad Pro 13-inch (M5) `capabilities.plist`
(host file, read in place), `SIMULATOR_MAINSCREEN_*` = 2064 / 2752 /
2.000000 / 264.000000, `SIMULATOR_MODEL_IDENTIFIER` = iPad17,4,
`SIMULATOR_PRODUCT_CLASS` = J821, `SIMULATOR_LEGACY_ASSET_SUFFIX` = ipad,
and `SIMULATOR_FRAMEBUFFER_FRAMEWORK` = our headless framebuffer prototype
(`research/experiments/simulator/simframebuffer/sfbheadless.c`, which takes
its geometry from `SIMULATOR_MAINSCREEN_*`).

Result:

- first boot finished in 20.6 s (35 migration plugins, as on the iPhone);
- backboardd: "initial main screen size:{2064, 2752} scale:2",
  "MG scale:2 display preferredScale:2", nativeRotation 0;
- `screenprobe`: idiom 1, model iPad, **systemName iPadOS**, systemVersion
  27.1, 1032 × 1376 points, 60 fps; MG DeviceClass iPad, ProductType
  iPad17,4, `DeviceSupportsEnhancedMultitasking` 1;
- `IconState.plist` is an **iPad** layout: page 1 = a large `files`
  element and Settings; dock = Safari; `dockUtilities` = []; `listMetadata`
  with `rotatedOrder`; Today view two widgets;
- running: SpringBoard, PosterBoard and its poster extensions,
  **DockFolderViewService**, fileproviderd; no crash report names the
  device.

So the 27.1 runtime's own content works as an iPad when the host gives it
an iPad identity. There is no Apple reference for this combination (the
simulator refuses it), and its app set is the reduced 27.1 one.
