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
for the dirty room (§11). §12 and §13 are the exceptions: the dirty
room's measurements of the reference from the council's captures
(rounds 1 and 2, 2026-11-04).

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
| Width | 260 (beta 2) | 260 (`workspace-window.md`, `liquid-glass.md` §7) | matches |
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

Items 1, 2 and 5 are answered in §12.

## 12. Council round 1 measurements (2026-11-04)

**This section is a dirty-room addition.** Unlike §1–§11, it records the
reference, measured in the council session's 1x captures (level 3). The
window was 1400 × 880, inactive and light, with the navigator 290 wide
(x 0–289) and the inspector 260 wide (x 1141–1399). Conditions are in
`liquid-glass.md` §7, the checklist in `fidelity-council.md`. The editor's
text metrics, gutter and minimap are in `editor-area.md` §C.1–§C.5. This
section adds the outline, scroll bars, jump bar and inspector. "Ycode"
means the session's build, which showed the SDK 15 fallback.

### 12.1 Navigator outline (answers §11 item 1)

| Element | Reference | Ycode in the session |
|---|---|---|
| Row pitch | **22** (judges: 20 or 22; settled at 22) | 22 |
| First row | ink from y 92: the row runs y 88–109, 7 below the selector capsule (§2) | the same |
| Indentation | **14 per level** (judges: 16 or 24; neither) | 13 |
| Disclosure triangle | centred at x 18 + 14 × level; 9 wide when open (ink 14–22 at level 0) | x 14–22 at level 0 |
| Row icon | left edge at x 27 + 14 × level, about 14 wide (level 0: 27–41; level 1: 42–55; level 2: 56–69; level 3: 71–83) | 40–52 at level 1 |
| Label | starts at x 48 + 14 × level (48, 62, 76, 91), 6–7 after the icon | 58 at level 1, 71 at level 2 |
| Label colour (inactive) | #404041; the selected row #353536; triangle #737374 | — |
| Selected row | **band y 198–219 (22, the row itself), x 10–279: 10 from both edges of the area**; corners about 8; fill **#E7E7E8** on #F2F2F3 (window inactive, outline not focused). With the scroll bar's lane shown, the band ends at x 262, 13 before the lane. | **none drawn** |

Every level steps 14: the triangle, the icon and the label all move by
14 per level. `liquid-glass.md` §2.3 had the selection's corners at about
5; this capture's best circular fit is 8. The corner may be a continuous
curve; confirm at 2x in round 2.

### 12.2 Scroll bars

The session's Mac showed **layout-taking scroll bars** (the system's
legacy style, which depends on the "Show scroll bars" setting and the
pointing device). When the navigator's bar appeared, the outline's rows
narrowed by 17. Ycode's scroll bars were overlay-style on the same Mac,
so Ycode sets a style the system did not choose. **Use
`NSScroller.preferredScrollerStyle` and follow its change notification.**
Do not force overlay.

| Bar | Reference (legacy style) | Ycode |
|---|---|---|
| Navigator | lane at the area's trailing edge: track and knob both **11 wide** at x 276–286, 3 from the edge; track #DEDEDF, knob #ABABAC; the track runs y 83–832 (3 below the selector capsule, 11 above the filter capsule) | knob 8 wide at x 279–286, no track, rows not narrowed |
| Editor | a **17-point lane at the editor's right edge, right of the minimap** (x 1123–1139). Track and knob 11 wide at x 1126–1136; track #F3F3F3, knob #7A7A7A; the track runs y 86–839. The knob was 31 tall with the file at its top. | **between the text and the minimap** (x 1012–1019) |

The overlay style (thin knob, no track, hides when idle) is to measure in
round 2 with the setting on "When scrolling".

### 12.3 Jump bar and bottom bar

| Element | Reference | Ycode in the session |
|---|---|---|
| Jump bar band | y 52–83 (32), editor white | y 52–82, #ECECEC |
| Separator | **2 points**, #E5E5E5, y 84–85 | 1 point, #D4D4D4, y 83 |
| Text | ink y 60–72; inactive colour #BFBFBF | — |
| Bottom bar (880 window) | separator at y 843, bar y 844–879 (36) | the same height |

