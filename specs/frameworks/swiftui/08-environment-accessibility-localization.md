# SwiftUI 8: environment values, accessibility, localization, previews

Status: draft, round 0 (KIT-SWIFTUI, 2026-10-19). Level 3 unless noted:
our probe (modes `env`, `a11y`, `a11y-ax`, `l10n-en/fr/ar`, `layout-ar`)
on the iOS 27.1 simulator; logs in `research/experiments/swiftui/results/`.

## 1. Environment values at the scene root

Defaults our app read at launch (iPhone Duo, en_US, light):

| Value | Default |
|---|---|
| `colorScheme` / `colorSchemeContrast` | `.light` / `.standard` |
| `dynamicTypeSize` | `.large` |
| `legibilityWeight` | `.regular` |
| `layoutDirection` | `.leftToRight` |
| `locale` / `calendar` / `timeZone` | `en_US` / gregorian / the host's zone (America/New_York) — the simulator follows the Mac's time zone |
| `displayScale` / `pixelLength` | 3.0 / 1/3 |
| `horizontalSizeClass` / `verticalSizeClass` | `.compact` / `.regular` |
| accessibility flags (`accessibilityReduceMotion`, `…ReduceTransparency`, `…DifferentiateWithoutColor`, `…InvertColors`, `…ShowButtonShapes`, `…VoiceOverEnabled`, `…SwitchControlEnabled`, `accessibilityEnabled`) | all `false` |
| `isEnabled` | `true` |
| `lineLimit` / `multilineTextAlignment` / `truncationMode` | `nil` / `.leading` / `.tail` |
| `defaultMinListRowHeight` / `defaultMinListHeaderHeight` | 52 / `nil` |
| `controlSize` / `imageScale` | `.regular` / `.medium` |
| `redactionReasons` | empty |
| `isLuminanceReduced` / `supportsMultipleWindows` / `isSceneCaptured` | `false` / `false` / `false` |
| `font` | `nil` (text uses `.body`) |

### 1.1 Live changes (driven with `simctl ui`)

| Setting change | What the app saw | Latency after the `simctl` command |
|---|---|---|
| `appearance dark` | `colorScheme` → `.dark`; every view reading it re-rendered; trait `userInterfaceStyle` 2; adaptive colours re-resolved (`07` §4); asset colour switched red → blue | < 1 s |
| `content_size accessibility-large` | `dynamicTypeSize` → `.accessibility2`; body text re-laid out 20.67 × 20.33 → 39.67 × 39.67; `defaultMinListRowHeight` 52 → 59 | < 1 s |
| `increase_contrast enabled` | `colorSchemeContrast` → `.increased`; trait `accessibilityContrast` 1; `Color.blue` → #5CB8FF (dark) | < 1 s; the app posted `com.apple.accessibility.status` itself |
| revert (light, large, disabled) | three separate updates, one per setting | < 1 s |

No relaunch is needed; the values arrive through the scene's trait
collection (UIKit) and Darwin notifications the app registered for at
launch (`ApplePreferredContentSizeCategoryChangedNotification`,
`com.apple.accessibility.cache.*`, …, `01` §3.4).

## 2. Accessibility

- With no assistive technology active, the app's accessibility tree is
  **not built**: walking the window's accessibility elements returned 0
  elements (`a11y`).
- With the simulator's application-accessibility preference enabled
  (`defaults write com.apple.Accessibility ApplicationAccessibilityEnabled
  -bool true` inside the device, as an accessibility client would), the
  same screen exposed 11 elements (`a11y-ax`):

