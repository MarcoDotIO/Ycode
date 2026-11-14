# Workspace window

Ycode module: `YcodeUI` (`WorkspaceWindowController`, `WorkspaceSession`).

## Opening

A workspace window opens one container: an `.xcodeproj`, an
`.xcworkspace`, a `Package.swift`, or a folder that contains
`Package.swift`. One container per window. Saving (⌘S) writes edited source
files and any changed project through the byte-exact pbxproj writer
(`specs/formats/pbxproj.md`); unchanged projects are not rewritten.

## Areas

```
+--------------------------------------------------------------------+
| toolbar                                                            |
+-----------+-------------------------------------+------------------+
| navigator | jump bar                            | inspector tabs   |
| selector  | editor (gutter | text | minimap)    |                  |
| bar       |                                     | inspector        |
|           +-------------------------------------+                  |
| content   | debug bar                           |                  |
|           | variables view   |  console         |                  |
| filter    |                                     |                  |
+-----------+-------------------------------------+------------------+
```

| Area | Toggle | Ycode default |
|---|---|---|
| Navigator (left, sidebar) | toolbar / View ▸ Navigators (no default shortcut; ⌘0 is Show Coding Assistant) | shown, 290 pt |
| Inspector (right) | toolbar / View ▸ Inspectors (no default shortcut) | shown, 260 pt (observed in pass 5 and in council round 1, `liquid-glass.md` §7) |
| Debug area (below editor) | ⇧⌘Y | hidden; shown when a debug session starts or on ⇧⌘C |
| Toolbar | ⌥⌘T | shown |

Default window frame 1400 × 900 pt including the toolbar
(`reference-ui.md` §2, `reference-ui-5.md` §3.3); the frame is remembered
per container. The window title (Window menu, Mission Control) is
"<workspace> — <document>" (`reference-ui-5.md` §3.4).
Menu titles for toggles read "Show …" or "Hide …" by current state.

## Toolbar

Superseded by the toolbar layout in the Evidence notes below and
`reference-ui-5.md` §4. The default toolbar has no Library button, and the
activity area shows no subtitle while idle. Ycode's earlier layout was:
navigator toggle; Run (▶, ⌘R) and Stop (■, ⌘.); the scheme pop-up and
run-destination pop-up joined by a chevron; the activity view; Library (+,
⇧⌘L); inspector toggle.

Activity view (no text while idle; correction 2026-10-19): container
name, then status text ("Building …",
"Compiling main.swift", "Build Succeeded | Today at 9:53 PM", "Running …",
"Paused: breakpoint"), then error and warning counts with their symbols.
A progress bar shows while busy.

Scheme list: shared then user schemes of the container (and of each project
in a workspace); if a project has none, one per target. Package: one scheme
named after the folder. Destinations: "My Mac" (`platform=macOS`),
"Any Mac" (`generic/platform=macOS`).

Run: build; ask `xcodebuild -showBuildSettings -json` for the first
application/tool target's `TARGET_BUILD_DIR/EXECUTABLE_PATH`; launch it
under lldb-dap (`specs/ide/debug.md`).

## Inspector area

Tabs for a source file, in order: File (⌥⌘1), History (⌥⌘2), Quick Help
(⌥⌘3). File inspector sections: Identity and Type (Name, Type, Location,
Full Path) and Text Settings (Text Encoding, Line Endings, Indent Using).

## Debug area

A debug bar (hide debug area, activate/deactivate breakpoints,
pause/continue, step over, step into, step out, current frame), then the
variables view on the left and the console on the right, split evenly.
While stopped, the variables view lists the non-expensive scopes of the top
frame and the editor highlights the stopped line.

## Icons

Ycode uses SF Symbols through the public runtime API only, and never a
trademark-shaped symbol: no Swift bird (`swift`), Apple logo, or Xcode
hammer. Swift files and package manifests use
`chevron.left.forwardslash.chevron.right`; projects use
`folder.badge.gearshape`; workspaces `square.stack.3d.up`; the build
system issue group `gearshape.2`. A test enforces this (CLAUDE.md rule 5).

## Council round 7 (2026-11-08): reopen, the toolbar under a sheet, the inspector, Add Editor, Welcome

