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

## Evidence

| Claim | Level | Source |
|---|---|---|
| Scores and the judges' claims | — | The council's three reports for rounds 1 and 2 (dirty room) |
| Every reference value in the checklist | 3 | The cited spec sections. They are measured from the round-1 1x stills and recordings of the reference with `research/tools/council-r1/measure_captures.py`; the method is in `research/notes/council-r1-2026-11-04.md` |
| Round 2 reference values | 3 | The round 2 1x stills and recordings (foreground, key window), measured with `research/tools/council-r2/measure_r2.py`; method in `research/notes/council-r2-2026-11-04.md` |
| Ycode values | — | The same session's captures of Ycode; `otool -l` of the captured executable |
| EditorConfig lookup | 1 | The EditorConfig specification (editorconfig.org) |
| Scroller style API | 1 | AppKit documentation (`NSScroller.preferredScrollerStyle`, `NSScroller.preferredScrollerStyleDidChangeNotification`) |
