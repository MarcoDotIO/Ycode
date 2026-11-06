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
| Settings sidebar | 179.5 wide + 0.5 divider, 32-point rows | the same (`settings.md` R3.2) | matches (`SettingsWindowR3Tests`) |
| Settings form | grouped cards x 200–690, rows 37.5, labels left at x 211, help text under them | the same (`settings.md` R3.3) | matches (`SettingsWindowR3Tests`) |
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

## 14. Layout on other macOS versions: the layout probe (beta 2, #24)

Ycode's spacing was tuned on macOS 27.2. To check it on other systems
without developer tools, Ycode.app has a **layout probe**: with
`YCODE_LAYOUT_PROBE=<out.json>` it opens a workspace window on the Demo
package (or `YCODE_LAYOUT_PROBE_PROJECT`) at 1400 × 900, a navigator alone
at 280 × 600 (as `NavigatorInspectorR45Tests` lays it out) and Device Hub
at 1100 × 800, lets each settle, writes every frame below in window points
(origin at the top left) with each value against its spec value, and
quits. `YCODE_LAYOUT_PROBE_SHOTS=<dir>` adds `cacheDisplay` snapshots (no
screen capture, so no privacy permission). The windows stay off screen as
in the tests (`YCODE_LAYOUT_PROBE_SHOW=1` orders them in; a screen smaller
than the window then shortens it, and the report says so). The probe uses
a preferences domain of its own and writes no window frames.

`LayoutProbe` (YcodeUI) does the measuring for the app and for
`LayoutProbeTests`, reading the same views as `UISpacingTests`,
`NavigatorInspectorR45Tests` and `LiquidGlassTests`, so the probe tells on
any system which of those checks would hold there. `scripts/layout-probe.sh
<local | ssh-target>` copies the app to a Mac, runs the probe in its GUI
session and fetches the report; `scripts/layout-probe-table.py` turns
reports into the tables of `docs/LAYOUT-PROBE.md`.

**Result, macOS 27.2 against 27.0** (both at 1x; a 2x run on 27.2 before the fixes agreed to half a point): 175
measures each. After the fixes below every measure meets its spec on both,
with the same values. Positions with no spec value differ by at most 1
point (backing-pixel rounding), except the toolbar's centre group.

