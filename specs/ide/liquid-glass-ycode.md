# Liquid Glass in Ycode: what each surface uses

**Status:** Ycode's own design record (clean room). It says which system
material, control and layout Ycode uses on each IDE surface to match
`liquid-glass.md` (the reference's per-surface glass), and why. Sources:
`liquid-glass.md`, Apple's Human Interface Guidelines (Materials, Liquid
Glass, Sidebars, Toolbars, Windows), the public AppKit API of the macOS
26/27 SDK, and the existing Ycode specs. The per-gap status is under
`liquid-glass.md` §0.

**Principle.** Ycode draws no glass of its own making. It uses the
system's materials through public API — toolbar items, `NSGlassEffectView`,
`NSButton.BezelStyle.glass`, popovers, sheets, `NSVisualEffectView` —
places them where the reference has them, and removes custom fills,
borders and lines that the reference does not have. Everything else
(dark appearance, inactive windows, full screen, Reduce Transparency,
Increase Contrast) is the system's.

## 0. The app must declare the current SDK

AppKit chooses the design from the SDK version recorded in the
executable (`LC_BUILD_VERSION`). SwiftPM records the deployment target
(15.0) as the SDK version of `YcodeApp`, so Ycode.app showed the earlier
design whatever its code did. `scripts/make-app.sh` records the SDK the app
was built with (`vtool -set-build-version macos <minimum> <SDK>`); the
deployment target stays 15.0. A bare `swift run YcodeApp` still shows the
earlier look. The test runner's host process is linked against the
current SDK, so tests run with the new design.

## 1. Workspace window

- `.fullSizeContentView`, `toolbarStyle = .unified`, title hidden,
  `titlebarSeparatorStyle = .none` (macOS 26+). The toolbar has no
  background; over each area it shows that area's background.
- The navigator (`sidebarWithViewController:`) and the inspector
  (`inspectorWithViewController:`) run the full window height, flush with
  the window's edges: on macOS 27.2 these split items draw no floating
  panel. Each area lays its first row out below the toolbar through its
  safe area. No line between navigator and editor; the inspector draws a
  1-point separator at its leading edge, full height.
- The center column holds the editor / debug area split below its
  safe-area top, so the split's heights (the debug area's 135 points, the
  remembered height, `reference-ui-5.md` §8.2) are measured as before.

## 2. Toolbar (`liquid-glass.md` §2.2)

| Item | Means | Drawn |
|---|---|---|
| Navigators \| Coding Assistant | `NSSegmentedControl` view item, segments 31.5 | capsule 78 × 38, selected segment a recessed pill |
| Run \| Stop, Back \| Forward | segmented controls, segments 30 | capsules 75 × 38 |
| Activity view | view item, `isBordered = false` | no shape |
| New Conversation | bordered image item | circle 38 × 38 |
| — | `.space` | splits New Conversation from the scheme |
| Scheme › Destination | stack view item, `isBordered = true`, 8-point side insets | capsule, width follows the titles |
| Issue capsule | view item, `isBordered = true`; hidden item when empty | capsule (63 for "⊗ 1 ⚠ 2") |
| Add Editor, Editor Options | two `NSMenuToolbarItem`s | one capsule, 81 × 38 |
| Editor modes | segmented control, segments 35 | capsule 125 × 38 |
| Show Inspector | bordered image item after the inspector tracking separator and a flexible space | circle at the far right |

- Order: Navigators | Coding Assistant, flexible space, Run | Stop,
  sidebar tracking separator, Back | Forward, activity, flexible space, New
  Conversation, space, scheme, issues, flexible space, Add Editor, Editor
  Options, editor modes, inspector tracking separator, flexible space,
  Show Inspector. The system gives the 38-point height, the 7-point top
  and bottom margins, the 6-point gaps and the flat inactive look.
- A view item is bordered by default (it gets a capsule); an
  `NSGlassEffectView` used as an item view merges with neighboring
  bordered items, so the toolbar uses none.
- Fitting (`reference-ui-6.md` §2.2, T1) is unchanged in kind. With the
  full-height inspector the editor's section is the window less both
  side areas: with long titles everything fits down to 1250 points;
  narrower, only Back | Forward, the activity view and New Conversation
  overflow, as §2.2 allows. A hidden issue item is not an overflow.
- Before macOS 26 the earlier segment widths and the issue capsule's own
  fill stay.

## 3. Floating bars (`liquid-glass.md` §2.3–§2.5)

`GlassBars` makes an `NSGlassEffectView` capsule (radius 15, 30 tall) that
sits behind the controls of a bar, as their sibling, above content that
may scroll beneath it; `SelectionPillView` is the recessed pill under the
selected tab (a quiet semantic fill set in `updateLayer`).

- Navigator selector bar: 278 × 30 at a 290-point width, 6 from each
  side, top one point above the toolbar's bottom; pill 30 × 24. The rule
  under the selector is transparent; the header rows keep their places.
- Navigator bottom bar: the "+" circle 31 × 30, 6 from the leading edge;
  the filter capsule 6 after it (or 6 from the edge without "+"), 6 from
  the trailing edge, 7 above the window's bottom. The filter field draws
  no bezel or background (its text keeps clear of the options menu).
