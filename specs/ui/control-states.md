# Control states: rest, hover, pressed, focus, disabled

**Status:** boundary spec for B5-STATES (issues #63 and #64, inventory row P-198).
It describes how the reference, Xcode 27.1, draws each kind of control at rest,
under the pointer, while the mouse button is held, with keyboard focus and when
disabled, in dark and light appearance, and what acts on mouse-down rather than
on mouse-up. Prose, tables and measured numbers only: no code, no copied
resources. Both of Ycode's IDEs build from it (the macOS `YcodeUI` and the Linux
`ycode-ide` on OpenViews); §9 says what the Linux side needs.

**Capture conditions.** Unless a row says otherwise the values come from the
b5-obs capture of 2026-11-20: a 1x display at 100 Hz, the workspace window
1400 × 880 pt, key and in front, Xcode's appearance set to System (dark) and then
to Light in the same launch, while the host ran other builds (1-minute load
between 7 and 150). Sizes are points at 1x, **±1 pt**; colours are sRGB from 1x
stills (hairlines approximate); timings are **±20 ms** (most recordings delivered
a frame every 20 ms). "One frame" means the change is complete in the first
captured frame after the input. Earlier measurements (the parity run of
2026-11-15 at 2x / 120 Hz, council rounds 1–11) are quoted where they differ; for
timings the 2x value is preferred, for behaviour the newer one.

Words: *hover bezel* is a filled shape that appears inside a control under the
pointer; *held* is the state 0.4 s after mouse-down with the button still down;
*grow* means the control's own shape gets larger.

## 1. Summary of rules

1. **Hover is one frame on and one frame off** wherever the reference has a hover
   state (no fade in or out), except the editor tab's close button, whose bezel
   fades out (≈ 150 ms).
2. **Most controls have no hover state at all**: navigator selector tabs,
   inspector tabs, segmented controls, sheet push buttons, switches, disclosure
   triangles, Settings sidebar rows, the navigator filter field and its buttons,
   the editor's bottom-bar buttons, and disabled controls. Hover belongs to the
   toolbar's glass controls, the Settings pop-up buttons and the editor tabs.
3. **Toolbar glass controls grow and brighten while held** (animated, ≈ 100–145 ms
   to 90 %), and settle back after release (≈ 120–320 ms). Flat controls
   (segments, sheet buttons) change tint in one frame and do not grow.
4. **Glass tab bars (navigator selector, inspector tabs) show a glass lens** under
   the pressed tab. The lens follows the pointer along the bar while the button is
   down; the selection changes on mouse-up.
5. **Mouse-down acts** for every control that opens a menu or popover (scheme and
   destination choosers, pop-up buttons, the filter options menu) and for Settings
   sidebar rows. Everything else acts on mouse-up inside the control; releasing
   outside cancels (nothing opens, nothing closes).
6. **No focus rings** are drawn in the workspace without Full Keyboard Access: a
   focused field shows only its caret.

## 2. Toolbar glass controls