| Element | Before on 27.0 | Cause | Fix |
|---|---|---|---|
| Activity icon | x 379 (27.2: 375); the reference x 385 | the system's gap before a view item: 8 points on 27.0, 4 on 27.2 | `ActivityView` pads its leading end so the icon sits 14 after Back \| Forward's control (`gapAfterNeighbor`): x 385 on both |
| Filter toggles (Debug navigator's first) | y 869, 1 point above the 16-point field (27.2 at 2x: 870.5) | a 15-point glyph centred on the field lands on a half point; a 1x screen rounds it out of the field | the toggles are 16 tall with their frame as their alignment rectangle (`NavigatorFilterToggle`): y 870 on both |
| Device Hub's Hide Sidebar circle | — | the probe kept the window off screen, so the first-appearance divider placement (sidebar 240) did not run | `DevicesController.placeFirstDividers()`, called on appearing and by the probe and the test; the circle ends 8 before x 240 on both |

**Deviation (no fix).** The centre group (New Conversation, the scheme
capsule) sits 3 points further right on 27.0: New Conversation x 588
against 585, the scheme 632 against 629. The flexible spaces around it
share out what the system's item gaps leave, and those gaps differ between
the versions. No spec gives the group's position for this window (the
reference's follows its activity title, `liquid-glass.md` §7.1 item 1), so
Ycode keeps the system's layout.

**Tests.** `UISpacingTests.hubSidebarGroupEndsAtTheSidebarEdge` and
`NavigatorInspectorR45Tests.filterOptionsAndTogglesSitInsideTheField` now
run on macOS 27.0 and later (they were limited to 27.2).

### 14.1 macOS 26.6 and 15.6 (beta 2, #24)

**Result** (both at 1x in virtual machines; numbers in
`docs/LAYOUT-PROBE.md`): on 26.6, 11 of 175 measures were out of spec
before and 1 after (Device Hub, below); on 15.6, 6 of 155 before and none of
150 after. 27.2 still meets all 175.

| Element | Before | Cause | Fix |
|---|---|---|---|
| Navigator on macOS 26 | x 8, y 8, 282 × 884: the selector, "+" and filter capsules 8 points in (x 14, 14, 50; bottoms 885) | macOS 26 draws a sidebar split item as a glass panel floating 8 points inside the window's leading, top and bottom edges (27 and 15 draw it flush) | On macOS 26 only, the navigator is a plain split item that behaves as a sidebar (collapses, holding priority 260), over the system's sidebar material (`.sidebar`, behind window), with a tracking separator of Ycode's over its divider (`FlushSidebar`). Its content reaches 1 point past the item over the divider, as the system's sidebar has no divider of its own; the item is 289 wide. Now x 0, 290 wide, and every capsule at its spec value |
| Run \| Stop on macOS 26 | x 225–286 (61 × 28) | the floating sidebar's toolbar section draws smaller items (28 tall) | the same: without the sidebar item the section is gone; Run \| Stop 208–281, Back \| Forward 298–371, the activity icon 385 |
| Inspector on macOS 15 | 259 wide | before macOS 26 the split's divider takes a point of its own; the inspector item starts after it | `applyDefaultLayout` moves the divider by what the inspector lacks: 260 |
| Variables bar's scope pop-up on macOS 15 | frame 2 points above the window's bottom | a small pop-up's frame reaches 2 points below its bezel there; the stack view centres the bezel (alignment rectangle) | none needed: the measure (probe and `debugAreaBottomBarsShareOneHeight`) now reads the drawn control, its alignment rectangle: 5 points on 15.6, 4 on 26 and 27 |

**Before macOS 26: glass-only measures.** The earlier layout draws none of
the capsules (`liquid-glass-ycode.md` §3) and keeps the earlier toolbar
(§2: bordered controls 40 tall at y 6 with the earlier segment widths, Run |
Stop 204–284, Back | Forward 297–377). No spec gives positions for that
design: §2 to §5 and `liquid-glass.md` describe the glass layout, and the
reference has no other. So the selector bar, its pill, the "+" circle, the
filter capsule, the inspector's tab bar and pill, and the toolbar's Run |
Stop, Back | Forward and activity-icon positions are measured with the glass
layout only ("-" on 15.6). What the specs do say of the earlier layout is
measured: the outline's first row 7 below the selector (§2, the clipped
layout), the 27-point debug bar (`liquid-glass-ycode.md` §4), the activity
icon 14 after Back | Forward, and the areas' widths.

**Deviation: Device Hub on macOS 26.** The hub keeps the system's sidebar
item, so on 26 its sidebar floats (x 8, 232 wide) and its toolbar section
draws Add Device, Filter and Hide Sidebar 28 tall; the circle ends 5
points before x 240 (spec 7 ± 1.5). The workspace's fix does not carry
over: the hub's window shows its title, which the toolbar places after the
sidebar's section, and with a plain item at the toolbar's leading end,
ahead of Add Device | Filter (measured on 27.2 with the plain item: Add
Device at x 260, the circle ending at 373, past the sidebar). It
needs the title moved into an item of its own; until then
`hubSidebarGroupEndsAtTheSidebarEdge` and `LayoutProbeTests.deviceHubMeasuresMeetTheSpec`
do not run on macOS 26. With a plain item and Ycode's own circle the
circle ended 10 points before the edge on 26 (8 on 27.2): the system leaves
2 more points before a tracking separator after an image item there.

**Tests.** `filterOptionsAndTogglesSitInsideTheField` runs on every
supported system (the probe met it on 27.2, 27.0, 26.6 and 15.6);
`hubSidebarGroupEndsAtTheSidebarEdge` everywhere except macOS 26.
`FlushSidebarTests` forces the plain navigator item on the system that
runs the tests and checks every workspace measure against its spec.

