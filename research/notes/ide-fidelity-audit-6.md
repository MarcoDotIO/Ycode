# IDE fidelity audit, pass 6 (2026-10-27): Xcode 27.1 vs Ycode at 5f74ef9

Dirty-room notes (prose and tables, no code). They hold the black-box
observations of this pass (evidence level 3, level 2 for files the
reference wrote) and the side-by-side comparison with a debug build of
Ycode at 5f74ef9. The boundary spec written from them is
`specs/ide/reference-ui-6.md`. No colors were recorded and no assets
were copied. Screenshots are in `research/dirty/ide-audit6/` (not
committed).

## 0. Method and limits

- **Reference.** `/Applications/Xcode.app`, Xcode 27.1 (27A9269), on the
  main display (3440 × 1440). Ycode: `YcodeApp` debug build from the
  `ide-audit6` worktree, wrapped in an app bundle with its own bundle
  identifier (clean user defaults), build output on the internal disk.
- **Samples** (ours, in `<samples>/ycode-observe-audit6/`):
  - `AuditApp`: made by the reference itself. Welcome ▸ New Project ▸ App
    created an untitled project (see §1.1); it was copied here, the
    `.xcodeproj` renamed, and a `Model.swift`, a `Notes.txt` and a git
    repository (one commit) added.
  - `AuditPhone`: a copy of `AuditApp` restricted to iOS (three build
    settings changed) so that the reference would pick a simulator.
  - `AuditPkg`: `swift package init --type library`, two passing
    swift-testing tests, a git repository.
- **Control.** The owner interrupted every attempt to take over the
  screen (four times), so the whole pass ran in the background:
  - Reference (click tier): accessibility tree, window screenshots and
    zooms, plain clicks on buttons, tabs and segments, the menu bar
    *listed* (titles only, no shortcuts, not validated because the
    reference was not frontmost). No menu was pressed, no pop-up or
    pull-down opened except where a plain button opened one, no typing,
    no right-click. Files were opened with `open -g -a Xcode <file>`.
  - Ycode: the same tools. Background clicks on outline and table rows
    and background keystrokes were refused by the tool, and Ycode's own
    menu items are disabled while it is not the active app. To open
    files and send commands, the scratch build carried an audit-only
    hook (a distributed notification that calls the window controller's
    `open(path:)` or sends an action selector). The hook was added to the
    scratch build only and removed from the source right after the build;
    nothing of it is committed. It changes no UI.
- **Not observed** (each needs the frontmost window, keystrokes or
  pressed menus): context menus; every pop-up and pull-down except the
  Welcome window's New Project and the assistant's New Conversation;
  Settings (no pane could be opened); Open Quickly, Quick Actions, the
  Library, the find bar and the completion popup (all need a menu press
  or typing); the Edit menu's Copy/Paste variants and all modifier
  alternates; Help ▸ Show Keyboard Hints; Copy File and Line's text; the
  project editor (selecting the project row is refused in the
  background); ⌘0 as a keystroke; a whole-scheme test run (⌘U).

## 1. New observations of the reference

### 1.1 Welcome window and New Project

- The Welcome window's New Project pull-down lists: App, Command Line
  Tool, Package…, Playground, a separator, Choose Template….
- **New Project ▸ App** shows no sheet. It creates and opens at once an
  untitled project:
  - window "Untitled Project", saved under the user's Library
    (`Developer/Xcode/UntitledProjects/Untitled Project/`);
  - one target "MyApp" in a synchronized folder "MyApp" with Assets,
    ContentView, MyApp; `MyApp.swift` open in the editor, caret at 1:1;
  - the inspector is hidden; destination My Mac;
  - the project file (level 2): `objectVersion = 90`, `SDKROOT = auto`,
    `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx xros xrsimulator"`,
    `TARGETED_DEVICE_FAMILY = "1,2,7"`, deployment targets 27.0, and a
    placeholder bundle identifier built from `$(PROJECT_UNIQUE_VALUE:identifier)`
    and `$(PRODUCT_NAME:rfc1034identifier)`. ContentView holds a
    `#Preview` and a `#Playground` block.
  - Closing that window asked nothing. The Welcome window had closed when
    the project opened from it.
