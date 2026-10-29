# Spec: simulator settings features (appearance, accessibility, location, sound)

Status: **proposed** (OBS-FEATURES, 2026-10-27); Ycode implementation in §I (FEAT-IMPL, 2026-10-27). It tells a clean agent how
the reference simulator (Xcode 27.1, iOS 27.1 runtime 24A94401) lets the user
change Appearance, Liquid Glass, Color Filters, Text Size, Reduce Motion,
Increase Contrast, Show Borders, Reduce Transparency, VoiceOver, Location,
Sound, Output and Input, what each change does inside the guest, and what
Ycode must build to offer the same. Observations behind it:
`research/notes/obs-features-2026-10-27.md`. It builds on `audio-host.md`
§12 (audio settings files), `launchd-sim.md` §3, `hid-input.md` and
`foldable.md` §4 (Device Hub); it does not repeat them.

Terms: **guest** = the simulated iOS; **setter** = the guest process that
applies a change for the host; **AX domain** = the preference domain
`com.apple.Accessibility` (file `DEV/data/Library/Preferences/com.apple.Accessibility.plist`);
**DEV** = the device directory. Preference values are written through the
guest's `cfprefsd` (the normal preferences API), never by editing the file
behind its back. **Ycode decision** marks design choices.

## 1. Summary

1. Every feature in this spec is **system state of the guest**: a few keys in
   preference domains plus Darwin notifications, or (location) requests to
   the guest's own `locationd`, or (audio) two small plists. Apple's
   frameworks in the runtime read that state and react; the app needs no
   help. All changes are **live**: a running app sees them within ~50 ms
   (trait-collection change or UIAccessibility notification), with no
   relaunch.
2. In the reference, the host never writes those keys itself. It asks a
   **guest-side agent** to do it:
   - `simctl ui` and `simctl location` → CoreSimulator → **CoreSimulatorBridge**
     (guest daemon, Mach services `com.apple.CoreSimulator.accessibility` and
     `com.apple.CoreSimulator.host_support`).
   - Device Hub and `devicectl` → CoreDevice → **dtconfigurationd** and
     **dtlocationd** (guest daemons, Mach services
     `com.apple.coredevice.feature.*`, §3).
   - Audio devices and volume → CoreSimulator's host audio service writes
     `DEV/data/var/run/com.apple.coresimulator.audio.plist` and has the
     bridge post Darwin notifications in the guest (§4.12, §4.13).
   Both paths end in the **same guest state** (§4).
3. These agents are **host-supplied binaries** (they ship in Xcode's
   CoreSimulator platform folder, not in the runtime) and CoreSimulator copies
   their launchd plists into `DEV/data/Library/LaunchDaemons/`. Ycode cannot
   ship them; it needs **its own guest agent** (§6).
4. Xcode's **Environment Overrides** (debug bar) is different: it changes one
   debugged app through the debugger and leaves the device's settings alone
   (§7.3).
5. Persistence: appearance, text size, contrast, reduce motion, reduce
   transparency, show borders, Liquid Glass and VoiceOver **survive a
   reboot** (they are preferences). **Location and color filters do not**
   (§5).

## 2. Control surfaces in the reference (overview)

