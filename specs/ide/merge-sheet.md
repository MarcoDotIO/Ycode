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

Ycode's alert is an accessibility sheet holding two static texts and no
buttons; a hit test on a button finds nothing, and the capture had to
press Return. The reference's alert buttons were pressed through
accessibility. Requirement: every alert button is an accessibility
element with the button role, its label as its title and a press
action; the alert exposes its default button (Merge) and its cancel
button (Cancel) as such; the title and message are static texts. The
same holds for the merge sheet's Cancel and Merge.

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

## Open questions

Each has a Ycode answer in §12, marked "Ycode's choice, open question".


1. The sheet's height rule and its bottom margin. In an 880-point window
   the sheet runs past the window's bottom edge. Capture the sheet in a
   taller window (1000+) to see the button row whole and whether the
   sheet's height is fixed or follows the window.
2. The buttons' height; whether Merge becomes the default (accent) button
   once every conflict is decided.
3. What the window shows after Merge (the commit, the navigator's state,
   any notice) and after Cancel; the sheet's disappear animation.
4. Which glyph each choice puts in the token ("1" after Choose Right and
   "3" on the clean change were seen); Choose Left and the two "Then"
   items were not captured.
5. Alignment when the two sides of a change have different line counts.
6. Whether the changed-word fills are recomputed after a choice (the
   capture showed them at the old positions).
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
