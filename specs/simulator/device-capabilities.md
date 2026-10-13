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

Left out: `marketing-name`; the `displays` array (CoreSimulator's host-side
display list: chrome, masks, secondary and external displays); the legacy
`iconState`. Ycode's main display (`SIMULATOR_MAINSCREEN_*` and its headless
SimFramebuffer's default) is 1398 × 2034 @3, pitch 460, matching the table;
before 2026-10-13 it was 1206 × 2622, which no device type of model
iPhone19,4 has.

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

Level 5 was not used; `.claude/Xcode.app`, `research/dirty/` and Ghidra were
not opened.