| Feature | `simctl` | `devicectl` (= Device Hub's actions) | Device Hub inspector / menu | Xcode Environment Overrides |
|---|---|---|---|---|
| Appearance | `ui appearance light\|dark` | `settings appearance --mode` | pop-up; Device ▸ Appearance ▸ Toggle Appearance, Light, Dark, Auto | Appearance |
| Liquid Glass | — | `--liquid-glass-opacity 0–1`, `--look-and-feel clear\|tinted` | slider (and a look picker where more than one look is supported) | — |
| Color Filter | — | `--color-filter on\|off`, `--color-filter-type`, `--color-filter-intensity 0.25–1` | pop-up | Grayscale only |
| Text Size | `ui content_size <name>\|increment\|decrement` | `--text-size`, `--larger-accessibility-sizes` | 12-step slider; Accessibility ▸ Increase/Decrease Text Size | Dynamic Type |
| Reduce Motion | — | `--reduce-motion` | switch; Accessibility ▸ Reduce Motion | Reduce Motion |
| Increase Contrast | `ui increase_contrast enabled\|disabled` | `--increase-contrast` | switch; Accessibility ▸ Increase Contrast | Increase Contrast |
| Show Borders | — | `--show-borders` | switch; Accessibility ▸ Show Borders | Button Shapes |
| Reduce Transparency | — | `--reduce-transparency` | switch; Accessibility ▸ Reduce Transparency | Reduce Transparency |
| VoiceOver | — | `settings voiceover --enable\|--disable` | switch; Accessibility ▸ VoiceOver | — |
| Location | `location set\|start\|run\|clear\|list` | `simulate location coordinate\|route\|scenario\|clear\|list` | pop-up; Device ▸ Location ▸ … | — |
| Sound | — | `settings audio --volume 0–100` | slider; Sound ▸ Increase/Decrease Volume | — |
| Output / Input | — | `settings audio --output-device`, `--input-device` | pop-ups; Sound ▸ Output/Input sections | — |

Exact labels, order and values are in §7 (IDE section).

## 3. The CoreDevice action exchange (interop facts)

Device Hub and `devicectl` reach a guest daemon by Mach service name in the
simulator's bootstrap namespace and send one XPC dictionary per action:

| Key | Type | Value |
|---|---|---|
| `CoreDevice.actionIdentifier` | string | `com.apple.coredevice.action.<name>` (names in §4) |
| `CoreDevice.input` | dictionary | action arguments (e.g. `reduceMotion` → { `enabled`: true }) |
| `CoreDevice.invocationIdentifier` | string | a UUID per call |
| `CoreDevice.deviceIdentifier` | string | the device UDID |
| `CoreDevice.CoreDeviceDDIProtocolVersion` | int64 | 2 |
| `CoreDevice.coreDeviceVersion` | dictionary | `components` [651, 13, 4, 0, 0], `originalComponentsCount` 3, `stringValue` "651.13.4" |

The reply is { `CoreDevice.output`: dictionary } (the resulting state, or
empty). A client call is a set action followed by get actions; the result
always includes the current user interface style. Services
(`com.apple.coredevice.feature.` + suffix):

| Daemon | Service suffixes | Actions |
|---|---|---|
| dtconfigurationd | `customizeuistyle`, `customizeappearancesettings`, `customizeliquidglass`, `voiceover`, `configurationprofiles`, `renamedevice` | get/set user interface style, device text size, larger accessibility sizes, increase contrast, reduce motion, reduce transparency, show borders, color filter, Liquid Glass configuration, device look and feel; get supported looks and feels, customizable appearance elements; get/set VoiceOver |
| dtlocationd | `simulatelocation` | available scenarios, set scenario, set simulated location, start location simulation, clear simulated location |

The daemons are launchd Mach-service jobs started on demand and exit when
idle. **Ycode decision**: Ycode does not need to speak this protocol (its
IDE talks to its own agent, §6); it is recorded so a future Ycode can accept
`devicectl`-style requests if wanted.

## 4. Features

Each subsection: controls, what changes in the guest (keys, notifications),
live or relaunch, persistence, and what Ycode must do. "Setter posts" lists
the notifications the setting agent posts itself; "system posts" lists those
that other guest processes (mostly backboardd) post in reaction and that Ycode
gets for free by running the runtime's own daemons. All AX keys are integers
0/1 unless noted.

### 4.1 Appearance (light / dark)

- **Controls**: §2. Values light, dark (Device Hub also offers Auto and a
  Toggle Appearance item).
- **Guest**: domain `com.apple.uikitservices.userInterfaceStyleMode`, key
  `UserInterfaceStyleMode`: 1 = light, 2 = dark. The file does not exist on
  a fresh device (reads as light). The setter changes it through UIKit's
  system user-interface-style service (the guest logs "Client … is
  requesting to change the mode to N"), which writes the key.
- **Notifications**: system posts `com.apple.UIKit.SystemUIServiceUserInterfaceStyleNotification`
  (SpringBoard).
- **Live**: yes; trait collection's user interface style changes ~50 ms later.
- **Persists**: yes.
- **Ycode must**: write the key through the guest's preferences API (or, if
  available in the runtime, through the same UIKit service so SpringBoard is
  told); verify SpringBoard posts the notification and apps flip. Auto is not
  specified (OPEN Q1).

### 4.2 Liquid Glass

- **Controls**: opacity 0.0 (fully translucent) … 1.0 (fully opaque); look
  and feel clear | tinted. On this runtime the device reports only one
  supported look ("Liquid Glass"), so Device Hub shows only the opacity
  slider.
- **Guest**: domain `com.apple.UIKit`: `UIViewGlassTintAmount` (real
  0.0–1.0, the opacity) and `UIViewGlassLegibilitySetting` (integer; 1 =
  tinted; clear is the default and absent key). Actions
  `setliquidglassconfiguration`, `setdevicelookandfeel`.
- **Setter posts**: `UIViewGlassTintAmountUpdateNotification`,
  `UIViewGlassLegibilityUpdateNotification` (Darwin).
- **Live**: yes (glass effect views turned opaque and pale on screen).
- **Persists**: yes.
- **Ycode must**: write the two keys, post the two notifications; report the
  supported looks as the runtime does (OPEN Q2: how the list is determined).

### 4.3 Color Filters

- **Controls**: None, Red/Green (Protanopia), Green/Red (Deuteranopia),
  Blue/Yellow (Tritanopia), Grayscale; intensity 0.25–1.0 for the three
  colour filters (not grayscale).
- **Guest**: domain `com.apple.mediaaccessibility`:
  `__Color__.MADisplayFilterCategoryEnabled` = 1,
  `__Color__.MADisplayFilterType` = filter code (protanopia = 2; other codes
  OPEN Q3), `MADisplayFilterRedColorCorrectionIntensity` = intensity for
  protanopia (other filters use their own intensity key, OPEN Q3). AX domain:
  `GrayscaleDisplay` (1 only for grayscale), `DidCheckGrayscaleValue-v2` = 1.
- **Setter posts**: `com.apple.mediaaccessibility.displayFilterSettingsChanged`,
  `com.apple.accessibility.displayFilterForceUpdate`, and the per-filter name
  `com.apple.accessibility.red-color-filter` (protanopia;
  `…green-color-filter`, `…blue-color-filter`, `…grayscale` are the names the
  host watches for the others). System posts `com.apple.accessibility.cache.grayscale`,
  `com.apple.accessibility.grayscale`.
- **Visible**: the whole composited frame is filtered, including screenshots
  taken from the framebuffer.
- **Live**: yes. **Persists**: **no** — the guest empties
  `com.apple.mediaaccessibility` during boot.
- **Ycode must**: write the keys, post the notifications; the filtering
  itself is done by the guest's compositor (backboardd) from these settings,
  so Ycode's display path must not bypass it (check on Ycode that the
  framebuffer shows the filter; OPEN Q4).

### 4.4 Text Size (Dynamic Type)

- **Controls**: 12 sizes: extra-small, small, medium, large (default),
  extra-large, extra-extra-large, extra-extra-extra-large,
  accessibility-medium, accessibility-large, accessibility-extra-large,
  accessibility-extra-extra-large, accessibility-extra-extra-extra-large;
  increment/decrement; Larger Accessibility Sizes on/off.
- **Guest**: domain `com.apple.UIKit`, key `UIPreferredContentSizeCategoryName`
  = `UICTContentSizeCategory` + `XS`, `S`, `M`, `L`, `XL`, `XXL`, `XXXL`,
  `AccessibilityM`, `AccessibilityL`, `AccessibilityXL`, `AccessibilityXXL`,
  `AccessibilityXXXL`. Domain `com.apple.preferences-framework`, key
  `largeTextUsesExtendedRange` (true when an accessibility size is chosen;
  `simctl` sets it with the size; `devicectl` sets it as its own option, and
  the accessibility sizes require it).
- **Setter posts**: `ApplePreferredContentSizeCategoryChangedNotification`.
- **Live**: yes (UIContentSizeCategoryDidChange and trait change ~20 ms).
- **Persists**: yes.
- **Ycode must**: write both keys, post the notification. Increment and
  decrement step through the 12 names in order and stop at the ends.

### 4.5 Reduce Motion

- **Guest**: AX domain `ReduceMotionEnabled` = 1 (also
  `PointerEffectScalingEnabled` = 0).
- **Setter posts**: `com.apple.accessibility.cache.ax`,
  `com.apple.accessibility.reduce.motion.status`. System posts
  `com.apple.accessibility.cache.reduce.motion`,
  `com.apple.accessibility.reduce.motion.status`,
  `com.apple.accessibility.cache.pointer.effect.scaling`,
  `com.apple.accessibility.pointer.effect.scaling`.
- **Live**: yes. **Persists**: yes. **Ycode must**: write, post.

### 4.6 Increase Contrast

