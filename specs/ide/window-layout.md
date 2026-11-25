# Window layout at narrow widths

**Status:** boundary spec for the narrow workspace window: how the areas share the
width and in what order toolbar items fold and move into the » overflow as the
window narrows. It reconciles the b5-obs capture (2026-11-20) with inventory rows
**P-024** (areas) and **P-025** (toolbar overflow), which B5-MOTION and
B5-TOOLBAR are implementing. Council round 12 (2026-11-21) adds the live drag
with the inspector hidden and the window's minimum width (§4), the toolbar with
the navigator hidden (§5, **P-190**), the panels' motion (§6, **P-190**,
**P-191**) and live-resize latency (§7, **P-201**). Prose, tables and measured
numbers only: no code, no copied resources.

Related: `specs/ide/workspace-window.md` (areas and default sizes),
`specs/ide/liquid-glass.md` §8.2 (the toolbar at 1100 pt), `fidelity-council.md`
rows 34, 107, 134, 159 and 218, `editor-area.md` §F.6 and §G.4 (the relayout and
the overflow capsule's morph).

**Capture conditions.**
- **b5-obs (2026-11-20):** a **1x** display at **100 Hz**; Shapes.swift open,
  navigator and inspector shown; the window's width **set through the
  accessibility interface** from 1400 pt down to 500 pt in **25-pt steps**
  (height 880), a still at every step and an accessibility tree at every 50 pt;
  dark, then light; host load 10–22. Thresholds are "present at W + 25, gone at
  W", so each is good to 25 pt.
- **Council round 12 (2026-11-21):** the same display, **1x / 100 Hz**, dark,
  host load 3.7–12.8; the window 1400 × 880 at a fixed place. Xcode's
  **inspector was hidden** for the whole narrow-window session (a state kept from
  the run before) and the **navigator shown** at the start of each drag. The
  right edge was **dragged live** by the pointer, 1400 → 400 pt over 2.0 s
  (twice), and widths of 1100, 900, 817, 700 and 503 pt were then **set through
  accessibility** with both side areas hidden. Widths during the drag come from
  the window's edge in every recorded frame (a frame every 10 ms), so drag
  thresholds are good to ≈ 25 pt (the overflow morph lags a fast drag).
- Sizes ±1 pt; timings ±20 ms (some recordings hold a frame for 20 ms).
- The parity run of 2026-11-15 (2x / 120 Hz) resized the window in one step to
  700 pt and then **dragged the right edge live** from 700 to 500 pt; where the
  runs disagree, §4 gives each.

## 1. Areas

| Area | Width | Notes |
|---|---|---|
| Navigator | **290 pt** | its selector capsule is 276 wide (7-pt insets) |
| Editor | the rest, **never below 300 pt** | |
| Inspector | **260 pt** | its tab capsule is 246 wide (7-pt insets) |

1. From 1400 down to **850 pt** only the editor narrows (≈ 840 pt at 1400 → 300
   at 850). The navigator and inspector keep their widths at every width
   recorded.
2. **850 pt = 290 + 300 + 260** is the narrowest window that shows all three
   areas whole. Below it, in this capture, nothing shrank or hid; the split view
   stayed 850 wide and was **clipped by the window**:
   - at 825 pt on the right (the inspector cut off by 25 pt);
   - from **800 pt** down on the **left**: the whole split view is shifted left
     by 850 − W (the navigator's selector at window x −43 at 800, −143 at 700,
     −343 at 500), the inspector pinned to the right edge, the editor's visible
     part shrinking and, below 560 pt, its left part hidden too.
3. Xcode accepted every width down to 500 pt set this way.
4. Widening back to 1400 restored the full layout in both appearances.
5. These are frames set through accessibility. On a **live drag** (council
   round 12) the navigator also keeps 290 pt, but collapses once the editor
   reaches 300 pt instead of being clipped (§4.2).

## 2. Toolbar: what folds and what moves into »

Navigator and inspector shown (b5-obs). Dark pass; the light pass differs only
where noted. Other states: §2.3.

| Width (pt) | Change |
|---|---|
| 1375 | everything shown (as at 1400) |
| **1350** (light 1325) | the Editor Only / Canvas / Assistant / Code Review segmented group folds into **one Editor Mode pop-up** (its current mode's glyph with up/down chevrons) |
| 1250 | the scheme title starts to truncate at its tail ("P…") |
| 1225 | the scheme title is gone (its glyph and "›" remain); the destination title truncates ("My M…"; light at 1200: "M") |
| **1200** (light 1175) | the issue capsule drops its count (its symbol only) |
| 1175 | the destination title is gone: the capsule is glyph › glyph |
| **1150** | the **» overflow circle** appears at the right end of the centre group; the cloud-notices button and the Editor Mode pop-up move into it |
| 1075 | Editor Options moves into » |
| 1050 | Add Editor moves into » |
| 1000 | the issue capsule moves into » |
| 950 | the scheme › destination capsule moves into » |
| 875 | New Conversation moves into » |
| 850 | the content no longer shrinks (§1) |
| 800 | the Navigators / Coding Assistant group is gone with the navigator's sliding edge |
| 725 | Run / Stop are gone |
| 625 | the window title (and activity) is gone |
| 500 | left: the traffic lights, Back / Forward, », the inspector toggle |

The order, in words: first the editor-mode group folds; then text goes, from the
scheme title to the destination title, the issue count in between; then whole
items move into », **from the right end of the centre group leftward** (cloud
notices and editor mode, Editor Options, Add Editor, issues, the scheme capsule,
New Conversation). Below 850 the leading items leave with the navigator they
track, then Run/Stop, then the title. Back / Forward and the inspector toggle
never leave.

Ycode has **no cloud-notices button** (owner decision 5): its first move into »
at 1150 is the Editor Mode pop-up alone. The thresholds above stay as they are;
Ycode does not close the gap the missing button leaves.

### 2.1 The overflow menu at 500 pt (b5-obs: the navigator off the left edge)

At 500 pt the » menu lists, in toolbar order, each item under its toolbar name
and with its toolbar glyph (Scheme and Destination without a glyph): Hide
Navigators, Show Coding Assistant, **Run ›** (Run / Test / Profile / Analyze),
Stop (disabled), Window Title/Activity (disabled), New Conversation, Jump to Next
Active Conversation (disabled), **Scheme ›**, **Destination ›**, **Issues ›**,
(Xcode Cloud Notices: not in Ycode), **Add Editor ›**, **Editor Options ›**,
**Editor Mode ›** (the light pass listed the modes Editor Only, Canvas,
Assistant, Code Review as items). The menu opens under the » circle.

### 2.2 The overflow item and its gap (owner decision, row 218)

Ycode keeps the system's overflow item and its morph, so the space before » is
≈ 26 pt where the reference has ≈ 5 pt. That stands. Motion when the window
narrows: one-frame relayout within ≈ 120 ms, the overflow capsule morphing from
the absorbed items' extent to its circle over ≈ 165 ms, ease-out
(`fidelity-council.md` row 159; not re-measured here).

### 2.3 The same order with side areas hidden (council round 12)

The order of §2 holds in every state recorded; only the widths move. The two
council round 12 states:

**(a) Live drag, navigator shown, inspector hidden** (the navigator collapses at
the end, §4):

| Width (pt, ±25) | Change |
|---|---|
| 1250 → 1225 | the editor-mode group folds into the Editor Mode pop-up |
| ≈ 1125 | the title's subtitle starts to truncate in its middle ("Build Succeede…oday at 4:41 AM"); the scheme title truncates |
| ≈ 1075 | the scheme title is gone; the destination title truncates |
| 1025 → 975 | the destination title and the issue count are gone |
| 950 → 925 | **»** appears; the cloud-notices button and Editor Mode move into it |
| ≈ 900 | Editor Options moves into » |
| ≈ 850 | Add Editor moves into » |
| ≈ 800 | Issues moves into » |
| ≈ 750 | the scheme capsule moves into » |
| 675 → 625 | New Conversation moves into » |
| ≈ 607 | the title (with its subtitle) fades out of the toolbar |
| ≈ 590 | the editor reaches 300 pt: **the navigator collapses** (§4); the Navigators group and Run / Stop take their navigator-hidden places (§5.1) |
| 500 → 450 | Back / Forward move into » |
| 408 (417 in the other drag) | the minimum: traffic lights, Navigators group, Run / Stop, », inspector toggle |

**(b) Both side areas hidden**, widths set after the drag:

| Width (pt) | Toolbar |
|---|---|
| 1100 | everything except the editor-mode group, which is the Editor Mode pop-up; no »; the scheme title truncated ("Pari"), "My Mac" whole, the issue count shown, the subtitle middle-truncated |
| 900 | » holds cloud notices and Editor Mode; the scheme capsule is glyph › glyph; the issue capsule has no count; Add Editor and Editor Options shown |
| 817 | Editor Options has moved into » too; Add Editor still shown |
| 700 | the scheme capsule, Issues and Add Editor are in »; New Conversation and the title shown |
| 503 | New Conversation and the title are in »; Navigators group, Run / Stop, Back / Forward, », inspector toggle |
| 408–417 | Back / Forward are in » too (the minimum, §4) |

**A model that fits all three states.** The toolbar has a leading section, a
content section and a trailing section. The leading section is the navigator's
column when the navigator is shown (290 pt) and ends after Run / Stop when it is
hidden (≈ 255 pt). The trailing section is the inspector's column when it is
shown (260 pt) and ≈ 50 pt (the inspector toggle) when it is hidden. The
centre and right groups move into » when the **content section** (window width
minus both sections) falls below a fixed width:

| Item moves into » | Content section below (pt) | b5-obs (both shown) | round 12 (a) | round 12 (b) |
|---|---|---|---|---|
| cloud notices and Editor Mode (» appears) | ≈ 600 | 1150 | ≈ 937 | between 1100 and 900 |
| Editor Options | ≈ 525–560 | 1075 | ≈ 900 | between 900 and 817 |
| Add Editor | ≈ 500 | 1050 | ≈ 850 | between 817 and 700 |
| Issues | ≈ 450 | 1000 | ≈ 800 | between 817 and 700 |
| the scheme capsule | ≈ 400 | 950 | ≈ 750 | between 817 and 700 |
| New Conversation | ≈ 310–325 | 875 | ≈ 650 | between 700 and 503 |

So hiding the inspector moves every overflow threshold down by ≈ 210 pt
(260 − 50), and hiding the navigator by ≈ 35 pt (290 − 255). The text steps (the
scheme and destination titles, the issue count, the subtitle) depend on how long
the title and subtitle are as well: in round 12 the subtitle was the long
"Build Succeeded • Today at 4:41 AM", and the titles went 135–210 pt lower than
the content model alone gives. Ycode must use the order of §2, the content
widths above, and check itself against the three tables (each to ±25 pt) in
the same states.

### 2.4 The » menu with both side areas hidden (council round 12)

The menu opens as a pop-up from », its first row level with the button and its
left edge ≈ 29 pt right of the »'s left edge, over the toolbar; rows are 24 pt;
its width comes from its longest title (213 pt at 817, 291 pt at the minimum).

**At 817 pt:** Xcode Cloud Notices (cloud glyph); Editor Options › (its glyph);
Editor Mode › (its glyph). Ycode has no cloud-notices button (owner decision 5),
so its menu is **Editor Options ›, Editor Mode ›**. (Ycode in round 12 listed
Navigators and Run: those must stay in the toolbar, §5.1.)

**At the minimum (12 rows), in order:**

| # | Row | Glyph | State |
|---|---|---|---|
| 1 | Go Back | ‹ | enabled |
| 2 | Go Forward | › | disabled (nothing to go forward to) |
| 3 | Window Title/Activity | none | disabled |
| 4 | New Conversation | its toolbar glyph | enabled |
| 5 | Jump to Next Active Conversation | none | disabled |
| 6 | Scheme › | none | enabled, sub-menu |
| 7 | Destination › | none | enabled, sub-menu |
| 8 | Issues › | the warning triangle, outlined | enabled, sub-menu |
| 9 | Xcode Cloud Notices | cloud | enabled (not in Ycode) |
| 10 | Add Editor › | its toolbar glyph | enabled, sub-menu |
| 11 | Editor Options › | its toolbar glyph | enabled, sub-menu |
| 12 | Editor Mode › | its toolbar glyph | enabled, sub-menu |

Ycode's menu is the same without row 9 (11 rows). The Navigators group and
Run / Stop are **not** in it: with the navigator hidden they stay in the toolbar.
The first row showed the accent highlight when the menu opened from an
accessibility press (not checked for a pointer click).

## 3. The scheme capsule's text

The capsule's titles give way in this order: the scheme title truncates, then
goes; the destination title truncates, then goes. The issue count goes between
those two steps. With both titles gone the capsule is ≈ 87 pt (target glyph,
"›", destination glyph; `liquid-glass.md` §8.2).

## 4. Reconciliation with P-024 and P-025; the minimum width

| Topic | parity 2026-11-15 (2x; one-step resize to 700, then a live drag 700 → 500) | b5-obs 2026-11-20 (1x; accessibility resize in 25-pt steps) | council round 12 (1x; live drag 1400 → 400, inspector hidden) |
|---|---|---|---|
| Editor | kept at ≥ 300 | kept at ≥ 300 | kept at ≥ 300 until the navigator collapses, then the whole width |
| Navigator | shrinks to 139.5 pt at 700 (the one-step resize); hidden at 503 and **not restored** when dragged back to 1468 | **never shrinks or hides** (290); slides off the left edge from 800 | **keeps 290** while the editor narrows; **collapses** (hides, with its slide, §6.1) when the editor reaches 300 (W ≈ 590); not restored when widened |
| Inspector | 258.5 at 700; **201.5 at 503** | **never shrinks** (260); pinned to the right edge | hidden throughout |
| Minimum width | **503 pt** (the drag stopped there, 3 pt short of its target) | none reached down to 500 | **408 and 417 pt** (two drags; the drag aimed at 400) |
| Toolbar at the end | the leading capsule and Run/Stop **come back** (the navigator is hidden), the title goes | traffic lights, Back/Forward, », inspector toggle (the leading items are off the left edge with the navigator) | traffic lights, Navigators group, Run / Stop, », inspector toggle |
| The » circle appears | between 1400 and 1100 (one-step resize) | at **1150** | ≈ 937 (drag), between 1100 and 900 (both areas hidden) |

### 4.1 The minimum width (P-024)

The three minimums come from different states, not from different rules:

| State at the minimum | Minimum | Run |
|---|---|---|
| navigator hidden, **inspector shown** (shrunk to 201.5) | **≈ 503 pt** = editor 300 + divider 1 + inspector ≈ 202 | 2026-11-15 |
| navigator hidden, **inspector hidden** | **≈ 408–417 pt**: the toolbar's floor | round 12 (twice) |
| a frame set through accessibility (nothing collapses) | not reached at 500 | b5-obs |

**Rule:** during a live resize the window's minimum width is the larger of
1. the **content floor**: the editor's 300 pt, plus, when the inspector is shown,
   its minimum width (≈ 201.5 pt) and its 1-pt divider. The navigator never adds
   to it, because it collapses instead of going below its width (§4.2); and
2. the **toolbar floor**: the room for the items that never move into » and for
   » itself: the traffic lights, the Navigators / Coding Assistant group
   (x 95–173), Run | Stop (x 176–255), » (38 pt) and the inspector toggle
   (40 pt), with the toolbar's margins. Measured: 408 and 417 pt for the same
   items (use **410 pt**; the 9-pt difference is OPEN).

So: **inspector shown ≈ 503 pt; inspector hidden ≈ 410 pt.** Ycode in round 12
stopped at 503 pt in both states (wrong for the inspector hidden). Neither run
had the debug area open; it changes heights only, so it should not change the
minimum (OPEN, not recorded). Both runs used a project's workspace window; other
window kinds (a lone file, a package) were not recorded (OPEN).

### 4.2 What gives way during a live drag

1. Above the point where the editor reaches 300 pt only the editor narrows
   (§1). The navigator keeps 290 pt; it does not shrink first (round 12).
2. When the editor would go below 300 pt, **the navigator collapses**: it hides
   with the slide of §6.1, the editor takes its room, and the toolbar takes the
   navigator-hidden arrangement of §5.1 within 2–4 frames. With the inspector
   hidden this happened at **W ≈ 590 pt** (290 + 300). With the inspector shown
   the same rule gives ≈ 850 pt (290 + 300 + 260); not recorded at 25-pt
   resolution (OPEN).
3. Then, if the inspector is shown, it narrows from 260 toward ≈ 201.5 pt while
   the editor stays at 300 (2026-11-15), and the window stops at ≈ 503 pt. If it
   is hidden, the editor narrows until the toolbar floor (≈ 410 pt).
4. The collapsed navigator stays hidden when the window is widened again (both
   live runs).
5. The title (and its subtitle) leaves the toolbar at ≈ 607 pt (round 12 (a)),
   just before the navigator collapses; with the navigator hidden it comes back
   only where §2.3 (b) shows it.

The 2026-11-15 one-step resize to 700 pt (navigator shrunk to 139.5 pt) and
b5-obs's accessibility steps (nothing collapsed, content clipped) are both frames
**set programmatically**; they disagree with each other and with a live drag.

**For Ycode (P-024, P-025):**
1. Above the point where the editor reaches 300 pt: the thresholds of §2 and
   §2.3 and the fixed side areas of §1.
2. **Live resize** (the user dragging an edge; the case that matters): §4.2.
   The navigator does not shrink; it collapses with its slide when the editor
   would go below 300; then the inspector, if shown, narrows to ≈ 201.5; the
   minimum is §4.1's rule (≈ 503 with the inspector shown, ≈ 410 without); a
   collapsed navigator stays hidden when the window widens; with it hidden, the
   toolbar's Navigators group and Run | Stop stay (§5.1).
3. **A frame set below the content's width** without a live resize (restoring a
   saved frame, scripting): Ycode may clip like the reference or apply rule 2's
   layout; it must not squeeze the editor below 300.
4. Superseded: the earlier interim rule (shrink the navigator from 850 pt, hide
   it below ≈ 140 pt). Round 12's drag shows no shrinking.

## 5. The navigator hidden: the toolbar (P-190, council round 12 C01)

### 5.1 Which items stay, and where

Window x in points, the window 1400 pt wide, dark; ±1 pt.

| Item | Navigator shown | Navigator hidden |
|---|---|---|
| Traffic lights | unchanged | unchanged |
| **Navigators / Coding Assistant** group (one capsule, two halves: list glyph, then lines-and-sparkle glyph) | x 96–171; the half whose pane is shown has a lighter round bezel; no divider | **stays at x 96–171**; neither half has a bezel; a hairline divider shows between the halves |
| **Run \| Stop** | x 209–281: right-aligned in the navigator's column, ≈ 9 pt inside its 290-pt edge | **stays, moved left to x 180–255**, ≈ 9 pt after the group |
| **Back \| Forward** | x 297–372, ≈ 8 pt after the navigator's edge | x 261–336, ≈ 6 pt after Run \| Stop |
| Title (project icon at) | x 385 | x 348 |
| Centre group (New Conversation, scheme › destination, issues) | centred over the area right of the navigator's column | shifted left by ≈ 145 pt (half the navigator's width): New Conversation's left edge ≈ 725 → ≈ 580 |
| Right group and inspector toggle | pinned right | unchanged |
| » | none at 1400 pt | **none at 1400 pt** |

