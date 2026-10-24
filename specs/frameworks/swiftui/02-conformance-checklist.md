# SwiftUI 2: conformance checklist for Ycode's simulator

Status: reference, round 0 (KIT-SWIFTUI, 2026-10-19). Each item: probe mode
(our app `SUIProbe`, `research/experiments/swiftui/SUIProbe/`), what the
driver does, and the result Apple's iOS 27.1 simulator produced (level 3;
reference logs in `research/experiments/swiftui/results/`). An item passes
on Ycode when the same mode prints the same lines (values within the
stated tolerance; order of `t=` lines as stated).

## How to run

1. Build once on the Mac: `build.sh <out>` (app, `svctrace.dylib`, HID
   driver). The app is an ordinary simulator app (arm64, iOS 27.0
   deployment target, ad-hoc signed).
2. Install on the device under test and run one mode:
   `run.sh <udid> <out> <logdir> <mode> [launch args]` (Apple's simulator).
   For Ycode, launch the same app with the same arguments through Ycode's
   launch path and the same environment (`DYLD_INSERT_LIBRARIES` =
   `svctrace.dylib` for the service items), and drive input through Ycode's
   display stream / HID path at the same ratios (`SUP target.<name>=x,y`
   lines give the touch points as screen ratios).
3. Compare `SUP` lines with the reference log (`diff` after stripping
   `t=`; timing items compare `t=` differences).

Device for the reference values: iPhone Duo, 466 × 678 pt, scale 3. On
another device type, items marked † change (safe areas, screen size).

Tolerances: **exact** = identical text; **±1f** = within one display
frame (17 ms) for durations measured on the same host; **order** = same
relative order of the named lines.

## A. Launch and lifecycle (mode `lifecycle`)

| # | Driver | Expected | Tol. |
|---|---|---|---|
| A-1 | launch | order: `app.init`, `delegate.didFinishLaunching=state=2`, `app.scenePhase=background->background`, `note.scene.willConnect`, `app.scenePhase=background->inactive`, `note.scene.willEnterForeground`, `note.app.willEnterForeground`, `root.onAppear`, `lc.text.onAppear`, `app.scenePhase=inactive->active`, `note.scene.didActivate`, `note.app.didBecomeActive`, `displaylink.first` | order |
| A-2 | launch | `lc.screen=466.00x678.00 scale=3.00 native=3.00 maxFPS=60`, one window `(0,0,466,678)`, safe `bottom 34, right 84`, `rootVC=UIHostingController`, traits `h=1 v=2 style=1 contentSize=UICTContentSizeCategoryL idiom=0 layoutDir=0 displayScale=3.0 gamut=1` † | exact |
| A-3 | launch | `displaylink.rate` between 55 and 60.5 | range |
| A-4 | launch | app.init → displaylink.first ≤ 0.5 s on an idle host (reference 0.22 s loaded) | perf |
| A-5 | launch Settings (`com.apple.Preferences`) | `active->inactive` (with `willDeactivate`, `willResignActive`), then `inactive->background` (`didEnterBackground`) | order |
| A-6 | launch the probe again | `background->inactive->active` with `willEnterForeground`, `didActivate`, `didBecomeActive` | order |
| A-7 | `openurl suiprobe://hello?x=1` | SpringBoard prompt "Open in “SUIProbe”?" (screenshot); app `active->inactive` | exact |
| A-8 | tap "Open" (0.633, 0.528) | `lc.onOpenURL=suiprobe://hello?x=1`, then `inactive->active` | order |
| A-9 | terminate | no `note.app.willTerminate` line | exact |
| A-10 | launch, wait 2 s | `images.lc.count` = 545 ± 10 and every `/System/Library/(Private)Frameworks/SwiftUI*`, `UIKitCore`, `AttributeGraph`, `RenderBox`, `CoreText`, `FontServices` line present | count |

## B. Services (any mode, with `svctrace.dylib`)

| # | Expected `SUPX` names (first lookup must succeed, kr=0) | Tol. |
|---|---|---|
| B-1 | lookups: `com.apple.system.notification_center`, `com.apple.logd`, `com.apple.backboard.display.services`, `com.apple.CARenderServer`, `com.apple.backboard.hid.services` | exact |
| B-2 | XPC: `com.apple.cfprefsd.daemon`, `com.apple.runningboard`, `com.apple.lsd.mapdb`, `com.apple.fontservicesd`, `com.apple.uiintelligencesupport.agent` | exact |
| B-3 | ≈ 80 `notify-register` names including `ApplePreferredContentSizeCategoryChangedNotification`, `GSEventHardwareKeyboardAttached`, `com.apple.accessibility.cache.reduce.motion`, `com.apple.UIKit.SimulatorSlowMotionAnimationState`, `com.apple.CoreAnimation.CAWindowServer.DisplayChanged` | set ⊇ reference minus PID-suffixed names |
| B-4 | mode `keyboard`: additionally `com.apple.TextInput.preferences`, `com.apple.pasteboard.pasted`, `com.apple.containermanagerd.system`; `com.apple.TextInput.kbd` running afterwards (`launchctl list`) | exact |
| B-5 | mode `modal`: `com.apple.metal.simulator` and `com.apple.IOSurface.Remote` after the alert/dialog steps; no crash | exact |
| B-6 | mode `a11y` with `ApplicationAccessibilityEnabled` set: `com.apple.iphone.axserver-systemwide` | exact |

## C. Layout and text (modes `layout`, `layout-ar` = `layout -AppleLanguages (ar) -AppleLocale ar_SA`)

| # | Expected | Tol. |
|---|---|---|
| C-1 | every `layout.*` line equals `results/layout.log` (1 387 `layout.*` lines; ~140 cases) | exact |
| C-2 | `layout.root.size=382.00x644.00`, `layout.root.safeArea=t0.00 l0.00 b34.00 r84.00` † | exact |
| C-3 | `font.ui.*` sizes rows (12 categories × 13 styles) and `font.families.count=87` | exact |
| C-4 | `layout-ar`: equals `results/layout-ar.log` (mirrored frames, 22.33 line height, safe area `l84 r0`) | exact |
| C-5 | two runs give identical `layout.*` output (determinism) | exact |

## D. Navigation (modes `nav`, `split`, `tabs`)

| # | Driver | Expected | Tol. |
|---|---|---|---|
| D-1 | (scripted path changes) | the `nav.*` lifecycle sequence of `results/nav.log` up to `nav.set=[] (pop all)`: new page `onAppear` at push start; covered page `onDisappear` ≈ 0.5 s later; pushing `[4,5]` gives `page4.onAppear` with a zero frame | order; push duration 0.5 s ±3f |
| D-2 | — | `nav.page*.frame=(0.00,82.00,382.00,562.00)` after each push; covered root at x = −140 during the push † | exact |
| D-3 | tap `target.nav.row0` | `nav.page10.init`, `nav.path=[]->[10]`, page 10 appears | order |
| D-4 | edge swipe from x = 0.005 to 0.8 | page frame x follows the finger, root at −140 + 0.3·dx | ±1 pt |
| D-5 | (`split`) | `split.hsc=compact`; selection 1 pushes `detail1` (sidebar `onDisappear` at end); selection nil pops back | order |
| D-6 | (`tabs`) | only tab 0 appears at launch; each selection change: new tab `onAppear` before old `onDisappear`; tab frame `(0,0,382,644)` safe `b34 r84` † | order / exact |

## E. Lists and scrolling (modes `list -stage 0|1|2`)

| # | Driver | Expected | Tol. |
|---|---|---|---|
| E-1 | — | stage 0: `list.initial=visible=13 min=0 max=12`; rows at `(40,50,…)`, `(40,100.33,…)`, `(40,150.67,…)` | exact |
| E-2 | — | `list.afterScrollTo500=visible=14 min=500 max=513 onAppearTotal=27 onDisappearTotal=13`; `scroll.list` offset 26013.33 | exact |
| E-3 | drag (0.4, 0.75) → (0.4, 0.3), 10 steps of 16 ms | offset follows the finger (≈ 30.67 pt per frame), then decays by ≈ 0.967 per frame; rows 520–534 visible at the end | ±2 rows |
| E-4 | — | stage 1: `lazy.initial=visible=15 min=0 max=14`, content `382.00x47992.00`, container `382.00x644.00` | exact |
| E-5 | same drag | lazy stack rests near offset 1 046 (rows 21–35) after ≈ 2.5 s | ±5 % |
| E-6 | — | stage 2: `eager.initial=visible=300 … onAppearTotal=300` | exact |

## F. Controls (mode `controls`)

| # | Driver | Expected | Tol. |
|---|---|---|---|
| F-1 | — | row frames: toggle `(40,56.17,322,20.33)`, slider `(40,107.33,322,31)`, stepper `(40,169.17,322,20.33)`, date `(40,272.5,322,34.33)` | exact |
| F-2 | — | programmatic `toggle on/off` → `ctl.toggle.value=true`, then `false` | order |
| F-3 | tap `target.ctl.toggle` | `ctl.toggle.value=true` | exact |
| F-4 | tap `target.ctl.button` | `ctl.button.action=` | exact |
| F-5 | tap `target.ctl.slider` (track at 80 %) | **no** `ctl.slider.value` line | exact |
| F-6 | tap `target.ctl.stepper` (plus) | `ctl.stepper.value=2` | exact |

## G. Keyboard and text (mode `keyboard`)

| # | Driver | Expected | Tol. |
|---|---|---|---|
| G-1 | — | `kb.activeInputModes=en-US,emoji` | exact |
| G-2 | (focus at 1 s) | `kb.focus=nil->Optional(1)`; `kb.didShow=end=(0.00,678.00,466.00,289.00) duration=0.0000 curve=7 local=true` (hardware keyboard attached: frame off-screen) | exact † |
| G-3 | keys `h`, `i` (HID usages 0x0b, 0x0c) | `kb.text=''->'H'`, `'H'->'Hi'` | exact |
| G-4 | key Return (0x28) | `kb.willHide…duration=0.3833 curve=7`, `kb.onSubmit=Hi`, `kb.focus=Optional(1)->nil` | order |
| G-5 | tap `target.kb.field` | focus moves to field 1 | exact |
| G-6 | — | no `kb.safeArea` change line at any time (no avoidance with the hardware keyboard) | exact |
| K-3 (open) | detach the hardware keyboard | software keyboard visible, `kb.safeArea` bottom grows by the keyboard height | to be measured |

## H. Presentations (mode `modal`)

| # | Expected | Tol. |
|---|---|---|
| H-1 | sheet: `modal.sheet.frame=(8.00,280.00,374.00,356.00)` at medium, `(8.00,8.00,374.00,636.00)` at large; `presented=…[2]` † | exact |
| H-2 | sheet off: frame to y=678, then `modal.sheet.onDismiss` before `modal.sheet.onDisappear`, ≈ 0.5 s after `isPresented=false` | order; ±3f |
| H-3 | alert: one presented controller with style `[4]`; dialog: style `[7]` | exact |
| H-4 | popover: content frame `95.00x52.33`, style `[7]` | exact |
| H-5 | full-screen cover: frame `(0.00,0.00,382.00,644.00)`, style `[5]`; `onDismiss` before `onDisappear` | exact / order |

## I. Animation (mode `anim`)

| # | Expected | Tol. |
|---|---|---|
| I-1 | all `curve.*`, `spring.*`, `keyframes.*` lines | exact |
| I-2 | `animation.*.description` parameter values (durations 0.35, responses/damping) | exact |
| I-3 | `anim.linear1 … frames=61`, `anim.linear1speed2 frames=31`, `anim.default frames≈77` | ±3 frames |
| I-4 | `v@…` samples of every `anim.<case>` line | ±0.03 |
| I-5 | `anim.implicitOnly.B frames=1` (jump), `explicitEaseIn0.5.A` 1 s linear, `txOverride.B` 0.3 s | ±3f |
| I-6 | completion times: logical ≈ nominal duration; `.removed` for spring ≈ 1.28 s | ±3f |
| I-7 | transition: `anim.transitioned.onAppear` right after insert; `onDisappear` ≈ 1.0 s after remove | ±3f |

## J. Gestures (mode `gesture`)

| # | Driver | Expected | Tol. |
|---|---|---|---|
| J-1 | tap `target.g.tap` | `g.tap.action=` | exact |
| J-2 | two taps 120 ms apart on `target.g.double` | `g.double.doubleAction=` only | exact |
| J-3 | press without movement for ≈ 0.8 s on `target.g.long` | `g.long.pressing=true`, `g.long.action` 0.5 s later, `g.long.pressing=false` at release | order; 0.5 s ±3f |
| J-4 | drag 0.25 → 0.75 of width, 20 steps | `g.drag.began` with translation just over 10; `predEnd = tr + 0.25 × vel` on every changed line; `g.drag.ended` | ±0.5 pt |
| J-5 | tap `target.g.button` | `g.button.action=` | exact |
| J-6 | drag on `target.g.simul` | `g.simul.dragEnded=…`, no `g.simul.tap` | exact |

## K. Data flow (mode `dataflow`)

| # | Expected | Tol. |
|---|---|---|
| K-1 | every `df.bodies.*` line of `results/dataflow.log` (body re-evaluation sets) | exact |
| K-2 | `df.order.onAppear` order: second, first, parentVStack; `df.pref=first,second` | exact |
| K-3 | identity cases: `ifFalse.onAppear` before `ifTrue.onDisappear`; `explicitID` new token; reorder without appear/disappear | order |

## L. Environment, colours, Dynamic Type (mode `env`)

| # | Driver | Expected | Tol. |
|---|---|---|---|
| L-1 | — | all `color.light.*`, `color.dark.*`, `color.ui.highContrast.*` lines | exact |
| L-2 | — | initial `env.values=…` line (defaults of `08` §1) | exact (time zone = host's) |
| L-3 | `simctl ui appearance dark` | `colorScheme=dark`, live colours `primary=#FFFFFFFF`, `asset.ProbeColor=#0000FFFF` | exact, < 1 s |
| L-4 | `content_size accessibility-large` | `dynamicType=accessibility2`, `minRowHeight=59.0`, body text frame 39.67 × 39.67 | exact |
| L-5 | `increase_contrast enabled` | `contrast=increased`, `blue=#5CB8FFFF` (dark) | exact |
| L-6 | revert | back to the initial values | exact |

## M. Images, accessibility, localization, persistence, services

| # | Mode / driver | Expected | Tol. |
|---|---|---|---|
| M-1 | `images` | all `img.symbol.*` sizes; `xcode` and `doesnotexist.symbol` nil; `img.asset.ProbeImage=size=30.00x20.00 scale=2.00`; missing symbol frame 0 × 0 | exact |
| M-2 | `a11y` (default device) | `ax.tree.count=0` | exact |
| M-3 | `a11y` after `defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true` | 11 `ax.tree.element` lines as in `results/a11y-ax.log` (labels, values, hints, trait bits, frames) | exact (class column ignored) |
| M-4 | `l10n -AppleLanguages (fr) -AppleLocale fr_FR` and `(ar) ar_SA` | `results/l10n-*.log` (strings, formats, RTL frames) | exact |
| M-5 | `persist`, three launches | `launches` 0 → 1 → 2 → 3 persisted; external `UserDefaults` write → `persist.appStorage.name` change within 10 ms; `scenePick=0` on every launch after `simctl terminate` | exact |
| M-6 | `services` | no crash; `svc.battery=0 -1.0`, `svc.thermal=0 lowPower=false`, `svc.brightness=0.50`, `svc.device=iPhone iOS 27.1 name=<device name>`, `svc.pasteboard.hasStrings=true` | exact |

## Evidence

| Claim | Level |
|---|---|
| Every expected result | 3 (reference runs of `SUIProbe` on Apple's iOS 27.1 simulator; logs in `research/experiments/swiftui/results/`) |
