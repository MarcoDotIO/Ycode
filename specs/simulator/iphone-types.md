# Spec: iPhone device types in the Ycode simulator (iPhone 18 Pro)

Status: **proposed** (OBS-IPHONE18, 2026-10-27). It gives the facts a
clean agent needs to add a second iPhone identity, **iPhone 18 Pro**, to
`ycode-simd`, in the same form as `ipad.md` §3–§4 and
`device-capabilities.md` §3. The reason is the iOS 27.0 runtime (24A434):
it ships Maps, Calendar, Photos, Messages and other apps that 27.1 lacks
(`home-apps.md` §4), but it does not accept Ycode's current iPhone
identity, iPhone Duo. Observations behind it:
`research/notes/obs-iphone18-2026-10-27.md`. It builds on
`device-capabilities.md`, `ipad.md`, `first-boot.md`, `home-apps.md` and
`launchd-sim.md`; it does not repeat them.

Facts come from the device-type and runtime bundles read as file formats
(level 2) and from throwaway iPhone 18 Pro devices on iOS 27.0 on this Mac
(level 3). No disassembly or decompilation was used. **Ycode decision**
marks design choices. Terms as in `ipad.md`: **RR** (RuntimeRoot), **DEV**
(device directory), "identity" (the values the host gives the guest for
one device type).

## 1. Summary

1. **iPhone Duo cannot be used with 27.0.** Its device type declares
   `minRuntimeVersion` 27.1; CoreSimulator's 27.0 runtime does not list it,
   and `simctl create` of an iPhone Duo on 27.0 fails with error 403
   "Incompatible device". The newest iPhone that 27.0 accepts is the
   iPhone 18 Pro (and 18 Pro Max).
2. **iPhone 18 Pro differs from iPhone Duo in a few values only.** The
   capabilities dictionary has the same key set and number types; twelve
   keys have other values (§4.2). The launch environment has the same
   variables; the model, product class and main-screen values change
   (§4.1). It has one built-in display instead of two (§3.3).
3. **The guest picks the generic iPhone home-screen layout** for this
   screen size (402 × 874 points). A fresh 27.0 iPhone 18 Pro shows two
   pages, a two-app dock and two page-1 widgets (`home-apps.md` §4.1).
4. **Recommendation (Ycode decision):** add the type as data
   (`iphone-18-pro`), keep `iphone-duo` the default for the 27.1 runtime,
   and use `iphone-18-pro` as the default for 27.0 (§5).

## 2. Runtimes and iPhone device types

`xcrun simctl list runtimes -j` (`supportedDeviceTypes`), Xcode 27.1:

| Runtime | Build | iPhone types | iPhone Duo listed | iPhone 18 Pro listed |
|---|---|---|---|---|
| iOS 26.5 | 23F77 | 31 | no | no |
| iOS 27.0 | 24A434 | 33 | **no** | yes |
| iOS 27.1 | 24A94401 | 1 | yes (the only type) | no |

The 33 iPhone types of 27.0: iPhone 18 Pro, iPhone 18 Pro Max, iPhone 17
Pro, iPhone 17 Pro Max, iPhone 17e, iPhone Air, iPhone 17, iPhone 16 Pro,
iPhone 16 Pro Max, iPhone 16e, iPhone 16, iPhone 16 Plus, iPhone 15 Pro,
iPhone 15 Pro Max, iPhone 15, iPhone 15 Plus, iPhone 14 Pro, iPhone 14 Pro
Max, iPhone 14, iPhone 14 Plus, iPhone SE (3rd generation), iPhone 13 Pro,
iPhone 13 Pro Max, iPhone 13, iPhone 13 mini, iPhone 12 Pro, iPhone 12 Pro
Max, iPhone 12, iPhone 12 mini, iPhone SE (2nd generation), iPhone 11 Pro,
iPhone 11 Pro Max, iPhone 11. (The other 29 of its 62 types are iPads.)

Why iPhone Duo is excluded from 27.0, as a file format: the 27.0 runtime's
`profile.plist` has no `restrictedToDeviceTypes`, so the device type's own
range decides, and the iPhone Duo's `minRuntimeVersion` is 27.1. The 27.0
and 27.1 runtime `profile.plist` files are otherwise the same: they differ
only in `defaultVersionString` and in 27.1's `restrictedToDeviceTypes`
(`ipad.md` §2.1). The required host services, the supported features and
the runtime environment (`LS_ENABLE_BUNDLE_LOCALIZATION_CACHING` = 1) are
identical.