- **Guest**: AX domain `DarkenSystemColors` = 1 and
  `PointerIncreasedContrastEnabled` = 1 (0 and 0 to turn off).
- **Setter posts**: `com.apple.accessibility.cache.ax`,
  `com.apple.accessibility.status`, `com.apple.accessibility.darken.system.colors`.
  System posts `com.apple.accessibility.cache.darken.system.colors.enabled`,
  `com.apple.accessibility.darken.system.colors`,
  `com.apple.accessibility.cache.pointer.increased.contrast`,
  `com.apple.accessibility.pointer.increased.contrast`; UI processes re-post
  `com.apple.accessibility.status`.
- **Live**: yes (UIAccessibility darker-colors notification; trait
  accessibility contrast becomes high). **Persists**: yes.
- **Ycode must**: write, post. `simctl`-style getter answers enabled/disabled
  from `DarkenSystemColors`.

### 4.7 Show Borders

- iOS 26.1+ name for Button Shapes (public `AXShowBordersEnabled`).
- **Guest**: AX domain `ButtonShapesEnabled` = 1.
- **Setter posts**: `com.apple.accessibility.button.shapes`. System posts
  `com.apple.accessibility.cache.button.shapes.enabled`,
  `com.apple.accessibility.button.shapes`. (The public show-borders status
  notification's value is `com.apple.accessibility.button.shapes`.)
- **Visible**: text-style system buttons get an underline.
- **Live**: yes. **Persists**: yes. **Ycode must**: write, post.

### 4.8 Reduce Transparency

- **Guest**: AX domain `EnhancedBackgroundContrastEnabled` = 1.
- **Setter posts**: `com.apple.accessibility.enhance.background.contrast.status`.
  System posts `com.apple.accessibility.cache.enhance.background.contrast`
  and the status again.
- **Visible**: blur materials and glass become opaque.
- **Live**: yes. **Persists**: yes. **Ycode must**: write, post.

### 4.9 VoiceOver

- **Guest**: AX domain `VoiceOverTouchEnabled`, `AccessibilityEnabled`
  (boolean), `ApplicationAccessibilityEnabled`, all 1 to enable and 0 to
  disable.
- **Setter posts**: `com.apple.accessibility.cache.ax`,
  `com.apple.accessibility.cache.app.ax`,
  `com.apple.accessibility.application.status`. System posts
  `com.apple.accessibility.cache.vot`, `com.apple.accessibility.voiceovertouch.status`,
  then the runtime's VoiceOver process (`vot`) starts, writes
  `VOTIsRunningKey` and `com.apple.VoiceOverTouch` defaults and posts
  `com.apple.accessibility.voiceover.launched`; SpringBoard posts
  `com.apple.accessibility.loaded`.
- **Visible**: a "VoiceOver Gestures" sheet with OK appears on first enable
  and the VoiceOver focus rectangle is drawn; speech goes to the audio
  output. Turning VoiceOver off does not dismiss that sheet.
- The reference setter waits until VoiceOver reports the new state (best
  effort with a timeout).
- **Live**: yes (status notification). **Persists**: yes.
- **Ycode must**: write, post, then poll `VOTIsRunningKey` (or the
  voiceovertouch status) to confirm; Ycode's boot must allow the `vot` job to
  start.

### 4.10 Location

- **Controls**: none (default); a fixed point (presets in §7.1 or custom
  latitude/longitude); a route (≥2 waypoints, speed m/s default 20, updates
  per distance in metres or per time interval in seconds, default 1 s); a
  scenario (City Run, City Bicycle Ride, Freeway Drive, Apple, or a scenario
  file inside the runtime); clear.
- **Guest mechanism**: the setter uses CoreLocation's simulation manager in
  the guest, which talks to `locationd` over NSXPC on the Mach service
  **`com.apple.locationd.simulation`** (the setter needs the
  `com.apple.locationd.simulation` entitlement). Request sequences observed:
  - fixed point: clear simulated locations, stop, append the location,
    start;
  - route: stop, clear, set interval (or distance), set speed, append each
    waypoint, start;
  - scenario: stop, clear, load scenario from a file URL in the runtime,
    start (locationd reads the file);
  - clear: stop, clear.
  locationd then enables simulation for all its location providers and
  delivers fixes to clients: fixed point accuracy 5 m, speed −1, course −1,
  altitude 0, the same fix re-sent every 1 s; route fixes at the interval
  with the given speed and the course along the segment, accuracy 5 m;
  scenario fixes as recorded (accuracy 10–30 m, ~1 s).
- **Scenario file format** (runtime `System/Library/Frameworks/CoreLocation.framework/Support/SimulationScenarios/<name>.plist`):
  binary plist with `Locations` (array of keyed-archive data, each a
  `CLLocation` with coding keys `kCLLocationCodingKeyCoordinateLatitude`,
  `…Longitude`, `…Altitude`, `…HorizontalAccuracy`, `…VerticalAccuracy`,
  `…Course`, `…Speed`, `…Timestamp`, `…Lifespan`, `…Type`) and `Options`
  (`LocationRepeatBehavior` real, 1 = once, 2 = loop as used by the trip
  scenarios; `LocationDeliveryBehavior` real, 0).
- **Live**: yes (an authorized app gets the first fix ~35 ms after start;
  clearing makes running clients get a location error, code 0).
- **Persists**: **no** (after reboot no simulation runs).
- No preference keys change.
- **Ycode must**: provide a guest agent with the simulation entitlement that
  drives CoreLocation's simulation manager (or locationd's simulation
  service) in these sequences; the presets are host-side coordinates (OPEN
  Q5 lists their values); routes and scenarios run inside locationd, so the
  host only sends parameters once.

### 4.11 Sound (volume)

- **Controls**: slider 0–100 (Device Hub; Increase/Decrease Volume menu
  items); no `simctl` command.
- **Guest**: `DEV/data/var/run/simulatoraudio/audiosettings.plist` key
  `sim_volume` (integer 0–100; default 60) is updated and the bridge posts
  `com.apple.springboard.volumestate` in the guest. Audio clients then report
  that volume (an app's audio session output volume read 0.30 after
  setting 30).
- **Live**: the value changes in running apps; no output-volume KVO callback
  was seen.
- **Persists**: the file keeps the value across reboot, but after reboot the
  guest reported the default 0.60 again (OPEN Q6).
- Ringer: `sim_ringer_state` (1) in the same file and the guest notification
  `com.apple.springboard.ringerstate`; the reference offers no ringer/mute
  control for the iPhone Duo.
