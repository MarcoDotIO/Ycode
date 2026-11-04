# Spec: Liquid Glass in the workspace window and its panels

**Status:** boundary spec. It records how the reference release, Xcode
27.1, uses the system's Liquid Glass material, so that Ycode can match it
with public AppKit API. It comes from black-box observation (level 3) of
the reference on macOS 27.2 in the background (window captures and the
accessibility tree, plain clicks only) and from Apple's public
documentation and SDK interface declarations (level 1). Dirty-room notes:
`research/notes/obs-glass-2026-10-27.md`.

**Scope.** Material kind (glass, solid, translucent panel), shape,
geometry in points, scroll-edge behavior, and the differences between
light and dark appearance and between active and inactive windows. **No
colors and no assets** are recorded: Ycode takes every color from the
system (semantic colors, the system's materials) and draws its own glyphs.

**Relation to other specs.** Item order, titles and accessibility names of
the toolbar are in `reference-ui-6.md` §2; area sizes in
`workspace-window.md` and `reference-ui-5.md`. This spec adds the
material, shape and spacing of the same items. Where it gives a size that
differs from an earlier spec, the earlier spec's number is an
accessibility frame and this spec's number is the drawn shape; both hold.

**Words used here.**

- *Glass*: the system's Liquid Glass material: a translucent shape with a
  thin rim, a light highlight along its upper and lower inner edges, a
  slight gradient, a soft shadow below, and the content behind it showing
  through blurred. It takes on the tone of whatever is beneath it.
- *Capsule*: a shape with fully rounded ends (corner radius = half the
  height). *Circle*: a capsule as wide as it is tall.
- *Flat filled*: a control drawn as a plain rounded fill with no rim, no
  highlight and no shadow (the standard macOS 26+ field and push-button
  look).
- *Active / inactive*: the window is key in the active app, or not.

## 0. Prioritized gap list (Ycode at 7c7e47d)

| ID | Gap | Priority |
|---|---|---|
| G0 | The `YcodeApp` binary built by SwiftPM declares **SDK 15.0** in its build-version load command (minos 15.0, sdk 15.0), although it links against the macOS 27.0 SDK. AppKit keeps the pre-26 design for binaries that declare an SDK older than 26, so no part of this spec can take effect until the shipped binary declares SDK 26 or later. Ycode's Welcome window shows the old design (bezeled push buttons with a drop shadow, a rimless close button). Verify with `otool -l` / `vtool -show-build` on the built product. | P0 (blocker) |
| G1 | Opening any project in the debug build crashes at once: a main-actor isolation check fails in the document controller's recent-document-count property, which AppKit reads from a background queue when it notes a recent document. (Not a glass item, but it blocks checking every surface below.) | P0 (blocker) |
| G2 | Side areas must **not** float: the navigator and the inspector are full-height, edge-to-edge areas with no inset, no rounded corners and no gap to the window frame (§2.1). With SDK 26+ the split-view sidebar and inspector behaviors may draw floating, inset panels; Ycode must end up with the reference's flush layout. | P1 |
| G3 | Toolbar items as glass shapes: every item in its own glass circle or capsule, 38 points tall; grouped items share one capsule; the activity view has no shape; 6-point gaps; 7-point margins at area edges; the left groups track the navigator's edge and the inspector button tracks the inspector (§2.2). Ycode today builds the groups as segmented controls in custom-view items with no grouping API. | P1 |
| G4 | Navigator selector bar, inspector tab bar, Coding Assistant header and the navigator's bottom bar as **floating glass capsules** 30 points tall over content that scrolls beneath them (§2.3–§2.5). | P1 |
| G5 | Scroll-edge behavior: the outline scrolls under the navigator's glass bars to the window's edges; the editor's bottom bar is a hard-edge bar over blurred editor text; the jump bar is an opaque band (§3). | P2 |
| G6 | Inactive windows flatten all glass (§4.2). This comes from the system once G0 and G3/G4 use system glass; check it, do not draw it. | P2 |
| G7 | Popovers: system popover material with arrow, 17-point corners; remove any custom background in popover content (§2.8). | P2 |
| G8 | Sheets centered on the parent window, parent dimmed (§2.9). This is system behavior with SDK 26+; check it. | P2 |
| G9 | Welcome window: glass close circle 38 × 38; flat filled capsule buttons (not bezeled push buttons); recent box with ~12-point corners and no border line; selected row inset 8 with ~8-point corners (§2.10). Ycode draws its own box radius (10) and uses push/flexible-push bezels. | P2 |
| G10 | Debug area, inspector content and the editor: **no glass** — flat filled fields and pop-ups, plain section headers (§2.6, §2.7, §2.7a). Do not add glass there. | P3 |

**Status (IDE-GLASS, 2026-10-27, branch `ide-glass`).** Ycode's design
record is `liquid-glass-ycode.md`; each gap:

- *G0 closed.* `scripts/make-app.sh` stamps the SDK the app is built with
  into `LC_BUILD_VERSION` (`vtool -set-build-version macos 15.0 27.0`);
  the deployment target stays 15.0. A bare `swift run` still declares
  SDK 15.0.
- *G1 closed.* The document controller's recent-document count is
  `nonisolated`.
- *G2 closed.* Navigator and inspector are full height and flush: the
  system's sidebar and inspector split items under a full-size content
  view draw no floating panel on macOS 27.2 (checked in a minimal AppKit
  window too). No line between navigator and editor; the inspector draws
  a 1-point separator at its leading edge, full height. No titlebar
  separator. Ycode's inspector stays 265 wide (`workspace-window.md`), so
  its section is 5 points wider than the reference's.
- *G3 closed.* Measured on Ycode's window (inactive, 1400 × 900):
  Navigators | Coding Assistant 95–173 (78 × 38, top 7), Run | Stop
  208–283 (75), Back | Forward 297–372 (75), New Conversation a 38 × 38
  circle, the scheme capsule and the issue capsule separate, Add Editor |
  Editor Options one capsule (81, the system's width for two menu items),
  editor modes 125, Show Inspector 1355–1393; 6-point gaps; activity view
  without a shape. Navigator hidden: the three left capsules close up 6
  apart; inspector hidden: 10 points between the editor modes and the
  circle (the reference: 11). Means: `NSSegmentedControl` view items with
  segment widths 31.5 / 30 / 35 (the system adds the capsule padding and
  draws the recessed selected pill), `isBordered = true` on the scheme and
  issue view items (a view item is bordered by default; the activity
  view's item sets `isBordered = false`), a fixed `.space` between New
  Conversation and the scheme (adjacent bordered items otherwise share one
  shape), Run | Stop before the sidebar tracking separator after a
  flexible space, a flexible space before Show Inspector after the
  inspector tracking separator. `NSToolbarItemGroup` was not needed.
- *G4 closed.* `NSGlassEffectView` capsules (radius 15) behind the
  controls: selector bar 278 × 30 from y 51 with a recessed pill under
  the selected icon; "+" circle 31 × 30 and filter capsule 242 × 30, 7
  above the bottom (the filter field drops its bezel); inspector tab bar
  30 tall, 5 from the divider and 6 from the right edge, pill 78 × 24;
  Coding Assistant header capsules 150 × 30 and 118 × 30, 7 apart and 7
  from the edges. No line under the bars. The outline runs from the
  window's top to its bottom under the bars (content insets keep the first
  row 7 below the selector bar); with a header row shown (Find, Source
  Control, Tests, Reports) it stays clipped below the header (§2.7).
- *G5 closed.* The debug bar is 36 tall and lies over the editor, which
  runs to the column's bottom with a 36-point bottom safe-area inset; its
  background is the system's header material blending within the window
  (`NSVisualEffectView`, `.headerView`, `.withinWindow`, always active),
  so text beneath shows strongly blurred and faint, with the separator
  line above as the hard edge. The jump bar was already an opaque band
  with a separator; its height is still the earlier specs'.
- *G6 checked.* Every Ycode capture here was of an inactive window: the
  toolbar shapes, bars and the Welcome close circle draw flat with an
  outline, at unchanged sizes (system behavior, no Ycode code).
- *G7 closed.* Popovers use the system material; `PanelBackgroundView`
  leaves a popover's background alone (macOS 26+); the prompt popover's
  content draws no background.
- *G8 checked.* An `NSAlert` sheet on a workspace window is centered on it
  both ways, with rounded corners, and the whole parent dims (system).
- *G9 closed.* Close button: a glass circle drawn 19–57 (38 × 38) with a
  36 × 36 frame at (20, 20); Open…, Clone…, New Project: `.push` with a
  capsule border shape (flat filled capsules, 107 / 107 / 130 × 36
  drawn); recent box x 60–420, y 295–572, corners 12, no border (a border
  only with Increase Contrast); rows 48 tall with the selection inset 8,
  corners 8. Row separators are not drawn (open).
- *G10 checked.* Inspector fields, debug-area fields and the editor stay
  standard controls with no glass; the separator lines above the debug
  area's bottom bars are gone (macOS 26+).
- §1 "candidate" rows: `NSGlassEffectView` (radius 15, style
  `.regular`) gives the observed 30-point capsules with rim, highlight
  and shadow, flat when inactive; `NSButton.BezelStyle.glass` with
  `borderShape = .circle` gives the 38 × 38 Welcome circle. Inside a
  toolbar, an `NSGlassEffectView` item merges with neighboring bordered
  items, so the toolbar uses bordered items, not glass views.
  `effectIsInteractive` was not needed. The split-item accessory API with
  `NSScrollEdgeEffectStyle` was not needed for the jump bar or the debug
  bar (above); it stays the way to try if the reference's edge rendering
  must be matched more closely.
- Full screen (§4.3) and the dark appearance are system behavior; Ycode
  draws only system materials and semantic colors, so nothing more is
  done for them.

## 1. Public API equivalents (level 1)

The names below are public AppKit API in the macOS 26/27 SDK. They are
the means; this spec's tables are the target. Where a row says
"candidate", the clean side must confirm that the API gives the observed
look.

| Observed effect | Public API |
|---|---|
| Glass look of toolbars, sheets, popovers and standard controls at all | Built against SDK 26+ with standard AppKit components; nothing else ("Adopting Liquid Glass": standard bars, sheets, popovers and controls adopt the material automatically). Not opting out (`UIDesignRequiresCompatibility` must stay absent or NO). |
| Toolbar items in glass shapes, grouped items sharing one shape | `NSToolbar` with `NSWindow.toolbarStyle = .unified`; `NSToolbarItem` (buttons with `isBordered`), `NSToolbarItemGroup` for items that share a capsule (with `selectionMode` for the segment groups; `role` is new in macOS 27, `.tabs` / `.valueSelection`), `NSToolbarItem.style` (`.plain`; `.prominent` is not used by the reference). |
| Fixed gap that splits a shared background | `NSToolbarItem.Identifier.space` (fixed spacer); flexible space for the centered group. |
| Left groups tracking the navigator edge, inspector button over the inspector | `NSTrackingSeparatorToolbarItem`, `NSToolbarItem.Identifier.sidebarTrackingSeparator`, `.inspectorTrackingSeparator`. |
| Custom glass shape (selector bar, inspector tab bar, filter bar, Welcome close button) | `NSGlassEffectView` (`contentView`, `cornerRadius`, `style` `.regular`), `NSGlassEffectContainerView` (`spacing`) to batch neighbors; for buttons `NSButton.BezelStyle.glass` with `borderShape` `.capsule` / `.circle`. `NSGlassEffectView.effectIsInteractive` (macOS 27) for glass that hosts controls. Candidate. |
| Flat filled fields and push buttons | Standard `NSTextField`/`NSSearchField`/`NSPopUpButton`/`NSButton` (`.push`) with `controlSize` and `borderShape`; no custom background. |
| Bars over a scroll view with soft or hard edges | `NSSplitViewItem.topAlignedAccessoryViewControllers` / `bottomAlignedAccessoryViewControllers` with `NSSplitViewItemAccessoryViewController.preferredScrollEdgeEffectStyle` (`NSScrollEdgeEffectStyle.softStyle`, `.hardStyle`, `.automaticStyle`; macOS 26.1); `NSTitlebarAccessoryViewController.preferredScrollEdgeEffectStyle` for titlebar accessories. Candidate for the jump bar (top, opaque-looking) and the editor's bottom bar (hard). |
| Content placed under side areas or bars | `NSSplitViewItem.automaticallyAdjustsSafeAreaInsets`, `allowsFullHeightLayout` (sidebar/inspector full height under a full-size content view), `titlebarSeparatorStyle`; `NSBackgroundExtensionView` (not used by the reference). |
| Split layout | `NSSplitViewController` with `NSSplitViewItem` behaviors (`sidebarWithViewController:`, `inspectorWithViewController:`). G2: whether these draw floating panels under SDK 26+ must be checked, and the reference's flush layout kept. |
| Concentric corners | `NSView.cornerConfiguration` / `effectiveCornerRadii` (macOS 27). Optional. |
| Accessibility adaptation | System: with standard components, Reduce Transparency and Increase Contrast adapt automatically (Apple, "Adopting Liquid Glass"). Ycode draws no custom translucency, so it needs no code for these. |

## 2. Surfaces

Geometry is for a 1400 × 900 window with the navigator (290) and the
inspector (260) shown, in points from the window's top left. Light
appearance, active window, unless stated. §4 gives the differences.

### 2.1 Window and areas

| Surface | Material | Shape and geometry | Notes |
|---|---|---|---|
| Window | system | continuous corner, the curve spans about 15 points along each edge | Same for project, Welcome and sheet-parent windows; system-drawn. |
| Navigator area | solid area background (system sidebar background) | full height x 0–289, from the window's top edge (under the window buttons and the left toolbar items) to its bottom edge; **no inset, no corner radius** | No divider line between navigator and editor; only the background changes. |
| Editor area | editor background | x 290–1139, full height under the toolbar | — |
| Inspector area | same kind as the navigator | full height x 1141–1399, from the top edge; no inset, no corner radius | A 1-point divider line at x 1140 between editor and inspector. |
| Toolbar | **no bar background** | 52 points tall, no bottom line | Each item is its own glass shape (§2.2). Over each area the toolbar shows that area's background. |

### 2.2 Toolbar items

All shapes are glass, **38 points tall**, top at y 7 (7 + 38 + 7 = 52).
Neighboring shapes are **6 points** apart. A group that ends or starts at
an area edge keeps **7 points** from that edge.

| Item | Shape | Drawn x | Size |
|---|---|---|---|
| Navigators \| Coding Assistant | one capsule, two segments; divider line only when no segment is selected | 95–172 | 78 × 38 |
| Run \| Stop | one capsule, divider line between | 208–282 (ends 7 before the navigator edge) | 75 × 38 |
| Go Back \| Go Forward | one capsule, divider line between | 297–371 (starts 7 after the navigator edge) | 75 × 38 |
| Activity view | **no shape**: icon, name and status as plain content on the toolbar | from x 380 | — |
| New Conversation | circle | 569–606 | 38 × 38 |
| Scheme › Destination | capsule | 613–803 | 191 × 38 (width follows the titles) |
| Issue capsule | capsule | 810–872 | 63 × 38 (width follows the counts) |
| Notices (Ycode leaves this slot out, `reference-ui-6.md` §12) | circle | 879–916 | 38 × 38 |
| Add Editor \| Editor Options | one capsule, no divider | 923–1002 | 80 × 38 |
| Canvas \| Assistant \| Code Review | one capsule, divider line before the third | 1009–1133 (ends 6 before the inspector divider) | 125 × 38 |
| Hide / Show Inspector | circle over the inspector area | 1355–1392 (7 from the window's right edge) | 38 × 38 |

1. The first capsule starts 15 points after the window buttons (which
   span x 18–79).
2. **Navigator hidden:** the editor background reaches the window's left
   edge; the left capsules close up with 6-point gaps (95–172, 179–253,
   260–334).
3. **Inspector hidden:** the inspector circle stays 7 points from the
   right edge; the gap between the editor-mode capsule and the circle is
   11 points.
4. **Selected segment:** a recessed, fully rounded pill inside the capsule,
   about 26 points tall, 4–5 points inside the rim, about 32 wide for a
   37-point segment. No accent color.
5. Accessibility frames stay as in `reference-ui-6.md` §2.1 (segments
   36–37 × 35, single buttons 39 × 51).

### 2.3 Navigator bars

| Surface | Material | Geometry | Notes |
|---|---|---|---|
| Navigator selector bar (nine icons) | glass capsule, floating | x 6–283, y 51–80: **278 × 30**; 6 from each side edge of the area, directly under the toolbar | Selected icon: recessed pill about 30 × 24. Shadow below; **no** divider line below. |
| "+" (add) button | glass circle | x 6–36, y 863–892: 31 × 30 | — |
| Filter field | glass capsule (search field inside) | x 42–283, y 863–892: **242 × 30**; 6 after the "+"; 7 above the window's bottom edge | Its menu glyph, recent-files and source-control toggles sit inside the capsule. |
| Outline | area background | full area height | Scrolls under both bars (§3.1). Selection: rounded rectangle 22 tall, inset 10 from both sides, corners about 5, neutral fill. Overlay scroller between the bars. |

### 2.4 Coding Assistant header (left area, second segment)

Two glass capsules, "New Conversation ⌄" (x 7–157) and "New Group"
(x 164–282), 30 tall at y 51–80, 7 apart, 7 from the area's edges: the
selector bar's metrics. Floating, no divider below.

### 2.5 Inspector tab bar

One glass capsule at x 1146–1393, y 51–80 (**248 × 30**), 5 from the
divider and 6 from the window's right edge; the selected tab a recessed
pill about 78 × 24. Floating, no divider below.

### 2.6 Inspector content, debug area, editor chrome (not glass)

| Surface | Material | Geometry |
|---|---|---|
| Inspector fields and pop-ups | flat filled rounded rectangles, no rim | about 24 tall, corners about 6 |
| Inspector section headers | plain text on the area background | — |
| Jump bar | opaque band continuing the toolbar's background over the editor | y 52–83, then a separator line (1–2 points) |
| Editor bottom bar ("debug bar") | translucent bar, hard edge (§3.2) | 36 tall; a separator line above it (and below it when the debug area is shown) |
| Debug area bottom bars | area background, borderless glyph buttons | filter fields **flat filled**, 22 tall, corners about 6; no separator line above the bars |
| Variables / console split | 1-point line | — |

### 2.7 Find navigator header (not glass)

The path ("Find › Text › Containing"), the find field and the scope
pop-up sit on the area background under the selector capsule and end with
a separator line. The find field is a rounded rectangle about 22 tall with
corners about 8: not a capsule, not glass.

### 2.7a Editor text area

Opaque. The minimap and the overlay scrollers are not glass.

### 2.8 Popovers

| Property | Value |
|---|---|
| Material | translucent frosted system popover material (the content beneath shows through, blurred); no visible rim |
| Arrow | yes, about 10 tall and 26 wide at the base, tip 2 points below the source button |
| Corners | about 17 points, continuous |
| Example sizes | toolbar notices popover 360 × 108; New Conversation prompt popover 376 × 176 (window) |
| Content | flat filled buttons; a separator line above a bottom row of glyph buttons and a circular send button (prompt popover) |
| Focus | the popover becomes key; the parent window draws inactive (§4.2) while it is open |

### 2.9 Sheets

| Property | Value |
|---|---|
| Position | **centered on the parent window, horizontally and vertically** (not attached under the toolbar) |
| Material | opaque; corners about 17 points; no visible rim |
| Parent | the whole parent window, toolbar included, is dimmed uniformly while the sheet is up |
| Buttons | flat filled, 75 × 24 drawn; the default button accent-filled |

### 2.10 Welcome window (480 × 632)

| Element | Material | Geometry |
|---|---|---|
| Window | opaque, no title bar | system corner |
| Close button | **glass circle** | x 19–57, y 19–57 (38 × 38); accessibility frame 36 × 36 at (20, 20) |
| Open…, Clone…, New Project ⌄ | **flat filled capsules** (not glass, no bezel shadow) | 35 tall drawn (36 accessibility), 107 / 107 / 130 wide, 8 apart (`reference-ui-6.md` §1.4) |
| Recent list box | flat fill slightly off the window background, **no border line** | x 60–420, y 295–572, corners about 12 |
| Selected recent row | accent-filled rounded rectangle | inset 8 (x 68–412), 48 tall, corners about 8 |
| Row separators | lines | start under the text, not under the icon |

## 3. Scroll-edge behavior

### 3.1 Navigator outline under its glass bars

1. The outline extends from under the selector bar to the window's bottom
   edge, under the filter bar.
2. Rows stay fully legible up to the edges of the glass capsules: there is
   **no progressive fade** above the filter bar or below the selector bar.
3. Rows under a capsule show through it, blurred and dimmed.
4. Observed with the window inactive; the active window was not observed
   scrolled (§5).

### 3.2 Editor bottom bar: hard edge

1. Editor text is clipped at the separator line above the bar.
2. Inside the bar, the text that has scrolled beneath it shows strongly
   blurred and faint (an impression of color, no legible shapes).
3. This holds with the debug area shown or hidden.

### 3.3 Editor top

1. The jump bar band never shows editor content (scrolling changes no
   pixel in it).
2. In the toolbar band above the editor, once the editor is scrolled away
   from the top, a very faint, heavily blurred trace of the scrolled-away
   text appears; at the top of the file nothing appears. Ycode may treat
   the toolbar band over the editor as plain editor background; the trace
   is barely visible.

## 4. Appearance and state differences

### 4.1 Dark appearance

Not observed (§6).

### 4.2 Inactive window

1. Every glass shape (toolbar items, selector and tab bars, navigator
   bottom bar, Welcome close button) becomes **flat**: one even fill,
   slightly darker than the area behind it, with a plain outline; no
   highlight, no gradient, no shadow. Shapes, sizes and positions do not
   change.
2. The navigator and inspector backgrounds become slightly lighter; the
   editor and the toolbar band over it do not change.
3. Window buttons turn neutral; toolbar glyphs and texts dim; the
   navigator's selection highlight becomes lighter.
4. Content under glass still shows through, blurred.
5. A window draws inactive while one of its popovers is key.

### 4.3 Full screen

1. The toolbar becomes a separate full-width band, 52 tall, laid over the
   top of the content (the system's full-screen toolbar window); the
   content keeps its 52-point top band, so the navigator selector bar,
   the inspector tab bar and the jump bar keep their offsets.
2. Window corners are square.
3. The toolbar band itself was not captured (§5).

### 4.4 Accessibility settings

Reduce Transparency and Increase Contrast were off and could not be
changed. Ycode relies on system materials only, so the system's
adaptation applies (§1, last row).

## 5. Not observed

Hover and pressed states, focus rings, menus (menu bar, context, pop-up
and pull-down), Settings, Open Quickly, the Library, the editor tab bar,
the find bar, the toolbar in full screen, live window resizing, the dark
appearance, the Reduce
Transparency and Increase Contrast states, and the scrolled navigator in
an active window. Each needs a menu press, a keystroke, the pointer over
the window, a drag, a Space change or a Mac setting change. Until
observed, Ycode uses the system's standard look for these (system menus,
standard search fields, standard tab bar).

## 6. Dark appearance

Not observed. The Mac's appearance is set to switch automatically and
stayed light through the whole pass (checked until 18:50 local time, after
sunset); the appearance is a Mac setting and was not changed, and the
reference cannot be relaunched with another appearance without quitting it
(a menu press). Requirement for Ycode until observed: draw every surface in
this spec with system materials and semantic colors only, so that the dark
appearance is the system's; the shapes, sizes, spacing and scroll-edge
behavior of §2–§4 do not depend on the appearance.

## 7. Council round 1 measurements (2026-11-04)

A review council of three judges compared Ycode with the reference in one
scripted session. These values were measured from that session's captures:
1x stills (one pixel is one point) and recordings with per-frame times. The
judges disagreed on several values, and these measurements settle them. The
checklist for the clean side is `fidelity-council.md`. The method is in
`research/notes/council-r1-2026-11-04.md`.

**Capture conditions.** The window was 1400 × 880 with the navigator (290)
and the inspector (260) shown, in the light appearance. **The window was
not key** in either app: the session runs in the background and the window
buttons are neutral grey. Every glass value below is therefore the
**inactive** look of §4.2. The colours in this section (an exception to the
"no colors" scope above, made for the council) are inactive-state sRGB
values.

**The Ycode build in the session showed the earlier design.** The capture
wrapper bundles the plain `swift build` executable, which declares SDK 15.0
(`LC_BUILD_VERSION`, minos 15.0, sdk 15.0). That is gap G0 again. AppKit
therefore drew Ycode's pre-macOS-26 fallback: no toolbar capsules, an
opaque grey toolbar band and a grey jump bar. The judges' "no glass
capsules" findings describe that build, not `make-app.sh`'s. The wrapper
must stamp the SDK as `make-app.sh` does before round 2.

### 7.1 Toolbar

Height 52. Every shape is 38 tall, from y 7 to y 44 inclusive. The judges'
28–32 and 34–36 are both wrong; §2.2 stands. In the inactive state each
shape is one flat fill with a 1-point outline.

| Shape over | Fill | Outline |
|---|---|---|
| Editor (white band) | #ECECEC | #D1D1D1 to #DDDDDD (anti-aliased 1 pt) |
| Navigator or inspector (#F2F2F3) | #E6E6E7 | #D3D3D4 |
| Selected segment pill (inside a capsule) | #CACACB | — |

Drawn spans at mid-height (y 26) in this window:

| Group, members | x with the subtitle shown | x after the subtitle went | x with the inspector hidden |
|---|---|---|---|
| Navigators \| Coding Assistant (two segments, the first selected) | 95–172 | 95–172 | 95–172 |
| Run \| Stop | 208–282 | 208–282 | 208–282 |
| Go Back \| Go Forward | 297–371 | 297–371 | 297–371 |
| Activity view (no shape) | icon 385–399, text 412–565 | icon 385–403, text 412–482 | the same |
| New Conversation (circle) | 599–636 | 565–602 | 694–731 |
| Scheme › Destination (capsule) | 643–859 (217) | 609–825 (217) | 738–954 |
| Issue capsule | absent (no issues) | absent | absent |
| Notices (circle) | 879–916 | 879–916 | 1090–1127 |
| Add Editor \| Editor Options (one capsule) | 923–1002 (80) | 923–1002 | 1134–1213 |
| Canvas \| Assistant \| Code Review (first selected) | 1009–1133 (125) | 1009–1133 | 1220–1344 |
| Hide / Show Inspector (circle) | 1355–1393 | 1355–1393 | 1355–1392 |

1. **The centre group follows the activity view's width.** New
   Conversation and the scheme capsule moved 34 points left when the
   subtitle "Preparing Editor Functionality" went away. That subtitle
   line was 153 wide and the title is 71, so the activity view is as wide
   as its longer line. When the inspector hid, the centre group moved
   right by 129–130, half of the 260 points the editor gained. The
   right-hand group moved with the inspector tracking separator, and the
   editor-mode capsule ended 11 before the circle (§2.2 item 3).
2. **Scheme capsule contents**, from left to right: a target glyph on a
   grey rounded square, "GlassScroll", a small "›" separator, a
   destination glyph (a laptop), "My Mac". The capsule has **no up-down
   pop-up chevrons**. Ycode draws "⌃⌄" chevrons after both titles; remove
   them.
3. **Activity view (title).** It has no shape. The icon is 19 wide at
   x 385, and the text starts 8 points after the icon. While a project
   loads, a progress spinner takes the icon's place; afterwards the icon
   is the project's. The title is bold. With a subtitle, the title's cap
   height runs from y 14 to y 23 and the subtitle line from y 30 to y 39
   (a smaller regular weight). Without one, the title is centred on the
   bar (ink y 21–30). **Inactive colour:** title and subtitle both
   #BCBDBD. The active colour is to measure in round 2. Ycode draws its
   title in #454546 in an inactive window and puts a document glyph before
   it.
4. The toolbar band over the editor is **white (#FFFFFF)**, the editor's
   background. Over the side areas it is their background, #F2F2F3. Ycode
   draws #E6E6E7 across the whole width.

### 7.2 Navigator and inspector bars

| Element | Measured | Notes |
|---|---|---|
| Navigator selector capsule | y 51–80 (30 tall), outline #C8C8C9, fill #DEDEDF | §2.3 confirmed |
| Its selected pill | x ≈ 10–36, y 54–77 (≈ 27 × 24), #CACACB; selected glyph #7C7D7E, others #919192 | neutral grey. **No accent colour.** Ycode tints the selected glyph accent blue (#0070F5) with no pill |
| Inspector tab capsule | y 51–80, fill #DEDEDF | §2.5 |
| Its selected pill | x ≈ 1151–1224, y 54–77, #CACACB; selected glyph #7D7D7E | Ycode: an accent-blue glyph (#007AFF) on a light pill |
| Filter capsule (880 window) | y 843–872, fill #E6E6E7, outline #C8C8C9 | 7 above the bottom edge, as §2.3 |
| Debug bar's first item | a filled light-accent shape 18 × 11 at x 303–320, y 857–867 (#7FBCFF inactive) | Ycode draws a grey outline glyph there |

### 7.3 Scroll-under

What passes under which bar. "Veil" means content that shows only as a
faint, shapeless darkening, with no glyph shapes.

| Bar | Content beneath | How much shows through (editor scroll of 600 pt, 136 frames) |
|---|---|---|
| Toolbar band over the editor (y 0–51) | editor text and minimap | Veil. Median mean darkness 0.4–0.6 levels of 255 (max 2.3). Visible content averages 8.1, so about **6 %** shows through. No pixel changes by more than 7 levels. |
| Jump bar (y 52–83) | editor text | Veil, the same strength: median 0.5 (max 1.2), at most 6 levels per pixel. **Correction to §3.3 item 1:** the band does change, faintly. |
| Sticky scope header (y 85–104) | editor text | Veil, median 0.54. Nearly opaque (`editor-area.md` §C.3). |
| Editor bottom bar (y 844–879) | editor text | Veil, median 1.2 (max 1.4), at most 8 levels per pixel (§3.2) |
| Navigator selector capsule | outline rows | Veil, at most 10 levels: heavily blurred; an orange icon shows only as a soft tint |
| Navigator filter capsule (bottom) | outline rows | **Visible**, moderately blurred. Glyph shapes and icon colour are discernible (pixel change up to 109 levels). |
| Toolbar band over the navigator | nothing | 0 pixels changed: the outline does not reach above the selector capsule |
| Inspector | not scrolled in this session | to measure in round 2 |

1. **No edge fade anywhere.** The first text row under the sticky
   header, and the first outline row under the selector capsule, are at
   full colour. For example, the comment ink right under the header is
   #697085, the same as in the middle of the editor. The effect does not
   reach below a bar's edge at all (0 points).
2. **Ycode:** its toolbar band and jump bar changed by 0–1 levels during
   the same scroll. They are opaque, and its scroll's changed region stops
   at y 83 and at the bottom bar. This is partly the SDK 15 fallback above.
3. **Tint over light and dark content was not measured.** Step 5 (bands
   under the toolbar) did not scroll in the reference: the image viewer
   scales the image to fit, so it has no scroll area
   (`editor-area.md` §C.6). To measure in round 2 (see the checklist).

### 7.4 Pane backgrounds (inactive, light)

| Surface | Reference | Ycode in the session |
|---|---|---|
| Navigator area | #F2F2F3 | #E6E6E7 |
| Inspector area | #F2F2F3 | #EBECEC |
| Editor text area | #FFFFFF | #FFFFFF |
| Toolbar band over the editor | #FFFFFF | #E6E6E7 |
| Jump bar band (y 52–83) | #FFFFFF, then a **2-point** separator #E5E5E5 at y 84–85 | #ECECEC, then a 1-point #D4D4D4 at y 83 |
| Editor bottom bar | #FFFFFF, 1-point separator #D7D7D7 above it (y 843) | #FBFBFB, separator #E6E6E6 |
| Editor ▸ inspector divider | 1 point #DADADB at x 1140 | 1 point #DADADB |
| Navigator ▸ editor | no line: #F2F2F3 meets #FFFFFF at x 289/290 | no line |
| Inspector section rules | 1 point #DADADB, x 1148–1391 | 1 point #D4D5D5 |

§4.2 says the side areas get lighter when the window is inactive, so
their active values are darker than #F2F2F3. To measure in round 2 with
the window key.

### 7.5 Inspector show/hide and the toolbar

When the inspector hides, the toolbar's right group and the centre group
move with the editor's width every frame (§7.1, item 1). The inspector
circle stays where it is. One frame about 35 ms after the slide ends
redraws the centre group (x 694–955). The slide itself is in
`editor-area.md` §C.7.

## 8. Council round 2 measurements (2026-11-04)

Round 2 captured both apps **in the foreground, with the window key**.
The capture was 1x on a 100 Hz display, with the window 1400 × 880 (1100
× 880 in the narrow-window step). These are the **active** values that §7
could not measure. The checklist's round 2 section is in
`fidelity-council.md`; the method is in
`research/notes/council-r2-2026-11-04.md`.

### 8.1 Active toolbar glass and pane colours

| Surface | Active (round 2) | Inactive (round 1, §7) |
|---|---|---|
| Navigator and inspector areas | **#EDEDEE** | #F2F2F3 |
| Editor ▸ inspector divider | 1 point **#D4D4D6** | #DADADB |
| Toolbar band over the editor | #FFFFFF | #FFFFFF |
| Toolbar shape over the editor (column x 700) | rim y 7 #EBEAEB; a fill that is #FFFFFF at the top, darkens to #F9F9F9 at y 15–24 and returns to #FDFDFD; rim y 44 #E7E7E7; a **soft shadow** about 10 points tall below the shape (y 45–54, #FCFCFC) | flat #ECECEC, 1-point outline |
| Toolbar shape over a side area (column x 150) | rim #DBDBDC; the fill runs from #FFFFFF at y 8 down to #EFEFF0 at y 15–17 and back up to #FBFBFC at y 42, with a white inner highlight at y 43; rim #D8D8D9; shadow #EAEAEB at y 45–50 | flat #E6E6E7 |
| Navigator selector capsule (y 51–80) | rim #D7D7D8; an inner highlight #FEFEFE at y 52; a fill from #E7E7E8 (y 59–68) to #F3F3F5 (y 78); an inner highlight #FFFFFF at y 79; rim #D5D5D6 at y 80 | flat #DEDEDF |
| Inspector fields | Name field #E0E0E1; pop-ups #DCDCDD; disabled pop-ups #E5E5E6; section rules #D6D6D7; Target Membership border #A0A0A1 | #E5E5E6 / #E1E1E2 / #E9E9EA / #DADADB / #A6A6A7 |

**Toggles and disabled buttons.** The reference never fills a toolbar
toggle with the accent colour. With the navigator shown, the Navigators
segment and the selected editor mode carry only the recessed grey pill;
neither has a single accent-blue pixel. Unavailable buttons dim:
- Stop is #A2A2A4;
- Go Back and Go Forward are #AEAEAE until there is history (Go Back is
  black once there is).

Ycode fills the navigator toggle (630 accent pixels) and the selected
editor mode (605) with solid accent blue, and draws Stop, Back and Forward
black whether or not they can act. The Show Inspector circle is not
accent-filled in either app, before or after hiding; Gemini's
"highlighted" button was not seen.

### 8.2 The toolbar in a narrower window (1100 × 880)

The harness resized the window from 1400 to 1100 in one step. In the
reference, the still of that step shows the whole window drawn at
**0.898 scale**, with its shadow, inside the 1100 × 880 frame. The Add
Editor menu from the failed split step was still open, so the capture
took in the window together with the menu. The window-server frame stayed
1100 × 880. Positions below are divided by 0.898 (±2 points). GPT's
"visible frame ends near 988" is this scaling, not a minimum width.

| Item, left to right | x (points) | Compared with 1400 |
|---|---|---|
| Navigators \| Coding Assistant; Run \| Stop; Back \| Forward | 95–173, 208–281, 298–372 | unchanged (they track the navigator) |
| Activity view | icon at 385; title 411–482; the subtitle **truncated in the middle**, "Scannin…positories", 412–512 | the subtitle was 165 wide |
| New Conversation (circle) | about 529–565 | moved left |
| **Scheme › Destination** | about 573–660 (87 wide) | **titles dropped**: target glyph, "›", destination glyph; no text |
| Add Editor \| Editor Options | about 668–746 | — |
| **Overflow "»" (circle)** | about 797–834, 7 before the inspector's edge (841) | new |
| Notices circle; Canvas \| Assistant \| Code Review | **not shown**: moved into the overflow | — |
| Show Inspector | 1056–1091 | stays over the inspector |

1. **Order of overflow.** At 1100 the editor-mode group and the Notices
   circle went into "»", and the scheme capsule dropped its titles. The
   order in which they go cannot be told from a one-step resize. **Window
   minimum width: not measured.**
2. **Ycode at 1100:** no "»". It keeps New Conversation, the scheme ("Glas…
   › My Mac", truncated), Add Editor, Editor Options, and a collapsed
   editor-mode pull-down. It has no subtitle and no Notices.
3. **To measure in round 3:** a slow live resize from 1400 down to the
   minimum, recorded, to get each item's overflow threshold, the scheme
   capsule's title-dropping width and the minimum window width.

### 8.3 Content under the bars, over dark and red bands

Step 08 scrolled `Bands.swift` 1200 points over 2 s. The file has rows
of full-block characters in the comment colour (slate) and in the string
colour (red), with blank rows between. The table gives each region's mean
colour, white at rest, at the frame where it was darkest over slate content
and where it was reddest. The content row itself (y 86–104) reaches a mean
darkness of 94.5 over slate.

| Region | Over slate bands | Mean darkness | Share of the content's | Over red bands | Ycode |
|---|---|---|---|---|---|
| Toolbar band, y 0–6 (above the shapes) | #ECEDF0 | 17.2 | **18 %** | #FDE5E3 | no change (#FFFFFF throughout) |
| Toolbar band, y 45–51 | #EEEFF2 | 15.3 | 16 % | #FBE7E6 | no change |
| Toolbar, between shapes (y 20–30) | #F1F2F5 | 12.2 | 13 % | #FEEBE9 | no change |
| Jump bar, y 53–83 | #F6F7F8 | 8.0 | **8.5 %** | #FFF2F0 | at most 2 levels |
| Editor bottom bar, y 846–879 | #F2F3F5 | 11.4 | **12 %** | #FEEDEB | 13.4 (12 %): **matches** |

1. **Blurred, not just tinted.** Over a red band the toolbar band and jump
   bar show a soft red glow in the band's shape. It stops where the band
   stops, and its edge spreads over about 15 points (10 % to 90 %), which
   is a blur of roughly 6 points (σ). Rows stay distinct vertically: at
   one frame the darkening in the green channel was 26, 12, 2, 24 and 26
   levels at y 3, 48, 60, 75 and 83, following the bands beneath. The
   glow also shows **through the toolbar shapes** (capsules and circles
   turn pink).
2. **Peak strength.** A red band darkens the green channel by 211 levels
   in the open editor and by 26 under the toolbar band: about 12 % per
   pixel.
3. **Edges.** The content is sharp right up to the jump bar's separator
   (y 84–85). Above it the toolbar band and jump bar act as one blurred
   veil, with **no gradient by height** and no fade below the separator.
   The bottom bar does the same above its 1-point separator.
4. **Active vs inactive.** Round 1, on an inactive window, measured about
   6 % for the toolbar band and jump bar over text. The active window
   passes 8.5–18 %. The inactive share may simply be lower; to confirm
   with one capture of each state over the same bands.
5. **Ycode:** its bottom bar matches. Its toolbar band does not respond
   at all and its jump bar barely responds (≤ 2 levels), so the red glow
   never appears above the editor. Ycode's own record says the editor
   column still starts below the toolbar (`liquid-glass-ycode.md` §12.8).
6. **The judge's 229,230,231 → 228,220,221** was a region mean that took
   in the toolbar shapes. Use the per-region values above.

### 8.4 Navigator under its bars (active)

After scrolling the navigator 432 points:
- the toolbar band over the navigator changed by at most 2 levels: rows
  never show above the selector capsule;
- rows showed through the selector capsule (the selected row's blue
  glows through it) and through the filter capsule (up to 237 levels of
  change: plainly visible, softened).

In **Ycode the rows draw over the toolbar band, the traffic lights and the
toolbar shapes at full contrast** (pixel change up to 238 levels at
y 0–44), and below the filter capsule. The outline must be clipped at the
selector capsule's top edge. Its content may pass under the two capsules
only.

## Evidence

| Claim | Level | Source |
|---|---|---|
| §0 G0 build version | — / 3 / 1 | `otool -l` of Ycode's SwiftPM product and of a plain `swiftc` product against the same SDK; a probe app of ours linked twice (declared sdk 27.0 vs 15.0) shows the new and the old design on macOS 27.2; Apple's "Adopting Liquid Glass" (build with the latest SDK to get the design; `UIDesignRequiresCompatibility`) |
| §0 G1 crash | — | Crash report of Ycode's own debug build (our code) |
| §0 G2–G10 Ycode side | — | Ycode source identifiers in `ycode/Sources/YcodeUI` and its running Welcome window |
| §1 API names | 1 | macOS 27.0 SDK AppKit interface declarations (`NSGlassEffectView`, `NSScrollEdgeEffectStyle`, `NSSplitViewItemAccessoryViewController`, `NSSplitViewItem`, `NSToolbarItem`, `NSToolbarItemGroup`, `NSButton`/`NSControl` border shapes, `NSTitlebarAccessoryViewController`, `NSBackgroundExtensionView`, `NSView` corner configuration) and Apple's "Adopting Liquid Glass" article |
| §2.1–§2.7 materials and geometry | 3 | Window captures at scale 1 (one pixel = one point): rim, highlight, shadow and separator positions from pixel profiles; accessibility frames |
| §2.2 hidden-area variants | 3 | Captures after clicking the Navigators segment and the inspector button |
| §2.8 popovers | 3 | Captures with the notices popover and the New Conversation popover open; window-server window sizes; a capture without backdrop rendering the popover dark (translucency) |
| §2.9 sheet | 3 | Capture with the Target Membership "Choose Targets" sheet open; accessibility role AXSheet |
| §2.10 Welcome | 3 | Capture and accessibility frames of the Welcome window |
| §3 scroll edges | 3 | Captures before and after scrolling the editor and the navigator; pixel differences per row |
| §4.2 inactive | 3 | Captures of the same window key and not key |
| §2.7 Find header | 3 | Capture after clicking the Find navigator icon |
| §4.3 full screen | 3 | Window-server window list and a background capture of the content window after the owner put it in full screen |
| §4.3, §5 | — | Settings read with `defaults read` only; limits of background, click-only control |
| §6 dark | — | Not observed (appearance setting read only) |
| §7 capture conditions | 3 / — | Capture manifests: window frame, neutral window buttons. Ycode wrapper: `otool -l` of its executable (our own binary) |
| §7.1 toolbar shapes, positions, title | 3 | Council r1 stills 01, 02, 08 (1x): colour runs on rows 10 and 26 and on column 700, and glyph ink boxes. `research/tools/council-r1/measure_captures.py` (`toolbar`) |
| §7.2 bars and pills | 3 | Still 01: colour runs on the selector and tab capsules |
| §7.3 scroll-under | 3 | Recordings 02 (136 frames) and 07: per-frame mean darkness of each bar region against the content; before/after differences of stills 07. Script sections `under` and `navigator` |
| §7.4 pane colours | 3 | Still 01: colour runs (fully covered pixels, sRGB) |
| §7.5 toolbar during the inspector slide | 3 | Recording 08: per-frame changed regions |
| §8 round 2: active glass, narrow toolbar, bands, navigator | 3 | Council r2 1x stills and recordings (foreground, key window). Column runs; capsule rims located as local minima; per-frame region means over the bands scroll; before/after differences. `research/tools/council-r2/measure_r2.py` (`bars`, `navigator`); the narrow still's scale from its alpha channel |
