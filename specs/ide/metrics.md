# Ycode metrics: spacing and insets of the IDE's windows

**Status:** Ycode's own design record (clean room), 2026-10-30. It
records a spacing audit of Ycode's windows: what Ycode measured, the
reference value where a spec gives one, the difference, and the fix or
decision. Reference values come only from `reference-ui.md` to
`reference-ui-6.md`, `liquid-glass.md`, `workspace-window.md` and
`device-hub.md`; standard metrics come from Apple's public Human
Interface Guidelines and AppKit documentation. Nothing here comes from
observing the reference directly. Where no spec value exists, Ycode's
value is a decision, and the measurement is listed as an open question
for the dirty room (§11).

**How Ycode was measured.** `UISpacingProbeTests` (opt-in, with
`YCODE_UI_PROBE_DIR=<dir>`) opens a sample package "Demo" in a real
workspace window: toolbar, full-size content, the navigator and the
inspector as the window's split items, 1400 × 900. It also opens the
Welcome window, Settings (General and Editing) and Device Hub with one
shut-down simulator row (no `simctl`). For each state it writes a dump of
every view's frame in window points (origin at the top left), a
`cacheDisplay` snapshot, and a `screencapture -l` capture of that one
window. The window is ordered behind all other windows; the capture is
the only one that draws the glass. Light runs set the window's appearance
to aqua (`YCODE_UI_PROBE_APPEARANCE=light`). The probe uses
`IsolatedPreferences` and `TestDefaults` only.

**Coordinates.** "y 51–81" is a frame from its top edge to its bottom
edge. `liquid-glass.md` gives inclusive pixel ranges ("x 6–283", 278
wide), so its end values are one less than a frame's edge.

## 1. Summary of fixes

| # | Region | Ycode before | Reference or standard | Difference | Fix |
|---|---|---|---|---|---|
| 1 | Project navigator: first row below the selector bar (the owner's report) | first row's top at y 78, under a selector capsule that ends at y 81: **3 points under the capsule** | 7 below the selector (`reference-ui-6.md` §5.3: row at y 86 under a selector ending at y 79) | −10 | Measured insets (§2). Now y 88, 7 below. |
| 2 | Navigators with header rows (Source Control, Find, Tests, Reports): first row | its top at 6 points **above** the clipping container's top, so its top 6 points were cut | 4 below the container (Ycode, R45's intent: 7 below the selector less the 3-point rule) | −10 | The same measured insets (§2). |
| 3 | Navigator filter capsule | x 43–284, 241 wide, 6 after the "+" circle | x 42–283 (242 wide), the circle x 6–36 (`liquid-glass.md` §2.3) | 1 point | 5 points after the circle; 242 wide. |
| 4 | Jump bar | y 52–78: 25-point band and a 1-point separator | band y 52–83, then the separator (`liquid-glass.md` §2.6) | −6 | 31-point band and separator (32). |
| 5 | Inspector rows | the Name field ended 5 points from the window's edge and long pop-ups ("No Explicit Line Endings") 2 points from it, against a 12-point left inset | — (Ycode: equal side insets) | up to 10 | Rows span the content between two 12-point insets; fields and pop-ups fill the value column and truncate inside it (§5). |
| 6 | Debug area bottom bars | variables bar 24 tall, console bar 20; the console's filter field touched the window's bottom edge | — (Ycode) | — | Both 28 tall, controls centered: 4 points from the bottom edge (§7). |
| 7 | Settings ▸ General | "Restore open projects and workspaces:" cut off in the 200-point label column ("Restore open projects and worksp") | — (AppKit form practice) | — | A label wider than the column wraps onto two lines (§8). |
| 8 | Device Hub toolbar: Add Device \| Filter, Hide Sidebar | capsule x 96–169, circle x 177–213: 27 points short of the sidebar's edge (x 240) | circle about x 195–233, ends 7 before the edge; capsule about x 113–189 (`device-hub.md` §3 items 2–4) | 18–20 | A leading flexible space: capsule x 115–188, circle x 196–232 (§9). |

