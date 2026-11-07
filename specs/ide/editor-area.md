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