The toolbar band is dark #29292A / light #EDEDEE over the side areas (light
#FFFFFF over the editor, `liquid-glass.md` §8.1). Every item is a glass capsule or
circle **36 pt tall** (window y 8–44) with fully rounded ends. At rest a capsule's
fill is dark #434344–#444446, light #F0F0F3–#FCFCFC; its top rim dark #696A6C /
light #FFFFFF, its bottom rim dark #747577 / light #D8D8D9. A group's selected
segment carries a recessed grey pill (dark #58585A, light #DDDDDF), never the
accent colour.

| Control (frame at 1400 pt) | Hover bezel | Dark rest → hover | Light rest → hover | Held |
|---|---|---|---|---|
| Run (37 × 36 segment of the 76 × 36 Run/Stop capsule, x 208) | a rounded bezel ≈ 34 × 28 inside the segment; **the 1-pt divider between Run and Stop disappears while Run is hovered** | #444446 → #58585A | #F0F0F3 → #E7E7E7 | the capsule brightens and grows; the pressed segment shows a lighter round bezel; tint dark #6E6E71, light #ECECEE. Held ≈ 374 ms, the Run / Test / Profile / Analyze menu opens under the button (P-028) |
| Navigators segment, selected (38 × 36, x 96) | bezel ≈ 32 × 28 | #58585A → #6D6D6F | #DDDDDF → #D2D2D2 | dark #6E6E71, light #FDFDFD; the group grows |
| Coding Assistant segment (40 × 36, x 134) | bezel ≈ 33 × 28 | #444446 → #58585A | #F0F0F3 → #E6E6E6 | dark #767678, light #F4F4F6; the group grows; released outside, nothing opens |
| Inspector toggle (a 36-pt circle in a 40 × 52 item, x 1356) | the whole circle | #434345 → #58585A | #F0F0F3 → #E6E6E6 | dark #8C8C8F, light #F9F9FB; the circle grows to ≈ 39–40 pt |
| Scheme › destination capsule (36 tall; its two halves are separate targets) | only the hovered half: a bezel as wide as that half's content (here scheme 77 × 28, destination 101 × 28) | #424242 → #4B4B4B | #FAFAFA → #EDEDED | **the chooser popover opens on mouse-down** (its arrow is already in the held frame); the pressed half tints dark #505050, light #DFDFDF |
| Issue capsule ("⚠ 1", a 65 × 52 item, x 807) | bezel ≈ 53 × 28 | #424242 → #565656 | #FAF9F9 → #EFEEEF | (not recorded) |
| Stop, disabled | none | — | — | see §7 |

**Timing.** Hover appears and disappears in one frame for every toolbar control in
both appearances (40–85 ms after the pointer event, which is the next captured
frame). Held: the tint and grow start 40–60 ms after mouse-down and reach 90 % at
**100–145 ms** (Run 104 ms dark, 144 ms light; Navigators 110 ms; inspector
62–115 ms). After release or leaving, the control settles back in **120–320 ms**
(Run 323 ms dark; inspector 121 ms dark, 214 ms light). The parity run of
2026-11-15 (2x) measured the pressed tint's first change at +37 ms on Run; it did
not measure the grow.

**Grow.** At 1x the held shape is about 1–2 pt larger on each side than at rest
(Run/Stop ≈ 76 × 36 → ≈ 78 × 38; the inspector circle 36 → ≈ 39–40). The b5-obs
first-pass note of "4–6 pt" included the shadow and, in light, the long-press menu;
use 1–2 pt.

## 3. Glass tab bars: navigator selector and inspector tabs

No hover state. Mouse-down shows a **glass lens** over the bar: a circle about
**42 pt** across on the navigator selector (its tabs are 30 × 28, the capsule 30
tall), a capsule about **98 × 40 pt** on an 82 × 28 inspector tab. The lens is
larger than the bar and overhangs it above and below; it is clear glass with a
thin bright rim and a faint coloured fringe at its top and bottom edges, and the
glyph under it shows slightly magnified. Tint inside it: navigator dark
#5E5E60 → #423F41, light #E8E8EB → #DDDEDE (90–165 ms); inspector dark
#626265 → #49494B, light #E9E9EC → #E5E5E7.

Behaviour, from the navigator recording:
1. On mouse-down the lens rises over the **currently selected** tab and glides to
   the pressed tab (it reached the pressed tab, two tabs away, ≈ 0.35 s after
   mouse-down under load).
2. While the button is held, the lens **follows the pointer along the bar**,
   tab by tab, even when the pointer leaves the bar vertically.
3. The navigator's content does **not** change while held. On mouse-up the tab
   under the lens (or the last tab the pointer crossed, if it left the bar)
   becomes selected and its content shows in the next frame; the lens shrinks
   into the selected pill over ≈ 150–250 ms.
4. Consequence: dragging off the selector selects the last tab crossed (here
   Reports). Releasing outside a tab bar is **not** a cancel.

## 4. Flat controls

| Control | Hover | Held | Timing |
|---|---|---|---|
| Segmented control (Build Settings Basic / Customized / All, Combined / Levels; 24 tall) | none | the pressed segment takes the **selected fill** and its label dims: track dark #303030 / light #F3F3F3; selected segment dark #A2A2A2 / light #7A7A7A with a white label; pressed unselected segment dark #A0A0A0 / light #787878, label dark #E8E8E8 → #C4C4C4; the divider beside it disappears | one frame |
| Sheet default button (Next, OK, Perform Changes; 96 × 24 blue #0078FE) | none | dark **lighter** #2C85FD, light **darker** #006CE5 | one frame |
| Sheet Cancel (96 × 24) | none | dark #2F2F31 → #434345, light #EBEBEB → #D3D3D3 | one frame |
| Settings pop-up button ("Use System Setting", 166 × 24) | a bezel over the whole control: dark #232326 → #343436, light #F6F6F6 → #E4E4E4 | **the menu opens on mouse-down** (the held frame shows it, selection tint dark ≈ #416468 blend, light ≈ #CCDFF7 blend) | hover one frame in, one out (≈ 50–60 ms) |
| Settings switch (36 × 16) | none | a slight darkening around the knob (dark #232323 → #272729, light #FDFDFD → #F5F5F5) | — |
| Settings sidebar row (180 × 32) | none | **selects on mouse-down** (dark #434345 → accent #0078FE, light #D6D6D6 → #006EF4) and its pane opens | one frame |
| Navigator filter field | none | none (a text field) | — |
| Filter options button in the field | none | **its menu opens on mouse-down** | — |
| "Recent files" toggle in the filter field | none | dark #575759 → #69696C, light #D0D0D2 → #D3D3D6 | — |
| Outline disclosure triangle | none | no visible change at 1x | — |
| Editor bottom bar "show debug area" | none | the glyph brightens in dark (#6E6E6E → #979797) and darkens in light (#AEAEAE → #767676) | — |
| Target tabs in the project editor | none | **none** (parity 2026-11-15, item D-046) | — |

The 2026-11-15 run gave the pressed Customized segment as #A2A2A2: the same as
the selected fill measured here. The sheet buttons are pressed only; neither
appearance has a hover state on them.

## 5. Editor tabs

- **Hover** (an unselected tab, 415 × 24 here): no bezel; its close **×** (at the
  left end) and **pin** (at the right end) buttons appear in one frame. After
  ≈ **1.1–1.35 s** a rich tooltip appears: the file name in bold, then the group
  path ("Parity ⟩ Parity") with the project glyph (2026-11-15: ≈ 1.05 s).
- **Close button** (18 × 18): hovering it shows a 16 × 16 round bezel
  (dark #575757 → #606060) that **fades out over ≈ 150 ms** when the pointer
  leaves; held #686868; releasing outside does **not** close the tab.
- A press-and-drag on a tab tears it off (not a pressed state).

## 6. Keyboard focus

Recorded with the system's Full Keyboard Access **off** (the default).

1. The navigator filter field, clicked, shows **no focus ring**: only a blue caret
   (dark #2360A5) inside the rounded field. Tab moves focus out of it (the caret
   goes); the third Tab brought it back.
2. Tab with the caret in the source editor **inserts a tab character**; focus
   never leaves the editor.
3. No focus ring was seen on any toolbar control.
4. The navigator's selection is accent (dark #007AFF, light #0070F5) only while
   the navigator has focus; otherwise the unfocused grey (dark #464647,
   light #D7D7D8), including while a palette such as Jump to Line is in front
   (`specs/ide/popovers.md` §8).

Ycode today draws a thick blue focus ring in its palettes' fields (inventory
P-031): remove it where the reference has none.

## 7. Disabled controls

- A disabled toolbar button keeps its glass shape; only the glyph dims: Stop with
  nothing running is dark **#7A7A7B**, light **#A5A6A7** (council round 2, light:
  #A2A2A4). Back and Forward with no history: light #AEAEAE (`liquid-glass.md`
  §8.1).
- A disabled control has **no hover** and no pressed state.
- **Mouse-down on a disabled toolbar button starts a window drag** (the press
  falls through to the toolbar background). Ycode should do the same: a disabled
  toolbar item must not swallow the drag.
- Disabled menu rows and pop-ups follow the system (dimmed label, no highlight).

## 8. Tooltips

| | council round 12 (2026-11-21; 1x, 100 Hz, load ≈ 6) | b5-obs (1x, 100 Hz, under load) | parity 2026-11-15 (2x, 120 Hz) | Use |
|---|---|---|---|---|
| Delay on a toolbar control | **1560 ms** after the pointer arrives (Run) | ≈ 1.58 s | ≈ 1.6 s; Run ≈ 1.5 s | **1.56 s** |
| Delay on an editor tab (rich tooltip) | — | ≈ 1.1–1.35 s | ≈ 1.05 s | 1.1 s |
| Appearance | one frame, no fade-in | one frame | one frame | one frame |
| Hold after the pointer leaves | **360 ms** | ≈ 360 ms | first fading frame **338 ms** after the pointer left (recorded earlier as "≈ 290 ms") | **350 ms** |
| Fade | **≈ 460 ms, linear**: 10 steps 50 ms apart, the brightness falling by the same amount each step | ≈ 460 ms | the recording **ended** 310–330 ms into the fade, the tooltip still ≈ 40 % visible and falling at the same rate | **460 ms, linear** |
| Pointer moves straight to another control with a tooltip | not recorded | not recorded | the new tooltip **replaces** the old one in one frame **330–355 ms** after the move (three moves); no fade, no new 1.56-s delay | §8.1 |

**Reconciled (P-197).** The "290 + 310 ms" of 2026-11-15 were not a different
behaviour: the 310 ms was where that clip stopped, part-way through the fade, and
the hold measures 338 ms to the first fading frame. Two 1x runs, one under heavy
load and one at a load of ≈ 6, give 360 + 460 ms, and the 2x hold and fade rate
agree with them. The fade is linear in opacity and the reference updates it
every 50 ms (10 steps); Ycode may draw a smooth linear 460-ms fade (OPEN only for
whether the 50-ms steps should be copied).

Placement and look (dark, Run's tooltip "Build and then run the current scheme"):
the tooltip's **left edge is at the pointer's x** and its top ≈ **18 pt below the
pointer**; one line is ≈ 24 pt tall (214 pt wide for that text); fill #444446
with a 1-pt dark outline (#101012). The light tooltip was not recorded. A tooltip
must also go away on the next click or drag (inventory P-197: Ycode can leave one
drawn ≈ 12 s).

### 8.1 When the pointer moves on

1. **Away to a place with no tooltip** (the editor, here): the tooltip stays
   ≈ 350 ms, then fades linearly over ≈ 460 ms.
2. **Onto another control with a tooltip while one is showing**: the old
   tooltip stays for the same ≈ 350 ms; then, instead of fading, it is replaced
   in one frame by the new control's tooltip, placed for the new control (§8
   placement). There is no fade of the old one, no fade-in of the new one and
   no new 1.56-s delay.
3. **Onto another control after a tooltip has faded out completely**: not
   recorded (OPEN); until settled, the full 1.56-s delay.
4. A click or a drag removes any tooltip at once, held or fading (inventory
   P-197: Ycode left one drawn ≈ 12 s).

## 9. Implementing it in both IDEs

One model serves both: each control has a **state** (rest, hover, pressed,
disabled; focus orthogonal) and a **trigger** (mouse-down or mouse-up), and the
style tables above map state to fill, bezel and size.

- **macOS (`YcodeUI`).** The system's glass buttons and toolbar item groups give
  the hover bezel, the grow and the lens when Ycode uses the system's own toolbar
  items and tab bars on the macOS 26+ SDK (`liquid-glass.md` §1). Custom-drawn
  controls need tracking areas for hover (repaint at once, no animation), a
  pressed-state animation with B5-MOTION's shared constants (grow ≈ 120 ms in,
  ≈ 200 ms out), and mouse-down actions for the choosers and pop-ups. Remove
  hover from the controls listed in §1 rule 2.
- **Linux (OpenViews).** OpenViews needs, from B5-OPENVIEWS: pointer enter/leave
  per view with a same-frame repaint; a held state distinct from "pressed then
  released" so that a press can be cancelled by releasing outside; an animatable
  scale for the glass grow; mouse-down actions on pop-up buttons and menu
  buttons; a tab bar whose glass lens follows the pointer while held and commits
  on release; a tooltip timer (1.56 s first; a 350-ms hold after the pointer leaves, then
  either a 460-ms linear fade or, over another control, an immediate swap to
  its tooltip, §8.1) and removal on any click. The Linux IDE today draws pressed as 50 % opacity,
  dims disabled controls twice and has no hover on plain buttons (inventory
  P-198, L-018, L-183, L-224); all three change to the tables above.
- **Ycode-only controls** (no counterpart in the reference) follow the HIG and the
  Liquid Glass language: glass controls in the toolbar behave as §2, flat controls
  in sheets and inspectors as §4 (`glass-materials.md` §6).

## 10. OPEN

1. Tooltips: settled by council round 12 (§8: 350-ms hold, 460-ms linear fade).
   Still open: the delay when the pointer reaches a control after a tooltip has
   faded out completely, and whether to copy the fade's 50-ms steps.
2. Pressed states and focus rings **with Full Keyboard Access on** (inventory §8):
   not recorded.
3. The light-appearance tooltip and the light tab-close and editor-tab hover: not
   recorded (the second tab was gone in the light pass).
4. The jump bar's path segments: hover and press not recorded (the pointer fell on
   the tab bar).
5. Whether hovering an enabled Stop also hides the Run/Stop divider (Stop was
   disabled throughout).
6. The issue capsule's held state.

## Evidence

| Claim | Level | Source |
|---|---|---|
| §2 toolbar hover, held tint, grow and timing | 3 | b5-obs 2026-11-20, item 1: hover and press recordings of each toolbar control in dark and light; colours are the median of changed pixels rest → state; durations to 10 % and 90 % of the change |
| §2 Run long-press menu | 3 | b5-obs 2026-11-20, item 1 (light held frame); parity 2026-11-15, item D-045 |
| §3 lens and selection on release | 3 | b5-obs 2026-11-20, item 1: frames of the navigator-tab press recording before, during and after the release; the inspector-tab held still |
| §4 flat controls | 3 | b5-obs 2026-11-20, item 1 (Build Settings segments, New File sheet buttons, Settings pop-up, switch and sidebar row in both appearances); parity 2026-11-15, item D-046 |
| §5 editor tabs | 3 | b5-obs 2026-11-20, item 1; parity 2026-11-15 (inventory P-063) |
| §6 focus | 3 | b5-obs 2026-11-20, item 1 (focused element per Tab press from the accessibility tree; the filter field still) |
| §7 disabled | 3 | b5-obs 2026-11-20, item 1 (stills; the first states attempt, where a press on the disabled Stop moved the window); `liquid-glass.md` §8.1 |
| §8 tooltips | 3 | council round 12 (2026-11-21), T03: the Run tooltip's region tracked in every frame (arrival, hold, each fade step); b5-obs 2026-11-20, item 6; parity 2026-11-15, items A-M-021 (the hover-off clip, re-measured: it ends mid-fade) and the toolbar hover clips that move from one control to the next (Editor Options → Canvas → inspector toggle: the swap times) |
| §9 | 1 / — | Public AppKit documentation of toolbar item groups and glass buttons (macOS 26 SDK); Ycode's own toolkit (OpenViews) |

Nothing here rests on levels 4 or 5.