### 14.2 macOS 27.0 (beta 3, 2026-11-05)

The probe on macOS 27.0 (26A434, a virtual machine at 2x) and on 27.2 (1x)
met all 176 measures on both. It now also widens the Device Hub to 1100
points and counts the toolbar items in its overflow menu, once with a stopped
simulator selected and once with a booted foldable on a simulator host
(`hub.toolbar.overflowedAt1100`, `hub.booted.toolbar.overflowedAt1100`):
none on either system. The toolbar's items are within a point of each other
on the two systems. CI's macOS runner reported two overflowing items
because its 1024-point screen clamps the 1100-point window, not because of
the system version; `DeviceHubR3Tests` treats a clamped window as a known
issue.

## 15. Council round 3: the navigator's bottom bar (2026-11-05)

Measured from the round 3 captures (2x, foreground, editor at rest; points
are pixels ÷ 2, positions from the visible rim). The owner reported that
Ycode's "+" spacing looked uneven.

| Element | Reference | Ycode before | Now |
|---|---|---|---|
| "+" circle's contents | a "+" alone, about 10.5 × 10.5 | a "+" and a 7 × 4.5 down-chevron (the pull-down's arrow) | the "+" alone (`arrowPosition = .noArrow`) |
| "+" ink from the circle's rims | 9.0 from the left, 9.5 from the right; the glyph's centre 0.25 left of the circle's | 2.0 from the left, 6.5 after the chevron on the right | centred within 1 point |
| Filter capsule's options glyph | three lines inside a circle, 13 wide and 13 tall, ink from 7.5 to 20.0 | the lines without a circle, 11 wide, 6.5 tall, from 11.0 | the lines in a circle, ink from 7.5 (7.0 at 1x) |
| Its chevron | 6 × 3.5, 1.5 after the glyph, ending at 27.5 | 6 × 3.5, ending at 29.0 | 6 × 3.5, ending at 27.5 (27.0 at 1x) |
| Glyph and chevron colour | the secondary label colour (luminance about 120 of 255 on the light capsule) | primary (about 36) | secondary |
| "Filter" text's first ink | 33.5 | 37.5 | 33.5 |

Ycode's layout: the options pull-down draws its glyph itself from its
leading edge (`NavigatorOptionsButton`; a pull-down cell clips its image
to an area of its own), and its frame is its alignment rectangle; it sits
2.3 after the field's alignment rectangle, which starts 4 after the
capsule's. The field keeps 28 at its leading end
(`NavigatorAreaController.filterTextInset`). The Linux IDE draws the same
bar (`NavigatorFilterBar`): the "+" alone, the circled lines with the
chevron in the secondary colour, the text 34 in.

## 16. Council round 3: jump bar, inspector and Welcome offsets (2026-11-05)

Measured from the round 3 Retina stills of both apps (foreground, key
window, 1400 × 880, editor at rest on Long.swift; points are pixels ÷ 2).
Checklist rows 78–80 in `fidelity-council.md`.

### 16.1 Jump bar

