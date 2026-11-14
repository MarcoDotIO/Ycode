# Merge workflow and the conflict sheet

**Status:** boundary spec (council round 3, 2026-11-05). It tells a clean
implementer how the reference starts a merge from the Source Control
navigator and how its merge sheet looks and behaves, so that Ycode's
conflict editor (`comparison.md`, "Ycode implementation") can be rebuilt
to match. Reference: Xcode 27.1 (27A9269) on macOS 27.2, light appearance,
window key. The checklist rows are in `fidelity-council.md` (round 3, rows
52–61). The git side of a merge (stages, labels, `add` on resolve) stays
as `source-control.md` describes it.

**Conditions.** One capture session: a 1400 × 880 window, the navigator
290 wide, the Source Control navigator's Repositories view, a test
repository with branches `main` (current) and `feature`, and one file
(`Greeting.swift`, 19 lines) with two conflicting changes and one change
that merges cleanly. Retina stills (values in points, half-point
precision) and 120 fps recordings. Positions are in window coordinates
(origin at the window's top-left), unless a row says "from the pane's left
edge".

**Rules for the implementer.** Labels in quotation marks are exact.
Symbols are described in words; Ycode draws its own (AGENTS.md rule 5).
Colours are sRGB hex values measured from fully covered pixels.

## 1. Starting the merge

### 1.1 The branch row's context menu

Control-click (secondary click) on a branch that is **not** the current
one, in Repositories ▸ Branches. The row gets the context-click ring (a
2-point accent outline around the row's rounded selection shape) while
the menu is open. The menu opens in **one frame** (no animation) with its
top-left corner at the pointer.

| # | Item | Enabled here |
|---|---|---|
| 1 | Switch to “feature”… | yes |
| 2 | New Branch from “feature”… | yes |
| 3 | Rename “feature”… | yes |
| 4 | Tag “feature”… | yes |
| — | separator | |
| 5 | Merge “feature” into “main”… | **yes** |
| 6 | Merge “main” into “feature”… | no (the other branch is not checked out) |
| — | separator | |
| 7 | New “project” Remote… | no (no hosting account) |
| 8 | Add Existing Remote… | no |
| — | separator | |
| 9 | View on Host… | no (no remote) |
| — | separator | |
| 10 | Apply Stashed Changes… | no (no stash) |
| 11 | Export Stashed Changes as Patch File… | no |
| — | separator | |
| 12 | Delete… | yes |

The names are the clicked branch and the current branch, in curly
quotes; "project" is the repository's name. Ycode's own row menu
(`source-control.md`, `SourceControlRowMenu`) has a different item set and
order ("Check Out", Rebase and Push items): the reference's set above
replaces it for a local branch row.

Menu metrics: 272 wide, 353 tall for 12 items and 5 separators. Items on
a **24-point pitch**; a separator is an 11-point gap holding a 1-point
rule (#E5E5E5) inset 16.5 from each side. Text starts 16.5 from the
menu's left edge; enabled text #262626, disabled text about #A0A0A0. The
menu is light glass (#FDFEFF over white content) with large corners and a
soft shadow (`liquid-glass.md` §2.8 for popovers).

Choosing an item: the highlight blinks once, then the menu fades out over
about 170 ms (frames at +0 to +170 ms in the recording); the alert appears
about 210 ms after the menu is gone.

### 1.2 The confirmation alert

A window-modal alert centred on the workspace window (not hung from the
toolbar). Measured: **420 × 133**, centred horizontally and vertically in
the 1400 × 880 window (x 490–910.5, y 373–506), white, corner radius about
16, with a soft drop shadow.

| Part | Value |
|---|---|
| Icon | the application's icon, 55 × 55, its top-left at (28.5, 22) inside the alert. Ycode shows its own icon. |
| Title | bold, #262626, starting 106 from the alert's left edge (22.5 after the icon), first cap top 20 below the alert's top; wraps to two lines at the alert's inner width. Text: Are you sure you want to merge from “<branch>”? |
| Message | regular, black, 2 lines, starting 59.5 below the alert's top, same left edge as the title. Text: Changes from “<branch>” will be merged into your current branch (“<current>”). |
| Buttons | right-aligned, 20 tall, bottom row at y 468–488 (18 above the alert's bottom edge): **Cancel** (58 wide, fill #EDEDED, text #232323) then **Merge** (79 wide, accent fill #007AFF, white text), 14.5 apart, the Merge button's right edge 20.5 inside the alert's right edge |
| Default | **Merge** (accent-filled, Return). Cancel answers Escape. |

Merge's accent fill appears only once the alert has finished appearing;
during its first frames both buttons are drawn grey.

**Appearing.** The window behind is veiled and the alert comes in
together. The veil darkens white content from #FFFFFF to **#CDCDCD**
(20 % toward black; the navigator's #EDEDEE becomes about #C6C6C7) over
**about 255 ms**, ease-out. The alert itself is fully drawn within 2
frames (17–33 ms) of the start. The judges' "288 ms ease-out" is this
segment: the alert and the veil, not the merge sheet.

**Clicking Merge.** The alert fades out over about 90 ms while the merge
sheet comes in (§10).

## 2. The merge sheet: frame, insets, veil

| Element | Value (1400 × 880 window) |
|---|---|
| Sheet frame | x **24–1376** (24 from each side of the window), top at **y 52.5**, the toolbar's bottom edge. Its bottom lies **below the window's bottom edge** in this window (the 880-point capture cuts the button row): see Open questions. |
| Sheet look | white, corner radius **about 16** (measured on the top-left corner), soft shadow; no title |
| Veil over the window | as for the alert: white content #CDCDCD, toolbar band #CCCCCC, navigator #C5C5C6. The veil covers the whole window, toolbar included. |
| Content box | one bordered box, **x 44–1356, y 64–846** (20 inside the sheet's sides, 11.5 below its top), 1-point border #BFBFBF, square corners |
| Button row | below the box: §9 |

Inside the box, left to right: the file list (§3), the left pane (§4),
the centre gutter (§5), the right pane (§4). One jump bar spans both panes
and the gutter (§4.1); one footer row spans them too (§8).

| Column | x | Width |
|---|---|---|
| File list | 45–243 | 198, then a 1-point divider #D7D7D7 at 243 |
| Left pane | 244–767 | 523 |
| Gutter | 768–814 | 46 between two 1-point rules #D7D7D7 at 767 and 814 |
| Right pane | 815–1355 | 540: 523 of text plus a 17-point overview ruler (§4.4) |

## 3. The file list

| Part | Value |
|---|---|
| Header band | y 65–92 (27 tall), white, a 1-point rule #E5E5E5 below it |
| View control | two segments **"Hierarchical" \| "Flat"**, centred in the band: x 86.5–161 for the selected segment, y 70–87 (17 tall). Selected: a pill filled #D1E7FF with the label in the accent colour (#007AFF); unselected: no fill, label #272727. Default: Hierarchical. |
| Rows | 24 tall from y 93: a disclosure triangle (x 45–60), then a folder row for the project's group ("Merger", a blue folder symbol) and, indented one level, the conflicted file |
| File row | the file-type symbol (x 76.5–91), the name with its extension ("Greeting.swift") from x 97.5 |
| Selection | **full width, flush** (x 45–243, no inset, square ends), fill **#0064E1** while the list has focus; white name and symbol |
| Conflict badge | a white rounded square about 12 × 12 at x 223–235 (8 from the list's right edge), with a red letter "C" (#FF383C) |
| Filter | at the bottom of the list: a field x 50.5–237.5, y 821.5–842.5 (21 tall), fill #F3F3F3, a filter symbol (circle with lines) at x 55–68 and the placeholder "Filter" from x 72.5 in #7A7A7A |

Selecting a file shows it in the panes. "Loading…" is shown in the list,
and "No Editor" in the pane area, until the first file is selected (about
4 s in the recording, under heavy load).

## 4. The two panes

### 4.1 Jump bar

One bar for the comparison: **y 65–101** (36 tall), white, a 1-point rule
#E5E5E5 below. Items from the left pane's edge: a grid symbol (x 257–270),
a 1-point divider (279), back and forward chevrons (288.5–295, 308–314.5),
then the path: project symbol and "Merger" › blue folder symbol and
"Merger" › Swift symbol and "Greeting" › "No Selection". Chevron
separators are about 3 wide, 6–7 from their neighbours. At the right
end, over the right pane: a conflict navigator — a back chevron
(1299.5–1306.5), a red circle with a white cross (1314.5–1325.5), a
forward chevron (1333–1339.5) — ending 16 before the box's right edge.

### 4.2 Text

Both panes are ordinary source views in the editor's font and theme
(`editor-area.md` C.1, D.1): **8.0** per character, **18** per line, the
default light theme's syntax colours (keywords #C4246E and so on). The
**left pane is the current branch's version with the clean change already
applied** (here line 17); the right pane is the incoming branch's version.

| Measure, from the pane's left edge | Left pane | Right pane |
|---|---|---|
| Line numbers, right-aligned, ending at | +26 to +28 | +26 to +28 |
| Code column 0 | **+41** | +41 |
| Line-number colour | #B7B2B4; the current line's number #322529 | the same |
| Current-line highlight | a rounded rectangle #EEEEED from +8 to the text's right edge −8 (507 wide here), covering every wrapped visual line of the line | the same |
| First line's top | y 110 (8 below the jump bar's rule) | y 110 |

Line 1 is a long comment that wraps: its continuation starts 4 columns
past the line's indentation, as in the editor.

### 4.3 Alignment

The panes scroll together and **corresponding lines share the same y**.
Here both versions have 19 lines and every change is one line, so line n
sits at the same y in both panes. How blocks of different lengths are
aligned (padding rows on the shorter side, or not) is not shown by these
captures (Open questions).

### 4.4 Overview ruler

The right pane ends in a 17-point strip (x 1338–1355), white, which maps
the whole file onto the pane's height (y 102–818). Each change is a
1-point mark 10 wide (x 1340–1350) at its proportional position: conflicts
#FDB9B5, the clean change #D4D4D4. The left pane has no ruler.

## 5. The centre gutter and its tokens

| Part | Value |
|---|---|
| Gutter | 46 wide (x 768–814), fill **#F5F5F4**, 1-point rules #D7D7D7 on both sides, full height from the jump bar's rule to the footer's rule |
| Shading | a changed row's shading (§6) continues across the gutter, blended over its grey: conflicts **#F9D5D5**, the clean change **#D1E4F8**; the selected change's two red rules cross it too |
| Token | one per change, on the change's first row: a **capsule 38.5 × 14** (x 771.5–810, so 3.5 from the left rule and 4 from the right), vertically centred in the 18-point row |
| Token fill | unselected **#575757**; the selected change **#6D2A2D** with a red rim (#DA5559) |
| Token contents | a white glyph left of centre (ink about x 786–800, about 12 tall), then a white down-chevron about 6 × 3.5 (x 802–808) |
| Glyph | **"?"** for a conflict with no choice yet; a **digit** once a choice is in effect: "3" on the clean change, "1" after Choose Right (§7) |
| Chevron circle | when a choice is in effect, the chevron sits in a filled circle about 11 across (x 798–809): **#6B6C6B** on a grey token, **#FF6569** on the selected red token; an undecided "?" token has no circle |

Clicking a token opens the Choose menu (§7) and selects that change.

## 6. Row shading

Shading is **full width**: it runs from the pane's left edge (including
the line-number column) to the pane's text edge (the left pane to 767,
the right pane to 1338, stopping at the ruler), and through the gutter.
It is **one row tall per line** (18), with no gap between adjacent rows.

| Change | Fill | Rules | Changed words |
|---|---|---|---|
| Conflict, not selected | **#FFDCDD** both panes | none | **#FF9A9D** behind each changed word, the row's full height less 1 at top and bottom (16 tall), square corners, character-exact (whole cells of 8.0), spaces between words not filled |
| Conflict, selected (the stepper's current change) | #FFDCDD | a **1-point rule #DA5559** on the row's top and bottom edges, across both panes and the gutter; **#FF656A** once a choice has been made for it | as above |
| Change that merges cleanly | **#D6EBFE** both panes | none | none seen |

Text keeps its syntax colours over the shading. The panes never show git
conflict markers.

## 7. The Choose menu

| # | Item |
|---|---|
| 1 | Choose Left |
| 2 | Choose Right |
| — | separator |
| 3 | Choose Left Then Right |
| 4 | Choose Right Then Left |

- Opens in one frame below the token: its top-left about at the token's
  horizontal centre and 3 below the token's bottom edge (x 792.5,
  y 281 for the token at y 274–287). Measured size about 174 × 115.
  Items in regular weight, #262626; the hovered item is an accent-filled
  rounded bar with white text, inset about 5 from the menu's sides.
- **Effect.** The chosen side's text replaces the **left pane's** lines
  for that change; the right pane does not change. Choose Left keeps the
  left text; Choose Right copies the right text; the two "Then" items
  put both sides' lines in the stated order (expected from the labels;
  only Choose Right was captured).
- **The change stays selected** and in view; the stepper still reads
  "1/3". The token's glyph turns from "?" to a digit and gains the
  chevron circle; the selected rules turn #FF656A. The shading stays.
  Captured detail: the left pane's word fills stayed at the old word
  positions (cells 1–4 and 6–12 of the string) over the new text.
- **Timing.** From the click on the item: the item blinks (two frames
  in the first 40 ms), the menu holds for about 90 ms, then fades out
  with an ease-in-out curve; the whole dismissal is **330 ms**. Progress
  of the fade (share of time → share of change): 0.40 → 0.11,
  0.48 → 0.28, 0.56 → 0.37, 0.60 → 0.54, 0.65 → 0.67, 0.70 → 0.78,
  0.75 → 0.82, 0.80 → 0.89, 0.87 → 0.94, 0.92 → 0.97, 1.0 → 1.0. **The
  pane text then changes in one frame, about 117 ms after the menu has
  gone.** There is no animation of the text or the shading.

## 8. Footers and the change stepper

One row under both panes: y 819–846 (27 tall), white, a 1-point rule
#E6E6E6 above. Text about 12 points, #262626.

| Part | Position | Contents |
|---|---|---|
| Left footer | from x 253.5 (9.5 from the pane's edge) | a clock symbol, the repository name ("project") › a branch symbol and the branch ("main") › a commit symbol, the commit's short date ("1/3/26"), author ("Capture Test"), short hash and "(HEAD)" |
| Stepper | centred on the gutter (x 760.5–820.5) | a back chevron, "**n/m**" (the current change and the count of changes, conflicts and clean changes together: "1/3"), a forward chevron |
| Right footer | from x 836.5 | the same three parts for the incoming side: repository › branch › date, author, short hash |

The stepper's chevrons move the selection to the previous or next change
and scroll it into view.

## 9. Cancel and Merge

Below the content box, right-aligned with it: **Cancel** (x 1176–1260,
84 wide, fill #EDEDED, text #252525) and **Merge** (x 1272–1356, 84 wide,
its right edge on the box's right edge), 12 apart, tops at y 867.5
(21.5 below the box). With a conflict still undecided, **Merge is
disabled** (fill #F5F5F5, grey text #B6B6B6). Their height and the
sheet's bottom margin are below the captured window (Open questions).

Cancel closes the sheet and leaves the repository unmerged. Merge
(enabled once every conflict has a choice) writes the merged files and
completes the merge (`source-control.md`: `add`, then the merge commit);
what the window shows afterwards was not captured.

## 10. Appear and disappear

**Appear** (after Merge in the alert): the alert fades out (about 90 ms)
while the sheet fades in and **slides down from under the toolbar**:
- opacity 0 → 1 over the first **about 90 ms**;
- its top edge travels **from about y 20 to y 52.5 (32 points)** over
  **about 200 ms**, nearly linear with a soft ease-out at the end;
- the veil deepens slightly in the same frames.

| Time from the first frame | Top edge (y) | Opacity |
|---|---|---|
| 0 ms | about 22 | 0.3 |
| 25 ms | 26 | 0.6 |
| 50 ms | 30 | 0.75 |
| 67 ms | 34 | 0.9 |
| 92 ms | 38 | 1.0 |
| 108 ms | 42 | 1.0 |
| 133 ms | 45 | 1.0 |
| 158 ms | 48 | 1.0 |
| 187 ms | 51 | 1.0 |
| 245 ms | 52.5 (rest) | 1.0 |

**Disappear:** not captured (Cancel and Merge were not clicked). Ycode
should reverse the appear transition until it is measured.

## 11. What Ycode did at round 3 (`0c3ae33f`; replaced by §12)

- No way to start a merge in the UI: branch rows in the Source Control
  navigator have no context menu on macOS (the row menu is attached only
  to other navigator indexes), and Integrate has no Merge item.
- After an outside `git merge`, Integrate ▸ Resolve Conflicts… opens an
  in-window editor: "Conflicts in Greeting.swift" with Mark as Resolved,
  Continue Merge and Abort Merge; left and right panes above a Result pane
  that shows git conflict markers; two segmented choice bars.
- Shading stops at the end of the text: pink on the left, green
  (#DDF5DD) on the right; no syntax colour; connector shapes between the
  panes; the left pane has 17 lines and the right 18, so lines do not
  line up.
- Choosing "Right" changes the Result pane within 50 ms, does not update
  the left pane, and moves to "Change 2 of 3".
- The editor appears in one frame.

## 12. Ycode implementation (B3-MERGE, 2026-11-05)

Both IDEs draw one shared model, so they behave the same:
`YcodeIDECore/SourceControl/MergeSheet.swift` (`MergeSheetMetrics`: every
length above; `MergeSheetPalette`: the colours above, light, and a dark
set; `MergeSheetMotion`; `MergeSheetText`; `MergeSheetToken`;
`MergeSheetLayout`: aligned rows, changed words, wrapping, highlighting;
`MergeSheetFooter`), `ConflictEditorState+Sheet.swift` (each file keeps
its choices while another is shown, Choose keeping the selection, the
tokens, the stepper, the ruler marks, the file list, Merge's enablement)
and `SourceControlRowMenu` (§1.1's items for a local branch).

- **macOS** (`YcodeUI/SourceControl/`): `MergeOverlayView` is the window
  frame's top view, so the veil covers the toolbar and the window stays
  key; `MergeAlertView` (§1.2), `MergeSheetController` with
  `MergeCanvasView` (both panes and the gutter in one scroll view),
  `MergeRulerView`, the file list, jump bar and footer views;
  `SourceControlCoordinator+Merge.swift` runs the flow. The Source
  Control navigator's rows now have their context menu. Alert and sheet
  are drawn by Ycode (no system sheet), so the geometry and motion are
  exact; the Choose menu is a native menu (its dismissal is the
  system's).
- **Linux** (`ycode-ide/MergeOverlay.swift`, `MergeAlertCard.swift`,
  `MergeSheetView.swift`, `MergeComparisonView.swift`; the model is
  `YcodeIDEShell/ConflictEditorShellModel.swift`): the same flow over the
  window's content. The in-window conflict editor of #75 is gone.
- **Flow.** The branch row's "Merge “b” into “c”…" (or Integrate ▸
  Merge…) shows the alert; Merge fades it out over 90 ms and runs `git
  merge`; a merge that completes clears the veil; conflicts (of a merge,
  rebase, cherry-pick, pull or stash apply) show the sheet. Mark as
  Resolved (the change row's item, Integrate, the file list's context
  menu), Integrate ▸ Continue and Abort and the Linux banner still work
  with the sheet up.

Ycode's choices for the open questions (each marked so a later round
can measure it):

| Question | Ycode's choice, open question |
|---|---|
| 1. Height and bottom margin | The sheet follows the window: its bottom is 24 above the window's (the side inset). The buttons sit 21.5 below the box with an 18-point margin below them. At 1x the box's 11.5 rounds to whole pixels. |
| 2. Button height; Merge as default | 24 tall. Merge is drawn as the default (accent) button once it is enabled; disabled it is #F5F5F5 with #B6B6B6. A stopped rebase, cherry-pick or revert titles it "Continue Rebase" (…), a stash apply "Resolve"; the button widens to its title. |
| 3. After Merge and Cancel; closing | Merge writes and stages every file (`add`), then completes the operation (`commit --no-edit` for a merge; a rebase continues and may stop again, and the sheet re-reads) and closes. Cancel, while an operation is stopped, asks "Abort the merge?" (Abort, Cancel) and aborts it; otherwise it only closes. Closing reverses the opening: fade over 90 ms and slide up 32 points over 200 ms, the veil clearing over 255 ms. |
| 4. Token glyphs | "?" undecided; Choose Right "1"; Choose Left "2"; a change taken automatically "3"; Left Then Right "4"; Right Then Left "5"; the ancestor "6"; written by hand "7". The chevron sits in its circle whenever a choice is in effect (open question 9 read as a state). |
| 5. Blocks of different lengths | The shorter side is padded with empty rows, so every row lines up; padding rows carry the change's shading and no line number. |
| 6. Word fills after a choice | They stay at the cells of the original sides' words, as captured. |
| 7. Other menus; Integrate ▸ Merge | The current branch's row: Switch (disabled), New Branch from, Rename, Tag — the remote group with Pull and Push when there is a remote — View on Host — the stash items — Delete (disabled); no merge group. Remote branch, tag and stash rows keep Ycode's menus (`source-control.md`). Integrate ▸ **Merge…** follows Cherry-Pick…: the alert for the branch selected in the navigator (else the first other branch), with a pop-up of the local branches below the message (the alert is 30 taller). "View on Host…" opens the first remote with a web address at `/tree/<branch>`; the stash items act on the newest stash; "New “repo” Remote…" stays disabled (no hosting integration) and "Add Existing Remote…" is disabled on branch rows as captured (it stays on the repository row and the Remotes group). |
| 8. Flat mode, several files | Flat lists the conflicted files without folders; Hierarchical groups them under one folder row per directory. Each file keeps its choices while another is shown; Merge needs every file decided. |
| Current line | Line 1 of each pane until a line is clicked. |
| Hand editing | Double-clicking a change's left lines opens an editor over that change's rows (Edit's text: both sides for an undecided conflict); its token reads "7". |
| Motion curve | The slide uses the timing curve (0.4, 0.3, 0.6, 1.0), within 2.5 points of every keyframe of §10. Reduce Motion: the sheet fades only. |
| Dark appearance | `MergeSheetPalette.dark` (the same roles on dark surfaces; the veil black at 32 %). |
| Linux | The menu bar is part of the window there: the veil leaves it uncovered (so Integrate stays usable) and the alert is centred below it. The Choose menu opens at the token's left edge, where the toolkit places menus, and closes as the toolkit's menus close. |

Tests: `YcodeIDECoreTests/MergeSheetTests.swift` (geometry against §2,
alignment and padding, changed words, Choose, tokens, files, wrapping,
the motion against §10's keyframes) and `ThreeWayMergeTests.swift`
(§1.1's menu); `YcodeUITests/MergeSheetUITests.swift` (the row menu and
its enablement, the alert's frame, texts, buttons, veil and keys,
Integrate ▸ Merge…, the sheet's frame and columns, token sizes, shading,
rule and token colours read back from the window's pixels in light and
dark, the Choose menu and its effect, the animations and Reduce Motion;
`YCODE_MERGE_SHOTS=<folder>` writes snapshots) and
`SourceControlBranchWorkflowTests.swift` (a merge through Choose, hand
editing and Merge; Mark as Resolved then Continue; Cancel aborting; a
rebase aborted from Integrate); `YcodeIDEShellTests/ConflictEditorShellTests.swift`
on Linux. End to end on Linux: `scripts/linux-conflict/run.sh`
(`YCODE_IDE_CONFLICT`, `ShellDriver+Conflicts.swift`; `OV_COLOR_SCHEME`
picks light or dark): the branch menu through the pointer, the alert,
the sheet, Choose through tokens and the menu, hand editing, Merge, a
cherry-pick through the sheet and a rebase cancelled and aborted, then
checked with git.

## 13. Council round 4: modal state, sheet height, dark colours (2026-11-06)

Round 4 repeated the session in the **dark appearance** with Ycode
`45c676aa`, whose merge now runs through its own UI (row menu, alert,
sheet). The alert matches: about 417 × 132 against the reference's 418 ×
131, the same centre and wrap, buttons within 1 point; the sheet's
entrance 267 ms against 275 ms, both ease-out; Choose Right's result and
timing match (408 ms against 428 ms). Values in window points of the
1400 × 880 window, from the stills `02-merge-start-alert`,
`03-conflict-at-rest` and the recording `04-conflict-choose-right`.
Checklist rows 97–103 in `fidelity-council.md`.

### 13.1 The parent window behind the alert and the sheet

The same regions of the window, in its normal state (the Repositories
view before the merge), behind the alert, and behind the sheet:

| Region | Reference: normal → alert → sheet | Ycode now: normal → alert → sheet |
|---|---|---|
| Editor background (empty) | #252525 → **#1A1A1A** (×0.70) | #1E1E1E → #141414 (×0.67) |
| Navigator background | #28292A → **#1C1C1D** → #1C1C1D | #242527 → #18191A → #151617–#171818 |
| Navigator text ("Branches", "Remotes") | #E9E9E9 → **#666767** (×0.44) | #E9E9E9 → #9E9E9E (×0.68) |
| Window title ("Merger") | #FFFFFF → **#6F6F70** → #6F6F70 | #DDDDDD → #969696 → #8D8D8D |
| Run button glyph | #FFFFFF → **#3B3B3C** → #3B3B3C (×0.23) | #FFFFFF → #ADADAD → #A3A3A3 |
| Scheme text | #E3E3E3 → **#646565** → #646565 | #E2E2E2 → #999999 → #8F8F8F |
| Filter field text | #ABABAC → **#4E4E50** | #A0A1A2 → #6D6D6E |
| Inspector placeholder | #757677 → **#3A3A3A** | #717274 → #4D4D4F |
| The context menu's target row (`feature`) behind the alert | **not highlighted** (navigator background) | still highlighted (#2C2D2E on #18191A) |
| Window buttons behind the sheet | **close grey (#4D4E4F, disabled); minimize #FBB900 and zoom #0DBE00 at full colour**, drawn above the veil | all three veiled: #9F3834, #A07700, #087800 |

Behind the alert both apps draw the same system indicator over the window
buttons (a capsule, x 16–82, #9B9CFF), so the alert still does not
compare the buttons; the sheet still does.

**Rule (target).** While a window-modal alert or sheet is up, the parent
window:
1. draws as **inactive and disabled**: its text takes its disabled tone
   (about 0.63 of its value) and its toolbar buttons their disabled tone
   (about 0.33) **before** the veil;
2. is veiled to about **0.70** (Ycode's veil depth is right);
3. drops transient highlights, such as the row a context menu was
   opened on;
4. disables the close button only (grey) and draws the window buttons
   above the veil, minimize and zoom in full colour.

### 13.2 Alert buttons are accessibility elements (behavioural requirement)

*Rewritten in council round 5 (2026-11-06); checklist rows 98 and 130.*

**What happened.** In round 4 the capture found Ycode's alert as an
accessibility sheet holding two static texts and no buttons, and pressed
Return instead. B4-MERGE then made the buttons accessible and tested them
by walking accessibility children **inside the app, starting at the
window's frame view**. Round 5's script was not changed: it still pressed
Return for Ycode and carried round 4's note, so **round 5 did not test
Ycode's alert through accessibility at all**; the judges' finding repeats
the note. Row 98 is therefore unverified, not failed. The requirement
below is the path the capture's driver follows from outside the app;
Ycode's own test must follow the same path.

**The path the driver follows** (the capture tool's accessibility
driver, used for the reference's Merge):

1. It starts at the **application element** for the app's process (the
   accessibility element created from the process ID), with a messaging
   timeout of 3 seconds per request. For this press the script asks for
   the whole app, not one window.
2. It walks **breadth first through the children attribute only**
   (`AXChildren`), to a depth of 40 and at most 30,000 elements. It does
   not read the windows, main window, focused window or sheets
   attributes during the search. So the alert must be reachable as
   application → window → … → alert → button through children alone.
3. At each element it reads the **role** and, for this match, the
   **title** attribute (`AXTitle`) only. The match is exact, ignoring
   case, with "..." read as "…". The description, value and help
   attributes are not consulted for a title match. A button whose name is
   only in its description or value is **not found**.
4. The first match in breadth-first order (the shallowest) wins. The
   driver performs the **press action** (`AXPress`) on it and requires the
   call to return success. A press on the reference's alert returned
   after about 0.53 seconds; the call must return within the 3-second
   timeout.
5. For a click (rather than a press) on a matched element, the driver
   uses the element's position and size attributes for the centre, then,
   in the foreground, checks that the system-wide hit test at that point
   returns an element of the same process before it posts the click.

**What the reference exposed** (round 5 press result): an element with
role **button**, title **"Merge"**, an automatic identifier, the press
action, and a frame **82 × 22** at window (809, 467) in the 1400 × 880
window. The full tree of the reference's alert (sheet role and subrole,
the static texts, the default and cancel button attributes) was **not
recorded** in any round; capture it in round 6 (Open question 12). For
AppKit sheets the public accessibility protocol defines default-button
and cancel-button attributes on the sheet, and alerts expose their title
and message as static texts (level 1).

**Requirement (behavioural).**
- From the application element, walking children only, the window that
  owns the alert lists the alert (role sheet) among its children, and the
  alert lists, in reading order, the title and message as static texts,
  then the buttons. Depth from the application element: application →
  window → sheet → button is enough; any extra levels must not be
  ignored elements whose children are dropped.
- Each button: role **button**, its label in the **title** attribute
  (Cancel, Merge), enabled state, a frame in screen coordinates that
  covers the drawn button, and the **press** action, which acts exactly
  as a click and returns success.
- The alert names Merge its **default button** and Cancel its **cancel
  button** through the default-button and cancel-button attributes.
- The system-wide hit test at a button's centre returns that button (or
  an element of the app whose nearest button ancestor is it).
- The same holds for the merge sheet's Cancel and Merge, and for the
  sheet's own controls (§13.8).
- **Test the path from outside the process**: with the alert up in a
  running Ycode, the capture tool's `find` with scope app, role button
  and title Merge must find exactly the drawn button, and its `press`
  must open the merge sheet. An in-process walk that starts below the
  window (for example at the frame view) does not prove the path,
  because what the window serves to other processes as its children can
  differ from its views' children. Round 6's script should press Ycode's
  alert buttons through accessibility, as it does the reference's.

### 13.3 The sheet's height in an 880-point window (refines §2)

| Element | Reference | Ycode now |
|---|---|---|
| Sheet | x 24–1376, top y 52 with a 1-point lighter top rim (#2D2E2F); fill **#1D1E1F**, one step from the veiled window (#1C1C1D), so in dark the sheet's sides hardly show | x 24–1376, top rim #474849 at y 51; fill #1F1F1F over a darker veil (#151617–#171818) |
| Content box | x 44–1356, y **64–847**; border a dark hairline **#171718** | x 44–1356, y 63.5–**792.5**; border a light line #3D3D3D |
| Footer row (§8) | y **819–846** | y 764.5–791.5 |
| Sheet bottom and buttons | below the window's bottom edge: the button row starts about y 868.5 (21.5 under the box) and is cut by the window | y 856; the buttons inside the window |

Ycode's box is **54.5 points shorter**; the judges' "866 against 811" is
the same difference in sheet coordinates. Target: in an 880-point window
the content box ends at y 847, 33 above the window's bottom, even though
the button row then extends past the window. The height rule in other
window heights stays Open question 1.

### 13.4 Dark colours in the sheet

| Element | Reference | Ycode now |
|---|---|---|
| Pane background | #262627 | #1F1F1F |
| Gutter | **#313131** between 1-point rules **#484848** | #252525, rules #383839 |
| Conflict row | **#583436** (in the gutter #613D3F) | #4A2629 (gutter #47262A) |
| Changed words | **#9B3A3C** | #7D3337 |
| Selected change's rules | **#DA5559** | #E06669 |
| Clean change | **#2F4457** (in the gutter #394C61) | #1E3A56 (gutter #1F3450) |
| Syntax | the dark theme of `editor-area.md` F.3, including the declaration and interpolation colours | no declaration colours; `Greeting` in the type-in-use colour |

### 13.5 Gutter tokens: dark fill, hairline rim

| | Reference | Ycode now |
|---|---|---|
| Size and place | 38.5 × 14, x 771.5–810, vertically centred in the change's first row | the same |
| Unselected token | fill **#575757** with a **0.5-point lighter rim** (about #6A6A6A; measured #6A6262 over a red row, #5E6771 over the blue row). On the dark gutter it reads as an outlined pill. | fill **#8A8A8A**, no rim: a light filled pill |
| Selected token | fill **#6D2A2D**, a 1-point rim #DA5559 | fill #8E3337, rim #E0666A |
| Glyphs | white "?" or digit; a light, thin down-chevron | white; the chevron drawn heavier and larger |

### 13.6 The Choose menu: hover and separator

- **Separator.** Both apps put the separator after Choose Right, at the
  same place: item tops at 0, 24, (separator at 41), 59 and 83 points
  from Choose Left's. The judges' "extra separator in Ycode" is wrong;
  §7's item list stands.
- **Hover.** The menu opens under the pointer, which rests where Choose
  Right appears. The reference **highlights Choose Right from the
  menu's first frame** (accent #007AFF bar x 797–962, 165 × 24, white
  text). Ycode shows no highlight until the click. Target: track the
  pointer from the first frame; an item under a stationary pointer is
  highlighted when the menu appears.
- **Position.** Ycode's menu sits 6 points lower (Choose Right's bar at
  y 315–339 against 309–333).
- **Click.** Reference: the highlight turns off 1293 ms after the step
  starts and back on at 1368 (the blink), the menu fades from about 1418
  to 1602, the pane text changes at 1685. Ycode: the highlight appears
  at 1293 and holds, the fade runs 1443–1622, the text changes at 1705.
  With hover tracking the blink then reads off-on as in the reference.

### 13.7 The jump bar's first item and the footers

- **Jump bar.** Reference: the project ("Merger", with the project's
  icon), the group ("Merger"), the file, "No Selection". Ycode starts
  with "project", the repository folder's name. Target: start the path
  at the workspace's project, as the main window's jump bar does.
- **Footers.** Reference: left "project › main › 1/3/26 Capture Test
  2e160c6 (HEAD)", right "project › main › 1/2/26 Capture Test cb364e9".
  Both footers name the **current branch** ("main"); only the commit on
  the right is the incoming one. Ycode's right footer names "feature".
  Whether the reference always names the current branch there is open
  (one capture).

### 13.8 Ycode implementation (B4-MERGE, 2026-11-06)

| Row | What Ycode does now |
|---|---|
| 97 | While the alert or sheet is up, `ModalParentDimming` (macOS) draws the window disabled before the veil: the content and the toolbar's text items at 0.63 opacity (`MergeModalTone.text`), the toolbar's glyph buttons through AppKit's disabled state, the close button disabled (AppKit's own grey). The veil has holes at the three window buttons and lets their clicks through, so minimize and zoom stay in colour and usable. Dark veil 0.30 (×0.70). The Source Control navigator's right-click no longer selects the row (the context ring only), so no highlight stays behind the alert. Linux: the window's columns at 0.63 under the modal; its window has no window buttons and the menu bar stays uncovered (§12). The window title (drawn by AppKit) is not dimmed (open). |
| 98 | `MergeButton` is an accessibility button (title, enabled state, press). The alert (role sheet, modal) lists the title and message as static texts, then Cancel and Merge, and names Merge its default and Cancel its cancel button; the sheet names its Merge and Cancel the same way, and Return merges once Merge is enabled. The sheet's drawn controls are exposed too: "Hierarchical" / "Flat" (radio buttons), the conflict navigator's and the stepper's chevrons, and one button per gutter token (its press opens the Choose menu). Linux: the buttons are toolkit buttons; the alert and sheet are modal containers, the buttons carry "Default button (Return)" / "Cancel button (Escape)" hints (the toolkit's tree has no default-button attribute), file rows are buttons. |
| 99 | `MergeSheetMetrics.sheetFrame`: the content box ends `boxBottomInset` (33) above the window's bottom in every window height (Ycode's choice for open question 1); the button row and the sheet's bottom lie past the window, which cuts them, as in the reference. |
| 100 | `MergeSheetPalette.dark` takes §13.3–§13.5's values (sheet, rim, panes, gutter and its rules, shading, word fills, rules, box hairline). The pane text is styled by the editor's own `Theme.apply` (macOS) and theme (Linux), so the declaration colours follow whatever the editor's theme gives. |
| 101 | Tokens: a 0.5-point rim (`tokenRim`, #6A6A6A in dark, none in light) on unselected tokens, 1 point on the selected; the chevron 6 × 3.5 with a 1-point stroke. |
| 102 | The Choose menu opens 6 points higher (`chooseMenuOrigin`). When it opens, a mouse-moved event at the pointer is queued so AppKit highlights the item under a resting pointer at once (not verified on screen: the tests do not move the pointer). Linux: hover highlighting is the toolkit's (unchanged). |
| 103 | The jump bar starts with the workspace's project (`MergeSheetProject`: a project's or workspace's name and folder, a package's folder), then the folders below the project's folder. Both footers name the current branch (a rebase's right footer keeps the replayed branch). |

## 14. Council round 5: the sheet below the window, Choose feedback, the ruler (2026-11-06)

Round 5 repeated the conflict session in dark with Ycode `a1f82372`.
**The window was placed 36 points below the display's top and the stills
and recordings took a 60-point margin below it**, so the reference's
sheet was captured whole for the first time. Values are in window points
of the 1400 × 880 window (the window's top-left at display (56, 36));
"display y" is the capture's own coordinate. Checklist rows 125–130 in
`fidelity-council.md`. §13.3's content box (y 64–847) now matches in
Ycode; what is left is below it.

### 14.1 The sheet hangs below its window

| | Reference | Ycode now |
|---|---|---|
| Window | stays where it is, the same size: frame y 0–880 in the stills before the alert, with the alert and with the sheet; it is **not** moved up or grown to hold the sheet | the same |
| Sheet frame | x 24–1376, **top y 52** (the toolbar's bottom; a 1-point lighter top rim #2D2E2F at 52), **bottom y 908**: 856 tall, **28 below the window's bottom edge** | x 24–1376, top 51.5; drawn only to **y 880**: everything below the window's edge is missing |
| The part below the window | the sheet's own frame continues past the window: its fill (#202020 there, over the black desktop) spans x 24–1376 from y 880 to 908, with the sheet's bottom corners rounded (radius about **16**: inset 5.5 at 4 above the bottom, 11 at 1 above). The window's own bottom corners show outside the sheet's sides (x 0–24 and 1376–1400, down to y 880) | nothing: the desktop shows from y 880 |
| Content box | y 64–847 (hairline #171718 at 846–847) | y 64–847 (#171718): **matches** |
| Button row | §9's places hold: Cancel x **1176.5–1260**, Merge x **1272–1356** (84 wide, its right edge on the box's right edge), 12 apart; Cancel y **866–886** (**20 tall**), Merge y 867.5–887.5 (1.5 lower); the sheet's bottom 22 below Cancel | the same x; the buttons start at y 868.5 and are cut at 880: only the top of their labels shows |

**Rule (target).** The sheet is its own window attached to the parent
below the toolbar, not a view inside the parent. Its height comes from
its content (here: 12 above the box, the box, 19 between the box and the
buttons, 20 of buttons, 22 below), not from the parent's height, and the
part that does not fit above the parent's bottom edge is drawn **outside
the parent's frame**, over whatever is below (another window or the
desktop). The parent window is not moved or resized. Whether the
reference shortens the sheet, or moves the parent, when the screen has
no room below is not captured (Open question 1).

### 14.2 The sheet's buttons

| | Reference | Ycode now |
|---|---|---|
| Shape | rounded rectangles, corner radius about **6** (0.5 point lost 3.5 in from the end), not capsules | capsules (radius about 10: 3 points lost 3 in from the end) |
| Cancel | fill **#2E2F30**, label #DFDFDF | fill #3A3A3A, label #E6E6E6 |
| Merge, disabled (a conflict undecided) | fill **#252627**, label #5B5C5C | fill #2C2D2C, label #575858 |
| Vertical place | Cancel's top 19 below the box's bottom edge (866), Merge's 1.5 lower | both 21.5 below (868.5) |

The 1.5-point drop of the disabled Merge was seen in one still; keep
both buttons on one baseline unless a later capture confirms it.

### 14.3 Choose Right: what changes, and when

Measured per frame from the recording `04-conflict-choose-right`, in ms
from the posted click. The click on the gutter token came 1.25 s (the
reference) and 1.19 s (Ycode) before the click on Choose Right.

| Event | Reference | Ycode now |
|---|---|---|
| The file list's row (Greeting.swift), from the **click on the token** | at **148 ms** the row turns from the focused selection (accent #0058D2, white text) to the **unfocused selection, grey #464546**, and its conflict badge from a white square with a red letter to a **red square (#FF4245) with a white letter** | stays the focused selection (#0059CE) with the white badge for the rest of the step |
| The Choose menu opens (from the token click) | 281 ms | 233 ms |
| Choose Right's highlight, from the **click on the item** | not highlighted until **151 ms**, then the accent bar (#007AFF) | highlighted at **44 ms**, off at 69, on again at 144 |
| Menu fade | starts about 180–200 ms, ends about **390** (the bar at #353435, the row behind it, by 392) | starts about 170–185, ends about **377**: the same |
| Left pane's text changes | 467 ms | 444 ms |

1. **The row and badge change because focus moves.** Clicking a token
   makes the merge panes the focused view, so the file list draws its
   selection unfocused. This happens on the token click, before any
   choice. Target: clicking in either pane, in the gutter or on a token
   moves keyboard focus into the panes; the file list then shows the
   unfocused grey selection and its badges in their normal colours (red
   square, white letter, as on an unselected row).
2. **The menu's fade is not late.** The judges' "333 against 417 ms"
   compares segments that start at different events (the tool's segment
   for Ycode started at its 44 ms highlight). The fade itself is the same.
3. **The highlight sequence differs.** In round 5 the pointer did not
   rest on the item before the click (the driver puts the pointer back
   after each click), so the reference showed no hover highlight; on the
   click it showed the item **off, then on at about 150 ms**, then faded.
   Ycode highlights at once, blinks off and on. Target: on a click on an
   item, keep the item's current hover state for the first frame, turn
   it off, then on at about 150 ms, then fade from about 190 ms over
   about 200 ms (§7's timing). Round 4's hover rule (§13.6: an item under
   a resting pointer is highlighted from the menu's first frame) stays.

### 14.4 The right pane's overview ruler in dark (refines §4.4)

| | Reference | Ycode now |
|---|---|---|
| Knob | a filled bar **11 wide (x 1339–1350)**, **#A2A2A2**, from y **105 to 815**: the whole track, because the whole file is visible | none |
| Change marks | 1-point lines drawn over the knob, x 1340–1350: conflicts **#FDB9B5** at y 423 and 571, the clean change **#D4D4D4** at 719 | 1-point lines on the pane's background: #9B4B48 at 419.5 and 578.5, #5A5B5A at 737.5 |
| Mark position | the change's first line's **centre** in proportion to the file's logical lines over the track: (line − 0.5) ÷ lines (lines 9, 13 and 17 of 19 give 0.447, 0.658, 0.868; measured 0.448, 0.656, 0.865) | (line − 1) ÷ (lines − 1) over the pane's height (0.444, 0.667, 0.889) |

Lines wrapped onto two rows still count once. The judges' "full-height
scroller with grey ticks" is this knob.

### 14.5 Ycode implementation (B5-MERGE, 2026-11-07)

| Row | What Ycode does now |
|---|---|
| 125 | macOS: the sheet is a window of its own (`MergeSheetWindow`, borderless, a child of the workspace window, never constrained to a screen), attached under the toolbar; its height comes from the content box (33 above the parent's bottom, §13.3) plus 19, the 20-point buttons and 22, so in the 880-point window it ends at y 908 over whatever lies below; the parent is not moved or resized. The window is 32 points taller than the sheet, transparent above it, so §10's slide is not cut. Linux: the toolkit has no child window that may extend past its parent, so the sheet is still drawn inside the window and cut at its bottom (a request to OpenViews). |
| 126 | Both IDEs: `buttonHeight` 20, `buttonGap` 19, `bottomMargin` 22, `buttonCornerRadius` 6; dark Cancel #2E2F30 / #DFDFDF, disabled Merge #252627 / #5B5C5C. Both buttons on one baseline (§14.2's note). |
| 127 | A click in either pane, the gutter or on a token makes the panes the focused view (macOS: the canvas becomes first responder; Linux: `ConflictEditorShellModel.panesFocused`); the file list then draws `MergeSheetPalette.fileRow(selected:listFocused:)`: the grey selection (#464546 dark; light #DCDCDC, Ycode's choice) and the red badge #FF4245 with a white letter. A click in the list brings the focus back. The sheet opens with the list focused. |
| 128 | Not changed: the Choose menu is the system's menu on macOS and the toolkit's on Linux; their click feedback (the mouse-down highlight, then the blink) is theirs. |
| 129 | Both IDEs: in dark an 11-point knob (#A2A2A2, x 1 in the strip) over the visible part of the track (3 inside the pane's top and bottom; the whole track when the file fits), marks #FDB9B5 / #D4D4D4 at (line − 0.5) ÷ lines of the right pane's logical lines (`rulerMarks`, `rulerMarkY`, `rulerKnob`). Light keeps §4.4's strip without a knob. |
| 130 | The alert's and the sheet's `MergeButton`s and drawn controls answer the accessibility hit test (an `NSControl` without a cell answered nothing). `MergeSheetR5UITests` runs the capture driver's search (§13.2: application element, children only, role and title) and its press in a separate process (`xcrun swift`) against the test's own application, with the window ordered in off every display: Merge is found at application → window → sheet → button, enabled, with the press action, its frame covering the drawn button (AppKit adds a point on each side, as the reference's 82 × 22), the default and cancel attributes, and the press opens the sheet in 0.3 ms; the sheet's Cancel and Merge are found the same way. Off every display the window server's hit test finds no window, so the hit test is checked through AppKit's own (`accessibilityHitTest`). |

## 15. Council round 6: word runs, the current change's rules, the ruler in light, the alert's order (2026-11-07)

Round 6 repeated round 5's conflict session (Retina, 120 fps, the window
at display (56, 36), a 60-point margin below it) in the **light**
appearance, with Ycode `0f1408a4`. Values in window points of the 1400 ×
880 window; times in ms from the click the capture tool posted. The
sheet is now whole in Ycode (§14.1 met) and the resolved state matches
(§14.3's focus rule met: the file row turns grey with the red badge in
both). Checklist rows 146–148 and 168 in `fidelity-council.md`.

### 15.1 Changed-word runs (refines §6)

The highlight fill is #FF9A9D on the conflict row's #FFDCDD in both
apps; the sheet's cell is 8.0 wide. Runs measured on conflict 03 (before
any choice), x in window points:

| Line | Left pane, reference | Left pane, Ycode now | Right pane, reference | Right pane, Ycode now |
|---|---|---|---|---|
| 9 | **Good** 355.5–387.5 (4 cells), **morning** 395.5–451.5 (7) | **"Good** 349–389 (5: the quote too), **morning,** 397–461 (8: the comma too) | **Welcome** 926.5–982.5 (7), **aboard** 991–1038.5 (6) | **"Welcome** 920–984, **aboard,** 992–1048 |
| 13 | **Farewell** 355.5–419.5 (8) | **"Farewell,** 349–429 (10) | **See you soon** 926.5–1022.5 (**12 cells, one run**, its two spaces filled) | **"See** 920–952, **you** 960–984, **soon,** 992–1032 (three runs) |

(Ycode's text also starts 1.5 points right of the reference's.)

**The rule the reference follows.** Split each side's line into tokens:
a run of word characters (letters, digits, underscore), a run of
whitespace, or **one other character** (every quote, comma, bracket and
operator is a token of its own). Match the two token sequences (longest
common subsequence). Fill each **maximal run of consecutive unmatched
tokens** as one box, whitespace inside the run included; matched tokens
stay unfilled. On line 9 the space between "Good" and "morning" matches
the space between "Welcome" and "aboard", so each side has two runs; on
line 13 the left has no space between its quote and comma for the
right's spaces to match, so "See you soon" is one unmatched run. Ycode
splits on whitespace only (so quotes and commas join their words) and
fills each word on its own.

**After a choice** (conflict 04) both apps keep the left pane's fills at
the cells they had before the choice, over the new text (so they fall
across "Welcome aboard" in fragments): open question 6 is answered for
this case, the fills are not recomputed, and Ycode does the same.

### 15.2 The current change's rules, and Choose Right's timing (refines §6, §14.3)

| Event | Reference | Ycode now |
|---|---|---|
| The conflict's 1-point rules (top and bottom of its rows, both panes and the gutter) turn from #DA5559 to **#FF656A** | **113 ms after the click on the token**, before the menu opens | only when the choice is applied: about 1.67 s after the token click (457 ms after the item's click) |
| Choose Right's highlight, from the click on the item | on at **165** (round 5: 151) | on at 57, again at 73 and 140 (row 128, unchanged) |
| The menu's fade | 215–319 | 207–323 |
| The left pane's new text | **452**; the changed region is the left pane's line and the token (x 356–810) | **457**; the changed region spans both panes and the gutter (x 244–1338), because the rules change in the same frame |

So §6's "#FF656A once a choice has been made" reads better as **the
current change's rules are #FF656A while the panes have the focus**: the
token click moves the focus into the panes (§14.3, 148 ms in round 5)
and the rules brighten with it (113 ms here). **Target:** draw the
current change's rules #FF656A whenever the panes are focused, #DA5559
when the file list is; with that, the text change is the only repaint at
the choice. The judges' 303 against 417 ms is the tool's segment
starting at each app's first highlight (165 against 57); the fade and
the text change already match.

### 15.3 The right pane's overview ruler in light (refines §14.4)

| | Reference | Ycode now |
|---|---|---|
| Knob | none drawn in light (the strip stays white over the track) | none |
| Marks | 1-point lines, #FDB9B5 conflicts at y **423** and **571**, #D4D4D4 the clean change at **719**: (line − 0.5) ÷ 19 of a track **105–815** (710), as in dark | the same colours at y 439.5, 597.5, 755.5: the same fraction of a track **105–853** (748): 16.5–36.5 lower |

**Target:** the track ends at 815 in light as in dark (§14.4), so the
marks land on the reference's y.

### 15.4 The alert's accessibility children (refines §13.2)

The children of the alert's sheet element, in order:

| # | Reference | Ycode now |
|---|---|---|
| 1 | an image, 18 × 18, at the alert's bottom-left (empty on screen; described as a source-control status image) | the message text (296 × 36) |
| 2 | **Merge** button, 82 × 22 | the informative text (296 × 32) |
| 3 | **Cancel** button, 60 × 22 | Cancel, 60 × 22 |
| 4 | the message text, 296 × **34** | Merge, 81 × 22 |
| 5 | the application icon image, 66 × 66 | — |
| 6 | the informative text, 296 × **30** | — |

**Target:** the reference's order (the default button before the cancel
button, both before the texts); expose the icon as an image with a
description (Ycode's own words); the status image is optional (nothing
is drawn for it). The buttons' frames already match.

## 16. Council round 7: the alert's children again, the window behind the sheet (2026-11-08)

Round 7's conflict session (dark, Ycode `0afb3bd7`) recorded the alert's
accessibility tree again (`02-merge-start-alert-tree`); the judges did
not get it this round, so row 168 was checked here instead. Checklist
row 195 in `fidelity-council.md`. The final empty line in both panes is
`editor-area.md` I.3; the toolbar behind the sheet (the issue capsule,
the activity subtitle, the traffic lights) is `workspace-window.md`
W7.2.

### 16.1 The alert's children (refines §15.4)

| # | Reference | Ycode now |
|---|---|---|
| Sheet | 420 × 132, **no description** | 420 × 133, its description the message text |
| 1 | an **image with no description, 18 × 18** (an empty status image) | — |
| 2 | button **Merge**, 82 × 22, title only | button Merge, 81 × 22, title and the same text as description |
| 3 | button **Cancel**, 60 × 22 | button Cancel, 60 × 22, title and description |
| 4 | the message, static text **296 × 34** | 296 × 36 |
| 5 | the application icon, an image **66 × 66** described as the application's icon | 57 × 57, described as Ycode's icon |
| 6 | the informative text, **296 × 30** | 296 × 32 |

Round 6's order (Merge, Cancel, message, icon, text) is **met**. What is
left: the leading 18 × 18 image without a description, the icon at 66 ×
66, the texts 2 points shorter each (34 and 30, so the sheet is 132),
and no description on the sheet or the buttons (the title carries the
name).

### 16.2 Ycode implementation (B7-D, 2026-11-08)

The alert is 132 tall (its top where the 133-point alert had it); an
empty, undescribed 18 × 18 image comes first among its children; the
icon's element is 66 × 66 round the drawn icon; the message's element
is 296 × 34 and the informative text's 296 × 30; the sheet and the
buttons (here and in the merge sheet) have no description, their titles
name them (macOS). The Linux card adds the same image and icon element;
its buttons and card keep their accessibility names (AT-SPI has no
separate title).

## Open questions

Each has a Ycode answer in §12, marked "Ycode's choice, open question".


1. The sheet's height rule. Round 5 (§14.1) saw the whole sheet in an
   880-point window: 856 tall, 28 past the window, its bottom margin 22
   below the buttons. Still open: whether the height is fixed or follows
   the window (capture it in a 1000+ window), and what happens when the
   screen has no room below the window.
2. The buttons' height; whether Merge becomes the default (accent) button
   once every conflict is decided.
3. What the window shows after Merge (the commit, the navigator's state,
   any notice) and after Cancel; the sheet's disappear animation.
4. Which glyph each choice puts in the token ("1" after Choose Right and
   "3" on the clean change were seen); Choose Left and the two "Then"
   items were not captured.
5. Alignment when the two sides of a change have different line counts.
6. Whether the changed-word fills are recomputed after a choice (the
   capture showed them at the old positions). Answered for Choose Right
   by round 6 (§15.1): they are not.
7. The context menu for the current branch row and for remote branches,
   tags and stashes; the Integrate ▸ Merge path (not captured).
8. Flat mode of the file list, and a sheet with several conflicted files.
9. The token chevron circle on the clean change: a state ("a choice is in
   effect") or a pointer-hover effect. The capture supports the state
   reading (the circle was there with the pointer elsewhere).
10. Whether the footers always name the current branch on both sides
    (§13.7; one capture).
11. The parent window's disabled tones: measured as about 0.63 (text)
    and 0.33 (toolbar glyphs) of the active value before the veil, from
    one alert and one sheet in dark; light appearance not captured with
    the new rule in mind.
12. The reference alert's full accessibility tree (§13.2): the sheet's
    role and subrole, the order of its children, and the values of its
    default-button and cancel-button attributes. Capture it with the
    capture tool's `tree` (scope app, depth 4) while the alert is up.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Context menu items, order, enabled state, metrics | 3 | Council round 3 conflict recording `02-merge-start` (120 fps): frames at 1.5 s and 2.2 s; colour runs and ink boxes |
| Alert geometry, texts, buttons, default, veil timing | 3 | The same recording, frames 2.45–3.9 s; per-frame column profiles |
| Sheet frame, veil, content box, file list, panes, gutter, tokens, shading, ruler, footers, buttons | 3 | Council round 3 still `03-conflict-at-rest` (2x), colour runs and ink boxes |
| Choose menu items, placement, effect, dismissal timing | 3 | Recording `04-conflict-choose-right` and still `04-conflict-choose-right-after`; the measured progress table of the 330 ms segment |
| Sheet appear transition | 3 | Recording `02-merge-start`, frames 3.875–4.15 s: the sheet's top edge and opacity per frame |
| Ycode's behaviour | — | The same session's captures of Ycode; the capture notes on its missing row menu |
| §12 | — | Ycode's design and choices (B3-MERGE); the git side: git's documentation (level 1) |
| git side of a merge | 1 | git documentation, as in `source-control.md` |
| §13: modal state, alert accessibility, sheet height, dark colours, tokens, Choose menu hover, jump bar and footers | 3 | Council round 4 stills `01-scm-repositories`, `02-merge-start-alert`, `03-conflict-at-rest` and recording `04-conflict-choose-right` of both apps (dark); region colours, colour runs, per-frame highlight detection; the accessibility gap from the capture session's notes |
| §13.2 (round 5): the driver's search path | — | The capture tool's own accessibility driver and session runner (our code, read in the dirty room): its search roots, breadth-first walk over the children attribute, match keys and press call |
| §13.2: the reference's Merge button as found (role, title, frame, action, press time) | 3 | The round 5 conflict manifest's result for the accessibility press |
| §13.2: default and cancel button attributes, static texts in alerts | 1 | AppKit accessibility documentation (`NSAccessibility` protocol) |
| §14: the sheet below the window, the buttons, Choose Right's row, badge, highlight and fade timing, the ruler in dark | 3 | Council round 5 stills `02-merge-start-alert`, `03-conflict-at-rest`, `04-conflict-choose-right-after` (app mode with a 60-point margin) and recording `04-conflict-choose-right` (120 fps) of both apps, dark; vertical and horizontal colour runs, per-frame samples of the file row, its badge and the menu item, timed against the driver's posted clicks |
| §15: changed-word runs, the current change's rules and Choose Right's timing, the ruler in light, the alert's children | 3 | Council round 6 stills `02-merge-start-alert`, `03-conflict-at-rest`, `04-conflict-choose-right-after` and the alert's accessibility tree (`02-merge-start-alert-tree`), recording `04-conflict-choose-right` (120 fps), both apps, light: highlight runs on a pixel row inside the fill, colour runs through the ruler, per-frame changed regions and one-point colour samples timed against the posted clicks |
| §16: the alert's children in round 7 | 3 | Council round 7 alert accessibility trees (`02-merge-start-alert-tree`, both apps, dark), recorded by the capture tool: roles, descriptions, titles, sizes and order |
