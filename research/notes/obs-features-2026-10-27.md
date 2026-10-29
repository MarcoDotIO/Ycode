# Simulator settings features (agent OBS-FEATURES, 2026-10-27)

Dirty-room notes behind `specs/simulator/simulator-features.md`. Prose only.
Raw logs, string dumps, plist snapshots, screenshots and our recorder live in
`research/dirty/obs-features/` (git-ignored); our sample app is in
`<samples>/ycode-observe-features/FeatureProbe/`.
No disassembly or decompilation. Ghidra, the reference tools folder and the
IPSWs were not opened. Evidence levels as in AGENTS.md rule 4.

## Setup

- Mac15,10, macOS 27.2, Xcode 27.1 at `/Applications/Xcode.app`. Simulator
  windows live in Device Hub (`Contents/Applications/DeviceHub.app`, bundle id
  `com.apple.dt.Devices`).
- The iOS 27.1 runtime (24A94401) accepts only the iPhone Duo device type
  (`simctl create` with iPhone 17 Pro or iPhone 18 Pro: error 403
  "Incompatible device"). One throwaway device, `ycode-test-features-1`
  (iPhone Duo, iOS 27.1), folded (cover display `LCD` in use).
- The host was badly overloaded the whole time (load average 200–900, other
  agents' boots, an Android emulator, `diskimagesiod` at 200 % CPU). Boots
  failed with "launchd failed to respond" several times and were retried;
  `bootstatus` reported "Data Migration Failed" on two boots (the device
  still reached the home screen). One `devicectl` action took about 18
  minutes to reach the guest. Times below are upper bounds.
- **Our recorder** (`ftrec2.dylib`, our own C code, libSystem only), inserted
  into every job of a boot with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`. It
  interposes `notify_post` (every process) and, in the processes named in
  `FTREC_XPC` (CoreSimulatorBridge, dtconfigurationd, dtlocationd,
  locationd), the XPC send, send-with-reply, sync send and event-handler
  calls, logging through `os_log` subsystem `ycode.ftrec`. Read with an
  in-guest `log stream`.
  - Lessons: a first build linked Foundation; under ARC its sync-send wrapper
    returned an autoreleased object where a +1 object is expected, so logd,
    syslogd and `log` crashed (over-release at pool pop). A second build in
    C only avoided that, but logging from inside logd/diagnosticd wedged the
    log system: every process blocked in its first `os_log`, SpringBoard sat
    in dyld initializers for 40 minutes, `simctl launch` and `simctl spawn`
    timed out. A recorder must skip logd, logd_helper, diagnosticd, syslogd,
    notifyd, launchd_sim, xpcproxy_sim, `log` and aslmanager. Linking
    Foundation also made every `xpcproxy_sim` load the whole framework graph
    from disk (dyld's just-in-time loader, minutes per process under load).
- **Our sample app** `FeatureProbe` (`io.ycode.observe.features`, Objective-C,
  built with `clang` for `arm64-apple-ios27.0-simulator`, ad-hoc signed). It
  logs (subsystem `ycode.ftapp`) and shows the trait collection (style,
  content size, contrast, legibility weight), the UIAccessibility and
  Accessibility-framework flags (reduce motion, cross-fade, reduce
  transparency, darker colors, button shapes, show borders, grayscale,
  invert, VoiceOver, bold, differentiate without color, on/off labels), the
  audio session's output volume and route, and CoreLocation updates; it
  observes every matching status notification, trait changes, route changes
  and volume KVO. It shows a system button, a switch, five colour swatches, a
  blur material over orange and a glass effect over purple.
  - iOS 27 refuses an app without scene lifecycle: UIKit stops it at
    launch with a breakpoint trap in "no scene lifecycle adoption" runtime
    issue handling. The app needs `UIApplicationSceneManifest` and a scene
    delegate.
- Plist snapshots of the device data directory before and after each action
  (file list with size and mtime, XML copies of every preference plist), then
  diffs with background noise filtered out.

## Host control surfaces (what exists where)

### `simctl` (level 3, help text and runs)

- `simctl ui <device> <option> [value]` has exactly three options:
  `appearance` (`light` | `dark`; get prints `light`, `dark`, `unsupported`,
  `unknown`), `increase_contrast` (`enabled` | `disabled`; get prints those
  or `unsupported`, `unknown`) and `content_size` (`extra-small`, `small`,
  `medium`, `large`, `extra-large`, `extra-extra-large`,
  `extra-extra-extra-large`, `accessibility-medium`, `accessibility-large`,
  `accessibility-extra-large`, `accessibility-extra-extra-large`,
  `accessibility-extra-extra-extra-large`, or `increment` / `decrement`; get
  prints the name, `unknown` or `unsupported`). Any other option (tried:
  `reduce_motion`) prints the usage text. Defaults on a fresh device: `light`,
  `disabled`, `large`.
- `simctl location <device>`: `list` (City Run, City Bicycle Ride, Freeway
  Drive, Apple), `clear`, `set <lat>,<lon>`, `run <scenario>`,
  `start [--speed=m/s] [--distance=m | --interval=s] <lat,lon> <lat,lon>…`
  (at least two waypoints, `-` reads them from stdin; default speed 20 m/s,
  default interval 1 s). It prints "Parsed N waypoints" for `start`.
- `simctl status_bar` (override `--time`, `--dataNetwork`, `--wifiMode`,
  `--wifiBars`, `--cellularMode`, `--cellularBars`, `--operatorName`,
  `--batteryState`, `--batteryLevel`; `list`; `clear`) — not one of the
  requested features; not exercised.
- No `simctl` command for reduce motion, reduce transparency, show borders,
  colour filters, Liquid Glass, VoiceOver, volume or audio devices.

### `devicectl` (Xcode 27's CoreDevice CLI; level 3)

`devicectl list devices` shows simulators (`simulated`). Its commands are the
same CoreDevice actions Device Hub uses (same guest daemons, same action
identifiers in the guest's logs):

- `device settings appearance`: `--mode light|dark`, `--look-and-feel
  clear|tinted`, `--text-size <12 names or xs…axxxl>`,
  `--larger-accessibility-sizes on|off` ("required to use the accessibility
  text sizes"), `--increase-contrast on|off`, `--reduce-motion on|off`,
  `--reduce-transparency on|off`, `--show-borders on|off`,
  `--liquid-glass-opacity 0.0–1.0` ("0.0 fully translucent, 1.0 fully
  opaque"), `--color-filter on|off`, `--color-filter-type
  grayscale|protanopia|deuteranopia|tritanopia` (aliases gray, red-green,
  green-red, blue-yellow), `--color-filter-intensity 0.25–1.0` (not for
  grayscale). Several options in one call are applied one after the other.
  The JSON result echoes the new values plus the current
  `userInterfaceStyle`; for Liquid Glass it lists `supportedLooksAndFeels`
  (on this device only "Liquid Glass").
- `device settings voiceover --enable|--disable`.
- `device settings audio --output-device <systemDefault|host device UID>
  --input-device <…> --volume 0–100`.
- `device simulate location coordinate --latitude --longitude`, `route`
  (`--mode distance|interval`, `--distance`, `--interval`, `--speed`,
  `--waypoints`, or `--route-file` JSON with `mode`, `distance`/`interval`,
  `speed`, `waypoints[{latitude, longitude}]`), `scenario <name or path
  inside the runtime>`, `list`, `clear`.
- `device notification post|observe` (Darwin notifications), `device
  orientation`, `device simulate statusBar`, `device settings biometrics`,
  `standby`, `reset` exist but were not used.
- Speed: one `appearance` call took 3.5 min to 18 min to reach the guest
  under this load (CoreDeviceService on the host was the bottleneck; one
  `route` call failed with "Timed out waiting for CoreDeviceService to fully
  initialize"). Calls made when the service was warm took 4 s.

### Device Hub (level 3 for the window and menus, level 4 for strings)

- The inspector's first tab (sliders icon) for a booted simulator, top to
  bottom, in three groups (read from the window of another agent's booted
  iPhone Duo; values shown are that device's):
  1. **Appearance** (pop-up, "Light"), **Liquid Glass** (slider with marks at
     both ends; on this runtime only the opacity slider, no look-and-feel
     picker), **Color Filter** (pop-up, "None"), **Text Size** (slider with
     12 tick marks), **Reduce Motion**, **Increase Contrast**, **Show
     Borders**, **Reduce Transparency**, **VoiceOver** (switches, off).
  2. **Location** (pop-up, "None").
  3. **Sound** (slider), **Output** (pop-up, "System"), **Input** (pop-up,
     "System").
- For a shut-down simulator the tab shows only "Start the simulator to
  customize behavior and appearance." Strings also name "No settings are
  available for the selected …" (the inspector asks the device which
  elements are customizable and shows only those).
- Menu bar: Device Hub, File, Edit, View, **Device**, **Controls**, Window,
  Help. Device: Restart, Shut Down, Force Shut Down, **Accessibility**,
  **Appearance**, Battery, Face ID, Touch ID, Optic ID, **Location**,
  Orientation, **Sound**, Enter Resize Mode, Keyboard, Pair Apple Watch…,
  Reset Content and Settings…
  - Accessibility ▸ Reduce Motion, Reduce Transparency, Increase Contrast,
    Show Borders, Increase Text Size, Decrease Text Size, VoiceOver.
  - Appearance ▸ Toggle Appearance, Light, Dark, Auto.
  - Location ▸ None, Berlin, Germany; Cupertino, CA, USA; Hong Kong, China;
    Johannesburg, South Africa; London, England; Mexico City, Mexico; Mumbai,
    India; New York, NY, USA; Paris, France; Rio de Janeiro, Brazil; San
    Francisco, CA, USA; Sydney, Australia; Tokyo, Japan; Warsaw, Poland;
    section "Trips": City Run, City Bicycle Ride, Freeway Drive; Apple;
    Custom Coordinates… . Strings add "Import GPX File" and a Custom
    Coordinates sheet with Latitude and Longitude fields, Cancel and an apply
    button.
  - Sound ▸ Increase Volume, Decrease Volume, section **Input**: None, Use
    System Settings, then every host input device by name; section
    **Output**: None, Use System Settings, then every host output device by
    name.
  - Controls ▸ Home, Lock, Siri, App Switcher, Action Button, Rotate Left,
    Rotate Right, Screenshot, Record Screen.
  - Keyboard shortcuts of these items could not be read (the background menu
    tool lists titles only).
- Colour filter names (DeviceKit strings): None, Red/Green (Protanopia),
  Green/Red (Deuteranopia), Blue/Yellow (Tritanopia), Grayscale; short
  labels exist for the three colour-blindness filters.
- Device Hub watches the guest for changes made elsewhere: DeviceKit names
  the guest notifications `com.apple.UIKit.SystemUIServiceUserInterfaceStyleNotification`,
  `ApplePreferredContentSizeCategoryChangedNotification`,
  `UIViewGlassLegibilityDidChangeNotification`,
  `com.apple.accessibility.cache.button.shapes.enabled`,
  `com.apple.accessibility.voiceovertouch.status`,
  `com.apple.accessibility.grayscale`, `…red-color-filter`,
  `…green-color-filter`, `…blue-color-filter`, and its own host
  notifications `com.apple.dt.devicekit.VolumeDidChange` and
  `com.apple.dt.devicekit.AudioDeviceSelectionDidChange`. Host defaults
  `enableAudioOutput`, `enableAudioOutput_iOS`, `enableAudioOutput_tvOS`
  can switch simulator audio output off.
- Selecting our device in the sidebar was refused by the background tool
  ("cannot be clicked while Device Hub is in the background"; keys to the
  list were refused too). No full-screen takeover was requested, so no
  Device Hub control was operated; `devicectl` drove the same actions
  instead. The search field was typed into and cleared again.

### Xcode's Environment Overrides (level 4: Xcode's own plug-in data)

Not observed live: running an app from Xcode on a throwaway device needs the
run-destination pop-up, which the click-tier background tool refuses (menu
controls). The table below comes from the extension declarations in
`IDEiOSDebugger.xcplugindata` (iOS, extension point
`Xcode.DebuggerFoundation.DebugOverride`) and `DebuggerFoundation.xcplugindata`
(AppKit). Each declaration has a category, display name, position priority,
the platforms and minimum OS it applies to, and a list of named values. Each
override is applied by the debugger evaluating an expression **inside the
debugged app process** (the declarations carry the expression; it calls
UIKit-private override objects in the app). It changes only that app, not
the device's settings. The views are `IDEDebugOverridesPopoverContentViewController`,
category, boolean, appearance and dynamic-type view controllers; actions
`configureEnvironmentOverrides:` and `disableAllEnvironmentOverrides:`.

| Category | Item (priority) | Values | Platforms (UIKit) |
|---|---|---|---|
| Appearance | Appearance (100) | No Override, Light, Dark | iOS, tvOS (13.0+) |
| Dynamic Type | Dynamic Type (101) | No Override, X Small, Small, Medium, Large (Default), X Large, XX Large, XXX Large, Accessibility 1–5; declared default index 7 | iOS 13+, watchOS 6+ |
| Accessibility | Increase Contrast (200) | No Override, Increased, Default | iOS, tvOS |
| | Reduce Transparency (201) | No Override, Reduced, Default | iOS, tvOS |
| | Bold Text (202) | No Override, Enabled, Disabled | iOS, watchOS, tvOS |
| | Reduce Motion (203) | No Override, Reduced, Default | iOS, watchOS, tvOS |
| | On/Off Labels (204) | No Override, Enabled, Disabled | iOS, watchOS |
| | Button Shapes (205) | No Override, Enabled, Disabled | iOS |
| | Grayscale (206) | No Override, Enabled, Disabled | iOS |
| | Smart Invert (207) | No Override, Enabled, Disabled | iOS |
| | Differentiate Without Color (208) | No Override, Enabled, Disabled | iOS |

AppKit declarations: Appearance (No Override, Light, Dark), Increase
Contrast (implies Reduce Transparency), Reduce Transparency, Reduce Motion,
Differentiate Without Color. DebuggerUI strings also name
`accessibilityDisplayShouldIncreaseContrast` and
`accessibilityDisplayShouldShowBorders` (macOS).

## Guest-side agents (level 2 and 4)

- Both agents are **host-supplied**, not part of the runtime: the
  CoreSimulator platform folder `Platforms/iphoneos/` carries
  `usr/libexec/CoreSimulatorBridge`, `dtconfigurationd`, `dtlocationd`,
  `dtdeviceinfod`, `dthidd`, `dtuhidd`, `dticond`, `dtappserviced`,
  `dtpasteboardd` and their launchd plists, which CoreSimulator copies into
  the device's `data/Library/LaunchDaemons/`.
- `com.apple.CoreSimulator.bridge` (CoreSimulatorBridge, KeepAlive): Mach
  services `com.apple.CoreSimulator.accessibility`,
  `…CoreSimulatorBridge.lifecycle_support` (reset at close),
  `…darwin_notification_bridge`, `…host_support`,
  `…SimPasteboardInterface`; launch events on Darwin notifications
  `com.apple.backboardd.safetosetidletimer`,
  `com.apple.CoreSimulator.audio.devices_changed`,
  `com.apple.springboard.ringerstate`, `com.apple.springboard.volumestate`,
  `CSLSCarouselLaunchDidHideLogoNotification`. Strings: request keys
  `CurrentStyle`, `CurrentSizeCategory`, `CurrentMode`; errors "Runtime does
  not support userInterfaceStyle", "Runtime does not support dynamic text",
  "Invalid request, invalid content size"; it uses CoreLocation's simulation
  manager (`clearSimulatedLocations`, `appendSimulatedLocation:`,
  `startLocationSimulation`, `stopLocationSimulation`, `selectScenario:`,
  `loadScenarioFromURL:`, `setLocationSpeed:`, `setLocationDistance:`,
  `setLocationInterval:`, `availableScenarios`,
  `localizedNameForScenario:`); entitlements `com.apple.accessibility.api`,
  `com.apple.locationd.authorizeapplications`.
- CoreSimulator's `SimDevice` has `setUIInterfaceStyle:error:`,
  `currentUIInterfaceStyle`, `setContentSizeCategory:error:`,
  `currentContentSizeCategory`, `setIncreaseContrastEnabled:error:`,
  `currentIncreaseContrastMode`, `sendAccessibilityRequestAsync:…`,
  `setLocationWithLatitude:andLongitude:error:`, `setLocationScenario:error:`,
  `setLocationScenarioWithPath:error:`,
  `startLocationSimulationWithDistance/Interval:speed:waypoints:error:`,
  `clearSimulatedLocationWithError:`, `availableLocationScenarios`.
- `com.apple.coredevice.dtconfigurationd`: Mach services
  `com.apple.coredevice.feature.configurationprofiles`,
  `…customizeappearancesettings`, `…customizeliquidglass`,
  `…customizeuistyle`, `…renamedevice`, `…voiceover`; actions (from its
  strings and logs) get/set user interface style, device text size, larger
  accessibility sizes, increase contrast, reduce motion, reduce
  transparency, show borders, colour filter, Liquid Glass configuration
  (opacity, called "glassiness" in its log), device look and feel, supported
  looks and feels, VoiceOver, customizable appearance elements. Its errors:
  "Liquid Glass opacity must be between 0.0 and 1.0", "Cannot set intensity
  without a filter type", "Intensity is not supported for the grayscale
  filter type", "Unknown legibility setting: …, defaulting to Clear Liquid
  Glass", "User interface style mode is automatic or unknown …, defaulting
  to light", "VoiceOver did not settle to … within …; returning
  best-effort".
- `com.apple.coredevice.dtlocationd`: Mach service
  `com.apple.coredevice.feature.simulatelocation`; actions available
  scenarios, set scenario, set simulated location, start location simulation,
  clear simulated location; it uses the same CoreLocation simulation manager;
  entitlements `com.apple.locationd.simulation`,
  `com.apple.locationd.preauthorized`.

## The CoreDevice action exchange (level 3, our recorder)

A host process (pids of short-lived host processes, gone after the call)
connects to the guest Mach service `com.apple.coredevice.feature.<feature>`
and sends one XPC dictionary per action:

- `CoreDevice.actionIdentifier` (string, e.g.
  `com.apple.coredevice.action.setreducemotion`),
- `CoreDevice.input` (dictionary; for reduce motion `reduceMotion` →
  `enabled` → true),
- `CoreDevice.invocationIdentifier` (UUID string),
- `CoreDevice.deviceIdentifier` (the device UDID),
- `CoreDevice.CoreDeviceDDIProtocolVersion` (int 2),
- `CoreDevice.coreDeviceVersion` (dictionary: `components` [651, 13, 4, 0,
  0], `originalComponentsCount` 3, `stringValue` "651.13.4").

The reply is a dictionary with one key `CoreDevice.output` (the new state,
e.g. `reduceMotion` → `enabled` → true; empty for some set actions). A
`devicectl` call sends the set action and then get actions (the JSON result
is built from them; it always includes the current user interface style).
The daemon starts on demand (launchd Mach service), registers one listener
per action type (later registrations on the same service fail with "already
in progress" and are ignored), and exits when idle.

## Per-feature observations

All "live" statements are from our app running in the foreground; times are
from the guest's log.

### Appearance

- `simctl ui appearance dark`: CoreSimulatorBridge asks UIKitServices'
  user-interface-style service to change the mode ("Client
  CoreSimulatorBridge is requesting to change the mode to 2"), and the
  preference domain `com.apple.uikitservices.userInterfaceStyleMode`
  (file `data/Library/Preferences/com.apple.uikitservices.userInterfaceStyleMode.plist`,
  absent on a fresh device) gets `UserInterfaceStyleMode` = 2 (dark); light
  is 1. SpringBoard posts `com.apple.UIKit.SystemUIServiceUserInterfaceStyleNotification`
  20 ms later; our app's trait collection changes to dark 50 ms later (live,
  no relaunch).
- `devicectl … --mode light` (dtconfigurationd, action
  `setuserinterfacestyle`) goes the same way: "dtconfigurationd is requesting
  to change the mode to 1", value 1.
- Device Hub's "Auto" is not offered by `simctl`/`devicectl`; dtconfigurationd's
  string calls automatic "defaulting to light" when reading. Not exercised.
- Persists across reboot (the plist stays; `simctl ui appearance` printed
  the last value after a reboot).

### Increase Contrast

- `simctl ui increase_contrast enabled` (bridge): writes, through the
  runtime's accessibility settings layer, `com.apple.Accessibility`
  `DarkenSystemColors` = 1 and `PointerIncreasedContrastEnabled` = 1; posts
  `com.apple.accessibility.cache.ax` and `com.apple.accessibility.status`.
  backboardd then posts `com.apple.accessibility.cache.pointer.increased.contrast`,
  `com.apple.accessibility.cache.darken.system.colors.enabled`,
  `com.apple.accessibility.pointer.increased.contrast`,
  `com.apple.accessibility.darken.system.colors`; every UI process (posters,
  SpringBoard, our app) re-posts `com.apple.accessibility.status`.
- Our app: UIAccessibility darker-system-colors notification after 35 ms, and
  the trait collection's accessibility contrast becomes high (1) after 50 ms.
  Live.
- `devicectl … --increase-contrast off`: dtconfigurationd writes the two
  keys = 0 and posts `com.apple.accessibility.darken.system.colors`.
- Persists across reboot.

### Text Size (Dynamic Type)

- `simctl ui content_size accessibility-extra-large` (bridge): writes
  `com.apple.UIKit` `UIPreferredContentSizeCategoryName` =
  `UICTContentSizeCategoryAccessibilityXL` (the setter addresses the domain
  by the absolute path of `data/Library/Preferences/com.apple.UIKit`) and
  `com.apple.preferences-framework` `largeTextUsesExtendedRange` = 1; posts
  `ApplePreferredContentSizeCategoryChangedNotification`. The app gets
  UIContentSizeCategoryDidChange and a trait change within 20 ms; its
  dynamic-type label re-laid out (screenshot). Live.
- Value names written: `UICTContentSizeCategoryXS`, `S`, `M`, `L`, `XL`,
  `XXL`, `XXXL`, `AccessibilityM`, `AccessibilityL`, `AccessibilityXL`,
  `AccessibilityXXL`, `AccessibilityXXXL` (prefix `UICTContentSizeCategory`;
  we saw `L` and `AccessibilityXL` written, the others follow UIKit's
  public category names).
- `devicectl … --text-size large --larger-accessibility-sizes off`:
  dtconfigurationd sets Larger Accessibility Sizes first
  (`largeTextUsesExtendedRange` becomes false, notification posted), then the
  size (`UICTContentSizeCategoryL`).
- Persists across reboot.

### Reduce Motion

- `devicectl … --reduce-motion on` (dtconfigurationd, `setreducemotion`):
  `com.apple.Accessibility` `ReduceMotionEnabled` = 1 and
  `PointerEffectScalingEnabled` = 0; dtconfigurationd posts
  `com.apple.accessibility.cache.ax` and `com.apple.accessibility.reduce.motion.status`;
  backboardd posts `com.apple.accessibility.cache.reduce.motion`,
  `com.apple.accessibility.reduce.motion.status`,
  `com.apple.accessibility.cache.pointer.effect.scaling`,
  `com.apple.accessibility.pointer.effect.scaling`. App: reduce-motion
  status notification after 35 ms. Live. Persists.

### Reduce Transparency

- `devicectl … --reduce-transparency on`: `com.apple.Accessibility`
  `EnhancedBackgroundContrastEnabled` = 1; dtconfigurationd posts
  `com.apple.accessibility.enhance.background.contrast.status`; backboardd
  posts `com.apple.accessibility.cache.enhance.background.contrast` and the
  status again. App: reduce-transparency notification. Visible: the blur
  material became an opaque pale panel, the glass effect too. Live.
  Persists.

### Show Borders

- `devicectl … --show-borders on`: `com.apple.Accessibility`
  `ButtonShapesEnabled` = 1 (the pre-26.1 Button Shapes key);
  dtconfigurationd posts `com.apple.accessibility.button.shapes`; backboardd
  posts `com.apple.accessibility.cache.button.shapes.enabled` and
  `com.apple.accessibility.button.shapes`. App: both
  `UIAccessibilityButtonShapesEnabledStatusDidChangeNotification` and the
  public `AXShowBordersEnabledStatusDidChangeNotification` (whose string
  value is `com.apple.accessibility.button.shapes`); `AXShowBordersEnabled()`
  and the deprecated button-shapes call both return true. Visible: the
  system text button is underlined. Live. Persists.

### Color Filters

- `devicectl … --color-filter on --color-filter-type protanopia
  --color-filter-intensity 0.5`: domain `com.apple.mediaaccessibility`:
  `__Color__.MADisplayFilterCategoryEnabled` = 1, `__Color__.MADisplayFilterType`
  = 2 (protanopia), `MADisplayFilterRedColorCorrectionIntensity` = 0.5;
  `com.apple.Accessibility` `GrayscaleDisplay` written 1 then 0 and
  `DidCheckGrayscaleValue-v2` = 1. Notifications from dtconfigurationd:
  `com.apple.mediaaccessibility.displayFilterSettingsChanged`,
  `com.apple.accessibility.displayFilterForceUpdate`,
  `com.apple.accessibility.red-color-filter`; backboardd:
  `com.apple.accessibility.cache.grayscale`, `com.apple.accessibility.grayscale`;
  AccessibilityUIServer re-posts displayFilterSettingsChanged. The app gets
  the grayscale status notification (grayscale stays false).
- Visible: `simctl io screenshot` after the change showed the red swatch
  shifted towards pink and the whole frame tinted, so the filter is applied
  in the composited frame that screenshots capture.
- **Not persisted**: after a reboot `com.apple.mediaaccessibility.plist` was
  rewritten empty during boot (19:53:06, by the guest) and the colours were
  normal again, while the other accessibility keys survived.
- Type codes for grayscale, deuteranopia and tritanopia and their intensity
  keys were not observed (only protanopia was set).

### Liquid Glass

- `devicectl … --liquid-glass-opacity 1.0 --look-and-feel tinted`
  (actions `setdevicelookandfeel`, "Tinted Liquid Glass", and
  `setliquidglassconfiguration`, "glassiness=1.000000"): `com.apple.UIKit`
  `UIViewGlassLegibilitySetting` = 1 (tinted; clear is the default) and
  `UIViewGlassTintAmount` = 1 (the opacity, 0.0–1.0). dtconfigurationd
  posts `UIViewGlassLegibilityUpdateNotification` and
  `UIViewGlassTintAmountUpdateNotification`. The JSON result reported
  `lookAndFeel` "Liquid Glass" and `supportedLooksAndFeels` ["Liquid Glass"]
  on this runtime, which matches Device Hub showing only the opacity slider.
- Our app's in-process observer of `UIViewGlassLegibilityDidChangeNotification`
  saw nothing (that name is Device Hub's, the guest posts the Update names);
  visible: the glass effect sample turned opaque and pale (screenshot).
- Persists (keys still present after reboot).

### VoiceOver

- `devicectl device settings voiceover --enable`: `com.apple.Accessibility`
  `VoiceOverTouchEnabled` = 1, `AccessibilityEnabled` = 1,
  `ApplicationAccessibilityEnabled` = 1; dtconfigurationd posts
  `com.apple.accessibility.cache.ax`, `com.apple.accessibility.cache.app.ax`,
  `com.apple.accessibility.application.status`; backboardd posts
  `com.apple.accessibility.cache.vot`,
  `com.apple.accessibility.voiceovertouch.status`. The VoiceOver process
  `vot` starts (posts `VOTDidLaunch`, `com.apple.accessibility.voiceover.launched`,
  many `_AXNotification_…` names), writes `VOTIsRunningKey` = true and
  `com.apple.VoiceOverTouch` defaults (braille tables, rotor items);
  SpringBoard posts `com.apple.accessibility.loaded`. The app gets the
  VoiceOver status notification 18 s later (load). Visible: a "VoiceOver
  Gestures" sheet with an OK button and the VoiceOver focus rectangle.
- `--disable`: the three keys go to 0/false, `VOTIsRunningKey` false; the
  "VoiceOver Gestures" sheet stayed on screen.
- dtconfigurationd waits for VoiceOver to settle (its string "VoiceOver did
  not settle … returning best-effort").

### Location

- `simctl location set 37.3349,-122.0090` (bridge): CoreSimulatorBridge
  opens an NSXPC connection to locationd's Mach service
  `com.apple.locationd.simulation` and sends, in order: clear simulated
  locations, stop, append one location, start (each an XPC dictionary
  `f` = 1, `proxynum` = 1, `root` = an NSXPC-encoded invocation of 61–1824
  bytes). locationd logs "received daemon-side request to stop",
  "append simulated location", "start location simulation", enables
  simulation "for all location providers" (wifi, simulated), and emits a fix
  with accuracy 5 m, course −1, speed −1. Our app got
  37.3349, −122.0090 ±5 m, altitude 0, 35 ms later. With one fixed point
  locationd re-sends the fix every second.
- `simctl location start --speed=50 --interval=2 A B`: stop, clear, set
  interval (logged `locationInterval_s` 2), set speed, append both
  waypoints, start. Fixes every 2 s, app saw speed 50, course 60→57°,
  positions interpolated along the line, accuracy 5 m.
- `simctl location run "City Run"`: the bridge passes the scenario file URL;
  locationd logs "Applying new simulation scenario" (900 locations) from
  `RuntimeRoot/System/Library/Frameworks/CoreLocation.framework/Support/SimulationScenarios/City Run.plist`,
  `locationRepeatBehavior` 2, then start. Fixes every 1 s with accuracy
  10–30 m, varying speed and course.
- `simctl location clear`: stop + clear; the app got a location error
  (`kCLErrorDomain` 0) when simulation stopped.
- `devicectl … simulate location coordinate --latitude 48.8584 --longitude
  2.2945`: dtlocationd ("Setting simulated location") sends the same NSXPC
  traffic to `com.apple.locationd.simulation`; app got the point ±5 m.
- Scenario files (level 2): binary plists with `Locations` (array of
  NSKeyedArchiver data, each a `CLLocation` with keys
  `kCLLocationCodingKeyCoordinateLatitude`, `…Longitude`, `…Altitude`,
  `…HorizontalAccuracy`, `…VerticalAccuracy`, `…Course`, `…Speed`,
  `…Timestamp`, `…Lifespan`, `…Type`) and `Options`
  (`LocationRepeatBehavior` float, `LocationDeliveryBehavior` float). Apple:
  11 locations, repeat 1; City Run 900, City Bicycle Ride 939, Freeway Drive
  2240, each delivery 0, repeat 2.
- **Not persisted**: after a reboot the app received no fix (location error)
  and locationd had no simulation running.
- `simctl privacy grant location-always` was needed for our app; the
  authorization status read 3 (always) after reboot.

### Sound (volume)

- `devicectl device settings audio --volume 30`: CoreSimulatorBridge posted
  `com.apple.springboard.volumestate` in the guest (its Darwin notification
  bridge posting on the host's behalf) and `var/run/simulatoraudio/audiosettings.plist`
  `sim_volume` became 30 (was 60). Our app's audio session output volume
  read 0.300 at its next refresh (no KVO callback arrived). Device Hub's
  Sound slider also has Increase/Decrease Volume menu items.
- After a reboot `sim_volume` was still 30 in the file, but our app read an
  output volume of 0.600: the guest started at the default 60 %.
- Ringer: `sim_ringer_state` 1 in the same file; the bridge also reacts to
  `com.apple.springboard.ringerstate`. Device Hub has no ringer/mute control
  for this device; not exercised.

### Output and Input

- The host writes `data/var/run/com.apple.coresimulator.audio.plist`
  (`sim_output_device_uid`, `sim_input_device_uid` = host CoreAudio device
  UIDs; `useHostDefaultOutputDevice`, `useHostDefaultInputDevice`) and makes
  CoreSimulatorBridge post `com.apple.CoreSimulator.audio.devices_changed`;
  the bridge rewrites `audiosettings.plist` (`sim_output_device_uid`,
  `sim_input_device_uid`, `sim_ringer_state`, `sim_volume`).
- "System"/"Use System Settings" = the use-host-default flags true. While
  true, a change of the Mac's default output (the owner's Bluetooth
  headphones connected at 19:05:33) made the bridge post `devices_changed`
  nine times and both files switched to the new UID
  (`AC-80-0A-EA-3A-EA:output`) without any action of ours.
- `devicectl … --output-device BuiltInSpeakerDevice --input-device none`:
  output UID `BuiltInSpeakerDevice`, both use-host-default flags false;
  `none` was echoed as the built-in microphone (input UID unchanged). How
  Device Hub's "None" is encoded was not observed.
- The host side is CoreSimulator's audio processor XPC service (strings:
  `routeGuestDeviceScope:toHostDeviceUID:…`, `postDarwinNotification:error:`,
  `setDarwinNotificationState:name:error:`, "resolveSelectedDeviceAndWritePlist").
- Both files survived a reboot unchanged (the host rewrote the first only
  when the selection changed). The app's route always reports one output
  `Speaker` (portType Speaker) whatever the host device; no route-change
  notification arrived.

## What could not be observed

- Device Hub's own controls were not operated (row selection refused in the
  background; no full-screen takeover). Their effects were reproduced with
  `devicectl`, which uses the same guest actions.
- Xcode's Environment Overrides panel was not opened (run destination
  pop-up refused at click tier); its contents come from Xcode's plug-in
  data.
- The host → CoreSimulatorBridge message format for `simctl ui` and
  `simctl location` (the bridge's incoming listener was not caught by our
  event-handler hook) and the NSXPC payloads to locationd beyond their sizes
  and method-name prefixes.
- Appearance "Auto", colour filter types other than protanopia, Liquid
  Glass "clear" and intermediate opacities, Device Hub's audio "None",
  keyboard shortcuts, `devicectl` routes and scenarios through dtlocationd.
