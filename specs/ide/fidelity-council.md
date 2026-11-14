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

## Round 7 (2026-11-08)

**Owner's design rules** (they decide every row below):
1. Where the reference has the element, **match it**.
2. Where Ycode has an element the reference lacks, **design it to the
   platform's human interface guidelines in the OS 26+ Liquid Glass
   language**, with the same anatomy as its neighbours.
3. Ycode's **macOS and Linux IDEs look one to one**: a row's target
   holds for both.

Both apps were captured as in round 6 (Retina, 120 fps, foreground, key
window; the conflict window with a 60-point margin), with Ycode
`0afb3bd7`, but:
- **The system appearance was Dark** (round 6: Light). Main, conflict,
  device, extra and reopen steps are dark in both apps; 20–22 dark;
  23–26 each app's own Appearance set to Light; D02–D05 set to Dark.
- **The host's 1-minute load was 250–700**, about 20 times round 6's
  (other machines' virtual machines and system services). Every
  duration, latency and fitted curve this round is **load-affected**;
  end positions, sizes and colours are reliable. Where a row's target is
  a timing, it rests on round 6's light-load value unless the difference
  is a whole behaviour (a snap against a slide, a stop short of an edge).
- New steps probe round 6's fixes harder: a classic iPhone and an iPad
  at Zoom to Fit in two window sizes (device 06–09), a slow flick and a
  flick to the bottom (X05, X03), the jump bar with a split at 1250 and
  1180 (X07–X09), the Appearance list scrolled (X13), the Foreground
  slider's accessibility (X10–X12), and the workspace closed and
  reopened in a new instance (X15, R01).

### Scores

Means of the three judges; "—" where a step did not exist. Every step
carried over from round 6 improved; **all eleven steps below 8 are new**.

| Step | Opus | Sol | Gemini | Mean | Round 6 | Round 5 | Round 4 |
|---|---|---|---|---|---|---|---|
| 01 select Long.swift | 8.5 | 9.2 | 9.6 | 9.10 | 8.83 | 8.2 | 8.2 |
| 02 editor at rest | 9.0 | 9.2 | 9.8 | 9.33 | 8.83 | 8.5 | 7.6 |
| 03 linear scroll 600 pt | 9.3 | 9.6 | 9.7 | 9.53 | 9.33 | 8.4 | 7.7 |
| 04 momentum flick | 8.0 | 8.9 | 9.4 | 8.77 | 7.80 | 8.2 | 6.9 |
| 05 select Stripes.png | 9.2 | 9.4 | 9.7 | 9.43 | 8.47 | 7.6 | 7.4 |
| 06 open Stripes.png | 9.3 | 9.9 | 9.8 | 9.67 | 9.70 | 9.2 | 9.3 |
| 07 select Bands.swift | 9.2 | 9.4 | 9.8 | 9.47 | 9.03 | 8.1 | 4.8 |
| 08 bands under the bars | 9.2 | 9.6 | 9.7 | 9.50 | 8.87 | 8.3 | 5.2 |
| 10 hide inspector | 8.3 | 9.2 | 9.5 | 9.00 | 8.23 | 7.9 | 6.6 |
| 11 show inspector | 8.8 | 9.3 | 9.5 | 9.20 | 8.37 | 7.8 | 6.5 |
| 12 inspector scroll | 9.0 | 9.6 | 9.8 | 9.47 | 9.27 | 8.4 | 7.5 |
| 13 plain group | 9.0 | 9.2 | 9.7 | 9.30 | 7.83 | 7.9 | 7.7 |
| 14 expand folder | 9.0 | 9.1 | 9.6 | 9.23 | 9.07 | 8.8 | 7.7 |
| 15 navigator scroll | 9.2 | 8.9 | 9.2 | 9.10 | 9.20 | 9.0 | 8.2 |
| 16 split editor | 8.8 | 8.4 | 9.6 | 8.93 | 8.60 | 7.8 | 8.1 |
| 17 narrower window | 8.8 | 8.9 | 9.4 | 9.03 | 8.20 | 7.4 | 6.5 |
| 18 Welcome window | 8.8 | 8.8 | 9.7 | 9.10 | 9.20 | 8.7 | 8.2 |
| X03 flick to the bottom (new) | 6.0 | 7.7 | 8.0 | **7.23** | — | — | — |
| X05 slow flick to the top (new) | 5.0 | 5.8 | 7.0 | **5.93** | — | — | — |
| X07 jump bar, split, 1250 (new) | 6.0 | 7.8 | 8.5 | **7.43** | — | — | — |
| X08 the same, deeper path (new) | 6.5 | 7.2 | 8.2 | **7.30** | — | — | — |
| X09 jump bar, split, 1180 (new) | 8.5 | 9.2 | 9.2 | 8.97 | — | — | — |
| X15 + R01 plain group on reopen (new) | 5.5 | 6.8 | 7.6 | **6.63** | — | — | — |
| 20 Settings ▸ General (dark) | | | | 9.23 | 9.13 (light) | 8.5 | 7.6 |
| 21 Settings ▸ Editing (dark) | | | | 9.47 | 9.30 (light) | 8.7 | 5.6 |
| 22 Settings ▸ Components (dark) | | | | 9.23 | 9.13 (light) | 6.3 | — |
| 23 Appearance (own Appearance Light) | 8.4 | 8.5 | 9.4 | 8.77 | 8.47 | 5.2 | — |
| 24 General (own Light) | | | | 9.23 | 9.17 | 8.1 | — |
| 25 Editing (own Light) | | | | 9.43 | 9.30 | 8.4 | — |
| 26 Components (own Light) | | | | 9.23 | 9.13 | 6.2 | — |
| D02 Appearance (own Dark) | 8.0 | 8.5 | 9.4 | 8.63 | 8.50 | — | — |
| D03 General (own Dark) | | | | 9.23 | 8.97 | 8.5 | 7.6 |
| D04 Editing (own Dark) | | | | 9.47 | 9.13 | 8.7 | 5.6 |
| D05 Components (own Dark) | | | | 9.23 | 9.10 | 6.3 | — |
| X13 Appearance scrolled (new) | 6.0 | 7.2 | 7.4 | **6.87** | — | — | — |
| Conflict 01 Repositories | 9.0 | 9.2 | 9.5 | 9.23 | 8.30 | 8.5 | 7.7 |
| Conflict 02 starting the merge | 8.8 | 9.3 | 9.6 | 9.23 | 9.10 | 7.4 | 7.3 |
| Conflict 03 conflict at rest | 8.0 | 9.4 | 9.1 | 8.83 | 8.83 | 6.2 | 6.8 |
| Conflict 04 Choose Right | 8.8 | 9.0 | 9.6 | 9.13 | 8.40 | 6.3 | 7.3 |
| Device 01 Duo, Home at rest | 7.5 | 8.4 | 8.8 | 8.23 | 7.67 | 7.4 | 6.1 |
| Device 02–05 Duo at Zoom to Fit (new) | | | | 8.67, 8.60, 8.80, 8.77 | — | — | — |
| Device 06 iPhone 17, 1100 (new) | 5.0 | 6.4 | 6.2 | **5.87** | — | — | — |
| Device 07 iPhone 17, 1400 (new) | 4.5 | 6.0 | 6.2 | **5.57** | — | — | — |
| Device 08 iPad, 1100 (new) | 3.0 | 4.8 | 5.0 | **4.27** | — | — | — |
| Device 09 iPad, 1400 (new) | 3.0 | 4.5 | 5.0 | **4.17** | — | — | — |
| **Main steps 01–18 (mean of 17)** | **8.91** | **9.21** | **9.62** | **9.25** | 8.75 | 8.25 | 7.31 |
| **Extra steps (mean of 6, new)** | 6.25 | 7.42 | 8.08 | **7.25** | — | — | — |
| **Area: conflict editor** | **8.6** | **9.2** | **9.4** | **9.07** | 8.67 | 7.00 | 7.20 |
| **Area: Settings** (adds X13 and the slider's accessibility) | **8.2** | **8.9** | **8.9** | **8.67** | 9.00 | 7.33 | 6.47 |
| **Area: device window** (01–09) | **6.1** | **6.9** | **7.3** | **6.77** | 7.67 | 7.40 | 6.10 |
| **Overall** | **7.6** | **8.5** | **8.7** | **8.27** | 8.63 | 7.83 | 6.97 |

The overall, Settings and device means fell only because the new steps
are harder. The Duo steps 02–05 average 8.61; the classic iPhone and the
iPad 4.97. Beta 3's council target is every step's mean at least 8.

### Disputed values, settled by measurement

| Item | Judges | Measured (reference) | Ycode |
|---|---|---|---|
| iPad "about 580 × 820" (Gemini), "535 × 866" (Sol) at 1400 | Gemini, Sol | body **556 × 769**, screen 484.5 × 697 (scale 0.591) at 1400; **485.5 × 671** at 1100 (`device-hub.md` §15.1) | 182 × 380 and 210 × 434 (the iPhone outline) |
| iPhone 17 "about 850 tall" at 1400 (Sol) | Sol | body **371.5 × 772.5** | 210 × 434 |
| Duo "179 × 248 in both" (Opus) | Opus | **274 × 379.5** in both at 1100 (a match) | 273.5 × 379.5 |
| What Zoom to Fit fits | all | the device's **silhouette to 0.98 F − 16** (F = window height − 96) for every device; the Duo through a reserved 1269-dp box (§15.2) | every device at the Duo's height |
| Flick overshoot "improved" (Gemini) against "3.7 times" | Gemini, summary | peak **39** (6.5 %) at this load, round 6 **119** at a light load; Ycode **147** and 199; the return ω ≈ 13.5 in both (`editor-area.md` I.2) | — |
| Slow flick and bottom flick "stop short" | all | the reference follows every momentum event to the edge; Ycode stops after about 277 of 567 (X05) and 245 of 1544 (X03) momentum points (I.1) | 396.5 of 600, 563.5 of 600 |
| "Missing line 845" (Opus) | Opus | the empty line after the final newline, with the current-line highlight #353535; overscroll puts its bottom 2.75 above the text area's middle (I.3) | line 844 last |
| Jump bar at 1250: why Ycode truncates | all | Ycode's project icon advance 20.5 against 19 and file icon advance 20.5 against 18: its path is 5 longer, exactly what its title loses; and it drops a title cut below about 9 points (I.5) | — |
| Step 08 scroller "about 10 lower" (Opus, unchecked) | Opus | knob **100** long (Ycode 115.5); after 1200 points its top at 227.5 (Ycode 247.5): the length differs, not the travel (I.6) | — |
| Inspector Widths "smaller" (Opus, unchecked) | Opus | two **text fields** 64–65 × 21 with 19 × 24 steppers; labels 16.5 and 30 wide (`workspace-window.md` W7.5) | bare numbers and steppers; labels 0.87 the size |
| Traffic lights "grey in Xcode, coloured in Ycode" under the sheet | Opus, summary | **the same in both**: close #4D4D4E grey, minimize #FDC000, zoom #31BF00 (W7.2); what is greyer in the reference is the toolbar's items | close #484949, the others equal |
| Issue badge in conflict 03 "very close" (Sol) | Sol | the reference has a capsule x 813.5–872, a red circle and "1"; Ycode has **none** (W7.2) | — |
| Dark Foreground swatch "about #F7A0C8" | Opus, summary | **#FF9EC4** (also its accessibility value); the track from #DCAAB9 to #FFD4E7 (`settings.md` R7.2) | #EE96BA, the light track |
| Inspector hide "180 ms, 3 frames" | summary | Ycode starts **720 ms** late and makes 99.5 % of the change in **one frame**; the reference slides over about 150 ms in 7 positions (W7.3) | — |
| Add Editor "327 ms highlight" | Sol, Opus | the reference's pressed tint lasts **one frame**; Ycode's fades over about 450–600 ms (W7.4) | — |
| Ycode's missing editor restore: real or the capture? | summary | **real**: Ycode's per-workspace user data has no editor, split or inspector state; the reference restored them despite the same launch flag (W7.1) | — |
| Alert accessibility order "not judged" | summary | the tree was recorded: **order met**; leftovers in row 195 (`merge-sheet.md` §16.1) | — |

### Round 7 rows

Grouped for four implementers with **no shared files**: A owns the
device window (`device-hub.md`); B the source editor, its scrolling, the
jump bar and the merge panes' text (`editor-area.md`); C the Settings
window (`settings.md`); D the window chrome, toolbar, inspector,
navigator, Welcome window, alert and state restoration
(`workspace-window.md`, `navigators.md`, `merge-sheet.md`). B's jump-bar
rule (row 180) leaves D's issue stepper (row 161, a fixed trailing part)
alone; D's toolbar capsule (row 188) is in the toolbar, not in B's jump
bar.

**A. Device window** (`device-hub.md` §15; the device canvas and
toolbar code)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 170 | Zoom to Fit for every device (supersedes row 154's interim rule) | the silhouette (body plus buttons on the top or bottom edge) **S = 0.98 F − 16**, F = window height − 96 (a margin of 8 + 1 % of F above and below); scale = S ÷ its height in device points; centred between y 52 and H − 44 and in the canvas; the Duo through a 1269-dp box (as now). Checks: iPhone 17 **324.5 × 674.5** at 1100 × 800 and **371.5 × 772.5** at 1400 × 900; iPad Air **485.5 × 671** and **556 × 769**; Duo 274 × 379.5 and 314 × 435. Width cap with the same margin form (a Ycode decision) | every device at the Duo's height: 182 × 380 and 210 × 434 (0.56 of the reference) | §15.1, §15.2 | 3 | Opus, Sol, Gemini | **H** |
| 171 | The iPad's own outline | a tablet body, width **0.724** of its height (940 × 1300 dp), corner about **83 dp**; border: a light line about 2 dp, a #2C2C2C band about 4, black about 51.5: **60 dp** to the screen on every side; screen corner about 18–20 dp; a top button near the right corner standing 4 dp out; two volume buttons flush on the right edge near the top | the iPhone's outline (0.484) | §15.3 | 3 | Opus, Sol, Gemini | **H** |
| 172 | The iPhone 17's border | body corner about 83 dp (a continuous curve); border: light line about 2 dp (#565657–#818182), #2C2C2C about 4, black about 10–11: 18.25 dp to the screen; screen corner about 63.5 dp; buttons: three on the left (from 159.5, 220, 299 dp), one on the right (from 261.5 dp), 4.7 dp out | the right proportion and buttons; one #5E5E5E grey band then black | §15.4 | 3 | meas. | L |
| 173 | Subtitle | the OS name of the device's family: **"iPadOS 27.2"** for the iPad (iOS for iPhones; watchOS, tvOS, visionOS likewise) | "iOS 27.2" | §15.5 | 3 | Opus, Sol | L |
| 174 | Toolbar glyphs and states | layout glyph: an outline rounded rectangle with a top bar and a right-side panel, dimmed, no separator before it; fit glyph's arrows on the rising diagonal, pointing in; with the inspector hidden, no item selected and two separators | a filled grey rectangle after a separator; arrows on the falling diagonal; the settings item still selected | §15.5 | 3 | Opus, Sol | L |
| 175 | Bottom capsules | glyphs **#FFFFFF** whenever the device is shown (a disabled state only for a control that cannot act, with its reason in the tooltip, rule 2); Home a grid of rounded squares; Rotate a square with two hooked corner arrows; the Duo's open posture a flat panel with curved edges | #9E9E9E; circles; circling arrows; an open book | §15.6 | 3 | Opus, Sol | L |

**B. Editor scrolling, text and the jump bar** (`editor-area.md` I.1–I.6;
the scroll view, text layout, gutter and jump-bar code; the merge panes
use the same text view)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 176 | Momentum to the edge | apply **every momentum-phase delta** one to one until the momentum ends or an edge is reached (no timer or speed floor of Ycode's own); on Linux, momentum from the release speed decaying with τ about 0.33 s. X05 (1800 points per second, 686.7 points delivered): reach the top, arriving at about 330 points per second with a 3-point stretch; X03: reach the bottom | X05 stops at **396.5** of 600 (coasting cut short after about 400 ms); X03 stops at **563.5** of 600 | I.1 | 3 | Opus, Sol, Gemini | **H** |
| 177 | Stretch past the edge (supersedes row 157's stretch) | grows with the momentum left at the edge, more slowly than Ycode's: about **120** for main 04's input at a light load, about **40** at this load (39 top, 41 bottom), a few points for a slow arrival; return x = A (1 + ω t) e^(−ω t), ω ≈ 13.5 (met) | **147** at this load (24.5 %), 199 in round 6 | I.2 | 3 | Opus, Sol | M |
| 178 | The final empty line | a document ending in a line break has an **empty last line**: numbered, able to hold the insertion point (⌘↓), drawn with the current-line highlight (#353535 dark); its row's bottom can rise to the text area's middle (within 3 points); in the source editor and **both merge panes** (Greeting.swift: line 19) | 845 and 19 missing | I.3 | 3 | Opus, meas. | M |
| 179 | Inactive pane across a re-wrap | keep the **first visible logical line** (and the fraction of its first row) at the top of every pane when its text re-wraps (split, resize, font); redraw the gutter in the same frame | the top line jumps (line 9 → 26 → 20); the gutter stale (20, 16, 27 over 21 …) | I.4 | 3 | Opus | M |
| 180 | Jump bar's title priorities at 1250 and 1180 (refines row 144) | icon slots the reference's widths (project **13**, group 12.5, file **11.5**, each then 6–6.5 to its title; advances 19 and 18); collapse order: groups' titles → project title cut with a fade **down to about 9 points** → project icon only → file title cut → last item whole; active-pane chevrons 3 wide. X07: "GlassScroll" whole in both panes; X08: "Gl" kept; X09: "Glass…" 23.5 wide; 1100 unchanged | project icon 14.5, file icon 15 (path 5 longer): "GlassScrol", "GlassScro", icon only in X08, "Glas" at 1180; chevrons 2 wide | I.5 | 3 | Opus, Sol, Gemini | M |
| 181 | Scroller knob length | the track times the visible height over the full scrollable height, the final line and the overscroll included: **100** for Bands.swift in step 08 | 115.5: its top 20 lower after the 1200-point scroll | I.6 | 3 | Opus, meas. | L |

**C. Settings ▸ Appearance** (`settings.md` R7.1–R7.4; the Settings
window code)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 182 | The Theme list below the first screen | cards with 10-point gaps: [Theme, Name] [**Foreground** (slider row, 56), **Background** (slider row, 56: knob at the left in the background colour, blue track to its right, button #484748), **Background Gradient** (switch 36 × 16, on; row 36.5)] [**Customize All Colors** (switch, off; 36.5)] [**Plain Text**] [**Comments, Documentation Comments, Keywords**, …]; colour-only rows **47 + 1** with a **48 × 24** colour button centred at x 632–680; labels 13 below each row's top; Ycode's extra rows after Keywords until the reference's order is captured; the note and Theme File buttons last | every syntax row a 56 slider row with a 48 × 28 well; no Background, Background Gradient, Customize All Colors or Plain Text rows; Strings and Numbers before Keywords | R7.1 | 3 | Opus, Sol, Gemini | M |
| 183 | Foreground row in dark (completes row 149) | track from a muted tone (#DCAAB9, #DD9FB3) to a **pale tint #FFD4E7**; knob and button at **#FF9EC4** (the default theme); light unchanged (met) | the light row in dark: pale #F7D2E3 → deep #E35691, #EE96BA | R7.2 | 3 | Opus | M |
| 184 | Foreground slider's accessibility | an element for the slider, frame **202.5 × 36** at x 421.5, y 401.5 (the track plus 11 above and below), between the label and the colour control; role **slider** (rule 2: the reference's has role unknown and no value), titled by the row's label, value a percentage, increment and decrement actions; the colour control a **button** whose value is the colour; the same for Background; the switches as switches | only a colour well "Foreground", value "System", 50 × 30 | R7.3 | 3 | Opus, Sol, Gemini | M |
| 185 | Appearance thumbnails | a close-up of a window's top-left corner: large traffic lights (about 6 across, 10 apart) at about **59 %** of the 61-point height, the window's top edge at about 40 %, a translucent panel above and a thin bar at the top (Ycode's own artwork) | a small whole window with tiny traffic lights at its top left | R7.4 | 3 | Opus | L |

**D. Window chrome, toolbar, inspector, navigator and state**
(`workspace-window.md` W7.1–W7.6, `navigators.md` round 7,
`merge-sheet.md` §16; the workspace window, toolbar, inspector,
navigator, Welcome, alert and user-state code)

| # | Area | Target (reference) | Ycode now | Spec | Level | Raised by | Impact |
|---|---|---|---|---|---|---|---|
| 186 | Restore on reopen: editors, split, inspector | keep in the per-workspace user data each pane's document, scroll position and selection, the split's direction and proportions, the active pane, the inspector's visibility and tab; restore them on open whatever the system's window restoration does; the title follows the active pane ("GlassScroll — Model01.swift") | **nothing restored** ("No Selection", no split, "Not Applicable"): `WorkspaceUserState` has no such fields — a real gap, not the capture | W7.1 | 3 | Opus, Sol, Gemini | **H** |
| 187 | Navigator expansion on reopen | restore the saved expansion of the project row and the main group's direct children (Plain expanded); rows deeper than that open **collapsed** (Sub) | Sub restored expanded | navigators.md §4 | 3 | Opus, Sol, Gemini | M |
| 188 | Issue capsule while the merge sheet is up (completes row 161) | the capsule whenever the workspace has issues, the merge included: x 813.5–872 here, 7.5 after the scheme capsule, the red circle and "1", dimmed with the toolbar under the sheet | none (the jump-bar stepper is present) | W7.2 | 3 | Opus, Gemini, meas. | M |
| 189 | Activity subtitle (completes row 141) | while the workspace indexes or prepares its services, a second line under the title (reference: ink y 29.5–40 under the title at 14.5–26.5, from x 411.5), Ycode's own words | the title alone, centred | W7.2 | 3 | meas. | L |
| 190 | Inspector hide under load (restates row 158 for hide) | H.2's slide (about 195 ms, ease-out) timed from the **first drawn frame** (or run by the window server), so a late start still plays it: the reference slid over about 150 ms in 7 positions at this load | a 720 ms late start, then 99.5 % in one frame | W7.3 | 3 | Opus, Sol | M |
| 191 | Add Editor press (restates row 164) | the pressed tint for **one frame**, then straight back to within 1.5 of the menu-open level, settling over about 200 ms | the tint held about 70 ms, then a 450–600 ms fade | W7.4 | 3 | Opus, Sol | L |
| 192 | Navigator glyph sets (restates row 166 for the navigator) | Swift rows: a **filled** glyph about **14.5 × 12.5**, #FFA54D (Ycode's own shape, never the trademark); project row a filled blue tile with Ycode's mark; selector bar 2, 7, 8, 9 as: a rounded square with a cross mark, a spray can with dots, a pointed horizontal tag, a tall page with a zigzag foot | outline code glyph 14 × 9 #ECA52A; outline folder with a gear; branch, gauge, tilted tag, landscape list | navigators.md §5 | 3 | Opus, Sol | L |
| 193 | File inspector Widths | two **text fields** (64 × 21, 65 × 21) each with a 19 × 24 stepper; "Tab" and "Indent" at the inspector's label size centred under their fields | bare numbers with 19 × 22 steppers; labels 0.87 the size | W7.5 | 3 | Opus, meas. | L |
| 194 | Welcome recent row | title and path at the reference's sizes and x (text 48.5 from the row's left; path about 4.9 points per character, #B3CEF1 on the selection) so the path fits whole; when a path does not fit, cut in the **middle** (not observed in the reference; the platform's convention); Ycode's own project icon in the row (owner's attention: the system's icon is the reference's artwork) | the path cut at its start ("…ate/tmp/…"), its font about 9 % larger, text 6 to the right | W7.6 | 3 | Opus | L |
| 195 | Alert's accessibility children (completes row 168) | a leading image with no description, 18 × 18; the icon 66 × 66; message 296 × 34, informative text 296 × 30 (sheet 132); no description on the sheet or the buttons | order met; no leading image; icon 57; texts 36 and 32; descriptions on the sheet and buttons | merge-sheet.md §16.1 | 3 | meas. | L |

**Top 10 rows by impact:** 170 (Zoom to Fit for every device); 171 (the
iPad's outline); 176 (momentum to the edge); 186 (restore on reopen);
182 (the Appearance list); 180 (jump-bar priorities); 178 (the final
empty line); 177 (the stretch); 184 (the slider's accessibility); 188
(the issue capsule under the sheet).

### Round 6 rows now met

From this round's stills, recordings and the judges:
- **Met:** 142 (step 17's wrapping matches line for line), 144 at 1100
  and 1180 (not at 1250: row 180), 150 (Choose… a rounded rectangle),
  152 (the Components subtitle), 160 (the navigator at first open), 162
  (the image inspector's "--"), 168's order (the leftovers: row 195),
  169's resolved path (the truncation: row 194), and row 154 **for the
  Duo** (274 × 379.5 in both; the other devices: rows 170–171).
- **Partly:** 149 (light met, dark row 183), 157 (the return met; the
  stretch row 177; the new edge cases row 176), 161 (the stepper met; the
  toolbar capsule under the sheet row 188), 165 (one judge still sees a
  different filter symbol).
- **Open:** 158 for hide (row 190), 164 (row 191), 166 (row 192 for the
  navigator; the toolbar items stay row 166).
- **Not raised or not measurable this round:** 143, 145, 146, 147, 148
  (the round was dark), 151, 153, 155, 156 (the band and the glyph are in
  rows 172 and 174), 159 (the narrowing's timing under this load), 163,
  167.

### Not settled by round 7

| Item | Why not | Capture needed |
|---|---|---|
| The issue capsule in a narrow window (N02) | neither app had an issue at that point | conflict step 01 at 1100 with the merged file's error, or a project with live issues |
| What the Duo's 1269-dp box is; whether the width ever limits the fit | no posture pressed; no width-limited case | the Duo's open posture at Zoom to Fit; a landscape iPad; an iPad in 1100 × 800 with the inspector shown |
| The stretch's law at the edge | two loads, one input each | main 04 and X03 at a light load, and a medium-speed flick |
| Mid-file top-line preservation in the reference | the reference's pane was at line 1 | scroll the left pane to about line 50, then split and resize |
| The reference's Appearance rows after Keywords; what Background Gradient, Customize All Colors and the Foreground slider change | the scroll ended at Keywords; nothing was pressed or dragged | scroll about 900 points; press each switch and drag the slider in a duplicated theme |
| Whether the reference drops nested expansions on reopen, or only ones set through accessibility | the only nested row was set through accessibility | expand a nested group by a real click, close, reopen |
| Where the reference cuts a long Welcome path | the path fitted | a project in a folder with a long path |
| Every timing this round | load 250–700 | the timed steps again at a light load before beta 3's council |


## Round 8 (2026-11-08)

The owner's design rules apply as in earlier rounds: where Xcode has the
element, match it; where Ycode has an element Xcode lacks, design it to
Apple's HIG in the OS 26+ Liquid Glass language; Ycode's macOS and Linux
IDEs look one to one. The project navigator's language logos are the
owner's deliberate choice (2026-11-08) and are not scored against fidelity.

Conditions: 1x display at 100 fps (round 7: 2x, 120 fps), system
appearance dark, **host load 4–10 for every timed session** (round 7:
250–700), so this round's timing values replace round 7's. Ycode at
`57c5ec0f`.

### Scores

| | Claude | GPT Sol | Gemini | Mean |
|---|---|---|---|---|
| Overall (R5 → R6 → R7 → R8) | 7.3 → 8.3 → 7.6 → **8.4** | 7.7 → 8.7 → 8.5 → **9.0** | 8.5 → 8.9 → 8.7 → **9.0** | 7.83 → 8.63 → 8.27 → **8.80** |
| Main steps 01–18 | 8.88 | 9.18 | 9.33 | 9.13 |
| Extra steps (X03–X09, X15 + R01) | 7.97 | 8.90 | 8.93 | 8.60 |
| Conflict editor (with N02) | 8.6 | 8.9 | 9.0 | 8.83 |
| Settings | 9.1 | 9.4 | 9.3 | 9.27 |
| Device window | 7.9 | 8.2 | 8.2 | 8.10 |
| Navigator icon stills (new) | 7.70 | 8.40 | 8.15 | 8.08 |

Steps below 8: the iPad at both window sizes (4.50, 4.47), the navigator
in light after an appearance switch (I04, 7.07), the narrow issue
indicator (N02, 7.37) and the inspector hide (main 10, 7.87). The slow
flick (X05) is at 8.00. Round 7's weak steps recovered: the classic
iPhone 8.90–9.10, the scrolled Appearance list 9.17, restore on reopen
9.20.

### Round 8 rows

Two groups with no shared files: A the window chrome, toolbar, navigator,
device family and state restoration; B motion (the inspector slide,
scroll momentum and stretch, resize and selection latency).

| # | Finding | Reference | Ycode now | Target | Spec | Level | Judges | Severity |
|---|---|---|---|---|---|---|---|---|
| 196 | iPad drawn as a phone, "iOS" subtitle (rows 171, 173) | the iPad Air's own wide body, 556 × 769 at 1400 × 900, 486 × 671 at 1100 × 800; "iPadOS 27.2" | 380 × 772, a phone outline; "iOS 27.2". Cause found after the round: a device of a type Ycode has no frame for took its family from the user's device name, matched case-sensitively ("…-ipad" → phone); fixed in `b85a79bc` | the device's family from its type and model, then its name, ignoring case; an iPad of an unknown type drawn with the round 7 tablet outline at Zoom to Fit; "iPadOS" | device-hub.md §15 | 3 | 3 of 3 | H |
| 197 | Selection lost after an appearance switch (I04) | after the app's appearance changes from dark to light, the open file's navigator row stays selected (blue) and the editor keeps the current-line band on the caret's line | no selected row; no current-line band | both kept across any appearance change, on both IDEs | navigators.md, editor-area.md | 3 | 3 of 3 | H |
| 198 | Narrow issue indicator (N02) | at 1100 pt with an error and a warning, the issues collapse to one red error glyph (an octagon with a cross) in **its own round capsule**, about 39 pt wide, between the scheme capsule and the Add Editor capsule | a red circled cross inside one long capsule (about 218 pt) with the scheme, Add Editor and editor options | its own round capsule at that place; the error glyph an octagon with a cross | workspace-window.md W7 | 3 | 3 of 3 | M–H |
| 199 | Scheme capsule icons | the scheme shows the app target's icon; the run destination for the host Mac shows a laptop glyph tinted blue on a laptop host | an empty dashed square; a dark desktop-monitor glyph | the target's app icon (its asset catalog's app icon, else a plain app tile of Ycode's own design); the destination glyph follows the host Mac's form (laptop or desktop) | workspace-window.md | 3 | 3 of 3 | M |
| 200 | Swift files in the jump bar and the merge sheet's file list | the same file icon as the project navigator | a generic code glyph | the navigator's icon (the owner's language logos) wherever a file is listed | navigators.md round 7 §5 | 3 | meas. | L |
| 201 | Activity subtitle on reopen (completes row 189) | "Preparing Editor Functionality" under the title while the editor's language features start after reopening | none | that subtitle while the language service starts for the restored editors; then as row 189 | workspace-window.md W7 | 3 | 2 of 3 | L |
| 202 | Restored pane's scroll offset (completes row 186) | the left pane reopens at its saved scroll position | line 1 | the saved first visible line restored after layout | workspace-window.md W7.1 | 3 | 1 of 3, confirmed | L |
| 203 | Plain-group folder glyph (dark) | about #B0B0B4 | about #6A6A6C | #B0B0B4 in dark | navigators.md | 3 | 1 of 3, confirmed | L |
| 204 | Inspector hide and show (main 10, 11; replaces row 190's timing) | hide 143 ms with 4 changed frames (290 ms in a second run); show 280 ms with 19 changed frames, an even ease-out | hide 431 ms, show 423 ms, 7 changed frames each about 60–70 ms apart | hide within about 150–290 ms, show about 280 ms, every display frame drawn (no frame gap over 20 ms at 60 Hz or more) | workspace-window.md W7 | 3 | 3 of 3 | M |
| 205 | Slow flick (X05; revises row 176) | at light load, the slow flick travels 564 of 600 pt over 788 ms and stops 36 pt short of the top (progress 0.84 at 250 ms) | the full 600 pt in 735 ms with a 3 % stretch (progress 1.0 at about 250 ms) | momentum distance and decay fitted to this curve; reach the edge only when the momentum carries there | editor-area.md I.1 | 3 | 3 of 3 | M |
| 206 | Live resize and selection latency (main 17, 01, 07) | live resize begins 83 ms after the drag; selecting a file changes the editor 384 ms (Long) and 103 ms (Bands) after the click, in one frame | 424 ms; 522 and 159 ms, over two frames (110 ms) | resize under 100 ms; selection within 50 ms of the reference, editor and inspector changing in the same frame | workspace-window.md | 3 | 1–3 of 3 | L–M |
| 207 | Fast flick's stretch at the top (main 04; revises row 177) | read from the strip: the first line about 190 pt below rest near +167 ms | about 90–100 pt near +200 ms | the stretch's depth and timing fitted to this; both reach the top in about 750–770 ms | editor-area.md I.2 | 3 | disputed (strip vs. fit) | L |

### Round 7 rows now met

Rows 170 (Zoom to Fit for every device), 172, 175, 178 (the final empty
line), 182–185 (the Appearance list, the dark Foreground row, the
slider's accessibility, thumbnails), 186–187 (restore on reopen, except
row 202) and 194. Rows 176 and 180 are met as specified but revised by
rows 205 and the live-warning item below. Row 192 is superseded by the
owner's logo decision.

### Round 8 group A implementation (B8-A, 2026-11-08)

- **196:** `DeviceFrameSpec.matching` (the Linux window's frame from a
  stream's hello) takes the family its type or model names, ignoring case,
  before the display size; with `b85a79bc` (the macOS hub's rows) an iPad
  of a type Ycode has no frame for, named in lower case, is the tablet at
  Zoom to Fit (485.8 × 671.9 at 1100 × 800, 556.4 × 769.6 at 1400 × 900)
  under "iPadOS 27.2" on both IDEs (`DeviceHubR8Tests`, `DeviceWindowR8Tests`).
- **197:** a settings change rebuilt the project navigator's rows and lost
  the selection; the rebuild now keeps the selected rows (by project
  object, file or place) and the scroll position. The light current-line
  band names #EEEEEE: the translucent neutral band, returned from the
  default theme's dynamic colour, drew nothing, so light had no band at
  all. The Linux IDE kept both already.
- **198:** short of room the toolbar dropped its fixed spaces and the
  capsules shared one glass shape; the fixed spaces keep a high visibility
  priority. With symbols only the issue capsule holds the most severe
  kind's glyph alone (an error is `xmark.octagon.fill`, OpenViews' drawing
  an octagon), 39 × 36, centred (`IssueSummary.Capsule.collapsedWidth`).
- **199:** `SchemeCapsuleIcons`: the scheme's target (by name, else the
  first application), its `ASSETCATALOG_COMPILER_APPICON_NAME` (default
  AppIcon), the set's largest picture for any appearance, drawn rounded
  (corner 3.4 in a 15-point tile); else `SchemeAppTile`, Ycode's grey
  gradient tile with three bars. This computer's destination is a laptop
  (an internal battery or a MacBook model; on Linux a battery or a
  portable chassis) tinted the system blue, else a desktop. macOS draws
  both in non-vibrant views over the pop-ups' image slots (drawn by the
  cells, the glass toolbar greyed them).
- **200:** the jump bar's file component and the merge sheet's file list
  and path draw the navigator's logo (11.5 points in the jump bar, at 55 %
  in a pane without focus; 14 and 13 in the sheet).
- **201:** `WorkspaceSession.startLanguageService(opening:)`: the
  preparing subtitle (Ycode's own words) stays until the server has
  published diagnostics for every document the window opened with (20 s
  at most); both IDEs open all their editors' files through it.
- **202:** not reproduced offscreen (the restore lands on the saved line in
  every test, the app's launch order included); for 4 s after a restore a
  pane found back at its document's top is scrolled to its saved line
  again, on both IDEs.
- **203:** the plain group's grey is #B0B0B4 in dark, drawn on macOS by an
  image view without vibrancy (the sidebar's vibrancy had darkened
  #999999 to about #6A6A6C).

### Not settled by round 8

| Item | Why not | Capture needed |
|---|---|---|
| The live warning the reference shows on the unbuilt plain project ("1" in the toolbar and a warning mark in each jump bar) | the capture did not open the issue navigator, so the warning's text and source are unknown | open the issue navigator on that project before a build |
| The scroll-edge blur under the Settings tab bar | one judge, not measured | a scrolled Settings pane at 2x |
| The merge alert's size difference | two judges disagree (wider or taller) | alert still at 2x |

## Round 9 (2026-11-13)

The design rules of rounds 7 and 8 still apply: where the reference has
the element, match it; where Ycode has an element the reference lacks,
design it to Apple's HIG in the OS 26+ Liquid Glass language; Ycode's
macOS and Linux IDEs look one to one.

**Owner's rules for this round** (2026-11-13). They replace round 8's
note that the navigator's language logos are not scored:
1. **Navigator file icons.** Each language keeps its official logo, but
   drawn as **single-colour vector line art**: devicon's "plain" or
   "line" variant, pinned at v2.18.0 (MIT). The glyph is tinted per file
   type the way the reference tints its own glyphs (the tint table
   below), sits in the reference's glyph box with the reference's stroke,
   and turns white on a focused selected row. The logos' shapes are not
   scored; box, stroke, tint and selection behaviour are. If v2.18.0 has
   neither variant for a type, that type keeps Ycode's own glyph in the
   same box and tint until the owner decides.
2. **Markdown** gets Ycode's own glyph: an open book in line art (two
   facing pages and a spine, 1.5-point strokes, about 14.5 × 12), in the
   reference's Markdown tint, matching the reference's description without
   its artwork. (Revised by the owner on 2026-11-13; it was the official
   M↓ logo.) The owner's further decisions of the same day: **Swift** is
   devicon's plain variant inverted, the bird alone with no rounded
   square (the reference's filled bird); **Python** is the outline of
   devicon's plain shapes only, 1.5-point strokes, no fill.
3. **JSON** gets Ycode's own glyph: an opening brace, a filled opening
   double quote and a closing brace, in the reference's JSON red. It
   matches the reference's look without its artwork.
4. **The title area's icon** (left of the project name in the toolbar) is
   Ycode's own mark, at the reference's size and spacing. During a build
   it becomes the reference's progress indicator. It is not the
   reference's blue project tile.
5. **The coding assistant button** matches the reference's gradient, size
   and hover as closely as possible, in Ycode's own drawing.

Conditions: every scored session at **2x Retina, 120 fps** (round 8: 1x,
100 fps), so compare this round's stills with rounds 3–7, not round 8;
system appearance dark; **host load 6.6–14.4 for every timed session**
(round 8: 4–10), so the timings compare with round 8's. The Apple Watch
and palette.json extras ran at 1x on a second display. Ycode at
`d221e382` (every round 8 fix). Positions are in window points from the
window's top left, in a 1400 × 880 window unless a row says otherwise;
colours are "light / dark".

### Scores

| Area | Claude R8 → R9 | GPT Sol R8 → R9 | Gemini R8 → R9 | Mean R5 → R6 → R7 → R8 → **R9** |
|---|---|---|---|---|
| Overall | 8.4 → **7.9** | 9.0 → **8.4** | 9.0 → **9.0** | 7.83 → 8.63 → 8.27 → 8.80 → **8.43** |
| Main steps 01–18 | 8.88 → 8.76 | 9.18 → 8.98 | 9.33 → 9.19 | 8.25 → 8.75 → 9.25 → 9.13 → **8.98** |
| Extra steps (X03–X09, X15 + R01) | 7.97 → 7.97 | 8.90 → 8.08 | 8.93 → 8.68 | — → — → 7.25 → 8.60 → **8.24** |
| Conflict editor (with N02) | 8.6 → 9.0 | 8.9 → 9.3 | 9.0 → 9.2 | 7.00 → 8.67 → 9.07 → 8.83 → **9.17** |
| Settings | 9.1 → 9.1 | 9.4 → 9.3 | 9.3 → 9.3 | 7.33 → 9.00 → 8.67 → 9.27 → **9.23** |
| Device window (01–09) | 7.9 → 9.0 | 8.2 → 9.2 | 8.2 → 9.1 | 7.40 → 7.67 → 6.77 → 8.10 → **9.10** |
| Navigator icon stills (I02, I04) | 7.70 → 8.40 | 8.40 → 6.55 | 8.15 → 8.90 | — → — → — → 8.08 → **7.95** |
| Owner steps (new) | 4.8 | 5.1 | 7.7 | **5.87** |

The overall mean fell from 8.80 to 8.43, almost entirely because of the
new owner steps; every other area held or improved. All of round 8's
steps below 8 recovered: the iPad 9.10 and 9.30 (round 8: about 4.5), N02
8.83 (7.37), main 10 8.07 (7.87), I04 7.97 (7.07).

Steps below 8 (11):

| Step | Claude / GPT / Gemini | Mean | Rows |
|---|---|---|---|
| W01 watch sidebar and opening zoom | 5.0 / 3.2 / 7.3 | 5.17 | 232, 233, 235 |
| W02 watch fit at 1100 × 800 | 4.5 / 4.0 / 7.2 | 5.23 | 231, 234 |
| W03 watch fit at 1400 × 900 | 4.5 / 4.0 / 7.4 | 5.30 | 231, 234 |
| OG navigator glyphs | 4.5 / 5.5 / 7.7 | 5.90 | 208, 209, 211, 213 |
| OJ JSON | 4.0 / 6.0 / 7.8 | 5.93 | 210, 217, 228–230 |
| OT title icon | 4.5 / 6.3 / 8.2 | 6.33 | 212 |
| OA assistant button | 5.5 / 7.0 / 8.0 | 6.83 | 214 |
| Main 04 fast flick | 7.0 / 6.8 / 8.2 | 7.33 | 220 |
| X05 slow flick | 7.0 / 7.2 / 8.2 | 7.47 | 221 |
| I02 navigator in dark | 8.3 / 6.5 / 9.0 | 7.93 | 208 |
| I04 navigator in light | 8.5 / 6.6 / 8.8 | 7.97 | 208, 209 |

Just above the line: main 10 inspector hide 8.07 (row 223, 224) and X08
8.03 (row 216).

### Round 9 fix groups

Five groups with **no shared files**, so they can run in parallel:

- **A1, icons** (rows 208–213): the line-art glyph renderer, its per-type
  tints and its selection states wherever a file is listed (the
  navigator, the jump bar's file and project components, the merge
  sheet's file list, Open Quickly's result glyph); the JSON glyph; the
  title area's icon and its build indicator; the M↓ colour on a
  selection; the plain-folder and project-row glyphs. A1 owns the
  per-file glyph lookup; Open Quickly's row (A2) only asks it for a
  glyph.
- **A2, toolbar and Open Quickly** (rows 214–219): the assistant button;
  Open Quickly's panel, field, row and breadcrumb; the jump bar's
  collapse order and its "No Selection" component (the layout, not the
  icons); the gap before the toolbar's overflow capsule; the
  source-control segment under the merge sheet.
- **B, motion and editor** (rows 220–227): overscroll and momentum, the
  editor's scroll anchor while the inspector slides, the inspector's
  pacing and the show's start, selection latency, caret restore and
  instance highlighting.
- **C, file types** (rows 228–230): which files go to the Swift language
  service, and the File inspector's Type pop-up and resource sections.
- **D, Device Hub's watch** (rows 231–235): Zoom to Fit, the opening zoom,
  the sidebar's scroll, the control capsule and the "Available" header.

### Navigator glyph tints (A1; the reference, measured at 2x)

Flat ink, or the core of thin strokes. Rows are 22 pt apart; a file
glyph at depth 2 spans x 55.5–70 in a box of about **14.5 × 12–12.5 pt**,
centred on its row; the name starts at x 76, about 6 pt after the glyph;
each depth adds 14 pt. Line-art glyphs have **1.5 pt strokes** (a 3-pixel
core at 2x); the Swift glyph, folders and the project glyph are filled.

| Type (test file) | Light | Dark | The reference's glyph | Ycode now |
|---|---|---|---|---|
| Swift (Bands, Zeta) | #F77640 | #FFA54D | a filled bird | a full-colour logo tile, 16 × 15 |
| Python (convert.py) | #EFBD00 | #FFF62A | the two-snake logo, line art | a full-colour logo, 13 × 13 |
| Markdown (NOTES.md) | #52788D | #CCEAFF | an open book, line art | the M↓ badge, 16 × 10, black in light |
| JSON (palette.json) | #EE2C22 | #FF695E | braces round a filled opening quote, **16.5 × 12** | a grey shaded ring, 16 × 16 |
| Image (Stripes.png) | #006BEF | #2DA7FF | a framed picture, line art | Ycode's picture glyph (not re-measured) |
| Folder, synchronized group (GlassScroll, Models) | #3FA1F6 | #5BC6FF | a filled folder, 14.5 × 12 | 13 × 10.5, #74A2EF / #6ABDFF |
| Folder, plain group (Plain, Sub) | #7B7B80 | #B6B7BC | a filled folder, 14.5 × 12 | 13 × 10.5 grey (round 8 fix: #B0B0B4 in dark) |
| Project (GlassScroll) | #006BEF | #2DA7FF | a filled tile, **15 × 15** at x 27–42 | the small Ycode mark |
| Asset catalog and other types | unmeasured | unmeasured | not in the test project | — |

Jump bar (the same glyph, smaller): Markdown 12 × 10.5 pt, **#5A8095 /
#B7D5EB**; JSON about 11 × 9 pt (measured at 1x); the project component
about 13 pt and a folder about 12.5 pt wide.

| Selected row | Light | Dark | Ycode now |
|---|---|---|---|
| Focused (the navigator has focus) | glyph **#FFFFFF** on row #0070F5 | glyph **#FFFFFF** on row #007AFF | logos keep full colour; M↓ black on blue in light |
| Unfocused (after a click in the editor; Long.swift) | the type tint, slightly shifted: Swift **#EC6D38** on row #D7D7D8 | Swift **#FFB75F** on row #454647 | logos keep full colour |
| Open Quickly's selected result | glyph #FFFFFF on #0064E1 | glyph #FFFFFF on #0059D1 | a grey generic document glyph on a grey row |

Other types on an unfocused selected row: unmeasured (only Long.swift was
selected); keep each type's tint.

### Assistant button (A2; the reference, measured at 2x and from 8x crops)

Both apps: a circular glass button 36 pt across (y 8–44) holding an
outlined speech bubble with a plus.

| Item | Reference | Ycode now |
|---|---|---|
| Bubble | outline 18 × 17 pt; stroke about 1.25–1.5 pt; a tail at the lower left | 16 × 15 pt |
| Plus | about 8 pt across, arms about 1.25 pt; median **#E3828D / #DF7C80** (coral). In light it shades from about #F46E5A at its top arm to about #BF8EA8 at its bottom arm, consistent with the same angular gradient painted over the whole glyph | #C658C9 / #C158C8 |
| Gradient kind | **angular (conic)**, centred on the bubble, running **clockwise** round the outline | linear, left to right, magenta to violet |
| Capsule at rest | **#FBFBFB / #454545** | #FCFCFC / #434343 |
| Hover (pointer resting 1.5 s) | light: capsule **#FBFBFB → #F2F2F2**, glyph unchanged; dark: no measurable change | no change in either appearance |
| Pressed | not captured (a click opens the assistant's account UI) | — |

Gradient stops, angles clockwise from the top (12 o'clock), median
colour of each sector, light / dark:

| Angle | Light | Dark | Ycode now (light / dark) |
|---|---|---|---|
| 0° (top) | #FD6848 | #FD6043 | #D357BB / #D157BA |
| 45° | #FC5168 | #FB4A53 | #C458CE / #C158C9 |
| 90° (right) | #F27CCA | #F070BB | #AF59DA / #AD59D9 |
| 135° | #BE99EF | #BE96EE | — |
| 180° (bottom) | #80AADC | #78A5D7 | — |
| 225° (the tail) | #6FB1D6 | #6AAED1 | — |
| 270° (left) | #E5956F | #DF8F5E | #D657BD / #D357B8 |
| 315° | #FD8039 | #F97533 | #E057B1 / #DD56B0 |
| 360° | back to the 0° colour | | |

So the outline runs red-pink at the top, magenta and violet down the
right, blue at the bottom and the tail, tan up the left and orange at the
top left.

### Round 9 rows

Spec sections named "§" are in the file given; "this section" means the
tables above.

#### A1, icons

| # | Finding | Reference | Ycode now | Target | Spec | Level | Judges | Severity |
|---|---|---|---|---|---|---|---|---|
| 208 | Navigator file glyphs (OG, I02, I04) | single-colour glyphs tinted per type (tint table), box about 14.5 × 12–12.5, line-art strokes 1.5 pt; white on a focused selected row; the type tint on an unfocused one | full-colour logos (Swift 16 × 15, Python 13 × 13), unchanged on a selected row | the owner's rule 1: devicon v2.18.0 plain or line variants as single-colour vectors, in the reference's box, stroke and tints; white on a focused selection, the tint on an unfocused one; on both IDEs | navigators.md round 7 §5, §6; this section | 3 | 3 of 3 | H |
| 209 | M↓ on a selected row (OG, I04) | the Markdown glyph white on the blue focused row | the M↓ badge stays black on #0070F5 in light | the owner's rule 2: M↓ as line art in #52788D / #CCEAFF, white on a focused selection, the tint on an unfocused one | navigators.md round 7 §5; this section | 3 | 3 of 3 | M |
| 210 | JSON glyph (OJ) | an opening brace, a filled opening double quote (two solid "6"-shaped commas side by side, each about 3 × 2.5 pt) and a closing brace; **16.5 × 12** (x 54.5–71 at depth 2, row centre y 297 in that capture), brace stroke 1.5 pt; #EE2C22 / #FF695E, white when focused; in the jump bar the same glyph about 11 × 9 | a grey shaded ring, 16 × 16, in the navigator and the jump bar | the owner's rule 3: Ycode's own drawing of that description, at those sizes and colours, in every place a file is listed | navigators.md round 7 §5; this section | 3 | 3 of 3 | M |
| 211 | File glyphs outside the navigator (OG, OJ; completes row 200) | the navigator's glyph and tint in the jump bar (Markdown 12 × 10.5, #5A8095 / #B7D5EB), and in Open Quickly's result row (24.5 × 20.5 pt, white on the blue row) | logos in the jump bar and merge sheet (row 200); M↓ in the jump bar; a generic document glyph in Open Quickly | A1's line-art glyph wherever a file is listed: the jump bar's file component, the merge sheet's file list and path, Open Quickly's result row (white on its selected row) | navigators.md round 7 §5; reference-ui-5.md §6.1; open-quickly.md | 3 | 3 of 3 | L–M |
| 212 | Title area icon (OT) | a 19.5 × 19.5 tile at x 383.5–403, y 16–35.5; its centre on the title's line (title cap height y 21–31, both centres at y ≈ 25.8); **8 pt** before the title's first letter; the same for every project and appearance. **While a build runs** it is replaced by a progress ring of about 18.5 pt diameter on the same centre: track #E6E6E6, arc #007AFF, stroke about 2.5 pt (light; dark not captured) | a blue folder-with-gear glyph, 16 × 11 at x 386–402, **10 pt** before the title | the owner's rule 4: **Ycode's own mark** in a 19.5 × 19.5 box, centred on the title's line, 8 pt before the title; during a build the reference's ring (sizes and light colours above; dark: the system's track and accent colours) in its place, the mark back when the build ends | reference-ui-5.md §4.3; workspace-window.md W7 | 3 | 3 of 3 | M |
| 213 | Folder and project-row glyphs (revises row 203) | filled folders 14.5 × 12: synchronized #3FA1F6 / #5BC6FF, plain #7B7B80 / #B6B7BC; the project row's glyph 15 × 15 at x 27–42, #006BEF / #2DA7FF | 13 × 10.5; blue #74A2EF / #6ABDFF; plain #B0B0B4 in dark (row 203's fix); the project row the small Ycode mark | folders at the reference's box and tints, white on a focused selection; the project row keeps the small Ycode mark (owner's decision of 2026-11-08) in a 15 × 15 box at x 27–42 | navigators.md round 7 §5; this section | 3 | 1 of 3 (project row), meas. | L–M |

#### A2, toolbar and Open Quickly

| # | Finding | Reference | Ycode now | Target | Spec | Level | Judges | Severity |
|---|---|---|---|---|---|---|---|---|
| 214 | Coding assistant button (OA) | the assistant-button table: bubble 18 × 17, angular gradient (stops above), coral plus; capsule #FBFBFB / #454545, hover #F2F2F2 in light | 16 × 15, linear #D657BD → #AF59DA; no hover | the owner's rule 5: Ycode's own bubble-and-plus drawing at 18 × 17 in the 36 pt glass circle, an angular gradient with those stops over the whole glyph, clockwise from the top; the light hover to #F2F2F2 (no change in dark); pressed state Ycode's own (HIG), as the reference's was not captured | reference-ui-5.md §4.3; coding-assistant.md §4; this section | 3 | 3 of 3 | M |
| 215 | Open Quickly panel (owner 06, 12) | panel **640** wide (x 380–1020), top at y 200, tall enough for its results (130 pt for one). Field: **no border, focus ring or clear button**; a 21 × 21 magnifier (#7D7D7D light) 21.5 from the panel's left; the query at x 446.5 (cap height 16.5, about 22 pt type, #262626 light); a 1 pt separator (#E4E4E4 / #525252) 54 below the panel top, inset 20 each side. Result row: **620 × 56**, inset 10 at the sides and 10 below the separator, corner radius about 22, **#0064E1 / #0059D1** when selected; glyph 24.5 × 20.5 at x 403, white; the name at x 446 (aligned with the query), white, its extension dimmed (#BFD8F8 in light); under it a 12 × 12 project glyph and **"GlassScroll ⟩ GlassScroll"** (the project and group path), white | panel top at y 158 and taller than its results; a 30 pt bordered field with a blue focus ring (#81B2F7 light) and a clear button; a grey row (#DDDCDC in light), 34 tall; a generic document glyph; the full file-system path; the extension not dimmed | the reference's panel, field, separator, row, colours and two-line content; the breadcrumb is the project's glyph (Ycode's mark) and the group path; the row glyph from A1 | open-quickly.md | 3 | 3 of 3 | M |
| 216 | Jump bar collapse order with a split (X07–X09) | 1250 pt: the project component becomes its glyph and "G" (tail fade), a group its glyph only; file names and "No Selection" whole. 1250, deep path: project and groups glyph only, the file "M", "No Selection" whole. 1180: the left pane's file its glyph only, "No Selection" whole; the right pane's "No Sele…" (tail fade). The issue stepper stays | keeps "GlassScroll" and "Model01" whole at 1250; at 1180 shows "Glas", "Long", "Moc" | collapse from the leading end: project and group names first (to an initial, then the glyph), then the file name (initial, then glyph), the last component last; text cut with a tail fade, not an ellipsis; at the same window widths | editor-area.md I.5, H.4; reference-ui-5.md §6.1 | 3 | 3 of 3 | L–M |
| 217 | "No Selection" for files without symbols (OJ, owner 05, 11) | after NOTES or palette: a chevron 7 pt after the name (3 pt wide, #808080 light, #DEDEDE dark), then "No Selection" 8.5 pt after it, in the components' text style (#272727 / #DEDEDE) | the path ends at the file name | the trailing "No Selection" component for every document with no symbol at the caret, Markdown and JSON included | source-editor.md §Jump bar; reference-ui-5.md §6.1 | 3 | 3 of 3 | M |
| 218 | Gap before the overflow capsule at 1100 pt (N02; completes row 198) | about **5 pt** between the Add Editor capsule and the ">>" capsule | about **29 pt** | 5 pt, the same fixed space as between the other capsules | workspace-window.md W7; editor-area.md H.8 | 3 | 1 of 3, confirmed | L |
| 219 | Source Control segment under the merge sheet (conflict 03) | the selected segment ("Hierarchical") dims to **#335273 with white text** (dark) | **#1E3C60 with blue text (#0B84FF)** | under a sheet, the selected segment as the reference: a dimmed fill with white text | merge-sheet.md §13.1; workspace-window.md W7.2 | 3 | 1 of 3 (claimed for the alert), meas. under the sheet | L |

The summary's note that Ycode's **close button is red under the merge
sheet** is not borne out: in conflict 03 both close buttons are grey
(#4F5051 in the reference, #4A4B4C in Ycode, sampled in the comparison
sheet), as W7.2 requires. No row; nothing to change.

#### Round 9 group A2 implementation (B9-A2, 2026-11-13)

- **214:** `AssistantButtonGlyph` (shared): Ycode's own bubble outline,
  18 × 17 with the tail at the lower left (stroke 1.4), and a plus 8
  across (arms 1.25) on the bubble body's centre, which is also the
  gradient's centre; one angular gradient clockwise from the top through
  the eight measured stops, linear between them, over the whole glyph.
  macOS (`AssistantToolbarButton`, a 36-point view the toolbar wraps in
  its glass circle) paints it as one wedge per degree clipped to the
  stroked outline and plus; Linux (`AssistantCircleButton`) strokes the
  same path with a conic gradient from −90°. Measured: ink 18 × 17 on
  both; outline samples within 5 levels of the stops (macOS top #FD6549,
  right #EE7CCB, left #E89166 in light). Hover: light #FBFBFB → #F2F2F2
  (macOS an overlay of black at 0.036 on the system's glass; Linux the
  fill), dark #454545 unchanged, on both. Pressed is Ycode's own: black at
  0.08 / 0.12 over the capsule.
- **215:** `OpenQuicklyLayout` (shared) and a new Linux panel
  (`OpenQuicklyPanel`, File ▸ Open Quickly… ⇧⌘O through
  `ShellOpenQuicklyModel`; the Linux IDE had none). 640 wide, its top
  200 below the window's (macOS: `GlassPanel.show(over:top:)`, and it
  keeps its top as it follows its results); the field's band 54 with a
  21-point magnifier at 21.5 and a 22-point query whose ink starts at
  66.5, no border, focus ring or clear button; a separator 1 point at 54,
  inset 20 (#E4E4E4 / #525252); rows 620 × 56 from 64, radius 22,
  #0064E1 / #0059D1 selected; 130 tall for one result, the band alone
  for an empty query, at most 8 rows before the list scrolls (Ycode's
  choice). The glyph's box 24.5 × 20.5 at 13 in the row; the name at 66
  (15 points, medium), its extension white at 0.75 on the selection
  (#BFD8F8 on #0064E1); under it the 12-point project mark and the group
  path ("GlassScroll › GlassScroll", `FuzzyMatch.Candidate.groupPath`).
  The panel's corners are concentric with the rows (32). The row glyph is
  the navigator's (group A1 draws it).
- **216:** `JumpBarPathLayout.Part.initial`: a title is cut down to its
  first letter and 2.5 points of fade, then goes (round 7's 9 points
  when no initial is known); the order is unchanged (groups, then the
  project, then the file, the last item last). With a warning (the
  stepper) Ycode now reproduces round 9's states: 1250, left pane
  "G…" (17 points), the group's icon, "Long" and "No Selection" whole;
  right pane all icons and "M…"; 1180, left pane "L…" (12), right pane
  all icons. The round 9 reference showed the stepper (a live warning on
  the project, not settled); Ycode's capture had none, which is why it
  kept "GlassScroll" whole there.
- **217:** a document without symbols (Markdown, JSON, text) ends its
  path with "No Selection" on macOS (`updateSymbolComponent`); the Linux
  IDE already did. The active pane's chevron is #808080 / #DEDEDE and
  takes its extra point from the gap after it: name, 7, chevron (3),
  8.5, "No Selection" on both.
- **218:** Linux: 5 points (`WorkspaceChrome.overflowCapsuleGap`).
  macOS: **not met, 26 points**. Once an item overflows, AppKit keeps the
  flexible spaces at their minimum and leaves the overflowed group's room
  (18 points of viewer at 1100) before its "»" indicator, which sits 7.5
  before the inspector's edge. A spacer item taking that room made AppKit
  squeeze the activity view by 24 points instead, so it was not kept;
  closing this gap needs Ycode's own "»" item in place of the system's
  overflow (and its morph, row 159).
- **219:** `MergeSheetPalette.segmentLabel`: the selected "Hierarchical"
  segment in dark is #335273 with a white label (light keeps #D1E7FF with
  the accent label), on both.

#### B, motion and editor

| # | Finding | Reference | Ycode now | Target | Spec | Level | Judges | Severity |
|---|---|---|---|---|---|---|---|---|
| 220 | Fast flick's stretch at the top (main 04; supersedes row 207) | travels 600 pt to the top; stretches **38 pt** (the first gutter line 134.5 against 96.5 at rest), deepest at **+203 ms**; the return fits a critically damped spring (response about 0.11 s, damping about 1.1), no second bounce; motion +49–734 ms, at rest by **+723 ms** | stretches **150 pt**, deepest at +246 ms; an under-damped return (fit damping about 0.45); at rest by +785 ms | 38 ± 4 pt, deepest near +200 ms, critically damped, at rest by about +730 ms | editor-area.md I.2 | 3 | 3 of 3 | H |
| 221 | Slow flick (X05; supersedes row 205) | travels 600 pt and reaches the top at about +400 ms at low speed; stretches **about 6 pt** (first line 100 against 94), deepest at +466 ms (470–510); motion +58–689 ms; at rest by +811 ms | reaches the top early (about +160 ms) still fast; stretches **49 pt**, deepest at +338–348 ms; at rest by +771 ms | momentum that decays to arrive at the edge near +400 ms with little speed; a stretch that grows with the speed at the edge: about 6 pt here, 38 pt for row 220 | editor-area.md I.1, I.2 | 3 | 3 of 3 | H |
| 222 | Flick to the bottom (X03) | motion starts at +34–45 ms and ends at **+557 ms** (523 ms); passes the end by **about 32 pt** (5 % of the travel) at +210 ms, then settles (spring fit: response about 0.20 s, damping about 0.73); travels exactly 600 pt | starts at +112–133 ms, ends at +867 ms (755 ms); passes the end by about 123 pt (20 %) at +340 ms (damping about 0.52); travels 609 pt; frames about 22 ms apart | start within 50 ms of the input; 32 ± 4 pt past the end; at rest by about +560 ms; exactly the flick's distance; a new frame every display frame | editor-area.md I.1, I.3 | 3 | 2 of 3 | M |
| 223 | **Regression:** hiding the inspector scrolls the editor (main 10; carries into 11, 12, 16, 17) | the text re-wraps continuously during the slide; **line 1 stays at the top** | the re-wrap stalls (progress about 0.31), then lands in one frame at +350–360 ms; the top line becomes **line 6** (about 93 pt, five wrapped lines up), and stays so through the show, the split and the narrow window | while the editor's width changes (inspector, navigator, window resize, split), the first visible character stays at the same y: re-wrap every frame, anchored on the top line | editor-area.md H.2; workspace-window.md W7.3 | 3 | 2 of 3, confirmed | H |
| 224 | Inspector pacing and the show's start (main 10, 11; the rest of row 204) | hide: edge movement +54–272 ms (218 ms), 13 positions, 4 holds over 20 ms (30, 35, 25, 25); show: first changed frame +106 ms, edge movement **+136**–366 ms (230 ms), 14 positions, 4 holds (25–30) | hide 222 ms with 10 positions and 7 holds (23–37); show starts at +25 ms (edge +57 ms), 228 ms, 12 positions, 6 holds (21–28) | durations as now; at least the reference's positions per slide and no more holds over 20 ms (4); the show's slide starting about 136 ms after the click | editor-area.md H.2; workspace-window.md W7.3 | 3 | 3 of 3 | L–M |
| 225 | Selecting Bands (main 07; the rest of row 206) | the editor starts to change at +157 ms and is done by +183–210 ms | one frame at +261–271 ms | done within 50 ms of the reference (by about +200 ms) | editor-area.md G.6 | 3 | 2 of 3 | L |
| 226 | Caret not restored (owner 08, 09) | Long.swift shown again keeps its caret: the status bar reads Line 9, Col 46 | Line 1, Col 1 | each document keeps its selection and scroll position while the window is open; showing it again restores both, and the status bar shows them | editor-area.md §History | 3 | 1 of 3, confirmed | L–M |
| 227 | Every occurrence of a clicked word highlighted (owner 04) | a click on "enough" inside a block comment highlights nothing; the reference highlights instances of the selected **symbol** (default on, after 0.25 s) | all ten lines' "enough" filled with an olive highlight | instance highlighting only for an identifier in code that the language service resolves as a symbol; never for words in comments or strings | source-editor.md §Evidence (the 0.25 s default); reference-ui.md §4 | 3 | 1 of 3, confirmed | L |

#### Group B implementation (B9-B, 2026-11-13)

Details in `editor-area.md` K.1–K.6; both IDEs share the models.

- **220–222:** every momentum delta applies one to one (round 8's gain and
  speed floor removed); the stretch is P(v) = 35 (v ÷ 3970)^0.71; the
  return is critically damped with ω 11.3 at the top and 16.6 at the
  bottom, at rest within half a point. On the documented inputs: main 04
  35.0 at 191 ms, at rest 741 ms; X03 35.0 at 191 ms, at rest 566 ms; X05
  reaches the top at 625 ms at about 400 points a second, 6.0 at 691 ms.
  Not changed: X05's arrival near 400 ms (the documented input cannot
  arrive there slowly), row 222's start latency and frame spacing (not
  reproduced off every display).
- **223:** the top line (line 1 included) is pinned from a slide's or live
  resize's start, restored on every re-wrap and at the end, and for 0.3 s
  after it a scroll the system makes on its own is undone; the visible rows
  re-wrap in every frame.
- **224:** the show's pane opens with its first moving frame (not at the
  press), and the show starts 130 ms after it.
- **225:** not changed; off every display Bands opens in about 77 ms in a
  debug build plus about 20 to draw (K.6).
- **226:** each editor keeps each document's selection and top line while
  the window is open (the Linux IDE already did).
- **227:** `SymbolInstances`: instances only for an identifier in code,
  never words in comments or strings; the Linux IDE now highlights them too.

#### C, file types

| # | Finding | Reference | Ycode now | Target | Spec | Level | Judges | Severity |
|---|---|---|---|---|---|---|---|---|
| 228 | Markdown and JSON sent to the Swift language service (owner 05, 11; owner-json 02, 04) | no diagnostic in the file; the toolbar shows only the project's own warning | a red line-1 diagnostic "Unable to handle compilation, expected exactly…" and an error capsule "1", for NOTES.md **and** palette.json | only documents of a Swift (or C-family) source type go to the language service; Markdown, JSON, property lists, plain text and images never do, and add no diagnostics or issue counts | language.md §Features | 3 | 3 of 3 | H |
| 229 | File inspector's Type (owner 05, 11; owner-json) | "Default - Markdown", "Default - JSON" ("Default - Swift Source" for Swift, "Default - PNG Image" for the image) | "Default - Default" | "Default - " and the type's name, from the file's type (its extension, or the project file's recorded type) | reference-ui-5.md §7; editor-area.md C.6 | 3 | 1 of 3, confirmed | M |
| 230 | Resource sections in the File inspector (owner 05, 11; owner-json) | for a resource (Markdown, JSON, image): On Demand Resource Tags as a "Tags" token field; then a **Localization** section, header ink at x 1148, y 347.5–357 (#878788 light), with a full-width **"Localize…"** button 238.5 × 16 (x 1151–1389.5; #DCDCDD / #424344) between it and Target Membership; Text Settings below for text files. For Swift source: "Only resources are taggable" and no Localization | "Only resources are taggable" for NOTES.md; no Localization section | resource or source decided by the file type; resources get the Tags field and the Localization section as described (the button's action was not captured) | editor-area.md C.6; reference-ui-5.md §7 | 3 | 1 of 3, confirmed; meas. | L–M |

##### Round 9 group C implementation (B9-C, 2026-11-13)

- **228:** `FileTypeRoles.usesLanguageService` (shared by both IDEs):
  only Swift and C-family sources and headers go to the language
  service. `LanguageService.open`, `change` and `save` ignore every other
  file, diagnostics published for one are dropped, and the preparing
  subtitle no longer waits on a restored Markdown or JSON editor. With a
  server that answers every document with a line-1 "Unable to handle
  compilation" error, NOTES.md and palette.json now show no line issue
  and the toolbar's error count stays 0 on both IDEs (before: 1 each);
  Long.swift still goes to the server (`CouncilRound9FileTypeTests`,
  `CouncilRound9FileTypeShellTests`, `CouncilRound9FileTypeUITests`).
- **229:** the Type pop-up's name comes from the file's type: the project
  file's recorded type for a file reference (`explicitFileType`, else
  `lastKnownFileType`), else the extension's (`BuildFileTypes`). NOTES.md
  reads "Default - Markdown", palette.json "Default - JSON"; Swift and PNG
  unchanged.
- **230:** a file is a resource when its type joins a target's resources
  phase (`BuildFileTypes.phase`): Markdown, JSON and images, not sources,
  headers, xcconfig, entitlements or `Info.plist`. A resource gets the
  enabled "Tags" field and the Localization section, straight after the
  tags (an image's stays after Image Properties), with the image's rhythm:
  tags box 22 below the header's ink, Localization's ink 20.5 below the
  box, the button 28 below that ink and 16 tall, Target Membership's ink
  25 below the button. The Localize… button is inset 2.5 from the
  content's edges on both IDEs: macOS x 1149.5–1389.5 (240 wide; was
  1147–1392, 245) against the reference's 1151–1389.5 (238.5). The
  header's ink sits about 2 points left of the reference's x 1148 with
  every other header in the inspector; not changed here.

#### D, Device Hub's watch

Apple Watch Series 12 (46 mm), watchOS 27.2, captured at 1x.

| # | Finding | Reference | Ycode now | Target | Spec | Level | Judges | Severity |
|---|---|---|---|---|---|---|---|---|
| 231 | Zoom to Fit overflows the stage (W02, W03) | the watch, crown included, fits the stage: **about 549 × 638 pt** at 1100 × 800 (inspector shown, sidebar hidden) and **629 × 732 pt** at 1400 × 900 (no inspector); no scroll bars | larger than the stage at both sizes: body about 577 wide (593 with the crown) at 1100 and 664 (681) at 1400, its bottom cut off; scroll bars on both axes | §15.2's rule for the watch: the silhouette, crown and side button included, fitted to the free stage above the control capsule; no scroll bars at Zoom to Fit | device-hub.md §15.2, §4.2 | 3 | 3 of 3 | H |
| 232 | Opening zoom (W01) | a newly created watch opens with the **third** zoom segment (Physical Size) selected: **about 177 × 196 pt** on a 1x display, its real size | the second segment (Zoom to Fit) selected; **about 535 × 624 pt**, filling the stage | a watch shown for the first time opens at Physical Size; later, the window's remembered zoom | device-hub.md §4.2, §14.1 | 3 | 3 of 3 | M |
| 233 | Sidebar does not reveal the selected device (W01) | the selected watch row (203 × 46 pt, x 10–213, fill #434344) is in view | the list is scrolled so the selected row is out of view | selecting a device, or opening the window with one selected, scrolls its row into view | device-hub.md §5.2 | 3 | 3 of 3 | M |
| 234 | The watch's control capsule (W02, W03) | **4 buttons** in one capsule about 143 × 36 pt, about 34 pt apart: two watch hardware controls, then Screenshot and Record | 2 buttons (Screenshot, Record), 75 pt | 4 buttons in that order; the two hardware buttons in Ycode's own drawings for the side button and the Digital Crown (their glyphs and actions were not captured; §10 Q2) | device-hub.md §4.4 | 3 | 1 of 3, confirmed | L–M |
| 235 | "Available" header (W01) | plain text "Available" at x 16, cap height y 110–119, #737374; **no chevron** | at x 26, brighter (#A2A2A3), with a chevron | the reference's header: no chevron, at x 16, in its grey | device-hub.md §5.1 | 3 | 1 of 3, confirmed | L |

### Round 9 group D implementation (B9-D, 2026-11-13)

Clean-room work from the rows above and `device-hub.md` §4.2, §4.4, §5,
§15.2. No Apple binary, Xcode, Device Hub or Simulator was opened, run or
observed.

- **231:** `DeviceFrameGeometry.reservedFitHeight`: a watch is fitted
  through a box `watchFitShare` (0.9475) taller than its silhouette (the
  body, the crown and the side button), as the Duo is through its
  1269-point box; §15.2's rule is otherwise unchanged. The share is the
  mean of the two captures (638 of 673.9 and 732 of 771.9). At Zoom to Fit
  the hub canvas's document is its area, so the drawing's clear margin
  round the crown never brings up scroll bars. Measured, both IDEs: the
  silhouette 565.6 × 638.5 at 1100 × 800 (inspector shown), 647.8 × 731.4
  at 1400 × 900 (inspector hidden), centred between the toolbar and the
  capsule, no scrolling. The heights match; the widths are 16.6 and 18.8
  wider than the reference's 549 and 629, because Ycode's watch is
  slightly wider for its height than the reference's (Ycode's body alone
  is 547.3 and 626.9). Not changed: the reference's proportions conflict
  between W02/W03 (0.86 wide for its height) and W01 at Physical Size
  (0.90), so the frame's proportions wait for a capture of the watch's
  body without the crown.
- **232:** macOS: the first time the hub shows a watch (its id is not in
  `Ycode.deviceHub.shownWatches`), the canvas opens at Physical Size, the
  third segment; that zoom is not saved as the window's, so another device,
  or the watch shown again, takes the window's remembered zoom, unless the
  person picks a zoom meanwhile. At 109 points per inch the silhouette is
  165.8 × 187.2 (the reference 177 × 196 on its display; the gap is the
  same proportion question as row 231, about 6 %). Linux: a watch's device
  window opens with the third segment (Zoom To Actual Size, one device
  point per point; Linux knows no display's physical size, so it is not
  the real size) unless `--scale` or a zoom control chose one; the window
  keeps the hub's 1100 × 800 round it.
- **233:** `DevicesController.revealSelection()` scrolls the sidebar to the
  selected row on every selection and when the window appears. The window
  also opens with the saved selection: the first selection in
  `viewDidLoad` used to select row 0 and overwrite the saved device before
  `restoreState` read it. Measured with 40 devices before the watch: its
  row (41) in view after a selection and after reopening. macOS only: the
  Linux device window has no sidebar (one device per window,
  `cross-platform-parity.md` §13).
- **234:** `DeviceControlsLayout.watchGroup`: one capsule [Side Button ·
  Digital Crown · Screenshot · Record], 142 × 36.5, glyph centres 34 apart,
  centred 8 above the window's bottom, on both IDEs. The two hardware
  glyphs are Ycode's own drawings (`DeviceControlGlyphs.sideButton`,
  `.digitalCrown`, 14 × 14.5): the watch's case as an outline rounded
  rectangle with, on its right edge, a long flat bar low down (the side
  button) or a knob high up (the crown), where the frame draws them. A
  press is the frame's button: the crown press (`home`) and the side button
  (`side`); a device Ycode does not run says why, as the other controls do.
- **235:** `HubSectionHeaderView`: plain text, no chevron while the section
  is open, #737374 in dark (#8B8B8C in light: the same contrast against the
  light sidebar, a Ycode decision); measured on macOS: ink from x 16.0, the
  capital's top and bottom y 110.0–118.0. A click still collapses the
  section; a collapsed section shows a small chevron after its title (a
  Ycode decision: the reference's collapsed header was not captured).
  macOS only (no sidebar on Linux).

Tests: `DeviceHubR9Tests` (YcodeUI; `YCODE_B9_SHOTS`, `YCODE_B9_VALUES`),
`WatchHubR9Tests` (YcodeDeviceModel), `DeviceWindowR9Tests`
(YcodeRemoteViewer); the watch's capsule in `DeviceControlsLayoutTests`,
`DeviceWindowChromeTests` and `WatchWindowTests` follows row 234.

### Round 8 rows now met

- **Met:** 196 (the iPad: 486 × 662 against 485 × 661 at 1100, 556 × 760
  in both at 1400, "iPadOS 27.2"), 197 (selection #0070F5 and band #EEEEEE
  kept across Dark → Light), 198 (the narrow capsule: 39.5 pt, 7.5 pt
  gap, in both; its trailing gap is row 218), 199 (Ycode's own tile; the
  laptop outlined in Ycode, filled in the reference) and 200.
- **Folded into A1:** 203 (the plain-group grey is now #7B7B80 /
  #B6B7BC; row 213).
- **Partly met:** 204, its duration (about 220–230 ms, from 425); its
  pacing is row 224 and the new scroll jump row 223. 206, Long's
  selection; Bands is row 225, live resize is deferred (below).
- **Superseded:** 205 and 207, by rows 220 and 221. Round 8's 190 pt
  target was a misreading of its 1x strip; frame-by-frame tracking at 2x
  measures 38 pt (fast) and about 6 pt (slow), and at 2x the slow flick
  reaches the top in the reference too.
- **Not settled:** 201 and 202 (below).

### Round 9 group A1 implementation (B9-A1, 2026-11-13)

- **The glyph model (both IDEs).** `FileGlyphs` (YcodeIDECore) lays out
  every glyph as Ycode's own paths (moves, lines, cubics; filled, stroked
  or both) in its box; the macOS IDE fills them as template images
  (`NavigatorRowImages`, tinted by their views, drawn without vibrancy),
  the Linux IDE as OpenViews paths (`FileGlyphView`). The language logos'
  paths are generated by `scripts/generate-language-logos.swift` from
  devicon v2.18.0's single-colour SVGs (`Resources/language-logos`: each
  "-plain" variant, "-line" for C and Rust), converted to absolute
  commands (arcs and quadratics to cubics) and trimmed to their ink;
  no SVG reader, raster or font is used at run time. The full-colour
  PNGs, their dark inverted copies and the full-colour SVGs are gone.
- **208:** each logo is fitted by its own bounds into the reference's
  14.5 × 12.5 box, centred at x 62.75 at depth 2 (55.5–70; the macOS
  frame 18 wide from 0.25 before the old icon's, the Linux glyph 1.5 right
  of its 16-point frame's centre); the label stays at x 73 (its text's ink
  at 76). The "-line" outlines (bands about 0.2 points) are also stroked,
  C 1.25, Rust 1.35, to about 1.5 points. Swift is the bird alone: the
  generator drops the plain variant's outermost subpath (the tile) and
  fills the knocked-out bird even-odd (94.3 × 80.6 of 128, so 14.5 × 12.4).
  Python is its plain shapes stroked 1.5 with no fill. Tints are the tint
  table's; the unmeasured languages take their logo's colour family
  (`FileGlyphs.logoTints`). Focused selection: white (#FFFFFF); a selected
  row without focus: the type's tint, Swift #EC6D38 / #FFB75F (macOS:
  `NavigatorRowView` restyles its cells on every selection change; Linux:
  `NavigatorRowIconView(unfocusedSelection:)`).
- **209:** Markdown is Ycode's open book (`FileGlyphs.book`): two pages
  mirrored about a spine at x 7.25, 1.5-point strokes, 14.5 × 12, #52788D /
  #CCEAFF, white on a focused selection.
- **210:** `FileGlyphs.json`: braces of 1.5-point strokes (ink x 0–4.4 and
  12.1–16.5) round two filled "6"s of 2.6 × 3.2 (a dot and a rising tail
  each), 16.5 × 12, #EE2C22 / #FF695E; 11 × 8 in the jump bar.
- **211:** the jump bar's file component draws the glyph at its jump-bar
  box (Markdown 12 × 10.5 in #5A8095 / #B7D5EB, JSON 11 wide, other logos
  11.5), a group the folder at 12.5, the project the Ycode mark at 13
  (`FileGlyphs.jumpBarGlyph`, both IDEs); the merge sheet's list (white
  when lit) and path draw the same glyphs in the navigator's tints; Open
  Quickly's file result is `FileGlyphIconView` at 24.5 × 20.5, white with
  `isOnSelection` (A2 sets it on the selected row; the Linux IDE has no
  Open Quickly yet).
- **212:** the title area's icon is the Ycode mark's small master in a
  19.5 box 12.5 after Back | Forward (x 383.5–403), the title 8 after it,
  centred on the title's cap height whether or not a subtitle shows. While
  busy, `BuildRingView` (macOS, layers) and `BuildRing` (Linux) draw an
  18.5 ring on the same centre, 2.5-point stroke, track #E6E6E6 (dark
  #3A3A3C) and a quarter-ring arc #007AFF / #0A84FF turning clockwise once
  a second: indeterminate, as Ycode has no build fraction (the reference's
  determinacy is not settled).
- **213:** groups and folders are Ycode's filled folder (`FileGlyphs.folder`:
  a back with its tab, the front panel 0.6 below), 14.5 × 12, synchronized
  #3FA1F6 / #5BC6FF, plain #7B7B80 / #B6B7BC; the project row the small
  Ycode mark in a 15 × 15 box centred at x 34.75 (27.25–42.25).
- Tests: `CouncilRound9GlyphTests` (YcodeIDECore: boxes, strokes, tints,
  the bird's bounds and empty corners, Python's missing fill, the book,
  the JSON glyph, the jump bar and Open Quickly boxes),
  `CouncilRound9GlyphUITests` (macOS: positions, the drawn ink's colour per
  type in light and dark, selection states, the jump bar, Open Quickly, the
  title mark and ring); the Linux walk `YCODE_IDE_GLYPHS9`.

### Not settled by round 9

| Item | Why not | Capture needed |
|---|---|---|
| Activity subtitle on reopen (row 201) | neither app shows it at the 5 s still | a still within 1–2 s of the window appearing |
| Restored scroll offset (row 202) | the saved position was line 1, so the capture cannot show a restore | leave the left pane scrolled before extra closes the workspace |
| The live warning on the unbuilt plain project ("1" in the toolbar, a stepper in each jump bar) | its text and source are still unknown | open the issue navigator on that project before a build |
| The title icon's build ring in dark, and whether it is determinate | only one light still, from an invalid step | a recorded build in both appearances |
| The source-control segment under the merge **alert** (conflict 02) | claimed by one judge; only the sheet was measured (row 219) | the alert still, sampled |
| Open Quickly with several results, keyboard selection and symbol rows | one file result only | a query with several matches |

### Deferred to beta 4

| Item | Reason |
|---|---|
| The rendered Markdown editor (a "Notes" heading, a formatting bar: Body, B, I, S, link, list) | a feature, not a fidelity fix; out of beta 3's scope |
| Linear drag sampling (main 03: the reference moves +97–1047 ms with 52 positions; Ycode +103–854 ms with 37) | outside beta 3's scope; 2 of 3 judges, medium |
| Live resize latency (main 17: 162 ms against 106) | the rest of row 206; outside beta 3's scope |
| The narrow subtitle's truncation (N02: "Build Fail…6:39 PM" against "Build …23 PM") | one judge; outside beta 3's scope |
| Settings: no scroll-edge blur under the tab bar, the back arrow enabled, scrolling 33 ms late (X13); the Foreground slider ignoring a value set through accessibility | one judge each, not measured; outside beta 3's scope |
| The conflict token's menu opening about 67 ms later (conflict 04) | one judge, not checked |

## Round 10 (2026-11-14)

The design rules and the owner's rules of round 9 still apply: where the
reference has the element, match it; where Ycode has an element the
reference lacks, design it to Apple's HIG in the OS 26+ Liquid Glass
language; Ycode's macOS and Linux IDEs look one to one. The project
glyph is Ycode's own mark wherever the reference shows its project tile.

Conditions: every session at **1x on a 3440 × 1440 point display at
100 Hz** (round 9: 2x at 120 Hz; round 8: 1x), so compare this round's
stills with round 8, and its timings with round 9 only where a row says
the value does not depend on the display. System appearance dark; each
app's own Appearance switched as in round 9. **Host load (1-minute)
5.8–19.6 at the start of every timed session** (round 9: 6.6–14.4).
Device Hub's device session started at a load of 432 (stills only, not
timings). Ycode at `ad266d98` (every round 9 fix). Positions are in
window points from the window's top left at 1x (so ±0.5–1 pt), in a
1400 × 880 window unless a row says otherwise; colours are "light /
dark"; "full-coverage" colours are pixels the ink covers entirely.

Not scored: the reference's main 18 (its Welcome window opened outside
the capture area; round 9's still was used), the reference's owner 03
and 09 as hovers (the pointer missed its button), device-watch 02 (the
reference's inspector was hidden), and the first reopen attempt.

### Scores

| Area | Claude R9 → R10 | GPT Sol R9 → R10 | Gemini R9 → R10 | Mean R5 → R6 → R7 → R8 → R9 → **R10** |
|---|---|---|---|---|
| Overall | 7.9 → **8.3** | 8.4 → **9.0** | 9.0 → **8.9** | 7.83 → 8.63 → 8.27 → 8.80 → 8.43 → **8.73** |
| Main steps 01–18 | 8.76 → 8.82 | 8.98 → 9.07 | 9.19 → 9.05 | 8.25 → 8.75 → 9.25 → 9.13 → 8.98 → **8.98** |
| Extra steps (X03–X09, X15 + R01) | 7.97 → 7.63 | 8.08 → 7.70 | 8.68 → 8.22 | — → — → 7.25 → 8.60 → 8.24 → **7.85** |
| Conflict editor (with N02) | 9.0 → 8.8 | 9.3 → 9.1 | 9.2 → 9.1 | 7.00 → 8.67 → 9.07 → 8.83 → 9.17 → **9.00** |
| Settings | 9.1 → 9.2 | 9.3 → 9.4 | 9.3 → 9.4 | 7.33 → 9.00 → 8.67 → 9.27 → 9.23 → **9.33** |
| Device window (01–09) | 9.0 → 9.1 | 9.2 → 9.2 | 9.1 → 9.2 | 7.40 → 7.67 → 6.77 → 8.10 → 9.10 → **9.17** |
| Navigator icon stills (I02, I04) | 8.40 → 8.75 | 6.55 → 9.15 | 8.90 → 8.85 | — → — → — → 8.08 → 7.95 → **8.92** |
| Owner steps | 4.8 → **7.1** | 5.1 → **8.7** | 7.7 → **8.6** | — → — → — → — → 5.87 → **8.13** |

The overall mean rose from 8.43 to 8.73, close to round 8's 8.80; the
owner steps rose from 5.87 to 8.13 and the icons from 7.95 to 8.92. The
extra steps fell from 8.24 to 7.85: the flicks at this display, the split
jump bars, and reopen now showing a real difference. Most of the spread
between judges is Claude's owner area (the watch art, the Markdown
editor, the assistant gradient).

Steps below 8 (7):

| Step | Claude / GPT / Gemini | Mean (R9) | Rows |
|---|---|---|---|
| Main 04 fast flick | 6.8 / 6.8 / 7.7 | 7.10 (7.33) | deferred (flicks) |
| X05 slow flick | 6.8 / 6.8 / 8.0 | 7.20 (7.47) | deferred (flicks) |
| OA assistant button | 6.3 / 7.8 / 7.9 | 7.33 (6.83) | 238, 239 |
| X09 jump bar split at 1180 | 7.6 / 7.7 / 8.2 | 7.83 (8.20) | deferred (row 216) |
| X03 flick to the bottom | 7.8 / 7.8 / 8.0 | 7.87 (8.27) | deferred (flicks) |
| W04 watch at Physical Size (new) | 6.8 / 8.3 / 8.7 | 7.93 (—) | 249–252 |
| OT title icon and build ring | 7.6 / 8.0 / 8.3 | 7.97 (6.33) | 236, 237 |

Just above the line: X08 8.00, W01 8.03, X07 8.07, main 18 8.10 (row
241), X15 + R01 8.13 (deferred: reopen), OG 8.17 (rows 242–247), N02 8.20
(rows 236, 237). Main 07 fell from 9.03 to 8.30 (Bands, row 225,
deferred).

### Round 10 fix groups

Two groups with **no shared files**, so they can run in parallel:

- **A, chrome and glyphs** (rows 236–247): the title area's build ring
  and icon placement; the assistant button's hover and glyph drawing; the
  merge sheet's jump bar; the Welcome window's placement; Open Quickly's
  row typography; the image, Python, Markdown and JSON glyphs; the dark
  navigator background; the jump bar's leading items and chevrons.
- **B, inspector timing and the watch** (rows 248–252): the inspector
  slide's start and pacing; Device Hub's watch art (case size, case
  drawing, crown and side button, the control capsule's hardware
  buttons).

### Round 10 rows

#### A, chrome and glyphs

| # | Finding | Reference | Ycode now | Target | Spec | Level | Judges | Severity |
|---|---|---|---|---|---|---|---|---|
| 236 | Determinate build ring (OT, N02; completes row 212) | measured in the 1100 × 880 light window, two snaps during a build. Ring ink **19 × 19** (x 385–403, y 17–35), centre (394.5, 26.5); stroke about **2.5** (two full pixels and a partial one at 1x); **round caps**; track **#E6E6E6**, arc **#007AFF** (light; dark not captured). The arc **starts at 12 o'clock and runs clockwise**. First snap, subtitle "Build" (no count yet): a short arc whose ink spans −11° to +24° (the arc itself about 0°–16°, about 0.04 of the circle, with its caps). Second snap, 1.9 s later, subtitle **"Building • 36/55"** (0.65): ink −9° to +202° at half coverage, so the arc on its centre line runs from 0° to about 195°, **about 0.54 of the circle**. After the build the icon returns | an indeterminate quarter arc (#007AFF on a #E6E6E6 track, 18 × 18 ink) turning once a second; the subtitle already counts ("Building • 35/36" in the second snap; "Build" in the first, as the reference) | a **determinate** ring at the reference's size, stroke, caps, colours (dark: the system's track grey and #0A84FF, as row 212), start and direction, its arc's fraction **n/m from the subtitle's "Building • n/m"**; before the first count a short arc of about 15° from the top. Each new fraction is reached by easing over about 0.25 s, never backwards (Ycode's choice: the one mid-build snap shows the reference's arc about 0.1 behind its counter, which one snap cannot explain). When the build ends, the icon returns | reference-ui-5.md §4.3; workspace-window.md W7 | 3 | 3 of 3 | M |
| 237 | The title-area icon rises with the title when a subtitle shows (N02) | with a subtitle (the build's), the title's cap height moves up to y 15–25 and the subtitle sits at y 30–39; **the icon or ring stays centred at y ≈ 26.5** (ink y 15–36 for the tile, 17–35 for the ring), level with the two-line block. Without a subtitle (owner session) the icon is at the same place, the title centred on it (round 9: cap height y 21–31) | in N02 the mark and the ring sit at **y 9–27** (centre about 18.5), centred on the title's cap height, 8 pt higher than the reference; without a subtitle (owner) it is at y 17–35, as the reference | the icon (and the ring in its place) at a **fixed vertical centre, the toolbar's centre line (y ≈ 26.5 in this window)**, whether or not a subtitle shows; only the title and subtitle move. Revises row 212's "centred on the title's line" | reference-ui-5.md §4.3; workspace-window.md W7 | 3 | meas. | L–M |
| 238 | No hover on the coding assistant button (OA; the rest of row 214) | round 9's value stands (round 10's reference hover is not valid): with the pointer resting 1.5 s on the button the light capsule goes **#FBFBFB → #F2F2F2**, the glyph unchanged; dark: no measurable change (#454545 at 2x, #444444 at 1x). Gemini's "brighter in dark" is not supported by any capture | **no pixel changes** in light or dark after 1.5 s with the pointer on the button (rest #F9F8F8 / #424242 in both stills), although B9-A2 implemented the hover: the hover state never starts when the pointer arrives the way the capture tool moves it | the hover shows within one frame of the pointer entering the button and holds while it rests there, however the pointer arrived (a real move, a posted mouse-moved event, or the pointer already inside when the button appears or the window becomes key); light #FBFBFB → #F2F2F2, dark unchanged | coding-assistant.md §4; reference-ui-5.md §4.3 | 3 | 3 of 3 | M |
| 239 | The assistant glyph at 1x (OA; sector colours of row 214) | at 1x: bubble ink **18 × 18 with the tail** (x 575–592, y 17–34 in the owner window); body x 575–592, y 17–31; corner radius about **2 pt** (each side straight for about 10 pt, y 18–28). **The left, right and top sides each fall in one pixel column or row at full colour** (left x 575: #FC8238 at the top to #C7A692 at the bottom; right x 592: #FB4765 at the top to #E985E3 at the bottom; top y 17: #FE8C4A at the left to #FF4B51 at the right); the bottom splits over two rows in both apps. Plus: arms **7 × 8 pt** (vertical y 20–26, horizontal x 580–587), about 1.5 pt thick, centred in the body (x 584, y 23.5–24), **nearly one colour**: core #DE7E7F, arms #DD817B (left) to #E1748F (right), #F48F85 (top) to #D6A5B9 (bottom), consistent with round 9's linear #F46E5A → #BF8EA8 from top to bottom, **not the outline's angular gradient**. The tail's point about 4 pt right of the body's left edge and 3 pt below its bottom. Sector medians at 1x (Claude's): right #F375C3, bottom #9ABBE0 (light) | ink 18 × 17 (x 586–603, y 17–33); corner radius about 3.5 (sides straight for about 6 pt). **Its left and right sides straddle two columns at about half coverage** (left x 586–587, right x 602–603), which is why the sector medians read paler in light (right #EF9BDA, bottom #B2C9E9) and darker in dark (right #C168A5); the top is aligned. **The plus's vertical arm runs from y 17 to 29 (13 pt)**, poking through the bubble's top edge and nearly reaching its bottom; the horizontal arm 9–10 pt; the plus takes the angular gradient arm by arm (top orange #FC8E71, left tan #E5AD92, right pink #F09AD3, bottom **blue #9BC0E2**). The tail's point about 1.5 pt right of the left edge | the outline's stops of row 214 unchanged; the outline placed so that at 1x its left, right and top strokes each land on one pixel column or row (stroke centres on pixel centres for an odd-pixel stroke), the corner radius about 2 pt; the plus **7 × 8 pt** inside the body, centred on it, not touching the outline, filled with its own **linear top-to-bottom gradient #F46E5A → #BF8EA8** (median about #E3828D / #DF7C80, round 9), not the angular one; the tail's point about 4 pt in from the body's left edge and 3 pt below it. Check at 1x and 2x: right-side sector median within about 10 levels of #F375C3 | coding-assistant.md §4; this section | 3 | 1 of 3, confirmed, meas. | L–M |
| 240 | The merge sheet's jump bar (conflict 03; the rest of row 211) | the project component is the project tile, **13 × 13** (x 385–398, y 113–126 in the 1516 × 976 capture with its margin); then "Merger" (37 wide), a chevron 4 × 10, the folder, "Merger", the Swift bird, "Greeting" (**44 wide**), "No Selection" (**48 wide**) | a **blue outlined cube**, 12 × 12, for the project; the names about 8 % wider than the reference's ("Greeting" 48, "No Selection" 52, "Merger" 39) while the main jump bar's names match the reference's width ("GlassScroll" 58 in both); chevrons 4–5 × 6 | the project component is **Ycode's mark** in the 13 × 13 box, as in the main jump bar (`FileGlyphs.jumpBarGlyph`, row 211); the sheet's jump bar uses the main jump bar's text style and chevron (row 247) | merge-sheet.md §4.1, §13.7; navigators.md round 7 §5 | 3 | 3 of 3 | L |
| 241 | The Welcome window's placement (main 18) | the 480 × 629 window is placed **on the screen, not on the workspace window**: centred horizontally on the screen (x 516–996 on a 1512-point display, centre 756), its top **89.5 pt below the visible frame's top** (screen y 122.5 with a 33 pt menu bar; 949 visible), so the free height is split about **28 : 72** above : below (rounds 4 and 9, 2x, built-in display; the workspace window's frame plays no part). Round 10: not observed (the reference's Welcome window opened on another display) | centred horizontally on the screen as the reference (x 460–940 in the capture, screen x 1480–1960 on 3440); its top about **192 pt below the visible frame's top** (about 25 : 75 of the free 781 pt), so on this display it sits about 78 pt above the workspace window's top. **The window is on screen**: the cut in the still is the capture area (the workspace window's frame), not the screen | the reference's rule: centred horizontally on the visible frame of the screen it opens on, its top at 28 % of the free height below the visible frame's top, never above the visible frame. On round 10's display this still puts its top about 51 pt above the workspace window, so **the next capture must take the Welcome window by its own frame**; judges should not score the cut. Which screen the reference opens it on with two displays is not settled (below) | editor-area.md F.11; workspace-window.md W7.6 | 3 | 3 of 3 | L |
| 242 | Open Quickly's row typography (owner 06, 12; the rest of row 215) | the result row 620 × 56 (top at y 136 at 1x, 266 at 2x). **Name**: cap height about 12.2 pt (2x: ink y 276.5–289), so about **17 pt** type, bold, cap top 10.5 below the row's top, baseline 23 below it. **Breadcrumb**: ascender height 11 pt and x-height 8 pt (2x: ink 298.5–310.5, the lowercase from 302), so about **15 pt** type; baseline **44.5** below the row's top; "GlassScroll" **73 wide** (1x); the separator a **thin tall chevron, 3 × 14** (y 167–181), with 7 pt of space each side; the project glyph **12 × 12** at x 445, 4 pt before the text, drawn white on the selected row | name 15 pt medium (cap 10.7, top 15 below the row's top, baseline 26); breadcrumb **11 pt** ("GlassScroll" 57 wide; ascender about 8, baseline 43); separator "›" 2 × 4 with 5 pt each side; Ycode's mark 10 × 10 ink, 6 pt before the text, in its own colours | name about **17 pt** bold at cap top +10.5 and baseline +23 from the row's top; breadcrumb **15 pt** regular at baseline +44.5; the separator a thin chevron about 3 × 14 with 7 pt each side; Ycode's mark in the 12 × 12 box, 4 pt before the text. Whether the mark turns white on the selected row, as the reference's tile does, is the owner's call (Ycode's mark is a colour logo) | open-quickly.md; reference-ui-5.md §6.1 | 3 | 3 of 3 (breadcrumb), meas. (name, separator) | L |
| 243 | The image glyph (I02, I04, OG; row 208) | **14 × 12** at 1x (x 56–70, y 313–325 at depth 2; 2x: x 55–70, 15 × 12 with antialiasing); a rounded frame of a 1 pt stroke, the corner radius about 1.5, **its sides each one pixel column at full colour at 1x**; inside, a small round sun about 2 pt across in the upper left third and a filled hill landscape over the bottom third, its peak right of the centre about 5 pt above the bottom. Full-coverage colour **#006BEF / #2DA7FF** (both rounds) | **12 × 11** (x 56–68, y 313–323/324); its sides at about 90 % coverage (#3EA2EA in dark); full-coverage colour **#0066E8 / #44BEFF** | Ycode's own picture glyph (the shape is Ycode's) at the reference's 14 × 12 box, 1 pt stroke pixel-aligned at 1x, in **#006BEF / #2DA7FF**, white on a focused selection | navigators.md round 7 §5; round 9 tint table | 3 | 3 of 3 | L |
| 244 | Python's dark tint and weight (I02, OG; row 208) | **#FFF62A is the reference's tint**, not round 10's #FFEF2A. Every full-coverage pixel of the outline reads #FFF62A in both rounds (2x: 142 of 304 ink pixels; 1x: the straight runs, x 61–63 on y 208 and x 63–66 on y 211); #FFEF2A is the **median of all ink pixels**, which takes in the antialiased edges, where red saturates at 255 before green does. At 1x the glyph is 12 × 13 (x 57–69, y 202–215) with **78 ink pixels**, 10 of them full | the hue is right (its edges are #FFF62A at about 0.9 coverage) but **only 1 of 104 ink pixels** reaches full coverage at 1x: its straight segments straddle pixel rows, so the glyph reads dimmer (median #C6C02A against #D7C12A) and heavier (more, paler pixels) | keep **#FFF62A** in dark (#EFBD00 in light); place the outline's straight segments on the pixel grid at 1x so that they draw at full colour; stroke 1.5 pt at 2x as row 208 (at 1x the reference's straight runs are one pixel wide). Target at 1x: about 80 ink pixels, of which at least 10 at full coverage | navigators.md round 7 §5; round 9 tint table | 3 | 3 of 3 | L |
| 245 | The dark navigator background (I02, owner, main; row 213) | mean over a flat 100 × 200 pt area of the navigator: **#28282A** (round 9, 2x) and **#29282A** (round 10, 1x); the most common pixels #282829–#29292A. Under the merge sheet the same area dims to #1B1C1D | #252628 (round 9) and #262627 (round 10); under the sheet #171819 | **#28282A** in dark (light unchanged) on both IDEs, with its dimmed form under a sheet following from it | navigators.md; workspace-window.md W7.2 | 3 | 3 of 3 | L |
| 246 | The jump bar's Markdown and JSON glyphs (owner 05, 11; owner-json 02, 04; row 211) | **Markdown**: ink **13 × 10** at 1x (x 528–541, y 61–70), outer sides and the **spine each one full pixel column** (#5A8095 / #B7D5EB), 1 pt strokes; each page's top a slight arch (high mid-page at y 61, down to y 62 at the outer corner and at the spine), the bottom likewise (y 69 mid-page, 70 at the corners and spine). 2x (round 9): 12.5 × 10.5. **JSON**: ink **14 × 10** (x 529–542, y 61–70); braces of about 1 pt; the quote **two filled marks, each about 3 × 4**, at x 533–535 and 537–539, y 64–67; colour **#FF383C / #FF4245** at full coverage (the system red, **not the navigator's #EE2C22 / #FF695E**) | Markdown 12 × 10, its spine **straddling two columns** at half coverage (#7292A4 / #A2BCCF), the page tops sloping down to the spine as two straight lines over two rows; full-coverage sides already #5A8095 / #B7D5EB. JSON **12 × 9**, braces at half coverage over two columns (#F68D88 in light); the quote marks collapse to a **horizontal dash** 4 × 1 at low coverage; colour the navigator's #EE2C22 / #FF695E | Markdown in a 13 × 10.5 box with the outer edges and the spine on whole pixel columns at 1x (the spine at the box's middle column), 1 pt strokes, arched page tops and bottoms; JSON 14 × 10 with two filled quote marks about 3 × 4 each, braces 1 pt on whole columns, in **#FF383C / #FF4245** in the jump bar (the navigator keeps row 210's red) | navigators.md round 7 §5; source-editor.md §Jump bar | 3 | 3 of 3 | L |
| 247 | The jump bar's leading items and chevrons (owner, main 02; measured, not raised) | in every jump bar of rounds 9 and 10 (light and dark, 1x and 2x): the Related Items grid **13 × 13** (x 303–316, y 60–72; four 6 × 6 squares, 1 pt strokes on whole pixels, #939393–#A0A0A0 / #7F7F7F–#8B8B8B), then a **1 × 12 divider at x 325** (y 60–72, **#E6E6E6 / #3C3C3C**), then the project glyph from **x 339**. Path chevrons **3 wide × 10 tall** (y 61–71; core #808080 / #DEDEDE), stroke about 1.25 | grid 11–12 × 12 (x 298–309) with half-covered squares; **no divider**; the project glyph from **x 315** (24 pt early), so the whole path sits 24 pt left; chevrons **3 × 6–7** (y 63–69), core #8A8A8A. (The merge sheet's jump bar already has its divider) | the grid 13 × 13 at x 303, the 1 pt divider at x 325 in those colours, the path from x 339; path chevrons 3 × 10 with the reference's colours, on both IDEs; the spacing of editor-area.md H.4 / I.5 otherwise unchanged | source-editor.md §Jump bar; editor-area.md F.10, H.4, I.5 | 3 | meas. | L–M |

Not borne out: the claim (Claude, as in round 9) that **the reference
greys its traffic lights under the merge sheet while Ycode keeps them
coloured**. In conflict 03 of both rounds, both apps show the close
button grey (#4B4C4C–#4D4E4F in the reference, #464747–#48494A in Ycode)
and the minimize and zoom buttons coloured (#FDBC00, #00BB00–#2DBF00) in
both. The only difference there is the dimmed toolbar and navigator
behind the sheet, #1B1C1D against #171819, which row 245 fixes. No row.

#### Round 10 group A implementation (B10-A, 2026-11-14)

- **The pixel grid (rows 239, 243, 244, 246, 247).** `FileGlyphs.pixelAligned`
  (shared) takes a glyph and where its box lands (points, and pixels per
  point): strokes become `max(1, ⌊w × scale + 0.25⌋)` pixels (1.5 points
  stays 3 pixels at 2x and is one pixel at 1x, as the reference's straight
  runs), the drawing moves by less than half a pixel so its horizontal and
  vertical runs fall on whole pixels (an odd-pixel stroke centred on a
  pixel's centre, an even one on an edge, a fill's edge on an edge), and a
  stroked run that still straddles pixels (Python's outline, whose runs lie
  at many phases) is snapped on its own, the curves leaving it moving their
  nearer control point. macOS draws through `GlyphPixelGrid` from the
  current context's transform (the navigator's `NavigatorFlatIconView`, the
  jump bar's `JumpBarIconView`, the merge sheet's path, the grid); Linux
  through `FileGlyphView` from its global frame and `displayScale`.
- **236:** `BuildRingProgress` (shared) reads n/m from "Building • n/m",
  starts at 15° from the top, eases out (cubic) over 0.25 s to each larger
  count and never moves back; a new build starts it again. The ring is 19
  across (its ink), 2.5 stroke, round caps, #E6E6E6 / #3A3A3C track,
  #007AFF / #0A84FF arc, clockwise from 12 o'clock; the turning arc is gone.
  macOS `BuildRingView` (strokeEnd with a 0.25 s animation from the shown
  value), Linux `BuildRing` (`task(id:)` per subtitle). Measured at
  "Building • 36/55": macOS ink 19 × 19 (19.5 at 2x with the edge), arc
  #007AFF at 3 and 6 o'clock, track #E6E6E6 at 9; Linux ink x 384–403,
  y 16–35, the arc to about 234°.
- **237:** the mark and the ring at one centre, the name's capitals'
  middle without a subtitle (`ActivityView.iconMidY`; Linux `TitleMark`
  no longer moves); only the title and subtitle move. Revises row 212.
- **238:** `AssistantToolbarButton`'s tracking area takes entered, exited
  and moved events in any window state, a local monitor takes every
  mouse-moved event the app receives (a posted one too), and the button
  reads where the pointer is when it joins a window, the window becomes key
  or its tracking areas are rebuilt. Linux: the toolkit's `onHover`
  (#FBFBFB → #F2F2F2 measured in the walk; dark #454545 either way).
- **239:** `AssistantButtonGlyph` 18 × 18: the outline's left, top and
  right on half points (stroke 1 at 1x, 1.4 at 2x and more), corner radius
  2, body bottom 14, the tail's point 4 in and 3 below; the plus 8 × 7 with
  a 1.5 stroke on (9, 7), filled with its own linear #F46E5A → #BF8EA8.
  macOS paints in place (no cached image) with the wedges unantialiased
  inside the antialiased clip, so a covered pixel is full colour; Linux
  snaps the box to whole pixels. Measured at 1x: ink x 9–26, y 9–26 in the
  36-point circle, columns 9 and 26 and row 9 full; the right sector's
  median #F280CF at 1x and #EF7ECC at 2x (target #F375C3); plus top
  #EE7163, bottom #C88999.
- **240:** the merge sheet's path draws the main jump bar's components: the
  project's Ycode mark in its 13-point slot, a group's folder, the file's
  jump-bar glyph, 11-point names 6 after each slot, the 3 × 10 chevron 7
  after a name and 9.5 before the next icon (8.5 before "No Selection").
  macOS `MergeJumpBarView`, Linux `MergePathComponents`.
- **241:** `WelcomePlacement` (shared): centred on the visible frame, its
  top 28 % of the free height down, never outside it (macOS: 480 × 632 on a
  1512 × 949 visible frame sits 89 above and 228 below). **Linux: not
  met**: a Wayland client cannot place its windows; the compositor does.
- **242:** `OpenQuicklyLayout`: the name 17 bold with its baseline 23 below
  the row's top (measured 23.0, cap top 11.0); the second line 15 regular,
  baseline 44.5; the project's mark 12 × 12 centred 39 down, 4 before the
  path; groups joined by a thin chevron 3 × 14 (1-point stroke, centre 38
  down) with 7 each side (`OpenQuicklyBreadcrumbView`, Linux
  `OpenQuicklyBreadcrumb`). "GlassScroll" is 76 wide at 15 points on
  macOS (reference 73). The mark keeps its colours on the selected row
  (the owner's call).
- **243:** `FileGlyphs.picture`, `NavigatorRowIcon.image` for image files:
  14 × 12, a 1-point frame (radius 1.5) on half points, a sun 2.2 across,
  hills filled from the frame's inner edge, peak at x 8.6, 5.4 above the
  bottom; #006BEF / #2DA7FF. Measured at 1x: 14 × 12, x 56–69 at depth 2
  on both IDEs, the sides full columns.
- **244:** Python at 1x: 77 ink pixels, 38 at full coverage (macOS), 78 and
  33 (Linux), 12 × 13; #FFF62A full-coverage in dark.
- **245:** `WorkspaceChrome.navigatorDarkBackground` #28282A: macOS
  `NavigatorDarkFillView` under the navigator (nothing in light), Linux
  `ShellColors.navigatorBackground`. Measured #28282A on Linux, #282829 on
  macOS (one level in the colour round trip).
- **246:** `FileGlyphs.jumpBarBook` 13 × 10.5 (sides and spine on whole
  columns, arched tops and bottoms, 1-point strokes) and
  `FileGlyphs.jumpBarJSON` 14 × 10 (1-point braces, two filled quote marks
  3 × 4 at x 4–7 and 8–11) in #FF383C / #FF4245 (`jumpBarTint(.json)`; the
  navigator keeps its red). Measured at 1x on both: the book 13 × 10 with
  full columns 0, 6 and 12; JSON 14 × 10, #FF383C.
- **247:** `JumpBarLeading`: Ycode's grid (four 6 × 6 squares, 1-point
  strokes, radius 1, #9A9A9A / #858585) 13 × 13 at 13, with a file open
  a 1 × 12 divider (#E6E6E6 / #3C3C3C) at 35, the path's first ink at 49;
  the empty bar keeps its divider at 33.5 and "No Selection" at 47.5, a
  split pane its +36 / +58 / +71.5. Chevrons 3 (2 in a pane without focus)
  × 10 with a 1.25 stroke. Measured: macOS grid 13–26, divider 35,
  path from 49.0, chevron 3 × 10; Linux (bar at 290) grid 303–316, divider
  325, project mark from 339.
- Tests: `CouncilRound10ChromeTests` (YcodeIDECore, both platforms),
  `CouncilRound10ChromeUITests` (macOS); round 9's glyph, A2 and toolbar
  tests and round 4's Welcome test follow the revised rows. Linux walk:
  `YCODE_IDE_CHROME10`.

#### B, inspector timing and the watch

Inspector timings are from the editor's minimap edge, tracked in every
recorded frame on row y 650 (the round 9 method; the recorder delivers
only changed frames), in ms from the press's start (an accessibility
press of Hide / Show Inspector).

| | Reference R9 (2x, 120 Hz) | Reference R10 (1x, 100 Hz) | Ycode R10 |
|---|---|---|---|
| Hide: first edge movement | +54 | **+119** (2 pt), +146 for the main movement | +57 |
| Hide: edge at rest | +272 | +307 | +294 |
| Hide: slide | 218 ms, 13 positions | **188 ms**, 7 positions; 25 % of the travel at +27 ms, 63 % at +78, 96 % at +167 (an ease-out) | 237 ms, 10 positions |
| Hide: holds over 20 ms | 4 | 6 (21–52) | 7 (21–38, whole frame) |
| Show: first edge movement | +136 (first changed frame +106) | **+225** | +101 |
| Show: edge at rest | +366 | +454 | +283 |
| Show: slide | 230 ms, 14 positions | **229 ms**, 10 positions; 15 % at +42 ms, 26 % at +84, 61 % at +110, 95 % at +174 (an ease-in-out) | **182 ms**, 10 positions |
| Show: holds over 20 ms | 4 (25–30) | 4 (25–42) | 2 |
| The press's own duration (the app's reply to it) | hide 124, show 115 | hide 112, show 172 | hide 129, show 102 |

| # | Finding | Reference | Ycode now | Target | Spec | Level | Judges | Severity |
|---|---|---|---|---|---|---|---|---|
| 248 | Inspector start latency and the show's length (main 10, 11; the rest of row 224) | the table above. With the same input, at about the same load, the reference's start moved by **+65 ms (hide) and +89 ms (show)** between round 9 and round 10, while its slide durations held (hide 218 → 188 ms, show 230 → 229 ms) and **the show started 80–110 ms later than the hide** in both rounds. The start is therefore not display-independent (nor tied to the press's reply: hide −70 and +7, show +21 and +53 ms after it); the duration and the hide-to-show offset are | hide starts at +57 in both rounds; the show at +57 (round 9) and **+101** (round 10); the hide slide 237 ms, the show **182 ms** (shorter than either reference); Ycode now starts first (row 224's frame holds are fixed: 7 against 6 on the hide, 2 against 4 on the show) | the hide's slide starting about **+85 ms** after the press and the show's about **+180 ms** (the means of the two rounds, so Ycode falls within about 35–45 ms of the reference in both); slides of about **200 ms (hide, ease-out)** and **230 ms (show, ease-in-out)**; at least 7 (hide) and 10 (show) new positions; holds over 20 ms no more than the reference's (6 and 4). A capture at both scales in beta 4 settles whether the start follows the display | editor-area.md H.2; workspace-window.md W7.3 | 3 | 2 of 3 | L |

Apple Watch Series 12 (46 mm), watchOS 27.2, dark appearance. The
screen is 416 × 496 pixels at scale 2, 326 pixels per inch (208 × 248
device points; `watchos.md` §11.3). Physical Size uses this display's
**about 109 points per inch** (Ycode's measurement, row 232's
implementation). "Body" is the case without the crown, measured on a row
between the crown and the side button.

| Still | Reference with crown | Reference body | Ycode with crown | Ycode body |
|---|---|---|---|---|
| 04 Physical Size, 1400 × 900 | 178 × 197 | 169 × 197 | 167 × 188 | 163 × 188 |
| 01 opening zoom, 1100 × 800 | 178 × 197 | 169 × 197 | 167 × 188 | 163 × 188 |
| 03 and 05 Zoom to Fit, 1400 × 900, no inspector | 660 × 731 | 628 × 731 | 649 × 733 | 629 × 733 |
| 02 Zoom to Fit, 1100 × 800 | 577 × 639 (no inspector) | 550 × 639 | 566 × 639 (inspector) | 548 × 639 |

| # | Finding | Reference | Ycode now | Target | Spec | Level | Judges | Severity |
|---|---|---|---|---|---|---|---|---|
| 249 | The watch's size at Physical Size (W01, W04; the rest of row 232) | the body is drawn at **the case's real size**: 197 pt tall is 45.9 mm at 109 points per inch, 169 wide is 39.3 mm, i.e. the **46 × 39 mm** case (with about 1 pt of the rim's glow each side). In device points (163 per inch) that is about **250 × 295**, the 208 × 248 screen plus about **21 at each side and 23.5 at the top and bottom**. The crown adds 9 pt at Physical Size (about 2.1 mm, **13 device points**); at Zoom to Fit (2.48 points per device point: 731 ÷ 295) it stands 32 pt out, the same 13 device points. Width over height 0.858 | the body is the screen plus a 16-point band: **240 × 280 device points** (163 × 188 at Physical Size, about 5 % small), the crown 8 device points out (20 pt at Zoom to Fit) | the watch's case at its real size: the screen plus about **21 device points at each side and 23.5 at the top and bottom** (250 × 295 for the 46 mm; other watches from their own case size where known, else the same border), the crown **13 device points** out. At Physical Size 169 × 197 (178 with the crown) on this display; at Zoom to Fit the body stays **628 × 731** at 1400 × 900 and 550 × 639 at 1100 × 800, so row 231's fit share is recomputed for the new silhouette | watchos.md §11.3; device-hub.md §4.2, §15.2 | 3 | 3 of 3 | M |
| 250 | The case's drawing: rim and bezel (W03–W05) | at Zoom to Fit (1400 × 900), from the silhouette's outer edge inwards: a **soft light rim**, rising over about 8 pt from the background (#1D1D1E) to a core about **4 pt wide peaking #5B5B5B–#5E5E5E** (#686868 on the right side by the side button), then dropping within about 2 pt to a **flat #1F1F1F band about 10–12 pt** wide, which **fades to #000000 over about 7 pt**; from there the case is black (the glass, about 25 pt) up to the screen, so **the screen's edge cannot be seen** (the black of the face runs into it). Rim, band and fade together about 30–32 pt (about 13 device points); the rest of the 56 pt border is black. Light appearance not captured | a 1 pt #3C3C3D outline and a 1 pt #2B2B2B line, then a **flat #121212 band 41 pt** wide (16 device points), ending at a visible black screen with rounded corners; no rim highlight | Ycode's own drawing of that structure, in device points: rim core about 1.6 wide at about 3.6 inside the outer edge, its glow outwards to the edge, the #1F1F1F band about 4.4, the fade to black about 2.8, then black to the screen, the screen's corner never outlined. In light: the same structure (the reference's light case was not captured; keep the dark values until it is) | watchos.md §11.3; device-hub.md §4.3 | 3 | 1 of 3, confirmed | L–M |
| 251 | The crown and the side button (W03–W05) | at Zoom to Fit: the **crown** 32 pt out from the body, about 115 pt tall (y 253–368 on a body from y 87, **22.5–38.5 %** of its height), its outer corners rounded with a radius of about 20 pt (8 device points), outlined by the same light rim, its inside dark (#11–#18); about **9 fine ridges about 7.5 pt apart** (3 device points) across its outer 12–14 pt only. The **side button** about 10 pt out, about 151 pt tall (**52.5–73.5 %** of the body's height), a pill with rounded ends (radius about 8), outlined by the rim | crown 21 pt out (8 device points), 111 tall (22–37 %), corner radius about 5, a flat grey strip with 8 ridges across its whole width; side button 7–8 pt out, 177 tall (47–71 %), a flat grey bar with square ends | crown **13 device points** out, about 46 tall at 22.5–38.5 % of the body, outer corners about 8, rim-outlined, dark inside, ridges about 3 apart on its outer third only; side button about 4 device points out, about 61 tall at 52.5–73.5 %, rounded ends, rim-outlined; Ycode's own drawing | watchos.md §11.3 | 3 | 1 of 3, confirmed | L |
| 252 | The watch's control capsule: order and glyphs (W02, W03, W05; row 234) | four buttons about 34–35 pt apart: **first the Digital Crown**, drawn as a short cylinder seen from the side with vertical ridge lines and a small arrow at its right pointing left into it (a press); **second the side button**, drawn as the case's right edge in profile, a tall narrow curve like a bracket, with a small arrow pointing left into its middle; then Screenshot and Record. The first two glyphs about 17 × 15 pt | [Side Button · Digital Crown · Screenshot · Record]: a rounded-rectangle case outline with a long bar low on its right edge, then one with a knob high up, about 12 × 15 | the order **Digital Crown, Side Button**, Screenshot, Record (actions unchanged from row 234's implementation: crown → `home`, side button → `side`); Ycode's own glyphs for "press the crown" and "press the side button" in the spirit of that description (a part of the watch and an arrow pressing it), about 17 × 15 | device-hub.md §4.4; watchos.md §11.3 | 3 | 1 of 3, confirmed | L |

#### Round 10 group B implementation (B10-B, 2026-11-14)

Clean-room work from rows 248–252 and the spec sections they name. No
Apple binary, Xcode, Device Hub or Simulator was opened, run or observed.
Both IDEs share the values (`EditorMetrics`, `DeviceFrameGeometry`,
`WatchCaseDrawing`, `DeviceControlsLayout`, `DeviceControlGlyphs`).

- **248:** the slide starts 75 ms (hide) and 170 ms (show) after the
  press, so the first moving frame is drawn at about +85 and +180 at
  100 Hz; the hide is an ease-out over 200 ms, the show an ease-in-out
  (0.42, 0, 0.58, 1) over 230. macOS also starts and ends the slide where
  the split view lays the pane out at rest: the hide's first frame used to
  move the edge one point at the press, and a show ended one point wider
  than the pane at rest. Off every display, stepped at 100 Hz in a council
  window: the hide's edge holds until +80, then moves on each of 19 frames
  to rest at +280 (200 ms); the show's holds until +170 and moves on each
  of 22 frames to rest at +400 (230 ms); the Linux slide takes the same
  start, length and curves. Not settled: rounds 9 and 10 measured Ycode's
  real-window slide 50–90 ms away from its model under load (hide 222 and
  237 ms against 150; show 228 and 182 against 280), so the next capture
  measures these values again.
- **249:** a watch is its case at its real size: the screen plus 21
  device points at the sides and 23.5 at the top and bottom (250 × 295 for
  the 46 mm, 39.0 × 46.0 mm at 163 per inch); Ycode's specs give no other
  watch's case, so every watch takes that border. The crown stands 13 out;
  the drawing keeps the crown's room at its sides only, so the whole
  drawing fits wherever the silhouette does. Measured on macOS: Physical
  Size at 109 points per inch 167.2 × 197.3, 175.9 with the crown (the
  reference 169 × 197 and 178, its body with about a point of glow each
  side); Zoom to Fit 619.8 × 731.4 at 1400 × 900 and 541.1 × 638.5 at
  1100 × 800, the crown 32.2 and 28.1 out. Row 231's share (0.9475) is
  unchanged: the body's height on screen is the share of the free height,
  whatever the silhouette's proportions. Left: the width at Zoom to Fit is
  8–9 points under the reference's 628 and 550, because 21 device points
  at the sides (the row's target) give 0.847 wide for the height and the
  reference's body reads 0.858 with its glow.
- **250:** `WatchCaseDrawing.caseStops`, from the outer edge in device
  points: the glow from nothing at 0 to #5C5C5C at 2.8, the core to 4.4,
  down to #1F1F1F at 5.2, the band to 9.6, the fade to black at 12.4, black
  to the screen; the screen's corner is not outlined. The same in light.
  macOS (`WatchCaseView`) fills the profile as nested rounded rectangles
  half a view point apart, their opacities compounding to the glow's; Linux
  shades it between the stops in one geometry call. Measured on macOS at
  Zoom to Fit 1400 × 900, the left side from the edge, a value a point: 32
  40 50 60 68 77 86 91 92 92 92 79 49 31 31 … 31 29 24 20 15 9 5 0 (over
  the #1D canvas).
- **251:** the crown at 22.5–38.5 % of the body (47.2 tall, 117 points at
  Zoom to Fit), its outer corners 8, 13 out; 9 ridges (#3C3C3C) 3 apart
  across its outer 5.2 only. The side button a pill (corners 3.2) 4 out at
  52.5–73.5 % (62 tall, 153.6 at Zoom to Fit); an Ultra's Action button the
  same pill on the left. Each with a narrow rim (glow 0.8, core to 1.4) and
  #151515 inside (#4A4A4A while pressed, macOS). Both reach 6 under the body,
  past its glow.
- **252:** the capsule is [Digital Crown · Side Button · Screenshot ·
  Record] (actions unchanged). The glyphs are Ycode's, 17 × 15: the crown
  seen from the side, a short upright cylinder with two upright ridges, an
  arrow at its right pointing left into it; the side button the case's
  right edge in profile, a bracket-like arc, an arrow pointing left into its
  middle.

Tests: `CouncilRound10GroupBTests` (YcodeIDECore), `CouncilRound10InspectorTests`
and `DeviceHubR10Tests` (YcodeUI; `YCODE_B10_SHOTS`, `YCODE_B10_VALUES`),
`WatchR10Tests` (YcodeDeviceModel); the earlier rows' tests that held round 8's
and round 9's values (rows 204, 224, 231, 234) follow these rows.

### Round 9 rows now met

| Row | Status after round 10 |
|---|---|
| 208 Navigator file glyphs | **Met**: single-colour glyphs in the reference's box and tints, white when focused, tinted when unfocused (I02 8.87, I04 8.97). Left: the image glyph (row 243) and Python's pixel coverage (row 244) |
| 209 Markdown on a selected row | **Met** |
| 210 JSON glyph | **Met** in the navigator (16 × 12, tints within a few levels). The jump bar's JSON glyph is row 246 |
| 211 Glyphs outside the navigator | **Partly met**: Open Quickly and the main jump bar met; left: the merge sheet's project glyph (row 240) and the jump bar's Markdown and JSON glyphs (row 246) |
| 212 Title area icon and build ring | **Partly met**: the mark's size and the 8–9 pt gap met. Left: the determinate ring (row 236) and the icon's place when a subtitle shows (row 237) |
| 213 Folder and project-row glyphs | **Met** (folder tints exact). Left: the dark navigator background (row 245) |
| 214 Coding assistant button | **Partly met**: size and an angular gradient running the right way. Left: the hover (row 238) and the glyph's 1x drawing, plus and sectors (row 239) |
| 215 Open Quickly panel | **Partly met**: field, separator, row and fills. Left: the row's type sizes and separator (row 242). The panel's place differs by display (the reference places it on the screen) |
| 216 Jump bar collapse with a split | **Not met; deferred** (below): confounded by the reference's live warning stepper |
| 217 "No Selection" for Markdown and JSON | **Met** |
| 218 Gap before the overflow capsule | **Closed by the owner's decision** (the system's overflow item stays); about 24 pt against 3 pt remains on macOS |
| 219 Source Control segment under the merge sheet | **Met** (dimmed fill, white text in both; no judge raised it) |
| 220 Fast flick's stretch | **Superseded** by the display dependence (deferred, below) |
| 221 Slow flick | **Superseded** likewise (deferred) |
| 222 Flick to the bottom | **Superseded** likewise (deferred); Ycode's return also draws a new position only every third recorder frame (about 30 ms) |
| 223 Inspector hide scrolls the editor | **Met**: line 1 stays at the top in main 10, 11, 12, 16 and 17 |
| 224 Inspector pacing and the show's start | **Partly met**: the holds met (7 against 6, 2 against 4). Left: the start latency and the show's length (row 248) |
| 225 Selecting Bands | **Not met, worse**: the editor changes at +375–394 ms against the reference's +97–312 (its editor at +169–214), round 9: 261–271. Deferred (below) |
| 226 Caret not restored | **Met** ("Line: 9 Col: 46" in both) |
| 227 Clicked word highlighted | **Met** |
| 228 Markdown and JSON sent to the Swift service | **Met** |
| 229 File inspector's Type | **Met** |
| 230 Resource sections in the File inspector | **Met** as specified. Left: Ycode shows Text Settings for NOTES.md where the reference shows none, which goes with the rendered Markdown editor (deferred) |
| 231 Zoom to Fit overflows the stage | **Met**: bodies within 1–2 pt, no scroll bars |
| 232 Opening zoom | **Partly met**: opens at Physical Size. Left: the size, about 5 % small (row 249) |
| 233 Sidebar reveals the selected device | **Met** |
| 234 The watch's control capsule | **Partly met**: four buttons. Left: their order and the first two glyphs (row 252) |
| 235 "Available" header | **Cannot be checked**: the header was out of view in Ycode's W01 (its list scrolled to the selected last row) |

### Not settled by round 10, and deferred to beta 4

| Item | Why not now | Needed |
|---|---|---|
| **The flicks** (rows 220–222; main 04, X03, X05) | The posted input was **identical in both apps** (below), yet the reference's response changed with the display: on main 04 it stretched **about 38 pt at 2x / 120 Hz** (round 9), **182 pt at 1x / 100 Hz** (round 10; deepest at +163 ms, at rest by +830) and about 190 pt at 1x in round 8. At 1x the slow flick X05 travels **552 of 600 pt** and stops with line 3 at the top, no stretch (round 9 at 2x: reaches the top, about 6 pt); X03 passes the end by **111 pt** (deepest +184 ms, at rest +783; round 9: 32 pt). Ycode, tuned to round 9: 75 pt (deepest +271, at rest +890; it first shows the top 90 ms after the reference), X05 600 pt with a 15 pt stretch, X03 80 pt (at rest +655). Retuning to either display alone would break the other | a study at both scales and refresh rates with the same logged input, to find what the reference's response depends on (points against pixels, refresh rate, event timing), before Ycode is retuned in beta 4 |
| The logged flick input (for that study) | — | Posted through the system's event stream at the window point (715, 450); dx 0 throughout; times from the first event, events every 8.333 ms (measured 6.6–10.4, mean 8.33). **Main 04 (fast, up):** 184 events: a may-begin (no delta) at 0 ms; 8 gesture events of **+40 pt** (320 pt) to 60.0 ms; an ended event at 60.0 ms; 173 momentum events from **+39.0026 pt** at 60.3 ms, each **0.975063** times the one before (time constant 0.33 s), down to +0.5068 pt at 1495.2 ms (1544.33 pt); momentum end at 1495.3 ms. Travel 600 pt in both apps. **X03 (fast, down):** the same 184 events with the opposite sign; travel 600 (reference) and 609 (Ycode). **X05 (slow, up):** 145 events: 8 gesture events of **+15 pt** (120 pt) to about 59 ms, then 134 momentum events from **+14.626 pt** at about 59 ms down to +0.5088 pt at 1167.8 ms (566.66 pt), momentum end at 1167.8 ms. The first event left 11–21 ms after the action's start |
| The jump bar's collapse with a split (X07–X09; row 216) | the reference showed its live warning stepper, which takes room; Ycode has no live warning, so the two collapse at different widths. The warning's source is still unknown | open the issue navigator on the unbuilt project to learn the warning, then compare with Ycode showing the same warning |
| Selecting Bands (main 07; row 225) | the whole-frame timing cannot say what Ycode does for 375 ms before its one-frame swap (the reference eases over about 215 ms from +97) | an on-screen trace of Ycode's selection (signposts) in the same session |
| The rendered Markdown editor, and no Text Settings for Markdown | a feature: the reference opens NOTES.md in a rendered editor (format bar, heading, bullets; no gutter, minimap or Line/Col) and shows no Text Settings for it | beta 4 feature work |
| **The reopen scroll position** (R01, row 202) | **the rounds contradict each other**: round 8's row 202 says the reference restores the left pane's scroll position; in round 10 it reopened at line 2 in both attempts (t0, +2.5 s, +5 s) after the pane was left at lines 45–57, while Ycode restores the position. Both reopen with Plain expanded and Sub and Models collapsed | a dedicated observation: the reference reopened several times, with different scroll positions, focus in either pane, and with and without the editor having been scrolled since the last save of the workspace's state |
| Which screen the reference opens its Welcome window on (row 241) | in round 10 it opened on the other display, not the one with the workspace window | main 18 with two displays, capturing the Welcome window by its own frame |
| The merge alert panel (conflict 02) | one judge: a lighter outlined panel about 7 % wider in Ycode; round 8 judges disagreed (wider or taller) | the alert still sampled in both apps |
| Settings: the scroll-edge blur under the Appearance pane's bar, and the back chevron enabled (X13) | one judge, not measured | a scrolled Settings pane sampled in both apps |
| Main 03's linear scroll start | the reference's movement starts at +40 ms, Ycode's at +132 ms, with 49 against 36 changed frames (one judge raised it; round 9 deferred its sampling) | beta 4, with the flick study |
| The assistant button's pressed state and the dark build ring | not captured (a click opens the assistant's account UI; the build snaps ran in light) | a dark build snap; the pressed state stays Ycode's own |
| "Available" header (row 235) | out of view in Ycode's W01 | W01 with the list scrolled to its top |

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
| Round 7 reference values | 3 | The round 7 Retina stills and 120 fps recordings of the reference and Ycode (foreground, key window, **dark**, host load 250–700; the device window at two sizes with three devices; the extra and reopen sessions), measured in the dirty room: device bodies and screens from colour runs walked out from the centre, corner fits, button bars; scroll travel per frame by matching against the stills, with the input events from the capture tool's record; the Appearance list stitched from its recording; ink clusters along the jump bar; colour samples and region means per frame; the accessibility trees the capture tool recorded; times against the session manifests; full descriptions in the cited spec sections |
| Round 8 reference values | 3 | The round 8 1x stills and 100 fps recordings of the reference and Ycode (foreground, key window, dark, host load 4–10; the device window with booted devices; the navigator icon stills; N02 with a real compile error and warning), as measured by the council runner from the stills, crops and the capture tool's timing files, with judge claims corrected against them (dirty room) |
| Round 9 reference values | 3 | The round 9 2x stills and 120 fps recordings of the reference and Ycode (foreground, key window, dark system appearance, host load 6.6–14.4 for every timed session); the owner session's crops (navigator glyphs, the title area, the assistant button at 8x, Open Quickly, the jump bar, the File inspector); the Apple Watch and palette.json extras at 1x; measured in the dirty room with colour runs, ink boxes, one-point and sector-median colour samples and the capture tool's timing files (displacement peaks, spring fits, hold counts), with judge claims corrected against them |
| Round 10 reference values | 3 | The round 10 1x stills and 100 fps recordings of the reference and Ycode on a 3440 × 1440 point display at 100 Hz (foreground, key window, dark system appearance, host load 5.8–19.6 for every timed session; Device Hub's device session stills at a load of 432), including two build snaps, the watch at Physical Size and Zoom to Fit, and the capture tool's log of every posted scroll event; measured in the dirty room with ink boxes, angular coverage of the build ring, full-coverage and mean colour samples, row coverage profiles for type sizes, per-frame minimap-edge tracking and the capture tool's timing files, with round 9's 2x stills for comparison and judge claims corrected against them |
| Round 9 owner's rules (line-art logos, the JSON glyph, the title mark, the assistant button) | — | The owner's instructions of 2026-11-13; devicon v2.18.0 is MIT-licensed (`THIRD_PARTY_NOTICES.md`) |
| Row 186's verdict (a real gap, not the capture) | — | Ycode's own source (`WorkspaceUserState`) and the capture tool's launch code (our code) |
| Round 5 accessibility path (row 130) | — | The capture tool's own accessibility driver and session runner (our code), and the round 5 conflict manifests' action results |
| Ycode values | — | The same session's captures of Ycode; `otool -l` of the captured executable |
| EditorConfig lookup | 1 | The EditorConfig specification (editorconfig.org) |
| Scroller style API | 1 | AppKit documentation (`NSScroller.preferredScrollerStyle`, `NSScroller.preferredScrollerStyleDidChangeNotification`) |