- **Ycode must**: update `sim_volume` the way §12 of `audio-host.md` already
  writes the file (temporary file and rename) and post
  `com.apple.springboard.volumestate`; Ycode's own audio service
  (`audio-host.md`) should apply the volume to its output.

### 4.12 Output and 4.13 Input (audio device selection)

- **Controls**: Output: None, Use System Settings ("System", default), each
  host output device by name. Input: None, Use System Settings, each host
  input device by name.
- **Host file** `DEV/data/var/run/com.apple.coresimulator.audio.plist`:
  `sim_output_device_uid`, `sim_input_device_uid` (host CoreAudio device
  UIDs, e.g. `BuiltInSpeakerDevice`, `BuiltInMicrophoneDevice`, or a
  Bluetooth device UID such as `<MAC>:output`), `useHostDefaultOutputDevice`,
  `useHostDefaultInputDevice` (true for "System"). With the flags true the
  host follows changes of the Mac's default devices by itself.
- **Delivery**: after rewriting the file the host has CoreSimulatorBridge
  post `com.apple.CoreSimulator.audio.devices_changed` in the guest (the
  bridge's launchd job also launches on that notification); the bridge then
  rewrites `audiosettings.plist` with the new UIDs (keeping volume and
  ringer).
- **Live**: yes for the files; apps' audio routes always show one "Speaker"
  output whatever the host device (the routing happens in the host audio
  service, `audio-host.md`).
- **Persists**: yes (both files keep the selection across reboot).
- **Ycode must**: keep the selection in Ycode's device state, write the host
  file, post the notification in the guest, rewrite `audiosettings.plist`,
  and route its host audio I/O (`audio-host.md`) to the chosen devices;
  "System" follows the Mac's default devices; "None" mutes (encoding OPEN
  Q7).

## 5. Persistence summary

| Feature | Stored in | Survives reboot |
|---|---|---|
| Appearance | `com.apple.uikitservices.userInterfaceStyleMode` | yes |
| Liquid Glass | `com.apple.UIKit` | yes |
| Text Size | `com.apple.UIKit`, `com.apple.preferences-framework` | yes |
| Reduce Motion, Increase Contrast, Show Borders, Reduce Transparency, VoiceOver | `com.apple.Accessibility` | yes |
| Color Filter | `com.apple.mediaaccessibility` | **no** (emptied at boot) |
| Location | locationd memory | **no** |
| Volume | `audiosettings.plist` | file yes; guest volume back to 60 % (Q6) |
| Output / Input | `com.apple.coresimulator.audio.plist`, `audiosettings.plist` | yes |

`Reset Content and Settings` (erase) resets all of them (fresh data
directory).

## 6. What Ycode must do

1. **A Ycode guest settings agent** (Ycode's own binary, launched by Ycode's
   launchd plist in `DEV/data/Library/LaunchDaemons/` like the reference's
   agents): a Mach service in the guest bootstrap that accepts Ycode's own
   requests from the host (over Ycode's existing host↔guest transport) and
   applies them with the runtime's own APIs: the preferences API for the
   keys in §4, `notify_post` for the setter notifications, CoreLocation's
   simulation manager for §4.10. It needs entitlements for preferences in
   the listed system domains, `com.apple.locationd.simulation`, and
   whatever the UIKit style service requires (OPEN Q8).
2. **Setter notifications are required**; system reactions come from the
   runtime's own daemons, which Ycode already runs (backboardd, SpringBoard,
   `vot`, AccessibilityUIServer). Ycode must not post the system ones itself.
