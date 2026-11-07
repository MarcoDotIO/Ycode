# Cross-platform parity: the macOS IDE against the Linux IDE

Audit B5-PARITY (2026-11-07). The owner's rule (RULES.md, design rules of
2026-11-06): every Ycode UI element looks and behaves the same in the
macOS IDE (`YcodeUI`, AppKit) and the Linux IDE (`ycode-ide` and
`YcodeIDEShell` on OpenViews). This document measures where they differ, so
that the round 5 fix agents can close the gaps. It compares Ycode with
Ycode only. No reference application is involved, and no value here says
what the reference does: where both IDEs differ from a council target, the
council's spec section is named and wins.

Routing groups (one fix agent each):

- **A. Editor and theme**: the source editor, gutter, minimap, jump bar,
  editor panes, image editor.
- **B. Settings**: the Settings window and the simulator runtime wizard's
  host step.
- **C. Merge and device windows**: the merge alert and sheet, the device
  window.
- **D. Main-window chrome and motion**: toolbar, navigator, inspector,
  debug area, Source Control navigator, Welcome, empty states.

Severity: **H**, a missing element or structure, or a difference seen at a
glance in a primary area (more than 4 points, another font size, another
colour family); **M**, a noticeable difference (2–4 points, a shifted
colour, another glyph, a different control style); **L**, a subtle one
(2 points or less, wording variants, secondary states).

## 1. Method

### 1.1 The same states on both IDEs

Both IDEs open the same two git repositories, written by
`ycode/scripts/linux-ui-parity/make-parity5.sh` (the Merger repository of
`scripts/linux-conflict/make-conflict.sh`, plus `Sample.swift`, a Swift
file with declarations, comments, strings, numbers and wrapping comment
lines, and `Stripes.png`, an 80 × 180 image; the "rest" copy has
`Sample.swift` changed and `Notes.swift` added, so Changes lists two files;
the "merge" copy is clean). States, in both appearances:

| State | What is shown | Window |
|---|---|---|
| `empty` | the workspace, nothing open, Project navigator | 1400 × 880 |
| `rest` | `Sample.swift` open (the editor clicked), inspector shown | 1400 × 880 |
| `debug` | `rest` with the debug area shown | 1400 × 880 |
| `split` | `rest` split side by side (macOS only: the Linux IDE has no panes) | 1400 × 880 |
| `image` | `Stripes.png` open | 1400 × 880 |
| `changes`, `repositories` | the Source Control navigator's two views | 1400 × 880 |
| `narrow` | `rest` | 1100 × 880 |
| `alert`, `sheet` | Merge "feature" into "main": the alert, then the merge sheet at rest | 1400 × 880 |
| `welcome` | Welcome with the repository as a recent project | the IDE's own |
| `settings-general`, `-editing`, `-components` | Settings panes | 710 × 452 |
| `settings-simulators` | Settings ▸ Components ▸ Ycode Simulator (macOS only) | 710 × 452 |
| `runtime-host` | the simulator runtime wizard's host step | the IDE's own |
| `devices` | the device window, a booted Ycode simulator selected (macOS only) | 1100 × 800 |

