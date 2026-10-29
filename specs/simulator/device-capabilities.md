# Spec: the device-capabilities plist (SIMULATOR_CAPABILITIES)

Status: **reference** for stages 7–8 (integrator H, 2026-10-13). It says
which file the runtime reads to learn what kind of device it runs on, what
happens without it, and what Ycode writes. Facts come from the device-type
bundle read as a file format on this Mac (level 2), the environment of a
booted iOS 27.1 simulator's processes (`ps -E`, level 3), and Ycode runs on
the Thor (level 3). No disassembly was used.

## 1. The variable and the file

- Every process of a booted simulator has `SIMULATOR_CAPABILITIES` in its
  environment. On the Mac it names the device type's
  `capabilities.plist` (inside CoreSimulator's
  `…/DeviceTypes/<name>.simdevicetype/Contents/Resources/`), a host file.
- The file is an XML property list with a top-level dictionary. The key
  `capabilities` holds a dictionary of device answers, keyed by the names
  that MobileGestalt questions use (`ArtworkTraits`, `idiom`,
  `ScreenDimensionsCapability`, `DeviceSupportsDynamicIsland`, …). A second
  top-level key, `iconState`, holds a legacy home-screen layout that the
  iOS 27.1 runtime does not use for its default layout (the home screen
  comes from the runtime's own default state; see §4).
- The display geometry in the file agrees with the
  `SIMULATOR_MAINSCREEN_WIDTH/HEIGHT/SCALE/PITCH` variables. For model
  `iPhone19,4` (device type "iPhone Duo") the Mac gives 1398 × 2034, scale
  3, pitch 460.

## 2. Without the file

Ycode set the variable to an empty string until 2026-10-13. Observed on the
Thor (level 3, `log stream` one-shot):

- every process that asks MobileGestalt logs "can't load simulator
  capabilities dictionary from" (empty path);
- CoreUI, which picks image renditions from asset catalogs by device
  traits, logs "couldn't get 'kMGArtworkDeviceIdiom' from MGCopyAnswer"
  and "couldn't get 'kMGArtworkGraphicsFeatureSetClass'" (fault level) in
  iconservicesagent.

With the file (§3) these messages are gone. (The grey icons of the first
Ycode home screens had other causes as well; `home-screen.md` §2.)

## 3. What Ycode writes

`ycode-simd --device` writes `DEV/ycode-capabilities.plist` on every boot and
sets `SIMULATOR_CAPABILITIES` to its path. The file has one key,
`capabilities`, with these entries for Ycode's single device model
(`iPhone19,4`; the values are the device type's own, read from its
`capabilities.plist`, level 2):

| Key | Value |
|---|---|
| `ArtworkTraits` | `ArtworkDeviceIdiom` "phone", `ArtworkDeviceProductDescription` "iPhone", `ArtworkDeviceScaleFactor` 3, `ArtworkDeviceSubType` 2034, `ArtworkDisplayGamut` "P3", `ArtworkDynamicDisplayMode` "0", `CompatibleDeviceFallback` "iPhone18,3", `DevicePerformanceMemoryClass` 12, `GraphicsFeatureSetClass` "APPLE11", `GraphicsFeatureSetFallbacks` "APPLE10:APPLE9:APPLE8:APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0" |
| `ScreenDimensionsCapability` | `main-screen-class` 36, `main-screen-height` 2034, `main-screen-orientation` 0, `main-screen-pitch` 460, `main-screen-scale` 3, `main-screen-width` 1398 |
| `idiom` | "phone" |
| `modelIdentifier`, `ThinningProductType` | "iPhone19,4" |
| `ModelNumber`, `RegulatoryModelNumber` | "A3447" |
| `device-name` | "iPhone Simulator" |
| `DeviceCornerRadius` 59, `HomeButtonType` 2, `MainScreenClass` 18, `memoryClass` 12, `subtype` 2034, `software-dimming-alpha` 0 | numbers |
| `displayGamut` | "P3" |
| `graphicsFeatureSetClass`, `graphicsFeatureSetFallbacks` | as in `ArtworkTraits` |
| true | `720p`, `accelerometer`, `accessibility`, `always-on-time`, `applicationInstallation`, `arm64`, `armv6`, `armv7`, `armv7s`, `ASTC`, `bluetooth`, `bluetooth-le`, `cellular-data`, `contains-cellular-radio`, `DeviceSupports3DImagery`, `DeviceSupports3DMaps`, `DeviceSupportsAdaptiveMapsUI`, `DeviceSupportsAdvancedMapRendering`, `DeviceSupportsDynamicIsland`, `DeviceSupportsHiResBuildings`, `displayport`, `encrypted-data-partition`, `full-6`, `gamekit`, `gas-gauge-battery`, `GPSCapability`, `hardware-keyboard`, `HasThinBezel`, `HEVCDecoder8bitSupported`, `HEVCDecoder10bitSupported`, `HEVCDecoder12bitSupported`, `HEVCEncodingCapability`, `hidpi`, `homescreen-wallpaper`, `international-settings`, `IsLargeFormatPhone`, `load-thumbnails-while-scrolling`, `location-services`, `magnetometer`, `metal`, `microphone`, `multitasking`, `opengles-1`, `opengles-2`, `peer-peer`, `screenrecorder`, `shoebox`, `sms`, `stand-alone-contacts`, `telephony`, `touch-id`, `unified-ipod`, `watch-companion`, `wifi` |
| false | `DeviceIsMuseCapable`, `DeviceSupportsElton`, `DeviceSupportsEnhancedMultitasking`, `DeviceSupportsSingleDisplayEnhancedMultitasking`, `FloatingLiveAppOverlay`, `hide-non-default-apps`, `ipad`, `MLEHW`, `OysterCapability`, `pearl-id`, `PiPOverlay`, `PiPPinned`, `reverse-zoom`, `ringer-switch`, `RingerButtonCapability`, `SupportsForceTouch` |

Left out: `marketing-name`; the legacy `iconState`; the `displays` array
(§3.1) except for a foldable with its inner panel published (since FOLD2,
2026-10-27: the iPhone Duo by default). *Correction (OBS-FOLD2, 2026-10-27): `displays` is not only a
host-side list. The guest reads it from this file and takes each built-in
panel's role (cover, inner) from it; without it a two-panel device's
SpringBoard stops (§3.1, `foldable.md` §9 Q7). A foldable must have it.* Ycode's main display (`SIMULATOR_MAINSCREEN_*` and its headless
SimFramebuffer's default) is 1398 × 2034 @3, pitch 460, matching the table;
before 2026-10-13 it was 1206 × 2622, which no device type of model
iPhone19,4 has.

### 3.1 The `displays` array

`displays` is a key **inside** `capabilities` (not at the top level). Its
value is an array of dictionaries, one per display port of the device. For
the iPhone Duo (`iPhone19,4`) it has five entries, in this order (level 2):

| Key | Type | `LCD` | `LCD-1` | `TVOut` | `Wireless` | `Resizable` |
|---|---|---|---|---|---|---|
| `displayName` | string | `LCD` | `LCD-1` | `TVOut` | `Wireless` | `Resizable` |
| `deviceName` | string | `primary` | `primary-1` | `external-0` | `wireless0` | `resizable` |
| `displayType` | string | `integrated` | `integrated` | `tvOut` | `carPlay` | `scene` |
| `screenID` | integer | 1 | 3 | 2 | 4 | 5 |
| `width`, `height` | integer | 1398, 2034 | 2007, 2853 | 720, 480 | 720, 480 | 7680, 4320 |
| `scale` | real | 3.0 | 3.0 | 1.0 | 1.0 | 3.0 |
| `hdpi`, `vdpi` | real | 460.0 | 460.0 | 72.0 | 72.0 | 120.0 |
| `refreshRate` | real | 60.0 | 60.0 | 60.0 | 60.0 | 60.0 |
| `colorspace` | string | `P3` | `sRGB` | `sRGB` | `sRGB` | `sRGB` |
| `powerState` | integer | 1 | 1 | 0 | 0 | 0 |
| `hasDigitizer` | boolean | true | true | false | false | true |
| `surfaceType` | integer | **1** | **2** | — | — | — |
| `nativeOrientation` | integer | 0 | 270 | — | — | — |
| `nativeRotation` | integer | 0 | 270 | — | — | — |
| `cornerRadiusUL`, `…LL`, `…UR`, `…LR` | real | 8.0, 8.0, 59.0, 59.0 | 55.0 each | — | — | 0.0 each |
| `chromeIdentifier` | string | `com.apple.dt.devicekit.chrome.phone15` | `com.apple.dt.devicekit.chrome.phone14` | — | — | — |
| `framebufferMaskIdentifier` | string | `1C896A2B-F0D7-405C-8D0F-66E4B80AD044` | `BF0DC480-5EE2-4EC1-B02B-C75E94759832` | — | — | — |
| `requiredFeatures` | array of string | — | — | — | — | `com.apple.CoreSimulator.display.resizableScene` |

"—" = key absent. Single-panel iPhones have the same list without the
`LCD-1` entry (`iphone-types.md` §3.3).

How the guest uses it (level 3, black-box boots on the Mac with
`SIMULATOR_CAPABILITIES` pointing at edited copies; `foldable.md` §9 Q7):

- Every guest process sees the file through `SIMULATOR_CAPABILITIES`;
  `SIMCTL_CHILD_SIMULATOR_CAPABILITIES` on `simctl boot` replaces the path in
  every guest process, while the host's display list stays the device type's.
- SpringBoard takes each built-in panel's **surface** from the `surfaceType`
  of that panel's `integrated` entry: 1 → `.cover`, 2 → `.inner`. Swapping
  the two values swaps the roles. Without `displays`, without
  `surfaceType`, or with an incomplete entry, the panel's surface is
  `.default` and a two-panel SpringBoard stops on the cloning-source
  assertion (killed and restarted by launchd, again and again).
- An `integrated` entry counts only when it is complete. Removing
  `chromeIdentifier`, `framebufferMaskIdentifier` or the four corner radii
  made it count as missing; removing `colorspace` and `refreshRate` did not.
  Two entries with exactly these twenty keys worked: `displayName`,
  `deviceName`, `displayType`, `screenID`, `width`, `height`, `scale`,
  `hdpi`, `vdpi`, `powerState`, `hasDigitizer`, `surfaceType`,
  `nativeOrientation`, `nativeRotation`, the four `cornerRadius*`,
  `chromeIdentifier`, `framebufferMaskIdentifier`. Whether each of the first
  fourteen is needed was not tested one by one.
- The `TVOut`, `Wireless` and `Resizable` entries are not needed for the
  surfaces (a list with only the two integrated entries worked).

**Ycode decision:** for a device type with a second built-in panel, Ycode
writes the type's whole `displays` array (all five entries, all keys, the
types above) into `DEV/ycode-capabilities.plist`, inside `capabilities`.
The values are facts read from the device type. The mask and chrome
identifiers are written as strings only; Ycode ships no mask or chrome
file.

