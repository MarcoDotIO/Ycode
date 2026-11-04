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
