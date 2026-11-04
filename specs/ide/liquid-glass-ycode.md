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
  the filter capsule 5 after it, 242 wide (or 6 from the edge without
  "+"; `metrics.md` §2), 6 from
  the trailing edge, 7 above the window's bottom. The filter field draws
  no bezel or background (its text keeps clear of the options menu).
- Outline: with no header row, its scroll view runs from the window's top
  to its bottom, under both bars, with content and scroller insets that
  keep the first row 7 below the selector bar (`reference-ui-6.md` §5.3)
  and the last row above the filter bar; there is no fade. With a header
  row shown (Find, Source Control, Tests, Reports) it stays clipped below
  the header (`liquid-glass.md` §2.7), its first row 4 below the clip.
  Both insets are measured against where the outline draws its first row:
  the source-list style pads that row in a plain window but not in the
  window's sidebar, and assuming the padding put the first row under the
  selector capsule (`metrics.md` §2).
- Inspector tab bar: 30 tall, 5 from the divider, 6 from the right edge;
  pill 78 × 24. No line below.
- Coding Assistant header: capsules 150 × 30 and 118 × 30 around the
  146 × 27 "New Conversation" combo button and the 115 × 27 "New Group"
  button (borderless on the glass), 7 apart and 7 from the edges.
- Before macOS 26 none of these capsules is drawn and the earlier layout
  stays.

## 4. Editor chrome (`liquid-glass.md` §2.6, §3)

- Jump bar: a 32-point band (y 52–83) in the editor's background, nearly
  opaque (96.5 %), then a 2-point separator (§12.8). The editor's text
  scrolls beneath it.
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

Spacing, insets and the measured metrics of every window are in
`metrics.md` (the spacing audit of 2026-10-30), with its own open
questions.

- The Welcome rows draw no separators (the reference's start under the
  text).
- ~~The jump bar's height is the earlier specs'.~~ The band is now 31
  points, y 52–83, then the separator (`metrics.md` §4).
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

## 11. Headset setup and the hub's Headset controls (XR-HUB, 2026-11-02)

A Ycode feature with no counterpart in `liquid-glass.md`, so these are Ycode's
choices, all system materials through public API:

- **Setup window** (`HeadsetSetupWindowController`): a full-size content
  view with a transparent title bar. The steps are on a floating
  `NSGlassEffectView` panel (`GlassBars.panel`, radius 18, 8 from the
  window's edges, the window's buttons on it), not a flush split item: this is
  a helper window, and §1's flush rule is the workspace's. The selected step
  sits on `SelectionPillView`; marks are system colours, a different shape per
  state; titles are the label colour.
- **What the panel floats over** (`HeadsetBackdropView`): the window's
  background with the running device's picture fading in from the leading
  edge, or a quiet accent wash without one (glass over one flat colour reads as
  a plain rectangle), gone before the text starts. Plain with Reduce
  Transparency or Increase Contrast. The scroll view runs under the panel.
- **Buttons** (`GlassBars.style`): the `.glass` bezel, capsule; the primary
  (Next / Finish, Install on Headset…, Connect, View in Headset) has
  `tintProminence = .primary`. Push buttons before macOS 26.
- **Body text** stays plain on the window's background: no glass behind the
  checks, and no glass on glass.
- **Headset box** (the Settings tab): the status on a `SelectionPillView`
  (a quiet semantic fill), glass buttons, the Display pop-up with the `.glass`
  bezel.
- **In Headset capsule**: `GlassCapsule` over the dimmed picture; its button is
  borderless with the accent colour, since it is already on glass (§3).
- Before macOS 26: `NSVisualEffectView` (`.sidebar`) with the same corners.

Seen in Ycode's own inactive windows over a real device picture
(`device-hub.md` §I.12.8); the active look and the tint are not yet seen.

## 12. Council round 1 measurements (2026-11-04)

The council compared this design with the reference in one scripted
session. Targets are in `liquid-glass.md` §7, `editor-area.md` §C,
`metrics.md` §12 and `navigators.md` "Council round 1"; the work list is
`fidelity-council.md`. This section records what the session showed of
**Ycode's** surfaces and what each needs.

1. **The session's Ycode declared SDK 15.0.** The capture wrapper bundles
   the bare `swift build` executable, not `make-app.sh`'s product, so §0
   did not apply. The toolbar, bars and jump bar drew the pre-macOS-26
   fallback:
   - no capsules: bare glyphs, with a grey square under each selected
     toggle (y 12–39);
   - an opaque #E6E6E7 toolbar band;
   - a #ECECEC jump bar.

   Stamp the SDK in the wrapper (`vtool -set-build-version macos 15.0
   <SDK>`, as `make-app.sh` does). Then recapture before judging §2–§4
   again.
2. **Toolbar (§2).** Even with the SDK fixed, two things differ from the
   reference:
   - Remove the up-down chevrons after the scheme and destination titles.
     The reference's capsule has a "›" between them and no chevrons.
   - Drop the document glyph before the title. The reference's activity
     view shows the project's icon (a spinner while loading), the bold
     title, and a subtitle line while a task runs. Both lines dim to
     #BCBDBD when the window is inactive; Ycode's title stayed #454546.