3. **Getters** read the same keys (and VoiceOver's running flag) so Ycode's
   UI shows the device's real state, including changes made in the guest's
   own Settings app. The reference host watches the guest notifications
   listed in §7.1 to refresh its controls; Ycode's agent should forward those
   to the host.
4. **Host CLI**: Ycode's command-line tool offers at least the `simctl`
   forms (`ui appearance|increase_contrast|content_size`, `location
   set|start|run|clear|list`) with the same value names and output strings
   (`light`, `dark`, `enabled`, `disabled`, size names, "Parsed N
   waypoints"), plus subcommands for the features `simctl` lacks, with
   `devicectl`'s value names (§2, §7.2).
5. **Audio**: §4.11–4.13 on top of `audio-host.md`.
6. **Persistence** follows §5 automatically if the keys are written through
   the guest's preferences; location and colour filter must not be restored
   by Ycode after a reboot.

## 7. IDE section (for `specs/ide/`): where Xcode 27 puts these controls

Xcode 27 has no Simulator.app; simulator windows and their controls are in
**Device Hub**. Labels below are exact. The window itself (hub and compact
windows, sidebar, toolbar, canvas, device controls, inspector tabs, the
other menus and the Screenshot shortcut ⇧⌘S) is specified in
`specs/ide/device-hub.md`.

### 7.1 Device Hub

- **Inspector**, first tab, for a booted simulator, three boxes:
  1. Appearance — pop-up (Light, Dark; shows the current value);
     Liquid Glass — slider (opacity), plus a look-and-feel pop-up when the
     device supports more than one look; Color Filter — pop-up (None,
     Red/Green (Protanopia), Green/Red (Deuteranopia), Blue/Yellow
     (Tritanopia), Grayscale; a short label is shown for the colour filters);
     Text Size — slider with 12 steps; Reduce Motion, Increase Contrast, Show
     Borders, Reduce Transparency, VoiceOver — switches.
  2. Location — pop-up (same items as the menu below).
  3. Sound — slider; Output — pop-up ("System" = Use System Settings);
     Input — pop-up ("System").
  Each row has a leading symbol. Only elements the device reports as
  customizable are shown; with none: "No settings are available for the
  selected …". For a simulator that is not running: "Start the simulator to
  customize behavior and appearance." Failures show alerts titled "Failed to
  Set Appearance", "Failed to Set Liquid Glass", "Failed to Set Color Filter",
  "Failed to Set Text Size", "Failed to Set Reduce Motion", "Failed to Set
  Increase Contrast", "Failed to Set Reduce Transparency", "Failed to Set
  VoiceOver", "Failed to Set Volume", "Failed to Set Location".
- **Menu bar** Device menu (order): Restart, Shut Down, Force Shut Down,
  Accessibility ▸, Appearance ▸, Battery ▸, Face ID ▸, Touch ID ▸, Optic ID ▸,
  Location ▸, Orientation ▸, Sound ▸, Enter Resize Mode, Keyboard ▸, Pair
  Apple Watch…, Reset Content and Settings…
  - Accessibility ▸ Reduce Motion, Reduce Transparency, Increase Contrast,
    Show Borders, Increase Text Size, Decrease Text Size, VoiceOver.
  - Appearance ▸ Toggle Appearance, Light, Dark, Auto.
  - Location ▸ None; Berlin, Germany; Cupertino, CA, USA; Hong Kong, China;
    Johannesburg, South Africa; London, England; Mexico City, Mexico; Mumbai,
    India; New York, NY, USA; Paris, France; Rio de Janeiro, Brazil; San
    Francisco, CA, USA; Sydney, Australia; Tokyo, Japan; Warsaw, Poland;
    section Trips: City Run, City Bicycle Ride, Freeway Drive; Apple; Custom
    Coordinates… (sheet "Custom Coordinates" with Latitude and Longitude
    fields). DeviceKit also has an "Import GPX File" location option, which
    the menu of this device did not list.
  - Sound ▸ Increase Volume, Decrease Volume; section Input: None, Use System
    Settings, then host input devices by name; section Output: None, Use
    System Settings, then host output devices by name.
  - Keyboard shortcuts: Screenshot is ⇧⌘S (`device-hub.md` §7); the rest are not recorded (OPEN Q9).
- Controls menu (for completeness): Home, Lock, Siri, App Switcher, Action
  Button, Rotate Left, Rotate Right, Screenshot, Record Screen.
- Device Hub refreshes its controls when the guest posts
  `com.apple.UIKit.SystemUIServiceUserInterfaceStyleNotification`,
  `ApplePreferredContentSizeCategoryChangedNotification`,
  `UIViewGlassLegibilityDidChangeNotification`,
  `com.apple.accessibility.cache.button.shapes.enabled`,
  `com.apple.accessibility.voiceovertouch.status`,
  `com.apple.accessibility.grayscale`, `com.apple.accessibility.red-color-filter`,
  `…green-color-filter`, `…blue-color-filter`.

### 7.2 Command line

- `simctl ui`, `simctl location` as in §2 and §4.
- `devicectl device settings appearance|voiceover|audio`, `devicectl device
  simulate location coordinate|route|scenario|list|clear` with the options in
  §2; `route --route-file` takes JSON { `mode`: "distance"|"interval",
  `distance` | `interval`, `speed`, `waypoints`: [{ `latitude`, `longitude` }] }.

### 7.3 Xcode's Environment Overrides (debug bar)

Shown in the debug bar while an app runs under the debugger as a pop-over
with one section per category and an action that disables all overrides
(from the panel's view and action names; the layout was not observed live,
OPEN Q11). Items, in category order and position order:

| Category | Item | Values (first = default) | Platforms |
|---|---|---|---|
| Appearance | Appearance | No Override, Light, Dark | iOS, tvOS |
| Dynamic Type | Dynamic Type (slider view) | No Override, X Small, Small, Medium, Large (Default), X Large, XX Large, XXX Large, Accessibility 1, 2, 3, 4, 5 | iOS, watchOS |
| Accessibility | Increase Contrast | No Override, Increased, Default | iOS, tvOS |
| | Reduce Transparency | No Override, Reduced, Default | iOS, tvOS |
| | Bold Text | No Override, Enabled, Disabled | iOS, watchOS, tvOS |
| | Reduce Motion | No Override, Reduced, Default | iOS, watchOS, tvOS |
| | On/Off Labels | No Override, Enabled, Disabled | iOS, watchOS |
| | Button Shapes | No Override, Enabled, Disabled | iOS |
| | Grayscale | No Override, Enabled, Disabled | iOS |
| | Smart Invert | No Override, Enabled, Disabled | iOS |
| | Differentiate Without Color | No Override, Enabled, Disabled | iOS |

macOS (AppKit) targets: Appearance, Increase Contrast (turning it on implies
Reduce Transparency), Reduce Transparency, Reduce Motion, Differentiate
Without Color. Behaviour: an override applies **only to the debugged
process**, by the debugger running code inside that app; the device's
settings and other apps are unchanged, and the override ends with the debug
session. **Ycode decision**: Ycode's debugger implements overrides by
evaluating its own code in the target process (calling the runtime's public
or private override entry points it finds), never by changing device
preferences; the IDE layout follows this table.

## 8. Open questions

- Q1. Appearance "Auto": what is written (a third `UserInterfaceStyleMode`
  value?) and how the guest switches.
- Q2. How the set of supported Liquid Glass looks is decided (one on iOS
  27.1 iPhone Duo).
- Q3. `MADisplayFilterType` codes and intensity keys for grayscale,
  deuteranopia and tritanopia.
- Q4. Whether Ycode's display path (`simframebuffer.md`) receives the frame
  after the guest's colour filter, as the reference's screenshots do.
- Q5. Coordinates of Device Hub's location presets (host-side constants; not
  read).
- Q6. Why the guest reports 60 % volume after a reboot while
  `audiosettings.plist` keeps another value.
- Q7. How Device Hub's audio "None" is encoded in the host file.
- Q8. Entitlements a non-Apple guest agent needs for the UIKit style service
  and the accessibility settings writes; whether writing
  `UserInterfaceStyleMode` alone (without the service) is enough.
- Q9. Device Hub keyboard shortcuts.
- Q10. The host → CoreSimulatorBridge request format for `simctl ui` and
  `simctl location` (not needed by Ycode, which uses its own transport).
- Q11. Environment Overrides pop-over layout, default switch states and the
  debug-bar button's look (only Xcode's declarations were read).

## I. Ycode implementation (agent FEAT-IMPL, 2026-10-27)

Clean-room: written from §1–§8, public headers (CoreFoundation
preferences, `notify.h`, CoreLocation, UIKit, dyld interposing), the GPX
1.1 schema, and selector names of CoreLocation's simulation manager that
open-source location tools publish; no Apple binary, simulator or Xcode was
read or run. Shared model: `ycode/Sources/YcodeSimFeatures` (one table of
§4's keys and notifications, used by ycode-simd, the viewer, the IDE and the
tests).

### I.1 The agent

`ycode-settings-agent` (`ycode/SimGuestAgents/settings`, Objective-C, built
for the iOS simulator by `SimGuestAgents/build.sh`, the entitlement
`com.apple.locationd.simulation` in `__TEXT,__entitlements`). ycode-simd
copies it to `DEV/data/Library/Ycode/bin/` at every cold boot (from the
guest-tools directory, `--settings-agent <binary>|none`) and writes
`DEV/data/Library/LaunchDaemons/dev.ycode.simulator.settings.plist`:
`ProgramArguments` = the agent's DEV path, `RootedSimulatorPath` true (a
DEV path, not a runtime path; without it launchd_sim looks for the program
under the runtime root, `launchd-sim.md` §4.4), `RunAtLoad`, `KeepAlive`,
`ProcessType` Interactive (an Adaptive job is held at boot until the system
is quiet, about 65 s, `scheduling-policy.md` §4.2), stderr in
`DEV/data/tmp/ycode-settings-agent.log`. launchd_sim runs it in
`user/<uid>` with HOME = DEV/data, so `CFPreferences` with the current user
and any host reaches the device's preference files through the guest's
cfprefsd. On another platform's runtime the image is retagged
(`GuestImagePlatform`) or left out.

