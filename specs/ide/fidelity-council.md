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

## Evidence

| Claim | Level | Source |
|---|---|---|
| Scores and the judges' claims | — | The council's three reports for rounds 1 and 2 (dirty room) |
| Every reference value in the checklist | 3 | The cited spec sections. They are measured from the round-1 1x stills and recordings of the reference with `research/tools/council-r1/measure_captures.py`; the method is in `research/notes/council-r1-2026-11-04.md` |
| Round 2 reference values | 3 | The round 2 1x stills and recordings (foreground, key window), measured with `research/tools/council-r2/measure_r2.py`; method in `research/notes/council-r2-2026-11-04.md` |
| Round 3 reference values | 3 | The round 3 Retina stills and 120 fps recordings of the reference and Ycode (foreground, key window; the merge session, Settings and Device Hub added), measured in the dirty room with colour runs, ink boxes, per-frame column profiles and the capture tool's timing segments; full descriptions in the cited spec sections |
| Round 4 reference values | 3 | The round 4 Retina stills and 120 fps recordings of the reference and Ycode (foreground, key window, dark appearance; Settings ▸ Editing added), measured in the dirty room with glyph-core colour samples, colour runs, ink boxes, per-frame edge tracking and the capture tool's timing segments; full descriptions in the cited spec sections |
| Ycode values | — | The same session's captures of Ycode; `otool -l` of the captured executable |
| EditorConfig lookup | 1 | The EditorConfig specification (editorconfig.org) |
| Scroller style API | 1 | AppKit documentation (`NSScroller.preferredScrollerStyle`, `NSScroller.preferredScrollerStyleDidChangeNotification`) |