## 3. The iPhone 18 Pro device type (file format)

### 3.1 Bundle

`/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 18 Pro.simdevicetype/Contents/`,
`CFBundleIdentifier` = `com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro`;
the same file set as the iPhone Duo (`ipad.md` §3.1): `profile.plist`,
`capabilities.plist`, one framebuffer-mask PDF named by UUID, the sensor-bar
PDF, a localized name. Ycode reads none of them at run time (§5).

### 3.2 profile.plist

| Key | iPhone 18 Pro | iPhone Duo |
|---|---|---|
| `modelIdentifier` | iPhone19,2 | iPhone19,4 |
| `productClass` | V63 | V68 |
| `representedModelIdentifiers` | iPhone19,2 | iPhone19,4 |
| `aliases` | absent | `com.apple.CoreSimulator.SimDeviceType.V68` |
| `environment` | `SIMULATOR_LEGACY_ASSET_SUFFIX` = iphone | iphone |
| `supportedProductFamilyIDs` | 1 | 1 |
| `supportedArchs` | arm64, x86_64 | arm64, x86_64 |
| `minRuntimeVersion`, `maxRuntimeVersion` | 27.0, – | 27.1, – |
| `createByDefaultForRuntimeVersions`, `pairByDefaultForRuntimeVersions` | 27.0–99.99 | 27.1–99.99 |
| `springBoardConfigName` | iPhone4Simulator | iPhone4Simulator |
| `supportedFeatures` | display.aot, display.integrated, display.supports-external, hid.keyboard, hid.staccato, hid.touch-screen, **pearl-id** | the same without pearl-id, plus **CoreSimulator.framebuffer.27** and **touch-id** |
| `supportedFeaturesConditionalOnRuntime` | carplay, CoreSimulator.display.resizableScene, CoreSimulator.pairing, deviceIdentity, display.ambient-overlay, hid.applepay.authorize, location.nearby-interaction, watch.pairing.companion, watch.pairing.qws | the same |
| `chromeIdentifier` | `com.apple.dt.devicekit.chrome.phone11` | `…phone15` |
| `framebufferMask`, `sensorBarImage` | a UUID, `sensor_bar_class_04` | another UUID, `sensor_bar_class_04` |

(Feature names are given without their `com.apple.` prefix.) Neither type
declares `com.apple.hid.pointer.system`.

### 3.3 capabilities.plist: displays

The `displays` array (host display list; Ycode does not write it, as for
the iPhone Duo):

| `displayName` | `displayType` | Size | Digitizer | Initial power |
|---|---|---|---|---|
| `LCD` | integrated | 1206 × 2622, scale 3, 460 dpi, refresh 60, corner radii 62 | yes | on |
| `TVOut` | tvOut | 720 × 480 | no | off |
| `Wireless` | carPlay | 720 × 480 | no | off |
| `Resizable` | scene (requires the resizable-scene feature) | 7680 × 4320, scale 3 | yes | off |

The iPhone Duo's list is the same plus a second integrated display `LCD-1`
(2007 × 2853). Consequence: on the reference, `simctl io <dev> screenshot`
without `--display` returns the `LCD` image (1206 × 2622) for the iPhone 18
Pro, while for the iPhone Duo it returns the black inner display
(`home-apps.md` §2.2). Ycode's single display matches the iPhone 18 Pro
directly.

## 4. Identity values for `iphone-18-pro`

### 4.1 Launch environment

Observed on a booted reference device (`simctl spawn <dev> /usr/bin/env`;
`launchctl getenv` returns nothing for these names). The variable **set**
is the iPhone Duo's (`launchd-sim.md` §3, `ipad.md` §4.1); values that
depend on the device type:

| Variable | iPhone 18 Pro | iPhone Duo (today) |
|---|---|---|
| `SIMULATOR_MODEL_IDENTIFIER` | iPhone19,2 | iPhone19,4 |
| `SIMULATOR_PRODUCT_CLASS` | V63 | V68 |
| `SIMULATOR_LEGACY_ASSET_SUFFIX` | iphone | iphone |
| `SIMULATOR_MAINSCREEN_WIDTH` / `HEIGHT` | 1206 / 2622 | 1398 / 2034 |
| `SIMULATOR_MAINSCREEN_SCALE` | 3.000000 | 3.000000 |
| `SIMULATOR_MAINSCREEN_PITCH` | 460.000000 | 460.000000 |
| `SIMULATOR_EXTENDED_DISPLAY_PROPERTIES`, `IPHONE_TVOUT_EXTENDED_PROPERTIES` | set (`DEV/data/Library/Application Support/Simulator/extended_display.plist`) | set (same path) |
| `SIMULATOR_CAPABILITIES` | the type's capabilities file (Ycode: `DEV/ycode-capabilities.plist`) | same rule |
| `SIMULATOR_VERSION_INFO` | names the device type "iPhone 18 Pro" | "iPhone Duo" |
| `SIMULATOR_RUNTIME_VERSION`, `SIMULATOR_RUNTIME_BUILD_VERSION` | 27.0, 24A434 (from the runtime) | 27.1, 24A94401 |

The extended-display file named by the two variables did not exist in the
reference device directory after the first boot; the variables are set
regardless. Points: 402 × 874 (1206 × 2622 at scale 3).

### 4.2 Capabilities (`DEV/ycode-capabilities.plist`)