Snapshots (outside the repository, next to the worktree):
`ui-spacing-<region>-{before,after}.png` for the regions navigator,
navigator-light, navigator-header, navigator-filter, jumpbar, inspector,
debug-bars, settings and hub-toolbar.

## 2. Navigator outline

| Element | Ycode (after) | Spec | Notes |
|---|---|---|---|
| Selector capsule | x 6–284, y 51–81 (278 × 30) | x 6–283, y 51–80 inclusive (`liquid-glass.md` §2.3) | matches |
| Selected icon's pill | 30 × 24 | about 30 × 24 | matches |
| First row's top | 7 below the capsule | 7 (`reference-ui-6.md` §5.3) | fixed (§1 item 1) |
| Row height | 22, no spacing between rows | 22 | matches |
| Disclosure triangle | 13 wide; x 12 at level 0 | — | AppKit's source-list layout; open question |
| Indentation per level | 12 | — | AppKit's source-list default; open question |
| Row icon, label | 16-point icon at the cell's start, label 4 after it | — | Ycode; open question |
| "+" circle | x 6–37, y 863–893 (31 × 30) | x 6–36, y 863–892 inclusive | matches |
| Filter capsule | x 42–284, y 863–893 (242 × 30), 7 above the bottom edge | x 42–283, y 863–892 inclusive | fixed (§1 item 3) |
| Last row | clears the filter capsule by 2 | — | unchanged |

**Why the first row was misplaced.** The outline's scroll view runs from
the area's top edge under the bars, and a top content inset puts the
first row below the selector. That inset subtracted a fixed 10-point
padding that the source-list table style adds above its first row. The
style adds it only in some places. In a plain window (where the R45 test
measured), the first row is 10 points down. In the workspace window's
sidebar split item, it is at 0. So in the real window the first row sat
10 points higher than designed. The clipped layout (header rows shown)
made the same assumption and cut 6 points off the first row.

**Rule now** (`NavigatorAreaController.updateOutlineInsets`). The inset
is the target position less the outline's own padding above row 0. The
padding is measured from `rect(ofRow: 0)` whenever the outline has rows,
and remembered while it is empty. The outline reports each reload, so
the inset follows the first rows that appear.

| Layout | First row's top |
|---|---|
| Under the bars (no header row; macOS 26 and later) | `firstRowGap` = 7 below the selector capsule |
| Clipped (header rows shown, or before macOS 26) | `clipToFirstRow` = 4 below the clipping container's top. With no header, the container starts 3 below the selector, so the row is 7 below it as above. |

The scroll view no longer starts above its container by a constant
offset; in both layouts it fills its container or the area.

## 3. Toolbar

The probe found nothing to change. Every value is the system's; Ycode
sets the item kinds and order (`liquid-glass-ycode.md` §2).

| Element | Ycode | Spec |
|---|---|---|
| Toolbar height | 52 (`contentLayoutRect` starts at y 52) | 52 |
| Item shapes | glass views at y 8, 36 tall in the frame dump; drawn 38 tall, top 7 (`liquid-glass.md` §0 G3, measured from captures) | 38 tall, top 7 |
| Run \| Stop, Back \| Forward | 208–282, 297–371 (frames 208.5–281.5, 297.5–370.5) | 208–282, 297–371 |
| Scheme capsule | width follows the titles | width follows the titles |

## 4. Editor

