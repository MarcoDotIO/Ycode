# Fidelity council: the checklist

**Status:** boundary spec. A review council of three judges scores how
faithful Ycode's macOS IDE is to the reference, Xcode 27.1, from one
scripted capture session that ran on both apps. The dirty room then
measures every finding from the reference's captures. This file is the
**clean implementer's work list**: one row per finding, with a target
value. Each row links to the spec section that has the full description.
Prose and numbers only.

- Judges: **Opus** (Claude Opus), **Sol** (GPT Sol), **Gemini** (Gemini
  3.8 Flash). "meas." marks a finding that came from measuring rather
  than from a judge.
- Evidence levels follow `AGENTS.md` rule 4. Values from the captures are
  level 3.
- Every reference value is from a 1400 × 880 window, **inactive**, light,
  1x, with the navigator 290 wide and the inspector 260 wide.
  Positions in a different window follow the stated rule ("the editor's
  left edge plus 51"), not the absolute x.
- "Ycode now" is the session's build. That build declared SDK 15.0 (row
  1), so its glass rows show the pre-macOS-26 fallback.

## Round 1 (2026-11-04)

### Scores

| Step | Opus | Sol | Gemini | Mean |
|---|---|---|---|---|
| 1. Editor at rest | 5 | 5.5 | 7 | 5.8 |
| 2. Slow scroll down 600 pt | 4 | 4.5 | 6 | 4.8 |
| 3. Flick back up | 6 | 5 | 7 | 6.0 |
| 4. Open the stripes image | 1 | 1 | 1 | 1.0 |
| 5. Scroll the bands under the toolbar | 2 | 3 | 4 | 3.0 |
| 6. Expand a navigator folder | 6 | 6 | 7 | 6.3 |
| 7. Scroll the navigator under its bars | 6 | 7 | 5 | 6.0 |
| 8. Toggle the inspector | 5 | 6 | 6 | 5.7 |
| **Overall** | **4** | **4.8** | **5.5** | **4.8** |

Step 9 (the Welcome window) was skipped: it needs the app in the
foreground. Step 5 cannot be compared, because the reference's image
viewer has no scroll area (row 3).

### Disputed values, settled by measurement

| Item | Opus | Sol | Gemini | Measured (reference) | Ycode now |
|---|---|---|---|---|---|
| Minimap width | about 115 | about 140 | about 80 | **127**, plus a 1-pt separator, in an 850-pt editor; rule min(128, 15 % of the editor) | about 125, with its scroll bar inside |
| Navigator row height | 22 | 22 | 20 | **22** | 22 |
| Navigator indentation | within 6 of Ycode | — | 16 | **14 per level** | 13 |
| Keyword colour | — | #C4246E | #9B2393 | **#C4246E** | #FF2D55 |
| String colour | — | — | #C41A16 | **#CA2B1C** | #FF383C |
| Comment colour | — | #6A7084 | #6A737D | **#6A7084** | #808080 |
| Number colour | — | #006279 | #1C00CF | **#0178B8**. #006178 is the declaration-name colour. | #0088FF |
| Toolbar height | — | — | 52 (Ycode 44) | **52 in both apps** | 52 |
| Toolbar shape height | 28–32 | 34–36 | — | **38** (y 7–44) | none drawn |
| Gutter | — | — | 40 (Ycode 48) | numbers end at the **editor's left edge + 38**; code at **+51** | numbers +27, code +58 |
| Inspector row spacing | 25–27 (Ycode 22) | — | 14 (Ycode 18) | **24** field to pop-up, **22** pop-up to pop-up, **27** across a rule | about 22–23 |
| Inspector hide duration | 310 ms | 310 ms | 310 ms | **about 215 ms of motion**, starting about 40 ms after the pressed state | 113 ms latency, then about 255 ms |
| Inspector slide distance | about 205 pt | — | 205.56 px | the inspector moves **260** (its width); content centred in the editor moves 130 | — |
| Editor scroll travel | Ycode 566 against 589 | 23 pt less | — | the reference **600** for 600 of input; Ycode **566** | 566 |
| Scroll durations | Ycode slower | Ycode slower | — | **not app behaviour**: the harness delivered Ycode's input more slowly; both follow their input within a frame | — |

### Checklist

