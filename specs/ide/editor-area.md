# Editor area: tabs, splits, history, assistant

Ycode module: `YcodeUI` (`EditorAreaController`, `NavigationHistory`,
`Counterparts`, `WorkspaceWindowController`).

## Tabs

- The editor area holds tabs. A tab bar (one button per tab, titled with
  the file name without its extension, with the file icon; the tooltip
  shows the name and the group path) appears with two or more tabs, or
  always after View ▸ Show Editor Tab Bar (reference-ui-2.md §8).
- View ▸ Pin Editor Tab (⇧⌘P) pins the current tab (a pin icon at its
  right end). Opening a file from the navigator replaces the current tab
  unless it is pinned; then the file opens in a new tab to its right.
- File ▸ Close "<file>" (⌃⌘W) empties the focused editor ("No
  Selection"); Close Editor Pane (⌃⇧⌘W, disabled with one pane) closes the
  focused split; Close Window (⇧⌘W); Close Project / Package (⌃⌥⌘W) closes
  the workspace. Duplicate Editor Tab and Open in New Tab (⌥⌘O, the
  navigator's selected file) add a tab.
- The window opens with nothing selected: an empty editor whose jump bar
  reads "No Selection" (reference-ui.md §2).
- File ▸ New ▸ Tab (⌘T): a new tab after the current one, showing the
  same file.
- File ▸ Close Tab (⌘W): closes the tab; with one tab it closes the
  window.
- Navigate ▸ Show Previous Tab (⇧⌘[) / Show Next Tab (⇧⌘]): wrap around
  (reference-ui.md §1 puts them in Navigate).

## Splits

- File ▸ New ▸ Editor Pane On Right (⌃⌘T): a new editor right of the
  focused one, showing the same file; Editor Pane Below (⌃⌥⌘T) stacks it
  below. (Correction 2026-10-19: these are File ▸ New items, not Editor
  menu items; `reference-ui-5.md` §2.2. The Editor menu's Layout ▸ places
  the editor relative to the canvas, §2.7.) The
  first split of a tab chooses the direction for that tab.
- Splits share the space equally when added; each has its own jump bar.
- File ▸ Close Editor Pane (⌃⇧⌘W) closes the focused split (not the last).
- Focus: the editor whose text view became first responder. Commands
  (find, open from the navigator, history) act on the focused editor.

## History

Each editor keeps its own list of the files it showed. Opening a file
appends it (dropping forward entries; reopening the current file adds
nothing). Navigate ▸ Show Previous / Next Location in History (⌃⌘← / ⌃⌘→) and the
toolbar's Go Back / Go Forward buttons move through it without recording.
The jump bar has no history buttons (`reference-ui-5.md` §6.1).

## Counterparts and the assistant

Counterparts of a file, in order (same folder first, then by path):

1. header (`h`, `hpp`, `hh`) ↔ implementation (`m`, `mm`, `c`, `cpp`,
   `cc`, `cxx`) with the same base name;
2. `Foo.swift` ↔ `FooTests.swift`;
3. a class file (`Foo.swift`, `.h`, `.m`) ↔ the storyboards and xibs whose
   `customClass="Foo"` appears; a storyboard/xib ↔ the class files of its
   custom classes.

- The jump bar of the focused editor shows a "Counterparts" pull-down
  when the file has any; choosing one opens it (in the assistant when it
  is shown).
- Editor ▸ Assistant (⌃⌥⌘↩) toggles an assistant editor right of the
  others. It shows the first counterpart of the focused editor's file and
  follows it when another file is opened; with none it shows "No
  Counterparts". Close Editor in the assistant closes it.

## Assistant modes

**Correction (2026-10-19).** The reference has no Editor ▸ Assistant
Mode submenu. Modes are chosen only in the mode pop-up of the assistant's
jump bar, whose list is `reference-ui-4.md` §16. The assistant's jump bar
starts with a close button, then the mode pop-up (`reference-ui-5.md`
§6.1). The table below is Ycode's mapping of the modes it can fill; Manual,
Top Level Objects, Includes and Tests are Ycode's earlier names and give
way to the §16 names (Includes and Included By, Test Classes and Test
Callers; Manual and Top Level Objects are dropped).

Before the correction: Editor ▸ Assistant Mode ▸ (Counterparts, Manual,
Top Level Objects, Includes, Tests), and a mode pop-up at the start of the
assistant's jump bar listing the modes available for the focused file;
the assistant's related-files pull-down is titled with the mode and lists
its files.

| Mode | Offered for | Files |
|---|---|---|
| Counterparts | every file | §Counterparts |
| Manual | every file | none; the assistant keeps what was opened in it |
| Top Level Objects | `.storyboard`, `.xib` | class files (`.swift`, `.h`, `.m`) named after the `customClass` of objects directly inside an `objects` element |
| Includes | C-family files | workspace files named by `#include "…"` / `#import "…"` (angle-bracket includes are skipped) |
| Tests | `.swift`, `.m`, `.mm`, `.h`, `.c`, `.cpp` | `<Base>Tests` files, and test files (`…Tests`/`…Test`) whose text contains the file's first declared type |

The assistant shows the mode's first file (Counterparts, Top Level
Objects, Includes, Tests), or "No <mode>" when there is none; a mode not
offered for the file falls back to Counterparts.

Code Review moved to ⌥⇧⌘↩ so the assistant keeps ⌃⌥⌘↩ (no two commands
share a shortcut).

## Council round 1 measurements (2026-11-04)

These values were measured from the council session's 1x captures of the
reference: a 1400 × 880 window, with the navigator 290 wide and the
inspector 260 wide. The editor therefore spans x 290–1139, and its
content area runs from y 86 to y 842. The window was inactive, in the
light appearance. Capture conditions are in `liquid-glass.md` §7, the
checklist in `fidelity-council.md`, and the method in
`research/notes/council-r1-2026-11-04.md`. The test file is our own
generated Swift file: comment blocks, then structs with `let` properties
and a `func`.

### C.1 Text metrics

| Property | Reference | Ycode in the session |
|---|---|---|
| Advance | **8.0** per character, exactly. 58 columns span 464 with no drift. | about 7.45 |
| Line pitch | **18.0**, the same for wrapped continuation lines (no extra spacing between logical lines) | 15.0 |
| Glyph size | capitals 10 px of ink, x-height 7; baseline 14 below the line's top | — |
| Font | monospaced. The size is consistent with 13 points (reference-ui.md §4: SF Mono), with advances rounded to whole points at 1x. **To confirm in round 2 at 2x**: the advance there is 15.6 px at 13 pt, or 16 if the size is larger. | about 12 pt |
| Code column 0 | x 341: the editor's left edge plus **51** | x ≈ 348 |
| First line | its top at y 93: **7 below** the content top (y 86, under the jump bar's 2-point separator) | its band top at y 88 |
| Visible lines | 42 visual lines in 757 points | 50 |
| Text container's right edge | x ≈ 986: 9–10 before the minimap's separator (x 995). That holds 80 columns in this editor. | wider: it wraps after "so that" |
| Wrapped lines | continue 4 columns past the line's own indentation. A line indented 1 continues at column 5 (reference-ui.md §4 confirmed). The break comes before a word that would pass the container edge: the 78-column comment wraps after "width" because " so" would end at x 989. | — |

### C.2 Gutter and current line

1. The gutter has no background or separator of its own. It is editor
   white, x 290 to the code column.
2. **Line numbers** are right-aligned; their ink ends at x 328 (the
   editor's left edge plus 38), 12 points before the code column. They
   use a **smaller face than the code**: digits are 9 px of ink against
   the code's 10, and step about 6 points against 8 (a two-digit number
   spans 11 points of ink; the code's "10" spans 15). They sit on the code
   line's baseline. Colour **#B8B3B4**. The current line's number is drawn
   in the plain-text colour, #322529.
3. **Current-line band:** x 304–985 and y 93–110, one line pitch (18)
   tall. It starts 14 after the editor's left edge, so it lies under the
   line numbers, and it ends at the text container's edge, not under the
   minimap. Fill **#EEEEEE** on white, corners about 4.
4. Ycode now: numbers end at x 317, 31 points before its code column. Its
   band is x 339–1007, 15 tall, #F2F2F2, and lies under the text only.

### C.3 Sticky scope header

Captured after scrolling 600 points into the file. "struct Section00 {"
(line 17) stays at the top while lines 25 and below scroll.

1. **Band:** y 85–104, 20 points: an 18-point line row with its top at
   y 87, plus 2 points above it. It spans the gutter and the text
   (x 290–994) and stops at the minimap's separator. The minimap is not
   covered.
2. **Background:** the editor's white, nearly opaque. Text beneath shows
   only as a veil: median darkness 0.54 of 255, about 6 % of the
   content's (`liquid-glass.md` §7.3). There is **no outline and no
   shadow**.
3. **Line number:** the header row shows its own line number ("17") in
   the gutter, at the normal place and in the normal line-number colour
   (#B6B2B3). The header's code keeps its syntax colours.
4. **Lower edge:** a 2-point separator, #E5E5E5, at y 105–106, across
   x 290–995. This is the jump bar separator's colour. The line just below
   is at full contrast: no fade.

### C.4 Syntax colours: the default light theme

Colours of fully covered glyph pixels (the median of the five pixels
farthest from the background in each token). Every token kind gave the
same value on several lines, to within ±1. These are recorded at the
owner's request for the council. Earlier specs left theme colours
unrecorded (reference-ui.md §4; settings.md: Ycode's built-in themes are
its own). Whether Ycode's default theme takes these values is the owner's
decision; `fidelity-council.md` marks it as one.

| Token (examples in the test file) | Reference | Ycode in the session |
|---|---|---|
| Keyword (`import`, `struct`, `let`, `func`) | **#C4246E** | #FF2D55 |
| Plain text (`Foundation` after `import`, braces) | **#322529** | #000000 |
| Comment, line and block | **#6A7084** | #808080 |
| String literal (`"Section 00"`) | **#CA2B1C** | #FF383C |
| Number (`0`, `10`) | **#0178B8** | #0088FF |
| Type name in use (`Int`, `String`) | **#9D31CF** | #CB30E0 |
| Type declaration name (`Section00` after `struct`) | **#007D9E** | #CA30DF |
| Other declaration name (`value00` after `let`, `describe` after `func`) | **#006178** | #000000 |
| Line number | **#B8B3B4** | #8B8C8C |
| Current line's number | **#322529** | — |

GPT's "number #006279" was the declaration-name colour. Gemini's
#9B2393, #C41A16, #6A737D and #1C00CF did not match the captures.

### C.5 Minimap

| Property | Reference |
|---|---|
| Place | between the text and the scroll bar lane: a 1-point separator #E6E6E6 at x 995, the minimap from x 996 to x 1122, then the scroll bar's 17-point lane (x 1123–1139) at the editor's right edge |
| Width | **127** plus the 1-point separator, in an 850-point editor (judges: 80, 115, 140; none right). reference-ui-5.md §6.5 has 128 at 962 and 73 at a 480-point split. All three fit **min(128, 15 % of the editor's width)**; confirm at two more widths in round 2. |
| Rendering | the text drawn at **1/6 scale** in both directions: each visual line (wrapped ones too) is a bar 2 points tall on a 3-point pitch, and a character is 1.33 points wide. Bars take their token's colour at about 35 % strength (a comment bar is #CED1D9 on white). Column 0 maps to x 1010, 14 inside the minimap's left edge. **No labels and no boxes**: Ycode's symbol-name pills ("Section00", "describe") have no counterpart. |
| Visible area | a full-width shade, **#EDEDED** on white, from y 87 to y 210 at the top of the file: the editor's 757-point height ÷ 6. Bars inside it blend darker (#BFC2CA). No outline. |
| Scrolling | the minimap scrolls with the text and passes under the toolbar band's veil (`liquid-glass.md` §7.3) |
| Ycode now | about x 1009–1133, with its scroll bar on the minimap's **left** (x 1012–1019) |

### C.6 Opening a file from outside the window (the image step)

**Input.** The session asked Launch Services to open `Stripes.png`, a file
inside the open project's synchronized folder, in the reference app
(`open -a`). This is the open-document event, **not a click in the
navigator**. A navigator click is to observe in round 2; the end state is
expected to be the same.

**Behaviour.** The file opens in the existing workspace window's
editor. No new window opens. Times are from the request:

| Time | What changed (all in the same frame unless stated) |
|---|---|
| +567 ms | The navigator selection moves from Long to Stripes. The jump bar reads "GlassScroll › GlassScroll › Stripes › No Selection". The editor clears to white. The inspector switches to the image's sections: Identity and Type (Type "Default - PNG Image"); On Demand Resource Tags (a "Tags" token field); **Image Properties** (Dimensions, Resolution, Color Space, Alpha Channel, each "--"); **Localization** (a "Localize…" button); Target Membership. Text Settings is gone. The window title becomes "GlassScroll — Stripes.png". |
| +812 ms | "Loading…" appears, centred, with the "Open with Preview" button at the bottom |
| +1164 ms | The image is drawn, in one frame with no fade. Image Properties still showed "--" 2.7 s after the request. |

**Image viewer layout.** The background is white, with no gutter, no
minimap and no frame around the image.

1. The image is **scaled to fit and centred**. 800 × 1800 pixels was drawn
   301 × 678 (scale 0.376), centred on the editor (centre x 714.5). Its
   top is at y 105, 20 below the editor's top, and its bottom at y 783.
2. Below it: a 20-point gap; the **"Open with Preview"** button, flat
   filled #ECECEC, 20 tall (y 803–822), centred, with no border; then 20
   points to the bottom bar's separator (y 843). The fit box is the
   editor's height less 20 above and 60 below.
3. Because the image fits, the viewer has **no scroll area**. The step
   that scrolled the bands under the toolbar could not run in the
   reference.

**Ycode** changed nothing: the editor, jump bar, inspector and row
selection stayed on Long.swift. The open-document event for a file in
the open workspace must open it there, select its row and update all
four in one pass.

### C.7 Hiding the inspector: what the editor does

The input was an accessibility press on the toolbar's Hide Inspector
button. The button's pressed look appears 22 ms after the press, and
motion starts about 40 ms after that.

1. **The inspector slides out rigidly** to the right by its full width
   (260). Its contents keep their places relative to its edge (the
   section header stays 8 points right of the divider in every frame), and
   nothing inside it reflows.
2. **The editor widens every frame.** Its frame is resized live, not
   slid: content centred in the editor (the image) moves by half the
   travel, 130 points.
3. **Duration:** 205–225 ms from the last still frame to the first final
   frame. The recorder's frames are 17–23 ms apart, which limits the
   precision.
4. **Progress** (the divider's travel ÷ 260), from the last still frame:

   | ms | 0 | 21 | 41 | 63 | 86 | 108 | 127 | 147 | 165 | 183 | 202 | 221 | 237 |
   |---|---|---|---|---|---|---|---|---|---|---|---|---|---|
   | progress | 0 | 0.01 | 0.05 | 0.17 | 0.25 | 0.31 | 0.47 | 0.58 | 0.74 | 0.92 | 0.97 | 0.98 | 1 |

   The best cubic fit is **cubic-bezier(0.8, 0.4, 0.65, 1.0) over about
   215 ms** (RMSE 0.017). The motion starts slowly, runs nearly linear
   through the middle and settles over the last 15 %. Standard
   ease-in-out fits worse (0.037, over 256 ms), and so does linear
   (0.060). Implement the table; round 2 confirms the curve at 120 Hz.
5. **Text re-wrap:** not observable here, because the editor showed the
   image. Round 2 must toggle the inspector with a source file open.
6. The judges' "310 ms" included the pressed-state frame before the
   motion and a toolbar frame 35 ms after it. Their "205 pt" came from
   whole-frame phase correlation, which mixed the 260-point slide with the
   130-point re-centring.
7. **Ycode now:** the pressed state shows 18 ms after its press. The
   first motion comes **113 ms** after that, and the last change 367 ms
   after it. There are two pauses of 56 and 71 ms between changed frames.
   The text re-wraps in a final frame (changed region x 306–1399).

### C.8 Scrolling

1. **Travel is 1:1.** 600 points of scroll input moved the reference's
   text exactly 600 points (row matching between the stills). Ycode moved
   it **566**, 5.7 % short, in both directions.
2. **Latency.** The text starts moving in the first frame after the first
   event and stops within one frame (≤ 19 ms) of the last. With these
   synthetic events there is no smoothing tail.
3. **The duration differences are not app behaviour.** The judges
   reported 1198 against 1295 ms for the editor and 987 against 1112 ms
   for the navigator. In each case the harness delivered the same input
   more slowly to Ycode (1.176 against 1.299 s, and 0.993 against
   1.117 s), and both apps followed their input within a frame.
4. **Frame pacing.** The longest gap between changing frames was 35 ms for
   the reference and 53 ms for Ycode while scrolling the editor, and 23
   against 48 ms in the navigator. Both recorders' median frame interval
   was about 19 ms. Ycode drops two or more frames at times. Confirm at
   120 Hz.
5. **Momentum: not observed.** The flick's synthetic events carried no
   momentum phase, so neither app coasted. The reference took 162 ms for
   a 155 ms input. Round 2 needs a real trackpad flick with the window in
   the foreground.

## Council round 2 measurements (2026-11-04)

Round 2 captured both apps in the foreground with the window key: 1x on
a 100 Hz display, 1400 × 880, with the same grid as round 1 (editor
x 290–1139, content from y 86). The recorder writes a frame only when
something changes, so the gaps between changed frames give each app's
frame cadence. Conditions are in `liquid-glass.md` §8, the checklist in
`fidelity-council.md` (round 2), and the method in
`research/notes/council-r2-2026-11-04.md`. These values supersede §C
where they differ.

### D.1 Syntax colours in the active window

All nine token colours in §C.4 are **unchanged** in the active window.
The type names `Int` and `String` are **#9D31CF** (purple). Gemini's teal
#36867A for types, #AD3DA4 for keywords and #D12F1B for strings do not
occur in the captures.

Ycode now matches every token but one: it colours the module name after
`import` (`Foundation`) as a type (#9D31CE). The reference draws it in
plain text, #322529.

### D.2 The pinned scope header during a linear scroll

The input was a 600-point scroll, delivered as 120 events 8.3 ms apart.
Each frame's scroll offset was found by matching rows against the
before and after stills:

| Offset | What the top of the editor shows |
|---|---|
| 0–470 | normal text; no header and no separator |
| **474–480** | the header pins. Line 17 ("struct Section00 {") reaches the header's row (top y 87) and **stops there**, with its line number. The 2-point separator (#E6E6E6–#E7E7E7) appears under it in the same frame. There is no fade-in. |
| 480–600 | line 17 stays pinned while lines 18 onward scroll beneath it. At 600 the first line below the header is line 25, as in §C.3. |

The header pins exactly when the declaration's own line would pass
y 87. It would stay until the declaration's closing line reaches the
header (offset about 726, beyond this scroll).

**Ycode:** in this step it scrolled **1050** points for the same input
(D.3). That left line 42, inside a `/* … */` block between two structs, at
the top. No header belongs there. The judges' "Ycode has no pinned
header" therefore was not tested in round 2.

### D.3 Scroll travel and frame cadence

| Step (input) | Reference travel | Ycode travel |
|---|---|---|
| 03, linear 600 | **600** | **1050** (1.75 ×) |
| 08, bands, linear 1200 | 1200 | 1200 |
| 15, navigator, 500 | 432 | 432 |

The harness's own measurement agrees with these. Ycode over-travelled
only in the first editor scroll after opening the file. The cause is not
visible in the captures; round 1 had Ycode 5.7 % short.

| Step | Reference: median / 90th percentile / longest gap between changed frames | Ycode |
|---|---|---|
| 03 linear scroll | 20.0 / 28.0 / 39 ms | 19.3 / 30.6 / 40 ms |
| 04 flick | 13.0 / 25.6 / 100 ms | 15.7 / **48.7** / 109 ms |
| 08 bands scroll | 20.0 / 22.0 / 40 ms | 19.8 / 22.0 / 33 ms |
| 15 navigator scroll | 19.7 / 24.6 / 33 ms | 22.9 / 29.8 / **75** ms |

The linear scrolls run at about 50 frames a second in **both** apps. The
judges' "Xcode 13.3 ms against Ycode 20 ms" for step 03 is not borne out.
Ycode's gaps are the problem only in the flick and in the navigator.

### D.4 Momentum flick and the top bounce

The input was 8 gesture events of 40 points over 60 ms, then 173 momentum
events (1544 points) over 1.43 s, decaying with a 0.33 s time constant.
The momentum curve is the harness's, so what each app adds is the bounce
at the top.

1. **Reference:** the text reached the top within about 30 ms of its first
   change. It ran on past the top, **overscrolling 83 points**: −19, −39,
   −55, −74, −79, −82, −83 in frames 10–15 ms apart, peaking about 75 ms
   after crossing. It then sprang back as a **critically damped spring,
   ω = 12.6 rad/s (response about 0.50 s)**, with an RMSE of 0.5 points.
   It was within 1 point of rest 0.48 s after the peak and at rest after
   0.58 s.
2. **Ycode:** overscroll **10** points; spring-back ω = 10.5 rad/s (about
   0.60 s); at rest 0.42 s after the peak.
3. The judges' totals (713 against 788 ms) include the input-driven travel
   from different starting offsets (600 against 1050), so they are not
   comparable.

### D.5 Hiding and showing the inspector with Long.swift open

This supersedes §C.7's duration and curve. Round 1 was recorded in an
inactive, background window and with an image open.

| | Hide | Show |
|---|---|---|
| Press to first motion | 43 ms | 118 ms (the pressed state shows at 94 ms) |
| Motion, first moving frame to last | **222 ms**; with fitted ends, about 255 ms | **216 ms**; with fitted ends, about 240 ms |
| Changed frames during the motion | 15; gaps 9–28 ms, mean **15.8 ms** (about 63 per second) | 14; mean **18.0 ms** |
| Best simple curve | ease-in-out (0.42, 0, 0.58, 1) over 248 ms (RMSE 0.046). The free fit, (0.5, −0.05, 0.6, 0.95) over 258 ms, gives 0.024. | ease-in-out over 240 ms (RMSE 0.040) |

Hide progress (the inspector's leading edge, divided by 260), in ms from
the press:

| ms | 43 | 54 | 81 | 95 | 111 | 121 | 144 | 167 | 180 | 189 | 214 | 230 | 240 | 253 | 264 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| progress | 0.01 | 0.02 | 0.08 | 0.15 | 0.20 | 0.31 | 0.44 | 0.51 | 0.68 | 0.77 | 0.87 | 0.91 | 0.97 | 0.98 | 1 |

1. **What moves.** The inspector slides rigidly, as in §C.7. The editor
   widens every frame, and **the text re-wraps progressively during the
   slide, not once at the end**. The second row of line 6 ended at x 859,
   835, 795, 755, 698, 650 and then 618 over successive frames, as words
   moved up a row with each gain in width. Showing the inspector does the
   reverse. The minimap widens with the editor (§D.6).
2. **Nothing else moves.** Line 1's number stays at y 98 in every frame:
   the scroll position and the top inset are preserved.
3. The judges' 305 and 270 ms include the pressed-state frame and a
   trailing toolbar frame.
4. **Ycode, hide:** 135 ms to the first motion, then only four frames over
   144 ms (gaps of 83, 38 and 23 ms). The text re-wraps in a separate
   frame 23 ms after the inspector is gone. **The text then jumps up 40
   points:** line 1 goes under the jump bar and line 3 takes its place.
   This persists through the show and the later steps.
5. **Ycode, show:** 83 ms to the first motion; 309 ms of motion in 12
   frames (mean 28 ms). The text re-wraps progressively.

### D.6 Minimap

| Editor width | Minimap (plus a 1-pt separator) | Share | Source |
|---|---|---|---|
| 551 (window 1100) | **83** | 15.1 % | narrow-window still, drawn at 0.898 scale |
| 850 | **127** | 14.9 % | at rest (§C.5) |
| 1110 (inspector hidden) | **139** | 12.5 % | still after hiding the inspector |

1. **Width.** These fit **min(15 % of the editor's width, about 140)**.
   The 17-point scroll-bar lane is unchanged. `reference-ui-5.md` §6.5's
   962 → 128 does not fit this rule (it would give 140). Confirm with
   several more widths in round 3.
2. **Scale is the same in both apps:** 1/6, a 3-point pitch per visual
   line and about 1.33 points per character. Opus's "Ycode at half scale"
   does not hold.
3. **What differs is the bars.** The reference draws one solid bar per
   token: a whole comment, spaces included, is a single bar, and code
   lines break only between tokens. Ycode breaks its bars at every space
   (one bar per word).
4. **The visible-region shade** is #EDEDED across the full minimap width,
   with no outline, in both apps. The reference's spans y 87–210 at the
   top of the file; Ycode's spans 86–211.

### D.7 Selecting files in the navigator by click

The reference's timings, from the click:

| Click | Navigator band, jump bar, editor, status bar | Inspector | Image |
|---|---|---|---|
| Long.swift (first selection of the session) | +580–660 ms, one frame | 289 ms after the editor | — |
| Stripes.png | +85–160 ms: the editor clears | +61 ms | "**Loading…**" 454 ms after the editor cleared, for about 100 ms; then the image |
| Bands.swift | +100–180 ms | +12 ms | — |

1. The reference **does show "Loading…"** before an image appears, so
   Opus's "Xcode never shows a loading state" is wrong. Ycode's one
   Loading frame (50 ms) is within the reference's behaviour.
2. Ycode changes the editor and the inspector in the same frame, 165–250
   ms after the click.
3. For an image, the reference's status bar shows no "Line: Col:".
   Ycode's still shows "Line: 1 Col: 1".

### D.8 Image inspector text (Stripes.png)

| Row | Reference | Ycode |
|---|---|---|
| Dimensions | "800 × 1800 pixels" | the same text |
| Resolution | **"--"** (the file records no resolution) | "72 × 72 DPI" |
| Color Space; Alpha Channel | "RGB"; "No" | the same |
| Labels | right-aligned, dark (#2C2C2C), regular weight | grey, and "Alpha Channel" clipped to "Alpha Channe" |
| Localize… | a pop-up-style button **as wide as the value area** (x 1152–1387, y 641–656, 16 tall), fill #DCDCDD, title centred | a small button at the left |
| On Demand Resource Tags | a "Tags" token field (y 457–480, #E0E0E1): an image is a resource | "Only resources are taggable" |

Whether the separator is "×" (U+00D7) or the letter "x" cannot be told at
1x: both apps draw the same small cross. **Retina capture needed**, or the
value read through Accessibility.

### D.9 Add Editor menu

The failed split step left the reference's Add Editor menu open in the
following stills. Its items are "**Tab**" (⌘T), "**Editor Pane On
Right**" (⌃⌘T) and "**Editor Pane Below**" (⌃⌥⌘T). The harness had looked
for "Add Editor Pane on Right", which is why the split failed. Ycode's
items are "Add Editor Tab", "Add Editor Pane on Right" and "Add Editor
Pane Below".

## Council round 3 measurements (2026-11-05)

Round 3 captured both apps at **Retina (2x)**, foreground, key window,
120 fps, 1400 × 880 (1100 × 880 after the narrow-window step), with the
same grid as rounds 1 and 2 (editor x 290–1139, content from y 86).
Values are in points with half-point precision. The Mac was under heavy
load during the scroll and flick steps, so durations there are weighed
lightly; shapes and amplitudes are reliable. Checklist rows 70–77 in
`fidelity-council.md`. These values supersede §C and §D where they
differ.

### E.1 Momentum flick: start and spring (supersedes D.4 in part)

Step 04: a momentum flick back up 600 points.

| Time from the first moved frame | Reference: travel (pt) | Ycode: travel (pt) |
|---|---|---|
| 0–85 ms | 80 at 17 ms, 280 at 33, 445 at 50, 537 at 67, 580 at 82 | **0 (no movement)** |
| 97–112 ms | 617, 634 | 240, 352 |
| 128–160 ms | 642, 645, **647.5 (peak at 157 ms)** | 494, 660, 679 |
| 188–215 ms | 644, 638 | 710, **724 (peak at 202 ms)** |
| 245–300 ms | 632, 631 | 714, 696 |
| 342–408 ms | 621, 614, 609 | 660, 645 |
| 452–508 ms | 606, 603 | 626, 616 |
| 597 ms | 601 | 607 |
| 713 ms | 600 (rest) | 604 (rest at 883 ms) |

1. **No start delay.** The reference moves in the first frame after the
   gesture; Ycode holds still for **85–98 ms**. Remove the delay: content
   must follow the gesture's first event.
2. **Overshoot 8 %.** The reference runs **48 points** past the end of a
   600-point flick (8.0 %), peaking 157 ms after it starts; Ycode runs
   120 points (20 %), peaking at 202 ms.
3. **Return.** From the peak the reference returns as a critically damped
   spring with ω about **11–12.6 rad/s** (half the overshoot gone about
   150 ms after the peak, within 1 point at 440 ms after it). Round 2's
   ω 12.6 still holds; its 83-point overscroll came from a faster input.
   The whole-motion fit the judges quote (response 0.16 s, damping
   fraction 0.69) describes the same curve including the input-driven
   rise; implement it as momentum + the critically damped return, not as
   one underdamped spring.
4. Ycode's whole-motion fit (response 0.47 s, damping fraction 0.45) is
   too soft: overshoot and return both need the reference's values.

### E.2 Split editor: the change is one frame (supersedes the judges' 200 ms)

Step 16: View ▸ Editor ▸ "Editor Pane On Right" with Long.swift open.

1. **Timing.** The reference draws the split in **one frame** (both
   panes, the divider and both jump bars), and **100 ms later** re-lays
   out the new pane's jump bar once (the middle component truncates and
   the issue stepper appears). There is no sliding or growing animation.
   The judges' "200 ms ease-out" spans the frame before the change to
   that second frame. Ycode's one-frame change (12 ms) matches; the
   follow-up jump-bar layout should come in the same frame or within
   100 ms.
2. **Panes.** Left pane x 290–713.5, a divider 713.5–716 (2.5 wide,
   #D7D7D7), right pane 716–1140: equal halves of the editor. Ycode
   matches (its divider is a 1-point line at 715).
3. **Each pane's jump bar** (y 45–84, as the editor's):

| Item | Position from the pane's left edge | Reference | Ycode now |
|---|---|---|---|
| Close button | +14 to +25 (an "×" 11 × 11) | present in both panes, #7F7F7F | missing |
| Grid button | +36 to +49 | present | present |
| Divider | +58 to +59 | 1 point | — |
| Path | from +71.5: project › group › file › symbol | | |
| Issue stepper | ends 15.5–17 before the pane's right edge: back chevron, a warning triangle, forward chevron (each about 7–11 wide, 8 apart) | present in both panes | missing |

4. **Middle truncation.** When the path does not fit, the **middle
   component** (the group) is cut to its first letters ("Gla") with a
   fade over its last **about 4 points**, and keeps its icon and its
   chevron; the first component and the file keep their full names.
   Ycode does not truncate.
5. **Inactive pane.** The pane without focus draws its jump bar dimmed:
   path text **#7F7F7F** (active **#262626**), path icons **desaturated
   to grey** (the project and Swift icons lose their colour), chevrons
   #7F7F7F in both. The warning triangle keeps its yellow in both panes.
   The close button is #7F7F7F in both. Ycode draws both panes alike.
6. **Minimaps stay** in split panes (67 points in a 424-point pane, E.6);
   Gemini's "auto-hide below 350 points" does not hold.
7. **Focus.** The new pane takes focus, so the navigator's selection turns
   to its unfocused colour (`navigators.md`, round 3).

### E.3 Selecting an image: one frame, no "Loading…" (supersedes D.7 for the target)

Step 05, a click on Stripes.png after Long.swift:

| | Reference (round 3) | Ycode now |
|---|---|---|
| Editor | the image replaces the text in **one frame** (the recording's single changed frame) | clears to a blank editor with "Loading…" centred, for **192 ms**, then the image |
| Jump bar, status bar | in the same frame | in the blank frame |

Round 2 saw the reference clear the editor and show "Loading…" for about
100 ms, 454 ms after the click. Together: the reference **keeps the old
content until the image is ready** and shows "Loading…" only when the
image is still not ready after about 450 ms. Target: never clear the
editor first; show the placeholder only after that delay.

### E.4 The open-document request repaints nothing

Step 06: an open-document request (the system's "open this file" event)
for Stripes.png, which is already open in the window.

- Reference: **zero changed frames**. No reload, no flash, the jump bar
  and the inspector unchanged.
- Ycode: the editor flashes blank and repaints over **100 ms**; the jump
  bar drops the group component ("GlassScroll › Stripes" instead of
  "GlassScroll › GlassScroll › Stripes"); the inspector's Full Path
  changes from `/tmp/…` to the resolved `/private/tmp/…`.
- Target: when the requested file is already the window's open document
  (compare by the resolved path), only bring the window forward. Keep the
  project's own path for the file (do not replace it with the symlink-
  resolved path) and keep the navigator item it was opened from, so the
  jump bar keeps its group.

### E.5 The empty editor draws no minimap

With no file open (step 01's "before" still; the conflict session's
Repositories view), the reference's editor area is **pure white** from
x 290 to 1140: no minimap, no minimap separator, no scroll lane. Ycode
draws the minimap's separator (a 1-point #E5E5E5 line at x 995), the
visible-region shade as a grey block (#EDEDED, x 996–1126, y 86–212),
and the scroll lane (#F3F3F3,
x 1126–1137). Draw neither the minimap nor its lane until a text document
is open.

### E.6 Minimap width: a floor (refines D.6)

Measured from the minimap's separator to the start of the scroll lane:

| Editor pane width | Reference | Ycode now |
|---|---|---|
| 850 (one pane, window 1400) | **131** | 131 |
| 424 (split, window 1400) | **67** | 67 |
| 274 (split, window 1100) | **63** | **45** |
| 551 (round 2) | 83 | — |
| 1110 (round 2, inspector hidden) | 139 | — |

The widths fit **clamp(15.5 % of the pane's width, 63, about 140)**: the
reference never makes the minimap narrower than about 63. Ycode follows
the percentage below the floor, so at 274 its minimap is 18 points
narrower and its text column 18 points wider, which makes its lines wrap
about 2 characters later than the reference's. The scroll lane (x 1126–
1137 in a full-width pane) is the same in both.

### E.7 Text layout

1. **Full-block characters take one cell.** In Bands.swift every band row
   is 110 full-block characters (U+2588) after "// ". The reference draws
   them **8.0 points apart**, the editor's cell width (C.1): the band's
   first visual row is 611 wide (x 373–984) and its continuation 273.5,
   884.5 in all. Ycode draws them **6.89 apart** (622 + 136 = 758): its
   fallback font's own advance. Every glyph, including glyphs from a
   fallback font, must advance exactly one cell (8.0 at the default
   size); centre a narrower fallback glyph in its cell and clip a wider
   one. The blocks are 13 tall in both apps; Ycode draws them 1 point
   lower (y 152–165 against 151–164).
2. **Wrap edge.** The band's first row ends at x 984 in the reference
   (the container edge of C.1, about 986) and at x 995 in Ycode, which
   wraps against the minimap's separator. Ycode's container is about 11
   points too wide.
3. **First layout.** Ycode's first layout of Long.swift wraps one word
   later ("width so") than every later layout; the reference wraps the
   same way from the first frame. Lay out with the final container width
   before the first draw.
4. **Wrapped current line.** The reference's current-line highlight
   covers every visual line of a wrapped line (also in the merge sheet,
   `merge-sheet.md` §4.2); Ycode's covers only the first.

## Council round 4 measurements (2026-11-06)

Round 4 captured both apps at **Retina (2x)**, foreground, key window,
120 fps, 1400 × 880 (1100 × 880 after the narrow-window step), with the
same grid as rounds 1–3 (editor x 290–1139, content from y 86). The Mac
was in the **dark appearance** and both apps followed it, so this round
gives the default dark theme; round 1's light values (C.4) stay valid for
light. Ycode was `45c676aa`. Values are in points with half-point
precision. Load was lower than in round 3 (Ycode's first scroll steps at
a 1-minute load of about 100–190, the reference's at about 45). Checklist
rows 83–88 and 106–113 in `fidelity-council.md`. These values supersede §C–§E where
they differ.

### F.1 A run that does not fit moves to the next row (Bands.swift)

Each band line of the test file is "// " followed by 110 full-block
characters (U+2588) with no space between them.

| | Reference | Ycode now |
|---|---|---|
| Visual rows per band line | **3**: "//" alone on the first row; the whole block run starts on the **second** row at the continuation indent (x 373, column 4), fills it to the container edge (76 blocks, x 373–984), and its last 34 blocks take the **third** row (x 373–646.5) | **2**: "// " and the first 77 blocks on the first row (x 365–981), 33 blocks on the second (x 373–637) |
| Pitch of one band line | **54** (3 × 18) | 36 (2 × 18) |
| Lines visible at rest (step 07) | 1–18 | 1–29 |
| Top line after the 1200-point scroll (step 08) | 36 | 45 |
| Block ink in its 18-point row | 13.5 tall, its top **3.5** below the row's top, 1 above the row's bottom; 4.5 of background between rows | 13.5 tall, its top 4.5 below the row's top (1 lower) |

**Rule (target).** Treat a run with no break opportunity as one word. A
run of full blocks has none: Unicode line breaking (UAX #14) gives U+2588
the class AL, and AL × AL does not break. When a word does not fit in the
space left on the current visual row, **start it on the next row** at the
continuation indent. Only when it does not fit even an empty continuation
row, break it after the last character that fits and continue on the
following rows, each at the continuation indent. Ycode breaks inside the
word on the row where it starts, which keeps "// " and the run together
and saves a row per line.

The same rule holds for ordinary words; §F.6 adds one observation about
the space after a word.

### F.2 Cell advance at Retina scale (refines C.1)

At 2x the reference's cell is **8.04**, not 8.0:

- The two block rows above start at the same x and hold 76 and 34
  blocks; their right edges differ by 337.5 for 42 cells (8.036 each).
  110 blocks span 884.5 (8.04 each), as round 3 measured (E.7).
- The continuation row "so that text passes under the toolbar as the
  editor scrolls." (60 characters from column 5) spans x 382–860.5 in the
  reference and x 382–858 in Ycode: 2.5 more over 59 advances.

Round 1's exact 8.0 was measured at 1x, where the advance is rounded to
whole pixels. At 2x the reference uses the unrounded advance (about 16.07
pixels), so glyph edges fall between device pixels. Ycode uses 8.0 at 2x.
Target: use the font's own advance at the backing scale (8.04 at the
default size on Retina), and keep the 80-column container of C.1, whose
edge then sits at about x 984–986. The code column (x 341.5–342) and the
18-point line pitch are unchanged and match.

### F.3 The default dark theme's colours

**Method.** Colours of fully covered glyph pixels: for each token, the
median of the five pixels farthest from the background inside the token's
cell box, on several lines. Antialiased edges are never used. The method
is checked against flat fills: the comment colour sampled from text
(#ABB4CE) and from the full-block runs, which are solid rectangles of the
comment colour (#ABB3CD over about 500,000 pixels), agree within one
unit; the string colour from text (#FF8E7B) and from the string bands
(#FF8D7A) agree within one unit. Values are sRGB as captured.

| Token (examples in the test files) | Reference | Ycode now |
|---|---|---|
| Editor background | **#262626** (with ±1 dither in the capture) | #1E1E1E |
| Plain text (`Foundation` after `import`, braces, `->`, `\(` and `)` of an interpolation) | **#FAF1F3** | #FFFFFF |
| Keyword (`import`, `struct`, `let`, `func`, `static`) | **#FF83B4** | #FF3860 |
| Comment, line and block, and the full-block runs after `//` | **#ABB3CD** | #9A9A9A (#A0A0A0 on line 1) |
| String literal and string bands | **#FF8E7B** (bands #FF8D7A) | #FF4346 (bands #FF4245) |
| Number (`7`, `100`) | **#ECA900** | #0092FF |
| Type name in use (`Int`, `String`) | **#D997FF** | #DC34F3 |
| Type declaration name (`Section01` after `struct`, `Greeting`) | **#00CAFB** | #FFFFFF in the editor; #DC35F2 (the type-in-use colour) in the merge sheet |
| Other declaration name (`value07` after `let`, `describe`, `farewell`, `defaultName`) | **#27A7C1** | #FFFFFF |
| A property used inside a string interpolation (`name` in `"\(name)"`) | **#20AD9D** | #FFFFFF |
| Line number | **#706D6E** | #9A9A9A |
| Current line's number | **#FAF1F3** (the plain-text colour) | #FFFFFF |
| Current-line band, focused pane | **#353535** | #2D2D2D |
| Current-line band, the unfocused pane of a split | **#2A2A2A** (faint, 4 above the background) | #2D2D2D (same as focused) |

1. The judges' "number about #D9C97C" and "comment bands about #C0C4E6 /
   #929CB0" were edge-blended samples from reduced sheets; the table's
   values are the cores. GPT's "Ycode's cyan identifiers are more
   saturated" is wrong in direction: Ycode has no declaration colour.
2. Three declaration colours are distinct in the reference: type
   declarations bright cyan (#00CAFB), other declarations teal
   (#27A7C1), and a property **reference** inside an interpolation
   green-teal (#20AD9D). Ycode should classify all three in both the
   editor and the merge sheet, with the same colours in both.
3. Whether Ycode's default dark theme takes these values is the owner's
   decision, as for the light theme (C.4); the checklist marks it.

### F.4 Full blocks join without seams

| | Reference | Ycode now |
|---|---|---|
| A row of blocks | reads as **one solid bar** of #ABB3CD; a one-device-pixel line (0.5 point), at most 22 levels darker (#979FB5 at its darkest), shows at cell edges only in alternating spans of about 7 cells, where the 8.04 advance puts the edge mid-pixel | a **1-point lighter seam** (#A9A9A9 and #AEAEAE on #9A9A9A) at **every** cell edge: each glyph is drawn slightly wider than its cell and the overlapping antialiased edges add up |
| Between rows | a clean 4.5-point gap of background | the same |

Target: neighbouring full blocks share an edge, with no overlap and no
gap. Either snap each block's left and right edges to the same device
pixel as its neighbour's, or fill a run of full blocks on one visual row
as a single rectangle in the run's colour. Never draw a lighter seam.

### F.5 Hiding and showing the inspector (step 10, 11): a regression

The press is an accessibility press on the toolbar's Hide Inspector /
Show Inspector button. Times are from the start of the press. The
position is the inspector panel's left edge at y 700, where its fill
meets the editor: x 1168 when shown, 1399.5 when hidden (231.5 points of
travel); progress is the share of that travel.

**Reference, hide** (button state changes at 24 ms):

| ms | 48 | 86 | 109 | 141 | 154 | 174 | 193 | 209 | 222 | 249 | 262 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| progress | 0.03 | 0.18 | 0.21 | 0.41 | 0.48 | 0.65 | 0.76 | 0.90 | 0.92 | 1.00 | 1 |

**Reference, show** (the first content change at 116 ms):

| ms | 129 | 154 | 167 | 190 | 216 | 231 | 257 | 269 | 294 | 308 | 334 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| progress | 0.03 | 0.12 | 0.24 | 0.29 | 0.44 | 0.55 | 0.75 | 0.79 | 0.83 | 0.97 | 1 |

| | Reference hide | Reference show | Ycode hide | Ycode show |
|---|---|---|---|---|
| Press to first motion | **48 ms** | **116–129 ms** | 78 ms | 102 ms (jump bar), 132 ms (edge) |
| Motion (first to last moving frame) | **214 ms** | **218 ms** | 245 ms (78–323) | 261 ms (102–363) |
| Changed frames during the motion | **11**, 13–37 ms apart (mean 21) | **12**, 12–26 ms apart | **5**, 41–88 ms apart (71, 88, 45, 41) | **6**, 30–68 ms apart |
| Curve | ease-in-out (0.42, 0, 0.58, 1) over about 226 ms, RMSE 0.035; free fit (0.65, 0.35, 0.60, 0.95), RMSE 0.019 | ease-in-out over about 217 ms, RMSE 0.057 | ease-in shaped: 0.02 at 78, 0.11 at 149, 0.70 at 237, 1 at 282; text re-wraps in a further frame at 323 | ease-out shaped: 0.05 at 132, 0.37 at 177, 0.72 at 232, 0.91 at 300, 1 at 363 |
| Whole-change segment (capture tool) | 305 ms | 292 ms | 414 ms | 395 ms |

1. The reference matches round 2 (D.5: 43 ms and 222 ms for hide; 118
   ms and 216 ms for show). The recorder delivered a frame about every
   12–15 ms; the reference changed on nearly every one.
2. **Ycode regressed.** In round 3 its segments were 321 and 295 ms
   against 323 and 296 with the same curve shape. Now it draws only 5–6
   frames, each held 40–90 ms (about 14 per second), and finishes 60–100
   ms later. The editor re-wraps Long.swift progressively in both apps,
   so each Ycode frame is a full relayout; round 3 ran at far higher load
   and matched, so load does not explain the drop. Look for per-frame
   work that grew since `0c3ae33f` (text layout of the whole file per
   frame, a synchronous minimap or jump-bar update, or an animation that
   is no longer driven by the display link).
3. Target: start the motion within 50 ms of the press (hide) and within
   120 ms (show); animate the inspector's edge with ease-in-out over
   about 220 ms; update the editor's width, re-wrap and the minimap on
   every display frame (at least 60 per second; the reference reaches
   about 75 in this recording).

### F.6 The narrow-window step (17): one frame, then the toolbar's overflow morph

The step sets the window's size to 1100 × 880 with one accessibility
call; it is not a live drag, so neither app runs a live resize.

| | Reference | Ycode now |
|---|---|---|
| Content relayout | **one frame**, 105 ms after the request (the call itself returned at 201 ms) | one frame, 274 ms after the request (its call blocked 264 ms) |
| Toolbar | the overflow capsule ("»") appears at the place of the items it absorbs, **wide**, and shrinks to its circle: its left edge stays at x 798.5, its right edge moves 918.5 → 831 over 155 ms (table) | the scheme capsule is drawn merged with the next group for one frame (x 560–727), then splits (560–636 and 636.5–710) 11 ms later; the "»" circle appears at once |
| What the judges called a "299 ms progressive live resize" | the content frame plus the 12 frames of the overflow morph | — |

Overflow capsule width (right edge − 798.5), ms from the content frame:

| ms | 0 | 13 | 28 | 42 | 57 | 71 | 86 | 99 | 114 | 128 | 142 | 155 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| width | 120 | 105.5 | 83 | 73 | 64 | 50 | 45.5 | 39 | 37 | 34.5 | 33 | 32.5 |

The curve is a fast ease-out (half the change by about 35 ms), like the
other glass shape morphs in `liquid-glass.md`. Target: relayout the
content in one frame as now, but within about 100 ms of the size change;
morph a newly shown overflow capsule from the absorbed items' extent to
its circle over about 150 ms; never draw two capsules merged for a frame.

**Widths at 1100 with the split editor** (the after stills):

| | Reference | Ycode now |
|---|---|---|
| Left pane's minimap | x 487.5–549.5 (**62**), then the 11-point scroll lane 549.5–560.5 | x 488.5–551 (62.5), lane 551–562 |
| Right pane's minimap | x 764–826 (62) | about 62.5 |
| Rightmost text ink in each pane | 476.5 and 753 | 476.5 and 752.5 |

The minimap floor (E.6) is now met; the judges' "61 against 52" is not
borne out. The remaining wrap difference is one line: on line 6's second
visual row the reference breaks "0: a" / "comment" and Ycode keeps "0: a
comment". Both "0: a comment" (from column 5) and "import Foundation"
(from column 0) end at column 17; the reference keeps "import Foundation"
on one row. The observation is reproduced if **the space after a word
must also fit** before the next word may start on that row (at the end
of a logical line there is no space, so "import Foundation" fits). With
F.2's 8.04 cell the space would end at x 486.7, past the container. This
is a single observation: see the open question in `fidelity-council.md`.

### F.7 Momentum flick (step 04)

From the capture tool's segment (the first moved frame is time 0; the
start latency after the gesture is 49 ms in the reference and 56 ms in
Ycode, so round 3's 85–98 ms hold is gone):

| | Reference | Ycode now |
|---|---|---|
| Passes the end of the travel | **55–60 ms** | about 210 ms |
| Overshoot peak | **140–150 ms**, 11 % of the measured travel | 310–350 ms, 10 % |
| Settled | **700 ms** | 818 ms, plus one stray repaint about 930 ms after the start |
| Frame changes | every **13.3 ms** on average | every 31.7 ms (each frame held about 30 ms) |

Ycode's overshoot now matches; its rise is about four times slower and
its frame rate about a third. Step 03 (linear scroll) shows the same
cadence gap (Ycode about every other recorded frame). Ycode's main
session ran at a higher load (100–190 against 45), so weigh the rate
lightly, but the rise time is a curve difference: keep E.1's momentum
(content follows the gesture's velocity from the first event) and make
the rise reach the end in about 60 ms for this flick.

### F.8 Selecting an image (step 05): refines E.3

The reference this round, from the click on Stripes.png:

| ms | What changes |
|---|---|
| 148 | the editor, jump bar and status bar switch to the image editor in one frame: an **empty** canvas with only the "Open with Preview" button at its bottom |
| 212 | the inspector switches to the image's inspector; Dimensions, Resolution, Color Space and Alpha Channel all read **"--"** |
| 608 | "Loading…" appears centred in the canvas (460 ms after the canvas cleared) |
| 689 | the image appears, in one frame |

The properties still read "--" in the after still. Ycode now: one frame
at 229 ms with the image and filled properties (800 × 1800, RGB, No).

Rounds 2–4 together: the reference switches to the image editor at once
and **does not keep the old text** (this supersedes E.3's "keep the old
content"); it draws the image when it is decoded (in one frame when that
is fast, as in round 3); it shows "Loading…" only once the image has
taken about 450 ms; and it shows "--" for any property it has not read
yet (round 2 showed real values). Target: Ycode's single frame is
correct when the image is ready; when it is not, show the empty canvas
with its button, then "Loading…" after about 450 ms. Showing values
immediately is acceptable: "--" is the reference's not-yet-known state,
not a value to copy.

### F.9 The bottom bars

Window points of step 02's after stills, at rest in the active window.

| Element | Reference | Ycode now |
|---|---|---|
| Navigator "+" circle | about **28 × 28** (x 7–35.5, y 844–872), glyph #E3E3E3 | about 31 × 30 (x 6.5–37.5, y 843–873) |
| Filter capsule | x **42.5–282.5** (240 wide), y **844–872** (28 tall) | x 41.5–284.5 (243), y 843–873 (30) |
| Filter-menu glyph (funnel and chevron) | #ABABAC | #807F7F (dimmer) |
| Editor's bottom-left item | a **filled** accent-blue (#007AFF) shape, x 304–321.5, y 856.5–868 (17.5 × 11.5): a rounded rectangle with its right end drawn to a point, like a filled label tag | an outline tag glyph, light grey |

Icons stay Ycode's own: match the filled style, the size and the accent
fill, not the artwork.

### F.10 Empty states and jump-bar text

| Element | Reference | Ycode now |
|---|---|---|
| Inspector, no file selected in the project navigator | "Not Applicable", centred on (1270, 480), **cap height 12** (about 17 points), #757677 | "Not Applicable", cap height 9.5 (about 13.5 points), #717274 |
| Inspector, Source Control navigator's Repositories view with nothing selected | **"No Selection"**, same size and place | "Not Applicable" |
| Jump bar with no file open | the grid button, a 1-point divider, then "No Selection" from **x 337.5** in **#DEDFDE** (the jump bar's normal text colour), cap top 61.5 | no divider; "No Selection" from about x 313.5, dimmed (#565656) |

### F.11 The Welcome window (step 18)

| | Reference | Ycode now |
|---|---|---|
| Frame (in the capture's coordinates, the same for both apps) | x 460–940 (**480**), y **51.5–680.5** (629) | x 460–939.5 (479.5), y 43.5–672.5: the **same size, 8 points higher** |
| First recent row's path | the full path as recorded, "/private/tmp/ycode-council-r4/council-r4/xcode/project" (the symlink-resolved form; it fits the row) | "…D/tmp/ycode-council-r4/council-r4/ycode/project": a longer stored path, truncated at its head |

The judges' "about 11 points narrower" is not borne out. Target: place
the window 8 points lower (centre it as the reference does) and show the
stored path in full when it fits. The reference's truncation mode for a
path that does not fit is not settled.

### F.12 Items raised by one judge, checked

- **Session start.** The reference restores the Plain group expanded:
  13 navigator rows at rest in step 01 (Zeta, Sub, alpha, Beta under
  Plain); Ycode shows 9 (Plain collapsed). Restore each group's
  expanded state with the workspace.
- **The unfocused split pane's current line** keeps a faint band in the
  reference (#2A2A2A on #262626; the focused pane's is #353535); Ycode
  draws the focused band in both panes (F.3).

## Council round 5 measurements (2026-11-06)

Round 5 repeated round 4's main session (Retina, 120 fps, foreground, key
window, dark, 1400 × 880 then 1100 × 880) with Ycode `a1f82372`. Load:
Ycode's session started while the 1-minute load fell from about 265 to 76
(its steps 03–08 at about 150–260), the reference's at 73 → 25; weigh
small timing differences in 03–08 lightly. Values in window points, times
in ms from the action the capture tool posted (from its manifest), frame
times from the recorder's frame list. Checklist rows 115–116 and 133–141
in `fidelity-council.md`. These values supersede §F where they differ.

### G.1 Hiding and showing the inspector (steps 10, 11; refines F.5)

The inspector panel's left edge at y 700 (1168 shown, 1400 hidden);
progress is the share of the travel. The recorder delivered a frame every
10–15 ms in both apps; a value repeated over several frames is a hold.

**Reference, hide:**

| ms | 60 | 88 | 101 | 129 | 145 | 200 | 218 | 232 | 258 |
|---|---|---|---|---|---|---|---|---|---|
| progress | 0.03 | 0.19 | 0.21 | 0.27 | 0.48 | 0.76 | 0.90 | 0.97 | 1 |

**Ycode, hide:**

| ms | 132 | 176 | 210 | 232 | 251 |
|---|---|---|---|---|---|
| progress | 0.02 | 0.44 | 0.77 | 0.97 | 1 |

**Reference, show:**

| ms | 170 | 197 | 211 | 241 | 256 | 288 | 317 | 331 | 345 | 358 |
|---|---|---|---|---|---|---|---|---|---|---|
| progress | 0.07 | 0.10 | 0.24 | 0.36 | 0.52 | 0.75 | 0.79 | 0.83 | 0.97 | 1 |

**Ycode, show:**

| ms | 108 | 120 | 141 | 163 | 187 | 211 | 244 | 286 | 334 |
|---|---|---|---|---|---|---|---|---|---|
| progress | 0.05 | 0.16 | 0.33 | 0.50 | 0.61 | 0.71 | 0.82 | 0.98 | 1 |

| | Reference hide | Ycode hide | Reference show | Ycode show |
|---|---|---|---|---|
| First motion | **60** (round 4: 48) | 132 | **170** (round 4: 116–129) | 108 |
| Motion | **198 ms**, 9 positions (one hold of 55 ms at mid-travel) | **119 ms**, 5 positions, a new one every 34–44 ms | **188 ms**, 10 positions, holds ≤ 30 ms | **226 ms**: 12–24 ms steps to 211, then **holds of 33, 42 and 48 ms** over the last 18 % |
| Shape | ease-in-out | starts late, then fast; the end matches | ease-in-out | ease-out: a third of the travel in the first 33 ms, the last fifth in two late steps |

The end layouts match (Ycode's edge rests at 1169, one point right of
the reference's). The judges' "325 against 250" and "287 against 383"
are the tool's whole-change segments, which include the toolbar's and
the editor's relayout; the edge itself is above.

Target (rounds 4 and 5 together): **hide** starts within about 60 ms of
the press, **show** within about 120–170 ms; the edge moves ease-in-out
(0.42, 0, 0.58, 1) over **about 200 ms** in both directions; a new
position at least every 25 ms through the whole motion, and above all no
holds in its last third (Ycode's show "ends stepped" there).

### G.2 Split panes at 1100: the right pane wraps narrower (step 17)

| | Reference | Ycode now |
|---|---|---|
| Left pane | x 290–563.5; minimap 487.5–549.5 (**62**), scroll lane 549.5–560.5, divider 563.5–566.5 | x 290–562; minimap 489–548 (**59**) then a 3-point darker strip (#1E1E1F) 548–551, lane 551–562, divider 562–565 |
| Right pane | x 566.5–840; minimap 764–826 (62), lane 826–837 | x 565–839.5; minimap 764–823 (59), strip 823–826, lane 826–837 |
| Text start (column 0) | left 341.5, right 617.5 | the same |
| Widest text row ends | left **476.5**, right **753** (each about 11 before its minimap) | left 476.5, right **737** |
| Columns that fit (8.04 cell) | **17 in both panes** | left 17, **right 15** |
| Seen | right pane: "material for" on one continuation row; "import Foundation" on one row | right pane: "material" / "for the" / "capture"; "import" / "Foundation" |

The pane frames are equal in both apps (the judges' "330 against 220" is
not borne out); the right pane's **wrap width** is two columns short in
Ycode. Target: each pane's text container runs from its text start to
about 10.5 before its own minimap, recomputed from the pane's final frame
after the window's size changes; equal panes wrap at the same column
count. Ycode's minimap is 3 points narrower than the 62-point floor of
E.6 and leaves a darker strip before the lane; the reference's minimap
meets the lane.

The left pane's one-row difference ("0: a" / "comment" in the reference)
is F.6's "space after a word" observation, seen again in this round on
the same line of the same file (row 88).

### G.3 The minimap follows the text's visual rows (Bands.swift, step 07)

| | Reference | Ycode now |
|---|---|---|
| Long.swift | one minimap row every **3** points | the same |
| Bands.swift, comment band line (3 visual rows in the editor, F.1) | marks **9** apart | **6** apart |
| Bands.swift, string band line | 6 apart | 6 apart |
| The test file's 12-band group repeats every | **246** points | 210 (14 % less) |

Ycode's editor text now wraps the bands as F.1 requires, but its minimap
still lays the comment bands out on two rows each. Target: the minimap
draws one 3-point row per **visual** row, using the same line breaking
as the text (F.1), so its vertical scale (and its viewport box) matches.

### G.4 Narrowing the window (step 17; refines F.6)

| | Reference | Ycode now |
|---|---|---|
| Content relayout | one frame, **219 ms** after the size request (round 4: 105); the request returned at 308 | one frame at **415**; the request returned at 418 (it waits for the layout) |
| Toolbar, the overflow capsule | appears with the content frame, a little wider than its circle, and shrinks: its right edge (measured at y 14) **841 → 828.5** over 170 ms, most of it in the first 70 | appears **wide** (right edge 915) with a **small "»" that grows**; 915 → 828 over 190 ms |
| Toolbar, other items | settle with the content frame (the scheme capsule shows its two icons only; the issue capsule its symbol only) | the scheme capsule is drawn **merged with the next group** for three frames (441–481 ms), then separates; the toolbar settles at 643 |

Round 4 saw the reference's capsule start 120 wide; round 5 about 40, so
its start width is not a fixed rule. Target: relayout within about 200
ms of the request without blocking the caller; the overflow capsule's
"»" at full size from its first frame; the capsule settles within about
170 ms; never draw two capsules merged (row 107's rule, still open).

### G.5 The image inspector's spacing (step 05)

Ink tops (y) of the inspector's parts for Stripes.png, both apps, the
inspector at x 1146–1400:

| Part | Reference | Ycode now | Ycode − reference |
|---|---|---|---|
| "Identity and Type" header | 87.5 | 89.5 | +2 |
| Name … Full Path rows | 116.5 … 233.5 | the same | 0 |
| "On Demand Resource Tags" header | 267 | 266.5 | 0 |
| Its field | box **289–313** | 281–305 | −8 |
| Separator | **325** | 310.5 | −14.5 |
| "Image Properties" header | **333.5** | 323 | −10.5 |
| Dimensions, Resolution, Color Space, Alpha Channel | **359, 377, 395.5, 413.5** (18 apart) | 343.5, 363.5, 383.5, 403.5 (20 apart) | −15.5 to −10 |
| Separator | 436 | 423.5 | −12.5 |
| "Localization" header | 444.5 | 436 | −8.5 |
| Localize… button | 472.5–488.5 | 451–467 | −21.5 |
| Separator | 505 | 472.5 | −32.5 |
| "Target Membership" header | 513.5 | 485 | −28.5 |
| Its box | from 532 | from 500 | −32 |

**Rule (reference):** a section header's ink starts **8.5** below the
separator above it (Ycode 12.5); the section's content starts **13–18**
below the header's ink (Ycode 4–6); the next separator is **12–16.5**
below the content (Ycode 5.5–9.5); label-and-value property rows are
**18** apart (Ycode 20). With those gaps every part from On Demand
Resource Tags down lands on the reference's y.

**"--".** The reference again showed "--" for all four image properties
in the after still (1.2 s after the step), as in round 4; round 2 showed
values. F.8's target stands: Ycode's filled values are acceptable, "--"
is the reference's not-yet-read state. Whether the reference ever fills
them without another selection is open (`fidelity-council.md`).

### G.6 Switching files (steps 07, 05)

The editor's text area (x 300–850, y 100–800) per frame, from the click
on the navigator row:

| Step | Reference | Ycode now |
|---|---|---|
| 07, Long.swift → Bands.swift | old text to 158 ms; the **empty editor** (its background only, #262626) at 173 and 185; the new text at **202** | old text to 255; the new text at **267**, in one frame |
| 05, → Stripes.png | the empty canvas at 254; "Loading…" at 692; the image at 867 (round 4: 148, 608, 689) | the image at 308, in one frame |

The judges' "blank for about 75 ms" is about **29 ms** (two recorded
frames). Target: the new file's text within about 200 ms of the click;
up to two frames of the empty editor before it match the reference; the
old text must not stay up with the new file's jump bar. Images: F.8.

### G.7 The Add Editor button (step 16)

The button's region (x 920–1010, y 3–48) per frame, from the click on it
(the menu itself is another window and not in the recording):

| | Reference | Ycode now |
|---|---|---|
| Menu-open state | at **90 ms**: a darker rounded square behind the glyph, held while the menu is open | at 64, the same look |
| Bright press highlight | **one frame** at 624 ms (about 13 ms), then back to the menu-open state | bright from **252 to about 363** (110 ms), then a gradual fade back to the menu-open state until about **750** (about 400 ms) |

Target: the bright highlight is a single-frame flash, with no fade. The
judges' "438 ms split transition" is this highlight; the split itself is
one frame in both apps (E.2).

**Split latency (not settled).** The reference drew the split **858 ms**
after the accessibility press on "Editor Pane On Right". Ycode's split
was not in the recording, which ran 1.2 s past the press; it was in the
after still 2.2 s past it. Measure again with a longer post-roll before
acting on it.

### G.8 Issue reporting: the toolbar capsule and the jump-bar stepper

The test project had one warning for the whole main session, and the
conflict session had one warning before the merge and an error and a
warning during it. **Ycode shows neither element in the main window.**

**Toolbar capsule.** A glass capsule in the toolbar's capsule material
(dark fill #444444), **36 tall** (y 8–44), right after the scheme capsule
(7.5 apart): in the 1400 window x **811–872** (61 wide) holding a warning
symbol (a yellow #FFE015 triangle with a white exclamation mark, 17.5 ×
15.5, its left edge 16.5 inside the capsule) and the count ("1", white,
about 13 points) 8 after it. With errors and warnings it holds both
pairs in one capsule, errors first: a red circle with a white cross and
its count, then the triangle and its count (110.5 wide in the conflict
window). In the 1100 window it shows the symbol without the count. It is
there in every captured step of both sessions, so it shows whenever the
workspace has issues; a session with none was not captured.

**Jump-bar stepper.** At the right end of **every editor's jump bar**
(both panes of a split, also for the image): a back chevron (6.5 × 11.5,
#9D9D9D), the symbol of the most severe issue kind (here the yellow
triangle, about 11 × 10.5), and a forward chevron, over x **1084.5–1124.5**
in the 1400 window (its right end 14.5 inside the editor's right edge),
centred on y 66. The merge sheet's jump bar shows the same stepper with
the error symbol; Ycode already draws that one. The chevrons step to the
previous and next issue.

Target: both elements, driven by the workspace's issues (build, live and
project issues), counts by kind, hidden when there are none (Ycode's
choice until a capture without issues).

### G.9 Items raised by one judge, checked or noted

- **Plain group (row 113):** still collapsed at session start in Ycode
  (Sol).
- **Activity subtitle (Opus):** in the conflict session the reference's
  window title had a second line naming a background activity while the
  workspace was still preparing its editor services; Ycode's title has
  none. Low; the wording is the reference's and is not copied.
- **Welcome window path (Opus):** the reference showed the recent
  project's path with the temporary folder's link resolved; Ycode the
  unresolved path. Not measured (the rows are painted out below the
  first).
- **Step 13 (Sol):** "Ycode omits Inner" is wrong; both show Inner.

## Council round 6 measurements (2026-11-07)

Round 6 repeated round 5's main session (Retina, 120 fps, foreground, key
window, 1400 × 880 then 1100 × 880) and conflict session, but in the
**light** appearance (round 5 was dark), with Ycode `0f1408a4`. Ycode's
steps 01–08 were re-run at a 1-minute load of 11–15, the reference's at
10–13, so this round's scroll and flick timings are comparable; steps
10–18 ran at a load of 9–13 for both. Values in window points, times in
ms from the first action the capture tool posted (its manifest), frame
times from the recorder's frame list; the recorder writes a frame only
when the window changes, so a value held over several frames is a hold.
Checklist rows 142–145, 157–167 and 169 in `fidelity-council.md`.
These values supersede §G where they differ.

### H.1 Momentum flick at the top of the file (step 04; supersedes F.7)

The step scrolls Long.swift from 600 points down back to the top: 8
gesture events of 40 points 8.3 ms apart, then momentum events decaying
with a 0.33 s time constant (about 1544 points more), the same events
for both apps. The offset below is the content's scroll position, found
per frame by matching the frame's text area (x 300–700, y 110–790)
against the stills at offset 0 and 600; negative values are **past the
top** (the content pulled down, empty space above it).

**Both apps stretch past the top and spring back.** The judges' "no
overshoot in the reference" is not borne out: the tool's progress
measure follows changed pixels, which barely change while the content
is pulled down, so it saw the stretch only in Ycode.

Reference:

| ms | 77 | 90 | 102 | 115 | 127 | 139 | 150 | 162–187 | 200 | 226 | 250 | 273 | 297 | 323 | 348 | 374 | 410 | 446 | 487 | 524 | 560 | 607 | 645 | 696 | 782 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| offset | 600 | 4 | −30 | −74 | −90 | −109 | −115 | **−119** | −115 | −103 | −90 | −76 | −67 | −55 | −42 | −34 | −23 | −17 | −12 | −8 | −5 | −3 | −2 | −1 | 0 |

Ycode now:

| ms | 76 | 87–108 | 119 | 130–150 | 160–168 | 178–207 | 219 | 230–252 | 263–284 | 295 | 315–338 | 346 | 366 | 387 | 407 | 437 | 464 | 488 | 529 | 558 | 611 | 645 | 704 | 745 | 828 | 870 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| offset | 600 | 560 | 450 | 201 | −44 | −94 | −184 | **−199** | −190 | −168 | −154 | −126 | −106 | −96 | −77 | −55 | −46 | −35 | −26 | −17 | −12 | −8 | −4 | −2 | −1 | 0 |

| | Reference | Ycode now |
|---|---|---|
| Reaching the top | the whole 600 points in **one frame** at 90 ms | in four steps, 87 to 160 ms |
| Stretch past the top | to **119**, 72 ms after reaching the top (162 ms), held about 25 ms | to **199** (1.67 times), at 230 ms, held about 22 ms |
| Spring back from the peak | a **critically damped spring, ω ≈ 13.6 per second** (rms error 0.014 of the stretch): half back 122 ms after the peak, 10 % left at 313, under a point at 509 | the **same spring** (ω ≈ 13.4, rms 0.013): half at 135, 10 % at 306, under a point at 576 |
| No oscillation | none: the offset never passes 0 on the way back | none |
| Settled | about **700 ms** (−1 at 696, 0 at 782) | about 870 ms |
| Position updates | **every recorded frame** (11–13 ms) | **every 2–3 frames** (about 30 per second): 20–45 ms holds throughout |

The spring is x(t) = A (1 + ω t) e^(−ω t), with A the stretch at the
peak and t from the peak. Ycode's return already matches it; what
differs is the depth of the stretch, the late arrival at the top and the
update rate. **Target:** for this input the stretch peaks at about **120
points** about 70 ms after the content reaches the edge (a stiffer
resistance than Ycode's now: about 0.6 of Ycode's stretch for the same
momentum), then the same critically damped return (ω about 13.5 per
second, no oscillation), settled within about 700 ms of the first
gesture event; apply the gesture's pending deltas in the first frame the
content moves; draw a new position every display frame. Round 4's F.7
target (reach the end in about 60 ms) stands; this round the reference
took one frame.

### H.2 Hiding and showing the inspector (steps 10, 11; supersedes G.1)

The inspector's left edge at y 700: shown at **1140.5** (Ycode 1141.5),
hidden at 1399.5 (the window's edge). Progress is the share of the
travel.

**Reference, hide:**

| ms | 70 | 83 | 98 | 111 | 137 | 164 | 179 | 206 | 219 | 235 | 248 | 273 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| progress | 0 | 0.02 | 0.16 | 0.25 | 0.38 | 0.51 | 0.67 | 0.82 | 0.91 | 0.94 | 0.99 | 1 |

**Ycode, hide:**

| ms | 75 | 88 | 134 | 185 | 209 | 244 | 253 | 273 |
|---|---|---|---|---|---|---|---|---|
| progress | 0 | 0.01 | 0.18 | 0.49 | 0.80 | 0.95 | 0.99 | 1 |

**Reference, show:**

| ms | 89 | 102 | 114 | 129 | 155 | 168 | 195 | 208 | 234 | 249 | 275 | 287 | 313 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| progress | 0 | 0.02 | 0.04 | 0.12 | 0.19 | 0.31 | 0.44 | 0.58 | 0.71 | 0.82 | 0.91 | 0.96 | 1 |

**Ycode, show:**

| ms | 89 | 99 | 121 | 142 | 165 | 176 | 198 | 239 | 286 | 318 |
|---|---|---|---|---|---|---|---|---|---|---|
| progress | 0 | 0.12 | 0.24 | 0.37 | 0.51 | 0.64 | 0.77 | 0.86 | 0.98 | 1 |

| | Reference hide | Ycode hide | Reference show | Ycode show |
|---|---|---|---|---|
| Motion | **77–273 (196 ms)** | 82–273 (191 ms) | **95–326 (231 ms)** | 94–318 (224 ms) |
| Positions drawn | 11, longest hold **27 ms** | 7, longest hold **51 ms** | 13, longest hold 27 ms | 9, holds of **41 and 47 ms** over the last 23 % |
| Half the travel | 87 ms into the motion (44 %) | 104 ms (54 %) | 105 ms (45 %) | 71 ms (32 %) |
| Best named curve (rms error) | **ease-out (0, 0, 0.58, 1)**, 0.068; linear 0.097 | ease-in-out, 0.093; ease-out 0.225 | **ease-in-out (0.42, 0, 0.58, 1)**, 0.048; free fit (0.45, 0.20, 0.60, 1), 0.025 | ease-out, 0.053; ease-in-out 0.191 |
| After the motion | the toolbar's items settle at 284–309 | a 9-pixel repaint at the editor's right edge (x 1386–1398, y 118–124) at **346** | nothing | the same kind of repaint (x 1126–1138, y 118–124) at **369** |

The start and the duration now match the reference within 10 ms. The
curves are **swapped**: the reference hides with a fast start (16 % of
the travel 21 ms in, about ease-out) and shows with ease-in-out; Ycode
hides with ease-in-out and shows with ease-out. The judges' 377 and 368
ms are Ycode's motion plus the late repaint at the editor's right edge.

**Target:** hide from about 77 ms over about 195 ms, ease-out; show from
about 95 ms over about 230 ms, ease-in-out (the keyframes above are the
reference); a new position at least every 27 ms; nothing redrawn after
the motion ends (the editor's scroll indicator must not repaint 70–90 ms
later).

### H.3 Narrowing the window (step 17; supersedes G.4)

| | Reference | Ycode now |
|---|---|---|
| Content relayout | one frame at **116 ms** (rounds 4 and 5: 105 and 219) | one frame at **375** |
| The size request returns | at 222 ms | at **1247** (the caret kept blinking while it waited) |
| Overflow capsule | appears with the content frame **at the width of the items it absorbs** and shrinks to its circle; its left rim stays at 796.5 | appears **at its final size** (x 796–833) |
| The "»" glyph | at **full size** (x 814–824) from the content frame | grows from a one-point dot at x 832 to 813.5–823.5 over 229 ms (452 to 604+) |

The reference's capsule right edge, ms from its content frame:

| ms | 0 | 13 | 28 | 41 | 56 | 69 | 84 | 97 | 112 | 125 | 140 | 153 | 167 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| right edge | 920.5 | 906 | 895 | 883.5 | 864.5 | 857 | 846 | 842.5 | 839.5 | 836 | 835 | 834 | 833.5 |

124 wide at its first frame, 37 at rest; half the change by about 45 ms
(ease-out). **Target:** relayout within about 120 ms of the request and
return the request without waiting for the layout; the overflow capsule
morphs from the absorbed items' extent to its circle over about 165 ms,
ease-out, with the "»" at full size from its first frame.

### H.4 Wrapping and the jump bar at 1100 with a split (step 17)

**Text areas (left pane).** Column 0 starts at **x 341.5** in both apps;
the cell advance is **8.04** (F.2). The reference's minimap starts with a
one-point separator at **486.5–487.5** (minimap 487.5–549.5, lane
549.5–560.5, pane divider 563.5–566.5); Ycode's separator is at 488–489
(minimap 489–551, lane 551–562): Ycode's text area is **1.5 wider**, not
narrower (145 against 146.5 to the separator). Both panes are equal
within 1.5 in both apps.

**Where the rows break.** Column k spans 341.5 + 8.04 k to 341.5 + 8.04
(k + 1); 17 columns end at **478.2**, 18 at **486.2**.

| Row (Long.swift) | Reference | Ycode now |
|---|---|---|
| "import Foundation" (17 characters from column 0, the end of its logical line) | one row, ink to 476.5 | the same |
| Line 6, first row: "Block 00, line" then "0:" (the "0:" would end at column 17, 486.2) | breaks before "0:" | the same |
| Line 6, second row from column 5: "0: a comment", then a space, then "line" | **breaks before "comment"**: "0: a" / "comment" | keeps "0: a comment" (ink to 476.5) |

"0: a comment" ends at column 16, exactly where "import Foundation"
ends, so both fit the container; the only difference is the **space
after "comment"**, which would occupy column 17 (to 486.2). The
reference therefore wraps a word to the next row when the word **and the
space after it** do not fit, unless the word ends its logical line. This
is the third round (4, 5, 6) to show it on this line, and no captured
row contradicts it. The container's edge lies between 478.2 and 486.2
(0.3–8.3 inside the minimap's separator); G.2's "about 10.5 before the
minimap" (476.5) is too narrow, since "import Foundation" fits. **Target:**
the space rule above (row 88's hypothesis, now the rule); Ycode's 17
columns already match, so its container width needs no change.

**The jump bar's collapse order.** The left pane's jump bar, ink
extents:

| Part | Reference at 1400 (step 16) | Reference at 1100 (step 17) | Ycode at 1400 | Ycode at 1100 |
|---|---|---|---|---|
| Close, grid | 304–315, 326–338.5 | the same | 301–311, 327.5–339.5 | the same |
| Project | icon 361.5–374.5, title "GlassScroll" 380.5–437.5 | **icon only** 361.5–374.5 | icon and title 361.5–437 (no gap) | icon and title (kept) |
| Chevron | 444.5–446.5 | 381.5–383.5 | 441–444 | the same |
| Group | icon 457–469.5, title 475.5–532.5 | **icon only** 394–406.5 | icon 448.5–463, title 467–524 | icon only 448.5–463 |
| Chevron | 539.5–541.5 | 413.5–415.5 | 528–531 | 469.5–472.5 |
| File | icon 552.5–564, "Long" 571–595 | icon 426.5–438, **"Lo" fading out**, 445–458 | icon 535.5–553.5, "Long" 558–582 | icon 477–495, "Long" 499.5–523.5 |
| Chevron | 601.5–603.5 | 464–466 | 586–589 | 527.5–530.5 |
| Last item ("No Selection") | 613–678, **the item colour** | **whole**, 475.5–540.5 | 593–658, a lighter secondary grey | **cut**, "No Se" fading out at the pane's edge (562) |

Reference spacing: icon to title **6**, title to chevron **7**, chevron
(2 wide) to the next icon **10.5**, chevron to a title without icon 9.5.
Ycode's: 0–4, 4, 4.5 (its chevron 3 wide), so its full path is 20
shorter. In the 1100 window the reference's path ends at 540.5, **23
inside** the pane's right edge (563.5).

Collapse order seen (the full path needs 316.5, 179 is available): **(1)**
the leading items' titles go and their icons stay (the project's and the
group's: −126); **(2)** then the file's title is cut from its end with a
fade (24 → 13); **(3)** the last item stays whole. Ycode drops only the
group's title and cuts the last item. **Target:** the reference's spacing
and order; the last item is cut only when everything before it is
reduced to icons and the file title to its minimum; "No Selection" and
the other path items in one colour (the active pane's label colour, the
inactive pane's grey). Which leading title goes first when only one must
go was not seen (both went at this width).

### H.5 The issue capsule and the jump-bar stepper in light (conflict 01, 03; refines G.8)

**With no issues, neither shows.** This round's main project had no
issues: the reference showed no issue capsule in the toolbar and no
stepper in any jump bar in any main step. This settles round 5's open
question; G.8's "hidden when there are none" is the rule. The conflict
project had a warning before the merge and an error and a warning during
it.

| Part | Reference, conflict 01 (one warning; 1400 window) | Reference, conflict 03 (an error and a warning; window behind the sheet) |
|---|---|---|
| Capsule | x **811–872** (61 wide), y 8–44 (36), a hairline rim #BFBFBF, fill #F9F9F9 (the toolbar capsules' light material); **7.5 after** the scheme capsule (its right rim at 803) | x **819–930** (111 wide), 8 after the scheme capsule, which ended at 811 this time |
| First symbol | a **yellow triangle (#F5C200) with a white exclamation mark**, 17.5 × 16, x 827.5–845 (16.5 inside the capsule) | a **red circle with a white cross**, 17 wide, x 835.5–852.5 (16.5 inside) |
| Its count | "1", black #000000, ink x 850–854 (5 after the symbol), 9.5 tall | "1", ink x 858–862 (5.5 after) |
| Second pair | — | the yellow triangle x 886.5–904 (**24.5** after the first count), its "1" at 909–913 |
| Trailing inset | 18 from the count's ink to the rim | 17 |
| Toolbar after it | unchanged | the last toolbar group showed one item and a pop-up chevron: the wider capsule pushed the group into its overflow form |
| Jump-bar stepper | back chevron x 1084.5–1091 (6.5 × 11.5, **#7F7F7F**), the warning symbol 1099.5–1110.5 (11 × 10.5, **#FFCB00**), forward chevron 1118–1124.5, y 60.5–72: round 5's places | — |

The stepper showed in conflict 01 although that editor showed "No
Selection" (no file open): it belongs to the editor's jump bar whenever
the workspace has issues, not to a file. In light the chevrons are
#7F7F7F (round 5's dark: #9D9D9D). **Target:** G.8's elements with these
light values; hidden with no issues.

### H.6 The plain group at first open (row 113)

Step 01's before still, the project navigator:

| Row | Kind | Reference | Ycode now |
|---|---|---|---|
| GlassScroll (the project) | project | expanded | expanded |
| GlassScroll | synchronized folder, a child of the main group | expanded | expanded |
| Models | folder inside it | collapsed | collapsed |
| Plain | `PBXGroup`, a child of the main group | **expanded** | **collapsed** |
| Sub | `PBXGroup` inside Plain | collapsed | — |

**Why: not restored state.** Each round's project is generated fresh into
a new folder (`/private/tmp/ycode-council-rN/…`) with no user data (the
generator writes none), the reference is launched with saved window state
ignored, and no setup step touches the navigator before step 01. Rounds
4, 5 and 6 all showed Plain expanded. So this is the reference's
**first-open default**: the project row and **every group or folder that
is a direct child of the main group** are expanded; anything deeper is
collapsed. `navigators.md` ("the project row and its first group") has
only the first of them, and Ycode implements that. **Target:** at first
open, with no saved navigator state, expand the project row and all of
its main group's direct children that are groups or folders (the
Products group stays hidden). Restoring a saved state in a later session
was not captured. Step 13's click then lands on Sub, as in the reference.

### H.7 The image inspector and file switches (steps 05, 07; refines G.5, G.6)

G.5's spacing is met: every row from "Identity and Type" to "Target
Membership" is within a point of the reference.

| | Reference | Ycode now |
|---|---|---|
| On Demand Resource Tags field | x 1148–1396, y 289–313, fill **#E0E0E1** | x 1145–1394, y 288.5–312.5, fill #D5D5D6 |
| Its placeholder | #707071, starts **6.5** inside the field, **vertically centred** (ink 296–306) | #6B6B6B, 2.5 inside, **3 below the field's top** (ink 291.5–301.5) |
| Dimensions, Resolution, Color Space, Alpha Channel | **"--"** in all four (two hyphens, ink 9.5 wide from x 1226.5), the third round in a row (1.2 s after the selection, the image long shown) | the image's values ("800 × 1800 pixels", "RGB", "No"); Resolution "--" |

| Switch | Reference | Ycode now |
|---|---|---|
| Long.swift → Bands.swift (07) | navigator, jump bar and the new text at **216**; the inspector one frame later (230); **no empty-editor frame** this round | everything at 272, one frame |
| → Stripes.png (05) | navigator and the **empty viewer** at 205; the inspector at **286**; a small text change at 645; the image at **1022** | everything, image included, at 266 |

**Targets:** the placeholder 6.5 in and centred; the field fill
#E0E0E1; the four image properties "--" when the image is selected from
the navigator (owner's rule 1: match; F.8's acceptance of filled values
is withdrawn); new content within about 210 ms of the click. The
inspector following the editor by one frame (text) or about 80 ms
(image), and the empty viewer before an image, are the reference's
order; F.8 still lets Ycode draw the image as soon as it is ready.

### H.8 The Add Editor button and the split (step 16; refines G.7)

The button's background (x 925–965 in the reference, 915–955 in Ycode,
y 10–42) per frame, from the click on it:

| Event | Reference | Ycode now |
|---|---|---|
| Hover | 59 ms | 65 |
| Pressed (the glyph darkens) | 293 | 247 |
| A **single darker frame** (about 15 ms) | **351** | none |
| Fade into the menu-open state (a light grey rounded square behind the glyph) | 486 → 708 | 459 → 741 |
| The split | **738 ms after** the press on "Editor Pane On Right" (round 5: 858) | not within the 1196 ms the recording ran after the press (round 5: the same); in the after still |

Round 5's bright 110 ms highlight and 400 ms fade are gone; the judges'
332 ms is the fade into the menu-open state, which the reference also
draws (about 220 ms). **Target:** add the single darker frame on the
press; the rest is met. The split's latency stays open (row 140): capture
with a 3-second post-roll.

### H.9 Glyph colours and toolbar items (steps 01–18, conflict 01)

| Item | Reference | Ycode now |
|---|---|---|
| Navigator filter glyph (a circle with three lines) | 14.5 × 13 (x 50–64.5, y 851.5–864.5), **#777777**, 1-point stroke; its chevron 6 × 4, #777778 | 13.5 × 14, **#000000**, 1–1.5 stroke; chevron #000000 |
| Trailing toolbar | a **standalone circle** x 879.5–916.5 (37 wide) holding a filled cloud glyph with a small blue dot at its lower right, 7.5 before the Add Editor capsule (924–1002); then the capsule 1009.5–1133.5 | **no circle**; the capsules at 922.5–1002 and 1009–1133 (within 1.5) |
| Leading capsule | a list glyph (navigator) and a sparkle glyph | a sidebar glyph and a speech bubble |
| Item left of the scheme capsule | a speech bubble with a plus, in a **pink-to-purple gradient** | a black outline bubble |
| Source Control navigator (conflict 01) | the Changes │ Repositories control y **90–106**; "Changes" ink 45 wide; rows from 90; **filled grey** group glyphs (repository, Branches, Recents, Tags); branch rows a blue fork with a curved branch | control y 88–104 (2 higher); "Changes" 41 wide (about 9 % smaller type); rows 1.5–3.5 higher; outline glyphs; a Y-shaped branch glyph |

Ycode draws its own glyphs (no artwork is copied); the targets are the
colour, weight, fill style and the items' presence and grouping. The
cloud circle stands for a cloud-service status Ycode does not have:
owner's decision whether Ycode shows an equivalent status there (for
example its simulator host's), designed by rule 2.

### H.10 Items raised by one judge, checked

- **Navigator scroller (step 15, Opus: "about 25 shorter").** Reference:
  track y **91.5–849.5** (758), thumb 298.5–735.5 (**437**); Ycode: track
  127.5–836 (708.5: it starts 36 lower and ends 13.5 higher), thumb
  327–711 (384). Thumb share of the track 0.577 against 0.542; at the
  reference's track length Ycode's thumb would be about 26 shorter, as
  the judge said. Ycode had one row fewer (H.6), which would lengthen
  its thumb, so the content or inset heights differ as well. Target: the
  scroller runs from just below the navigator's top bar to just above
  its bottom bar (the content's scroll insets), and its thumb is the
  visible share of the content.
- **Welcome window path (step 18, Opus).** The reference's recent
  project row shows the path with the temporary folder's link resolved
  ("/private/tmp/…"); Ycode shows it as opened ("/tmp/…"). The inspector's
  Full Path shows the unresolved form in both apps. Target: the Welcome
  list shows the real path (symbolic links resolved); the inspector keeps
  the opened path.
- **Property names "reddish" (Gemini)** and **step 08's scroller "visible
  at rest" (Gemini):** not borne out (round 6 summary).

## Council round 7 measurements (2026-11-08)

Round 7 repeated rounds 5–6's main session and added harder steps: a
**slower flick** to the top (X05), a flick **down to the bottom** (X03),
the jump bar with a split at **1250** and **1180** points (X07–X09), and
a reopen. Retina, 120 fps, foreground, key window, the system in
**Dark**, Ycode `0afb3bd7`. **The host's 1-minute load was 250–700**
(about 20 times round 6's), so every duration and latency below is
approximate and load-affected; end positions, sizes and colours are
reliable. Values in window points, times in ms from the capture tool's
first posted event. Offsets are found per frame by matching the frame's
text area (x 300–700, y 110–790) against the step's before and after
stills. Checklist rows 176–181 in `fidelity-council.md`. These values
supersede §H where they differ.

### I.1 Momentum must carry to the edge (X05 slow flick, X03 bottom flick)

**The input.** X05: 8 gesture events of 15 points 8.3 ms apart (120
points, **1800 points per second**), then 134 momentum-phase events over
1.11 s carrying **566.7 points more**, their deltas decaying with a 0.33 s
time constant: 686.7 points in all, from 600 below the top. X03: main
step 04's flick mirrored, 8 events of 40 points (4800 per second) then
173 momentum events carrying 1544 points, from 600 above the bottom.
Both apps received the same events (the capture tool's own record).

**X05, travel toward the top (600 = the top; above 600 = past it):**

| Reference ms | 113 | 128 | 155 | 181 | 206 | 234 | 260 | 289 | 331 | 361 | 389 | 416 | 441 | 469 | 495 | 508 | 534 | 646 | 727 | 885 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| travel | 15 | 213 | 247 | 294 | 337 | 381 | 416 | 456 | 490 | 523 | 541 | 562 | 576 | 587 | 597 | **600** | **603** | 602 | 601 | 600 |

| Ycode ms | 215 | 242 | 271 | 295 | 323 | 357 | 378 | 426 | 453 | 489 | 525 | 564 | 614 | 667 | 717 | 772 | 838 | 882 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| travel | 15 | 32 | 96 | 125 | 162 | 210 | 243 | 282 | 300 | 319 | 342 | 357 | 374 | 382.5 | 387 | 393.5 | 395 | **396** (rest 396.5) |

| | Reference | Ycode now |
|---|---|---|
| Speed, first 100 ms of motion | about 1700 points per second | about 1370 |
| Speed later | 1090 (220–308 ms), 940 (308–389), 575 (389–469), **330 on reaching the top** (469–508) | 685 (378–489), 440 (489–614), then **126** (614–717) and 55 (717–882): the coasting is cut short |
| End | **the top**, with a 3-point stretch past it (0.5 % of the travel) and back by about 885 ms | **stops 203.5 short** (at about line 9), never reaching the edge |

**X03, travel toward the bottom (600 = the bottom):**

| Reference ms | 203 | 276 | **296** | 312 | 340 | 385 | 451 | 478 | 515 | 593 | 661 | 1087 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| travel | 554 | 622 | **641** | 638 | 631 | 625 | 619 | 611 | 608 | 604 | 602 | 600 |

| Ycode ms | 222 | 258 | 292 | 328 | 360 | 406 | 450 | 505 | 566 | 612 | 656 | 703 | 761 | 839 | 962 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| travel | 40 | 83 | 131 | 201 | 264 | 360 | 398 | 452 | 480 | 513 | 532 | 543 | 552 | 561 | **564** (rest 563.5) |

The reference reaches the bottom about 230 ms in and stretches **41**
past it (6.8 % of the travel), then returns with the same critically
damped spring as at the top (I.2). Ycode decelerates smoothly and stops
**36.5 short of its own bottom** (its start was 600 above its maximum
offset, so this is not the missing last line of I.3): it applied only
about 245 of the 1544 momentum points (X05: about 277 of 567).

**What the reference does.** Its travel follows the delivered event
deltas, momentum-phase events included, until the edge; what is left
when the edge is reached feeds the stretch. Ycode ends its own coasting
early, whatever the events still carry. **Target:** on macOS, apply every
momentum-phase delta one to one until the gesture's momentum ends or an
edge is reached (then I.2's stretch); never stop coasting on a timer or
a speed floor of Ycode's own. On Linux, where Ycode makes the momentum
itself, start it at the release speed and decay it with a time constant
of about **0.33 s** (the events above), so that the same flick travels
the same distance (686.7 points for X05's input) in both IDEs.

### I.2 The stretch past the edge (main 04, X03, X05; supersedes H.1's stretch)

Main step 04 (the fast flick up, 1544 momentum points), travel toward the
top:

| Reference ms | 79 | 108 | 122 | 136 | 150 | 163 | 177 | 204 | **218** | 245 | 273 | 300 | 327 | 355 | 395 | 436 | 489 | 545 | 626 | 734 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| travel | 240 | 487 | 524 | 597 | 613 | 626 | 634 | 638 | **639** | 635 | 633 | 627 | 622 | 617 | 613 | 609 | 606 | 603 | 601 | 600 |

| Ycode ms | 148 | 178 | 191 | 218 | 230 | **262** | 285 | 296 | 318 | 340 | 360 | 383 | 406 | 441 | 486 | 529 | 573 | 627 | 677 | 737 | 852 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| travel | 40 | 243.5 | 634.5 | 668.5 | 731 | **747** | 744 | 733 | 718 | 706 | 686.5 | 677 | 659.5 | 648 | 630.5 | 617.5 | 611.5 | 606.5 | 604 | 602 | 600 |

| | Reference | Ycode now |
|---|---|---|
| Peak stretch, fast flick at the top (04) | **39** (6.5 % of 600), about 80 ms after reaching the top | **147** (24.5 %), about 70 ms after |
| Peak stretch, fast flick at the bottom (X03) | **41** (6.8 %) | none: Ycode never reached the bottom (I.1) |
| Peak stretch, slow flick at the top (X05) | **3** (arriving at about 330 points per second) | — (stopped short) |
| Return from the peak | x(t) = A (1 + ω t) e^(−ω t) with **ω ≈ 13.5 per second**: 44 % left 137 ms after the peak (spring 45 %), 13 % at 284 ms (spring 10.5 %), 5 % at 368 (4 %) | the **same spring**: 52 % at 121 ms (51.6 %), 21 % at 224 (19.6 %), 3.7 % at 389 (3.3 %) |
| Round 6 (load 11–15), same input | 119 | 199 |

The return is met. The stretch is not: at this load the reference's is
**0.27 of Ycode's**, at round 6's low load 0.6. Under load the events
reach the reference in fewer, larger batches (it moves 240 then 487 in
its first two frames), so it arrives at the edge with less left to
spend; the low-load value is the like-for-like one. **Target:** a
stretch that grows with the momentum left at the edge but more slowly
than Ycode's now: about **120** for main step 04's input at a light load
(H.1), about 40 when that momentum arrives in batches as here, and a
few points for X05's slow arrival; the same at the top and the bottom
edge; the return unchanged (ω about 13.5, no oscillation).

### I.3 The final empty line and the overscroll below it (X03, conflict 03)

Long.swift ends with a newline. At rest after X03:

| | Reference | Ycode now |
|---|---|---|
| Last numbered line | **845**, the empty line after the final newline, laid out like any other row (18-point pitch) | **844**: no row for the line after the final newline |
| Its row | y 443–461, filled with the **current-line highlight #353535** (the editor's background is #252625) because the insertion point is on it (the step's ⌘↓ put it there), the caret at its start | — |
| Text area | y 84.5 (below the jump bar's hairline at 84) to 843 (the bottom bar's hairline): 758.5 tall | y 84.5–844 |
| Below the last row at the maximum offset | **382** empty: the last row's bottom (461) is **2.75 above the text area's middle** (463.75) | at its maximum, line 844 sits where the reference draws 845 (the two start positions differ by exactly one line, so Ycode's maximum offset is one row less) |

The merge sheet (conflict 03): Greeting.swift has 18 lines and a final
newline; the reference numbers **19** in both panes (an empty row 19
under line 18's "}"); Ycode ends both panes at 18.

**Target:** a document that ends with a line break has one more line,
empty, after it: numbered in the gutter, able to hold the insertion
point (⌘↓ goes there), drawn with the current-line highlight when it is
current; in the source editor and in both merge panes. The maximum
scroll offset lets that last row's bottom rise to the text area's
vertical middle (within about 3 points). (Corrected after implementation:
Ycode's macOS overscroll was half of the whole scroll view, which put the
last row 68 points too high, and the Linux IDE had none; both now use half
of the text area.)

### I.4 The inactive split pane across a re-wrap (X06–X09)

| Moment | Reference, left (inactive) pane | Ycode now, left pane |
|---|---|---|
| Before the split (after X05) | line 1 at the top (X05 reached the top) | about **line 9** at the top (X05 stopped 203.5 short) |
| After Add Editor Pane on Right at 1400 (X06; the pane narrower, its rows re-wrap) | line 1 at the top | about **line 26** at the top |
| After the resize to 1250 (X07) | line 1 at the top | about **line 20** at the top, and the gutter **stale**: 20, 16, 27 drawn over 21, then 22 … beside rows they do not belong to |

The reference's case is the trivial one (line 1 stays line 1), and
Ycode's start differs because of I.1; but Ycode's own behaviour is still
wrong twice over: the top line jumps by 6–17 lines at each re-wrap, and
its gutter is drawn against the old layout. **Target:** when a pane's
text re-wraps (a split, a window or pane resize, a font change), keep
the **first visible logical line** at the top, at the same fraction of
its first row, in every pane, active or not; redraw the gutter in the
same frame as the text. (Behaviour mid-file in the reference is to be
confirmed by a later round with the pane scrolled before the split.)

### I.5 The jump bar at 1250 and 1180 with a split (X07–X09; refines H.4)

Long.swift in both panes (X07), then Model01.swift (a deeper path) in
the right pane (X08), then the window at 1180 (X09). Ink extents:

| Part | Reference X07, left pane | Ycode X07, left pane | Reference X09 (1180), left | Ycode X09, left |
|---|---|---|---|---|
| Project | icon **361.5–374.5** (13), "GlassScroll" **380.5–437.5 whole** | icon 361.5–376 (**14.5**), "GlassScrol" 382–435.5, cut with a fade | icon 361.5–374.5, "Glass…" **380.5–404** (23.5), cut | icon 361.5–376, "Glas…" 382–400.5 (18.5), cut |
| Group | icon only, 457–469.5 | icon only, 456.5–469 | icon only, 422.5–435 | icon only, 421.5–434 |
| File | icon **490–501.5** (11.5), "Long" 508–532.5 | icon 488.5–503.5 (**15**), "Long" 509–533.5 | icon 455–466.5, "Long" 473–497.5 | icon 453.5–468.5, "Long" 474–498.5 |
| Last item | "No Selection" 550–615.5 | 551.5–617 | 515–580.5 | 516.5–582 |
| Pane edge (divider) | 639.5 | 640 | 604.5 | 605 |

| Part | Reference X08, right (active) pane | Ycode X08, right pane |
|---|---|---|
| Project | icon 713–726, **"Gl" 732–741 (9), cut with a fade** | icon 712.5–727, **no title** |
| Two groups | icons only | icons only |
| File | icon 822.5–834, "Model01" 840.5–883.5 | icon 811–826, "Model01" 831.5–874.5 |
| Last item | "No Selection" 901.5–967 | 892–957.5: **10 points unused** |

Both apps reserve the same space after the last item (about 23–24
before the pane's edge), and both drop the groups' titles first. The
differences:
- **Ycode's icons are wider.** Project icon 14.5 against 13 (its advance
  to the title 20.5 against **19**); file icon 15 against **11.5** (advance
  20.5 against **18**). Its path is 5 points longer, which is exactly
  the 5 points its project title loses at both widths (X07: 53.5
  against 57; X09: 18.5 against 23.5).
- **Ycode drops the project title too soon.** With 10 points to spare in
  X08 it shows the icon alone; the reference keeps the title cut down
  to about **9 points** (two letters fading) before it gives it up.
- The active pane's chevrons are 3 wide in the reference (2 in the
  inactive pane); Ycode's are 2 in both.

Collapse order (with H.4's at 1100): **(1)** the groups' titles go,
their icons stay; **(2)** the project's title is cut from its end with a
fade, down to about 9 points; **(3)** then it goes, its icon stays;
**(4)** then the file's title is cut; **(5)** the last item stays whole.
**Target:** that order; icon slots the reference's widths (project 13,
group 12.5, file 11.5, each followed by 6–6.5 to its title); a title's
minimum before it goes, about 9 points; active-pane chevrons 3 wide.
The 1100 (H.4) and 1180 results must not change: at 1180 the reference's
"Glass…" is 23.5 wide, which Ycode reaches once its icons are narrower.

### I.6 The editor's scroller knob (main 08; a judge's claim, measured)

The vertical scroller at x 1129.5 (the editor's right edge), Bands.swift:

| | Reference | Ycode now |
|---|---|---|
| Knob at offset 0 (07, 08 before) | y 90–190 (**100**) | y 90–205.5 (**115.5**) |
| After the 1200-point scroll (08 after) | y **227.5**–329.5 | y **247.5**–364 |
| Knob travel per scrolled point | 137.5 ÷ 1200 = knob ÷ 873 | 157.5 ÷ 1200 = knob ÷ 880 |

The judge's "about 10 lower" is the knob's top 20 lower and its centre
27 lower; the cause is the knob's **length** (15 % longer), since both
apps move it by the knob's share of a view about 880 tall (the whole
window: the text runs under the bars). A longer knob means Ycode counts
a shorter document for the scroller (about 13 % shorter): the missing
final line (I.3) and, probably, the overscroll below it. **Target:** the
knob's length is the track times the visible height over the full
scrollable height **including** the final empty line and the overscroll
of I.3; 100 points for Bands.swift in this window.

### I.7 Not settled by round 7

- The stretch's law at the edge: only two loads and one input each (I.2).
  Capture main step 04 and X03 again at a light load.
- Mid-file top-line preservation in the reference (I.4): scroll the pane
  to about line 50 before the split and the resize.
- The jump bar where only the project title must be cut by more than
  its fade (between 1180 and 1250 with the deep path in the left pane).

## Council round 8: Ycode implementation (B8-B, 2026-11-08)

Rows 204–207 of `fidelity-council.md` (round 8, light load). The
reference values are the round's rows; this section records what Ycode
now does on both IDEs.

### J.1 Momentum's share (row 205; revises I.1)

At a light load the reference's slow flick (X05) travels 564 of 600
points and stops 36 short of the top, so the momentum does not carry its
events' whole distance (686.7 points delivered). Both IDEs apply each
momentum-phase delta times a gain that decays from 1 with a time constant
of **1.42 s** from the momentum's first event, and end the momentum once
the applied speed (the events' distance over the last 0.1 s, times the
gain) is below **145 points per second**; the rest of it is taken in
(`EditorMomentum`). X05 then travels 564.3 with its last movement 770 ms
after the first event (fractional deltas; 567 for deltas cut to whole
points). The fast flick (main 04) still reaches the top, 132 ms after its
first event at about 3690 points per second. On Linux the toolkit's own
momentum (τ 0.33 s from the release speed) goes through the same model.

### J.2 The stretch (row 207; revises I.2)

The stretch past an edge is P(v) = 190 (v ÷ 3690)^1.44 for a crossing at
v points per second, limited to 0.28 of the visible height; the run past
the edge peaks 71 ms after the crossing and returns as the critically
damped spring of H.1 (ω 13.5). The bounce ends once it is within 1 point
of the edge. Main 04: 190 points at about 203 ms, back at the top at
about 750 ms (the reference: about 190 near 167 ms, back by 750–770). A
slow arrival (330 points per second) stretches about 6 points.

### J.3 The inspector's slide (row 204)

Hide: ease-out (0, 0, 0.58, 1) over **150 ms** from 50 ms after the press
(the reference: 143 ms; round 6's 195 at a heavy load is superseded).
Show: the same ease-out over **280 ms** from 145 ms (round 6's ease-in-out
over 230 is superseded).

Every display frame draws a new position (macOS):

- The pane cannot collapse while it slides. The split view collapses a
  pane whose divider is set narrower than about half its usual width and
  opens it only past that, so a show held the edge still for its first
  40 % and then jumped, and a hide collapsed early; the hide now collapses
  the pane once, after its last frame.
- A slide frame does not lay the whole document out: a re-wrap during the
  slide or a live resize lets TextKit lay out what is on screen, and the
  exact height (I.6) settles once, after the motion's last frame.
- The minimap renders its bars once into a bitmap as wide as the longest
  row and clips it, so a width change renders nothing again.
- The bars (toolbar band, jump bar, bottom bar) are not drawn per frame:
  their layers stretch what was drawn last, as the held blurred image was
  stretched; they draw once when the motion ends.
- The last position is drawn on time; the slide's end (the hide's
  collapse, the bars' render, the toolbar's update and fit) follows that
  frame's commit.

Off every display (a test window stepped at 60 Hz, a host load of 6–16)
a slide frame costs about 25–35 ms in a debug or a release build alike:
AppKit's layout and the layer commit, part of it materials the window
server draws on screen. There the hide shows its last position about
250–300 ms after the press and the show about 480–500 ms, frames one to
three display frames apart; whether every display frame is drawn on screen
is for the council's capture to measure.

The Linux slide is the toolkit's animation on the shared curves; each of
its frames re-evaluates the window's view graph (about 150–190 ms a frame
in a release build at a light load), which is the toolkit's cost, not the
editor's: the Linux slide shows 2–3 positions.

### J.4 Selection and resize (row 206)

The File inspector is rebuilt in the same pass as the editor (round 6's
deferral, `InspectorFollow`, is off), so both change in one frame. After
an open, or a re-wrap in one step (a resize request, a split), the first
frame is drawn before the whole document's layout, which follows it
(documents over 150 lines, on screen). A live resize holds the bars'
drawing as the slide does (J.3) and leaves the exact height for its end,
so its first step draws within a display frame or two of the drag, well
under the reference's 83 ms. On Linux the editor and the inspector are
drawn from the same model state and change in one frame.

## Council round 9: Ycode implementation (B9-B, 2026-11-13)

Rows 220–227 of `fidelity-council.md` (round 9: 2x, 120 fps, host load
6.6–14.4). These values supersede J.1–J.3 where they differ.

### K.1 Momentum and the stretch (rows 220–222; supersede J.1, J.2)

- **Momentum:** every momentum-phase delta applies one to one until the
  momentum ends or an edge is reached (I.1's rule; round 8's decaying gain
  and its 145-point-a-second floor are gone: round 9 saw the reference's
  slow flick reach the top). `EditorMomentum` keeps the gain and the floor
  as parameters (infinite time constant, no floor).
- **The stretch** past either edge is P(v) = 35 (v ÷ 3970)^0.71 for a
  crossing at v points per second (35 is within 4 of both the top's 38 and
  the bottom's 32), limited to 0.28 of the visible height; the run past the
  edge still peaks 71 ms after the crossing.
- **The return** is the critically damped spring from the peak with ω
  **11.3** at the top and **16.6** at the bottom, over once it is within
  **half a point** of the edge (a pixel at 2x).

With the council's inputs as I.1 and H.1 give them, on both IDEs' shared
model:

| Step | Crossing | Stretch, deepest at | At rest | Reference (round 9) |
|---|---|---|---|---|
| Main 04, top | 125 ms, about 3970 points a second | **35.0** at 191 ms | **741 ms** | 38 at 203, at rest by 723 |
| X03, bottom | 125 ms | **35.0** at 191 ms | **566 ms** | 32 at 210, at rest by 557 |
| X05, top | **625 ms**, about 400 points a second | **6.0** at 691 ms | 1058 ms | about 6 at 466, the top at about 400, at rest by 811 |

X05's documented input (8 events of 15 points, then 566.7 points decaying
with τ 0.33 s) carries the text only 361 points past the gesture's 120 by
400 ms, so with the deltas applied one to one it cannot reach the top by
400 ms without arriving fast; Ycode arrives later, as slowly as the
reference (round 7's reference arrived at 330 points a second). Round 9's
own timing of the input is not in the specs: if its X05 delivered more
than I.1 says (Ycode's round 9 run reached the top at about 160 ms, which
the documented input cannot do), the arrival time needs the round's input
to be settled (K.6).

### K.2 The top line through a width change (row 223)

The first visible logical line is pinned when the window's layout starts
to move (an inspector slide, a live resize of the window) and every re-wrap
until its end restores that line, at the same depth into its first row;
line 1 at the top counts too (it was left out, so nothing held it there).
The end restores it once more, and for 0.3 s after it a scroll the system
makes on its own (a bounds change of the clip view with no scroll event
and no new selection) is undone. Each re-wrap during the motion lays out
the visible rows in that frame. Off every display, the hide from line 1
keeps the origin at −86 (the jump bar's inset) through all ten frames, the
container widening on each (666 → 897 points), and mid-file line 49 stays
at the top; a scroll of 93 points made mid-slide or just after the end is
undone. The jump itself (to line 6, about 93 points) was not reproduced off
every display: it is consistent with the text being scrolled to the clip
view's raw top under the jump bar.

### K.3 The inspector's show (row 224)

The pane stays collapsed until the motion's first frame and opens in that
frame's pass (it opened to 1 point at the press, so the edge moved at +57
ms); the show starts 130 ms after the press (round 8: 145), so its first
moving frame lands near the reference's 136 ms. Durations and curves are
J.3's. Off every display (debug build, 60 Hz stepping) a slide frame costs
26–27 ms (median), so the frame rate on screen is for the council to
measure.

### K.4 Each document's place (row 226)

Each editor keeps, per document, its selection and its top line while the
window is open; showing a document again restores both (the status bar
reads the caret), and a document shown for the first time starts at line
1, column 1. The Linux IDE already kept them (its documents stay open
with their buffers).

### K.5 Instances of the selected symbol (row 227)

`SymbolInstances`: after the highlighting delay, only when the insertion
point is in an identifier in code (not in a comment, a string, a keyword,
a number, an attribute or a directive), every instance of that identifier
in code is highlighted; words in comments and strings never are. Both IDEs
use it (the Linux IDE had no instance highlighting; it now draws them in
the macOS colour, yellow at 30 %).

### K.6 Not settled by round 9's implementation

- X05's input timing at 2x (K.1), and the start latency and frame spacing
  of the flick to the bottom (row 222: Ycode started 112–133 ms after the
  input with frames about 22 ms apart): neither reproduces off every
  display; an on-screen trace of the first scroll event's frame is needed.
- Selecting Bands (row 225): off every display a debug build's open costs
  about 77 ms (the line index and folds 10, the syntax 24, the File
  inspector 16, the rest under 7 each) plus about 20 ms to draw; whether
  the council's 261 ms is this work, the navigator's click handling or the
  build kind needs an on-screen trace.

## Evidence

- Commands, shortcuts and the assistant/counterparts behavior: Apple's
  published Xcode keyboard-shortcut reference and Xcode Help (level 1).
- Counterpart pairing rules: Xcode Help's description of counterparts
  (level 1); the test-file and storyboard rules are Ycode's reading.
- Tab bar look, when it shows, pinning, and the close commands (⌘W closes
  the tab): `specs/ide/reference-ui-2.md` §8 (level 3).
- With one tab, ⌘W is Close Window: `specs/ide/reference-ui-3.md` §5.2
  (level 3).
- Code Review ⌥⇧⌘↩ and Assistant ⌃⌥⌘↩ are the reference's own
  shortcuts; the assistant's modes are `reference-ui-4.md` §16; split
  commands, history buttons and the assistant jump bar:
  `reference-ui-5.md` §2.2, §6.1 (level 3).
- OPEN QUESTION: whether split history is shared with the tab.
- Council round 8, Ycode implementation (J.1–J.4): Ycode's own tests and
  measurements (`CouncilRound8GroupBTests`, `CouncilRound8MotionTests`,
  `YCODE_IDE_MOTION8`); the reference values are those of
  `fidelity-council.md` rows 204–207 (level 3).
- Council round 1 (C.1–C.8), level 3: the session's 1x stills and
  recordings of the reference (black box). Glyph ink boxes and colour
  runs give C.1–C.5. Row matching between stills gives the travel. Per-frame
  changed regions (C.6) and divider positions (C.7) come from the
  recordings' frame times, and the C.7 curve from a grid fit of a cubic
  Bezier. The script is `research/tools/council-r1/measure_captures.py`;
  the method is `research/notes/council-r1-2026-11-04.md`. Font family:
  reference-ui.md §4 (level 3). Ycode values come from the same session's
  captures of Ycode.
- Council round 2 (D.1–D.9), level 3: the round 2 session's 1x stills and
  recordings of the reference (foreground, key window). Offsets come from
  row matching against stills; the springs and Bezier curves from least
  squares; cadence from the gaps between changed frames. The script is
  `research/tools/council-r2/measure_r2.py`; the method is
  `research/notes/council-r2-2026-11-04.md`. The harness's input
  parameters come from its manifest.
- Council round 3 (E.1–E.7), level 3: the round 3 session's Retina stills
  and 120 fps recordings of both apps (foreground, key window). The
  recorder writes a frame only on change, so single changed frames and
  their times come from the frame list; travel from the harness's
  per-frame displacement (rows matched between frames); widths and
  colours from colour runs and ink boxes on the stills. The band length
  per character uses the test project's own generator (110 blocks per
  row). Measured in the dirty room; prose only here.
- Council round 4 (F.1–F.12), level 3: the round 4 session's Retina
  stills and 120 fps recordings of both apps (foreground, key window,
  dark appearance). Token colours are glyph-core samples (the five
  pixels farthest from the background per token, median), checked
  against the flat full-block and string-band fills; run geometry from
  colour runs and ink boxes; animation keyframes from per-frame edge
  positions in the recordings (frame times from the recorder's frame
  list, the press time from the session manifest) and least-squares
  Bezier fits; the flick from the capture tool's timing segments.
  Measured in the dirty room; prose only here.
- Council round 5 (G.1–G.9), level 3: the round 5 session's Retina
  stills and 120 fps recordings of both apps (foreground, key window,
  dark). Inspector keyframes from per-frame edge positions at three
  heights; pane, minimap and text extents from colour runs and per-row
  ink ends on the stills; minimap pitch from mark runs; toolbar and
  button states from per-frame changed regions and region means; issue
  elements from ink boxes and colour runs; all times against the
  session manifest's action times. Measured in the dirty room; prose
  only here.
- Council round 6 (H.1–H.10), level 3: the round 6 session's Retina
  stills and 120 fps recordings of both apps (foreground, key window,
  light). The flick's offsets from matching each frame's text area
  against the stills at offsets 0 and 600, and a least-squares fit of a
  critically damped spring to the return; inspector keyframes from the
  per-frame edge at y 700 and named-curve fits; the overflow capsule
  from rim positions per frame; wrap columns and jump-bar parts from
  per-row ink ends and ink clusters on the stills; button states from
  region means per frame; the first-open state from the before still,
  the test project's generator and the capture scripts (our code); all
  times against the session manifests. Measured in the dirty room; prose
  only here.
- Council round 7 (I.1–I.6), level 3: the round 7 session's Retina
  stills and 120 fps recordings of both apps (foreground, key window,
  dark, host load 250–700). Travel per frame from matching each frame's
  text area against the step's before and after stills; the input
  events from the capture tool's session record (our code); the spring
  checked against the return at three points; last-line rows, the
  current-line fill and the text area's hairlines from colour runs and
  gutter ink rows; the inactive pane from its stills; jump-bar parts
  from ink clusters along the bar and the pane dividers from column
  profiles; the scroller knob from its run along its column. Measured in
  the dirty room; prose only here.