3. **Toolbar band and jump bar colour (§1, §4).** Over the editor the
   reference shows the **editor's background** (white in light), not a
   bar colour. The jump bar is the same white band, 32 tall, over a
   **2-point** separator (#E5E5E5). Ycode's band was #E6E6E7 and its jump
   bar #ECECEC over a 1-point separator. With the SDK fixed, check that
   the toolbar band shows the area beneath it, and draw the jump bar with
   the editor's background colour, not a grey fill.
4. **Scroll-under (§4).** The reference's toolbar band, jump bar, sticky
   header and bottom bar each let about 6 % of the text beneath show as a
   shapeless veil (`liquid-glass.md` §7.3). Ycode's toolbar and jump bar
   showed nothing (0–1 levels of change). Run the editor's scroll view
   under the jump bar and the toolbar, as the outline already runs under
   the navigator's bars. Its top content inset keeps the first line at
   y 93 at rest. The bars' backgrounds must be nearly opaque, with no fade
   below them. The navigator's rows must show **through the filter
   capsule** (moderately blurred) and only faintly through the selector
   capsule. Ycode's rows stopped at y 88 and at its bottom bar.
5. **Side-area backgrounds.** The reference's navigator and inspector
   were both #F2F2F3 (inactive). Ycode's were #E6E6E7 and #EBECEC: two
   different colours, both darker. Use the same system sidebar or
   inspector background for both areas, and check the inactive values
   against #F2F2F3.
6. **Selected tab glyphs (§3).** The reference's selected icon in the
   selector bar and in the inspector tab bar sits on a grey pill (#CACACB)
   and is drawn grey (#7C7D7E), **not accent blue**. Ycode tinted it blue
   (#0070F5, #007AFF).
7. **Scroll bars.** Follow the system's preferred scroller style
   (`metrics.md` §12.2). Ycode showed overlay knobs while the system's
   style on that Mac was the layout-taking one. In the editor, put the
   scroll bar's lane at the editor's right edge, **after** the minimap.

8. **What Ycode does since B2-GLASS (beta 2).** Each source editor's
   scroll view spans the editor, with content insets for its safe area,
   the jump bar and the find bar, so the text scrolls under the jump bar
   and the sticky header. The editor column still starts below the
   toolbar: running the center split under it was tried, but the system
   band over the editor stayed opaque in an inactive window and the split
   no longer kept the debug area at the height asked for. Those bars and the band behind the toolbar are the
   editor's background at 96.5 % (`EditorMetrics.barVeil`): a black glyph
   pixel beneath changes the bar by about 8 levels, and nothing fades
   below a bar. AppKit offers a hard scroll edge only through a split
   item's top accessory (`NSSplitViewItemAccessoryViewController`), which
   has one bar per split item, while Ycode has a jump bar per editor pane,
   so the bars are drawn fills. The minimap sits between the
   text and the scroll bar's lane; scroll views follow
   `NSScroller.preferredScrollerStyle`.

## 13. Council round 2 measurements (2026-11-04)

What the round 2 captures (foreground, key window) showed of **Ycode's**
surfaces since §12. The targets are `liquid-glass.md` §8.

1. **Fixed since round 1.** The captured build now draws the macOS 26+
   design:
   - the toolbar glass shapes match the reference's profile on the white
     band (rim, gradient, shadow) to within 1–3 levels;
   - the side areas are #EDEDEE in both;
   - the jump bar is white over a 2-point #E5E5E5 separator;
   - the divider is #D4D4D6.
2. **Toolbar band and jump bar still do not show content.** Over red
   bands, the reference's toolbar band reaches #FDE5E3 and its jump bar
   #FFF2F0, a blurred glow of the band beneath. Ycode's stay #FFFFFF and
   at most 2 levels off. §12.8 explains why: the editor column starts below
   the toolbar, and the 96.5 % fill passes too little. The reference's
   active bars pass about 8.5 % (jump bar) to 18 % (toolbar band) of the
   content's darkness, **blurred** with an edge spread of about 15
   points. Ycode's bottom bar already matches (12 %).
3. **Accent fills on toggles.** Remove the accent fill from the Navigators
   toggle and the selected editor mode; the reference shows only the grey
   recessed pill. Dim unavailable buttons: the reference's Stop is #A2A2A4,
   and Back and Forward are #AEAEAE.
4. **Navigator clipping.** Rows draw over the toolbar band and the window
   buttons. Clip the outline at the selector capsule's top edge, and let it
   run only under the two capsules.
5. **Narrow windows.** Add the "»" overflow. At 1100 points the reference
   moves the editor-mode group and the Notices circle into it, and drops
   the scheme capsule's titles (glyphs only) before truncating anything
   (`liquid-glass.md` §8.2).

## Evidence

- Target geometry and materials: `liquid-glass.md` (level 3 there).
- Ycode measurements: captures of Ycode's own windows (inactive) measured
  per pixel; probe windows of our own with toolbar items, glass views and
  glass buttons to see what each public API draws.
- API names and behavior: the public AppKit API reference and SDK
  declarations; Apple's HIG and "Adopting Liquid Glass" (level 1).
- §12: what the council session's captures showed of Ycode's own windows
  (pixel runs and `otool -l` of the captured executable); the reference
  targets it cites are level 3 in `liquid-glass.md` §7.
- §13: the round 2 captures of Ycode's own windows; the targets it cites
  are level 3 in `liquid-glass.md` §8.
- Apart from those cited targets, nothing here comes from observing the
  reference directly.