**macOS:** `CrossPlatformParityShotTests` (opt-in,
`YCODE_B5_PARITY_DIR=<folder>`) builds each window, places it off every
display (origin −6000, −6000) and behind every other window, and captures
the window alone with `screencapture -l` (the window server's own drawing,
so glass and materials are included; the Mac's screen is never taken). The
windows are drawn as the key windows of the active app (the test answers
yes to `isKeyWindow`, `isMainWindow` and `NSApplication.isActive` for its
own duration) so that selection, title and accent colours are the active
ones. Each shot has a dump: every visible text field, button, segmented
control, text view and identified view with its frame in points from the
window's top left, and for texts the font's size and weight and the text
colour Ycode set.

**Linux:** `YCODE_IDE_PARITY5=<prefix>` (`ShellDriver+Parity5.swift`),
run by `scripts/linux-ui-parity/run-parity5.sh` on the x86 workstation's
Wayland desktop (SDL back end, desktop scale 1), with
`YCODE_IDE_WINDOW_SIZE` setting the area under the in-window menu bar to
1400 × 880 or 1100 × 880. Each shot is OpenViews' readback of the window
and a dump of every `Text` and every identified view with its frame.

**Normalising.** Everything is compared in points. The macOS windows were
drawn at a backing scale of 1 (off the displays), the Linux desktop is at
scale 1, so one pixel is one point on both; the Linux main window's menu
bar (26 points) is cut off, so both images start at the top of the
toolbar. `scripts/linux-ui-parity/measure5.py` pairs the shots, matches
every text present on both sides (a repeated text with the nearest frame),
finds the ink box inside each frame (pixels departing from the frame's
dominant colour) and its colour, and lists the texts present on one side
only. Fills were sampled as medians of small boxes at the same point on
both sides.

### 1.2 Limits of this measurement

- **Inactive drawing on macOS.** AppKit still draws some content in its
  background-window style: the window buttons are grey, and the vibrant
  Project and Source Control navigator rows (text and icons) are drawn at
  about half contrast (light ink #979798 for a declared #3B3B3C, dark
  #878888 for a declared white at 0.85). The navigator's text colours
  below therefore use the colour Ycode declares on macOS, not the drawn
  ink. The council's foreground captures (`fidelity-council.md`) remain the
  reference for the active look.
- **Drawn at 1x.** Text and hairlines on macOS were drawn at scale 1 here;
  the council compares at 2x. Ink widths can differ by a point for that
  reason alone.
- **State differences that are not UI differences**, left out of the
  tables: the caret line (macOS line 5, set by the test; Linux line 1, set
  by the click), the macOS inspector's disabled Indent Using (the macOS
  copy sits under a folder with an `.editorconfig`), Welcome listing two
  recent projects on Linux (both copies were opened there), absolute paths.

## 2. Window frame and toolbar (group D)

Owners: macOS `YcodeUI/Window/WorkspaceWindowController.swift`
(`+ToolbarBand.swift`), Linux `ycode-ide/WorkspaceView.swift`,
`ycode-ide/ShellStyle.swift`, `ycode-ide/YcodeIDEApp.swift`.

| Element | macOS | Linux | Difference | Sev. |
|---|---|---|---|---|
| Window buttons | close, minimize, zoom at x 19 / 42 / 65, y 19, 14 × 14 | none in the window (no client-side decorations); the window's menus are an in-window menu bar, 26 points above the toolbar | the three buttons are missing; the menu bar adds 26 points (an OpenViews matter, §15) | H |
| Toolbar band fill | light #FFFFFF, dark #262626 (sampled at x 870) | light #FFFFFF, dark **#1E1E1E** | dark 8 levels darker | M |
| Capsule fill (navigator/assistant toggles, Run/Stop, history, scheme, editor modes) | filled: light #ECECEC, dark #3A3A3A | not filled: the band's colour inside a hairline outline | Linux capsules read as outlines | H |
| Capsule extents | y 7–44 (37 with the rim) | y 7–44 | same | — |
| Navigator / assistant toggles | x 96–172 (2 × 38) | x 98.2–182.2 (2 × 42) | Linux 8 wider, starts 2.2 right | M |
| Run / Stop | x 209–282 (73) | x 198.2–279.2 (81) | Linux 8 wider, starts 10.8 left | M |
| Back / Forward | x 298–371 (73) | x 302.5–383.5 (81) | Linux 8 wider; disabled glyphs lighter on Linux | M |
| Title | the window title "Merger", regular weight, x 412 | "Merger" semibold (`ShellFonts.toolbarTitle`), x 415.5 | weight; 3.5 right | M |
| Scheme / destination capsule | x 629–797: scheme glyph (rounded square), "Merger", "›", display glyph, "My Mac"; 13 pt regular; no pop-up arrows | x 597–812: "Merger ⌃⌄ › ▪ My Computer ⌃⌄", 13 pt **semibold**, an up-down chevron after each, no scheme glyph | weight, glyphs, 47 wider, 32 left | H |
| Destination wording | "My Mac" | "My Computer" | wording (platform name; decide one rule) | L |
| Add Editor and Editor Options | enabled with a file open | **disabled** (light grey) with a file open | state | M |
| Editor modes (canvas / split / review) | x 1009–1132, three segments, the selected one in a grey pill | x 1005–1127; the second and third segments disabled | 4 left; disabled segments | M |
| Inspector toggle | x 1356, 36 × 36 circle, filled | x 1356, 36 × 36, outline only | fill (as capsules) | M |
| At 1100 points | the scheme capsule collapses to its two glyphs; the title stays; nothing overlaps | the scheme and destination keep their text; the title collapses to "..", Back/Forward slide under the Run capsule and are cut off | Linux toolbar has no compaction rule; items overlap | H |

## 3. Navigator (group D)

Owners: macOS `YcodeUI/Navigator/NavigatorAreaController.swift`,
`NavigatorBars.swift`, `NavigatorRowViews.swift`; Linux
`ycode-ide/NavigatorArea.swift`, `ycode-ide/ShellStyle.swift`.

| Element | macOS | Linux | Difference | Sev. |
|---|---|---|---|---|
| Area fill | light #F2F2F3, dark #252627 (the sidebar material) | light **#FBFBFB**, dark **#1C1C1C** (flat `ShellColors.sidebar`) | 9 levels lighter in light, 9 darker in dark | H |
| Selector bar | nine 30-point cells from x 10 in a capsule; selected cell a grey pill (#D1D1D1 light, #545555 dark), glyph grey | the same cells (x 10 + 30 n, y 51, 30 × 30); pill #E2E2E2 / #3B3B3B; selected glyph **accent blue** | pill lighter (light) and darker (dark); selected glyph tinted on Linux only | M |
| Selector glyphs | 2: a "Y" branch; 3: a bookmark | 2: a branch with a curved arm; 3: a list-with-tree glyph | two of nine glyphs differ (the others match in shape) | M |
| Row indentation | 14 per level (`NavigatorAreaController.indentation`); labels at x 45 / 59 / 73 / 87 | 12 per level (`WorkspaceChrome.indentationPerLevel`); labels at 45 / 57 / 69 / 81 | 2 per level, 6 at the third level. The shared constant says 12: macOS departs from it | M |
| Row pitch and text | 22; 13 pt, ink identical in width ("Merger" 42) | 22; 13 pt, the same ink | same | — |
| Row text colour | declared #3B3B3C (light), white 0.85 (dark) | ink #181818–#1E1E1E (light), #F3F3F3–#FBFBFB (dark) | Linux nearer black / white | L |
| File-type icons | Swift files: an orange `</>`; folders: light blue filled; package: blue cube | every source file: a **blue** `</>`; folders: dark blue filled; package: blue cube | colour of file icons; folder tint | M |
| Selected row when a file is opened | the open file's row is selected (`selectOpenFileRow`), grey band #E7E7E8 / #333435, rounded, x 10–280 | **no row selected** when a file is opened other than by a click on its row | behaviour: Linux does not follow the open document | M |
| Status badges | "?" and "M", 10 pt semibold, #000 at 0.5, ink right edge x 267 | the same letters, ink right edge x 273 / 275 | 6–8 right | L |
| Bottom bar "+" | 28-point circle, filled #E6E6E7 / #393A3B | the same circle, not filled (outline) | fill | M |
| Bottom bar filter capsule | filled #E6E6E7 / #393A3B, funnel menu, "Filter", two trailing glyphs | outline only; the same contents; "Filter" placeholder lighter | fill | M |

## 4. Jump bar and editor (group A)

Owners: macOS `YcodeUI/Editor/SourceEditorController*.swift`,
`GutterView.swift`, `Theme.swift`, `DefaultTheme.swift`, `EditorChrome.swift`,
`JumpBar+Panes.swift`, `EditorAreaController+Panes.swift`; Linux
`ycode-ide/SourceEditorView.swift`, `SourceEditorController.swift`,
`EditorArea.swift`, `LanguageViews.swift` (the symbol item).

| Element | macOS | Linux | Difference | Sev. |
|---|---|---|---|---|
| Line pitch | **18** (`EditorMetrics.lineHeight`: 13 × 18 / 13) | **16** (`SourceEditorController.lineHeight` = round(13 × 1.25)) | 2 per line: Linux shows 12 % more lines; every row is off | H |
| Source font | the system monospaced face, 13 pt, advance 8.0 | Noto Sans Mono 13 pt, advance **7.8** | face; 0.2 per column (80 columns: 16 points) | H |
| Code column | x 342 (editor + 51, `EditorMetrics.codeColumn`) | x **349** | 7 right | H |
| Gutter digits | two-digit numbers' ink x 315–326, colour #BAB6B8 (light) / #6B6869 (dark) | ink x 305–315, #BFBBBC / #666465 | 11 left (the numbers end 34 before the code on Linux, 16 on macOS); colours equal within 6 | M |
| Wrap column at 1100 | "// Section 0: a comment block that is long" (42 columns) then a continuation indent | 49 columns on the first row | the wrap edge differs with the font, column and minimap (see minimap) | M |
| Current line band | #EEEEEE light / #353535 dark, from x 304 (the gutter stays the editor's colour), rounded ends | the same colours, square, across the gutter from x 290 | extent and shape | M |
| Source-control change bar | none for the changed line 7 | a 2-point blue bar at x 334 beside line 7 | element on Linux only (decide: both or neither) | M |
| Theme colours (dark) | keyword #EF89B2 ink (declared #FF83B4 family), comment, string and type colours of the default dark theme | keyword #FF83B4; the same palette | equal within anti-aliasing | — |
| Keyword weight | regular | regular in data (equal ink), but Noto's heavier strokes read semibold at 1x | face only | L |
| Minimap | 112/845 of the editor wide, syntax colours, the visible region shaded; a **scroller** beside it (x ≈ 1125–1137) | about the same width, lines in one grey, no colours; **no scroller** | colours; scroller (an OpenViews matter, §15) | M |
| Jump bar items | 11 pt; package, folder and file icons in colour (blue cube, blue folders, orange `</>`), "›" separators 3 wide | 11 pt Inter with 0.35 tracking (ink 10 % narrower: "Sources" 41 against 47); grey monochrome icons; ">" chevrons with wider gaps | icon colour; ink widths; separator spacing | M |
| Jump bar symbol item | the symbol at the caret ("defaultName"), plain text after a "›" | a grey capsule "No Selection" (`jump bar symbol`, 92 × 28) | style of the item: a capsule only on Linux | M |
| Jump bar rule and fill | a 2-point rule at y 84–85, #E5E5E5 / #404040; bar fill the editor's (#FFFFFF / #262626) | a 1-point rule at y 84, #E5E5E5 / #393939; bar fill #FFFFFF / **#1E1E1E** | rule weight; dark bar fill | M |
| Editor panes (split) | side by side or below, each with its own jump bar and close button | **none**: the Linux IDE has one editor | missing feature | H |
| Image editor | the image centred at 1:1 with an "Open with Preview" capsule at the bottom | "**Binary file**" (`YcodeIDEShell/SourceText.swift`): no image editor | missing feature | H |

## 5. Inspector (group D)

Owners: macOS `YcodeUI/Inspector/InspectorAreaController.swift`,
`InspectorStyle.swift`; Linux `ycode-ide/InspectorArea.swift`.

| Element | macOS | Linux | Difference | Sev. |
|---|---|---|---|---|
| Area fill | #F2F2F3 / #252627 | #FBFBFB / #1C1C1C | as the navigator | H |
| Tab bar | three cells in a capsule, the selected one a grey pill; glyph grey | the same cells (x 1149 + 80.7 n, 30 tall); selected glyph **accent blue** | tint | M |
| Section headers | "Identity and Type", 11 pt semibold, #858587, x 1146, y 89 | 11 pt semibold, **#171717** (label colour), x 1152, y 93 | colour (Linux black, macOS secondary grey); 6 right, 4 down | M |
| Row labels | 11 pt, **#000 0.85** (light) / white 0.85 (dark), right-aligned to x ≈ 1219 | 11 pt, **#898989** / #737373, right-aligned to x ≈ 1232 | colour family (Linux secondary grey); 13 right | H |
| Values | start x 1222 / 1219 | start x 1240 / 1248 | 18–29 right | M |
| Name | plain editable text "Sample.swift", no box | a bordered text field (x 1240–1388, 22 tall, white with a grey rim) | control style | M |
| Pop-ups (Type, Location, Text Encoding, Line Endings, Indent Using) | borderless: text then an up-down chevron at the column's end, full value ("Default - Swift Source") | grey capsules (#EAEAEA), values truncated ("Default - Swift Sou…", "Relative to Gro…", "No Explicit Line En…") | control style; truncation | H |
| File name under Location | "Sample.swift", 11 pt regular | 11 pt **bold** | weight | L |
| Rows present | Name, Type, Location, file name, Full Path, **Working Copy, Relative Path**, Text Encoding, Line Endings, Indent Using, Widths | no Working Copy and no Relative Path | two rows missing | H |
| Group separators | a hairline between groups (after Type, after Full Path, after Relative Path, after Line Endings) | one rule between the two sections | separators missing | M |
| Steppers (Widths) | up/down arrow pairs 13 wide, value at x 1224 | small circular steppers (≈ 12 diameter) | control style | M |
| Vertical rhythm | Location 165, Full Path 203, Text Settings 423 | 170, 213, 299 (rows missing) | 5–10 down where rows match | M |

## 6. Debug area and editor bottom bar (group D)

Owners: macOS `YcodeUI/Debug/DebugAreaController.swift`,
`DebugBarExtras.swift`, `ConsoleRows+DebugArea.swift`,
`SourceEditorController+Bars.swift`; Linux `ycode-ide/DebugArea.swift`,
`DebugViews.swift`, `EditorArea.swift`.

| Element | macOS | Linux | Difference | Sev. |
|---|---|---|---|---|
| Debug area frame | bar y 708–745, panes 745–880 | the same | same | — |
| Bar fill (dark) | #262626 | #1E1E1E | as the toolbar | M |
| Editor bottom bar order | "Line: 5  Col: 8" at x 975, then branch "main" at x 1076, then the debug toggle | branch "main" at x 935, then "Line: 1 Col: 1" at x ≈ 1032 | **order swapped** | M |
| Breakpoints tag | filled #007AFF tag, ink 18 × 12 at (304, 856) | a tag glyph, ink 12 × 12 at (304, 856) | 6 narrower | M |
| Debug toggle when shown | grey glyph | accent-blue glyph | tint | L |
| Variables bar | "Auto ⌃⌄" pop-up with a bezel (76 × 20), eye, info, then a filter field x 425–708 | "Auto ⌃" without bezel, no eye or info, filter x 528–708 | two controls missing; pop-up style; filter 103 shorter | M |
| Console bar | eye, list glyph, filter field x 771–1065, trash, two split toggles (grey) | "All Output ⌃" pop-up (Linux only), no filter field, trash, two split toggles **filled blue** | filter missing; a pop-up macOS lacks; toggle style | M |
| Pane divider | not drawn at x 715 (macOS divides at its own split) | a 1-point #E5E5E5 / #393939 line at x 715 | divider | L |
| Scrollers | both panes show a scroller | none | §15 | L |

## 7. Source Control navigator (group D)

Owners: macOS `NavigatorAreaController+Repositories.swift`,
`YcodeUI/SourceControl/`; Linux `ycode-ide/SourceControlNavigator.swift`.

| Element | macOS | Linux | Difference | Sev. |
|---|---|---|---|---|
| Changes \| Repositories control | x 9–281 × 16 at y 88, 10 pt; selected segment a grey pill, dark text | two 136 × 16 cells at y 89; selected segment **filled accent blue with white text** (#DFEAFE ink on blue) | selected style; 1 lower | M |
| Repository row | blue drive glyph, "Merger" regular, "main" secondary | grey/black rounded-bar glyph, "Merger" **bold**, "main" secondary | glyph; weight | M |
| Changed files | Swift files with a Swift-bird glyph (system symbol); "?" and "M" badges in rounded rims | a blue `</>`; the same badges | glyph | M |
| "Uncommitted Changes" count | "2" right after the title | "2" right-aligned at the row's end (x ≈ 326) | position | L |
| Group rows (Branches, Recents, Tags, Stashes, Remotes) | x 59, glyphs grey | x 57, glyphs dark (#585858 ink) | 2 left; glyph tone | L |
| Branch rows | blue "Y" glyphs, labels x 73 | dark branch glyphs with a curved arm, labels x 69 | glyph and colour; 4 left (indentation, §3) | M |

## 8. Empty states (group D)

| Element | macOS | Linux | Difference | Sev. |
|---|---|---|---|---|
| Inspector placeholder | "Not Applicable" (and "No Selection" in Repositories) 17 pt, #000 0.5, frame at (1210, 470) | the same texts, frame at (1213.5, 429) | 41 higher on Linux (centred in a different box) | M |
| Empty jump bar | grid button, divider, "No Selection" at x 336–339, 11 pt | the same at x 338.5 | within 3 | L |
| Navigator with nothing open | first rows as at rest | the same | same | — |

## 9. Welcome (group D)

Owners: macOS `YcodeUI/Window/WelcomeWindowController.swift`; Linux
`ycode-ide/WelcomeView.swift`.

| Element | macOS | Linux | Difference | Sev. |
|---|---|---|---|---|
| Container | its own 480 × 632 window | a 480 × 632 panel (16-point radius, 1-point rim) centred in the 1400 × 880 main window under the menu bar | structure: not a window of its own | H |
| Close button | a 36 × 36 filled grey circle (`RoundButton`) with an "×", at (20, 20) | a bare "×" glyph, no circle, at about (38, 38) | control style | M |
| App name | "Ycode", 18.5 pt semibold (cap-height sized), y 186 | "Ycode", **34 pt bold**, y 171.5 | size nearly double | H |
| Icon | 97 × 97 at y 78 | 90 × 90 at y 184 − 124 = 60 | 7 smaller, 18 higher | M |
| Version | 13 pt, #000 0.5, y 210 | 13 pt, y 213 | 3 lower | L |
| Buttons | Open…, Clone…, New Project ⌄ at y 242, 36 tall | the same | same | — |
| Recent row | name 13 pt semibold at (120, 307); path 11 pt, head-truncated ("…5-parity/…/rest") | name at (118, 311.5); path middle-truncated ("…B5…-PARITY…") and **clipped** by the box's edge with no ellipsis | truncation rule; clipping | M |

## 10. Settings (group B)

Owners: macOS `YcodeUI/App/SettingsWindow.swift`, `SettingsPanes.swift`;
Linux `ycode-ide/SettingsWindow.swift`, `SettingsCards.swift`,
`SettingsPanes*.swift`, `SettingsPanesEditing.swift`,
`SettingsPanesSystem.swift`.

Settings is the closest area: card fills (#F7F7F7 / #262626), the detail
(#FFFFFF / #1F1F1F), the sidebar (#EDEDED / #262627), wells (#E5E5E5 /
#363636), the title (17 pt semibold, #4D4D4D / #E8E8E8), sidebar rows and
card rows match within one point.

| Element | macOS | Linux | Difference | Sev. |
|---|---|---|---|---|
| Window buttons | three at the top left | none (§15) | missing | H |
| Sidebar selection | drawn #2F6EED (light) / #3478F6 (dark) | #0070F5 / #007AFF (`settings.md` R4.2 says #007AFF in dark) | macOS draws its own selection lighter than its declared #007AFF | L |
| Sidebar divider at x 179.5 | #DFDFDF / #343334 | not drawn (sidebar colour) | divider missing on Linux (R4.3: 0.5-point #414142 in dark) | M |
| Sidebar icons | the system's outline symbols, accent-tinted | OpenViews' filled glyphs (General: a filled gear; Accounts: a person in a circle; Navigation: a filled arrow) | glyph style (§15) | M |
| Sidebar labels | x 46 | x 47 | 1 | L |
| Scroller | a permanent scroller at the right of the detail | none | §15 | L |
| General help text | "Use System Setting reopens them unless "Close windows when quitting an application" is on in System Settings ▸ Desktop & Dock." (two lines) | "… as the desktop restores its other apps' windows." (one line): every card below is **13 points higher** | wording (platform-specific, deliberate); the shift follows | L |
| Editing: line endings value | "macOS / Unix (LF)" | "Unix (LF)" | wording | L |
| Editing: second "When Editing" row | "Trim whitespace-only lines" | "Including whitespace-only lines" | **wording differs** for the same setting | M |
| Components: structure | a "Ycode Simulator" navigation card (green icon), then "Installed (read-only)" with "None found" and a "Simulator Runtimes…" push button (grey bezel, black text) | no Ycode Simulator card; "Installed" with a centred empty state ("No Components" and two lines of help) and a "Simulator runtimes" row whose button has **blue text** | structure, wording and button style | H |
| Simulators page | Settings ▸ Components ▸ Ycode Simulator: the simulator-host settings | none (`SettingsPaneOrder.notOnLinux`); the Linux IDE sets the host in the runtime wizard | page missing by design; see §11 | M |
| Pop-up value ink | "Use System Setting" ink 145 wide (text and well) | 114 (text only; the well drawn apart) | how the well is drawn; values end within 3 | L |

**Status after B5-SETTINGS (2026-11-07).** Measured again with the same
shots and `measure5.py`: Components went from 13 shared texts (4 on one
side only, a different structure) to 24 shared, none moved more than 2
points, one side-only text each (the built-in platform's name, "macOS" or
"Linux", by the platform rule); Editing from 3 one-side texts to 1 (the
window buttons on macOS; the "abc" icon text on Linux); General unchanged
(its help text is worded per platform, so the cards below it sit 13
higher). Closed: the sidebar divider (Linux now #D4D4D4 / #414142 at
x 179), the line-endings wording ("macOS / Unix (LF)" on both), "Trim
whitespace-only lines" on both, Components' structure and buttons (round 5's
two sections on both), the Simulators page (the host page on both). The
title is 15 points on both ("General" 54.5 × 12 on macOS, 54 × 12 on Linux).
Open: the window buttons and the scroller (OV-1, OV-3) and the sidebar
glyphs (OV-6); the pop-up's drawn well (L).

## 11. Simulator runtime wizard, host step (group B)

Owners: macOS `YcodeUI/Window/RuntimeSetupWindowController.swift`,
`SetupAssistant.swift`; Linux `ycode-ide/RuntimeSetupSheet.swift`.

| Element | macOS | Linux | Difference | Sev. |
|---|---|---|---|---|
| Container | its own 760 × 600 window | a 760 × 600 sheet over the main window (veil, a second card shadow behind it) | structure | H |
| Step dots | seven grey rings, the current one larger | seven: green dot, orange diamond, rings, orange diamond (states of the checks) | dots carry state on Linux only | M |
| Icon, title, text | the processor glyph, "Simulator Host" 22 pt bold, two lines of help | the same, 2 points lower | — | L |
| Fields | Host, Data folder, Link name 320 wide; Ports 120 wide; monospaced placeholders | all four 340 wide, rounded 8-point fields | widths; field style | M |
| Check Host button | none | "Check Host" (accent-tinted bordered button) | element on Linux only | M |
| Status | "Not checked yet." and the Apple-software note | a grey card with an error glyph, "Host", "Name the simulator host …" | status presentation | M |
| Buttons | Back (left), Re-check, Continue (grey, disabled) | Back, Close, Re-check, Continue (**accent, enabled**) | Close only on Linux; Continue's state | M |

**Status after B5-SETTINGS (2026-11-07).** The Linux wizard is a window of
its own (760 × 600 under its in-window menu bar), as on macOS; both draw the
host form the same (`RuntimeSetupLayout`: right-aligned labels in a
112-point column, fields 320 wide and Ports 120, 22 tall, radius 6 with a
1-point border, monospaced 12-point text); Linux has no Check Host (the
fields are committed by Return, Continue, Back and Re-check, as macOS
commits them when editing ends) and its footer buttons take the macOS
widths. Measured: the four labels' ink ends within 2 points of macOS and
2 lower. The dots are one drawing on both; they and the status differ only
by state (the audit's macOS shot had not run the checks). With B5-OPENVIEWS
merged, the Linux window has a hidden title bar showing only the close
button, the content's size and the menus on demand (no in-window menu bar),
as the macOS wizard window; the Close button is gone. Open: none in this
step beyond the checks' state.

## 12. Merge alert and sheet (group C)

Owners: macOS `YcodeUI/SourceControl/MergeAlertView.swift`,
`MergeOverlay.swift`, `MergeSheetController.swift`; Linux
`ycode-ide/MergeAlertCard.swift`, `MergeOverlay.swift`,
`MergeSheetView.swift`, `MergeComparisonView.swift`.

| Element | macOS | Linux | Difference | Sev. |
|---|---|---|---|---|
| Alert frame | 420 × 133 card at y 374, centred | the same (y 373) | 1 | — |
| Alert icon | the system's blue folder icon (the repository folder's) | the Ycode app icon | icon | M |
| Title | 13 pt semibold, "Are you sure you want to merge from / "feature"?" | the same wrap and ink (228 against 237 wide) | — | L |
| Message wrap | "… into your / current branch ("main")." (ink 253 wide) | "… into your current / branch ("main")." (278) | wrap point (Inter is narrower) | L |
| Merge button | grey in this capture (the accent appears 400 ms after the alert on a key window) | accent #007AFF filled | timing or key state; to check with an active window | L |
| Veil | light #C7C7C7, dark #181819 over the window | light #CBCBCB, dark **#0B0B0B** | dark veil darker on Linux | M |
| Sheet | frame, file list, panes, gutter tokens, shading, footers and jump bar match (5 of 14 shared texts moved more than 2 points, all by font face) | the same | — | — |
| Sheet source text | system monospaced, keywords regular | Noto Sans Mono (keywords read heavier) | face (§4) | L |
| Parent window under the sheet | traffic lights grey; toolbar glyphs dimmed | no window buttons; toolbar dimmed | §2 | — |

## 13. Device window (group C)

Owners: macOS `YcodeUI/Window/DevicesController.swift`,
`DeviceHubToolbar.swift`, `DeviceInspectorCard.swift`; Linux
`YcodeRemoteViewer/DeviceWindowChrome.swift`,
`YcodeRemoteViewerSDL/RemoteDeviceWindow.swift` (`ycode-sim-viewer`).

Evidence from Ycode's code (the Linux device window needs a running
simulator host, which this audit did not use).

| Element | macOS | Linux | Difference | Sev. |
|---|---|---|---|---|
| Window | the device hub: sidebar of devices (Search, "Available", rows with glyph, name, version), toolbar (keyboard, display, zoom group, compact, More), the device canvas, the settings inspector (Appearance, Liquid Glass, Color Filter, Text Size, switches, Location, Sound, Output, Input) | `ycode-sim-viewer`, an SDL window drawn without a toolkit: the device and its bezel, the floating control capsules (`DeviceControlsLayout`, shared), a More Actions circle at the top right with a menu | sidebar, toolbar and inspector missing on Linux; settings reachable only through the More menu's commands | H |
| Control capsules | below the canvas, light #E6E6E6-class with dark glyphs (y 755–792 at 1100 × 800) | the same layout from `DeviceControlsLayout`, drawn in SDL with `ViewerPalette` | shared layout; drawing apart | L |
| Toolkit | AppKit | none (SDL primitives): no OpenViews text, focus or accessibility | not an OpenViews window | M |

**After B5-MERGE (2026-11-07).** §12: the macOS alert shows Ycode's own
icon in every process (the parity capture's folder icon was the test host's
generic icon); the Linux window dims over its window background
(`MergeModalTone.backdrop`, #1E1E1E / #ECECEC), not black; both IDEs draw
the round 5 buttons, focus colours and ruler from the shared model; the
macOS sheet is a window of its own below the parent, the Linux sheet is
still cut at the window (OpenViews has no child window that may extend past
its parent). §13: the Linux device window has the macOS window's toolbar,
canvas, capsules and Settings inspector (`DeviceWindowFrame`, drawn with
OpenViews); left: the sidebar (one device per window), the live settings,
the More menu's bitmap font, the glyphs OpenViews lacks (drawn by Ycode).

## 14. Top 15 differences

1. **Editor line pitch 18 against 16** (§4): every source row and the
   visible line count differ. A.
2. **Source font and column** (§4): system monospaced 8.0 against Noto
   Sans Mono 7.8 per column; the code column at 342 against 349. A.
3. **No image editor on Linux** ("Binary file") (§4). A.
4. **No editor panes on Linux** (split) (§4). A.
5. **Toolbar capsules not filled on Linux** (#ECECEC / #3A3A3A against
   outlines) (§2). D.
6. **Navigator and inspector fills** #F2F2F3 / #252627 against #FBFBFB /
   #1C1C1C (§3, §5). D.
7. **Toolbar at 1100 points overlaps on Linux**: no compaction (§2). D.
8. **Window buttons missing on Linux** in every window (§2, §10, §15).
   OpenViews.
9. **Inspector labels and pop-ups**: grey labels and capsule pop-ups with
   truncated values on Linux, black labels and borderless pop-ups on macOS;
   Working Copy and Relative Path missing (§5). D.
10. **Scheme and destination capsule**: semibold text and up-down chevrons
    on Linux, regular text and glyphs on macOS; 47 wider (§2). D.
11. **Welcome**: a panel in the main window on Linux; app name 34 pt bold
    against 18.5 pt semibold; the close button without its circle (§9). D.
12. **Settings ▸ Components**: different structure, wording and button
    (§10). B.
13. **Device window**: the hub on macOS, the bare SDL viewer on Linux
    (§13). C.
14. **Navigator indentation** 14 against 12 per level, and **no row
    selection** for the open file on Linux (§3). D.
15. **Selected-state tint**: Linux tints the selected selector glyph,
    inspector tab, Changes | Repositories segment and debug toggles with
    the accent; macOS draws grey pills (§3, §5, §6, §7). D.

## 15. Differences that come from OpenViews (the toolkit)

These need OpenViews (`frameworks/swiftui`) changes, not Linux IDE
changes:

| # | Gap | Effect in the IDE | Sev. |
|---|---|---|---|
| OV-1 | No window decorations: a window has no close, minimize and zoom buttons, and the app's menus are an in-window menu bar 26 points tall | every Linux window lacks the three buttons; the main window is 26 points taller than its content | H |
| OV-2 | No sidebar material: `List`/sidebar backgrounds are flat fills chosen by the app | the IDE picks #FBFBFB / #1C1C1C where AppKit's material gives #F2F2F3 / #252627 | M |
| OV-3 | No scroll indicators at rest (AppKit shows its scroller when the system says so) | no scroller beside the minimap, the debug panes, Settings | L |
| OV-4 | UI font: Inter (bundled) for the system face; small sizes run narrower than the macOS face (11 pt: 8–13 % narrower ink; 13 pt: equal) | jump bar, alerts and pop-up values wrap and truncate differently | M |
| OV-5 | Control styles: `TextField` draws a bordered box, `Picker` a filled capsule, `Stepper` small circles, `Button(.bordered)` tints its title with the accent, segmented `Picker` fills the selection with the accent | the inspector's Name, pop-ups and steppers; Components' button; the Changes \| Repositories control | M |
| OV-6 | Symbols: OpenViews' own artwork stands in for system symbols; several glyphs differ in shape or are filled where the system's are outlined | selector glyphs 2 and 3, branch glyphs, Settings sidebar icons, the repository glyph | M |
| OV-7 | No document-window concept for a second top-level window of the same kind without a menu bar (Welcome is drawn inside the main window) | Welcome's structure (§9); the runtime wizard as a sheet (§11) | M |

## 16. Totals

| Area | Group | H | M | L |
|---|---|---|---|---|
| Window frame and toolbar | D | 4 | 8 | 1 |
| Navigator | D | 1 | 7 | 2 |
| Jump bar and editor | A | 5 | 8 | 1 |
| Inspector | D | 4 | 7 | 1 |
| Debug area and bottom bar | D | 0 | 5 | 3 |
| Source Control navigator | D | 0 | 4 | 2 |
| Empty states | D | 0 | 1 | 1 |
| Welcome | D | 2 | 3 | 1 |
| Settings | B | 2 | 4 | 6 |
| Runtime wizard host step | B | 1 | 5 | 1 |
| Merge alert and sheet | C | 0 | 2 | 4 |
| Device window | C | 1 | 1 | 1 |
| **All** | | **20** | **55** | **24** |

By group: A (editor and theme) 5 H, 8 M, 1 L; B (Settings) 3 H, 9 M,
7 L; C (merge and device windows) 1 H, 3 M, 5 L; D (main-window chrome)
11 H, 35 M, 11 L. OpenViews-level: 1 H, 5 M, 1 L (§15; they also appear
in the areas where they show).

## 17. Reproducing

macOS: `cd ycode && YCODE_B5_PARITY_DIR=$PWD/.build-ide/b5-parity swift
test --filter CrossPlatformParityShotTests`. Linux: build `ycode-ide`, then
`scripts/linux-ui-parity/run-parity5.sh <ycode-ide> <work folder> <shots
folder>` with the Wayland and `OV_SDL3_LIBRARY` variables set. Then
`python3 -I scripts/linux-ui-parity/measure5.py <folder with both>
<out>` writes the pairs, the text tables and the one-side-only lists.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Every macOS value | 1 | Ycode's macOS IDE drawn by the window server (`CrossPlatformParityShotTests`, 2026-11-07) and its view dump (frames, fonts, declared colours) |
| Every Linux value | 1 | Ycode's Linux IDE on OpenViews (`YCODE_IDE_PARITY5`, x86-64 Wayland, SDL back end, scale 1) and its `Text` and identified-view dump |
| Line pitch, code column, advance, font sizes, indentation, toolbar sizes | 1 | Ycode's code: `EditorMetrics`, `SourceEditorController.lineHeight` (Linux), `NavigatorAreaController.indentation`, `WorkspaceChrome`, `ShellFonts`, `ShellColors`, `WelcomeView`, `WelcomeWindowController` |
| Device window | 1 | Ycode's code: `DevicesController` and the shot; `DeviceWindowChrome`, `RemoteDeviceWindow` |
| Measuring | 1 | `measure5.py` (ink boxes, nearest-frame pairing, median fills) |