- Geometry (window 480 × 632): round close button 36 × 36 at (20, 20);
  the three buttons are 107, 107 and 130 wide, 36 tall, 8 apart, a row
  of 360 centered at y 242; the recent list sits in an inset rounded box
  and has no visible heading (only its accessibility name). A package
  row uses a package glyph.
- Launching the reference by opening a project (`open -a Xcode
  <project>`) showed only the workspace window, no Welcome window.

### 1.2 Workspace window just opened (AuditApp, no user data)

- Accessibility title "AuditApp — AuditApp.xcodeproj"; frame 1400 × 900.
- Toolbar, left to right, with frames in window points:
  - Navigators | Coding Assistant: two segments 37 × 35 in one capsule
    at x 94;
  - Run | Stop: 36 × 35 each in one capsule at x 205;
  - Go Back | Go Forward: one capsule at x 292;
  - the activity view (project icon, name, subtitle);
  - New Conversation (39 wide) at x 559;
  - the scheme capsule: "Active Scheme" (86) and "Active Run
    Destination" (91) pop-ups, starting x 606; the destination shows a
    device icon and the device name only ("My Mac", "iPhone 18 Pro"), no
    OS version;
  - the issue capsule "⚠ 1" (64 wide); after a failing build it holds
    two buttons, "Errors" and "Issues";
  - the cloud-notices button (projects only; absent in a package
    window);
  - Add Editor (44) and Editor Options (40) in one capsule;
  - Canvas | Assistant | Code Review: 41, 40, 41 wide in one capsule
    ending x 1112;
  - Hide Inspector (39 × 51) at the far right, x 1329, above the
    inspector.
- Navigator selector: nine tab buttons 28–34 wide, 27 tall, in one
  capsule (270 × 29) at y 50.
- Project navigator: the project row and the synchronized folder
  expanded; rows 22 tall; Swift files with a Swift glyph; first row at
  y 86.
- Editor area: jump bar "⊞ | No Selection" with, at its right, ‹ (Show
  Previous Issue), a severity glyph menu ("Issues", 20 wide, no text)
  and › (Show Next Issue); below it an empty editor. **No Start Page.**
- Inspector shown (File tab), "Not Applicable" centered.
- Debug bar: Breakpoints (left), "main" branch button, "show debug area"
  (right). The debug-area button's accessibility title follows the
  state: "show debug area" while hidden, "hide debug area" while shown.
- The issue capsule counted one project-level warning ("Update to
  recommended settings", directly under the project root). No live
  issue was shown for the open file before the first build.

### 1.3 File open (Model.swift)

- Jump bar: AuditApp › MyApp › Model (no extension, Swift glyph) › No
  Selection. Debug bar "Line: 1  Col: 1"; the caret is at 1:1 after
  opening.
- Minimap at the editor's right edge (about 126 points for an 816-point
  editor, 62 points for a 418-point split). The owner's preferences hold
  a minimap key, so this is not proof of the factory default.
- File inspector: thin rules separate the sections. Location is a
  disabled pop-up "Relative to Group" for a file in a synchronized
  folder (enabled, with a folder button, for a package file). Target
  Membership is a bordered table (target icon, name, "Default" under it)
  with "+", "−" and a pencil inside the table's bottom edge; "+" is
  enabled. Text Encoding and Line Endings are pop-ups that read "No
  Explicit Encoding" and "No Explicit Line Endings" in the dimmed style;
  Indent Using "Spaces"; Widths: two fields with steppers, captions
  "Tab" and "Indent".
- A package source file has no On Demand Resource Tags and no Target
  Membership section.
- History inspector row: author (bold), subject under it; at the right
  the abbreviated commit hash (7 characters) on the first line and the
  relative date ("Today") on the second.
- Quick Help with the caret not on a symbol: "No Quick Help" and the
  "Search Documentation" button, both centered, a rule below.

### 1.4 Debug area (opened with the debug-bar button while idle)

- It opened about 135 points tall (bar included).
- Variables bar: "Auto" pop-up (borderless, with arrows), Quick Look,
  Print Description, filter (leading filter-options control).
- Console bar: Quick Look, Metadata Options, filter (leading
  filter-options control), Clear Console, the two half toggles.
- The console has no command-entry line while no process is debugged.
  After a stop it printed "Debug session ended with code 9: killed".

