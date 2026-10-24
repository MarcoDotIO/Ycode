# SwiftUI 1: simulator parity — what SwiftUI apps need from the simulator

Status: reference, round 0 (KIT-SWIFTUI, 2026-10-19). This is the first
target for Ycode's iOS simulator for SwiftUI: a guest app that uses
SwiftUI must behave under Ycode as it does under Apple's simulator. Ycode
does **not** implement SwiftUI for this: the guest loads Apple's SwiftUI
from the iOS 27.1 runtime. Ycode has to provide what that framework uses
at run time — processes, Mach/XPC services, notifications and host
features. Everything here is level 3 (our own app on Apple's simulator)
except the service-to-daemon mapping, which reads the runtime's launchd
job property lists as a file format (level 2).

## 1. Method

- **Probe:** `research/experiments/swiftui/SUIProbe/` (our SwiftUI app,
  built with `swiftc` and `actool` from Xcode 27.1, no project;
  `build.sh`, `run.sh`). One mode per launch (`-mode <name>`); it prints
  `SUP key=value` lines; modes and expected results are in
  `02-conformance-checklist.md`.
- **Device:** throwaway `ycode-test-swiftui-1` (iPhone Duo, iOS 27.1
  runtime 24A94401), booted headless with `simctl` (no Simulator.app
  window), one device at a time, deleted after the runs.
- **Input:** the simulator track's HID driver
  (`research/experiments/simulator/hid/hidsend.m`, taps, drags, keys) and
  `simctl ui`, `simctl openurl`, `simctl launch` of another app.
- **Service tracer:** `svctrace.c` (ours), inserted into our app only with
  `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`. It logs, by name, every
  `bootstrap_look_up`/`bootstrap_look_up2`, `xpc_connection_create_mach_service`,
  named `xpc_connection_create`, `CFMessagePortCreateRemote`, and every
  Darwin notification registration and post made through the exported
  entry points. **Blind spots:** lookups made inside libxpc itself,
  connections built from endpoints the app receives from another process
  (FrontBoard/BackBoard scene and workspace connections are set up this
  way — see `specs/simulator/app-install-launch.md` §5), and anything below
  the C API (MIG messages on already-held ports).
- **Job diffs:** `launchctl list` inside the device before and after each
  mode (which launchd jobs were running).
- Host load during the runs: load average 300–560 (other agents' work).
  Orders and values are reliable; durations are upper bounds.

## 2. Process-level facts

- Our SwiftUI app loaded **545 images** from the runtime by the time its
  first screen was up (mode `lifecycle`). SwiftUI-relevant ones (bundle
  names, level 4): `SwiftUI`, `SwiftUICore`, `UIKitCore`, `UIKitServices`,
  `UIFoundation`, `QuartzCore`, `CoreText`, `CoreUI`, `FontServices`,
  `RenderBox`, `AttributeGraph`, `Gestures`, `CoreMaterial`, `Symbols`,
  `SFSymbols`, `TextInput`, `AXRuntime`, `GraphicsServices`,
  `FrontBoardServices`, `BackBoardServices`, `RunningBoardServices`,
  `IOSurface`, `Metal`, `libswiftObservation`. Ycode's loader must map all
  of them (`specs/simulator/loader.md`, `host-library-*.md`); the count is a
  useful regression check (±10).
- Launch timing (Apple's simulator, loaded host): exec → `App.init`
  0.29–0.79 s; `App.init` → first frame 0.22 s; `UIScene` connects at
  0.14 s; scene active at 0.21 s (`06` §1).
- Display link: 60 Hz maximum (`UIScreen.maximumFramesPerSecond` 60;
  measured 56–60 callbacks per second). Animation sampling depends on it
  (`05` §1).
- Screen: 466 × 678 pt, scale 3, P3 gamut; window safe area bottom 34,
  trailing 84 (status area on the right edge of this device type).

## 3. Run-time dependencies

### 3.1 Services every SwiftUI app used (all modes)

| Service name (as looked up) | Owner (launchd job) | When | Used for (observed or inferred from timing) | Ycode spec |
|---|---|---|---|---|
| `com.apple.system.notification_center` | notifyd | 0.02 s | Darwin notifications (≈ 80 names registered, §3.4) | `launchd-sim.md` |
| `com.apple.logd` | logd | 0.02 s | unified logging | `service-fidelity.md` |
| `com.apple.cfprefsd.daemon` (XPC) | cfprefsd | 0.02 s | `UserDefaults`, `@AppStorage`, UIKit/SwiftUI preference reads | — |
| `com.apple.backboard.display.services` | backboardd | 0.04 s | display/screen facts; **fatal if missing** (`app-install-launch.md` §5) | `app-install-launch.md` |
| `com.apple.runningboard` (XPC) | runningboardd | 0.04 s | process state, foreground/background assertions (scene phases) | `processes.md` |
| `com.apple.CARenderServer` | backboardd | 0.06 s | Core Animation commits: **every SwiftUI frame** goes through it | `headless-rendering.md`, `display-stream.md` |
| `com.apple.lsd.mapdb` (XPC) | lsd | 0.07 s | bundle/URL-scheme database (`onOpenURL`, `Link`) | `app-install-launch.md` |
| `com.apple.fontservicesd` (XPC) | fontservicesd | 0.07 s | system font access (every `Text`) | — (to verify) |
| `com.apple.uiintelligencesupport.agent` (XPC) | intelligencecontextd | 0.14 s | UIKit intelligence/context support, connected at launch | `service-fidelity.md` (`intelligencetasksd` notes) |
| `com.apple.backboard.hid.services` | backboardd | 0.24 s | HID event routing for touches and keys | `hid-input.md` |
| FrontBoard workspace / scene connection | SpringBoard | before `didFinishLaunching` | `UIScene` lifecycle, scene phases, open-URL delivery | `app-install-launch.md` §5 (not visible to our tracer) |
| `com.apple.springboard.services` | SpringBoard | late, some modes (35 s in `layout`, also `split`) | SpringBoard queries (not tied to a specific action) | — |

### 3.2 Services used only by some features

| Feature (mode) | Service | Owner | Notes |
|---|---|---|---|
| Text input, focus (`keyboard`) | `com.apple.TextInput.preferences` | `com.apple.TextInput.kbd` (**started on demand** at the first text input) | kbd also owns `com.apple.TextInput` and 15 more names |
| Text input | `com.apple.pasteboard.pasted` | pasted | also on any `UIPasteboard` use (`services`) |
| Text input | `com.apple.containermanagerd.system` | containermanagerd_system | |
| Text input | `com.apple.SystemConfiguration.NetworkInformation_sim` | configd_sim | |
| Text input | `com.apple.mobileasset.autoasset` | mobileassetd | |
| Text input | `com.apple.sharing.remote-text-editing` | sharingd | |
| Text input | `com.apple.remote-text-editing-legacy`, `com.apple.rti-screencontinuity` | (no job in the runtime; lookups fail quietly) | must keep failing without side effects |
| Alerts, confirmation dialogs, glass (`modal`) | `com.apple.metal.simulator` (after a failing per-app name `com.apple.metal.simulator.<app>`, kr 1102) | **host** (CoreSimulator Metal service) | the app creates a Metal device when it first presents an alert/dialog | `metal-sim-protocol.md`, `stage8-contract.md` |
| Symbols in colour, accessibility tree, presentations (`images`, `a11y`, `modal`) | `com.apple.IOSurface.Remote` | **host** (remote IOSurface service) | | `iosurface-remote.md` |
| Accessibility tree enabled (`a11y-ax`) | `com.apple.iphone.axserver-systemwide` | backboardd | plus AccessibilityUIServer running | — |
| Haptics (`services`: `sensoryFeedback`, `UIImpactFeedbackGenerator`) | none | — | no-ops in the simulator; must not crash |
| Device info, battery, thermal, brightness (`services`) | none new | — | battery state unknown (0) and level −1; thermal nominal; brightness 0.5; model "iPhone", system "iOS 27.1", device name = simulator name |

### 3.3 Daemons that must be running (or demand-launchable)

backboardd (render server, display, HID, accessibility server),
SpringBoard (scene hosting, open-URL confirmation prompt, home screen,
snapshots), runningboardd, notifyd, logd, cfprefsd, lsd, fontservicesd,
intelligencecontextd, pasted, sharingd, configd_sim,
containermanagerd_system, mobileassetd, AccessibilityUIServer, and
TextInput's `kbd` on demand. In Apple's simulator all of these were
running (or started on first use) on the booted device. Ycode's **lean
boot** (`specs/simulator/lean-boot.md`) must not disable any of them for
SwiftUI parity runs; the parity benchmark uses the full boot anyway.

### 3.4 Darwin notifications

At launch the app registered ≈ 80 notification names (full list in the
`layout` log, `SUPX … notify-register`). Groups that matter for SwiftUI
behaviour:

- **Settings that change environment values live:**
  `ApplePreferredContentSizeCategoryChangedNotification` (Dynamic Type),
  `com.apple.accessibility.cache.*` (≈ 25 names: reduce motion, invert
  colours, button shapes, darken colours, differentiate without colour,
  VoiceOver, …), `AppleLanguagePreferencesChangedNotification`,
  `com.apple.language.changed`, the `Apple*PreferencesChangedNotification`
  family (date, time, number, measurement, temperature, keyboards),
  `com.apple.system.timezone`, `SignificantTimeChangeNotification`,
  `com.apple.system.lowpowermode`.
- **Keyboard:** `GSEventHardwareKeyboardAttached` (hardware keyboard
  state, see §4), `AppleKeyboards*`, `com.apple.keyboard.isOnScreen`
  (posted by the app when focusing a field).
- **Display and orientation:** `com.apple.CoreAnimation.CAWindowServer.DisplayChanged`,
  `…DisplayPower`, `com.apple.backboardd.orientation`,
  `com.apple.backboardd.rawOrientation`, `UIBacklightLevelChangedNotification`.
- **Simulator-only switches:** `com.apple.UIKit.SimulatorShake`,
  `com.apple.UIKit.SimulatorSlowMotionAnimationState` (Simulator.app's
  "Slow Animations" — affects every SwiftUI animation's duration).
- **System:** `com.apple.springboard.showingAlertItem`,
  `com.apple.LaunchServices.database`, `com.apple.runningboard.daemonstartup`,
  `com.apple.iohideventsystem.available`.

Ycode must deliver these through its notifyd exactly as the reference does
(names are posted by the daemons that own the settings; `simctl ui` on the
Mac changes the setting and causes the post).

### 3.5 Host features

| Feature | Needed for | Reference behaviour |
|---|---|---|
| Frame pacing at 60 Hz | animations, scrolling, display link | 56–60 callbacks/s measured |
| Touch injection (HID digitizer) | gestures, buttons, scrolling, back swipe | `hid-input.md`; taps, drags and two quick taps (double tap) all recognised |
| Hardware keyboard (HID keyboard) | text entry | **attached by default** in a headless boot: no software keyboard, keys arrive as text |
| `simctl ui appearance / content_size / increase_contrast` | colour scheme, Dynamic Type, contrast | live update < 1 s, no relaunch (`08` §1.1) |
| `simctl openurl` | `onOpenURL` | SpringBoard confirmation prompt first; URL delivered after "Open" |
| Time zone | `Date` formatting, `timeZone` environment | follows the Mac's time zone |
| Metal (host service) | alerts, dialogs, glass and material effects | Metal device created on first such presentation |
| Remote IOSurface (host service) | symbol rendering, presentations | used from the first coloured symbol |
| Screenshots (`simctl io screenshot`) | visual checks in the checklist | 1398 × 2034 px PNG (scale 3) |

## 4. Behaviour to reproduce, by area (summary)

Details and numbers are in files 03–08; the checklist turns them into
pass/fail items.

| Area | Observable behaviour in Apple's simulator | Depends on |
|---|---|---|
| App/scene lifecycle | launch order, phase transitions background ↔ inactive ↔ active, `onOpenURL` after prompt (`06` §1) | SpringBoard (FrontBoard), runningboardd, backboardd |
| Layout | ~140 golden cases identical across runs (`golden-layout.md`) | fontservicesd + the runtime's fonts (all text-dependent sizes) |
| Text | system font sizes per Dynamic Type category (`07` §1) | fontservicesd, CoreText, content-size preference + notification |
| Navigation | push/pop 0.5 s, lifecycle order, interactive back swipe (`06` §2) | CARenderServer (animation), HID (swipe) |
| Lists/scrolling | lazy materialisation counts, deceleration ≈ 0.998/ms (`06` §3) | HID, display link |
| Controls | toggle/button/stepper by touch (`06` §4) | HID |
| Keyboard/text input | focus, hardware-key text entry, submit (`06` §5) | TextInput kbd, pasted, HID keyboard, GraphicsServices keyboard state |
| Presentations | sheet detents and frames, alert/dialog/popover styles, dismissal order (`06` §6) | CARenderServer, Metal and IOSurface host services |
| Animations | 60 Hz sampling, curve and spring values (`05`) | display link |
| Gestures | tap, double tap, long press timing, drag translation/velocity/prediction (`06` §7) | HID timestamps (velocity is computed from event times) |
| Images/symbols | sizes, rendering modes, asset catalogs (`07` §3) | CoreUI/Symbols assets in the runtime, IOSurface.Remote |
| Data flow | re-evaluation counts, identity (`03`) | none (in-process) |
| Persistence | `@AppStorage` via cfprefsd; `@SceneStorage` discarded after `simctl terminate` (`06` §8) | cfprefsd, SpringBoard/FrontBoard scene archive, container layout |
| Dark mode / contrast | colour tables, live switch (`07` §4) | preference + notifications, trait propagation via FrontBoard |
| Accessibility | no tree until an AX client enables it; then labels/values/traits (`08` §2) | AccessibilityUIServer, axserver in backboardd, the accessibility preference |
| Localization | lookup, formats, RTL mirroring, language-dependent line height (`08` §3) | launch arguments / language preference, ICU data in the runtime |
| Haptics | silent no-ops | — |

## 5. Not covered in this round

- The software keyboard (requires detaching the hardware keyboard, which
  Simulator.app does through a preference we did not touch).
- Multi-window scenes (iPhone supports one), external displays, Stage
  Manager, iPad size classes (the 27.1 runtime refuses iPad types on this
  Mac; see `specs/simulator/ipad.md`).
- VoiceOver itself, Switch Control, Reduce Motion toggling.
- Scene-state restoration after a system-initiated termination.
- Previews (`08` §4).

## Evidence

| Claim | Level |
|---|---|
| Service names, timing, per-mode differences, notification names | 3 (our tracer inside our own app; logs `results/*.log`, lines `SUPX`) |
| Service → launchd job mapping | 2 (`MachServices` keys of the runtime's `LaunchDaemons` property lists, read as a file format) |
| Loaded framework names and count | 3/4 (dyld image list of our own process; bundle names only) |
| Daemons running, demand launch of `kbd` | 3 (`launchctl list` inside the device before/after each mode) |
| Host-feature behaviour | 3 (`simctl` and HID-driver runs) |
| Fatality of a missing display-services lookup | from `specs/simulator/app-install-launch.md` §5 (simulator track, level 3) |
