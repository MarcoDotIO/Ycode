# SwiftUI 6: app and scenes, navigation, lists, controls, text input, presentation, gestures, persistence

Status: draft, round 0 (KIT-SWIFTUI, 2026-10-19). Observed behaviour of
our probe (level 3) on the iOS 27.1 simulator (iPhone Duo, 466 × 678 pt,
window safe area: bottom 34, trailing 84). Times are seconds since
`App.init` (`t=`), measured on a heavily loaded host (load average
300–560): ordering is reliable, absolute durations are upper bounds within
about one frame. Logs: `research/experiments/swiftui/results/<mode>.log`.
Input was injected with the simulator track's HID driver (taps, drags,
hardware-keyboard keys); its process start-up adds 1–3 s between a driver
step and the effect, which does not affect the observations below.

## 1. App, scenes and scene phases

Launch sequence (mode `lifecycle`, two runs, same order):

| t | Event |
|---|---|
| (exec + 0.29–0.79 s) | `App.init` (our `init` logged the time since the kernel started the process) |
| 0.04 | `UIApplicationDelegate.application(_:didFinishLaunchingWithOptions:)` (adaptor delegate), `applicationState` = background |
| 0.08–0.11 | `App.body` evaluated; `scenePhase` (App level) initial value `.background` |
| 0.14 | `UIScene.willConnect`, `App.body` again, App `scenePhase` → `.inactive`, scene/app `willEnterForeground` |
| 0.17–0.19 | root view `body`, view-level `scenePhase` `.inactive`, root `onAppear`, child `onAppear` and `task` start |
| 0.21 | App and view `scenePhase` → `.active`, `didActivate` / `didBecomeActive` |
| 0.22 | first display-link callback (≈ first frame); exec → first frame 0.68 s |

Transitions:

| Trigger | Sequence |
|---|---|
| another app launched (Settings) | `active → inactive` at once (`willDeactivate`, `willResignActive`), `inactive → background` when the switch finishes (5 s later on our loaded host; `didEnterBackground`) |
| our app launched again | `background → inactive → active` within 30 ms (`willEnterForeground`, `didActivate`, `didBecomeActive`) |
| `simctl openurl suiprobe://…` | SpringBoard shows an "Open in “SUIProbe”?" confirmation over the app → app `active → inactive`; after "Open": `onOpenURL` receives the URL, then `inactive → active` |
| `simctl terminate` | no further callbacks (`willTerminate` is not delivered) |

- `scenePhase` read in `App` and in a view change together, App first, in
  the same run-loop turn as the UIKit notifications.
- `App.body` is re-evaluated on every phase change (it reads `scenePhase`).
- Window facts: one `UIWindowScene` (role application), one key window
  466 × 678 at level 0, root view controller a `UIHostingController`
  subclass; traits: horizontal size class compact, vertical regular,
  idiom phone, display scale 3, wide gamut (P3), content size L.

## 2. Navigation (`NavigationStack`, `NavigationSplitView`, `TabView`)

### 2.1 `NavigationStack(path:)` (mode `nav`)

| Step | Observed |
|---|---|
| root shown | root list `onAppear`; content frame (0, 82, 382, 562): the navigation bar adds **82** to the top inset (both inline and large titles) |
| `path = [1]` | destination for 1 is created (`init`, `body`) and gets `onAppear` **immediately**; the push animates ≈ 0.5 s; during it the root slides to x = −140 (30 % of the window width); the root's `onDisappear` (and `task` cancellation) fires **at the end** of the push |
| `path = [1, 2]`, `[1, 2, 3]` | same pattern for each push |
| `path = [1, 2]` (pop one) | page 2 `onAppear` at the start of the pop, page 3 slides out to x = 466, its `onDisappear` at the end (0.5 s) |
| `path = []` (pop to root) | root `onAppear` at start, top page `onDisappear` at end; intermediate pages had already disappeared |
| `path = [4, 5]` from root (push two) | both destinations created; 5 (top) appears; 4 also gets `onAppear` (with a zero frame) although never shown; root disappears at the end |
| `path = []` again | 4 `onDisappear` at once, 5 at the end of the animation |
| tap on a `NavigationLink(value:)` row | pushes its destination (same lifecycle); `path` binding updated to `[10]` |
| edge swipe from the left edge | interactive pop: the top page follows the finger (x = 44.67, 59.33, … per frame), the page below moves at 30 % (x = −140 + 0.3·dx) |

List rows inside the stack: content x = 40 (inset-grouped style: 20
section inset + 20 cell inset), row pitch 52, first row text at y = 97.83.

### 2.2 `NavigationSplitView` on a compact-width iPhone (mode `split`)