### 12.4 Inspector (answers §11 item 5)

There is no separate inspector spec. Content per file type is in
`reference-ui-5.md` §7; the image file's sections are in
`editor-area.md` §C.6.

| Element | Reference (260 wide) | Ycode in the session (265 wide) |
|---|---|---|
| Content insets | **7** from the divider (x 1148), **8** from the window's edge (x 1391): section rules, table, placeholder field | 12 / 12 |
| Section header | bold, at x 1147–1148. The first ("Identity and Type") has cap ink y 87–99, 7 below the tab capsule. Inactive colour #8C8C8D. | first header ink y 94–104, at x 1149 |
| Key column | right-aligned; ink ends at **x 1219** (inspector edge + 78). Labels #252525–#2B2B2B. | ends at x 1226 |
| Value column | controls from **x 1224** (5 after the keys) to x 1392 (7 from the edge); text inset 6 (x 1230) | from x 1236 |
| Text field (Name) | **22 tall** (y 110–131), **filled #E5E5E6, no border**, corners about 6 | white with a border |
| Pop-ups | **16 tall** (Type: y 137–152), filled **#E1E1E2** with no border, a black up-down chevron at x 1381–1387. Disabled: fill #E9E9EA, title #9C9C9D, chevron #A4A4A5. | white with an outline |
| Row pitch (baseline to baseline) | text field to pop-up **24**; pop-up to pop-up **22**; across a section rule **27** | about 22–23 throughout |
| Section rules | 1 point #DADADB, **6** below the control above and 6 above the next (y 158, 306, 426, 493, 638, 713, 833 in this file) | — |
| Multi-line values (Full Path, Working Copy, Relative Path) | **14-point** line pitch. Lines break after "/" and also after "-" inside a component ("Xcode-clean-room-re-" / "project/…"), and each line is filled first: Full Path took 6 lines. | breaks after almost every "/", 7 lines |
| Location | the disabled pop-up "**Relative to Group**", even for a file in a synchronized folder (`PBXFileSystemSynchronizedRootGroup`) | "Relative to Folder" |
| On Demand Resource Tags | a placeholder field x 1148–1391, y 457–480, fill #EAEAEB, "Only resources are taggable" | — |
| Target Membership | a **table box** x 1148–1391, y 520–629 (**110 tall** with its border); 1-point border #A6A6A7; the inside is the area's background. One row per target: a grey rounded-square target glyph, the name, and "Default" (grey) under it. Footer (y 610–628, 19 tall) under a #DEDEDF line at y 609: "+", "−" and a pencil, separated by thin vertical lines. | 52 tall, a checkbox per row |
| Text Settings with an EditorConfig file | see below | all controls enabled, no note |

**Text Settings and EditorConfig.** The test project sits inside a
repository whose root `.editorconfig` sets `indent_style = space`,
`indent_size = 4`, `charset = utf-8` and `end_of_line = lf`. The reference
found that file in an ancestor folder and took **only the indentation**
from it:

1. "Indent Using" (Spaces) and the Tab and Indent width fields (4, 4,
   each with a stepper, labelled "Tab" and "Indent" underneath) are
   **disabled**.
2. Under them sits the note **"Indentation settings provided by
   EditorConfig"**, in two lines at x 1226 (y 782–806), regular weight,
   #252525.