With the navigator shown, the toolbar's band above the navigator belongs to the
navigator's column (its edge at x 290 shows); with it hidden the toolbar is one
band.

**Requirement for Ycode:** the Navigators / Coding Assistant group and Run | Stop
stay in the toolbar whenever the navigator area is hidden, whatever hid it (⌘0,
the toggle, View ▸ Navigators, a live resize), at the positions above. No » may
appear at 1400 pt for this reason. If a platform's toolbar hides the items it
places over a collapsed sidebar, Ycode places these items so that they are not
hidden (round 12: Ycode dropped both, shifted Back / Forward to the traffic
lights and showed » at 1400 pt).

### 5.2 What the toggle and ⌘0 do

| Input | Effect |
|---|---|
| Click the **Navigators** half while the area is hidden | shows the navigator area with the navigator it last showed (here the project navigator, its selection kept); slides in (§6.1); the Navigators half gets the bezel |
| Click the Navigators half while the navigators are shown | hides the area (slide, §6.1) |
| Click the **Coding Assistant** half while the area is hidden | not recorded (OPEN; expected: shows the area with the assistant) |
| ⌘0 (View ▸ Navigators ▸ Show Coding Assistant) with the navigators shown | swaps the area's content to the coding assistant **in place, one frame** (first change ≈ +110–220 ms; the area keeps its 290 pt); the Coding Assistant half gets the bezel |
| ⌘0 again (the assistant shown) | hides the area (slide, §6.1) |
| ⌘0 while hidden | not recorded (OPEN) |