| Element | Ycode (after) | Spec | Decision |
|---|---|---|---|
| Jump bar | y 52–84: 31-point band, then the separator | band y 52–83, then a 1–2-point separator | fixed (`JumpBar.bandHeight`, `JumpBar.height`) |
| Jump bar contents | 6 from both ends, centered vertically | — | unchanged |
| Gutter | 48 wide; the numbers right-aligned in the 36 points left of the 12-point folding-ribbon column | — | unchanged; open question |
| Change column | 11, left of the numbers | 11 (`reference-ui-5.md` §6.3) | matches |
| Text inset | 4 points (`textContainerInset`) plus the line fragment padding | — | unchanged; open question |
| Minimap | 112 wide in an 845-point editor (13.3 %) | 13–14 %, at least 60 (`reference-ui-5.md` §6.5) | matches |
| Find bar | one row: 32 tall, 24-point controls, 4 above and below, 8 at the sides; with Replace, two rows 4 apart | not observed (`liquid-glass.md` §5) | unchanged; open question |
| Editor tab bar | 26 when shown | not observed | unchanged; open question |
| Debug bar | 36 tall with its separator (y 864–900 with the debug area hidden) | 36 (`liquid-glass.md` §2.6) | matches |

## 5. Inspector

| Element | Ycode (after) | Spec | Decision |
|---|---|---|---|
| Width | 265 | 265 (`workspace-window.md`); 260 observed (`liquid-glass.md`) | unchanged (`liquid-glass-ycode.md` §10) |
| Tab capsule | x 1141–1394 (253 × 30), 5 from the divider, 6 from the edge | 5 and 6 from the edges (248 at a 260-point inspector) | matches |
| Selected tab's pill | 78 × 24 | about 78 × 24 | matches |
| Content | 12 from the divider and from the window's edge (`contentInset`), 10 above the first heading (`contentTopInset`) | — | Ycode |
| Key column | 80, right-aligned, 8 before the value | — | Ycode; open question |
| Fields and pop-ups | fill the value column to the right inset; a long pop-up title truncates inside it ("No Explicit Line Endin…" at 265) | fields about 24 tall (`liquid-glass.md` §2.6) | fixed (§1 item 5); widths are an open question |
| Section rules | full content width | thin rules between sections (`reference-ui-6.md` §6) | matches |

Rows are `InspectorRowView`s: a row is exactly as wide as the inspector's
content less the two insets.

## 6. Navigator, inspector and debug area: other states

| State | Ycode | Notes |
|---|---|---|
| Find navigator | path row, find field and scope rows under the selector capsule; outline clipped below them | the first result row is 4 below the clip (§2) |
| Tests navigator | plan pop-up and filter buttons in a 20-point header row 2 below the rule; rows 4 below the clip | before the fix the root row's top 6 points were cut off |
| Source Control, Reports | the same header row | the same |

## 7. Debug area

| Element | Ycode (after) | Spec | Decision |
|---|---|---|---|
| Height when first opened | 135 | 135 (`reference-ui-5.md` §8.2) | matches |
| Variables / console split | 50/50 with a 1-point line | about 50/50 | matches |
| Bottom bars | both 28 tall (`bottomBarHeight`), controls centered, 6 from the column's sides (`bottomBarSideInset`) | no separator line above them; filter fields flat, about 22 tall (`liquid-glass.md` §2.6) | fixed (§1 item 6) |
| Filter fields | the system's small search field, 20 tall | about 22 | unchanged (system control size) |

## 8. Settings, Welcome

| Element | Ycode | Spec | Decision |
|---|---|---|---|
| Settings sidebar | 200 wide | not observed | `liquid-glass-ycode.md` §7 |
| Settings form | 20 above, 28 at the sides, rows 10 apart, labels in a 200-point right-aligned column (`SettingsPane.labelColumnWidth`) | not observed | Ycode |
| Long labels | wrap onto a second line inside the column; the control centers on the two lines | — | fixed (§1 item 7) |
| Welcome window | 480 × 632; close circle at (20, 20); buttons 107 / 107 / 130 × 36, 8 apart, top at 242; recent box x 60–420, y 295–572; selected row inset 8 | the same (`reference-ui-6.md` §1.4, `liquid-glass.md` §2.10) | matches (`NavigatorInspectorR45Tests.welcomeGeometry`) |

## 9. Device Hub