**What Ycode writes (FOLD2, 2026-10-27).** `ycode-simd` writes the iPhone
Duo's `displays` array exactly as the table above: five dictionaries in
the order `LCD`, `TVOut`, `LCD-1`, `Wireless`, `Resizable`; integers for
`screenID`, `width`, `height`, `powerState`, `surfaceType`,
`nativeOrientation`, `nativeRotation`; reals for `scale`, `hdpi`, `vdpi`,
`refreshRate` and the corner radii; booleans for `hasDigitizer`; an array
of strings for `requiredFeatures`. Each built-in entry has 22 keys (the
twenty that worked on the reference plus `colorspace` and `refreshRate`),
`TVOut` and `Wireless` 13, `Resizable` 18. The record is
`DisplayEntry.iPhoneDuo` in `ycode-simd/DeviceTypes.swift`; the `LCD-1`
entry is built from the same record as the framebuffer library's second
display (id 3, `LCD-1`, `primary-1`, 2007 × 2853 @3, 460 dpi, mounted at
270°), and the `LCD` entry agrees with `SIMULATOR_MAINSCREEN_*`; the
other three agree with the list the library publishes (`simframebuffer.md`
§4, §10).

- The array is written **only together with the inner panel**: by default
  for a foldable (`foldable.md` §10.4); with `YCODE_FOLD_DISPLAYS=0` the
  framebuffer library publishes the cover only and the file is byte for
  byte the file before 2026-10-27 (no `displays`). Other device types
  (iPhone 18 Pro, iPads, Apple Vision Pro) still get no `displays`.