The owner's decision stands: ⌘0 opens the coding assistant.

## 6. Panel motion (P-190, P-191; council round 12 C01, C02, B15, main 16)

Method: the edge or content that moves was tracked frame by frame (the editor's
text by phase correlation for the navigator; the editor's bottom bar for the
debug area). Whole-frame difference timing, which the judges and the round 12
INDEX quote, also counts unrelated changes in the same clip (the title's
subtitle, the caret, activity text); where the two disagree the tracked value
is the reference.

### 6.1 The navigator area (P-190)

| Trigger | Motion starts after the input | Editor's travel | Duration | Curve | New positions |
|---|---|---|---|---|---|
| ⌘0, second press (hide) | +60…+83 ms | 290 pt left | 230–240 ms | ease-in-out | every 20 ms (≈ 12) |
| Navigators half clicked (hide) | +79…+89 ms | 290 pt left | 240–260 ms | ease-in-out, cubic ≈ (0.41, 0, 0.57, 1.0) | every 20 ms |
| Navigators half clicked (show) | +146…+172 ms | 290 pt right | 220–240 ms | ease-in-out, cubic ≈ (0.2, 0, 0.6, 1.0) | every 20 ms |

- The editor's left edge and the navigator's right edge move together: the
  navigator slides out of (or in from) the window's left edge at its full
  width; its content is not squeezed.