### I.2 The host channel

The agent connects an AF_UNIX stream socket to
`/private/var/run/dev.ycode.settings`. That path is a host-provided socket
of the VMM (`HostStreamSockets.serve`, next to the DNS service's): the
connect succeeds with no guest listener and the bytes go to ycode-simd's
`SimSettingsController`. Frames both ways: a 4-byte big-endian length, then
an XML property list with a dictionary root (`SettingsChannel.swift`).
Requests `{id, op}`: `apply` (writes `{domain, key, value?}` — no value
removes the key — then `notify` names, optional `startServices` (Mach
service names whose on-demand launchd jobs the agent starts by sending each
an empty message), optional `waitVoiceOver`), `read`
(`{domain, key}` → `values["domain|key"]`), `notify` (optional `states`,
set with `notify_set_state` first), `location` (`steps`, I.5), `watch`
(names the agent reports as `{event: "notification", name}`), `ping`.
Replies `{id, ok, error?, values?, voiceOverRunning?}`; the agent says
`{event: "hello", pid, version}` first. The agent reconnects when the
connection ends (a snapshot restore resets host-socket connections), so
restored devices keep working. After the hello the host asks it to watch
§7.1's notifications (and the system's cache notifications of §4.5–4.8)
and sends the commands queued while the device was stopped (I.4). A
command waits up to 60 s for the agent (`YCODE_SETTINGS_AGENT_WAIT_S`) and
15 s for an answer (20 s for VoiceOver).

### I.3 Per feature