Ordered by impact. **H**: a judge would see it in every step. **M**:
visible in one area. **L**: detail.

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 1 | Capture build | The compared Ycode **declares SDK 26 or later** in `LC_BUILD_VERSION`: the capture wrapper must stamp it as `make-app.sh` does | wrapper bundles the bare `swift build` executable, which declares SDK 15.0, so the toolbar, bars and jump bar draw the pre-26 fallback | `liquid-glass-ycode.md` §12.1 | — | meas. | H |
| 2 | Opening a file | An open-document event for a file in the open workspace (and a navigator selection) opens it in that window. The row selection, jump bar, inspector and editor all change in **one frame**. | nothing changes | `editor-area.md` §C.6 | 3 | Opus, Sol, Gemini | H |
| 3 | Image viewer | Image **scaled to fit and centred**; 20 above it; 20 gap; a flat "Open with Preview" button 20 tall, centred; 20 to the bottom bar. "Loading…" while it decodes. Inspector: Image Properties and Localization sections, no Text Settings. No scroll area while it fits. | none | `editor-area.md` §C.6 | 3 | Opus, Sol, Gemini | H |
| 4 | Editor text metrics | advance **8.0**; line pitch **18**; first line's top **7** below the content top; code column at the editor's left edge **+51**; wrapped lines continue **4 columns** past their indentation; text container ends 9–10 before the minimap separator | 7.45; 15; 2; +58 | `editor-area.md` §C.1 | 3 | Opus, Sol, Gemini | H |
| 5 | Scroll-under (editor) | Text passes under the toolbar band, jump bar, sticky header and bottom bar, which each let **about 6 %** show as a shapeless veil (at most 6–8 levels per pixel). **No fade** below any bar. | opaque bars, text clipped at y 83 | `liquid-glass.md` §7.3; `liquid-glass-ycode.md` §12.4 | 3 | Opus, Sol, Gemini | H |
| 6 | Toolbar shapes | Glass shapes **38 tall at y 7**, grouped and placed as `liquid-glass.md` §7.1. Inactive: one flat fill (#ECECEC over the editor, #E6E6E7 over the side areas) with a 1-pt outline. | bare glyphs (fallback) | `liquid-glass.md` §7.1, §2.2 | 3 | Opus, Sol, Gemini | H (needs row 1) |
| 7 | Sticky scope header | A 20-pt band (an 18-pt row plus 2) in editor white, nearly opaque. It shows **its line number** in the gutter in the line-number colour. A **2-pt #E5E5E5 separator** below it spans the gutter and text, not the minimap. No outline, no shadow. | see-through, no number, outlined in some frames | `editor-area.md` §C.3 | 3 | Opus | H |
| 8 | Minimap | 127 wide plus a 1-pt #E6E6E6 separator; width min(128, 15 % of the editor). Text at **1/6 scale**: 2-pt bars on a 3-pt pitch in the tokens' colours at about 35 %. **No labels or boxes.** Full-width visible-area shade #EDEDED. The scroll bar's lane sits **right of the minimap**, at the editor's edge. | grey bars with symbol-name pills; scroll bar on the left | `editor-area.md` §C.5 | 3 | Opus, Sol, Gemini | H |
| 9 | Inspector show/hide | The inspector **slides rigidly** by its width while the editor **resizes live** (its centred content moves half as far). About **215 ms**, following the progress table in §C.7 (best fit cubic-bezier(0.8, 0.4, 0.65, 1.0)). Motion starts within about 40 ms of the pressed state. No glitch frames. | first motion 113 ms after the press; ends at 367 ms with 56–71 ms pauses; text re-wraps in the last frame | `editor-area.md` §C.7 | 3 | Opus, Sol, Gemini | H |
| 10 | Syntax colours (default light) | keyword #C4246E, plain #322529, comment #6A7084, string #CA2B1C, number #0178B8, type #9D31CF, type declaration #007D9E, other declaration #006178, line number #B8B3B4 | system colours | `editor-area.md` §C.4 | 3 | Sol, Gemini | H. **Owner decision**: earlier specs kept Ycode's themes its own |
| 11 | Navigator order | In synchronized folders, **folders first**, then files, each by name | mixed | `navigators.md` Council §1 | 3 | Opus, Sol | M |
| 12 | Navigator selection | The open file's row is selected: a band 22 tall, **inset 10** on both sides (13 before a shown scroll-bar lane), corners about 8. Inactive: #E7E7E8 on #F2F2F3. | none | `metrics.md` §12.1; `navigators.md` Council §3 | 3 | Opus, Sol | M |
| 13 | Pane backgrounds | Inactive: navigator **and** inspector #F2F2F3; toolbar band over the editor and the jump bar white (the editor's background); jump bar separator **2 pt** #E5E5E5; editor ▸ inspector divider 1 pt #DADADB; no line between navigator and editor | #E6E6E7 / #EBECEC; grey band and jump bar; 1-pt separator | `liquid-glass.md` §7.4 | 3 | Opus, Sol | M |
| 14 | Scroll-under (navigator) | Rows run under both capsules to the area's edges. Through the **filter capsule** they stay visible (moderately blurred); through the selector capsule only a faint veil; nothing above the selector. No fade. | rows clipped at y 88 and at the bottom bar | `navigators.md` Council §6; `liquid-glass.md` §7.3 | 3 | Opus, Gemini | M |
| 15 | Scroll bars | Use the system's preferred scroller style. With the layout-taking style: an 11-pt track and knob, 3 from the edge; navigator track #DEDEDF, knob #ABABAC; editor lane 17 wide at the editor's right edge, track #F3F3F3, knob #7A7A7A. | forced overlay; the editor bar between text and minimap | `metrics.md` §12.2 | 3 | Sol, Gemini, Opus | M |
| 16 | Toolbar title | No shape. The project's icon (a spinner while loading), then 8 points, then a **bold title** and, while a task runs, a **subtitle** line. Inactive: both #BCBDBD. The centre group follows the title's width. | document glyph; title not dimmed (#454546) | `liquid-glass.md` §7.1 item 3 | 3 | Opus, Gemini | M |
| 17 | Scheme capsule | One capsule: target glyph, scheme, "›", destination glyph, destination. **No up-down chevrons.** | chevrons after both titles | `liquid-glass.md` §7.1 item 2 | 3 | Opus, Gemini | M |
| 18 | Selected tab glyph | In the selector and inspector tab bars the selected glyph is **grey (#7C7D7E) on a grey pill (#CACACB)**, not accent | accent-blue glyph | `liquid-glass.md` §7.2 | 3 | Opus | M |
| 19 | Navigator geometry | indentation **14**; triangle centred at 18 + 14 × level; icon at 27 + 14 × level; label at 48 + 14 × level | 13; labels 4–5 left | `metrics.md` §12.1 | 3 | Gemini, Opus | M |
| 20 | Navigator icon colours | Swift files **orange**; folders light blue; project and image badges blue (colour family only; Ycode's own artwork) | Swift files blue | `navigators.md` Council §4 | 3 | Opus, Gemini | M |
| 21 | Gutter | Numbers right-aligned, ending at the editor's left edge **+38**, 12 before the code; **a smaller face** (digits 9 px against the code's 10, about 6-pt steps); #B8B3B4; on the code baseline | numbers end at +27 | `editor-area.md` §C.2 | 3 | Gemini | M |
| 22 | Inspector layout | insets **7 / 8**; key column ends at the inspector's edge +78; values from +83 to 7 before the edge; Name field **22 tall, filled #E5E5E6, no border**; pop-ups **16 tall, filled #E1E1E2**; row pitch 24 / 22 / 27; section rules 6 from the controls | 12 / 12 insets, white bordered fields, about 22 pitch | `metrics.md` §12.4 | 3 | Opus, Gemini | M |
| 23 | Target Membership | A bordered table **110 tall** (1-pt #A6A6A7); rows show the target glyph, name and "Default"; a 19-pt footer with +, − and a pencil | 52 tall, a checkbox | `metrics.md` §12.4 | 3 | Opus | M |
| 24 | Text Settings and EditorConfig | `.editorconfig` read from the file's folder up to `root = true`. Indentation from it **disables** Indent Using and the widths and shows "Indentation settings provided by EditorConfig". Encoding and line endings stay enabled, with grey "No Explicit …" titles. | all enabled, no note | `metrics.md` §12.4 | 3 (1 for the lookup) | Opus | M |
| 25 | Scroll travel | Scroll deltas applied **1:1** (600 of input moves 600) | 566 (−5.7 %) | `editor-area.md` §C.8 | 3 | Opus, Sol | M |
| 26 | Frame pacing | No pause between changed frames longer than the reference's (35 ms editor, 23 ms navigator, at a 19-ms recorder interval) | 53 ms, 48 ms | `editor-area.md` §C.8 | 3 | Opus | M (confirm at 120 Hz) |
| 27 | Current-line band | From the editor's left edge **+14** to the text container's end, 18 tall, #EEEEEE, corners about 4, under the numbers; the current line's number in the plain-text colour | text only, 15 tall, #F2F2F2 | `editor-area.md` §C.2 | 3 | Opus | L |
| 28 | Inspector Location | "**Relative to Group**" for files in synchronized folders | "Relative to Folder" | `metrics.md` §12.4 | 3 | Opus | L |
| 29 | Inspector path values | 14-pt line pitch; break after "/" and after "-", filling each line | breaks after almost every "/" | `metrics.md` §12.4 | 3 | Opus | L |
| 30 | Jump bar | band y 52–83 (32), editor white; separator 2 pt #E5E5E5 | 31 tall, #ECECEC, 1-pt separator | `metrics.md` §12.3 | 3 | Gemini | L |
| 31 | Debug bar first item | drawn filled in a light accent colour (18 × 11) when on | a grey outline glyph | `liquid-glass.md` §7.2 | 3 | Opus | L |
| 32 | Navigator expand | rows appear in **one frame**, no animation | the same | `navigators.md` Council §5 | 3 | Opus, Sol, Gemini | — matches |
| 33 | Toolbar height | 52 | 52 | `liquid-glass.md` §7.1 | 3 | Gemini | — matches |

### Not measurable from round 1: to measure in round 2

| Item | Why not | Capture needed |
|---|---|---|
| Active-window look: glass highlight and shadow, title and glyph colours, side-area backgrounds, selection with the outline focused | Both apps were captured as inactive windows (background session) | The same session with the owner bringing each app to the front (key window), still and video |
| Font size (13 against about 13.3), line-number face, corner radii, minimap bar detail | At 1x, advances round to whole points and corners alias | The same stills at **2x (Retina)** |
| Tint and blur over light and dark content (stripes under the bars) | The image viewer fits the image, so there is no scroll area | Zoom the image to actual size before scrolling, or use a source file with dark-highlighted bands (for example a long selection), and scroll it under the toolbar, jump bar and bottom bar |
| Momentum (flick) and its deceleration | The synthetic flick carried no momentum phase | A real trackpad flick, window in the foreground, recorded at **120 Hz** |
| Inspector animation curve at better resolution; when the text re-wraps | 17–23 ms frames; the editor showed an image | Toggle the inspector with **Long.swift** open, at 120 Hz |
| Minimap width rule | One editor width | Stills at two more editor widths (inspector hidden, a split editor) |
| Overlay scroll-bar style | The Mac's setting gave the layout-taking style | The same steps with "Show scroll bars: When scrolling" |
| Navigator click to open (rather than open-document) | The session used `open -a` | Click the Stripes row in the navigator |
| Inspector scrolled under its tab bar | Not scrolled | Scroll the inspector with a long Full Path |
| Plain groups' sort order | The project uses a synchronized folder | A project with a plain `PBXGroup` holding a subgroup and files |
| Welcome window | Needs the app in the foreground | Step 9 with the owner's agreement |
| Dark appearance | Not captured | The same session in dark mode |

Before round 2, the capture wrapper must stamp the SDK (row 1). The test
project must also either carry its own `.editorconfig` or sit outside a
repository that has one, so that row 24 is tested deliberately.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Scores and the judges' claims | — | The council's three reports for round 1 (dirty room) |
| Every reference value in the checklist | 3 | The cited spec sections. They are measured from the round-1 1x stills and recordings of the reference with `research/tools/council-r1/measure_captures.py`; the method is in `research/notes/council-r1-2026-11-04.md` |
| Ycode values | — | The same session's captures of Ycode; `otool -l` of the captured executable |
| EditorConfig lookup | 1 | The EditorConfig specification (editorconfig.org) |
| Scroller style API | 1 | AppKit documentation (`NSScroller.preferredScrollerStyle`, `NSScroller.preferredScrollerStyleDidChangeNotification`) |