- The toolbar's items do not travel with it: they switch to the other
  arrangement of §5.1 in 2–4 frames (≈ 30–40 ms), **at the start of a hide**
  and **at the end of a show**.
- Whole-frame timing of the second ⌘0: +23 → +313 ms (≈ 290 ms, 13 frames),
  which adds the toolbar's switch to the slide. This is the "≈ 290 ms" of the
  council summary.
- **Reconciled with P-190's 2x numbers:** hide +93 → +334 ms, second ⌘0 +42 →
  +292, show +102 → +344: the same ≈ 240–250 ms. The 2x row called the hide
  ease-out and the show ease-in from whole-frame pixel fits; tracking the
  editor's edge fits ease-in-out far better (error 0.001–0.014 against
  0.10–0.19 for ease-out). **Use: 240 ms, ease-in-out**, starting within
  ≈ 80 ms of a key and ≈ 150 ms of a click.
- Ycode in round 12: the second ⌘0 removed the area in one frame (+137 ms);
  the toggle click did nothing (§5.1).

### 6.2 The debug area (P-191)

⇧⌘Y with Shapes.swift open; the debug area's stored height here was 102 pt.

| | Motion | Duration | Curve |
|---|---|---|---|
| Show | the editor's bottom bar rises 102 pt, from +69 to +319 ms after the key (first whole-frame change +49) | ≈ 250–270 ms | **linear**: 4 pt every 10 ms, 8 pt every 20 ms, throughout |
| Hide | it falls 102 pt, from +78 to +338 ms (first change +58) | ≈ 260–280 ms | linear, the same steps |