3. Text Encoding and Line Endings stay **enabled** (enabled fill, black
   chevrons), with grey titles (#949495): "No Explicit Encoding" and "No
   Explicit Line Endings". The file's `charset` and `end_of_line` did not
   set them.

Ycode must look for `.editorconfig` in the file's folder and its
ancestors, up to a file with `root = true`. When indentation comes from
one, it must disable those controls and show the note.

## 13. Council round 2 measurements (2026-11-04)

This is a dirty-room addition, like §12: the reference measured in the
round 2 captures (level 3). The window was 1400 × 880, **active (key)**,
light, at 1x. Conditions are in `liquid-glass.md` §8 and the checklist in
`fidelity-council.md` (round 2). Every §12 position that was measured
again is unchanged in the active window. Only colours change.

### 13.1 Navigator outline, active

| Element | Reference | Ycode in the session |
|---|---|---|
| Selected row (the open file, outline focused after the click) | band y 220–241 (**22**), x **10–279** (inset 10 on both sides), corners about 8, fill **#0070F5**; the label and the icon in it are **white** | not in any after-still. In the recordings the band appeared 248–519 ms after the click; in step 01 it vanished again 357 ms later |
| Labels | **#3B3B3C**, regular weight (mean ink darkness of a label 34) | black (#000000) and heavier (mean darkness 48) |
| Indentation | 14 per level (§12.1), also in plain groups | 14 (now matches) |
| Icon colour families | project and image badges blue (#006BEF); synchronized folders blue (#3FA1F6); **`PBXGroup`s a neutral grey filled folder (#7B7B80), even with a folder on disk**; Swift files orange (#F77640) | plain groups as a light-blue outline folder (#7DA8EE); Swift files as an orange "</>" glyph |

Ycode draws its own icons; only the colour family is the target.

### 13.2 Navigator scroll bar

The Mac showed the layout-taking (legacy) style in both apps.

1. **When content fits** (before the Models folder is expanded), there is
   **no scroll bar**.
2. **When content overflows** it appears at once and **stays**. It was
   still drawn 1 s after the scroll ended: no auto-hide under this setting.
   Gemini's "overlay, hidden until scrolled" does not match this Mac. The
   overlay style is to measure with the setting on "When scrolling".
3. **Geometry:**
   - The track is 11 wide at x 276–286 (3 from the area's edge), #DAD8DA.
   - It runs y **83–832**: 3 below the selector capsule (bottom y 80) and
     11 above the filter capsule (top y 843).
   - The knob is #A6A6A7, as wide as the track.
4. **Knob length** = track × (scroll view height ÷ document height). The
   scroll view is the **whole area height** (880), because the outline runs
   under both bars. Here 750 × 880 / 1507 = 438, measured 438 (y 83–520).
5. **Knob travel:** 432 points scrolled moved the knob 215, which is
   (750 − 438) / (1507 − 880) × 432.
6. **Ycode:** the same width and colours, but the track runs y **179–798**
   (620 tall): it starts 96 lower and ends 34 higher. So its knob was 363
   tall and sat 96 below the reference's at the top of the list.

### 13.3 Inspector, active

**Colours.**

| Element | Reference | Ycode |
|---|---|---|
| Section headings | bold, **#858587** (mean ink darkness 30): a light grey | **#393A3B** (48.8): darker |
| Labels | #252525–#2C2C2C | — |
| Name field fill | #E0E0E1 | #D5D5D6 |
| Pop-up fill | #DCDCDD; disabled #E5E5E6 | #D2D2D3 |
| Rules | #D6D6D7 | — |

**Row rhythm, top of the text ink (y).**

| Row | Reference | Ycode | Reference rule after the row |
|---|---|---|---|
| Name | 116 | 116 | — |
| Type | 140 | 137 (pop-up 137–152) | rule at 158 (Ycode: none) |
| Location | 167 | 159 | — |
| File name | 187 | 180 | — |
| Full Path, first line | 205; **the label is top-aligned** with it | 194; the label is centred on the block (234–246) | rule at 306 (Ycode: none) |
| Working Copy | 313 | 295 | — |
| Relative Path | 360 | 326 | rule at 426 (Ycode: 371) |
| On Demand Resource Tags heading | 434 | 384 | rule at 493 |
| Target Membership heading | 501 | 439 | — |
| Table | 520–629 | 454–563 | rule at 638 |
| Text Settings heading | **646** | **582** (64 ahead) | — |
| Text Encoding, Line Endings | 673, 695 | 600, 622 (pop-up tops) | **rule at 713** (Ycode: none) |
| Indent Using | 722 | 644 | — |
| Widths | 745 | 666 | — |
| EditorConfig note | 782 | 697 | — |

Ycode falls behind in three ways:
- it **leaves out the rules** after Type, Full Path, and Line Endings,
  together with their 6-point margins;
- it spaces its path lines from the file name by 14 instead of 18;
- it centres the Full Path label instead of top-aligning it.

Ycode's inspector is also 265 wide (divider at x 1135) against 260.

**Target Membership row.** The reference shows a grey rounded-square
target glyph, the name, and "Default" in grey below it. Ycode shows a
checkbox and no glyph.

**Widths row.** The reference has two disabled fields, values
right-aligned, each about 48 wide (x 1224–1272 and 1312–1361), with a
stepper after each. "Tab" and "Indent" are centred under them. Ycode
packs "4", a stepper, "4" and a stepper into about 70 points.

### 13.4 Welcome window

The Welcome window was captured over the workspace window, and its top
(the app icon) lies outside the frame. After its 160 ms appearance:

| Element | Reference | Ycode |
|---|---|---|
| App name | bold, cap ink 13 tall (y 110–122), 49 wide, #272727, centred over the list box | **26 tall, 95 wide**: about twice the size |
| Version line | #808080, ink 10 tall (y 132–141) | #808080 |
| Buttons Open…, Clone…, New Project | 36 tall (y 161–196), about 99 / 98 / 129 wide, 8 apart, spanning the list box's width | 103 / 103 / 126 |
| List box | x **520–862 (343)**, fill #F8F8F8 | x 520–879 (360) |
| Rows | **47-point pitch**. The selected row is y 221–267, x 528–854 (inset 8), #0064E1. Separators are 1 point, #DFDFDF, from x 576 (under the text, not the icon) to 848. Name #262626; path #7D7D7D. | one row; selected 529–870, #0064E1 |
| Path | **head-truncated**: the line starts with "…" and keeps the end, e.g. "…/captures/2026-11-04-council-r2-full/xcode/project". A path on another volume is shown from the volume's name, without "/Volumes". | the startup volume's name and the full path, **truncated in the middle** |

The list box measured 343 here, against 360 in `liquid-glass.md` §2.10,
and the rows 47 against 48. The whole window was not in the frame, so
this needs a capture of the entire Welcome window (**Retina capture
needed** for the 1-point differences).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Reference values in §1–§9 | 3 (in those specs) | `reference-ui-5.md`, `reference-ui-6.md`, `liquid-glass.md`, `workspace-window.md`, `device-hub.md`, as cited |
| Ycode values | — | `UISpacingProbeTests` frame dumps and `screencapture -l` captures of Ycode's own windows; `UISpacingTests` |
| The source-list padding depends on placement | — | Ycode's own outline in a plain window (10) and in the workspace window's sidebar item (0), measured with `rect(ofRow:)` |
| Form-label wrapping, side insets | 1 | Apple's Human Interface Guidelines (Layout; Sidebars) and AppKit documentation (`NSStackView`, `NSTextField`) |

| §12 council round 1 (reference values) | 3 | Council r1 1x stills and recordings of the reference: colour runs, glyph ink boxes, before/after differences (`research/tools/council-r1/measure_captures.py`, sections `navigator`, `inspector`; `research/notes/council-r1-2026-11-04.md`) |
| §13 council round 2 (reference values, active window) | 3 | Council r2 1x stills and recordings of the reference, foreground: colour runs, ink boxes, row matching; `research/tools/council-r2/measure_r2.py` (`navigator`, `welcome`); `research/notes/council-r2-2026-11-04.md` |
| §12.4 EditorConfig lookup rule | 1 | The EditorConfig specification (editorconfig.org: files are read from the file's folder upward until `root = true`) |

Level 5 was not used. Reference behavior was observed only for §12 and §13
(black box, from captures).