### 1.5 Builds, runs and tests: the activity view

| Action | Subtitle sequence observed |
|---|---|
| Run, macOS app | "Build" → "Building • Planning deferred tasks" → "Building • 42/64" … "Building • 113/141" → "Running MyApp"; after Stop "Finished running MyApp" |
| Run with a compile error | "Build" → … → "Build Failed • Today at 1:17 PM" |
| Run, iOS app on a shut-down simulator | "Build" → "Building • 39/61" … → "Launching MyApp" (about 30 s, while the simulator boots; there is no separate boot text) → "Configuring Debugger Actions" (debug bar: "Waiting to attach") → "Running MyApp on iPhone 18 Pro"; after Stop "Finished running MyApp on iPhone 18 Pro" |
| One passing test, from its gutter diamond | "Building • 60/78" → "Configuring Debugger Actions" → "Test Completed • Today at 1:21 PM" |

- While building, the project icon in the activity view is replaced by a
  circular progress indicator. "n/m" is the count of finished build
  tasks out of the planned ones; the total grows during the build.
- Long subtitles are truncated **in the middle** ("Finished r…ning
  MyApp").
- When the toolbar runs short of room (a long subtitle, the two-button
  issue capsule), the reference first collapses the Canvas | Assistant |
  Code Review capsule into one pull-down, then truncates the scheme name
  in the scheme pop-up ("My/›"). The inspector button and the rest of the
  right group stay visible.
- The debug area did not open by itself on any of these runs.
- The issue capsule appears in the middle of a build as soon as the
  first issue arrives.
- A run of one selected test that passed ended in "Test Completed", not
  "Test Succeeded". A whole-scheme test (⌘U) was not possible this pass.

### 1.6 Issue navigator after a failing build

```
AuditApp  1 issue                      (project row)
  ⚠ Update to recommended settings
MyApp  2 issues                        (target row, target icon)
  Broken                               (file row, file icon)
    ⊗ Cannot convert value of type 'String' to specified type 'Int'
  Model
    ⚠ Initialization of immutable value 'unused' was never used; consider replacing with assign…
```

- Issues are grouped by **target**, then by file; file groups are by
  name. A file-less issue sits directly under the project.
- The compiler's message is shown with its first letter capitalized.
- The live issue and the build's issue for the same line and message
  are one row.
- Messages wrap to the "Issue navigator detail" limit (three lines).
- In the editor: the issue's token is underlined; the line is tinted; an
  annotation with the severity glyph follows the code on the same line.
  There is no glyph in the gutter. The jump bar's severity glyph becomes
  the error glyph when the file set has an error.

### 1.7 Canvas, assistant pane, packages, tests

- A SwiftUI file with a `#Preview` opened with the canvas shown at the
  right, 50/50. The canvas showed a "Canvas paused" pill with a refresh
  button at its top and a device pop-up "Automatic – iPhone Duo ⌄" at
  its bottom left.
- Package window: root "AuditPkg" › Package (Swift glyph), Sources
  (expanded) › AuditPkg (collapsed), Tests (expanded) › AuditPkgTests
  (collapsed). Scheme with a package glyph, destination My Mac.
- In a test file the gutter shows a test diamond **in place of** the
  line number on each `@Test` line; after the run the diamond shows the
  result.
- Test navigator: header with the test-plan pop-up "AuditPkg
  (Autocreated)" (194 wide, bordered) and two icon radio buttons; rows
  "AuditPkg 2 Tests" › "AuditPkgTests 2 Tests" › "addition()",
  "greeting()"; result glyphs at the right of every row, the parents
  included.
- Find navigator header: "Find › Text › Containing" as a path with no
  pop-up arrows; "Aa" at the right; the field has a recents control and a
  clear button; the scope reads "In Package" in a package.

### 1.8 Coding Assistant (no account, no model provider configured)

- The toolbar's Coding Assistant segment replaces the navigator with the
  assistant pane:
  - header row at the navigator selector's place: "New Conversation"
    with a chevron (146 wide) and "New Group" (115 wide), both 27 tall;
  - below, the conversation list. With no conversations it holds one
    group row, "Archive" (archive-box glyph, disclosure), which expands
    to nothing;
  - no bottom bar, no filter.
- "New Conversation ⌄" opens a menu: a section label "Agents", then one
  row per installable third-party coding agent, each with a "GET" button
  at the right (three rows). No other item. Nothing was installed.
- The toolbar's New Conversation button opens a popover (about 342 × 146)
  under it: a multi-line prompt with a placeholder that rotates through
  hints ("New conversation with <agent>", tips about slash commands); a
  bottom row with an attach button, an options button and a round send
  button (disabled while the prompt is empty). Clicking the button again
  closes the popover.
- Menus (listed, not validated): File ▸ New ▸ Conversation,
  Conversation in New Tab, Conversation in Editor Pane (the first three
  items); Navigate ▸ Jump to Next Active Conversation; View ▸ Navigators
  ▸ "Show Coding Assistant" (still so titled while the pane was shown)
  and "Show Navigator"; **Editor ▸ Show Coding Tools ▸ holds only "Show
  Coding Tools…"** in this state (pass 5, read in another state, also
  listed Explain, Document, Generate a Playground, Generate a Preview).
  Enabled states could not be read (the menus were not validated).