- The council's "450–560 ms in several steps" is whole-frame timing that runs
  on through small, unrelated changes after the panel stops (+330 ms onward:
  the caret and a few small text regions). The panel itself stops at +320 /
  +338 ms.
- **Reconciled with P-191's 2x numbers:** hide +74 → +307 ms (233 ms), show
  +127 → +319 (192 ms): the same end times and similar durations. The 2x curves
  (ease-in / ease-out) were whole-frame fits; the edge moves at constant speed.
  **Use: ≈ 250 ms, linear, starting within ≈ 70 ms of the key**, for a debug
  area of ≈ 100 pt. Whether a taller debug area keeps 250 ms or the speed
  (≈ 0.4 pt/ms) is OPEN.
- Ycode in round 12: one motion of 180 ms (show, from +149 ms) and 240 ms
  (hide, from +79 ms).

### 6.3 The coding assistant pane (B15)

⌘0 with the navigators shown swaps the area's content to the coding assistant
**in one frame** at +110 ms (the area keeps its width; a few small regions of the
new list fill in over the next ≈ 50 ms). There is **no slide**. The ≈ 450 ms the
judges measured is the window title's subtitle ("Finished running Parity")
ending in the same clip: the subtitle fades out (≈ +190 → +310 ms) and the title
moves down ≈ 7 pt to the toolbar's centre line (≈ +160 → +530 ms). Ycode's
two-frame change (80 ms) is right for the pane and must not become a slide.
Whether ⌘0 ends the subtitle or it expired at that moment is OPEN; the
subtitle's own exit (fade, then the title's move) belongs to the title area.