The `capabilities` dictionary is the iPhone Duo's (`device-capabilities.md`
§3: same keys, same number types, same booleans) with these values changed
(level 2, the type's `capabilities.plist`):

| Key | iPhone 18 Pro | iPhone Duo |
|---|---|---|
| `ArtworkTraits` → `ArtworkDeviceProductDescription` | "iPhone 18 Pro" | "iPhone" |
| `ArtworkTraits` → `ArtworkDeviceSubType` | 2622 | 2034 |
| `ArtworkTraits` → `CompatibleDeviceFallback` | "iPhone18,1" | "iPhone18,3" |
| `ScreenDimensionsCapability` → `main-screen-width` / `-height` | 1206 / 2622 | 1398 / 2034 |
| `subtype` | 2622 | 2034 |
| `DeviceCornerRadius` (real) | 62.0 | 59.0 |
| `modelIdentifier`, `ThinningProductType` | "iPhone19,2" | "iPhone19,4" |
| `ModelNumber`, `RegulatoryModelNumber` | "A3472" | "A3447" |
| `pearl-id` | **true** | false |
| `touch-id` | **false** | true |
| `RingerButtonCapability` | **true** | false |
| `marketing-name` (Ycode leaves it out) | "iPhone 18 Pro" | "iPhone Duo" |

Unchanged and worth naming because they decide the home screen and app
visibility: `idiom` "phone", `ipad` false, `hide-non-default-apps` false,
`telephony`, `sms`, `watch-companion` true (Watch is placed on page 2),
`DeviceSupportsDynamicIsland` true, `hardware-keyboard` true,
`IsLargeFormatPhone` true, `MainScreenClass` 18, `main-screen-class` 36,
`main-screen-orientation` 0.0, `main-screen-scale` 3.0,
`main-screen-pitch` 460, `ArtworkDeviceScaleFactor` 3.0,
`DevicePerformanceMemoryClass` and `memoryClass` 12, `GraphicsFeatureSetClass`
"APPLE11" with the iPhone Duo's fallbacks, `displayGamut` "P3",
`HomeButtonType` 2.

Number types (as a format): reals are `ArtworkDeviceScaleFactor`,
`main-screen-scale`, `main-screen-orientation`, `DeviceCornerRadius`;
`ArtworkDeviceSubType`, `DevicePerformanceMemoryClass`, `HomeButtonType`,
`MainScreenClass`, `main-screen-class`, `-height`, `-width`, `-pitch`,
`memoryClass`, `software-dimming-alpha` and `subtype` are integers.

## 5. Requirements for `ycode-simd` (observable)

I1. `--device-type iphone-18-pro` (**Ycode decision** for the id, in the
style of `ipad.md` §4.3 R1) selects the values of §4.1 and §4.2; the
written plist and environment equal the reference's key for key, with
number types as in §4.2. The extended-display variables are set, as for
every iPhone type.

I2. The framebuffer and display stream take 1206 × 2622 at scale 3 from
`SIMULATOR_MAINSCREEN_*` (no code change; `ipad.md` §4.3 R3). Hello carries
1206 × 2622 px and 402 × 874 points; refresh 60 Hz.

I3. **Ycode decision:** the default device type follows the runtime:
`iphone-duo` for 27.1 (the only type 27.1 accepts) and `iphone-18-pro` for
27.0 (the newest iPhone 27.0 accepts and the one Xcode creates by default).
An explicit `--device-type` overrides the default. Ycode does not refuse
the other combinations, but the IDE labels them as identities without an
Apple reference (as `ipad.md` §8 D1 does for iPads on 27.1). **Implemented
with one change (§9):** the iPhone Duo on 27.0, which the reference refuses
by the type's own `minRuntimeVersion`, is refused by Ycode too.

I4. Device-type records, golden devices and snapshots work as in
`ipad.md` §4.3 R2: a DEV first booted as `iphone-18-pro` keeps that type,
and keys include (runtime build, device type).

I5. Expected guest results of a first boot on 27.0 (acceptance checks):
`DesiredIconState.plist` equal to the runtime's
`SpringBoard.app/DefaultIconState~iphone.plist` plus `metadata.creationDate`
and an empty `dockUtilities`; `IconState.plist` with the layout of
`home-apps.md` §4.1; 39 visible app records; status bar with time at the
left and Wi-Fi and battery at the right of the island gap.

## 6. Reference boot behavior (iOS 27.0, level 3)

| Observation | Value (busy Mac, load average 60–400) |
|---|---|
| First boot, `bootstatus` terminal | 30–41 s (data migration from about 18 s, LaunchServices migrator the longest step) |
| First boot, home screen drawn | 45–49 s; in the first drawn frame the two widgets are still blank tiles, icons, dock and wallpaper are drawn |
| Second boot, `bootstatus` terminal | 3.7 s (no migration); the screen still shows the boot logo then |
| Second boot, home screen drawn | 18.1 s |
| A first boot under load average 350 | failed once: `simctl boot` "launchd failed to respond" (launchd_sim could not bind to its session); a new device booted normally at lower load |
| Jobs in `launchctl list` after launches | 398 entries, 174 with a pid |

Crash reports of the reference device (host DiagnosticReports), to be
expected on 27.0 and not to be counted as Ycode faults without comparison:
intelligencetasksd (11 times in 15 minutes), AppIntentsLiveEntityService
(2) and SettingsSearchReindexService (1), all a breakpoint trap with the
same exception codes; at shutdown ind, tccd, dmd and siriactionsd were
killed for not exiting in time.

## 7. Differences of 27.0 from 27.1 that matter to a host

In addition to `ipad.md` §2.2:

| Item | 27.0 with iPhone 18 Pro | 27.1 with iPhone Duo | Consequence for Ycode |
|---|---|---|---|
| Accepted iPhone types | 33, not iPhone Duo | iPhone Duo only | a second iPhone identity is needed (§5 I3) |
| SpringBoard default layout files | no size-specific file for this phone; `DefaultIconState~iphone.plist` is used | the 466w-678h file for the Duo cover display | the guest chooses by idiom and point size; the host only supplies the right screen size |
| Displays of the device type | one integrated display | two integrated displays (cover, inner) | the reference default screenshot is the home screen; Ycode's one display matches |
| Visible app records | 39 (179 registered, 134 hidden, 6 launch-prohibited) | 22 (162 registered) | longer first-boot registration; more icons and widgets to render |
| First-run sheets and alerts | Maps, Calendar, Photos, News, Reminders show onboarding sheets; Maps asks for location, Health for notifications (`home-apps.md` §4.1) | Settings and Safari only | screenshot comparisons must use the same state (fresh, unanswered) on both sides |
| Background relaunch | Calendar and Photos are started again in the background after `terminate` | not observed | a Ycode process count after `terminate` will not be zero for these apps |
| Daemon crash reports | intelligencetasksd, AppIntentsLiveEntityService, SettingsSearchReindexService traps (§6) | see `ipad.md` §9.1 | compare per runtime before treating as a Ycode fault |
| Runtime `profile.plist` | as 27.1 except `restrictedToDeviceTypes` and the version string | — | nothing in the host-service list changes |

## 8. Open questions

1. What the guest does with an iPhone Duo identity on the 27.0 runtime
   (the runtime has no 466w-678h layout file, so the generic iPhone layout
   would be chosen; the cover/inner display pair is not represented in
   Ycode). Not testable on the reference (CoreSimulator refuses it).
2. The Today view, page 2 and the App Library were not seen on screen
   (headless `simctl` only); page 2 and the Today list are from
   `IconState.plist`.
3. Whether the persistent permission alert (`home-apps.md` §4.1) also
   appears in Ycode; it is guest behavior (SpringBoard) and should, if the
   apps run the same.

## 9. Ycode (agent IOS27, 2026-10-27)

Implemented: `iphone-18-pro` with the values of §4 (reals for the scale
factors, orientation and corner radius; the iPhone Duo record keeps its
integers), the default on 27.0, and the refusal of the iPhone Duo on 27.0
(`ipad.md` §9.2, a Ycode decision against I3's "does not refuse"). A first
boot on 27.0 gave `IconState.plist` equal to `home-apps.md` §4.1 and the
screen of §4.1 (Maps widget, Calendar stack, eight apps, dock Safari and
Messages). Q1 answered in `ipad.md` §9.2.

## 9. Ycode with `iphone-18-pro` (agent IOS27, 2026-10-27)

Clean-room implementation from §4–§5 (level 3: Ycode's own simulator on the
Thor with the 27.0 RuntimeRoot copy; guest files read after the boot; Ycode
screenshots). No Apple simulator, Xcode or reference tool was run.

- **I1** done: `--device-type iphone-18-pro`; the capabilities are the
  iPhone Duo's with exactly the keys of §4.2 changed and the reference's
  number types (reals for `ArtworkDeviceScaleFactor`, `main-screen-scale`,
  `main-screen-orientation`, `DeviceCornerRadius`; the iPhone Duo record
  keeps its integers for its byte-for-byte history); the environment has
  the iPhone set with V63/iPhone19,2/1206 × 2622 and the extended-display
  variables (`DeviceRuntimeTests.iPhone18ProIdentity`).
- **I2**: the display came up at 1206 × 2622 (screenshots), no code
  change.
- **I3** done, with one narrowing (**Ycode decision**, coordinator's
  instruction from §1 item 1): the default is `iphone-18-pro` on 27.0 and
  `iphone-duo` on 27.1; the iPhone Duo on 27.0 is **refused** (exit 66),
  because the type's own `minRuntimeVersion` 27.1 excludes it and the
  reference refuses it with 403. Other pairings (the iPhone 18 Pro or an
  iPad on 27.1) still boot as Ycode identities. `ipad.md` §9.2 item 3.
- **I4**: the type is recorded (`DEV/ycode-device-type`) and the runtime
  too (`DEV/ycode-runtime`, `ipad.md` §9.2 item 4).
- **I5**: a new device's first boot wrote `IconState.plist` equal to
  `home-apps.md` §4.1 in every list — dock, both pages, the folder
  "Utilities", `ignored`, and the five `today` widgets with the same sizes
  (`extraLargePortrait` News included); 35 of 35 migrators succeeded. The
  screen: §9.1 of `home-apps.md`.
- §8 Q1 (Ycode's answer, no reference): `ipad.md` §9.2.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Ycode results (§9) | 3 | Ycode boots on the Thor (27.0 runtime copy), `IconState.plist` and `com.apple.migration.plist` read with `plistlib`, Ycode screenshots; unit tests |
| Supported device types per runtime, Duo refused on 27.0 (§2) | 3 | `simctl list runtimes -j`; `simctl create` error 403 |
| Runtime profile differences (§2) | 2 | both runtimes' `profile.plist` compared key by key |
| Device-type bundle, profile, displays (§3) | 2 | the device types' `Info.plist`, `profile.plist`, `capabilities.plist` read with `plutil`/`plistlib` |
| Capabilities values, differences and number types (§4.2) | 2 | key-by-key comparison of the iPhone 18 Pro and iPhone Duo `capabilities.plist` |
| Launch environment (§4.1) | 3 | `simctl spawn <dev> /usr/bin/env` and `ps -E` of backboardd on a booted iOS 27.0 iPhone 18 Pro |
| Default screenshot display, display ports (§3.3) | 3 | `simctl io enumerate`, `simctl io screenshot` |
| Desired/Icon state, visible apps (§5 I5) | 2, 3 | `DesiredIconState.plist` and `IconState.plist` against SpringBoard's default file; `simctl listapps`; Info.plist keys of the runtime's bundles |
| Boot times, failed boot, job counts, crash reports (§6) | 3 | `simctl boot`/`bootstatus`, screenshot polling, `launchctl list` via `simctl spawn`, host DiagnosticReports (process name and exception type only) |
| Default type per runtime, id, labeling (§5) | — | Ycode decisions |

Level 5 was not used. The reference tools folder, Ghidra, the IPSWs and
`research/dirty/` contents other than this session's own raw data were not
opened; no Apple file was copied into the repository.