| View | label | value | hint | traits (UIKit bits) |
|---|---|---|---|---|
| `Text("Heading").accessibilityAddTraits(.isHeader)` (title font) | Heading | | | header + static text |
| `Button("Save").accessibilityHint(…)` | Save | | Saves the document | button |
| `Image(systemName: "star.fill")` | **Favorite** (the symbol's built-in accessibility label) | | | image |
| `Image(systemName: "trash").accessibilityLabel("Delete")` | Delete | | | image |
| `Image(decorative:)` | — (not exposed) | | | |
| `Toggle("Wi-Fi", isOn:)` | Wi-Fi | 1 | | button + a toggle bit |
| `Slider` | (none) | 30% | | adjustable |
| `Stepper` | — (not found by our traversal; open) | | | |
| `HStack {…}.accessibilityElement(children: .combine)` | "Combined, children" (labels joined with ", ") | | | static text |
| `.accessibilityHidden(true)` | — (not exposed) | | | |
| `.accessibilityIdentifier("probe.id")` | Identified | | | static text (identifier not readable through our traversal) |
| `Link` | Link | | | link |
| `TextField` with text "typed" | (none) | typed | | text-entry bit |
| `ProgressView(value: 0.4)` | (none) | 40% | | updates frequently |

  Frames are in screen coordinates (e.g. the header 139.83, 86.83,
  102.33 × 33.67).
- Enabling the tree made the app look up
  `com.apple.iphone.axserver-systemwide` (a backboardd service) and
  register for further accessibility notifications.
- `AccessibilityNotification.Announcement(…).post()` returned without
  error; no observable effect without VoiceOver.
- Reduce Motion, Bold Text, Button Shapes and similar flags were off and
  were not toggled in this round (their `simctl`-free switches are
  accessibility preferences inside the device; see `10-plan.md`).

## 3. Localization and right-to-left layout

Our app bundle contains `en`, `fr` and `ar` `Localizable.strings`; launch
arguments `-AppleLanguages (xx) -AppleLocale xx_YY` select the language:

| | en | fr | ar |
|---|---|---|---|
| `Text("greeting")` (key lookup in `Localizable.strings`) | "Hello world", 85.33 wide | "Bonjour tout le monde", 168.33 | Arabic string, 85.67 |
| `Text(verbatim: "greeting")` | not localized (63.33) | same | same |
| `Text("items \(3)")` (key `items %lld`) | "3 items" | "3 éléments" | "٣ عناصر" (Arabic-Indic digits) |
| `locale`, `layoutDirection` | en_US, LTR | fr_FR, LTR | ar_SA, **RTL** |
| date (year, month, day) | Sep 8, 2001 | 8 sept. 2001 | Islamic (Umm al-Qura) calendar date, Arabic-Indic digits |
| number 1234567.891 | 1,234,567.891 | 1 234 567,891 (narrow no-break space) | ١٬٢٣٤٬٥٦٧٫٨٩١ |
| text line height (body) | 20.33 | 20.33 | **22.33** (also for Latin text: the line height depends on the UI language) |

Right-to-left layout (`layout-ar` vs `layout`; frames are always
reported in left-to-right absolute coordinates):

- Stacks reverse: `HStack { a; b }` → b at x = 0, a at x = 18; a
  `Spacer` between texts mirrors the whole arrangement.
- `leading`/`trailing` alignment flips: `frame(…, alignment: .topLeading)`
  puts the text at the right (x = 61 in a 100-wide frame); `.bottomTrailing`
  goes left.
- Custom alignment guides are mirrored (`alignmentGuide` case).
- `offset(x: 20)` moves the view **left** (x = −20): horizontal offsets are
  in the layout direction.
- `padding(.horizontal)` is symmetric (unchanged).
- `LazyVGrid` columns fill right to left.
- Safe-area insets are expressed in leading/trailing terms: the device's
  84 pt right-side inset became the **leading** inset.
- `Image(systemName: "arrow.forward")` is laid out at the reading start;
  whether its artwork is mirrored was not checked (screenshot only).

## 4. Previews

- The view form of the `#Preview` macro and the `PreviewProvider`
  protocol are declared in the `SwiftUI` module; the shared preview
  vocabulary (preview registry and trait types) lives in
  `DeveloperToolsSupport` (SDK, level 4). Xcode renders previews in
  a separate simulator-hosted agent. Ycode's own preview design for the IDE
  is `specs/ide/previews.md`; it compiles preview bodies into a host app
  and does not need anything from this spec beyond a working SwiftUI.
- For the simulator track: a preview host is an ordinary SwiftUI app as far
  as the simulator is concerned (same services as `01`); nothing
  preview-specific was probed in this round.
- For the open implementation: `#Preview` must expand to something the
  Ycode preview host can discover lexically (`specs/ide/previews.md`); the
  macro can be implemented with swift-syntax (Apache-2.0).

## Evidence

| Claim | Level |
|---|---|
| Environment defaults and live changes, accessibility tree contents, localization results, RTL frames | 3 (`SUIProbe` modes `env`, `a11y`, `a11y-ax`, `l10n-*`, `layout-ar`) |
| `simctl ui` options | 3 (`simctl ui` help output and use) |
| Accessibility API and semantics (`accessibilityElement(children:)`, traits, identifiers), localization lookup rules, `#Preview` | 1 (developer.apple.com pages for these APIs) |
| Modules declaring `#Preview`, `PreviewProvider` and the preview types | 4 (SDK module interfaces, names only) |
| `axserver-systemwide` owner | 2 (the runtime's launchd job plist read as a file format) |