### 6.4 Adding an editor pane (main 16)

Add Editor ▸ Editor Pane On Right: the new layout appears **in one frame**; one
more frame, ≈ 64 ms later, fills in only the new pane's jump-bar text (a
212 × 12 pt region). The "93 ms" was these two frames; there is no slide
(`editor-area.md` §E.2 stands). Ycode's one frame is right; its new pane's jump
bar should be complete in that frame or within ≈ 60 ms.

### 6.5 Summary for Ycode

| Panel | Use |
|---|---|
| Navigator hide / show (⌘0, toggle, menu) | slide 290 pt, 240 ms, ease-in-out; toolbar switches in ≈ 30–40 ms at the start of a hide and the end of a show |
| Debug area hide / show | ≈ 250 ms, linear |
| Coding assistant swap (⌘0 with the navigators shown) | one frame |
| Split editor added | one frame |
| Inspector | `editor-area.md` §H.2 and `workspace-window.md` §W7.3 (not re-measured) |

## 7. Live-resize latency (P-201, council round 12 T01)

Method: the right edge dragged by the pointer from 2 pt outside the frame; the
edge read in every recorded frame from one pixel row 10 pt below the window's
top and compared with the pointer's scheduled position; frames held at the
minimum left out.

| Drag | Reference median / p90 | Ycode median / p90 (round 12) |
|---|---|---|
| 1400 → 400 pt over 2.0 s (first run) | 66.9 / 78.8 ms | 76.1 / 98.1 ms |
| 1400 → 1100 pt over 1.0 s (first run) | 61.4 / 71.4 ms | 79.4 / 99.4 ms |
| 1400 → 400 pt over 2.0 s (second run) | 55.4 / 67.4 ms | 116.5 / 176.5 ms |
| 1400 → 1100 pt over 1.0 s (second run) | 65.4 / 82.1 ms | 107.9 / 127.9 ms |

