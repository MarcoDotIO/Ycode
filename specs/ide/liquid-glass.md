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
