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

## Round 2 (2026-11-04)

Both apps were captured **in the foreground with the window key**, 1x, on
a 100 Hz display. The session added:
- a real click in the navigator;
- a momentum flick;
- `Bands.swift` (rows of full-block characters in the comment and string
  colours) scrolled under the bars;
- the inspector hidden and shown with `Long.swift` open;
- a plain `PBXGroup` with children out of name order;
- a 1100-point window;
- the Welcome window.

Known artefacts:
- Ycode's Stripes row could not be found through Accessibility (step 05).
- The reference's split step failed (the menu labels differ), and its menu
  stayed open in the stills that follow.
- In the narrow-window still the reference is drawn at 0.898 scale
  (`liquid-glass.md` §8.2).

### Scores

| Step | Opus | Sol | Gemini | Mean |
|---|---|---|---|---|
| 01 select Long.swift | 6 | 6.5 | 6 | 6.2 |
| 02 editor at rest | 6 | 7 | 7 | 6.7 |
| 03 linear scroll 600 pt | 4 | 4 | 5 | 4.3 |
| 04 momentum flick | 6 | 6 | 8 | 6.7 |
| 05 select Stripes.png | not scored | 7 | 5 | 6.0 |
| 06 open Stripes.png (open document) | 6 | 9 | 8.5 | 7.8 |
| 07 select Bands.swift | 7 | 4.8 | 7 | 6.3 |
| 08 bands under the bars | 4 | 6 | 3 | 4.3 |
| 10 hide inspector | 4 | 6 | 7 | 5.7 |
| 11 show inspector | 5 | 5.5 | 5.5 | 5.3 |
| 12 inspector scroll | 6 | 6 | 8 | 6.7 |
| 13 plain group | 7 | 7.8 | 7.5 | 7.4 |
| 14 expand folder | 7 | 7.2 | 7 | 7.1 |
| 15 navigator scroll | 3 | 6.5 | 1 | 3.5 |
| 16 split editor (Ycode only) | 5 | 7.8 | 8.5 | 7.1 |
| 17 narrower window | 4 | 4.2 | 5 | 4.4 |
| 18 Welcome window | 6 | 6.4 | 8.5 | 7.0 |
| **Overall** | **5.5** | **6.1** | **6.2** | **5.9** (round 1: 4.8) |

### Disputed values, settled by measurement

| Item | Judges | Measured (reference) | Ycode |
|---|---|---|---|
| Syntax colours | Gemini: keywords #AD3DA4, strings #D12F1B, types teal #36867A, and Ycode's types uncoloured | unchanged from round 1 in the active window: **#C4246E, #CA2B1C, types #9D31CF** | the same, types included; only `Foundation` after `import` is wrong (D.1) |
| Toolbar response to red content | Sol: mean 229,230,231 → 228,220,221 | per region: toolbar band **#FFFFFF → #FDE5E3**, jump bar → **#FFF2F0**, bottom bar → **#FEEDEB**; over slate #ECEDF0, #F6F7F8, #F2F3F5; **blurred** (edge spread about 15 pt), not a flat tint | toolbar band unchanged, jump bar ≤ 2 levels; bottom bar matches |
| Inspector hide / show | 305 / 270 ms | motion **222 / 216 ms** (fitted ends about 255 / 240); ease-in-out; 43 / 118 ms from the press | 144 ms in 4 frames after a 135 ms wait / 309 ms |
| Frame interval, linear scroll | Xcode 13.3 ms, Ycode 20 ms | **20 ms median in both**; flick 13.0 against 15.7 ms | — |
| Ycode scroll travel (step 03) | 1000 / 1060 / "67 lines" | **1050** (the reference 600) | — |
| Navigator scroll bar | Gemini: overlay, hidden until scrolled | layout-taking on this Mac, **shown once content overflows, not hidden 1 s later**; track y 83–832, knob 438 at the top | track y 179–798, knob 363 |
| Narrow window | Sol: Xcode's frame ends near 988 | an artefact: the still is drawn at 0.898; the window is 1100 | — |
| Navigator indentation | Gemini: 16 against 12 | **14** | 14 |
| Inspector heading colour | Sol: #858587 against #3A3A3C | **#858587**, bold | #393A3B |
| Welcome title | Sol: 49 × 13 against 95 × 24 | **49 × 13** (cap ink) | 95 × 26 |
| Image loading | Opus: Xcode never shows "Loading…" | it does, for about 100 ms, 454 ms after a click | one 50 ms frame |
| Minimap scale | Opus: Ycode at half scale | **1/6 in both**; the difference is per-token against per-word bars | — |
| Flick duration | 713 against 788 ms | not comparable (different start offsets). The app part: overscroll **83 pt**, spring ω **12.6 rad/s** | 10 pt, ω 10.5 |
| Inspector button state | Gemini: Ycode's stays accent-highlighted after hiding | not seen in either app; but Ycode accent-fills the Navigators toggle and the selected editor mode | — |
| "800 × 1800" glyph | Gemini: Ycode uses an ASCII x | **cannot be told at 1x** | — |

### Rows whose target changed