It collapses to a stack: the sidebar is shown first (column visibility
reported `detailOnly` automatic → `automatic`); setting `selection = 1`
pushes the detail (sidebar slides to −140, detail `onAppear` at once,
sidebar `onDisappear` at the end); `selection = nil` pops back; `selection
= 2` pushes again. UIKit stored split-view column preferences in the app's
`UserDefaults` (key `com.apple.UIKit.UISplitViewController.Root`, seen in
the preferences plist; interop detail for `08` §4).

### 2.3 `TabView(selection:)` with `Tab` (mode `tabs`)

Only the selected tab is built at launch (tab 0 `onAppear`); switching
selection creates the next tab: new tab `onAppear` **before** the old
tab's `onDisappear` (2 ms, same update), no animation; returning to a tab
re-runs its `onAppear`. Tab content is laid out under the floating tab bar:
frame (0, 0, 382, 644) with bottom safe-area inset 34 (the tab bar does
not add to the inset in the 27.1 design).

## 3. Lists, lazy stacks and scrolling (modes `list0`, `list1`, `list2`)

| Container | Materialisation |
|---|---|
| `List` of 1 000 rows | 13 rows `onAppear` at launch (rows 0–12; row pitch 52 → 644 pt visible) |
| `ScrollViewReader.scrollTo(500, anchor: .top)` | rows 500–513 appear, the 13 earlier rows disappear (onAppear total 27, onDisappear 13); content offset jumps to 26 013.33 (500 × 52 + list top inset) without animation |
| `LazyVStack` in `ScrollView`, 1 000 rows of 40 + 8 spacing | 15 rows appear (0–14); the scroll geometry reports content size 382 × 47 992 at once (= 1 000 × 48 − 8, i.e. exact, not estimated, for equal rows); container 382 × 644; bottom content inset 34 after the first layout |
| `VStack` in `ScrollView`, 300 rows | **all 300 rows `onAppear` at once** (a non-lazy stack creates everything) |

Fling (drag of 305 pt in 160 ms, released): the offset followed the
finger exactly (30.67 pt per frame), then decelerated with a per-frame
ratio of ≈ 0.967 (≈ 0.998 per millisecond, the UIKit "normal" deceleration
rate), from ≈ 1 300 pt/s; the lazy stack came to rest at 1 046 after
≈ 2.5 s (lazy rows 21–35 visible); the `List` moved from rows 500–513 to
520–534. `onScrollGeometryChange` fired once per frame while scrolling.

`defaultMinListRowHeight` environment value: 52 at the default content
size, 59 at accessibility-large (AX2).

## 4. Controls (mode `controls`)

| Control | Observed |
|---|---|
| `Toggle` in a `Form` row | tap on the switch flips the bound value (`onChange` fired); programmatic changes animate the switch |
| `Button` | action runs on touch-up inside |
| `Slider` | a **tap on the track does not change the value** (only dragging the thumb does) |
| `Stepper` | tap on "+" increments by 1 |
| `Picker` in a `Form` | default style shows the selection with a menu (screenshot) |
| `DatePicker` (date, compact) | compact button; row height 34.33 |
| Row geometry in `Form` | rows at x = 40, width 322; section header spacing gives first row y = 56 |

Intrinsic sizes of every control are in `golden-layout.md` (e.g. bordered
button = label + 12/7 padding, toggle switch 61 × 28 when the label is
hidden, slider height 31, segmented picker 31, rounded text field 34).

## 5. Keyboard and text input (mode `keyboard`)

Apple's simulator, booted headless by `simctl`, has a **hardware keyboard
attached** (GraphicsServices' hardware-keyboard state; the app registered
for its notification at launch). Consequences we observed:

- Programmatic focus (`@FocusState`) works: `focus = 1` focused the field
  0.5 s later; `UIResponder.keyboardDidShowNotification` fired with an end
  frame **below the screen** (0, 678, 466, 289) — the software keyboard is
  not shown; `keyboardWillHide`/`DidHide` use (0, 678, 466, 0), duration
  0.3833 s, curve 7.
- The SwiftUI safe area did **not** change (no keyboard avoidance).
- Hardware key events (HID usage `h`, `i`) were inserted as text: the
  binding went `''` → `'H'` → `'Hi'` (auto-capitalisation applied).
- Return triggered `onSubmit` and removed focus (`focus → nil`).
- A tap on a text field focuses it.
- Active input modes: `en-US`, `emoji`.
- Services first used when text input started: the keyboard daemon
  (`com.apple.TextInput.kbd`, launched on demand), text-input preferences,
  pasteboard, remote text editing endpoints (`01` §3.2).