Round 7's captures: Retina, 120 fps, foreground, key window, the system
in **Dark**, Ycode `0afb3bd7`; the host's 1-minute load was **250–700**,
so durations below are approximate and load-affected. Values in window
points. Checklist rows 186 and 188–194 in `fidelity-council.md` (row
187, the navigator's expansion on reopen, is in `navigators.md`).

### W7.1 Restoring a workspace on reopen (X15 → R01)

The extra session's last steps left the GlassScroll copy with a split
editor (Long.swift on the left, **Model01.swift on the right, active**),
the file inspector shown, Plain and Sub expanded and Models collapsed
(X15), then closed the workspace window (File ▸ Close Window) and quit.
The reopen session opened that same copy in a **new instance** of each
app, launched with saved window state ignored (both apps).

| Restored | Reference | Ycode now |
|---|---|---|
| Window title | "GlassScroll — Model01.swift" | "GlassScroll — GlassScroll.xcodeproj" |
| Editors | **the split**: Long.swift in the left pane at its line 1, Model01.swift in the right pane, the right pane active (its current-line highlight on line 1), two panes of about equal width as before | **no editor**: the jump bar reads "No Selection", no split |
| Inspector | **shown, File tab**, describing Model01.swift (Name, Type, Full Path, Text Settings …) | shown, the File tab reading **"Not Applicable"** |
| Navigator | see `navigators.md` (round 7) | — |

**Is Ycode's missing editor restore real, or the capture's?** Real. Both
apps were launched with the same flag (saved window state ignored), and
the reference restored its editors anyway: it keeps that state in the
project's per-user data, not in the system's window restoration. Ycode's
per-workspace user data (`WorkspaceUserState`: recent files, expanded
rows, run destinations, the debug area's height, kept in the project's
per-user folder) has **no field for the open editors, the split or the
inspector**, so there is nothing to restore whatever the launch flags;
the capture's deletion of Ycode's own preferences domain at launch
touches only window frames and app settings. The navigator's expansion
was restored from that same file, which shows the file was written and
read. (Read from Ycode's own source and the capture tool's launch code.)

**Target:** keep, in the per-workspace user data, the editor layout
(each pane's document, its scroll position and selection, the split's
direction and proportions, which pane is active), the inspector's
visibility and tab, and restore them when the workspace opens, whether
or not the system's window restoration is on; the window title follows
the active pane's document.

### W7.2 The toolbar while the merge sheet is up (conflict 03)

| Item | Reference | Ycode now |
|---|---|---|
| Issue capsule | present: x **813.5–872** (58.5 wide), **7.5** after the scheme capsule (gap 804.5–812 at the toolbar band's colour); a red circle with a white cross x 828.5–845, then "1" at 854; drawn **dimmed** with the rest of the toolbar (circle #6F2A27, cross and count #6F6F70) | **none**, though the jump bar's issue stepper shows the error |
| Activity subtitle (row 141) | **present**: the title "Merger" ink y 14.5–26.5, under it **"Indexing Text"** ink y 29.5–40, both from x 411.5; under the sheet the title is #6F6F70 and the subtitle #525252 | none: the title alone, vertically centred (ink y 21.5–33.5) |
| Toolbar items | all dimmed (the leading capsule's glyphs about #464646, the run button the same) | dimmed, a little lighter (about #5C5C5C) |
| Traffic lights | **close grey (#4D4D4E), minimize yellow (#FDC000), zoom green (#31BF00)** | **the same** (#484949, #FDC000, #31BF00) |

The judge's "Xcode's traffic lights are grey and Ycode's coloured" is
not borne out: both apps grey only the close button while the sheet is
up (the first still and the comparison sheet agree pixel for pixel);
what is greyer in the reference is the toolbar's items. **Targets:** the
issue capsule whenever the workspace has issues, the merge included
(G.8, H.5, row 161; it shows in the same states as the jump bar's
stepper), dimmed with the toolbar under a sheet; the activity subtitle
(row 141: a second line under the title naming the current activity, in
Ycode's own words, while the workspace indexes or prepares its editor
services; the title moves up to make room); no change to the traffic
lights.

### W7.3 Hiding the inspector under load (main 10; refines `editor-area.md` H.2)

The inspector's left edge at y 700 per recorded frame, from the press:

| Reference ms | 93 | 109 | 127–150 | 166 | 184 | 208 | 227–242 | 259 |
|---|---|---|---|---|---|---|---|---|
| edge | 1168 | 1180 | 1231 | 1280 | 1332 | 1344 | 1393 | 1400 (gone) |

Ycode: no change for **720 ms** after the press, then **99.5 % of the
change in one frame** (the capture tool's segment: 180 ms, 3 frames,
the rest a small settle). In round 6, at a light load, Ycode's hide took
the reference's time (H.2). So under load the reference still plays its
slide (about 150 ms, 7 positions, from about 100 ms), while Ycode's
starts late and arrives at its end at once: its animation's clock
evidently starts at the press, so a late first frame finds the curve
already over. **Target:** H.2's hide (about 195 ms, ease-out) measured
from the **first frame the animation draws**, or run by the window
server's own animation so that the main thread's delay cannot skip it;
never jump to the end because the start was late. The ~150 ms between
the two apps' durations is at the load caveat's threshold; the snap is
not.

### W7.4 Add Editor: the press (main 16; refines `editor-area.md` H.8)

Mean brightness of a 90 × 44 area round the Add Editor button, per
frame, from the click:

| | Reference | Ycode now |
|---|---|---|
| Menu-open state | 74.5 → **77.8 at once** (86 ms) | 65.0 → 68.4 at once (50 ms) |
| The pressed flash | **one frame** at 102.0 (469 ms), the next frame already 79.1 | 93.1 at 1048 ms, **held about 70 ms**, then 85.7, 84.3, 83.1 (to 1183), 78.9 (to 1263), 73.7 (to 1337), 70.7 (to 1486), 68.8, 68.4 by about 1650: a **fade of about 450–600 ms** |
| After the flash | 79.1, 78.3, 78.0, 77.8 over about 200 ms | — |

In dark the reference's pressed frame is lighter (in light, round 6, it
was darker): the same pressed tint. **Target:** the pressed tint for
**one frame** (about 15 ms), then straight back to within about 1.5 of
the menu-open level, settling over about 200 ms; no long fade (row 164
restated with this round's values).

### W7.5 The file inspector's Widths row (X08–X10; a judge's claim, measured)

The 1180 window, inspector x 920–1180 (the accessibility tree's frames
and the still):

| Part | Reference | Ycode now |
|---|---|---|
| Tab width | a **text field** x 1003–1067 (**64 × 21**) showing "4" right-aligned, then a stepper x 1067–1086 (**19 × 24**) | a bare "4" (9.5 wide) at x 1003, then a stepper x 1018.5–1037.5 (19 × 22) |
| Indent width | a text field x 1091–1156 (**65 × 21**), a stepper x 1156–1175 (19 × 24) | a bare "4" at x 1043.5, a stepper x 1059–1078 |
| Labels under them | "Tab" (ink 16.5 wide, x 1029.5–1046) centred under the Tab field, "Indent" (30 wide, x 1111.5–1141.5) under the Indent field; cap height 8 | "Tab" 14.5 wide at x 1013–1027.5, "Indent" 26 wide at x 1048–1074: about **0.87** of the size, centred under the steppers |

**Target:** the reference's two editable fields with their steppers
filling the value column (field 64–65 wide, stepper 19 × 24, 4 apart),
each label at the inspector's label size centred under its field.

### W7.6 The Welcome window's recent row (main 18; refines `editor-area.md` H.10)

The selected row (fill x 528–872 in both):

| Part | Reference | Ycode now |
|---|---|---|
| Title "GlassScroll" | ink x **576.5**–642.5, y 362.5–372.5 (66 wide) | x 582.5–651.5, y 360.5–370.5 (69 wide): 6 right, 2 higher, about 5 % larger |
| Path | **whole**: "/private/tmp/ycode-council-r7/council-r7/xcode/project", ink x **576–840.5** (264.5 for 54 characters: about **4.9 per character**), y 379.5–388.5, #B3CEF1 on the selection | **cut at its start**: "…ate/tmp/…/ycode/project", x 583–856 (273 for 51 characters: about 5.35 per character), y 376–386.5 |
| Right inset of the text | 31.5 to the row's end | 16 |

Ycode's path font is about 9 % larger and its text starts 6 points
further right, so the same path does not fit and Ycode cuts its head.
**Target:** the reference's title and path sizes and x (text 48.5 from
the row's left), so this path fits whole. Where the reference cuts a
path that does not fit was not seen (the path fitted); until it is,
cut in the **middle**, keeping the leading folders and the project's
folder (the platform's convention for paths).

The row's icon in Ycode is the system's document icon for the project
type, which the system takes from the installed reference app: a piece
of the reference's artwork in Ycode's window (AGENTS.md rule 5). Owner's
attention: Ycode should draw its own project icon there.


### W7.7 Ycode implementation (B7-D, 2026-11-08)

- **W7.1:** `WorkspaceUserState` gains `editorLayout` (each pane's file,
  first visible logical line and UTF-16 selection; the split's direction
  and shares; the active pane) and `inspector` (shown, tab), written when
  the window closes or the app quits and read when the workspace opens
  (`WorkspaceEditorLayout`, both IDEs). A missing file leaves its pane
  empty; the navigator selects no row on reopen. The Linux panes share
  the split equally (they have no divider to drag) and save equal shares.
- **W7.2:** a file git reports as conflicted is one workspace error at its
  first conflict marker ("Unresolved merge conflict", `ConflictIssues`),
  so the capsule shows in the same states as the jump bar's stepper,
  under the merge sheet too, where its parts fade to the glyphs' disabled
  tone (0.33) while the rest of the toolbar takes the text tone. The
  activity subtitle reads "Indexing files" while the language server
  reports work-done progress (`$/progress`; the client now asks for it).
- **W7.3:** `InspectorSlideClock`: a first frame later than the motion's
  start begins the motion there; a stalled frame advances the curve by at
  most 1/30 s. The Linux slide is the toolkit's animation, begun when the
  motion starts (not measured under load).
- **W7.4:** not changed. Add Editor is the system's menu toolbar item; its
  pressed tint and fade are the system's drawing, and a custom item would
  leave the shared glass group with Editor Options.
- **W7.5:** `InspectorWidthsRow`: editable fields (64–65 × 21) with 19 × 24
  steppers, labels 10.3 points centred under the fields; the row runs 3
  past the other rows' value column.
- **W7.6:** `WelcomeRecentRow`: title 12.4 semibold, path 10, the text 6
  left and 2–3.5 lower than before, cut in the middle, #B3CEF1 on the
  (accent) selection; the row's icon is Ycode's mark (the package glyph
  for packages), never the system's document icon.

## Evidence

- Correction 2026-10-19: area toggles without default shortcuts, the
  frame size, window title, toolbar exclusivity and tooltips, and the idle
  activity area: `reference-ui-5.md` §2.0, §3.3–§3.4, §4 (level 3).
- Area names, toggles and shortcuts (⌘0, ⌥⌘0, ⇧⌘Y, ⇧⌘C, ⌘R, ⌘., ⇧⌘L):
  Apple's public Xcode Help and keyboard-shortcut reference (level 1).
- Toolbar content (run/stop, scheme/destination, activity view, library,
  inspector toggle): Xcode Help and WWDC session descriptions (level 1).
- Inspector tab order for source files: Xcode Help (level 1).
- `-showBuildSettings -json`: `man xcodebuild` and black-box runs (level 3).
- OPEN QUESTION: default area widths/heights and window size (ours are
  guesses).
- Toolbar layout (reference-ui.md §2, §5, level 3): Navigators / Coding
  Assistant two-segment control at the left, Run/Stop, Back/Forward, the
  workspace name with the activity as a second line under it, the
  centered scheme › destination pill (re-centered by the inspector
  tracking separator when the inspector toggles), Canvas / Assistant /
  Code Review three-segment control, Show Inspector at the far right.
- Debug area (reference-ui.md §5, level 3): opened on run output or a
  pause, hidden on completion only when the run printed nothing; split
  50/50 between variables and console. Variables bar: scope pop-up
  (Auto), registers and info toggles, filter. Console bar: debugger and
  target output toggles, filter, clear, show/hide each half. Debug bar:
  breakpoint activation at the left, "Line: N Col: N" and a show/hide
  toggle at the right.
- File inspector (reference-ui.md §6, level 3): Name (editable; renames
  the file only in package workspaces), Type, Location with a chooser,
  Full Path with reveal, Text Encoding "No Explicit Encoding", Line
  Endings "No Explicit Line Endings", Indent Using, Tab/Indent steppers.
- OPEN QUESTION: exact activity-view status strings and date format.
- Window 1400 × 900, navigator 290, inspector 260, debug area 135 points
  (reference-ui.md §2, §5, §6). The debug bar sits under the editor and
  stays when the debug area is hidden; Continue and the step buttons show
  only during a debug session.
- Issue capsule (reference-ui-2.md §2): right of the scheme pill, errors,
  warnings and failed tests; zero counts left out, hidden when empty. The
  activity line after an action is "<Result> • Today at <time>" ("Test
  Completed" for a test run with failures; "Finished running
  <product>").
- OPEN QUESTION: autocreated scheme names for packages with several
  products.
- Council round 7 (W7.1–W7.6), level 3: the round 7 stills and 120 fps
  recordings of both apps (dark; host load 250–700) and the capture
  tool's accessibility trees; the reopen session's stills of the copy
  the extra session left; colour samples, ink boxes and region means per
  frame; the inspector's edge per frame at y 700; times against the
  session manifests. Whether Ycode's missing restore is real was decided
  from Ycode's own source (`WorkspaceUserState`) and the capture tool's
  launch code (our code), not from the reference. Measured in the dirty
  room; prose only here.