| # | Area | New target | Ycode now | Spec |
|---|---|---|---|---|
| 2 | Opening a file | By **click**: navigator band, jump bar, editor and status bar change in one frame; the inspector follows 12–61 ms later (289 ms for the session's first selection). By open-document: as round 1. | inspector in the same frame | `editor-area.md` §D.7 |
| 3 | Image viewer | "Loading…" also shows after a click (about 100 ms). The status bar shows no Line and Col for an image. | Loading one frame; "Line: 1 Col: 1" | §D.7 |
| 5 | Scroll-under (editor) | Active: the toolbar band passes **about 18 %** of the content's darkness (16 % at its lower edge, 13 % between shapes), the jump bar **8.5 %**, the bottom bar **12 %**. All **blurred** (edge spread about 15 pt, σ ≈ 6), following the content's shape, also through the toolbar shapes; one veil from y 0 to the jump bar's separator, no gradient, no fade below. Round 1's 6 % is the inactive window. | toolbar band 0, jump bar ≤ 2 levels; bottom bar matches | `liquid-glass.md` §8.3 |
| 8 | Minimap | Width **min(15 % of the editor, about 140)**: 83 at 551, 127 at 850, 139 at 1110. **One bar per token** (a comment is one bar). | bars break at every space | `editor-area.md` §D.6 |
| 9 | Inspector show/hide | Hide: motion about 222 ms (fit 250), starting 43 ms after the press; show: 216 ms (fit 240), starting 118 ms after. **Ease-in-out** (0.42, 0, 0.58, 1) is the working curve; progress table in §D.5. **Frames every 16–18 ms. The text re-wraps progressively, frame by frame.** Scroll position and top inset unchanged. | hide: 4 frames 23–83 ms apart; text jumps 40 pt | `editor-area.md` §D.5 |
| 12 | Navigator selection | Active, focused: **#0070F5**, white label and icon, 22 tall, inset 10, corners about 8. The outline **keeps focus** after a click. | band missing from every after-still | `metrics.md` §13.1; `navigators.md` round 2 §3 |
| 13 | Pane backgrounds | Active: navigator and inspector **#EDEDEE**; divider #D4D4D6; the round 1 values are the inactive ones | matches | `liquid-glass.md` §8.1 |
| 15 | Scroll bars | Knob = track × (view height ÷ document height), where the view is the whole area (880). Navigator track y 83–832: 3 below the selector capsule, 11 above the filter capsule. Shown while content overflows; not hidden under the layout-taking style. | track 179–798 | `metrics.md` §13.2 |
| 20 | Navigator icon colours | Active: Swift orange (#F77640); synchronized folders blue (#3FA1F6); **`PBXGroup`s neutral grey** (#7B7B80), even with a folder on disk; project and image badges blue | groups light-blue outline | `metrics.md` §13.1 |
| 22 | Inspector layout | Add the active colours: field #E0E0E1, pop-ups #DCDCDD (disabled #E5E5E6), rules #D6D6D7, headings **#858587 bold**. Full row table in §13.3. | darker fills; headings #393A3B | `metrics.md` §13.3 |
| 25 | Scroll travel | 1:1 still (600 → 600; 1200 → 1200) | **1050 for 600** in step 03; 1200 for 1200 | `editor-area.md` §D.3 |
| 26 | Frame pacing | Linear scroll: median 20 ms, 90th percentile ≤ 28 ms. Flick: median 13 ms. Navigator: worst gap ≤ 33 ms. | flick 90th percentile 49 ms; navigator worst 75 ms | §D.3 |

Since round 1 Ycode now matches rows 1 (SDK), 4 (pitch 18, code column
+51), 6 (toolbar shapes), 10 (colours, but see row 48), 13, 19
(indentation), 23 (table height) and 30 (jump bar).

### New rows (round 2)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 34 | Toolbar overflow | At 1100 the editor-mode group and the Notices circle go into a **"»" circle** placed 7 before the inspector's edge; the scheme capsule **drops its titles** (glyphs and "›" only, about 87 wide); the subtitle truncates in the middle | no "»"; "Glas…" truncated; editor modes collapsed to a pull-down | `liquid-glass.md` §8.2 | 3 | Opus, Sol, Gemini | H |
| 35 | Navigator clipping | Rows never draw above the selector capsule's top. They pass only under the selector and filter capsules. | rows over the toolbar band and window buttons at full contrast | `liquid-glass.md` §8.4 | 3 | Opus, Sol, Gemini | H |
| 36 | Editor top inset | Kept through inspector hide/show, splits and resizes: line 1 stays at y 93 | text moves up 40 pt after the first toggle and stays there | `editor-area.md` §D.5 | 3 | Opus, Sol | H |
| 37 | Toolbar toggles and disabled buttons | No accent fill on any toggle (grey recessed pill only). Unavailable Stop #A2A2A4; Back and Forward #AEAEAE. | accent-filled Navigators toggle and editor mode; black disabled buttons | `liquid-glass.md` §8.1 | 3 | Opus | M |
| 38 | Navigator selection after a click | The band stays (#0070F5) while the file is open; focus stays in the outline | the band appears after 248–519 ms, then vanishes | `navigators.md` round 2 §3 | 3 | Opus, Sol, Gemini | H |
| 39 | Navigator labels | #3B3B3C, regular weight | black, heavier | `metrics.md` §13.1 | 3 | Opus | M |
| 40 | Top bounce (rubber band) | Momentum carries the text **past the top (83 pt here)**, then a **critically damped spring, ω ≈ 12.6 rad/s** (about 0.5 s) brings it back | 10 pt, ω 10.5 | `editor-area.md` §D.4 | 3 | meas. (Opus, Gemini noted the bounce) | M |
| 41 | Inspector rules and alignment | Rules after Type, Full Path and Line Endings, 6 pt from the controls; the Full Path label top-aligned with its first line; 18 from the file-name line to the path | no rules there; label centred; 14 | `metrics.md` §13.3 | 3 | Opus, Sol | M |
| 42 | Inspector headings | bold, **#858587** | #393A3B | `metrics.md` §13.3 | 3 | Sol, Opus | M |
| 43 | Image inspector text | Resolution "**--**" when the file records none; labels dark (#2C2C2C); **Localize… as wide as the value area**; a "Tags" field for resources | "72 × 72 DPI"; grey labels; "Alpha Channe" clipped; a small button; "Only resources are taggable" | `editor-area.md` §D.8 | 3 | Opus, Gemini | M |
| 44 | Status bar for images | No "Line: Col:" | "Line: 1 Col: 1" | §D.7 | 3 | Opus | L |
| 45 | Welcome window | Name cap 13 tall (49 wide for "Xcode"); buttons 36 tall, about 99 / 98 / 129, 8 apart; rows on a **47 pitch** with 1-pt #DFDFDF separators under the text; paths **head-truncated**, another volume shown from its name | title twice the size; middle-truncated full paths | `metrics.md` §13.4 | 3 | Opus, Sol, Gemini | M |
| 46 | Add Editor menu | "Tab" ⌘T, "Editor Pane On Right" ⌃⌘T, "Editor Pane Below" ⌃⌥⌘T | "Add Editor Tab", "Add Editor Pane on Right", "Add Editor Pane Below" | `editor-area.md` §D.9 | 3 | Opus | L |
| 47 | Navigator accessibility | Every row is an `AXRow` titled with its name | the Stripes row could not be found | `navigators.md` round 2 §4 | 3 | Opus, Sol, Gemini | M |
| 48 | Module name after `import` | plain text #322529 | type colour #9D31CE | `editor-area.md` §D.1 | 3 | meas. | L |
| 49 | Navigator scroll-bar track | y 83–832 (3 below the selector capsule, 11 above the filter capsule) | 179–798 | `metrics.md` §13.2 | 3 | Opus, Sol | M |
| 50 | Wrap edge | The text container ends at x ≈ 986, so " so" does not fit on line 6's first row | "so" fits (ink to 987) | `editor-area.md` §C.1 | 3 | Sol, Opus | L |
| 51 | Pinned header onset | Pins exactly when the declaration's line reaches y 87, with no fade; separator in the same frame | not tested (Ycode over-scrolled) | `editor-area.md` §D.2 | 3 | Sol, Gemini | M |

**Top 10 new or changed rows by impact:**
1. 35, navigator clipping.
2. 5, blurred scroll-under at 8.5–18 %.
3. 36, the editor's top inset.
4. 38, navigator selection after a click.
5. 34, toolbar overflow.
6. 9, inspector animation cadence and progressive re-wrap.
7. 25, scroll gain.
8. 37, toggle and disabled states.
9. 41, inspector rules and rhythm.
10. 40, the top bounce.

### Not settled by round 2: Retina capture or round 3 needed

| Item | Why not | Capture needed |
|---|---|---|
| "×" or "x" in the image dimensions; the font size (13 against 13.3); line-number face; corner radii (selection about 8, current line about 4) | 1x rounding | **Retina capture needed**, or the value read through Accessibility for the string |
| Welcome window: list box 343 against 360, rows 47 against 48 | top of the window outside the frame; 1-pt differences | **Retina capture needed**, with the whole window in the frame |
| Overflow order and thresholds; the minimum window width; exact positions | one-step resize; the reference's still is scaled because a menu was open | a slow live resize from 1400 to the minimum, recorded, with no menu open |
| Minimap width rule | three widths | widths about 700, 962 and 1300 |
| Inspector scrolled under its tab bar | the content fits in 880 (neither app scrolled) | a shorter window, or an item with a longer inspector |
| Unfocused selection colour in an active window | the outline kept focus | click into the editor after selecting a row |
| Active against inactive scroll-under share over the same content | different content in rounds 1 and 2 | the bands scroll once key and once not key |
| Overlay scroll-bar style | the Mac's setting | "Show scroll bars: When scrolling" |
| Split editor in the reference | menu labels in the script | use "Editor Pane On Right" |
| Dark appearance | not captured | the session in dark mode |

## Round 3 (2026-11-05)

Both apps were captured at **Retina (2x)** on a 120 Hz display, in the
foreground with the window key, at 120 fps; round 3 numbers compare only
with round 3. Ycode was `0c3ae33f`, wrapped with the macOS 27 SDK so its
glass layout ran. The session added three areas:
- **the merge workflow and conflict editor** (a test repository with a
  conflicting branch; the reference's path was the branch row's context
  menu, the confirmation alert and the merge sheet; Ycode's merge had to
  be started with `git merge` because its branch rows have no context
  menu);
- **Settings ▸ General**;
- **the device window** (Device Hub with an iPhone Duo on iOS 27.1;
  Ycode's simulators run on a remote host, so its canvas showed an
  outline).

Known artefacts: the Mac was under heavy load (load average 300–840 in the
main session), so scroll and flick durations are weighed lightly; neither
app rotated the device, so the landscape step is not scored; three steps
were re-run (main 10–11 for Ycode, Settings and the Repositories still for
the reference).

### Scores

| Step | Opus | Sol | Gemini | Mean |
|---|---|---|---|---|
| 01 select Long.swift | 7 | 7.8 | 8 | 7.6 |
| 02 editor at rest | 6.5 | 7.4 | 7.5 | 7.1 |
| 03 linear scroll 600 pt | 7 | 8 | 6.5 | 7.2 |
| 04 momentum flick | 6 | 7.2 | 6.5 | 6.6 |
| 05 select Stripes.png | 6 | 7 | 7 | 6.7 |
| 06 open Stripes.png (open document) | 4 | 3.5 | 5.5 | 4.3 |
| 07 select Bands.swift | 6 | 6 | 7 | 6.3 |
| 08 bands under the bars | 5.5 | 7.8 | 6.5 | 6.6 |
| 10 hide inspector | 8 | 9 | 8.5 | 8.5 |
| 11 show inspector | 8.5 | 9.2 | 8.5 | 8.7 |
| 12 inspector scroll | 6 | 7 | 9 | 7.3 |
| 13 plain group | 8 | 5.8 | 8.5 | 7.4 |
| 14 expand folder | 7 | 6.2 | 7 | 6.7 |
| 15 navigator scroll | 7 | 7.8 | 4.5 | 6.4 |
| 16 split editor | 6 | 5.8 | 5 | 5.6 |
| 17 narrower window | 6 | 7 | 6 | 6.3 |
| 18 Welcome window | 7.5 | 6 | 8.5 | 7.3 |
| 20 Settings ▸ General | 2.5 | 4 | 4.5 | 3.7 |
| Conflict 01 Repositories view | 5 | 6 | 7.5 | 6.2 |
| Conflict 02 starting the merge | 2 | 1 | 2 | 1.7 |
| Conflict 03 conflict at rest | 2.5 | 2.5 | 4 | 3.0 |
| Conflict 04 Choose Right | 3 | 2.5 | 4.5 | 3.3 |
| Device 01 Home at rest | 5 | 6 | 5 | 5.3 |
| **Area: conflict editor** | **3.0** | **2.8** | **4.5** | **3.4** |
| **Area: Settings** | **2.5** | **4.0** | **4.5** | **3.7** |
| **Area: device window** | **5.0** | **6.0** | **5.0** | **5.3** |
| **Overall** | **5.8** | **6.2** | **6.4** | **6.1** (round 2: 5.9) |

The main-window steps scored in both rounds rose from a mean of 5.95 to
6.97; the overall mean rose less because the three new areas score under 6.

### Disputed values, settled by measurement

| Item | Judges | Measured (reference) | Ycode |
|---|---|---|---|
| "The merge sheet animates in about 288 ms, ease-out" | Opus, Sol, the summary | The 288 ms segment is the **confirmation alert** appearing with the window's veil (veil about 255 ms, ease-out). The **sheet** comes about 1.1 s later, after Merge in the alert: it fades in over about 90 ms and slides down 32 points from under the toolbar over about 200 ms (`merge-sheet.md` §1.2, §10) | the editor appears in one frame |
| "Choose Right takes 330 ms, ease-in-out" | all three | The 330 ms is the **Choose menu's dismissal** (item blink, a hold, a fade). The left pane's text then changes in **one frame**, 117 ms after the menu is gone; the change stays selected (`merge-sheet.md` §7) | the Result pane changes in 50 ms; the view moves to the next change |
| Sheet inset "about 20 pt" | Sol | **24** from each side of the window; top at the toolbar's bottom (52.5); content box 20 inside the sheet | — |
| Gutter "about 46 pt" | Opus | **46** (x 768–814), tokens 38.5 × 14 | — |
| Conflict colours "#FADADD, light blue #D7E8FB" | Opus, summary | conflict rows **#FFDCDD**, changed words **#FF9A9D**, the selected change's rules **#DA5559** (#FF656A once decided); the clean change **#D6EBFE**; in the gutter #F9D5D5 and #D1E4F8 | pink to the end of the text; green #DDF5DD |
| Split editor "200 ms ease-out" | Opus, Sol, Gemini | The split appears in **one frame**; 100 ms later the new pane's jump bar re-lays out once (truncation, issue stepper). No sliding animation (`editor-area.md` E.2) | one frame (12 ms): **matches** |
| Minimap "auto-hides below about 350 pt" | Gemini | **No**: the reference keeps minimaps in split panes: 67 at a 424-point pane, 63 at 274 (`editor-area.md` E.6) | 67 and 45 |
| Full-block glyph "wider in Ycode" | Gemini | Ycode's is **narrower**: 6.89 per block against the reference's 8.0 (one cell); a 110-block row is 758 against 884.5 (`editor-area.md` E.7) | 6.89 |
| Keywords "coral red in Ycode" | Gemini | keywords are **#C4246E in both apps** | matches |
| Ycode's jump bar "opaque #F6F6F6" | Gemini | Ycode's jump bar shows a **flat pink tint** (239–245 in the green channel over red bands), not an opaque fill; what it lacks is the content's structure (`liquid-glass.md` §9.1) | flat tint |
| Settings window "680 × 400" / "708 × 453" / "710 × 452" | Gemini / Opus / summary | **710 × 452** (the capture's window frame) | 860 × 560 |
| Settings sidebar "inset glass" | summary | **flush**: full height, #EDEDED, 179.5 wide plus a 0.5-point divider (`settings.md` R3.2) | flush, 200 |
| Settings title "regular weight" | Opus | regular to medium (stems 1.5–2.0 at a 12-point cap height), colour **#4D4D4D**, not black | bold, #272727 |
| "Loading…" for about 170 ms on selecting an image | Opus (about Ycode) | Reference round 3: **one frame, no Loading**; round 2 showed Loading for about 100 ms after 454 ms. Ycode: Loading for 192 ms (`editor-area.md` E.3) | 192 ms |
| Device inspector rows | `device-hub.md` §6: 32–36 tall | **42 + 1** (43 pitch), in cards 260 wide, 10 apart (`device-hub.md` §11.3) | no cards |
| Momentum flick | all three | confirmed: the reference has no start delay, overshoots **48 points (8 %)** and settles by 713 ms; Ycode holds still **85–98 ms**, overshoots 120 points (20 %), settles by 883 ms (`editor-area.md` E.1) | — |

### Rows whose target changed

| # | Area | New target | Ycode now | Spec |
|---|---|---|---|---|
| 3 | Image viewer | Keep the old content until the image is ready; one-frame swap. Show "Loading…" only if the image is still not ready after about 450 ms. | Loading for 192 ms | `editor-area.md` E.3 |
| 8 | Minimap | Width **clamp(15.5 % of the pane, 63, about 140)**: 131 at 850, 67 at 424, **63 at 274** | 45 at 274 | `editor-area.md` E.6 |
| 40 | Top bounce | No start delay; overshoot scales with the flick (48 for this 600-point flick, 8 %); critically damped return, ω about 11–12.6 rad/s | 85–98 ms delay; 20 % overshoot | `editor-area.md` E.1 |
| 12 | Navigator selection | Accent band only while the outline has focus; the unfocused grey band as soon as an editor takes focus | stays accent blue | `navigators.md` round 3 §1 |

Since round 2 Ycode now matches rows 9 (inspector hide 321 against 323 ms,
show 295 against 296 ms, the same curve shape), 13 (plain-group order),
25 (scroll travel 600 → 600) and 36 (the editor's top inset), and the
split pane sizes. Row 35 is met for the toolbar band; the selector
capsule still shows rows legibly (row 69).

### New rows (round 3)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 52 | Starting a merge | A local branch row's context menu with 12 items in 6 groups, "Merge “b” into “current”…" enabled; then a centred **420 × 133** alert (title, message, Cancel and **Merge**, Merge the default); the veil darkens white to #CDCDCD over about 255 ms | no row menu on macOS; no Integrate ▸ Merge | `merge-sheet.md` §1 | 3 | Opus, Sol, Gemini | H |
| 53 | Merge sheet frame | A modal sheet **24** in from each side of the window, top at the toolbar's bottom, corner radius about 16, over the veiled window; one bordered content box 20 inside it | an in-window three-pane editor with a Result pane | `merge-sheet.md` §2 | 3 | Opus, Sol, Gemini | H |
| 54 | Merge sheet file list | 198 wide; "Hierarchical \| Flat" (Hierarchical default, a #D1E7FF pill); 24-point rows; flush full-width selection #0064E1; a red "C" badge in a white square; a Filter field at the bottom | none | `merge-sheet.md` §3 | 3 | Opus, Gemini | M |
| 55 | Merge sheet panes | Two 523-point source panes with syntax colours, line numbers at +26 to +28, code at +41, current-line highlight on every wrapped visual line; corresponding lines at the same y; one shared jump bar with a conflict navigator; an overview ruler on the right pane | no syntax colour; 17 against 18 lines, misaligned; git markers in a Result pane | `merge-sheet.md` §4 | 3 | Opus, Sol, Gemini | H |
| 56 | Centre gutter | **46** wide, #F5F5F4 between #D7D7D7 rules; one **38.5 × 14** capsule token per change ("?" undecided, a digit once decided, a down-chevron; the chevron in a circle once decided); #575757, the selected change's #6D2A2D with a red rim | connector shapes; no tokens | `merge-sheet.md` §5 | 3 | Opus, Sol, Gemini | H |
| 57 | Row shading | **Full width** through the gutter, one 18-point row per line: conflicts #FFDCDD with changed words #FF9A9D (16 tall, cell-exact); the selected change with 1-point rules #DA5559 above and below; the clean change #D6EBFE | text-width pink and green (#DDF5DD) | `merge-sheet.md` §6 | 3 | Opus, Sol | H |
| 58 | Choose menu | Choose Left, Choose Right, separator, Choose Left Then Right, Choose Right Then Left; opens from the token; the choice rewrites the **left pane** in one frame after a 330 ms menu dismissal; the change stays selected | "Left"/"Right" segments; the left pane not updated; jumps to the next change | `merge-sheet.md` §7 | 3 | Opus, Sol, Gemini | H |
| 59 | Footers and stepper | A 27-point footer row: repository › branch › date, author, short hash ("(HEAD)" on the left) under each pane; "‹ n/m ›" centred on the gutter | none | `merge-sheet.md` §8 | 3 | Opus, Gemini | M |
| 60 | Cancel and Merge | 84-wide buttons right-aligned with the content box, 12 apart, 21.5 below it; Merge disabled while a conflict is undecided | Mark as Resolved, Continue Merge, Abort Merge | `merge-sheet.md` §9 | 3 | Opus, Sol, Gemini | M |
| 61 | Sheet transition | Fade in over about 90 ms while sliding down 32 points from under the toolbar over about 200 ms (keyframes in §10); the alert fades out in the same 90 ms | one frame | `merge-sheet.md` §10 | 3 | Sol, Opus | M |
| 62 | Settings window | **710 × 452**; window buttons at x 19, 42, 65 on y 26, all enabled; one 73.5 × 34.5 glass back/forward capsule with a divider; the title at x 273.5, about 17 points, #4D4D4D, regular to medium | 860 × 560; minimize disabled; two circles; bold black title | `settings.md` R3.1 | 3 | Opus, Sol, Gemini | H |
| 63 | Settings sidebar | Flush, **179.5** + a 0.5 divider #D4D4D4; **32-point rows**; a 160 × 32 selection #0070F5 inset 10; accent-tinted symbols centred on x 29; labels aligned at x 47; 12 items in the reference's order (Ycode's names where the protocol requires) | 200 wide, 26-point rows, grey symbols, labels at 42–47.5, 13 items | `settings.md` R3.2 | 3 | Opus, Sol | H |
| 64 | Settings General pane | Section headers bold over **cards** x 200–690, #F7F7F7, radius about 12; rows 37.5 + 1-point separators #EBEBEB inset 10; labels left at x 211, no colons; help text #7C7C7C, 14-point pitch; pop-ups as value text plus a 20-point circular chevron button 13.5 inside the card; switches 10 inside; controls centred on the label's line | right-aligned labels with colons, checkboxes, no cards, no help | `settings.md` R3.3 | 3 | Opus, Sol, Gemini | H |
| 65 | Device control capsules | Two glass capsules, **108** and **145.5** wide, **36.5** tall, 7.5 apart, floating 8 above the window's bottom edge, centred on the canvas; glyphs black on a 34-point pitch; the current Duo pose in the accent colour | missing | `device-hub.md` §11.1 | 3 | Opus, Sol, Gemini | H |
| 66 | Device inspector | Settings rows in **cards** (x 830–1090, #E6E6E7, radius about 12, 10 apart), **43-point** row pitch, symbol, label, trailing control | one grey message; a full-height scroll track | `device-hub.md` §11.3 | 3 | Opus, Sol, Gemini | M |
| 67 | Device canvas and toolbar | The frame centred between the toolbar and the capsules (no name or OS label under it); with the sidebar hidden no "+" and no Filter; no "»"; the resize toggle beside Capture Keyboard; a plain "i" tab | label under the frame; "+", "»"; "i" in a circle; frame high in the canvas | `device-hub.md` §11.2, §11.4 | 3 | Opus, Sol, Gemini | M |
| 68 | Structure behind the bars | The toolbar band, the jump bar and the bottom bar each show the content behind them **blurred (σ about 6), with its shape**: two smears at the top, a fading band under the bottom bar | a flat tint in every region | `liquid-glass.md` §9.1 | 3 | Opus, Sol, Gemini | H |
| 69 | Selector capsule | Rows under it blurred to smudges (no letter strokes), fill about #E8E8E9; glyphs **black** | rows legible; fill #F0F0F1; glyphs #858585–#9C9C9C | `liquid-glass.md` §9.2 | 3 | Opus, Gemini | M |
| 70 | Flick start | Content follows the gesture's first event; no hold | 85–98 ms hold | `editor-area.md` E.1 | 3 | Opus, Sol, Gemini | M |
| 71 | Split-pane jump bars | Close button at +14, issue stepper at the right in each pane; middle component truncated with a 4-point fade; the inactive pane's path #7F7F7F with grey icons (active #262626 in colour); the second layout within 100 ms | none of these | `editor-area.md` E.2 | 3 | Opus, Gemini | M |
| 72 | Image selection | One-frame swap; no "Loading…" unless the image is not ready after about 450 ms | 192 ms of "Loading…" | `editor-area.md` E.3 | 3 | Opus, Sol, Gemini | M |
| 73 | Open-document request | **Zero changed frames** for a file already open; keep the project's path (no `/private` resolution) and the jump bar's group | 100 ms flash; group lost; `/private/tmp` path | `editor-area.md` E.4 | 3 | Opus, Sol, Gemini | H |
| 74 | Empty editor | Pure white: no minimap, separator, shade or scroll lane | separator, a #EDEDED block, the lane | `editor-area.md` E.5 | 3 | Opus | M |
| 75 | Full-block and fallback glyphs | Every glyph advances one cell (8.0), fallback fonts included | 6.89 per full block | `editor-area.md` E.7 | 3 | Opus, Gemini | M |
| 76 | First layout | Wrap with the final container width (edge about 986) from the first frame | first layout wraps one word later | `editor-area.md` E.7 | 3 | Opus, Sol | L |
| 77 | Minimap floor | Never under about 63 points | 45 at a 274-point pane | `editor-area.md` E.6 | 3 | Opus, Gemini | M |
| 78 | Jump bar text | Path ink y 59.5–72.5 (centred on 66) | 2.75 lower | `metrics.md` §16.1 | 3 | Opus | L |
| 79 | File inspector rhythm | Heading at 90, Location at 168.5, the tags heading at 267, Target Membership at 334; the target's app icon in Target Membership | +3.5, +7, +10, −2.5; an empty checkbox | `metrics.md` §16.2 | 3 | Opus, Gemini | L |
| 80 | Welcome icon | 98 × 98, its bottom 15.5 above the name's cap top | 90 × 90, 44 above | `metrics.md` §16.3 | 3 | Opus, Sol | L |
| 81 | Unfocused selection | The navigator's band turns grey when an editor takes focus | stays blue | `navigators.md` round 3 §1 | 3 | Opus (runner) | M |
| 82 | Repositories view | A full-width Changes \| Repositories control (x 9–281, 16 tall); grey filled group symbols; only Branches expanded at first; no "(current)"; a plain filter field; the empty inspector's line 38.5 lower | compact control, blue folders, Recents expanded, "(current)", an options button | `navigators.md` round 3 §2 | 3 | Opus, Sol, Gemini | M |

**Top 10 new or changed rows by impact:**
1. 52, starting a merge from the branch row and the alert.
2. 53–58, the merge sheet: frame, panes, gutter tokens, full-width
   shading and the Choose menu (build together).
3. 64, Settings ▸ General as grouped cards.
4. 62–63, the Settings window and sidebar.
5. 65, the device window's floating control capsules.
6. 68, content structure behind the toolbar, jump bar and bottom bar.
7. 73, the open-document request repainting nothing.
8. 70 and 40, the flick's start and spring.
9. 71 and 81, split-pane jump bars and the unfocused selection.
10. 66–67, the device inspector's cards and canvas placement.

### Not settled by round 3

| Item | Why not | Capture needed |
|---|---|---|
| The merge sheet's height and bottom margin; the buttons' height; Merge becoming the default | the sheet runs below the 880-point window's bottom edge | the merge sheet in a window 1000+ tall |
| After Merge and after Cancel; the sheet's disappear animation | neither was clicked | complete one merge and cancel another, recorded |
| The token glyph for each choice; Choose Left and the "Then" items; alignment of unequal blocks; whether word fills update after a choice | only Choose Right on one-line changes was captured | a file with a 1-line against 3-line conflict; each menu item once |
| Context menus of the current branch, remote branches, tags and stashes; Integrate ▸ Merge | not captured | right-click each row kind; open Integrate |
| Settings rows below the fold; other panes' sizes; on-state switch | one still of General | scroll General; one still per pane |
| The Zoom to Fit scale rule in the device window | one device (a foldable), one window size | an iPhone 17-class device and an iPad at two window sizes |
| Landscape layout and rotation animation | neither app rotated | a device that rotates, recorded |
| The unfocused selection band's exact grey in an active window | the row was under the filter capsule | select a row in view, then click into the editor |
| Inspector scrolled under its tab bar | the content fit in 880 | a shorter window |
| Dark appearance | not captured | the session in dark mode |

## Round 4 (2026-11-06)

Both apps were captured at **Retina (2x)** on the 120 Hz display, in the
foreground with the window key, at 120 fps, with the same frames as round
3, but in the **dark appearance**: round 4 gives the dark values, and
round 1–3 light values stay valid for light. Ycode was `45c676aa`,
wrapped with the macOS 27 SDK. New this round: Ycode's merge ran through
its own UI (row menu, alert, sheet), and Settings ▸ Editing (step 21) was
added. The load was much lower than in round 3 (Ycode's first scroll
steps at a 1-minute load of 100–190, the reference's at about 45; the
device run at 123–313), so small timing differences in steps 03, 04, 08,
15 and 17 are weighed lightly. Rotation was skipped. The device window
showed a simctl device that Ycode does not operate, so Ycode drew a
generic outline.

### Scores

| Step | Opus | Sol | Gemini | Mean | Round 3 mean |
|---|---|---|---|---|---|
| 01 select Long.swift | 7.5 | 8.2 | 9 | 8.2 | 7.6 |
| 02 editor at rest | 6.5 | 7.8 | 8.5 | 7.6 | 7.1 |
| 03 linear scroll 600 pt | 7.5 | 8 | 7.5 | 7.7 | 7.2 |
| 04 momentum flick | 6 | 6.7 | 8 | 6.9 | 6.6 |
| 05 select Stripes.png | 8 | 6.2 | 8 | 7.4 | 6.7 |
| 06 open Stripes.png (open document) | 9 | 9 | 10 | 9.3 | 4.3 |
| 07 select Bands.swift | 4 | 4.5 | 6 | **4.8** | 6.3 |
| 08 bands under the bars | 5 | 4.2 | 6.5 | **5.2** | 6.6 |
| 10 hide inspector | 5.5 | 7.2 | 7 | **6.6** | 8.5 |
| 11 show inspector | 5.5 | 7 | 7 | **6.5** | 8.7 |
| 12 inspector scroll | 8 | 6.5 | 8 | 7.5 | 7.3 |
| 13 plain group | 8 | 5.5 | 9.5 | 7.7 | 7.4 |
| 14 expand folder | 8.5 | 5.7 | 9 | 7.7 | 6.7 |
| 15 navigator scroll | 8.5 | 6.7 | 9.5 | 8.2 | 6.4 |
| 16 split editor | 8 | 7.3 | 9 | 8.1 | 5.6 |
| 17 narrower window | 6.5 | 6 | 7 | 6.5 | 6.3 |
| 18 Welcome window | 7.5 | 8.2 | 9 | 8.2 | 7.3 |
| 20 Settings ▸ General | 7 | 7.7 | 8 | 7.6 | 3.7 |
| 21 Settings ▸ Editing (new) | 5 | 5.2 | 6.5 | 5.6 | — |
| Conflict 01 Repositories view | 7 | 7.5 | 8.5 | 7.7 | 6.2 |
| Conflict 02 starting the merge | 7.5 | 7 | 7.5 | 7.3 | 1.7 |
| Conflict 03 conflict at rest | 6.5 | 6 | 8 | 6.8 | 3.0 |
| Conflict 04 Choose Right | 7 | 6.3 | 8.5 | 7.3 | 3.3 |
| Device 01 Home at rest | 6.5 | 5.8 | 6 | 6.1 | 5.3 |
| **Area: conflict editor** | **7.0** | **6.6** | **8.0** | **7.2** | 3.4 |
| **Area: Settings** | **6.0** | **6.4** | **7.0** | **6.5** | 3.7 |
| **Area: device window** | **6.5** | **5.8** | **6.0** | **6.1** | 5.3 |
| **Overall** | **7.0** | **6.6** | **7.3** | **7.0** | 6.1 |

Steps 07, 08, 10 and 11 fell. 07–08: the full-block layout and colour
(rows 83, 86, 87). 10–11: Ycode's inspector animation regressed (row 106).

### Disputed values, settled by measurement

| Item | Judges | Measured (reference) | Ycode |
|---|---|---|---|
| Bands: "line height 26 pt" | Gemini | **Wrapping**, not line height: "//" alone, then the 110-block run on two continuation rows; 3 rows of 18 = 54 per line (`editor-area.md` F.1) | 2 rows (36) |
| Number colour "about #D9C97C"; Ycode "#0A84FF" | Opus, summary | glyph core **#ECA900** | #0092FF |
| Comment bands "#C0C4E6 / #929CB0"; string bands "#F08C7C / #FC6A5D" | Opus, summary | flat fills **#ABB3CD** and **#FF8D7A**, equal to the comment and string text colours (F.3) | #9A9A9A, #FF4245 |
| "Ycode's cyan identifiers are more saturated" | Sol | Ycode has **no** declaration colour (#FFFFFF); the reference has three: #00CAFB, #27A7C1, #20AD9D (F.3) | — |
| Choose menu: "an extra separator in Ycode; Xcode's four items evenly spaced" | Opus | **Both** have the separator after Choose Right, at the same offsets (`merge-sheet.md` §13.6) | matches |
| "299 ms progressive live resize" against "a 33 ms snap" | Sol (high), Opus | The step is one programmatic resize: **both** relayout the content in one frame (105 against 274 ms after the request). The 299 ms is the toolbar's overflow capsule shrinking from 120 to 33 wide over 155 ms (F.6) | content in one frame; no morph |
| Text column "15–20 pt wider"; minimap "61 against 52" | Opus | minimaps **62 and 62.5**; text extents equal (476.5); the one wrap difference fits a "space must fit" rule (F.6) | — |
| Welcome window "about 11 pt narrower" | Opus, summary | the **same size** (480 × 629 against 479.5 × 629), 8 points higher (F.11) | — |
| Inspector placeholder "14 against 11 pt" | Opus | cap height **12** (about 17 points) against 9.5 (about 13.5) (F.10) | — |
| Settings switch "41 × 19 against 34 × 17" | Opus | reference **36 × 16**, Ycode 44 × 20 (`settings.md` R4.1) | 44 × 20 |
| Settings selection "#1A7CF5 against #0B63D6" | Opus | **#007AFF** against #0A62D9 (R4.2) | #0A62D9 |
| Editing icons "about 16–18 pt" | Opus, Sol | **24 × 24** rounded squares with vertical gradients (R4.1) | none |
| Editor's bottom-left badge "about 16 × 14" | Opus | a filled #007AFF tag shape **17.5 × 11.5** (F.9) | outline tag |
| Image selection: "blank for about 80 ms, done in 163 ms" | Opus, Sol | blank canvas at 148 ms, "Loading…" at 608 ms, the image at **689 ms** (the tool's segment stopped at the gap) (F.8) | image in one frame at 229 ms |
| Merge path bar "y 866 against 811" | Opus | footer rows y **819–846** against 764.5–791.5; content box to **847** against 792.5: the same 54.5-point difference (§13.3) | — |
| Flick redraws "every 16 ms against 8" | Opus | mean frame interval **13.3 ms** against **31.7 ms** (F.7) | 31.7 ms |
| "No current-line highlight in Xcode's inactive pane" | Opus | a faint band, **#2A2A2A** on #262626 (#353535 when focused) (F.3) | #2D2D2D in both |

### Round 4 rows

Grouped for implementers so that no two groups edit the same files.

**A. Editor text and theme** (`editor-area.md` F.1–F.4, F.6; the source
editor's layout and theme code)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 83 | Whole-run wrap | A run with no break opportunity is one word: if it does not fit the rest of the row, it starts on the next row at the continuation indent; it is broken by character only if it does not fit an empty row. Bands.swift: 3 rows (54) per band line, lines 1–18 visible at rest, line 36 at the top after 1200 points | breaks inside the run on its first row: 2 rows (36), lines 1–29, line 45 | `editor-area.md` F.1 | 3 | Opus, Sol, Gemini | H |
| 84 | Cell advance at 2x | **8.04** (the font's unrounded advance at the backing scale); 80 columns to the container edge at about x 984–986 | 8.00 | F.2 | 3 | meas. | M |
| 85 | Declaration colours (dark) | type declarations **#00CAFB**, other declarations **#27A7C1**, a property referenced in an interpolation **#20AD9D**; the same in the editor and the merge sheet | none (#FFFFFF); `Greeting` in the type-in-use colour in the sheet | F.3 | 3 | Opus, Gemini, meas. | H |
| 86 | Default dark palette | background #262626, plain #FAF1F3, keyword #FF83B4, comment #ABB3CD, string #FF8E7B, number **#ECA900**, type in use #D997FF, line numbers #706D6E, current line's number #FAF1F3, current-line band #353535 (unfocused pane #2A2A2A). **Owner's decision** whether the default theme adopts these | #1E1E1E, #FFFFFF, #FF3860, #9A9A9A, #FF4346, #0092FF, #DC34F3, #9A9A9A, #FFFFFF, #2D2D2D in both panes | F.3 | 3 | Opus, Sol, Gemini | H |
| 87 | Full-block joins | adjacent full blocks share an edge: no overlap, no gap, never a lighter seam (a run may be filled as one rectangle per row) | a 1-point lighter seam at every cell | F.4 | 3 | Opus, Sol | M |
| 88 | Space after a word | (single observation) the space after a word must fit inside the container before the next word starts on that row: "0: a" / "comment" in the 1100-point split | "0: a comment" on one row | F.6 | 3 | Opus, meas. | L |

**B. Settings** (`settings.md` R4.1–R4.3; the Settings window code)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 89 | Editing pane cards | card 1 (Display, Completion, Indentation) y 72–206; **no "Files" header**; Default text encoding alone in a card (216–253.5); Default line endings and Convert existing files on save in the next (263.5–338); cards 10 apart; "When Editing" card at 394 | a "Files" header; one card of three rows (243–357.5); "When Editing" card at 413 | `settings.md` R4.1 | 3 | Opus, Sol, Gemini | H |
| 90 | Navigation rows and icons | rows **44** tall; a **24 × 24** rounded-square icon 10 inside the card, vertical gradient (blue #2BAFFF→#0091FE, cyan #63E3FF→#3BD3FE, periwinkle #94A1FF→#6D7CFF) with a white symbol (described in R4.1); label at x 245; separators x 210–680; chevron #5C5C5C | 37.5-point rows, no icons, labels at 211 | R4.1 | 3 | Opus, Sol, Gemini | H |
| 91 | Pop-up values | value text #DEDEDE ending **12.5–13 before** a 20-point round well (#363636) 13.5 inside the card, in every pane | Editing: grey #9F9F9F text, no well; General: well present but the text ends 2–3 points before it | R4.1, R4.2 | 3 | Opus, Gemini | M |
| 92 | Switch | **36 × 16**, knob about 21 × 12, 10 inside the card; off #3B3B3B, on #0679F7 | 44 × 20, knob 26 × 14 | R4.1 | 3 | Opus | M |
| 93 | Sidebar fits | at most **12 rows** at 32 points in the 452-point window, **no scroller**; Ycode's Simulators item moves (the implementer decides where) | 13 rows, a permanent scroller, the last row cut off | R4.2 | 3 | Opus, Sol, Gemini | M |
| 94 | Sidebar selection (dark) | x 10–170 (160 × 32), **#007AFF** | x 10–162.5 (clipped by the scroller), #0A62D9 | R4.2 | 3 | Opus, Sol | M |
| 95 | Pane title | **semibold**, #E8E8E8 in dark (cap height 12, about 17 points) | regular, #C4C4C4 | R4.2 | 3 | Opus | L |
| 96 | Dark palette | cards #262626 on #1F1F1F, separators #303030, sidebar #262627 with a 0.5-point #414142 divider | #2A2A2A on #1E1E1E, #3A3A3A, #2B2B2B with #111111 | R4.3 | 3 | meas. | L |

**C. Merge and device windows** (`merge-sheet.md` §13, `device-hub.md`
§12; the merge sheet, alert and device-window code)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 97 | Parent window under a modal | behind the alert and the sheet: text at its disabled tone (about 0.63) and toolbar glyphs at theirs (about 0.33) **before** the 0.70 veil; no highlight on the context menu's target row; only the close button disabled (grey), minimize and zoom drawn above the veil in colour | veil only (0.67–0.68); the row stays highlighted; all three window buttons veiled | `merge-sheet.md` §13.1 | 3 | Opus, Sol, Gemini | M |
| 98 | Alert accessibility | alert (and sheet) buttons are accessibility buttons with titles and press actions; the default (Merge) and cancel (Cancel) buttons exposed as such | the alert exposes two static texts and no buttons | §13.2 | 3 | Opus, Sol, Gemini | H |
| 99 | Sheet height | content box y 64–**847** in the 880-point window (33 above the window's bottom); the button row may extend past the window | box to 792.5; sheet bottom 856 | §13.3 | 3 | Opus, Sol | M |
| 100 | Sheet colours (dark) | panes #262627; gutter #313131 between #484848 rules; conflict rows #583436, changed words #9B3A3C, selected rules #DA5559, clean change #2F4457; content-box border a dark hairline #171718 | #1F1F1F; #252525 / #383839; #4A2629, #7D3337, #E06669, #1E3A56; border #3D3D3D | §13.3, §13.4 | 3 | Sol, meas. | M |
| 101 | Gutter tokens | unselected: fill **#575757** with a 0.5-point lighter rim (reads outlined); selected: #6D2A2D with a 1-point #DA5559 rim; light, thin chevron | unselected #8A8A8A, no rim; heavier chevron | §13.5 | 3 | Opus, Sol | L |
| 102 | Choose menu hover | the item under the pointer is highlighted from the menu's first frame (#007AFF bar, 165 × 24); the menu 6 points higher than Ycode's | no highlight until the click | §13.6 | 3 | Opus, Sol | L |
| 103 | Sheet jump bar and footers | the jump bar starts with the project ("Merger"), not the repository folder; both footers name the current branch | "project" first; the right footer names "feature" | §13.7 | 3 | Opus | L |
| 104 | Device control capsules | as row 65, in dark: fill #3B3B3D, 0.5-point lighter rim, white glyphs, divider #505052. Confirm they show for a booted Ycode simulator; decide whether a device Ycode does not operate gets them disabled | none for the captured (non-operated) device, by I.13's design | `device-hub.md` §12.1 | 3 | Opus, Sol, Gemini | M |
| 105 | Device toolbar states | the compact-window button (two inward arrows) **enabled** (#E1E1E1) | disabled (#6F6F71) | §12.2 | 3 | Opus | L |

**D. Main-window motion and chrome** (`editor-area.md` F.5–F.12;
inspector, window, navigator, Welcome and image-editor code)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 106 | Inspector hide/show (**regression**) | first motion within 48 ms (hide) and about 120 ms (show) of the press; about 220 ms ease-in-out (keyframe tables); a new frame on every display refresh (11–12 changed frames) | 78 / 102–132 ms to start; 245 / 261 ms of motion in **5–6 frames** held 40–90 ms | `editor-area.md` F.5 | 3 | Opus, Sol, Gemini | H |
| 107 | Narrowing the window | content relayout in one frame within about 100 ms; a newly shown overflow capsule shrinks from the absorbed items' extent (120) to its circle (33) over about 155 ms, ease-out; no frame with two capsules merged | content at 274 ms (the resize call blocks 264 ms); "»" at once; one merged-capsule frame | F.6 | 3 | Sol, Opus | M |
| 108 | Flick rise | passes the end of travel about 55–60 ms after the first moved frame; peak at 140–150 ms; settled by 700 ms; frames every 13 ms or better | 210 ms, 310–350 ms, 818 ms; 31.7 ms frames | F.7 | 3 | Opus, Sol, Gemini | M (load) |
| 109 | Image selection | switch to the image editor at once (empty canvas with its button); the image when decoded; "Loading…" only after about 450 ms; "--" only for properties not yet read | one frame with the image (correct when the image is ready) | F.8 | 3 | Opus, Sol, Gemini | L |
| 110 | Bottom bars | navigator "+" circle 28 × 28; filter capsule 240 × 28 (x 42.5–282.5, y 844–872); funnel glyph #ABABAC; the editor's bottom-left item a **filled** #007AFF tag shape 17.5 × 11.5 | 31 × 30; 243 × 30; #807F7F; an outline tag | F.9 | 3 | Opus, Sol, Gemini | L |
| 111 | Empty states | inspector placeholder about 17 points (cap 12); "No Selection" in the Repositories view, "Not Applicable" for the project navigator; the empty jump bar: grid button, divider, "No Selection" at x 337.5 in #DEDFDE | about 13.5 points; "Not Applicable" in both; no divider, text dimmed (#565656) from about x 313.5 | F.10 | 3 | Opus, Gemini | L |
| 112 | Welcome window | 8 points lower (y 51.5–680.5 in the capture's frame), same 480 × 629; the stored path shown in full when it fits | 8 higher; a head-truncated path | F.11 | 3 | Opus, Sol, Gemini | L |
| 113 | Session state | each navigator group's expanded state restored with the workspace (Plain expanded: 13 rows at rest) | Plain collapsed (9 rows) | F.12 | 3 | Opus | L |
| 114 | Changes \| Repositories control | 16 tall (row 82), "Changes" ink 45 wide | about 20 tall, text about 10 % larger (49.5 wide) | `navigators.md` round 3 §2 | 3 | Opus | L |

**Top 10 rows by impact:** 83 (whole-run wrap); 85–86 (dark theme and
declaration colours); 106 (inspector regression); 89–90 (Editing pane
structure and icons); 98 (alert accessibility); 97 (parent window under a
modal); 99 (sheet height); 104 (device capsules); 87 (block seams); 93–94
(Settings sidebar fit and selection).

### Round 3 rows now met

Measured or confirmed this round:
- **52–61, the merge workflow:** the row menu, the alert (within 1
  point), the sheet's frame and content layout, file list, two aligned
  panes, gutter tokens, full-width shading, the Choose menu's items and
  effect, footers, buttons, and the sheet's entrance (267 ms against 275
  ms). Remaining: rows 97–103.
- **62–64, Settings:** window size and position, grouped cards, row
  heights, help text and trailing controls on General (rows match within
  0.5). Remaining: rows 91–96.
- **70 and 40, the flick's start and bounce:** start latency 56 ms
  against 49; overshoot 10 % against 11 %. Remaining: row 108 (rise).
- **73, the open-document request:** no repaint (9.3 mean).
- **71 and 81, split panes:** one-frame split, jump bars and the
  inactive pane's dimming match (8.1 mean). Remaining: the unfocused
  pane's band (row 86).
- **75, full-block advance:** Ycode now advances one cell per block.
  Remaining: rows 84 and 87.
- **77, the minimap floor:** 62.5 against 62 at a 274-point pane.
- **66–67 (toolbar part), the device toolbar groups** match within about
  4 points; the inspector's width matches.
- **82 (partly), the Repositories view:** the segmented control is there.
  Remaining: rows 111, 114 and the filled group symbols.
- **72:** superseded by row 109 (the target changed).

Regressed: **9**, the inspector animation (row 106). Still open: **65**
(capsules, row 104), **12** (the icon set, constrained by the clean-room
rules; the judges ask for filled symbols where the reference's are filled
and matching stroke weight and size), **68 and 69** (structure behind the
bars and the selector capsule; no judge raised them this round).

### Not settled by round 4

| Item | Why not | Capture needed |
|---|---|---|
| The "space after a word must fit" rule (row 88) | one observation | a line whose last word ends exactly at the container edge, once followed by a space and a word, once at the end of the line |
| The font behind the 8.04 advance (size or face) | only advances were measured | a ruler line of one repeated glyph at two editor font sizes |
| The merge sheet's height rule and its bottom margin | the sheet runs past the 880-point window | the sheet in a window 1000+ tall |
| Whether both footers always name the current branch | one capture | a merge started from another current branch |
| What the reference's device window shows for a device it cannot drive; whether Ycode's capsules appear for a booted Ycode simulator | the reference only showed a running device; Ycode showed a non-operated one | Ycode's hub with one of its own simulators booted |
| The Welcome window's truncation of a long path | the reference's path fitted | a recent project with a path longer than the row |
| Whether the image inspector's "--" is replaced later | the after still kept "--" | the step held longer, or a second still after a few seconds |
| Light-appearance counterparts of the round 4 dark values (Editing icons, the modal disabled tones, token rims) | dark only | the merge and Settings steps in light |
| The Editing pane below "When Editing" | the window's bottom | scroll the pane |
| The cause of Ycode's inspector frame drops | a Ycode-side question | a profile of Ycode during the toggle (clean room) |

## Round 5 (2026-11-06)

**Owner's design rules** (they decide every row below):
1. Where the reference has the element, **match it**.
2. Where Ycode has an element the reference lacks (the Linux simulator
   host and its page), **design it to the platform's human interface
   guidelines in the OS 26+ glass language**, with the same anatomy as
   its neighbours.
3. Ycode's **macOS and Linux IDEs look one to one**: a row's target
   holds for both.

Both apps were captured as in round 4 (Retina, 120 fps, foreground, key
window, dark) with Ycode `a1f82372`. New this round: the conflict window
sat 36 points below the display's top and app-mode stills and recordings
took a **60-point margin**, so the reference's merge sheet showed whole;
Settings ▸ Components in dark, and Appearance, General, Editing and
Components in light (each app's own Appearance setting set to Light).
Ycode's main session started while the 1-minute load fell from about 265
(steps 03–08 ran at about 150–260, the reference's at about 70), so small
timing differences in 03, 04 and 08 are weighed lightly; later sessions
ran at 20–40. The device window again showed a simctl device that Ycode
does not operate; Ycode now draws its capsules for it, disabled.

### Scores

| Step | Opus | Sol | Gemini | Mean | Round 4 | Round 3 |
|---|---|---|---|---|---|---|
| 01 select Long.swift | 8 | 7.4 | 9.2 | 8.2 | 8.2 | 7.6 |
| 02 editor at rest | 7.5 | 8.7 | 9.2 | 8.5 | 7.6 | 7.1 |
| 03 linear scroll 600 pt | 8 | 8.2 | 9.0 | 8.4 | 7.7 | 7.2 |
| 04 momentum flick | 7.5 | 7.8 | 9.2 | 8.2 | 6.9 | 6.6 |
| 05 select Stripes.png | 7.5 | 6.6 | 8.8 | 7.6 | 7.4 | 6.7 |
| 06 open Stripes.png (open document) | 9 | 9.2 | 9.5 | 9.2 | 9.3 | 4.3 |
| 07 select Bands.swift | 8 | 7.2 | 9.2 | **8.1** | 4.8 | 6.3 |
| 08 bands under the bars | 7.5 | 8.3 | 9.0 | **8.3** | 5.2 | 6.6 |
| 10 hide inspector | 7 | 7.8 | 9.0 | 7.9 | 6.6 | 8.5 |
| 11 show inspector | 7 | 7.5 | 8.8 | 7.8 | 6.5 | 8.7 |
| 12 inspector scroll | 7.5 | 8.2 | 9.5 | 8.4 | 7.5 | 7.3 |
| 13 plain group | 8.5 | 6.1 | 9.2 | 7.9 | 7.7 | 7.4 |
| 14 expand folder | 8.5 | 8.8 | 9.2 | 8.8 | 7.7 | 6.7 |
| 15 navigator scroll | 8.5 | 9.0 | 9.5 | 9.0 | 8.2 | 6.4 |
| 16 split editor | 7.5 | 7.0 | 8.8 | 7.8 | 8.1 | 5.6 |
| 17 narrower window | 6.5 | 8.6 | 7.2 | 7.4 | 6.5 | 6.3 |
| 18 Welcome window | 8.5 | 8.4 | 9.2 | 8.7 | 8.2 | 7.3 |
| 20 Settings ▸ General (dark) | 8 | 8.7 | 8.8 | 8.5 | 7.6 | 3.7 |
| 21 Settings ▸ Editing (dark) | 8 | 9.0 | 9.0 | **8.7** | 5.6 | — |
| 22 Settings ▸ Components (dark, new) | 4.5 | 6.7 | 7.6 | 6.3 | — | — |
| 23 Settings ▸ Appearance (light, new) | 4 | 5.1 | 6.5 | **5.2** | — | — |
| 24 Settings ▸ General (light, new) | 8 | 8.8 | 7.5 | 8.1 | — | — |
| 25 Settings ▸ Editing (light, new) | 8 | 9.1 | 8.0 | 8.4 | — | — |
| 26 Settings ▸ Components (light, new) | 4.5 | 6.8 | 7.2 | 6.2 | — | — |
| Conflict 01 Repositories view | 8 | 8.2 | 9.2 | 8.5 | 7.7 | 6.2 |
| Conflict 02 starting the merge | 7 | 7.4 | 7.8 | 7.4 | 7.3 | 1.7 |
| Conflict 03 conflict at rest | 5.5 | 7.0 | 6.2 | **6.2** | 6.8 | 3.0 |
| Conflict 04 Choose Right | 5.5 | 6.8 | 6.5 | **6.3** | 7.3 | 3.3 |
| Device 01 Home at rest | 7 | 6.4 | 8.8 | 7.4 | 6.1 | 5.3 |
| **Main steps 01–18 (mean of 17)** | **7.79** | **7.93** | **9.03** | **8.25** | 7.31 | 6.87 |
| **Area: conflict editor** | **6.3** | **7.3** | **7.4** | **7.0** | 7.2 | 3.4 |
| **Area: Settings** | **6.5** | **7.7** | **7.8** | **7.3** | 6.5 | 3.7 |
| **Area: device window** | **7.0** | **6.4** | **8.8** | **7.4** | 6.1 | 5.3 |
| **Overall** | **7.3** | **7.7** | **8.5** | **7.8** | 7.0 | 6.1 |

Biggest gains: 07 and 08 (+3.3, +3.1, the whole-run wrap and the dark
theme), Editing (+3.1), the flick (+1.3), the inspector (+1.3), the
device window (+1.3). Only the conflict editor fell (03, 04: the sheet is
clipped at the window's edge now that it is as tall as the reference's).
Settings 20–21 like for like: 6.6 → 8.6. Weakest: 23 Appearance (5.2) and
Components (6.3, 6.2).

### Disputed values, settled by measurement

| Item | Judges | Measured (reference) | Ycode |
|---|---|---|---|
| Merge sheet "hangs about 28–30 below the window" | all | **28**: the sheet's frame y 52–908 in the 880 window; the window does not move or grow; content box to 847 (`merge-sheet.md` §14.1) | box to 847 (matches); drawn only to 880 |
| Choose menu "fades 100 ms late (417 against 333 ms)" | Opus, Sol | the fade itself is the **same**: from about 180–200 to about 390 ms after the click in both; the tool's segments began at different events. The difference is the item's highlight: the reference's is off until 151 ms, Ycode's on at 44, off at 69, on at 144 (§14.3) | — |
| "After the choice the row turns grey with a red C" | Opus, summary | the row turns grey **148 ms after the click on the token**, before the menu opens: focus moves into the panes; the badge turns red (#FF4245) with a white letter (§14.3) | keeps the focused selection; its badge is white with a red letter, not blue |
| Alert "buttons still missing from accessibility" | all | round 5's script still pressed Return for Ycode (its note copied from round 4): **round 5 did not test it** (§13.2) | unverified |
| Light scroll bars "dark charcoal in Ycode"; General's scroller "spurious" | Gemini | both apps: knob #7A7A7A on #F3F3F3 (light), #9F9F9F on #2A2A2A (dark); the reference's General scrolls too (`settings.md` R5.4) | the same |
| Pane title "bolder" / "Medium against Semibold" | Opus, Gemini, summary | **same weight, larger**: cap height 12 against 13.5, "General" 54.5 against 60 wide, the stem scaled with the size; colours equal (R5.3) | 10–12.5 % larger |
| Appearance thumbnails "about 60 × 40", "2 pt ring" | Opus, Gemini | **67 × 44**; ring **3** points #0088FF, 1 point outside (R5.1) | 66 × 42 flat swatches, no ring |
| Components rows "about 47" / "about 52" apart | Opus, Sol | **51.5 + 1 = 52.5** (R5.2) | 37.5 + 1 |
| Split at 1100: "unequal panes", "330 against 220" | Opus, Gemini | pane frames equal within 1.5 in both apps; Ycode's **right pane wraps 2 columns narrower** (widest row 737 against 753) (`editor-area.md` G.2) | — |
| Minimap "about 14 % smaller" | Opus | a comment band line spans 9 points in the reference, 6 in Ycode; the 12-band group repeats every 246 against 210 (G.3) | — |
| Inspector "hide 325 against 250, show 287 against 383" | all | edge motion: hide 198 ms from 60 ms against 119 ms from 132; show 188 ms from 170 against 226 ms from 108, ending in 33–48 ms holds (G.1) | — |
| File switch "blank about 75 ms" | Opus, Sol | the empty editor for **two frames (about 29 ms)**, new text at 202 ms (G.6) | new text at 267 in one frame |
| Split "a 438 ms transition" | Sol, Gemini | the Add Editor button's highlight; the split is one frame in both (G.7) | highlight 110 ms plus a 400 ms fade |
| Device picture "125 points further right" | Sol | both centred; the capsule pair's centre x 410 in both (`device-hub.md` §13) | — |
| "Ycode omits Inner" (step 13); "Xcode fills image properties" (step 05) | Sol | Inner shows in both; it is the reference that shows "--" (summary's corrections) | — |

### Round 5 rows

Grouped for four implementers so that no two groups edit the same files.

**A. Editor text and theme** (`editor-area.md` G.2, G.3; the source
editor's text layout and minimap code)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 115 | Wrap width in each split pane | each pane's text container runs from its text start to about 10.5 before **its own** minimap, from the pane's final frame after a resize; at 1100 both panes fit **17 columns** (right pane: "material for" and "import Foundation" on one row each; widest row ends 753) | right pane **15 columns** (widest row 737): "material" / "for the", "import" / "Foundation"; left pane right | G.2 | 3 | Opus, Gemini, meas. | M |
| 116 | Minimap rows | one **3-point row per visual row**, with the text's own line breaking (F.1): a Bands.swift comment band line spans **9** points, the 12-band group repeats every **246**; minimap 62 wide, meeting the scroll lane | 6 points per comment band line, group every 210 (14 % short); minimap 59 wide plus a 3-point darker strip | G.3, E.6 | 3 | Opus, meas. | M |

Row 88 (the space after a word) was seen again on the same line; it
stays open.

**B. Settings** (`settings.md` R5.1–R5.5; the Settings window code)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 117 | Appearance: top card | card y 72–160; label "Appearance" at x 210.5 (cap top 85.5); three **window-on-wallpaper thumbnails 67 × 44, right-aligned** (x 463, 538, 613; last 10 inside the card), System split down the middle; selection a **3-point #0088FF ring** 1 point outside; captions 10 below, unselected #7C7C7C regular, **selected #262626 bold** | no label; flat swatches 66 × 42 left-aligned; no ring; no bold caption | R5.1 | 3 | Opus, Sol, Gemini | H |
| 118 | Appearance: preview | a **bordered box** x 200–690, y 170–239.5 (1-point #E6E6E6), **line numbers** (#B8B3B4, ending x 228), code from x 243 at an 18-point pitch, **no wrapping**, its own scrollers | no box, no numbers, wraps, 16-point pitch | R5.1 | 3 | Opus, Sol, Gemini | H |
| 119 | Appearance: segments and layout | full-width separators at y 251.5 and 304.5; Theme/Fonts/Editor **210 × 28, centred** (x 340–550), segments 70, divider only between unselected segments; the list **below the second separator scrolls on its own**, the top part stays | 171.5 × 24 at x 200, no separators, one scroll | R5.1 | 3 | Opus, Sol, Gemini | M |
| 120 | Appearance: the list | Theme row with a **push button "Choose…"** (80.5 × 24, no chevron); a **Name** row with the theme's name right-aligned; a Foreground card (56-point row) with a **gradient slider** and a **colour well capsule** 48 × 28; further rows as the reference (not yet captured) | theme name in bold beside a "Choose…" pop-up with a chevron; one colour-well row per syntax element | R5.1 | 3 | Opus, Sol | M |
| 121 | Components | first header "Platform Support" (no row above it); **two-line platform rows 51.5 + 1**: accent icon centred on x 226, title at x 251, subtitle ("Built-in" or the size) 15 below, "Last used …" right-aligned to x 655.5 when known, a **13-point info button** 11.5 inside the card; then "Other Components" | a "Ycode Simulator" navigation row first; "Installed (read-only)"; one-line SDK rows 37.5 + 1, no icons, no info buttons | R5.2 | 3 | Opus, Sol, Gemini | H |
| 122 | Pane title size | cap height **12** (17 points), "General" 54.5 wide, in both appearances, the same weight | cap 13.5, 60 wide (10–12.5 % larger) | R5.3 | 3 | Opus, Gemini, owner's question | L |
| 123 | Selected sidebar label | **semibold** on the selected row (about 3.5 points wider for "Components") | regular | R5.3 | 3 | Sol, meas. | L |
| 124 | Simulator-host settings | per-device settings in the hub's Settings inspector (match); the host's own page designed to the guidelines in the glass language; its entry must not displace "Platform Support": a Components-style row at the end of "Other Components", or a section after it (implementer's choice, both IDEs alike) | a navigation row at the top of Components | R5.5 | 3 | owner's question | M |

**C. Merge and device windows** (`merge-sheet.md` §13.2, §14,
`device-hub.md` §13; the merge sheet, alert and device-window code)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 125 | Sheet below its window | the sheet is its **own window**: frame y 52–**908** in the 880-point window (28 below it), drawn outside the parent over the desktop, bottom corners radius about 16; the parent is not moved or resized; buttons y 866–886, sheet bottom 22 below | drawn inside the parent's frame and **cut at y 880**: Cancel and Merge invisible | §14.1 | 3 | Opus, Sol, Gemini | H |
| 126 | Sheet buttons | rounded rectangles radius about 6, **20 tall**; Cancel #2E2F30 with #DFDFDF label, disabled Merge #252627 with #5B5C5C; tops 19 below the box | capsules (radius about 10), #3A3A3A, tops 21.5 below | §14.2 | 3 | meas. | L |
| 127 | Focus after a token click | clicking a token (or in the panes) moves focus into the panes: within about 150 ms the file list shows the **unfocused grey selection (#464546)** and the badge **red #FF4245 with a white letter** | the file list keeps focus: blue selection, white badge | §14.3 | 3 | Opus, meas. | M |
| 128 | Choose item flash (replaces row 102's "late fade") | on the click, the item's highlight **off, then on at about 150 ms**, the fade from about 190 to 390 ms, the text change at about 450–470 (round 4's hover-from-the-first-frame rule stays) | on at 44, off at 69, on at 144; fade and text change already match | §14.3 | 3 | Opus, Sol, meas. | L |
| 129 | Overview ruler in dark | a knob 11 wide (x 1339–1350), #A2A2A2, over the whole track (y 105–815) when the file fits; 1-point marks over it, #FDB9B5 conflicts, #D4D4D4 clean change, at (line − 0.5) ÷ lines of the track | no knob; marks #9B4B48 / #5A5B5A at (line − 1) ÷ (lines − 1) of the pane | §14.4 | 3 | Opus | L |
| 130 | Alert accessibility (restates row 98) | reachable from the **application element through children only** (application → window → sheet → button); each button role **button**, name in the **title** attribute, press action returning success; Merge the default and Cancel the cancel button; the hit test at a button's centre finds it; **verified from outside the process** with the capture tool's find and press | in-process test from the window's frame view only; round 5 did not test it | §13.2 | 3, 1 | Opus, Sol, Gemini | H |
| 131 | Second capsule for a foldable | **Rotate │ three posture buttons** (closed, current, in the accent colour; half open; flat), **146 × 36**, centres 415.5, then 452.75, 486.5, 520.5 (34 apart), divider at 434; shown disabled for a foldable Ycode does not operate | Rotate alone, 40 × 36 | `device-hub.md` §13.1 | 3 | Opus, Sol | M |
| 132 | Rotate glyph | a square with curved arrows at **two opposite corners** (19 × 21.5) | a square with one arrow at its top-right | §13.1 | 3 | meas. | L |

**D. Main-window chrome and motion** (`editor-area.md` G.1, G.4–G.9;
inspector, window, toolbar, jump bar, navigator and image-editor code)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 133 | Inspector hide/show (updates row 106) | hide starts within about **60 ms**, show within about **120–170**; **about 200 ms ease-in-out** both ways (keyframe tables); a new position at least every 25 ms, no holds in the last third | hide starts at 132 and moves in 119 ms (5 positions); show starts at 108, ease-out, 226 ms with **33–48 ms holds** at the end | G.1 | 3 | Opus, Sol, Gemini | M |
| 134 | Narrowing (updates row 107) | content relayout in one frame within about **200 ms** (219 this round, 105 in round 4) without blocking the caller; the overflow "»" at full size from its first frame, the capsule settled within about **170 ms**; no merged capsules | content at 415 (the call waits for it); "»" grows from small; capsule from 115 wide, settled at 607; scheme capsule merged with the next group for three frames | G.4 | 3 | Sol, Opus | M |
| 135 | Image inspector spacing | header ink **8.5** below a separator; content **13–18** below the header; next separator **12–16.5** below the content; property rows **18** apart (Image Properties rows at 359, 377, 395.5, 413.5; Target Membership header 513.5) | 12.5, 4–6, 5.5–9.5, 20: everything from the Tags field down 8–32 points high | G.5 | 3 | Opus, meas. | L |
| 136 | File switch | the new text within about **200 ms** of the click; up to two frames (about 30 ms) of the empty editor before it; never the old text under the new jump bar | new text at 267 ms in one frame | G.6 | 3 | Opus, Sol | L |
| 137 | Add Editor button | the bright press highlight is a **single frame** when the menu opens, then the menu-open state | bright for 110 ms, then a 400 ms fade | G.7 | 3 | Opus, meas. | L |
| 138 | Issue capsule in the toolbar | a capsule **36 tall** right after the scheme capsule (x 811–872 for one warning): per issue kind, its symbol and count (errors first: red circle with a white cross; warnings: yellow triangle with a white mark); symbol only in a narrow window; hidden with no issues | none | G.8 | 3 | Opus | M |
| 139 | Jump-bar issue stepper | at the right end of **every editor's jump bar**: back chevron, the most severe kind's symbol, forward chevron (x 1084.5–1124.5 in the 1400 window); steps through the issues | none (only in the merge sheet) | G.8 | 3 | Opus | M |
| 140 | Split latency (to confirm) | the split one frame, **858 ms** after the menu item's press | not within 1.2 s of the press (seen at 2.2 s) | G.7 | 3 | meas. | L (confirm) |
| 141 | Activity subtitle | while the workspace prepares its editor services, a second line under the window title naming the activity (Ycode's own words) | none | G.9 | 3 | Opus | L |

**Top 10 rows by impact:** 125 (the sheet below the window); 130 (alert
accessibility, verified from outside); 117–118 (Appearance's card and
preview); 121 (Components' platform rows); 115 (right-pane wrap width);
127 (focus after a token click); 138–139 (issue capsule and stepper);
131 (the foldable's posture buttons); 133 (inspector motion); 124 (where
the host page goes).

### Round 4 rows now met

From the stills of this round:
- **Met:** 83 (whole-run wrap), 85 (declaration colours), 87 (block
  joins), 89–93 (Editing's cards, icons, pop-ups, switch, sidebar fit),
  103 (jump bar and footers), 105 (compact-window button), 110 (bottom
  bars: "+" about 28, filter capsule about 240 × 28), 114 (Changes │
  Repositories).
- **Met, not raised:** 84, 86 (editor background #262626), 94 (selection
  #007AFF, measured), 96 (cards #262626 on #1F1F1F), 97, 100 (panes
  #262627, conflict rows #583336), 101, 111. 99's content box (to 847)
  is met.
- **Met as specified:** 109: Ycode draws the image in one frame when it
  is ready, which is F.8's target.
- **Partly:** 95 (weight now right; size row 122); 99 (the sheet now cut
  at the window: row 125); 102 (hover not testable this round; the fade
  matches; row 128); 104 (capsules shown, disabled; the posture group
  missing: row 131); 106 (row 133); 107 (row 134); 108 (flick settle 792
  against 685 ms, at higher load); 112 (path not resolved, G.9).
- **Open:** 88 (seen again), 98 (untested: row 130), 113 (Plain still
  collapsed).

### Not settled by round 5

| Item | Why not | Capture needed |
|---|---|---|
| The reference alert's accessibility tree (sheet role and subrole, children order, default and cancel attributes) | never recorded | the capture tool's `tree` (scope app, depth 4) with the alert up; press Ycode's alert through accessibility too |
| The merge sheet's height rule; the sheet when the screen has no room below the window | one window height, room below | the sheet in a 1000+ window, and with the window's bottom at the screen's bottom |
| Whether the disabled Merge sits 1.5 lower than Cancel | one still | the sheet with Merge enabled and disabled |
| Hover on the Choose menu when the pointer rests on an item | the driver restores the pointer after each click | a hover to the item before the click |
| Ycode's split latency (row 140) | the recording ended 1.2 s after the press | a 3-second post-roll |
| Whether the reference fills "--" image properties later | the after still is 1.2 s after the step | a still 5 s after the step |
| The issue capsule and stepper with no issues, and the stepper's order | the project always had an issue | a clean project; step through two issues |
| Appearance in dark; Fonts and Editor segments; the list below Foreground; Components below the first "Other Components" row | not captured | scroll and switch segments in both appearances |
| The second capsule for a classic iPhone, an iPad, a watch | only the foldable | the hub with those devices |
| The overflow capsule's start width (120 in round 4, about 40 in round 5) | two rounds disagree | the narrowing step again, and a slow live resize |
| Row 88's "space must fit" rule | the same line twice | a line ending exactly at the container edge, with and without a following word |

## Round 6 (2026-11-07)

**Owner's design rules** (they decide every row below):
1. Where the reference has the element, **match it**.
2. Where Ycode has an element the reference lacks, **design it to the
   platform's human interface guidelines in the OS 26+ Liquid Glass
   language**, with the same anatomy as its neighbours.
3. Ycode's **macOS and Linux IDEs look one to one**: a row's target
   holds for both.

Both apps were captured as in round 5 (Retina, 120 fps, foreground, key
window, the conflict window 36 below the display's top with a 60-point
margin), with Ycode `0f1408a4`, but with the **system appearance Light**
(round 5: Dark). So the main, conflict and device steps are light in
both apps, and Settings 20–22 are light too; each app's own Appearance
was set to Dark for a supplement (D02–D05: Appearance, General, Editing,
Components). Ycode's main steps 01–08 were re-run at the reference's
load (1-minute load 11–15 against 10–13), so this round's scroll and
flick timings compare like for like. Ycode's first main run hung in a
toolbar layout loop after Settings opened over the narrowed, split
window (a Ycode bug; Settings 19–28 were taken from a fresh instance).

### Scores

Round 6 is light, round 5 dark, except where the note says so; Settings
rows compare like with like (round 6's light 20–22 against round 5's
light 24–26; round 6's dark D03–D05 against round 5's dark 20–22).

| Step | Opus | Sol | Gemini | Mean | Round 5 | Round 4 | Round 3 |
|---|---|---|---|---|---|---|---|
| 01 select Long.swift | 8.5 | 8.7 | 9.3 | 8.83 | 8.2 | 8.2 | 7.6 |
| 02 editor at rest | 8.5 | 8.8 | 9.2 | 8.83 | 8.5 | 7.6 | 7.1 |
| 03 linear scroll 600 pt | 9 | 9.4 | 9.6 | **9.33** | 8.4 | 7.7 | 7.2 |
| 04 momentum flick | 7.5 | 7.9 | 8.0 | 7.80 | 8.2 | 6.9 | 6.6 |
| 05 select Stripes.png | 8 | 8.1 | 9.3 | 8.47 | 7.6 | 7.4 | 6.7 |
| 06 open Stripes.png | 9.5 | 9.6 | 10 | 9.70 | 9.2 | 9.3 | 4.3 |
| 07 select Bands.swift | 9 | 9.0 | 9.1 | 9.03 | 8.1 | 4.8 | 6.3 |
| 08 bands under the bars | 8.5 | 8.9 | 9.2 | 8.87 | 8.3 | 5.2 | 6.6 |
| 10 hide inspector | 7.5 | 8.2 | 9.0 | 8.23 | 7.9 | 6.6 | 8.5 |
| 11 show inspector | 8 | 8.0 | 9.1 | 8.37 | 7.8 | 6.5 | 8.7 |
| 12 inspector scroll | 9 | 8.8 | 10 | 9.27 | 8.4 | 7.5 | 7.3 |
| 13 plain group | 8 | 7.7 | 7.8 | 7.83 | 7.9 | 7.7 | 7.4 |
| 14 expand folder | 9 | 8.7 | 9.5 | 9.07 | 8.8 | 7.7 | 6.7 |
| 15 navigator scroll | 9 | 9.2 | 9.4 | 9.20 | 9.0 | 8.2 | 6.4 |
| 16 split editor | 8.5 | 7.8 | 9.5 | 8.60 | 7.8 | 8.1 | 5.6 |
| 17 narrower window | 7 | 8.8 | 8.8 | 8.20 | 7.4 | 6.5 | 6.3 |
| 18 Welcome window | 9 | 9.0 | 9.6 | 9.20 | 8.7 | 8.2 | 7.3 |
| 20 Settings ▸ General (light; R5's 24) | 9 | 9.2 | 9.2 | 9.13 | 8.1 | — | — |
| 21 Settings ▸ Editing (light; R5's 25) | 9 | 9.3 | 9.6 | 9.30 | 8.4 | — | — |
| 22 Settings ▸ Components (light; R5's 26) | 8.5 | 9.4 | 9.5 | **9.13** | 6.2 | — | — |
| 23 Settings ▸ Appearance (light) | 8 | 8.2 | 9.2 | **8.47** | 5.2 | — | — |
| 24 General (own Appearance Light) | 9 | 9.2 | 9.3 | 9.17 | 8.1 | — | — |
| 25 Editing (own Appearance Light) | 9 | 9.3 | 9.6 | 9.30 | 8.4 | — | — |
| 26 Components (own Appearance Light) | 8.5 | 9.4 | 9.5 | **9.13** | 6.2 | — | — |
| D02 Appearance (dark, new) | 8 | 8.2 | 9.3 | 8.50 | — | — | — |
| D03 General (dark; R5's 20) | 8.5 | 9.1 | 9.3 | 8.97 | 8.5 | 7.6 | 3.7 |
| D04 Editing (dark; R5's 21) | 8.5 | 9.3 | 9.6 | 9.13 | 8.7 | 5.6 | — |
| D05 Components (dark; R5's 22) | 8.5 | 9.3 | 9.5 | **9.10** | 6.3 | — | — |
| Conflict 01 Repositories view | 7.5 | 8.4 | 9.0 | 8.30 | 8.5 | 7.7 | 6.2 |
| Conflict 02 starting the merge | 9 | 9.0 | 9.3 | **9.10** | 7.4 | 7.3 | 1.7 |
| Conflict 03 conflict at rest | 8 | 9.1 | 9.4 | **8.83** | 6.2 | 6.8 | 3.0 |
| Conflict 04 Choose Right | 7.5 | 8.5 | 9.2 | **8.40** | 6.3 | 7.3 | 3.3 |
| Device 01 Home at rest | 7.5 | 6.8 | 8.7 | 7.67 | 7.4 | 6.1 | 5.3 |
| **Main steps 01–18 (mean of 17)** | **8.44** | **8.62** | **9.20** | **8.75** | 8.25 | 7.31 | 6.87 |
| **Area: conflict editor** | **8.0** | **8.8** | **9.2** | **8.67** | 7.00 | 7.20 | 3.43 |
| **Area: Settings** (20–26, D02–D05) | **8.6** | **9.0** | **9.4** | **9.00** | 7.33 | 6.47 | 3.67 |
| **Area: device window** | **7.5** | **6.8** | **8.7** | **7.67** | 7.40 | 6.10 | 5.33 |
| **Overall** | **8.3** | **8.7** | **8.9** | **8.63** | 7.83 | 6.97 | 6.13 |

Biggest gains: Appearance (5.2 → 8.47), Components (6.2 → 9.13), the
conflict steps 02–04 (+1.7 to +2.6; the sheet whole, the alert in the
accessibility tree), the Settings area (+1.67). The spread between the
judges (8.3 to 8.9) is the narrowest so far. Weakest: the device window
(7.67), the flick (7.80), the plain group (7.83), the narrow window
(8.20), the inspector (8.23, 8.37).

### Disputed values, settled by measurement

| Item | Judges | Measured (reference) | Ycode |
|---|---|---|---|
| Device outline "130 × 185 against 225 × 320" (Sol), "175 × 350 against 350 × 700" (Gemini) | Sol, Gemini | frame **274 × 379.5**, screen **248 × 360**: **0.53** of the cover's 466 × 678 points (`device-hub.md` §14.2) | frame 460 × 651.5, screen 431.5 × 627.5: 0.93 (1.74 times) |
| "Actual Size selected" | Opus | **Zoom to Fit** in both: the second segment, the magnifier with four outward arrowheads (§14.1) | the same segment |
| Flick "settles without overshoot in the reference" | all | **both stretch past the top**: the reference to **119** points, Ycode to 199; both spring back critically damped at ω about 13.5 per second; the tool's pixel progress missed the reference's stretch (`editor-area.md` H.1) | 199; updates every 2–3 frames |
| Flick "703 against 905 ms" | all | settled at about **700–780** against about 870; the reference reaches the top in one frame at 90 ms, Ycode in four steps by 160 | — |
| Inspector "303 / 278 against 377 / 368 ms" | all | the edge moves **196** (hide) and **231** (show) ms in the reference, **191** and **224** in Ycode; Ycode's extra is a 9-pixel repaint at the editor's right edge 70–90 ms after the motion. The curves are swapped (H.2) | — |
| Split at 1100: Ycode's text area "3 narrower" (summary), "12 wider" (Gemini) | Gemini, summary | Ycode's is **1.5 wider** (to the minimap separator 488 against 486.5); both hold 17 columns; the difference is **the space after a word** (H.4) | — |
| Narrowing "latency 365 against 101" | Opus | content frame **116** against 375; the request returned at 222 against **1247** (H.3) | — |
| Choose Right "303 against 417 ms" | all | the item's highlight at **165** against 57; the fade (215–319 against 207–323) and the new text (452 against 457) match; Ycode's wider change is the conflict's rules changing in the same frame (`merge-sheet.md` §15.2) | — |
| Split "animated 332 ms" | Sol, Gemini | the split is one frame in both (E.2); 332 ms is the Add Editor button fading into its menu-open state, which the reference draws too (486–708 ms); only the reference's single darker press frame is missing (H.8) | — |
| Navigator scroller "about 25 shorter" | Opus | thumb **437** on a track 91.5–849.5 against 384 on 127.5–836; at equal tracks about 26 shorter (H.10) | — |
| Settings "rows drift 1–1.5 lower" | Opus | the reference's rows are content-sized (pop-up rows about 37.25, switch rows 36.5) and its labels 13 below a row's top; Ycode's rows are all 37.5, labels 14 below: 1 to 3.5 lower further down (`settings.md` R6.3) | — |
| Components subtitle "about 3 pt" | Opus | a size subtitle starts **3–3.5** right of the title; "Built-in" does not; and "Last used" is the **subtitle's size**, not 13 points (R6.2) | aligned; "Last used" 13 points |
| Description lengths differ | Sol | Ycode's own words; line counts equal (R6.4) | — |
| Filter glyph "#333333, 1.5–2 times the stroke" | all | the reference #777777, 1 point, 14.5 × 13 (H.9) | **#000000**, 1–1.5 |
| Welcome row "/tmp against /private/tmp" | Opus | confirmed: the reference resolves the link (H.10) | — |

### Round 6 rows

Grouped for four implementers so that no two groups edit the same files.
Group A owns the jump bar's layout; group D's stepper (row 161) is a
fixed-width trailing part that A's collapse rule (row 144) leaves alone.

**A. Editor text, wrap, jump bar and the merge sheet's word runs**
(`editor-area.md` H.4, `merge-sheet.md` §15.1–§15.3; the source
editor's line breaking, the jump bar, the merge sheet's panes and ruler)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 142 | Line breaking: the space after a word (supersedes row 88) | a word moves to the next row when **it and the space after it** do not fit, unless it ends its logical line; at 1100 with a split, line 6 breaks "0: a" / "comment" while "import Foundation" (also to column 17) stays on one row; containers hold 17 columns of 8.04 from x 341.5 | lets the trailing space hang: "0: a comment" on one row | H.4 | 3 | Opus, Gemini, meas. | M |
| 143 | Jump-bar spacing | icon to title **6**, title to chevron **7**, chevron (2 wide) to the next icon **10.5**, chevron to an icon-less title 9.5 | 0–4, 4, 4.5 (chevron 3 wide): the path 20 shorter at 1400 | H.4 | 3 | meas. | L |
| 144 | Jump-bar collapse order | when the path does not fit: **(1)** the project's and groups' titles go, their icons stay; **(2)** then the file's title is cut from its end with a fade; **(3)** the last item ("No Selection" or the symbol) stays whole. At 1100: icon › icon › file icon "Lo…" › "No Selection" (ending 23 inside the pane) | keeps "GlassScroll", drops the group's title, cuts "No Selection" to "No Se" | H.4 | 3 | Opus, meas. | M |
| 145 | Jump bar's last item colour | "No Selection" in the same colour as the other items (the active pane's label colour, the inactive pane's grey) | a lighter secondary grey | H.4 | 3 | meas. | L |
| 146 | Changed-word runs | tokens = word-character runs, whitespace runs and **single other characters**; fill each **maximal run of unmatched tokens** as one box (inner spaces filled): "Good", "morning" (no quote, no comma); "See you soon" one run | splits on whitespace: "\"Good", "morning,", "See", "you", "soon," | §15.1 | 3 | Opus, meas. | M |
| 147 | Current change's rules | **#FF656A while the panes have focus** (113 ms after the click on a token), #DA5559 while the file list has it; at the choice only the text changes | turn #FF656A only when the choice is applied (a full-width repaint) | §15.2 | 3 | meas. | L |
| 148 | Overview ruler in light | marks at (line − 0.5) ÷ lines of a track **105–815**: y 423, 571, 719 | the same fraction of 105–853: 16.5–36.5 lower | §15.3 | 3 | Opus | L |

**B. Settings** (`settings.md` R6.1–R6.3; the Settings window code)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 149 | Appearance: Foreground row | slider track x 421.5–624 (14 tall) in **one hue from a pale tint to the full colour**, a darker 1-point edge; knob about 28 across, white rim around the colour under it, at the theme's value (**50 %** for the default); colour well **48 × 28** with a **3-point #DFDFDF rim** around the knob's colour | a grey gradient, the knob at the right end, a rimless 42 × 22 grey well | R6.1 | 3 | Opus, Sol, Gemini | M |
| 150 | Choose… shape | a **rounded rectangle, radius about 6**, 80.5 × 24 | a capsule (radius 12) | R6.1 | 3 | Opus, meas. | L |
| 151 | Theme row's content | button y 310.5–334.5, label cap top 317.5: 5.5 below the card's top (2.25 above the row's centre) | centred: 2.5 lower | R6.1 | 3 | Opus | L |
| 152 | Components: subtitle and "Last used" | a size subtitle starts **3–3.5 right** of the title ("Built-in" aligned); "Last used …" at the **subtitle's size** (cap 8) | sizes aligned with the title; "Last used" at about 13 points | R6.2 | 3 | Opus, meas. | L |
| 153 | Row heights | content-sized: pop-up rows about **37.25 + 1**, switch rows **36.5 + 1**, a switch with a two-line description 66; labels **13** below a row's top; a description **17.5** below its title's top | every row 37.5 + 1, labels 14 below, description 20.5 below: 1–3.5 lower further down | R6.3 | 3 | Opus, meas. | L |

**C. Device window** (`device-hub.md` §14; the device canvas code)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 154 | Device scale at Zoom to Fit | the frame fills **54 % of the free height** (toolbar's bottom to the capsules' top) and at most **33 % of the canvas width**, centred in that space: in the 1100 × 800 window the Duo's cover at **0.53** of its points (screen 248 × 360, frame 274 × 379.5, 161 above and 163 below); rescales with the window (an interim rule; one window size captured) | 0.93 (frame 460 × 651.5, 26 above and below) | §14.2, §14.3 | 3 | Opus, Sol, Gemini | **H** |
| 155 | Frame band and buttons | band about 16 device points (8.5 here) in two tones: black inside, mid grey (#505050–#6F6F6F) outside; on a foldable's closed posture a 10-point grey step on the hinge side; the cover's buttons: two bars on the top edge, one on the right edge | one near-black tone (#121212) 11.5 with a 1-point rim; three bars on the left, one on the right | §14.2 | 3 | meas. | L |
| 156 | Zoom to Fit glyph | a magnifier holding four small outward arrowheads (Ycode's drawing) | a magnifier holding a diagonal two-headed arrow | §14.1 | 3 | meas. | L |

**D. Main-window chrome and motion** (`editor-area.md` H.1–H.3, H.5–H.10,
`merge-sheet.md` §15.4; scroll, inspector, window, toolbar, navigator,
image-editor, Welcome and alert code)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 157 | Flick at the edge (supersedes row 108) | the gesture's pending deltas in the first moved frame (the top reached in one frame at 90 ms); a stretch past the edge peaking at about **120 points** about 70 ms later; a **critically damped return, ω about 13.5 per second**, no oscillation; settled in about 700 ms; a new position **every display frame** | the top reached in four steps by 160; stretch **199**; the same return; positions every 2–3 frames (about 30 per second) | H.1 | 3 | Opus, Sol, Gemini | M |
| 158 | Inspector hide and show (supersedes row 133) | **hide**: from about 77 ms over about **195 ms, ease-out** (16 % of the travel in the first 21 ms); **show**: from about 95 ms over about **230 ms, ease-in-out** (keyframe tables); a new position at least every 27 ms; **nothing repainted after the motion** | timing envelope met; the curves swapped (hide ease-in-out, show ease-out); 41–51 ms holds; a 9-pixel repaint at the editor's right edge 70–90 ms after | H.2 | 3 | Opus, Sol, Gemini | M |
| 159 | Narrowing (supersedes row 134) | content relayout in one frame within about **120 ms** of the size request; the request returns without waiting (about 220 ms); the overflow capsule morphs from the absorbed items' extent (124 wide here) to its circle over about **165 ms**, ease-out, with the "»" at full size throughout | relayout at 375; the request returns at 1247; the capsule at its final size from the start, the "»" growing from a dot over 229 ms | H.3 | 3 | Opus, meas. | M |
| 160 | Navigator at first open (supersedes row 113) | with no saved state: the project row and **every group or folder that is a direct child of the main group** expanded (GlassScroll and Plain), deeper ones collapsed (Models, Sub) | only the project and its first group (Plain collapsed, so step 13's click expands Plain) | H.6 | 3 | Opus, Sol, Gemini | M |
| 161 | Issue capsule and jump-bar stepper (restates rows 138–139 in light) | capsule 36 tall, 7.5–8 after the scheme capsule, fill #F9F9F9 with a #BFBFBF hairline; per kind its symbol (17–17.5 wide, 16.5 inside the capsule) and a black count 5 after it, errors first, pairs 24.5 apart (61 wide for one warning, 111 for an error and a warning); stepper chevrons #7F7F7F around the most severe symbol at x 1084.5–1124.5, shown in every editor's jump bar even with "No Selection"; **neither shown with no issues** | none | H.5 | 3 | Opus, Sol, Gemini | M |
| 162 | Image inspector | Dimensions, Resolution, Color Space, Alpha Channel **"--"** when the image is selected in the navigator (F.8's acceptance withdrawn); the Tags field #E0E0E1 with its placeholder **6.5 in and vertically centred** | filled values; field #D5D5D6; placeholder 2.5 in, 3 below the top | H.7 | 3 | Opus, Sol, Gemini | L |
| 163 | File switch (supersedes row 136) | the new file's content within about **210 ms** of the click (216 text, 205 the empty image viewer); the inspector may follow one frame (text) or about 80 ms (image) later; no empty-editor frame needed | everything at 266–272 in one frame | H.7 | 3 | Opus, meas. | L |
| 164 | Add Editor press (supersedes row 137) | a **single darker frame** (about 15 ms) on the press, then the fade into the menu-open state (about 220 ms) | the fade matches; no darker frame | H.8 | 3 | Opus, Sol, Gemini | L |
| 165 | Navigator filter glyph | **#777777**, 1-point stroke, 14.5 × 13; its chevron the same grey | #000000, 1–1.5, 13.5 × 14 | H.9 | 3 | Opus, Sol, Gemini | L |
| 166 | Toolbar and Source Control glyphs | the reference's items, grouping and fill style in Ycode's own drawings: leading capsule a list glyph and a sparkle; the bubble left of the scheme in a pink-to-purple gradient; Source Control groups **filled grey**, the control y 90–106 with its labels about 9 % larger than Ycode's, rows 1.5–3.5 lower than Ycode's; the standalone cloud circle (37 wide, 7.5 before the Add Editor capsule): **owner's decision** on an equivalent status item (rule 2) | sidebar glyph and speech bubble; a black bubble; outline group glyphs; control 2 higher; no circle | H.9 | 3 | Opus, Sol, Gemini | L |
| 167 | Navigator scroller | the track from just below the navigator's top bar to just above its bottom bar (y 91.5–849.5 here); the thumb the visible share of the content (437 of 758 at step 15) | track 127.5–836; thumb 384 | H.10 | 3 | Opus, meas. | L |
| 168 | Alert accessibility order (completes row 130) | the sheet's children: [an empty status image], **Merge**, **Cancel**, the message (296 × 34), the application icon as an image with a description, the informative text (296 × 30) | message (296 × 36), informative text (296 × 32), Cancel, Merge; no images | §15.4 | 3 | Opus, Sol, Gemini | L |
| 169 | Welcome window path | the recent project's **real path** (symbolic links resolved: "/private/tmp/…"); the inspector keeps the path as opened | the path as opened ("/tmp/…") | H.10 | 3 | Opus | L |

**Top 10 rows by impact:** 154 (device scale); 157 (flick stretch and
cadence); 160 (first-open expansion); 161 (issue capsule and stepper);
158 (inspector curves); 142 (the space rule); 144 (jump-bar collapse);
149 (Foreground row); 146 (word runs); 159 (narrowing).

### Round 5 rows now met

From this round's stills and recordings:
- **Met:** 115 (each pane wraps at its own width: 17 columns in both
  panes at 1100), 116 (the minimap's 12-band group repeats every 246 in
  both, measured), 117–119 (Appearance's card, thumbnails and ring,
  preview, segments; the thumbnails' artwork is Ycode's own), 121
  (Components' two sections and two-line rows; the details are row 152),
  122 (the pane title), 125 (the sheet below its window, both buttons
  visible), 127 (the file row grey with the red badge after a token
  click), 130 (the alert's buttons found and pressed from outside; the
  order is row 168), 131 (the posture buttons), 135 (the image
  inspector's spacing, every row within a point).
- **Partly:** 120 (push button and Name row present; rows 149–151), 133
  (start and duration within 10 ms; curves and cadence, row 158), 136
  (no blank frame needed; latency, row 163), 137 (the fade matches; the
  darker frame, row 164).
- **Open:** 128 (the Choose item's on-off-on at 57, 73, 140 ms; Ycode's
  menu is the system's, §14.5), 134 (row 159), 138–139 (row 161), 140
  (Ycode's split again not within the 1.2 s after the press; the
  reference's at 738 ms), 141 (no activity subtitle was visible in this
  round's conflict stills, so it was not tested).
- **Not re-measured:** 123 (the selected sidebar label's weight), 124
  (the simulator host's settings page, not captured), 126 (the sheet's
  buttons, captured in light only), 129 (the ruler in dark; light is row
  148), 132 (the Rotate glyph).
- **Round 4 rows:** 88 becomes row 142, 108 row 157, 113 row 160.

### Not settled by round 6

| Item | Why not | Capture needed |
|---|---|---|
| The device's Zoom to Fit rule (row 154 is an interim fit) | one window size in every round | the same device at Zoom to Fit in a second window size and with the inspector hidden; a classic iPhone and an iPad in 1100 × 800; the Duo opened |
| The flick's stretch for other speeds and at the bottom edge | one flick, at the top | flicks at two speeds, up to the top and down to the bottom |
| Which leading jump-bar title goes first | at 1100 both went | the split at a width between 1100 and 1400 (for example 1250), and a deeper path |
| What the Foreground slider changes; the list below it; Fonts and Editor | no control moved | drag the slider; scroll the list; switch segments, in both appearances |
| A saved navigator state restored in a later session | each round opens a fresh copy | collapse and expand groups, close the workspace, reopen it |
| Whether the reference ever fills the image properties | the after still is 1.2 s after the step | a still 5 s after, and after selecting the image a second time |
| Ycode's split latency (row 140) | the recording ended 1.2 s after the press | a 3-second post-roll |
| The issue capsule in a narrow window in light; its order with three kinds | conflict steps only at 1400 | the conflict session at 1100; a project with errors, warnings and notes |
| Row heights in the dark supplement; Settings rows below the first screen | not measured; not scrolled | the dark stills measured; scroll each pane |
| The activity subtitle (row 141) | not visible this round | a still while the workspace prepares its editor services |

## Evidence

| Claim | Level | Source |
|---|---|---|
| Scores and the judges' claims | — | The council's three reports for rounds 1 and 2 (dirty room) |
| Every reference value in the checklist | 3 | The cited spec sections. They are measured from the round-1 1x stills and recordings of the reference with `research/tools/council-r1/measure_captures.py`; the method is in `research/notes/council-r1-2026-11-04.md` |
| Round 2 reference values | 3 | The round 2 1x stills and recordings (foreground, key window), measured with `research/tools/council-r2/measure_r2.py`; method in `research/notes/council-r2-2026-11-04.md` |
| Round 3 reference values | 3 | The round 3 Retina stills and 120 fps recordings of the reference and Ycode (foreground, key window; the merge session, Settings and Device Hub added), measured in the dirty room with colour runs, ink boxes, per-frame column profiles and the capture tool's timing segments; full descriptions in the cited spec sections |
| Round 4 reference values | 3 | The round 4 Retina stills and 120 fps recordings of the reference and Ycode (foreground, key window, dark appearance; Settings ▸ Editing added), measured in the dirty room with glyph-core colour samples, colour runs, ink boxes, per-frame edge tracking and the capture tool's timing segments; full descriptions in the cited spec sections |
| Round 5 reference values | 3 | The round 5 Retina stills and 120 fps recordings of the reference and Ycode (foreground, key window, dark; Settings in light and dark; the conflict session with a 60-point margin below the window), measured in the dirty room with colour runs, ink boxes, per-row ink ends, stem widths and ink areas, per-frame edge positions, region samples and changed regions timed against the session manifests; full descriptions in the cited spec sections |
| Round 6 reference values | 3 | The round 6 Retina stills and 120 fps recordings of the reference and Ycode (foreground, key window, **light**; Ycode's steps 01–08 re-run at the reference's load; Settings in light with a dark supplement; the conflict session with a 60-point margin; the device window), measured in the dirty room with frame-to-still matching for scroll offsets and a spring fit, per-frame edge positions and named-curve fits, rim positions per frame, colour runs, ink boxes and ink clusters, region means per frame, highlight runs, one-point colour samples, and the alert's accessibility tree as recorded by the capture tool; times against the session manifests; full descriptions in the cited spec sections |
| Round 5 accessibility path (row 130) | — | The capture tool's own accessibility driver and session runner (our code), and the round 5 conflict manifests' action results |
| Ycode values | — | The same session's captures of Ycode; `otool -l` of the captured executable |
| EditorConfig lookup | 1 | The EditorConfig specification (editorconfig.org) |
| Scroller style API | 1 | AppKit documentation (`NSScroller.preferredScrollerStyle`, `NSScroller.preferredScrollerStyleDidChangeNotification`) |