The software keyboard path (shown keyboard, safe-area avoidance, keyboard
height for this device) was **not** exercised; see `02` K-3 and the open
questions in `10-plan.md`.

## 6. Presentations (mode `modal`)

| Presentation | Observed |
|---|---|
| `.sheet` with detents `[.medium, .large]` | content frame (8, 280, 374, 356) at medium — a floating sheet inset 8 pt from the window edges — and (8, 8, 374, 636) at large; UIKit presentation style form sheet (2); `onAppear` when the presentation starts |
| setting the detent binding | the sheet resizes (animated) |
| `isPresented = false` | sheet slides out (to y = 678); **`onDismiss` then `onDisappear` at the end** (0.53 s later) |
| `.alert` | presented by UIKit as an alert controller (style custom, 4) |
| `.confirmationDialog` | presented as an action sheet in a popover-style presentation (7) |
| `.popover` on iPhone | presented as a popover (style 7) sized to its content (95 × 52.33), not adapted to a sheet in this configuration; `.presentationCompactAdaptation(.popover)` likewise |
| `.fullScreenCover` | style over-full-screen (5), content frame (0, 0, 382, 644) with the window's safe area; `onDismiss` then `onDisappear` at the end of the dismissal |

Alerts, dialogs and glass materials made the app create its Metal device
(`com.apple.metal.simulator`, the host's Metal service) and use remote
IOSurfaces (`01` §3).

## 7. Gestures (mode `gesture`)

| Gesture | Observed |
|---|---|
| `onTapGesture` | fires on touch-up |
| `onTapGesture(count: 2)` + `onTapGesture` on one view | a double tap (two taps 120 ms apart) fired only the double-tap action |
| `onLongPressGesture(minimumDuration: 0.5)` | `pressing` true at touch-down, action 0.5 s later while still down, `pressing` false at touch-up |
| `DragGesture(minimumDistance: 10)` | first `onChanged` once the translation exceeds 10 (11.33); `startLocation` is the touch-down point; `velocity` in pt/s (≈ 580–690 for our 20-step drag); **`predictedEndTranslation` = translation + 0.25 s × velocity** (e.g. 233 + 0.25 × 437.63 = 342.41); `onEnded` with the final values |
| `onTapGesture` + `simultaneousGesture(DragGesture())` | a drag ended the drag gesture only; the tap did not fire |
| `Button` (bordered prominent) | action on touch-up |
| `NavigationStack` back swipe | system edge gesture, interactive (§2.1) |

Haptics (`sensoryFeedback`, `UIImpactFeedbackGenerator`) produced no
error and no service connection in the simulator (`01` §3).

## 8. Persistence (modes `persist1`–`persist3`)

| Wrapper | Observed |
|---|---|
| `@AppStorage("launchCount")` | stored in the app's standard `UserDefaults` (`Library/Preferences/<bundle id>.plist` in the data container, written by `cfprefsd`, flushed lazily — the file lagged one value behind right after a write, the next launch still read the latest value) |
| `@AppStorage` and external writes | `UserDefaults.standard.set(_:forKey:)` from elsewhere updated the `@AppStorage` property and fired `onChange` within 6 ms |
| `@SceneStorage` | written values were **not** restored after (a) backgrounding the app and `simctl terminate`, or (b) terminating it in the foreground: each launch read the default. After (a) a per-session state archive existed briefly (`Library/Saved Application State/<bundle id>.savedState/<session UUID>/data.data`), and was discarded on the next launch (only `KnownSceneSessions/data.data` remained). `simctl terminate` counts as a user-initiated quit, which discards scene state; restoration after a system-initiated termination was not tested. |
| Snapshots | SpringBoard saved launch/app-switcher snapshots in `Library/SplashBoard/Snapshots/…/*@3x.ktx` |

## Evidence

| Claim | Level |
|---|---|
| All tables and sequences in this file | 3 (`SUIProbe` modes `lifecycle`, `nav`, `split`, `tabs`, `list0–2`, `controls`, `keyboard`, `modal`, `gesture`, `persist1–3`; our own app on Apple's iOS 27.1 simulator) |
| Scene phases, navigation, presentation, `AppStorage`/`SceneStorage` semantics as documented API | 1 (developer.apple.com `ScenePhase`, `NavigationStack`, `NavigationSplitView`, `TabView`, `sheet`, `AppStorage`, `SceneStorage` pages; WWDC20 session 10037 "App essentials in SwiftUI") |
| UIKit presentation style numbers, notification names | 1/3 (public UIKit enums and notification names, values printed by our app) |
| Container file names | 2 (files our app's container holds, read as a file listing) |