Both apps drew a new edge every refresh (10 ms).

**Targets for Ycode (1x, 100 Hz, this method):** pointer-to-edge median
**≤ 67 ms** and p90 **≤ 82 ms**, with a new edge position every refresh, for
both drag lengths, including the drag through the navigator's collapse (§4.2).
P-201's earlier "≈ 106 ms" (against Ycode's 162 ms) and `fidelity-council.md`
row 206's "begins 83 ms after the drag" came from main step 17's whole-frame
timing (the delay to the first change, not the lag behind a moving pointer);
round 12's tracked edge replaces them as the target.

## 8. Changes for work in progress

- **P-024 (B5-MOTION):** the side areas are 290 / 260 and never change above
  the point where the editor reaches 300 pt; on a live drag the navigator
  **collapses** at that point instead of shrinking (new, §4.2); the minimum is
  ≈ 503 pt with the inspector shown and **≈ 410 pt with it hidden** (new,
  §4.1); a programmatic frame below the content's width clips the content
  (§4).
- **P-025 (B5-TOOLBAR):** the thresholds of §2 hold for both side areas shown;
  with an area hidden they move by the freed width (§2.3: −210 pt for the
  inspector, −35 pt for the navigator); with the navigator hidden the
  Navigators group and Run | Stop never enter »; the minimum's » menu has 11
  rows in Ycode (§2.4). Earlier: editor-mode fold 1350 (light 1325); » at 1150;
  Editor Options 1075, Add Editor 1050, Issues 1000, the scheme capsule 950, New
  Conversation 875; the issue count drops at 1200; the scheme title truncates at
  1250 and goes at 1225, the destination title goes at 1175; Run/Stop leave at
  725 and the title at 625 (both shown, b5-obs); overflow menu items carry the
  toolbar glyphs (§2.1, §2.4).