| Element | Reference | Ycode now |
|---|---|---|
| Bar band | y 45–84, a 1.5-point separator #E5E5E5 at 84 | the same (separator 2 points) |
| Path text ink | **y 59.5–72.5** (centred on y 66) | y 62.5–75: **2.75 lower** |
| Path start (grid button's ink) | x 310 | x 314.5 |

Move the path's text and icons up 2.75 so they centre on y 66, the bar's
centre less 0.5.

### 16.2 File inspector, top rows

Ink tops of the labels and headings in the file inspector (Long.swift):

| Row | Reference | Ycode now | Difference |
|---|---|---|---|
| "Identity and Type" heading | **90.0** | 93.5 | +3.5 |
| Name | 117.0 | 117.0 | 0 |
| Type | 140.5 | 140.5 | 0 |
| Location | **168.5** | 175.5 | +7.0 |
| The file name above Full Path | 188.0 | 194.0 | +6.0 |
| Full Path (first line) | 206.0 | 212.0 | +6.0 |
| "On Demand Resource Tags" heading | **267.0** | 277.0 | +10.0 |
| "Target Membership" heading | **334.0** | 331.5 | −2.5 |

So: the first heading sits 3.5 too low; the gap between Type and Location
is 7 too large (the rule after Type plus its 6-point spacing, §13.3, is
28 from Type's ink to Location's in the reference: 140.5 → 168.5); the
tags heading 4 too low beyond that; and the Target Membership heading
2.5 too high, since Ycode's tags box is shorter. Target Membership shows
the target's app icon in the reference (a rounded-square icon left of the
target's name and "Default") where Ycode draws an empty checkbox.

### 16.3 Welcome window

The Welcome window was captured over the workspace window, at slightly
different window positions in the two apps, so positions are given
relative to the app name.

| Element | Reference | Ycode now |
|---|---|---|
| App icon | **98 × 98** | 90 × 90 |
| Icon's bottom to the name's cap top | **15.5** | 44 |
| Icon's top to the name's cap top | **113.5** | 134 |
| Name's cap top to the buttons' top | 50.5 | 49 |
| Buttons' ink height | 28.5 | 36 |

Ycode's icon sits about 26.5 points higher than the reference's relative
to the window, and its name about 6 points higher. Put the icon 15.5
above the name's cap top and draw it at 98 points.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Reference values in §1–§9 | 3 (in those specs) | `reference-ui-5.md`, `reference-ui-6.md`, `liquid-glass.md`, `workspace-window.md`, `device-hub.md`, as cited |
| Ycode values | — | `UISpacingProbeTests` frame dumps and `screencapture -l` captures of Ycode's own windows; `UISpacingTests` |
| The source-list padding depends on placement | — | Ycode's own outline in a plain window (10) and in the workspace window's sidebar item (0), measured with `rect(ofRow:)` |
| Form-label wrapping, side insets | 1 | Apple's Human Interface Guidelines (Layout; Sidebars) and AppKit documentation (`NSStackView`, `NSTextField`) |

| §12 council round 1 (reference values) | 3 | Council r1 1x stills and recordings of the reference: colour runs, glyph ink boxes, before/after differences (`research/tools/council-r1/measure_captures.py`, sections `navigator`, `inspector`; `research/notes/council-r1-2026-11-04.md`) |
| §13 council round 2 (reference values, active window) | 3 | Council r2 1x stills and recordings of the reference, foreground: colour runs, ink boxes, row matching; `research/tools/council-r2/measure_r2.py` (`navigator`, `welcome`); `research/notes/council-r2-2026-11-04.md` |
| §14 Ycode on macOS 27.0 and 27.2 | — | The layout probe's reports of Ycode's own windows (`scripts/layout-probe.sh`); no reference observed |
| §15 the navigator's bottom bar: the "+" circle's contents and the options glyph | 3 | Council round 3 captures of the reference and Ycode (2x, foreground), measured by the dirty room; prose only |
| §16 round 3: jump bar text offset, file-inspector row offsets, Welcome icon size and position | 3 | Council round 3 Retina stills of both apps (steps 02 and 18), ink boxes and colour runs measured in the dirty room; prose only |
| §14.1 Ycode on macOS 26.6 and 15.6; the floating sidebar of macOS 26 | — | The layout probe's reports of Ycode's own windows, and a minimal AppKit window of our own (sidebar item against plain item, both separators) on 27.2 and 26.6; no reference observed |
| §14.1 split items, tracking separators, alignment rectangles | 1 | AppKit documentation and SDK headers (`NSSplitViewItem`, `NSTrackingSeparatorToolbarItem`, `NSSplitViewController`, `NSView.alignmentRect(forFrame:)`) |
| §12.4 EditorConfig lookup rule | 1 | The EditorConfig specification (editorconfig.org: files are read from the file's folder upward until `root = true`) |

Level 5 was not used. Reference behavior was observed only for §12 and §13
(black box, from captures).