| Element | Ycode (after) | Spec | Decision |
|---|---|---|---|
| Window, areas | 1100 × 800; sidebar x 0–240, canvas 240–820, inspector 820–1100 | the same (`device-hub.md` §2.1) | matches |
| Add Device \| Filter | capsule x 115–188 | about x 113–189 | fixed (§1 item 8) |
| Hide Sidebar | circle x 196–232, 8 before the sidebar's edge | about x 195–233, 7 before it | fixed; the system draws the circle 36 wide (the reference about 38) |
| Device controls, inspector capsule | x 536–812 and 981–1092 at y 8 | `device-hub.md` §3 | unchanged |
| Sidebar search field | x 10–230, y 58–86 | not measured in `device-hub.md` | unchanged |

`DeviceHubToolbar.order` starts with a flexible space, as the workspace
window's toolbar does before Run | Stop.

## 10. Tests

`UISpacingTests` (YcodeUITests), in a real workspace window:

- `projectOutlineStartsSevenPointsBelowTheSelector`: the owner's report.
  The first row is 7 below the selector capsule, rows are 22 tall, and
  the gap holds after switching navigators.
- `headerNavigatorsKeepTheirFirstRowBelowTheHeader`: the Tests navigator's
  first row is 4 below its clip.
- `jumpBarIsTheReferenceBandAndASeparator`: y 52, 32 tall, the editor
  right under it.
- `inspectorRowsKeepTheRightInset`: the Name field ends 12 from the edge,
  and every pop-up ends within the inset on one edge.
- `debugAreaBottomBarsShareOneHeight`: both bars are 28 tall at the
  window's bottom, with no control closer than 3.5 to the edge.
- `settingsLabelsAreNotCutOff`: General's long label wraps in its column,
  and no single-line label is cut.
- `hubSidebarGroupEndsAtTheSidebarEdge`: the Hide Sidebar circle ends 7
  (± 1.5) before x 240.

`LiquidGlassTests.navigatorBarsFloatOverTheOutline` now expects the
242-point filter capsule and the clipped layout's inset rule.
`NavigatorInspectorR45Tests.rowsAre22PointsAndStartSevenBelowTheSelector`
still holds in its plain window, where the padding is 10.

## 11. Open questions for the dirty room

1. Outline indentation per level, disclosure triangle position and width,
   and the gap between the row icon and its label in the Project navigator
   (Ycode: 12, x 12 / 13 wide at level 0, 4).
2. The gutter: its width for a short file, where the line numbers end,
   and the gap from the gutter to the text.
3. The find bar's height, rows and side insets, with and without Replace.
4. The editor tab bar's height and tab metrics.
5. The inspector's key column width and the gap to the value, the value
   controls' widths (do pop-ups fill the column?), the content's side
   insets, and how "No Explicit Line Endings" fits in 260 points.
6. The debug area's bottom bars: height, and their controls' distance
   from the window's bottom edge.
7. Settings: sidebar width, form insets, label column, and how long
   labels are laid out (Settings was not observed, `liquid-glass.md` §5).
8. The first row's gap below the header rows in the Find, Source Control,
   Tests and Reports navigators (Ycode: 4 below the clip).
9. Device Hub: the sidebar search field's frame and the gap to the first
   section header.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Reference values in §1–§9 | 3 (in those specs) | `reference-ui-5.md`, `reference-ui-6.md`, `liquid-glass.md`, `workspace-window.md`, `device-hub.md`, as cited |
| Ycode values | — | `UISpacingProbeTests` frame dumps and `screencapture -l` captures of Ycode's own windows; `UISpacingTests` |
| The source-list padding depends on placement | — | Ycode's own outline in a plain window (10) and in the workspace window's sidebar item (0), measured with `rect(ofRow:)` |
| Form-label wrapping, side insets | 1 | Apple's Human Interface Guidelines (Layout; Sidebars) and AppKit documentation (`NSStackView`, `NSTextField`) |

Level 5 was not used, and no reference behavior was observed for this
spec.