- Outline: with no header row, its scroll view runs from the window's top
  to its bottom, under both bars, with content and scroller insets that
  keep the first row 7 below the selector bar (`reference-ui-6.md` §5.3)
  and the last row above the filter bar; there is no fade. With a header
  row shown (Find, Source Control, Tests, Reports) it stays clipped below
  the header (`liquid-glass.md` §2.7).
- Inspector tab bar: 30 tall, 5 from the divider, 6 from the right edge;
  pill 78 × 24. No line below.
- Coding Assistant header: capsules 150 × 30 and 118 × 30 around the
  146 × 27 "New Conversation" combo button and the 115 × 27 "New Group"
  button (borderless on the glass), 7 apart and 7 from the edges.
- Before macOS 26 none of these capsules is drawn and the earlier layout
  stays.

## 4. Editor chrome (`liquid-glass.md` §2.6, §3)

- Jump bar: unchanged, an opaque band with a separator line.
- Debug bar: 36 tall (35 plus its separator), laid over the editor, whose
  view runs to the column's bottom with a 36-point bottom safe-area inset
  (`additionalSafeAreaInsets`) so its text scrolls clear of the bar. The
  bar's background is `NSVisualEffectView` (`.headerView`, blending
  `.withinWindow`, state `.active`): the text beneath shows strongly
  blurred and faint, the separator above is the hard edge. Before macOS 26
  the bar sits below the editor, 27 tall.
- Debug area: no separator lines above its bottom bars (macOS 26+);
  fields stay standard (flat filled).

## 5. Welcome window (`liquid-glass.md` §2.10)

- Close button: `NSButton.BezelStyle.glass`, `borderShape = .circle`,
  frame 36 × 36 at (20, 20), drawn 38 × 38.
- Open…, Clone…, New Project: `.push` with `borderShape = .capsule` (flat
  filled capsules), 107 / 107 / 130 wide, 36 tall.
- Recent box: x 60–420, y 295–572 from the window's top left, a quiet
  `quaternarySystemFill` with 12-point continuous corners, no stroke (a
  separator-colored stroke with Increase Contrast).
- Rows 48 tall; the selection (`RecentRowView`) a rounded rectangle inset
  8 with 8-point corners in the system's selection colors.
- Before macOS 26: the earlier box (20 from the sides and bottom, stroked,
  radius 10), 44-point inset rows, flexible push buttons, drawn close
  circle.

## 6. Popovers, sheets, menus

- Popovers and menus are the system's. `PanelBackgroundView` paints the
  window background only in a titled window or offscreen, so a popover's
  material shows (macOS 26+). The prompt popover's content is clear.
- Sheets are the system's: centered on the parent, parent dimmed, rounded
  corners (checked with an alert sheet).

## 7. Settings, Open Quickly, coding assistant fields (not observed)

`liquid-glass.md` §5 did not observe these; Ycode keeps system materials:

- Settings: an `NSSplitViewController` with a 200-point sidebar item;
  round glass back / forward buttons; the window title is not drawn over
  the pane's title row.
- Open Quickly: a borderless floating panel on `NSGlassEffectView` (radius
  20) over the window's upper part, closing on Return, Escape or losing
  key; a sheet before macOS 26.
- Coding assistant message field: a rounded field (8-point continuous
  corners, text background, separator hairline, heavier with Increase
  Contrast); scrollers hide themselves.

## 8. Accessibility, appearance, state

Every material above is the system's, so Reduce Transparency, Increase
Contrast, the dark appearance, inactive windows (flat glass, same sizes)
and full screen follow the system. Ycode's own fills are semantic colors
resolved under the view's appearance (`updateLayer`, drawing).

## 9. Availability

Deployment target macOS 15 (`Package.swift`, unchanged). Every macOS 26
API (`NSGlassEffectView`, `.glass` bezel, `borderShape`) is behind
`#available(macOS 26, *)` (`GlassBars.enabled`) with the earlier look as
the fallback. `.fullSizeContentView`, safe-area layout,
`additionalSafeAreaInsets` and `NSToolbarItem.isHidden` work on macOS 15.

## 10. Open

- The Welcome rows draw no separators (the reference's start under the
  text).
- The jump bar's height is the earlier specs' (the reference's band is
  31 points, y 52–83).
- The inspector is 265 wide (`workspace-window.md`), 5 more than the
  reference's 260, so its tab bar is 253 wide.
- Organizer window: hand-built sidebar, not reviewed here. The Devices
  window is now Device Hub (`device-hub.md` "Ycode implementation"): a
  split view controller with system sidebar and inspector items, a
  unified toolbar of glass items, `NSGlassEffectView` capsules for the
  device controls and banners.
- The dark appearance, hover and pressed states, menus, full screen and
  the scrolled navigator in an active window are unobserved in the
  reference (`liquid-glass.md` §5); Ycode keeps the system's behavior.

## Evidence

- Target geometry and materials: `liquid-glass.md` (level 3 there).
- Ycode measurements: captures of Ycode's own windows (inactive) measured
  per pixel; probe windows of our own with toolbar items, glass views and
  glass buttons to see what each public API draws.
- API names and behavior: the public AppKit API reference and SDK
  declarations; Apple's HIG and "Adopting Liquid Glass" (level 1).
- Nothing here comes from observing the reference directly.