### 1.9 Menu listings (background, not validated)

- File ▸ New lists "File from Clipboard" (not "New File from
  Clipboard").
- The Edit menu listed Undo … Select All without the Copy and Paste
  variants, while other menus listed their alternates (Run…, "(option)"
  variants in Navigate). The variants are therefore probably added only
  while a source editor is validated; still open.
- Help ▸ "Show Keyboard Hints" is present. The Help menu has no system
  "Send … Feedback" item.
- Window ▸ the window list shows "<workspace> — <document>" for every
  workspace window.

## 2. Side-by-side with Ycode (5f74ef9)

Rows are grouped by area. "Gap" names the ID used in
`reference-ui-6.md`.

### 2.1 Launch, windows, opening files

| Gap | Reference | Ycode | Pri |
|---|---|---|---|
| W1 | Window title "<workspace> — <document>" in the accessibility title and the Window menu | "AuditApp.xcodeproj" / "AuditPkg" (regression of pass 5 L4: the code that sets it exists, but the title is reset) | P0 |
| W2 | Opening a project with `open` shows only its window | Also shows the Welcome window | P1 |
| W3 | Opening a source file from the Finder or `open` opens it in the workspace that contains it | Alert "The document “Model.swift” could not be opened. The specified URL type isn’t supported." | P1 |
| W4 | First open: jump bar "No Selection" over an empty editor, no Start Page | Start Page (Open Quickly field, Recent Files) and no jump bar; a 47-point empty strip at the top left | P0 |
| W5 | Welcome geometry (§1.1) | 12-point close button, 137 × 30 buttons in a 426 row, visible "Recent Projects" heading, visible scroller, package shown as a folder | P2 |
| W6 | New Project ▸ App creates an untitled multiplatform project at once; a separator precedes Choose Template… | Opens the template sheet on iOS ▸ App; no separator | P2 |

### 2.2 Toolbar and activity view

| Gap | Reference | Ycode | Pri |
|---|---|---|---|
| T1 | Right group always ends at the window's right edge; on shortage the editor-mode capsule collapses into a pull-down, then the scheme name truncates | The right group overflows into a "»" menu (editor modes and the inspector button disappear) once the issue capsule shows errors and warnings; in a package window the group stops short of the right edge | P0 |
| T2 | Destination pop-up shows device icon and name only | Shows "iPhone Duo … 27.1⇕": the menu row's tabbed version is drawn in the pop-up, stretched to 327 points | P1 |
| T3 | Default destination of a multiplatform app (macOS supported): My Mac | iPhone Duo (iOS 27.1 simulator) | P1 |
| T4 | Activity: "Build", "Building • n/m", spinner instead of the icon, middle truncation | "Building MyApp", then "Preparing" with a thin bar under the subtitle; no counter; the subtitle is underlined | P1 |
| T5 | Run/test texts of §1.5 | "Booting simulator", "Installing X.app", "Running X on Simulator", "Finished running X"; remote "(1 of 3)" counters; "Testing <scheme>"; "Test Succeeded" | P1 |
| T6 | Accessibility titles "Active Scheme", "Active Run Destination", "Add Editor", "Editor Options" | "Scheme" (both), "Add Editor Tabs or Editor Panes", "Adjust Editor Options" | P2 |
| T7 | Toggle buttons are titled by the action they perform now ("show/hide debug area", "Hide/Show Inspector") | Debug-area button always "Hide Debug Area"; inspector button "Show Inspector" while shown | P1 |
| T8 | Grouped capsules: Navigators/Assistant (37 × 35 segments), Run/Stop, Back/Forward, Add Editor + Editor Options, the three editor modes (41/40/41) | Ungrouped glyphs, 39–54-point segments | P2 |
| T9 | Issue capsule "⊗ 1  ⚠ 2" as two buttons "Errors", "Issues" | One item with filled dots | P2 |
| T10 | Cloud-notices slot only in project windows | Disabled "Account" item in every window | P2 |

### 2.3 Editor

| Gap | Reference | Ycode | Pri |
|---|---|---|---|
| E1 | Jump bar file component without extension | "Model.swift" (regression of pass 5 §6.1) | P1 |
| E2 | Jump bar issue cluster "‹ ⚠ ›" (glyph only) | "⌃ ⚠ Issues ⌄ ⌄" with up/down chevrons and the word "Issues" | P2 |
| E3 | "Line: 1  Col: 1" after opening; caret at 1:1 | "Col: 359", "Col: 190" (the column shows a character offset); ContentView opened with the caret at 12:10 | P0 |
| E4 | Inline issue: token underline, tinted line, annotation after the code, no gutter glyph | Lightbulb/glyph in a gutter column left of the numbers, annotation | P2 |
| E5 | No live issue before the first build in a fresh window | Live warning at once | P2 (setting-dependent; keep) |
| E6 | Test diamonds replace the line number | Diamond drawn beside the number | P2 |
| E7 | Canvas shown automatically for a file with previews (50/50) | Not shown | P1 |
| E8 | Minimap shown | Hidden (Ycode default off) | P2, factory default unconfirmed |

### 2.4 Navigators

| Gap | Reference | Ycode | Pri |
|---|---|---|---|
| N1 | Issue tree: project › file-less issues; target › file › issue | Root › file › issue, no target level | P1 |
| N2 | Live and build issue for the same line merged; first letter capitalized | Both listed, as two "Model" groups; build messages lowercase; capsule counts both | P0 |
| N3 | Row height 22, first row at y 86 | Rows 27.5, first row at y 102 | P1 |
| N4 | Package tree: Sources and Tests expanded | Tests collapsed | P2 |
| N5 | Test navigator root is the package/project name; target row "2 Tests" only; result glyph on every row | Root is the plan name "AuditPkg (Autocreated)"; target row "2 Tests, 0 Failing…"; no glyph on root/target | P2 |
| N6 | Find header is a path without pop-up arrows; field placeholder is the kind ("Text") | Arrows after each component; placeholder "Find" | P2 |
| N7 | Filter fields carry the filter-options control inside, at the leading end | Separate pull-down outside; magnifier inside | P2 |
| N8 | Selected navigator tab keeps its accessibility title | The selected tab loses its title | P2 |

### 2.5 Inspectors and debug area

| Gap | Reference | Ycode | Pri |
|---|---|---|---|
| I1 | Section rules; Location disabled in synchronized folders; boxed Target Membership with "+" enabled; none for package files | No rules; Location enabled; checkbox row with disabled buttons; shown for package files | P2 |
| I2 | History row shows the 7-character hash above the date | Date only | P2 |
| I3 | Quick Help empty state centered | Left-aligned | P2 |
| D1 | Console bar without an output-kind pop-up; no command line while idle | "All Output" pop-up; "(lldb) LLDB command or expression" line while idle | P2 |

### 2.6 Menus

| Gap | Reference | Ycode | Pri |
|---|---|---|---|
| M1 | One "Open Recent" | Two (AppKit adds its own) | P1 |
| M2 | No system "Send … Feedback to Apple" in Help | "Send Ycode Feedback to Apple" first | P1 |
| M3 | "File from Clipboard" | "New File from Clipboard" | P2 |

### 2.7 Coding assistant

| Gap | Reference | Ycode | Pri |
|---|---|---|---|
| A1 | Pane header "New Conversation ⌄" / "New Group"; list with "Archive" | Centered placeholder text | P1 (for the assistant round) |
| A2 | New Conversation menu: "Agents" section with provider rows | — | P1 |
| A3 | Toolbar New Conversation opens a prompt popover | Button disabled | P1 |
| A4 | Editor ▸ Show Coding Tools holds only "Show Coding Tools…" without a provider | Pass-5 set (five items) | P2 |

## 3. Pass-5 corrections checked

Confirmed as matching: Welcome window exists and is shown at launch
with no document; Open Recent lists recents; window frame 1400 × 900;
Products group hidden; extensions hidden in the project navigator;
Navigators | Coding Assistant segments are exclusive; Run/Stop and
Back/Forward tooltips; navigator bottom-bar toggles; Find scope "In
Project"; jump bar has no history buttons and has the issue cluster;
File inspector Working Copy and Relative Path, ODR placeholder; History
inspector rows; Quick Help empty state text; debug-area variables and
console bar items; menu titles of Edit, View, Editor, Navigate, Window
listed in the reference's order.

Regressions or unfinished pass-5 items: W1 (window title, L4), E1 (jump
bar extension, §6.1), W4 (Start Page over the jump bar, §3.5), T6
(accessibility names of the pill, §4.3.4), N7 (filter options inside
the field, §5.2), T7 (state-dependent toggle titles).

## 4. Corrections to earlier notes and specs

- `reference-ui-5.md` §3.5: the reference shows no Start Page at first
  open; the editor is empty under a "No Selection" jump bar.
- `reference-ui-5.md` §2.2: "File from Clipboard".
- `reference-ui-5.md` §11.5 / `run.md`: the reference's simulator run
  texts are known now (§1.5); there is no step counter.
- `reference-ui-2.md` §2.3 and `testing.md`: a passing selected-test run
  ends in "Test Completed"; the whole-scheme text is still open.
- `reference-ui-5.md` §2.7 item 8: without a model provider, Show Coding
  Tools ▸ holds only "Show Coding Tools…".

## 5. Still to observe (needs the frontmost window)

Everything in `reference-ui-5.md` §12 except the items answered in §1
(simulator run texts, the Welcome New Project pull-down, the all-pass
text for a selected test, the assistant pane layout). Additionally: the
Settings panes, Add Editor and Editor Options contents, the scheme and
destination menus, the toolbar's collapsed editor-mode pull-down, a ⌘U
run, the project editor, and ⌘0 toggling with the assistant shown.

## 6. Pass 6b (2026-10-27): click-level attempt, accessibility reads

### 6.0 Method and limits

- **Control.** The owner had approved a click-level pass, but in this
  session the computer-use tool granted the reference only its IDE tier
  ("click": plain left clicks and screenshots; no typing, no key
  presses, no right-click, no modifier clicks, no menu presses through
  the menu-bar tool; a second access request returned the same tier).
  Both full-screen takeover attempts ended at once with "user
  interrupt", before any action, and a later background batch of two
  plain clicks was interrupted the same way. As the brief says, no
  further takeover was tried.
- **What could be done.** One background plain click (the toolbar's
  Coding Assistant segment). Read-only accessibility dumps of the menu
  bar (titles, key equivalents, modifier masks, check marks, enabled
  state) and of windows. Reading a menu through accessibility makes the
  application update it, so enabled states and dynamic titles are the
  validated ones for the main window of the time (the reference was not
  frontmost; the main window was the last one opened). Files were opened
  with `open -g -a Xcode`.
- **User data.** Before launch, the reference's user defaults were
  exported to a scratch file, and the one minimap key was removed so the
  factory default could be seen; after quitting, the key was written
  back with its prior value (on). No other preference was touched. For
  the default-destination question a copy of `AuditPhone` **without**
  `xcuserdata` was made in `_agents/scratch` and removed afterwards.
- **Not done.** No build, run or test; no simulator created, booted or
  selected; no Settings window (needs a menu press); no pop-up or
  pull-down opened; no context menu; no typing. Xcode was closed through
  its scripting interface (close the workspace documents, quit). The
  owner's simulators (one `ycode-…` device was booted by another agent)
  were not touched.
- Raw dumps are in `research/dirty/ide-audit6b/` (not committed):
  `menubar-source-editor.txt` (AuditApp, `Model.swift` focused, issue
  navigator shown), `menubar-auditphone-fresh.txt` (fresh iOS-only copy,
  `Model.swift` focused), window trees.

### 6.1 Minimap and canvas defaults

- With the minimap key absent from the user defaults, Editor ▸ Minimap
  ⌃⇧⌘M was **checked** and the minimap was drawn, both in AuditApp and
  in the fresh copy that has no workspace user data. The factory default
  is **on** (answers `reference-ui-6.md` §4.5).
- Editor ▸ Canvas ⌥⌘↩ was checked and the toolbar's Canvas segment was
  selected in both windows, with `Model.swift` (no previews) focused; no
  canvas was drawn for that file. Canvas mode is on by default per
  editor; the canvas area appears only for a file that has previews.
- Editor ▸ Layout ▸ read "Automatic" (checked), —, "Canvas on Right",
  "Canvas on Bottom", all enabled. Pass 5 had "Editor on Left / Editor
  on Top", disabled while the canvas is hidden.

### 6.2 Coding assistant toggle (⌘0)

- After clicking the Coding Assistant segment (the pane appeared as in
  §1.8), View ▸ Navigators ▸ read: Project ⌘1 … Reports ⌘9, —, **Hide
  Coding Assistant ⌘0**, Hide Navigator (no shortcut), Filter in
  Navigator ⌥⌘J **disabled**. With the navigator shown the same item is
  "Show Coding Assistant ⌘0" and Filter in Navigator is enabled.
- So ⌘0 is a toggle: while the assistant is shown it hides it (the
  item keeps ⌘0). What is shown in the left area after the hide was not
  observed (the click that would have checked it was interrupted).
- Editor ▸ Show Coding Tools ▸ in a validated read held the five-item
  set: Show Coding Tools… ⌥⌘0, —, Explain, Document, Generate a
  Playground, Generate a Preview, all enabled. The one-item form recorded
  in §1.9 came from a non-validated listing. The user defaults carry key
  names showing that an assistant model was used on this Mac before
  (values not read), so "no provider" cannot be asserted for this read.

### 6.3 Default destination for an iOS-only product

- Fresh copy of AuditPhone (`SDKROOT iphoneos`, supported platforms
  iphoneos + iphonesimulator, device families 1,2, deployment target
  27.0), no workspace user data. The Active Run Destination read
  **"iPhone 18 Pro"**; Product ▸ Destination checked "iPhone 18 Pro
  27.0".
- Installed iOS runtimes 26.5, 27.0, 27.1; the SDK is 27.1. The 27.1
  runtime held three simulators, all of the newest device type ("iPhone
  Duo", plus two user-named devices of that type). The 27.0 runtime held
  the standard set (iPhone 17, 17 Pro, 17 Pro Max, 17e, 18 Pro, 18 Pro
  Max, Air, five iPads, Apple Vision). The reference did **not** take the
  first row of the Simulators section ("iPhone Duo 27.1"), as pass 5's
  rule says; it took the newest-generation Pro iPhone, on the only
  runtime that has it.
- Product ▸ Destination for this product: Choose Destination ⌃⇧0, Select
  Next / Previous Destination ⌃⌥⌘] / ⌃⌥⌘[, —, Show All Run Destinations,
  —, label Devices, "My Mac (Designed for iPad) 27.2", a connected phone,
  —, label Simulators (27.1 rows, then 27.0 rows iPhone → iPad → "Apple
  Vision Pro (Designed for iPad, 27.0)", then the same Vision row for
  26.5 and 26.4.1), —, label Build, "Any iOS Device (arm64)", "Any iOS
  Simulator Device (arm64, x86_64)", —, Incompatible ▸ (first row "My
  Mac (mismatched platform) 27.2", then the 26.5 iPhones and iPads "(OS
  version lower than deployment target)", then other platforms), —,
  Manage Devices… ⇧⌘2. This matches pass 5 §2.9 and §11.4. The toolbar
  pop-up itself (pass 3 saw a filter field and a Recent section) was not
  opened.
- Product ▸ Scheme: Choose Scheme ⌃0, Select Next / Previous Scheme
  (disabled with one scheme), —, Edit Scheme… ⌘<, New Scheme…, Manage
  Schemes…, —, "MyApp" checked. As pass 5.

### 6.4 Edit ▸ Copy and Paste

- The accessibility tree has an item "Copy" with **no** key equivalent
  and a submenu: Copy ⌘C, Copy File and Line ⌃⌥⌘C, Copy Symbol Name
  ⌃⇧⌘C, Copy Qualified Symbol Name ⌃⌥⇧⌘C. Likewise "Paste" (no key
  equivalent) with a submenu: Paste ⌘V, Move Item Here ⌥⌘V (listed in
  one read, absent in the next), Paste and Preserve Formatting ⌥⇧⌘V.
- Known modifier alternates (File ▸ New ▸ Conversation in New Tab,
  Product ▸ Run…, Debug ▸ Step Over Instruction, Navigate ▸ … using Tab)
  are exposed **flat**, as siblings of their primary item, and no item
  carries a reference to a different primary. The nesting of Copy and
  Paste is therefore a real submenu, not an alternate group. The drawn
  menu was not seen.
- Validated states with the caret in `Model.swift` and no selection:
  Copy ⌘C disabled; the three Copy variants enabled; Cut disabled; Paste
  enabled; Delete disabled; Undo / Redo disabled ("Undo" / "Redo" with no
  action name).
- The flat alternates cannot be told apart from visible items through
  accessibility; which Debug / Find / Navigate items are alternates stays
  open.

### 6.5 Dynamic titles and states seen in validated reads

| Item | Read 1 (AuditApp, issue navigator shown) | Read 2 (fresh copy, project navigator shown) |
|---|---|---|
| File ▸ New ▸ from the clipboard | "File from Clipboard", disabled | "New File from Clipboard", enabled (the pasteboard held text) |
| File ▸ New ▸ Empty File | disabled | enabled |
| File ▸ New ▸ Group, Group without Folder, Group from Selection, Group from Selection without Folder | present, disabled | absent (a file in a synchronized folder selected; Folder and Folder from Selection enabled) |
| File ▸ Add Files… ⌥⌘A | "Add Files…", disabled | "Add Files to “AuditPhone”…", enabled |
| Find ▸ Find in Selected … | "Find in Selected Groups…", disabled | "Find in Selected File…", enabled |
| Edit ▸ Convert ▸ Preflight Conversion … | "… To Folder" | "… to Folder" |
| Editor ▸ Show Last Change for Line | enabled (git repository) | disabled (no repository) |
| View ▸ Debug Area ▸ ⇧⌘Y | "Hide Debug Area" (shown) | "Show Debug Area" (hidden at first open) |

- Help ▸ "Hide Keyboard Hints ⌥⌘?" with no keyboard-hint key in the
  user defaults: the hints are **on** in the factory state. What they
  show was not observed.
- File ▸ ⌘W read "Close Window" (one tab), as pass 5.
- Open Recent disambiguation, confirmed: "AuditPhone.xcodeproj —
  AuditPhoneFresh" / "… —  AuditPhone" (em dash, two spaces before the
  folder).

### 6.6 Window title at first open

- The fresh copy's window: accessibility title "AuditPhone —
  AuditPhone.xcodeproj" (as pass 6 §1.1), but the Window menu's entry
  read **"AuditPhone — New Editor"** at the same moment. After
  `Model.swift` was opened both read "AuditPhone — Model.swift". Whether
  the Window-menu entry is meant to differ, or lagged, is open.

### 6.7 Still to observe and why

Everything below needs a frontmost reference with typing, key presses,
right-clicks or menu presses, none of which this pass had:

- Settings panes (all but Apple Accounts and Intelligence) and every
  pop-up's values;
- context menus (navigator rows, editor, gutter, tabs, jump bar);
- Add Editor and Editor Options pull-downs; the toolbar scheme and
  destination pop-ups as drawn (filter field, Recent section); the
  collapsed editor-mode pull-down (needs a narrow window);
- Open Quickly and Show Quick Actions… layout and ranking; the Library;
  the find bar; the completion popup;
- which Debug / Find / Navigate items are hidden alternates; Help ▸
  Keyboard Hints behavior; Copy File and Line's text;
- a whole-scheme test (⌘U) and the "Test" action's first text;
- the project editor and its Editor menu (selecting the project row is
  an outline click the tool does not send in the background);
- what the left area shows after ⌘0 hides the assistant.