- **P-190:** keep the toggle and Run | Stop (§5.1); the toggle's clicks (§5.2);
  the slide: 240 ms ease-in-out for every trigger, including the second ⌘0 (§6.1).
- **P-191:** ≈ 250 ms, **linear**, not the 450–560 ms of the council summary
  (§6.2).
- **B15 and main 16:** no slide; one frame (§6.3, §6.4).
- **P-201:** median ≤ 67 ms, p90 ≤ 82 ms (§7).

## 9. OPEN

1. The navigator's collapse point and the inspector's narrowing with the
   inspector **shown**, on a live drag at 25-pt resolution (§4.2 rule 2 predicts
   ≈ 850 pt), and the order in which they happen.
2. The 9-pt difference between the two toolbar floors (408 and 417 pt) with the
   same items (§4.1).
3. The minimum with the debug area open and for other window kinds (a lone file,
   a package).
4. The 10-pt refinement of every threshold in §2 and §2.3 (25-pt steps, or a
   fast drag, here); the light appearance in round 12's states.
5. Why b5-obs's 825-pt still clipped on the right and the 800-pt one on the left
   (both set the same way), and why 2026-11-15's one-step resize to 700 shrank
   the navigator while b5-obs's steps clipped it.
6. ⌘0 and the Coding Assistant half while the area is hidden (§5.2).
7. Whether ⌘0 ends the title's subtitle (§6.3).
8. The debug area's slide for other heights (§6.2).

## Evidence

| Claim | Level | Source |
|---|---|---|
| §1 areas | 3 | b5-obs 2026-11-20, item 4: the split view's, scroll areas' and splitters' accessibility frames at 1400, 850, 800, 700 and 500 pt; stills at every 25 pt |
| §2, §3 toolbar thresholds | 3 | b5-obs 2026-11-20, item 4: stills at every 25 pt in dark and light (items present or gone), accessibility trees at every 50 pt |
| §2.1 overflow menu | 3 | b5-obs 2026-11-20, item 4: the menu's still and its items in the accessibility tree at 500 pt, both appearances |
| §2.2 | 3 | `fidelity-council.md` rows 159 and 218 |
| §2.3, §2.4 | 3 | council round 12 (2026-11-21), C10: the live-drag recordings with the window's width read from every frame (toolbar stills at 25-pt widths), the accessibility trees at 1100, 900, 817, 700 and 503 pt and at the minimum, the » menus' stills and items |
| §4, §4.1, §4.2 | 3 | council round 12, C10 and T01 (both drags: the window and split-view frames at the minimum, the frames before and after); parity 2026-11-15, items D-007, D-008, D-009, A-S-028; b5-obs 2026-11-20, item 4 |
| §4 rules for Ycode | — | the owner's design rule; a reconciliation of the runs, not an observation |
| §5 | 3 | council round 12, C01: toolbar stills before and after each ⌘0 and toggle click, toolbar item frames from the accessibility trees with the navigator shown and hidden |
| §6.1 | 3 | council round 12, C01 (both sessions): the editor's text tracked by phase correlation in every frame; toolbar items tracked by their glyphs; parity 2026-11-15 (inventory P-190) |
| §6.2 | 3 | council round 12, C02: the editor's bottom bar tracked in every frame; parity 2026-11-15 (inventory P-191) |
| §6.3, §6.4 | 3 | council round 12, B15 and main 16: frame-to-frame differences located by region |
| §7 | 3 | council round 12, T01: the edge against the pointer's scheduled position in every frame |

Nothing here rests on levels 4 or 5.