- No mask or chrome file: the identifiers are strings only, and the
  framebuffer library's `SFBDisplayGetMaskPath` stays NULL. Result under
  Ycode: see `foldable.md` §10.4.

## 4. Note: the default home screen of this runtime

A fresh iOS 27.1 device of this type on the Mac (level 3: `simctl create`,
`boot`, screenshot, and `DEV/data/Library/SpringBoard/IconState.plist`
read with `plutil`) shows **Settings** on the first page and **Safari** in
the dock, nothing else; `IconState.plist` holds exactly
`iconLists = [[com.apple.Preferences]]`, `buttonBar = [com.apple.mobilesafari]`
and the Today widgets. `DesiredIconState.plist` (written later) lists a full
iPhone layout, but the home screen does not use it. Ycode's device shows the
same two icons, so the short app set is the reference behavior, not a fault.

## Evidence

| Claim | Level | Source |
|---|---|---|
| The variable and its value on the Mac (§1) | 3 | `ps -E` of PosterBoard in a booted throwaway iOS 27.1 device |
| File structure and values (§1, §3) | 2 | the device type's `capabilities.plist` and `profile.plist` read with `plutil` |
| Failures without the file (§2) | 3 | Ycode `log stream` one-shot on the Thor (iconservicesagent, CoreUI lines) |
| Default home screen (§4) | 2, 3 | Mac `simctl io screenshot`; `IconState.plist`, `DesiredIconState.plist` via `plutil` |
| What Ycode writes | — | Ycode decision from the above |
| The `displays` array Ycode writes (§3.1 "What Ycode writes") | — | Ycode decision; unit test `DeviceTypeTests.iPhoneDuoDisplaysList` checks every key, value and plist type against the table |
| `displays` structure, key types and values (§3.1) | 2 | the iPhone Duo device type's `capabilities.plist` read with `plistlib` (OBS-FOLD2) |
| The guest reads `displays`; surface roles, required keys (§3.1) | 3 | reference boots of throwaway iPhone Duo devices with `SIMCTL_CHILD_SIMULATOR_CAPABILITIES` pointing at edited copies: SpringBoard log stream, `ps -E`, launchd run counts, crash-report frame names (OBS-FOLD2) |

Level 5 was not used; `.claude/Xcode.app`, `research/dirty/` and Ghidra were
not opened.