| Feature | Status | Writes / posts (setter) | Verified on the Linux host (probe app, screenshots) |
|---|---|---|---|
| Appearance | done | `UserInterfaceStyleMode` 1/2; **posts nothing** | live: the app's style flips; SpringBoard posts `…SystemUIServiceUserInterfaceStyleNotification` itself; home screen light/dark wallpaper; persists |
| Liquid Glass | done | `UIViewGlassTintAmount`, `UIViewGlassLegibilitySetting` 1 / removed; the two update notifications | keys read back; persists |
| Color Filters | done | §4.3 keys, codes of I.7; per-filter notification | live, in screenshots (the framebuffer is filtered, Q4); grayscale, and three distinct colour shifts; not restored after a reboot |
| Text Size | done | category + extended range for accessibility sizes; `ApplePreferredContentSizeCategoryChangedNotification` | live (UIContentSizeCategoryDidChange and the trait change); persists, also when written while the device was stopped; increment/decrement stop at the ends |
| Reduce Motion | done | `ReduceMotionEnabled`, `PointerEffectScalingEnabled` 0 (removed when off) | live (status notification); the system posts its cache notifications; persists |
| Increase Contrast | done | `DarkenSystemColors`, `PointerIncreasedContrastEnabled` | live (trait contrast high); persists |
| Show Borders | done | `ButtonShapesEnabled` | live (text buttons underlined); persists |
| Reduce Transparency | done | `EnhancedBackgroundContrastEnabled` | live (materials opaque); persists |
| VoiceOver | done | the three keys and three notifications; on: the agent starts the screen reader's on-demand job (an empty message to its Mach service `com.apple.VoiceOverTouch`, **Ycode decision**); waits up to 10 s for VoiceOver's running key | on: `vot` starts (it registers with Ycode's audio service and starts audio IO for speech), writes its running key, the VoiceOver focus rectangle is drawn on the home screen; off: `vot` ends within about 2 s and clears the key; apps get the VoiceOver status notification and `UIAccessibilityIsVoiceOverRunning` follows; after a reboot with VoiceOver on, the agent starts `vot` again (I.8) |
| Location | done | §4.10 sequences through the simulation manager | fixed point (preset): first fix in the app 92 ms after the command started, accuracy 5 m, speed/course −1; route with 3 waypoints at 20 m/s, a fix a second, course along the segment; City Run from the runtime; a GPX track replayed at its recorded spacing; clear → error 0; not restored after a reboot |
| Sound | done | host writes `sim_volume` through the host-write hook (`HostDataWrites`, temporary file and rename); agent posts `com.apple.springboard.volumestate` | Ycode's audio output is scaled by the volume at once; a running app's `outputVolume` follows live (0.60 → 0.30 → 0.80 → 0.45, each in the probe's next 5 s sample; I.9); the file keeps the value and apps read it at their next launch (0.30 after a reboot) |
| Output / Input | done (Ycode's devices) | both files, `com.apple.CoreSimulator.audio.devices_changed` | files rewritten, persist; None silences Ycode's output |

All live changes reached the running probe app. Timed on the Linux host
(run r6, the probe's wall clock against the host's, from the start of the
`ycode-simd --ui …` client process, which itself takes about 20–40 ms to
connect and finish): appearance 110 ms, text size 134 ms, Increase Contrast
94 ms, Show Borders 107 ms, Reduce Transparency 63 ms, Reduce Motion 399 ms,
a fixed location's first fix 92 ms, an environment override 24–214 ms. The
command round trip itself (control socket → agent → cfprefsd → posts →
answer) took 5–55 ms. The reference's ~50 ms is from the setter's request,
not from a client process start.

### I.4 Controls

- **Control socket** (`FoldControl.swift`, answered by `SimSettings.swift`;
  one thread per connection): `ui appearance [light|dark|toggle]`, `ui
  content_size [<simctl name>|increment|decrement]`, `ui increase_contrast
  [enabled|disabled]`, `ui liquid-glass [<0…1>] [clear|tinted]`, `ui
  color-filter <none|protanopia|deuteranopia|tritanopia|grayscale>
  [<0.25…1>]`, `ui larger-accessibility-sizes on|off`, `accessibility
  reduce-motion|increase-contrast|show-borders|reduce-transparency|voiceover
  [on|off]`, `location set <lat>,<lon> | preset <name> | start [--speed=S]
  [--distance=M|--interval=S] <lat>,<lon>… | run <scenario name or guest
  .plist path> | file <host path> | clear | list`, `audio volume
  [0…100|up|down] | output [none|system|<uid>] | input […] | devices`,
  `overrides <bundle id> [show|clear|<item>=<value>…]`, `settings` (every
  setting, one per line). Getters answer simctl's words (`light`, `dark`,
  `enabled`, `disabled`, size names); a route answers "Parsed N waypoints".
  Diagnostics: `settings events|read <domain> <key>|write <domain> <key>
  int:N|real:X|bool:B|string:S|remove|notify <name>…|notify-state <name> <n>`.
- **Command line**: `ycode-simd --device DEV --ui|--accessibility|--location|--audio|--overrides
  <words…>` and `--settings` (the same words; getters print the bare
  value). With no running device, persistent settings (§5: everything but
  location and colour filters) are written into the device's preference
  files (binary plists, as cfprefsd keeps them) and queued in
  `DEV/ycode-pending-settings.txt`, which the agent applies when it next
  connects (so a warm-boot restore gets them too); location and colour
  filters answer "needs a running device" (exit 69). The launcher
  `ycode-sim.sh` passes these options straight to ycode-simd.
- **Viewer**: Device ▸ Accessibility ▸, Appearance ▸, Color Filter ▸,
  Location ▸, Sound ▸ with §7.1's items, as device commands over the
  display stream (`0x90` command, `0x10` answer; `display-stream.md`); check
  marks from `settings`.
- **IDE**: `specs/ide/devices.md` §Settings, `debug.md` §Environment
  Overrides and Simulate Location, `run.md` §Settings and Environment
  Overrides.

### I.5 Location

Requests go to CoreLocation's simulation manager (class
`CLSimulationManager`, reached by name; every selector is checked):
`clearSimulatedLocations`, `stopLocationSimulation`,
`appendSimulatedLocation:`, `startLocationSimulation`,
`setLocationInterval:`, `setLocationDistance:`, `setLocationSpeed:`,
`setLocationRepeatBehavior:`, `loadScenarioFromURL:`, then `flush`, in
§4.10's orders. Appended points carry accuracy 5 m, vertical accuracy −1,
course and speed −1. Scenarios: a runtime scenario by name
(`DEV`-independent guest path in the runtime; its data never enters
Ycode), a scenario file at a guest path, or Ycode's own: a GPX file
(`trkpt`/`rtept`/`wpt`, `ele`, `time`), the route JSON of §7.2 or
"lat,lon" lines (`SimLocation.parseFile`). Points with times become a
scenario the agent writes (`DEV/data/tmp/ycode-location-scenario.plist`,
§4.10's format: each fix a keyed-archived `CLLocation` made with the public
initializer, Options `LocationRepeatBehavior` 1 or 2,
`LocationDeliveryBehavior` 0); anything else becomes a route at 20 m/s,
one fix a second. **Finding on Ycode:** locationd plays a scenario fix only
when its `kCLLocationCodingKeyType` is 1; an archive of a new `CLLocation`
has 0, and such a scenario delivers nothing (clients get error 0), so the
agent sets the key to 1 in each archive.

### I.6 Environment Overrides

**Ycode decision** (§7.3): a remote Ycode run has no debugger, so Ycode
puts its own code into the app at launch instead of evaluating code in it:
with `--environment-overrides`, ycode-simd stages
`libYcodeEnvironmentOverrides.dylib` (`SimGuestAgents/overrides`) into DEV
and launches the app with `DYLD_INSERT_LIBRARIES` naming it and
`YCODE_ENV_OVERRIDES_DIR` naming `DEV/data/Library/Ycode/EnvironmentOverrides`.
The host keeps `<bundle id>.plist` there (removed at each launch: overrides
end with the run) and has the agent post
`dev.ycode.environment-overrides.changed`; the library rereads the file and
applies appearance, Dynamic Type, Increase Contrast and Bold Text as trait
overrides of every window scene, and the nine accessibility items by
answering UIKit's status functions (dyld interposing) and posting their
public change notifications. Device preferences are never written. Verified:
`appearance=light dynamic-type=small bold-text=on reduce-motion=off` on a
device set to dark, extra-large and Reduce Motion made the app light,
small and bold with Reduce Motion off within one notification; clearing
returned it to the device's settings. Limits: SwiftUI views that read
accessibility settings through UIKit's private paths, not the public
functions, may not follow the switch overrides.

### I.7 Answers to the open questions (Ycode behaviour)

- Q1 (Auto): not offered; Light and Dark only (Ycode decision).
- Q2: Ycode offers one look (no look pop-up); `ui liquid-glass … tinted|clear` sets the key.
- Q3: **Ycode decision**: `MADisplayFilterType` grayscale 1, protanopia 2
  (observed in the reference), deuteranopia 4, tritanopia 8; intensities in
  `MADisplayFilter{Red,Green,Blue}ColorCorrectionIntensity`. On Ycode each
  code gives a different filter in screenshots (Safari's compass: none
  (127, 189, 235), protanopia (127, 197, 190), deuteranopia (125, 191, 187),
  tritanopia (126, 165, 235), grayscale (175, 175, 175)); whether they
  match the reference's codes is still open.
- Q4: yes on Ycode: the display stream and screenshots show the filtered frame.
- Q5: the cities' commonly published centres (`SimLocation.presets`).
- Q6: **Ycode decision**: the file's volume applies after a reboot (apps read 0.30).
- Q7: **Ycode decision**: None = empty UID with the host-default flag off.
- Q8: on Ycode writing `UserInterfaceStyleMode` through cfprefsd is enough
  (SpringBoard announces it, apps flip); the AX keys need no entitlement
  under Ycode. Ycode's agent has only the location entitlement.
- Q9: the viewer's shortcuts are Ycode's (⇧⌘A Toggle Appearance, ⌥⌘+ / ⌥⌘−
  text size).
- Q10: not needed (Ycode's own channel).
- Q11: Ycode's pop-over layout, `specs/ide/debug.md`.

### I.8 Verification

Thor runs r2–r6 (iOS 27.1, iPhone Duo, full boot) with Ycode's probe app
`SimShim/guest-tests/features/FeatureProbe.m` (`build-features.sh`;
prints trait collection, content size, the accessibility switches,
location updates, audio volume and route, each line with milliseconds since
launch and the wall clock), `ycode-display-probe` (taps; the new `command`
step drives the display-stream command path) and control-socket
screenshots. Persistence: a reboot kept appearance, text size (also one
written while the device was stopped), contrast, Reduce Motion, Show
Borders, Reduce Transparency, Liquid Glass, VoiceOver's keys, volume and
output; the colour filter (grayscale) and the location were gone.

Runs r9–r11 (FEAT-IMPLb, 2026-10-28, after the merge of the main line):
VoiceOver on started `vot` (audio client, aggregate device and IO for its
speech), off ended it about 2 s later (the command answered "VoiceOver not
running" in 290 ms), on again started a new `vot` (3.9 s until its running
key); with the probe app in front, protanopia and grayscale screenshots;
with VoiceOver, dark and grayscale set, a reboot (r11) came back dark,
without the filter, with VoiceOver on and the focus rectangle on the home
screen (the agent's boot start; `vot` started audio IO 2 s later). Settings
written while the device was stopped (appearance light, VoiceOver off)
were applied at the next boot (r10). Screenshots (outside the repository):
`feat-dark.png` (dark home screen after the reboot, VoiceOver's focus on
Settings), `feat-filter.png` (protanopia over the probe app),
`feat-voiceover.png` (VoiceOver with dark and grayscale).

### I.9 Not done

- What starts VoiceOver's screen reader in the reference is not in this
  spec (a dirty-room question: the launch condition of the job, or the
  request that starts it). Writing the keys and posting the notifications
  does not start it under Ycode, so **Ycode decision**: the agent starts
  the job through one of its Mach services (`launchctl print` of the
  running Ycode device lists the job in `user/<uid>` with the services
  `com.apple.VoiceOverTouch`, `….xpc`, `….drag.xpc` and
  `com.apple.accessibility.AXVoiceOverServer`, all on demand), after a live
  switch and when it connects after a boot with VoiceOver enabled
  (`SimFeatureMapping.bootPlan`). Ycode stops a device by killing its
  processes, so `vot`'s running key can outlive it; after a boot the agent
  therefore starts the reader whenever VoiceOver is enabled, and removes a
  left-over running key when it is not.
- ~~A running app's `AVAudioSession.outputVolume` does not follow a volume
  change.~~ Fixed (agent VNODE-EVENTS, 2026-10-28): the app's audio
  session watches the `simulatoraudio` directory with a dispatch vnode
  source (EVFILT_VNODE `NOTE_WRITE`, flags `EV_CLEAR | EV_DISPATCH |
  EV_UDATA_SPECIFIC | EV_VANISHED`; seen with `YCODE_DEBUG_VNODE=1`, Ycode's
  own registration log), and Ycode's kernel never fired such knotes. It now
  does (`threads-and-events.md` §3.10), and ycode-simd writes the audio
  files through the host-write hook, so the directory gets `NOTE_WRITE`
  when the file is replaced. Verified on the Linux host (runs `vnode/v1`, `v2`,
  FEAT's check: FeatureProbe in front, `--audio volume 30`, `80`, `45`):
  the app got one `NOTE_WRITE` per change and its next 5 s sample showed
  0.30, 0.80, 0.45. The probe samples every 5 s, so the measured 4–5 s is
  its sampling period, not the delivery time.
- Host audio device enumeration: Ycode's audio service has one output and
  no input device and does not list the Linux host's devices.
- devicectl's CoreDevice protocol (§3) is not served.

## Evidence

| Claim | Level | Source |
|---|---|---|
| `simctl ui`, `simctl location`, `status_bar` options, defaults, outputs (§2, §4) | 3 | `simctl help`, runs on `ycode-test-features-1` |
| `devicectl` commands and options (§2, §7.2) | 3 | `devicectl help`, runs |
| Device Hub inspector labels, order, control kinds, menus (§7.1) | 3 | Device Hub window and menu bar read with background accessibility tools |
| Device Hub alert titles, colour filter labels, watched notifications, GPX/custom coordinates items (§7.1) | 4 | DeviceKit framework strings |
| Environment Overrides items, categories, order, values, platforms; per-process application (§7.3) | 4 | Xcode's `IDEiOSDebugger.xcplugindata`, `DebuggerFoundation.xcplugindata`, DebuggerUI resource names; not observed live |
| Guest agents are host-supplied, their Mach services and launch events (§1, §3) | 2, 4 | launchd plists in CoreSimulator's platform folder and in the device's `data/Library/LaunchDaemons`; binary strings |
| CoreDevice action dictionary and reply (§3) | 3 | our in-guest recorder (XPC receive/send hooks in dtconfigurationd) |
| Keys and values written per feature (§4) | 3 | plist diffs before/after each action; the guest's accessibility-settings debug log ("CF Save: domain, preference, value") |
| Notifications posted and by whom (§4) | 3 | our recorder's `notify_post` hook in every guest process |
| Live reaction of apps (§4) | 3 | our sample app's trait-change, UIAccessibility, CoreLocation and audio-session observers |
| Location request sequences, locationd behaviour, fixes (§4.10) | 3 | recorder (XPC sends from CoreSimulatorBridge and dtlocationd to `com.apple.locationd.simulation`), locationd log, sample app |
| CoreLocation simulation method names (§4.10) | 4 | ObjC selector names in CoreSimulatorBridge and dtlocationd |
| Scenario file format (§4.10) | 2 | the runtime's scenario plists read as files |
| Audio files and notifications (§4.11–4.13) | 3, 4 | plist diffs, recorder, a host default-device change; audio service strings |
| Persistence (§5) | 3 | reboot of the test device, `simctl ui` getters, plists, sample app relaunch |
| Visible results (§4) | 3 | `simctl io screenshot` of the sample app |
| Ycode implementation (§I): agent, channel, mapping, controls | 1 | §1–§8; public CoreFoundation, notify, CoreLocation, UIKit and dyld documentation and headers; GPX 1.1 schema; CLSimulationManager selector names from open-source location tools; Ycode code and tests (`SimFeaturesTests`, `SimSettingsTests`, `HostChannelTests`, `SimulatorSettingsUITests`, display-stream tests) |
| VoiceOver's job, its Mach services and on-demand launch on Ycode (§I.3, I.9) | 3 | `launchctl print` in a running Ycode device (one-shot), Ycode's audio-service log, screenshots |
| Results of §I.3, I.5 (type key), I.7 (Q3, Q4, Q6, Q8 on Ycode), I.9 | 3 | Ycode runs on the Linux host: Ycode's probe app, screenshots, launchd's log, the agent's log (no reference observed) |
| The app's vnode watch of `simulatoraudio` and the live volume (§I.3 Sound, I.9) | 3 | Ycode run `vnode/v1` on the Linux host: Ycode's EVFILT_VNODE registration and delivery log (`YCODE_DEBUG_VNODE=1`), Ycode's probe app (no reference observed) |

Level 5 was not used.
