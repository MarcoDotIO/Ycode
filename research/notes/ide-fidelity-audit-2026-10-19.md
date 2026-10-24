# IDE fidelity audit, 2026-10-19 (Xcode 27.1 vs Ycode at aa1bf7c)

Dirty-room notes (prose and tables, no code). They hold two things:

1. New black-box observations of the reference IDE (pass 5, evidence
   level 3). They add to `xcode-27-gui-observations.md` and `-2.md`.
2. The full fidelity matrix. Each row compares what the reference does
   (spec section or the observation below) with what Ycode does at commit
   aa1bf7c (source read and a running build), then gives the delta class
   and a priority.

The boundary spec written from these notes is `specs/ide/reference-ui-5.md`.
No colors were recorded and no assets were copied. User identity, the
user's own projects and account panes were not looked at.

## 0. Method and limits

- **Reference.** `/Applications/Xcode.app`, Xcode 27.1 (27A9269).
- **Samples.** Copies of our own "ObsApp" (iOS app, objectVersion 77, one
  synchronized folder, git repo with one modified and two untracked
  files) and "Obs" (Swift package), in
  `/Volumes/MARCUS-PROJECTS/_inbox/ycode-observe-ide-audit/`. Copied
  without `xcuserdata`, so Xcode started with no per-project user state.
- **Tools.**
  - The workspace window's accessibility tree, read with our own tool that
    only reads attributes: role, title, description, help (tooltip),
    value, frame.
  - The menu bar read the same way. Every item's title, key equivalent,
    modifier mask, enabled state and mark is listed, so shortcuts are
    exact.
  - Background left-clicks on buttons and tabs, through the desktop-control
    tool at the "click" tier.
  - `open -g -a Xcode <file>` to open files.
  - There were no keystrokes, no menu presses, no right-clicks and no
    full-screen control: the one full-screen attempt was interrupted by the
    user, so it was not retried.
- **Menu validation.** Xcode rebuilds its menus while it works. The menu
  bar was read in two states:
  - with no workspace (the Welcome window);
  - after files had been opened in the workspace window. In this state the
    menus were validated: dynamic titles such as "Close “Model.swift”"
    appeared, and the Editor menu was filled for the focused editor.

  The Editor menu was read for five focused editors: a Swift file, a
  SwiftUI file, a plain-text file, a property list, a storyboard and an
  asset catalog.
- **Factory defaults.**
  - The user's key-binding set (`~/Library/Developer/Xcode/UserData/KeyBindings/Default.idekeybindings`)
    is an empty dictionary. Every shortcut below is therefore a factory
    default.
  - The user's preferences domain was searched only for the names of
    customized keys, never their values. The only display-related keys
    present are the minimap switch, "always show editor tab bar" (off),
    predictive completion, and theme names. No file-extension key is set,
    so "File extensions: Hide All" (`reference-ui.md` §4) is the factory
    default.
- **Not possible this pass** (listed in §5 with steps): context menus,
  pop-up and pull-down menus (toolbar, jump bar, navigator "+" menus), the
  Settings window, Open Quickly, the Library, the find bar, completion, and
  selecting rows in outlines (refused in the background).

## 1. New observations (pass 5)

### 1.1 Launch and the Welcome window

- When Xcode is launched with no document, it shows the window "Welcome to
  Xcode" (480 × 632). From top to bottom:
  - a round close button at the top left;
  - the application icon;
  - the name "Xcode", then "Version 27.1";
  - three buttons in a row: "Open…", "Clone…" and a "New Project" pull-down
    with a chevron;
  - an outline titled "Recent Projects". Each row has the project's icon,
    its name in primary text, and the folder path in secondary text, with
    a tooltip on each. The first row is selected.
- Opening a project with `open` left the Welcome window on screen behind
  the new workspace window. Its close button closed it.
- Window ▸ Welcome to Xcode is ⇧⌘1.

### 1.2 Workspace window as opened (fresh copy, no user data)

- **Window title** (accessibility title, Window-menu entry):
  "`<project> — <focused document>`", for example "ObsApp — Model.swift".
  With nothing selected the window title read "ObsApp — ObsApp.xcodeproj",
  and the Window-menu entry read "ObsApp — New Editor".
- **Frame:** 1400 × 900 including the toolbar.
- **Areas:**
  - The navigator was shown (Project navigator, 290 wide).
  - The inspector was shown (260 wide) and read "Not Applicable", centered.
  - The debug area was hidden.
- **Project navigator:**
  - The project row and its first group were expanded.
  - The children were the synchronized folder's files, without extensions.
  - There was **no "Products" group**, although the main group lists it
    (`productRefGroup`).
  - Status letters appeared only on files. The project and group rows had
    none.
  - Row height 22.
- **Editor area:** a jump bar holding the Related Items button (a grid
  icon), "No Selection", and, at its right end, previous-issue, issues
  (menu) and next-issue buttons. Below it the editor area was blank in the
  background capture. Whether a Start Page shows here when the window is
  frontmost is still open (§5).
- **Destination:** "iPhone 18 Pro", a simulator on the iOS 27.0 runtime.
  Other simulators existed on 27.1. This may be a global recent rather
  than a rule.
- **Issue capsule:** "⚠ 1". The issue is "Update to recommended settings",
  listed directly under the project root in the Issue navigator, not in a
  group.
- **Debug bar** (bottom of the editor area), left to right:
  - Breakpoints toggle (tooltip "Deactivate Breakpoints");
  - "Line: N  Col: N" once a file is open;
  - the branch as a button with a branch glyph (tooltip "Shows a list of
    available branches");
  - "show debug area" (tooltip "Show the Debug Area") at the far right.

### 1.3 Toolbar, left to right (accessibility labels and tooltips)

| Item | Kind | Tooltip / label |
|---|---|---|
| Navigators, Coding Assistant | radio group, two segments | "Navigators", "Coding Assistant". The selected segment shows which content fills the left area. Clicking the selected segment hides the area (both segments become unselected). Clicking it again shows the navigator. |
| Run, Stop | joined pair | "Build and then run the current scheme", "Stop the running scheme or application" (disabled when idle) |
| Go Back, Go Forward | joined pair | "Show Previous Location in History", "Show Next Location in History" |
| Window Title/Activity | project icon, a progress indicator, the name | No subtitle while idle |
| New Conversation | button | — |
| path: Active Scheme › Active Run Destination | two pop-ups in one capsule | accessibility names "Active Scheme", "Active Run Destination" |
| Issues | button (the issue capsule) | — |
| Xcode Cloud Notices | button | — |
| Add Editor | pull-down | — |
| Editor Options | pull-down | — |
| Editor Mode: Canvas, Assistant, Code Review | radio group, three segments | "Show Canvas", "Show Assistant", "Show Code Review". **At most one is on.** Selecting Assistant turned Canvas off. Clicking the selected segment turns it off, leaving none selected. |
| Hide Inspector / Show Inspector | button | — |

### 1.4 Navigator chrome, per navigator (bottom bar, header, empty state)

| Navigator | Header below the selector | Bottom bar, left to right (tooltips) | Empty state |
|---|---|---|---|
| Project | — | "+" pull-down; filter "Project navigator filter" (tooltip "Show files with matching name") with a leading filter-options pull-down; in-field toggles "Recent files" ("Show only recent files") and "Files with source-control status" ("Show only files with source-control status") | — |
| Source Control | Changes \| Repositories (tooltips "Show the Changes navigator", "Show the Repositories navigator") | pull-down; filter "Changes Navigator Filter" ("Filter Changes Navigator") with options | Row status letters have tooltips: "Untracked" for "?", "No changes staged" for an unstaged "M" |
| Bookmarks | — | a "…" pull-down (not "+"); filter "Bookmark Navigator Filter" with options; toggle "Incomplete Items" ("Show only incomplete items") | "No Bookmarks" / "Click the '…' button to add bookmarks" |
| Find | Find › Text › Containing; "Aa" toggle (tooltip "Case Sensitive"); search field (placeholder = the kind, "Text"); scope pop-up | filter field only | none (blank). The scope read "In Workspace" right after opening, then "In Project". |
| Issues | — | filter "Issue navigator filter" ("Show issues with matching name") with options, full width (no "+"); toggles "Show only latest issues" ("Show only issues from open documents and recently built sources") and "Only errors" ("Show only errors") | — |
| Tests | test-plan pop-up ("ObsApp (Autocreated)"); "Mode" with two radio buttons "Group by Test Hierarchy" and "Group by Tags" | "+" pull-down ("Add a new test target or class"); filter "Test Navigator Filter" ("Show tests with matching criteria"); toggles "Show Only Included Tests" and "Recent Tests" ("Show only recent tests and open documents") | "No Tests" / "Click the ⊕ button to add test targets" |
| Debug | — | filter "Debug navigator filter" ("Show matching content based on filter string") with options; toggles "Show compressed stack frames" (on; "Show only stack frames with debug symbols and between libraries"), "Show only interesting content" (off; "Show only crashed threads and threads with debug symbols"), "Show only running blocks" (on; "Show only running blocks when in Queues view") | "No Debug Session" |
| Breakpoints | — | "+" pull-down ("Create a breakpoint"); filter "Breakpoints Navigator filter" ("Show breakpoints with matching content"); toggles "Modified breakpoints" ("Show only modified breakpoints") and "Enabled breakpoints" ("Show only enabled breakpoints") | "No Breakpoints" |
| Reports | Local \| Cloud ("Show Local Reports", "Show Cloud Reports") | pull-down; filter "Report navigator filter" ("Show reports with matching name"); toggle "Recent reports filter" ("Show only recent reports") | "No Logs" |

Selector tooltips: "Show the Project navigator", "Show the Source Control
navigator", "Show the Bookmark navigator", "Show the Find navigator", "Show
the Issue navigator", "Show the Test navigator", "Show the Debug Navigator",
"Show the Breakpoints Navigator", "Show the Report navigator". The
capitalization of "Navigator" varies, exactly as shown.

### 1.5 Source editor chrome (Model.swift open)

- **Jump bar.** Related Items (grid icon, tooltip "Navigate to Related
  Items"), then project › group › file (without extension) › symbol ("No
  Selection"). There are **no back/forward buttons** in the jump bar: history
  lives in the toolbar. At the right end are Show Previous Issue, an
  "Issues" pull-down, and Show Next Issue.
- **Change gutter.** An 11-pt column at the far left of the gutter, left of
  the line numbers, present in normal editing (not only in Code Review).
  - A modified range shows a bar.
  - The bar's accessibility description is "Local modification on lines 13
    through 14".
  - The column's tooltip is "Unstaged change".
- **Line-number gutter.** 32 pt wide.
- **Minimap.** At the right edge. Its width scales with the editor: 128 pt
  in a 962-pt editor, 140 pt in a wider one, 73 pt in a 480-pt assistant
  split. The first pass recorded about 110. It carries "landmark" labels
  for the declarations ("Counter", "value", "increment(by:)").

### 1.6 Inspectors

- **Tab bar.** Three segmented tabs fill the width ("File Inspector",
  "History Inspector", "Quick Help Inspector"), with tooltips "Show the File
  inspector", "Show the History inspector", "Show Quick Help inspector".
- **File inspector, for a file in a git working copy:**
  - Identity and Type: Name, Type, Location, the file name, Full Path,
    **Working Copy**, **Relative Path**.
  - **On Demand Resource Tags:** a disabled field with the placeholder
    "Only resources are taggable".
  - **Target Membership:** a list of targets with the membership kind under
    the name ("Default"), and buttons "+" ("Choose which targets include
    this file"), "−" ("Remove this file from selected targets") and a pencil
    ("Edit target membership options").
  - Text Settings.
- **History inspector:** one row per commit that touched the file: author,
  subject, and the relative date at the right ("Yesterday").
- **Quick Help inspector, caret not on a symbol:** a section "Quick Help"
  holding "No Quick Help" and a "Search Documentation" button.
- **Property list open, Quick Help tab:** "No Selection".

### 1.7 Debug area (opened with the toolbar button while idle)

- **Placement.** The debug bar moves above the area. The area is split
  between variables and console.
- **Variables bar:** "Auto" pop-up, "Quick Look", "Print Description" (this
  is the "info" button), and a filter.
- **Console bar:** "Quick Look", "Metadata Options", a filter with an
  options pull-down, "Clear Console", then the two half toggles at the far
  right.

### 1.8 Editors

- **Property list editor.**
  - The Key | Type | Value column headers are sort buttons.
  - The jump bar ends with the key-path component ("No Selection").
- **Assistant (Editor Mode ▸ Assistant).**
  - The editor splits 50/50.
  - The assistant's jump bar has a close button ("Close this Editor Pane")
    and the mode pop-up ("Counterparts").
  - With no counterpart it shows "No Editor".

### 1.9 Menus

The menu bar as validated with Model.swift focused in the ObsApp
workspace. Format:

- "— ⌘X" is the default shortcut.
- "———" is a separator.
- "[✓]" marks a checked item.

System-supplied lists are not recorded: Services, Open Recent entries,
AutoFill, Move & Resize, Touch Bar and the window list.

Some items are option- (or control-) **alternates**: they appear in place
of their primary item only while the modifier is held. They were
identified from:

- screenshots of the visible menu in passes 2–4 (Product: Run, Test,
  Profile, Analyze, Archive, Stop without the "…" items; the File close
  group without the "Close Other …" items; File ▸ New without "Conversation
  in …" and "Choose Template…");
- AppKit's alternate rule (adjacent, same key, more modifiers);
- titles carrying "using Tab" or "in Next Editor Pane".

The table in `reference-ui-5.md` §2 marks them.

Titles that change with context: "Close Window" / "Close Tab" for ⌘W;
"Close “<file>”"; "Close Project" / "Close Workspace" / "Close Package";
"Project Settings…" / "Workspace Settings…"; "Bookmark “<file>” Line
<n>"; "Find in Project" / "Find in Workspace"; "Jump to Line in
“<file>”…"; "Compile “<file>”"; "Stage Changes in “<file>”"; "Discard
Changes in “<file>”…"; "Pause" / "Continue"; "Deactivate Breakpoints" /
"Activate Breakpoints"; "Show/Hide Navigator", "Show/Hide Inspector",
"Show/Hide Debug Area", "Show/Hide Toolbar", "Show/Hide All Issues",
"Show/Hide Keyboard Hints"; "Redo <action>".

In a **package workspace** (sample "Obs", Shapes.swift focused):

- "Close Package ⌃⌥⌘W";
- "Package Settings…";
- "Find in Package ⇧⌘F" and the other "… in Package" titles;
- Export / Import Localizations… present but disabled;
- window title "Obs — Shapes.swift".

With **no workspace open** the same menus read:

- ⌘W: "Close Tab, Editor Pane, Window Tab, or Window";
- ⌃⌘W: "Close Document";
- ⇧⌘W: "Close Window Tab";
- ⌃⌥⌘W: "Close Workspace";
- Find titles: "… in Workspace";
- Integrate: "Stage Selected Files", "Unstage Selected Files", "Mark as
  Resolved", "Add", "Create Pull Request…", "Discard Changes in Selected
  Files…";
- the Editor menu is empty.



**Xcode**

- About Xcode
- Xcode Extensions…
- ———
- Settings… — ⌘,
- Behaviors ▸
  - No Custom Behaviors
  - ———
  - Edit Behaviors…
- ———
- Open Developer Tool ▸
  - Instruments
  - Device Hub
  - Icon Composer
  - Accessibility Inspector
  - FileMerge
  - Create ML
  - ———
  - More Developer Tools…
- Services ▸ (system-provided or dynamic list; not recorded)
- ———
- Hide Xcode — ⌘H
- Hide Others — ⌥⌘H
- Show All
- ———
- Quit Xcode — ⌘Q
- Quit and Keep Windows — ⌥⌘Q

**File**

- New ▸
  - Conversation — ⌃⌘H
  - Conversation in New Tab — ⌃⌥⌘H
  - Conversation in Editor Pane — ⌃⌥⇧⌘H
  - ———
  - Tab — ⌘T
  - ———
  - Editor Pane On Right — ⌃⌘T
  - Editor Pane Below — ⌃⌥⌘T
  - Window Tab
  - Window — ⇧⌘T
  - ———
  - Empty File
  - New File from Clipboard
  - File from Template… — ⌘N
  - Target…
  - ———
  - Project… — ⇧⌘N
  - Choose Template… — ⌥⇧⌘N
  - Workspace… — ⌃⌘N
  - ———
  - Group
  - Group without Folder
  - Group from Selection
  - Group from Selection without Folder
  - Folder — ⌥⌘N
  - Folder from Selection
- ———
- Add Files… — ⌥⌘A
- Add Package Dependencies…
- ———
- Open… — ⌘O
- Open Recent ▸ (system-provided or dynamic list; not recorded)
- Open Quickly… — ⇧⌘O
- ———
- Close Window — ⌘W
- Close Other Tabs — ⌥⌘W
- Close “Model.swift” — ⌃⌘W
- Close Editor Pane — ⌃⇧⌘W
- Close Other Editor Panes — ⌃⌥⇧⌘W
- Close Window — ⇧⌘W
- Close Other Window Tabs — ⌥⇧⌘W
- Close Project — ⌃⌥⌘W
- ———
- Duplicate Editor Tab
- Save — ⌘S
- Save All — ⌥⌘S
- Duplicate… — ⇧⌘S
- Save As… — ⌥⇧⌘S
- Revert to Saved…
- Unlock…
- Export…
- ———
- Show in Finder
- Open Terminal at Location
- Open in New Tab — ⌥⌘O
- Open in New Window
- Open with External Editor
- ———
- Packages ▸
  - Reset Package Caches
  - Resolve Package Versions
  - ———
  - ———
  - Update to Latest Package Versions
- ———
- Save As Workspace…
- Project Settings…
- ———
- Page Setup…
- Print… — ⌘P

**Edit**

- Undo — ⌘Z
- Redo Typing — ⇧⌘Z
- ———
- Cut — ⌘X
- Copy ▸
  - Copy — ⌘C
  - Copy File and Line — ⌃⌥⌘C
  - Copy Symbol Name — ⌃⇧⌘C
  - Copy Qualified Symbol Name — ⌃⌥⇧⌘C
- Paste ▸
  - Paste — ⌘V
  - Move Item Here — ⌥⌘V
  - Paste and Preserve Formatting — ⌥⇧⌘V
- Duplicate — ⌘D
- Delete — ⌘⌫
- ———
- Select All — ⌘A
- ———
- Bookmark “Model.swift” Line 1 — ⌃⌘'
- Bookmark “Model.swift” Line 1… — ⌃⌥⌘'
- Bookmark “Model.swift” — ⌃⇧⌘'
- Bookmark “Model.swift”… — ⌃⌥⇧⌘'
- ———
- Sort ▸
  - By Name
  - By Type
- Format ▸ (the standard macOS text Format menu: Show Fonts ⌃⇧⌘T, Show Colors, Font ▸, Text ▸, Spelling and Grammar ▸ (Show Spelling and Grammar ⌘:, Check Document Now ⌘;), Substitutions ▸, Transformations ▸, Speech ▸; present in every context, its items act on text views)
- ———
- Convert ▸
  - To Group
  - To Folder
  - Preflight Conversion To Folder
  - To String Catalogs…
- ———
- AutoFill ▸ (system-provided or dynamic list; not recorded)
- Start Dictation… — fn
- Emoji & Symbols — fn E

**View**

- Editor ▸
  - Focus Editor Pane — ⌃⇧⌘↩
  - ———
  - Show Related Items — ⌃1
  - Show Previous History — ⌃2
  - Show Previous Files History — ⌃⌘2
  - Show Next History — ⌃3
  - Show Next Files History — ⌃⌘3
  - Show Top Level Items — ⌃4
  - Show Group Files — ⌃5
  - Show Document Items — ⌃6
- ———
- Show Editor Tab Bar
- Pin Editor Tab — ⇧⌘P
- Change Editor Orientation
- Reset Editor Sizes
- Reset Assistant Selection — ⌥⇧⌘Z
- ———
- Show Quick Actions… — ⇧⌘A
- ———
- Navigators ▸
  - Project — ⌘1
  - Source Control — ⌘2
  - Bookmarks — ⌘3
  - Find — ⌘4
  - Issues — ⌘5
  - Tests — ⌘6
  - Debug — ⌘7
  - Breakpoints — ⌘8
  - Reports — ⌘9
  - ———
  - Show Coding Assistant — ⌘0
  - Hide Navigator
  - Filter in Navigator — ⌥⌘J
- Debug Area ▸
  - Activate Console — ⇧⌘C
  - ———
  - Hide Debug Area — ⇧⌘Y
- Inspectors ▸
  - File — ⌥⌘1
  - History — ⌥⌘2
  - Quick Help — ⌥⌘3
  - ———
  - Hide Inspector
- Show Library — ⇧⌘L
- Open Library — ⌥⇧⌘L
- Reload Organizer — ⌃R
- ———
- Choose Theme…
- ———
- Hide Toolbar — ⌥⌘T
- Customize Toolbar…
- Show Window Tab Bar
- Show All Window Tabs — ⇧⌘\
- ———
- Enter Full Screen — ⌃⌘F

**Find**

- Find in Project — ⇧⌘F
- Find and Replace in Project… — ⌥⇧⌘F
- Find Next in Project — ⌃⌘G
- Find Previous in Project — ⌃⇧⌘G
- ———
- ———
- Find Selected Text in Project
- Find Selected Words in Project
- Find Selected Symbol in Project — ⌃⇧⌘F
- Find Call Hierarchy — ⌃⇧⌘H
- Find Ancestor Types
- Find Descendent Types
- Find Conforming Types
- Find in Selected Groups…
- ———
- Find… — ⌘F
- Find and Replace… — ⌥⌘F
- Find Next — ⌘G
- Find Previous — ⇧⌘G
- Find and Select Next — ⌥⌘G
- Find and Select Previous — ⌥⇧⌘G
- ———
- Replace
- Replace All
- Replace and Find Next
- Replace and Find Previous
- ———
- Use Selection for Find — ⌘E
- Use Selection for Replace — ⇧⌘E
- Select Next Occurrence — ⌥⌘E
- Select Previous Occurrence — ⌥⇧⌘E
- ———
- Select All Find Matches
- Select Find Matches in Selection
- ———
- Hide Find Bar

**Navigate**

- Reveal in Project Navigator — ⇧⌘J
- Reveal in Changes Navigator — ⇧⌘M
- Reveal in Debug Navigator — ⇧⌘D
- Open using Tab — ⌥⌘,
- Open in Next Editor Pane — ⌥⌘<
- ———
- Move Focus to Next Area — ⌥⌘`
- Move Focus to Previous Area — ⌥⇧⌘`
- Move Focus to Next Editor Pane — ⌃`
- Move Focus to Previous Editor Pane — ⌃⇧`
- Move Focus to Editor Pane… — ⌘J
- ———
- Show Previous Tab — ⌘{
- Show Next Tab — ⌘}
- ———
- Show Next Location in History — ⌃⌘→
- Show Next Location in History using Tab — ⌃⌥⌘→
- Show Next Location in History in Next Editor Pane — ⌃⌥⇧⌘→
- Show Previous Location in History — ⌃⌘←
- Show Previous Location in History using Tab — ⌃⌥⌘←
- Show Previous Location in History in Next Editor Pane — ⌃⌥⇧⌘←
- ———
- Jump to Next Active Conversation — ⌃⌘K
- ———
- Jump to Selection — ⌥⌘L
- Jump to Definition — ⌃⌘J
- Jump to Definition using Tab — ⌃⌥⌘J
- Jump to Definition in Next Editor Pane — ⌃⌥⇧⌘J
- Jump to Original Source/Generated Interface
- Jump to Last Destination
- ———
- Jump to Next Issue — ⌘'
- Jump to Previous Issue — ⌘"
- ———
- Jump to Next Bookmark — ⌃;
- Jump to Next Bookmark In Workspace — ⌃⌥;
- Jump to Previous Bookmark — ⌃:
- Jump to Previous Bookmark In Workspace — ⌃⌥:
- ———
- Jump to Program Counter — ⌃⌘P
- ———
- Jump to Next Counterpart — ⌃⌘↑
- Jump to Next Counterpart using Tab — ⌃⌥⌘↑
- Jump to Next Counterpart in Next Editor Pane — ⌃⌥⇧⌘↑
- Jump to Previous Counterpart — ⌃⌘↓
- Jump to Previous Counterpart using Tab — ⌃⌥⌘↓
- Jump to Previous Counterpart in Next Editor Pane — ⌃⌥⇧⌘↓
- Jump to Line in “Model.swift”… — ⌘L
- ———
- Jump to Next Placeholder — ⌃/
- Jump to Previous Placeholder — ⌃?
- ———
- Jump to Next Change — ⌃\
- Jump to Next Local or Upstream Change — ⌃⌥\
- Jump to Previous Change — ⌃|
- Jump to Previous Local or Upstream Change — ⌃⌥|

**Editor**

- Show Editor Only — ⌘↩
- ———
- Canvas — ⌥⌘↩
- Assistant — ⌃⌥⌘↩
- Code Review — ⌥⇧⌘↩
- Layout ▸
  - [✓] Automatic
  - ———
  - Editor on Left
  - Editor on Top
- ———
- Show Completions — ⌃Space
- Show Predictive Completion — ⌃⌥Space
- Show Coding Tools ▸
  - Show Coding Tools… — ⌥⌘0
  - ———
  - Explain
  - Document
  - Generate a Playground
  - Generate a Preview
- Edit All in Scope — ⌃⌘E
- Show Callers…
- Expand Macro
- Hide All Macro Expansions
- Refactor ▸
  - Rename…
  - Extract Selection to File
  - Extract to Function
  - Extract to Method
  - Extract to Variable
  - Extract All Occurrences
  - ———
  - Add Missing Abstract Class Overrides
  - Add Missing Protocol Requirements
  - Add Missing Switch Cases
  - Convert to Switch
  - Convert to Regex Builder
  - Expand Default
  - Generate Memberwise Initializer
  - Generate Missing Function Definitions
  - Wrap in NSLocalizedString
- ———
- Fix All Issues — ⌃⌥⌘F
- Show Issues — ⌃⌥⌘L
- Show All Issues — ⌃⌘L
- ———
- Show Markdown
- ———
- ———
- Selection ▸
  - Select All Symbols
  - Split Selection By Lines
  - Balance Delimiters
  - ———
  - Select Column Up — ⌃⇧↑
  - Select Column Down — ⌃⇧↓
- Structure ▸
  - Re-Indent — ⌃I
  - Shift Left — ⌘[
  - Shift Right — ⌘]
  - ———
  - Reformat To Width — ⌃⌥I
  - Format to Multiple Lines — ⌃M
  - Format Selection with ‘swift-format’ — ⌃⌥⇧I
  - Format File with ‘swift-format’ — ⌃⇧I
  - ———
  - Move Line Up — ⌥⌘[
  - Move Line Down — ⌥⌘]
  - Comment Selection — ⌘/
  - Add Documentation — ⌥⌘/
- Code Folding ▸
  - Fold — ⌥⌘←
  - Unfold — ⌥⌘→
  - Unfold All
  - ———
  - Fold Methods & Functions — ⌥⇧⌘←
  - Unfold Methods & Functions — ⌥⇧⌘→
  - ———
  - Fold Comment Blocks — ⌃⇧⌘←
  - Unfold Comment Blocks — ⌃⇧⌘→
- Syntax Coloring ▸
  - [✓] Default for File Type
  - None
  - ———
  - (one item per language, alphabetical: AppleScript … Swift … YAML; the file's effective language carries a mixed-state mark)
- Font Size ▸
  - Increase — ⌘+
  - Decrease — ⌘-
  - ———
  - Reset — ⌃⌘0
- Choose Theme...
- ———
- [✓] Inline Comparison
- Side By Side Comparison
- ———
- [✓] Minimap — ⌃⇧⌘M
- Authors — ⌃⇧⌘A
- Code Coverage
- ———
- Vim Mode
- Relative Line Numbers
- ———
- Invisibles
- Scope Guides
- [✓] Wrap Lines — ⌃⇧⌘L
- ———
- Show Last Change for Line
- Create Code Snippet…

**Product**

- Run — ⌘R
- Run… — ⌥⌘R
- Test — ⌘U
- Test… — ⌥⌘U
- Profile — ⌘I
- Profile… — ⌥⌘I
- Analyze — ⇧⌘B
- Analyze… — ⌥⇧⌘B
- Archive
- Archive…
- Stop — ⌘.
- ———
- Build For ▸
  - Running — ⇧⌘R
  - Testing — ⇧⌘U
  - Profiling — ⇧⌘I
- Perform Action ▸
  - Run Without Building — ⌃⌘R
  - Test Without Building — ⌃⌘U
  - Profile Without Building — ⌃⌘I
  - ———
  - Build with Timing Summary
  - Build and Export Test Products
  - ———
  - Test — ⌃⌥⌘U
  - Test Again — ⌃⌥⌘G
  - Test Without Building Again
  - Profile
  - Profile Again
  - ———
  - Compile “Model.swift” — ⌃⌘B
  - Analyze “Model.swift” — ⌃⇧⌘B
  - ———
  - Preprocess “Model.swift”
  - Assemble “Model.swift”
  - ———
  - Generate Optimization Profile…
- ———
- Build — ⌘B
- Clean Build Folder… — ⇧⌘K
- Clean Build Folder Immediately — ⌥⇧⌘K
- Delete Derived Data…
- Clear Test Results — ⌃⌥⌘K
- Clear All Issues
- ———
- Build Documentation — ⌃⇧⌘D
- ———
- Show Build Folder in Finder
- Copy Build Folder Path
- ———
- Export Localizations…
- Import Localizations…
- ———
- Scheme ▸
  - Choose Scheme — ⌃0
  - Select Next Scheme — ⌃⌘]
  - Select Previous Scheme — ⌃⌘[
  - ———
  - Edit Scheme… — ⌘<
  - New Scheme…
  - Manage Schemes…
  - ———
  - [✓] ObsApp
- Destination ▸
  - Choose Destination — ⌃⇧0
  - Select Next Destination — ⌃⌥⌘]
  - Select Previous Destination — ⌃⌥⌘[
  - ———
  - Show All Run Destinations
  - ———
  - Devices (section label), then one row per device: "<name> <OS version>" (here "My Mac (Designed for iPad) 27.2")
  - ———
  - Simulators (section label), then one row per simulator "<name> <OS version>", the current one checked; newest runtime first; within a runtime iPhones, then iPads, then Apple Vision "(Designed for iPad, <runtime>)", each group by name
  - ———
  - Build (section label), "Any iOS Device (arm64)", "Any iOS Simulator Device (arm64, x86_64)"
  - ———
  - Incompatible ▸ — each row "<name> (<reason>) <OS version>"; reasons seen: "mismatched platform", "OS version lower than deployment target"; a duplicate name adds "(<runtime>)" before the reason
  - ———
  - Manage Devices… — ⇧⌘2
- Test Plan ▸
  - Select Next Test Plan
  - Select Previous Test Plan
  - ———
  - Edit Test Plan — ⌘>
  - New Test Plan…
  - Manage Test Plans…
  - ———
  - [✓] ObsApp (Autocreated)
- ———
- ———
- App Shortcuts Preview

**Debug**

- Pause — ⌃⌘Y
- Continue To Current Line — ⌃⌘C
- Step Over — F6
- Step Over Instruction — ⌃F6
- Step Over Thread — ⌃⇧F6
- Step Into — F7
- Step Into Instruction — ⌃F7
- Step Into Thread — ⌃⇧F7
- Step Out — F8
- ———
- Step Over and Follow Program Counter
- Step Into and Follow Program Counter
- Step Out and Follow Program Counter
- ———
- ———
- Deactivate Breakpoints — ⌘Y
- Breakpoints ▸
  - Create Breakpoint at Current Line — ⌘\
  - Enable Breakpoints at Current Line
  - Create Column Breakpoint
  - Delete Column Breakpoints at Current Line
  - Create Swift Error Breakpoint
  - Create Exception Breakpoint…
  - Create Symbolic Breakpoint… — ⌥⌘\
  - Create Test Failure Breakpoint
  - Delete All Breakpoints
- ———
- Console ▸
  - Copy Row with Visible Metadata — ⌥⇧C
  - Copy Row with All Metadata
  - Copy Row without Metadata
  - ———
  - Jump To Source — ⌥⇧⌘J
  - ———
  - Hide Similar Items ▸
    - Type '-'
    - Process '-'
    - PID '-'
    - Library '-'
    - Subsystem '-'
    - Category '-'
    - TID '-'
  - Show Similar Items ▸
    - Type '-'
    - Process '-'
    - PID '-'
    - Library '-'
    - Subsystem '-'
    - Category '-'
    - TID '-'
  - ———
  - Clear Console — ⌘K
  - Reload Console — ⌥⌘K
  - Select Last Output — ⌥⇧⌘A
- Debug Workflow ▸
  - [✓] Navigate to Source File when Process Pauses
  - Synchronize Insertion Point to Program Counter
  - Always Show Disassembly
  - Show Library Info…
  - View Memory — ⌃⌥⇧⌘M
  - Interrupt Debugger Operation — ⌃C
- ———
- Attach to Process by PID or Name…
- Attach to Process ▸
  - Getting Process List…
- Detach
- Debug Executable…
- Debug Crash Log…
- ———
- Capture GPU Workload
- Simulate Location ▸
- Induce Device Conditions ▸
- View Debugging ▸
  - Capture View Hierarchy
  - ———
  - Show View Frames
  - Show Alignment Rectangles
  - Show View Drawing
  - Show Responsive Scrolling Status
  - ———
  - Configure Environment Overrides…
  - Disable All Environment Overrides
  - ———
  - Rendering ▸
    - Color Blended Layers
    - Color Hits Green and Misses Red
    - Color Copied Images
    - Color Layer Formats
    - Color Immediately
    - Color Misaligned Images
    - Color Offscreen-Rendered Yellow
    - Color Compositing Fast-Path Blue
    - Flash Updated Regions
  - Appearance ▸
    - System Appearance
    - ———
    - Light
    - Dark
    - High Contrast Light
    - High Contrast Dark
- ———
- StoreKit ▸
  - Manage Transactions...
  - ———
  - Approve Transaction
  - Decline Transaction
  - Refund Purchase
  - Resolve Issue
  - Request Price Increase Consent
  - Edit Subscription
  - ———
  - Delete Transaction
- GameKit ▸
  - Manage Game Progress...
  - ———
- ———

**Integrate**

- Source Control
- Commit… — ⌥⌘C
- Push…
- Pull… — ⌥⌘X
- Fetch Changes
- Refresh File Status
- ———
- ———
- Stage All Changes
- Stage Changes in “Model.swift”
- Unstage All Changes
- Unstage Changes in Selected Files
- Mark Selected Files as Resolved
- ———
- Add Selected Files
- Cherry-Pick…
- Stash Changes…
- ———
- ———
- Discard All Changes…
- Discard Changes in “Model.swift”…
- ———
- Clone…
- New Git Repository…
- ———
- Xcode Cloud
- Create Workflow…
- Manage Workflows…

**Window**

- Minimize — ⌘M
- Minimize All — ⌥⌘M
- Zoom
- Zoom All
- Fill — ⌃F
- Center — ⌃C
- ———
- Move & Resize ▸ (system-provided or dynamic list; not recorded)
- Full Screen Tile ▸
  - Left of Screen
  - Right of Screen
- ———
- Move to <other display name>
- Move All to <other display name>
- ———
- Rename Window Tab… — ⌥⇧⌘T
- Show Previous Window Tab — ⌃⇧⇥
- Show Next Window Tab — ⌃⇥
- Move Tab to New Window
- Merge All Windows
- ———
- Developer Documentation — ⇧⌘0
- Welcome to Xcode — ⇧⌘1
- Downloads — ⇧⌘9
- Organizer — ⌥⇧⌘O
- ———
- Touch Bar ▸ (system-provided or dynamic list; not recorded)
- ———
- Bring All to Front
- Arrange in Front
- Arrange in Front
- Remove Window from Set
- ———

**Help**

- Developer Documentation — ⇧⌘0
- Human Interface Guidelines — ⇧⌘H
- ———
- Xcode Help
- What’s New in Xcode
- Release Notes
- Developer Account Help
- App Store Connect Help
- Swift Programming Language Book
- Provide Feedback…
- ———
- Hide Keyboard Hints — ⌥⌘?
- Show Quick Help for Selected Item — ⌃⌘?
- Search Documentation for Selected Text — ⌃⌥⌘/


### 1.10 Editor menu for other editors

Read with each file focused. The source-editor Editor menu is in §1.9.


**Editor menu, plist**

- Show Editor Only — ⌘↩
- ———
- [✓] Preview — ⌥⌘↩
- Assistant — ⌃⌥⌘↩
- Code Review — ⌥⇧⌘↩
- Layout ▸
  - [✓] Automatic
  - ———
  - Preview on Right
  - Preview on Bottom
- ———
- Add Item
- Value Type ▸
  - Array
  - Dictionary
  - ———
  - Boolean
  - Data
  - Date
  - Number
  - String
- ———
- Raw Keys and Values

**Editor menu, Main.storyboard**

- Show Editor Only — ⌘↩
- ———
- [✓] Preview — ⌥⌘↩
- Assistant — ⌃⌥⌘↩
- Code Review — ⌥⇧⌘↩
- Layout ▸
  - [✓] Automatic
  - ———
  - Preview on Right
  - Preview on Bottom
- ———
- Align ▸
  - Left Edges — ⌘[
  - Right Edges — ⌘]
  - Top Edges
  - Bottom Edges
  - ———
  - Horizontal Centers
  - Vertical Centers
  - Baselines
  - ———
  - Horizontally in Container
  - Vertically in Container
- Arrange ▸
  - Send to Front
  - Send to Back
  - Send Forward
  - Send Backward
- Size to Fit Content — ⌘=
- Update Frames — ⌥⌘=
- ———
- Embed In ▸
  - View
  - View Without Inset
  - Scroll View
  - Stack View
  - ———
  - Navigation Controller
  - Tab Bar Controller
- Unembed
- ———
- Resolve Auto Layout Issues ▸
  - Selected Views
  - Update Frames
  - Update Constraint Constants
  - Add Missing Constraints
  - Reset to Suggested Constraints — ⌥⇧⌘=
  - Clear Constraints
  - ———
  - All Views in Container
  - Update Frames
  - Update Constraint Constants
  - Add Missing Constraints
  - Reset to Suggested Constraints
  - Clear Constraints
- Refactor to Storyboard…
- Localization Locking ▸
  - [✓] Nothing
  - All Properties
  - Localizable Properties
  - Non-localizable Properties
  - ———
  - Reset Locking Controls
- ———
- ———
- [✓] Document Outline
- Reveal in Document Outline
- [✓] Minimap — ⌃⇧⌘M
- ———
- Canvas ▸
  - [✓] Constraints
  - Intrinsic Size Constraints Contributing To Ambiguity
  - Involved Views For Selected Constraints
  - Layout Rectangles
  - Bounds Rectangles
  - [✓] Device Bezels
  - [✓] Placeholder Backgrounds
- Zoom ▸
  - Zoom to 6.25%
  - Zoom to 12.5%
  - Zoom to 25%
  - Zoom to 50%
  - Zoom to 75%
  - Zoom to 100% — ⌃⌘=
  - Zoom to 125%
  - Zoom to 150%
  - Zoom to 200%
  - Zoom to 300%
  - Zoom to 400%
  - ———
  - Zoom to Fit
  - ———
  - Zoom In
  - Zoom Out
- ———
- [✓] Snap to Guides
- Guides ▸
  - Add Horizontal Guide — ⌘_
  - Add Vertical Guide — ⌃⌘|

**Editor menu, Assets.xcassets**

- Show Editor Only — ⌘↩
- ———
- [✓] Preview — ⌥⌘↩
- Assistant — ⌃⌥⌘↩
- Code Review — ⌥⇧⌘↩
- Layout ▸
  - [✓] Automatic
  - ———
  - Preview on Right
  - Preview on Bottom
- ———
- Add New Asset ▸
  - Image Set
  - Color Set
  - Symbol Image Set
  - Data Set
  - AR and Textures ▸
    - Texture Set
    - Sprite Atlas
    - Cube Texture Set
    - ———
    - AR Resource Group
    - AR Reference Image
    - AR Reference Object
  - ———
  - iOS ▸
    - iOS App Icon
    - iOS Launch Image (Deprecated)
    - Messages Extension Icon
    - ———
    - Sticker Pack
    - Sticker
    - Sticker Sequence
    - Sticker Sequence Frame
  - macOS ▸
    - macOS App Icon
    - macOS Generic Icon
    - Icon Status Badge
    - Sidebar Icon
  - watchOS ▸
    - watchOS App Icon
    - Complication Placeholder
  - tvOS ▸
    - tvOS App Icon and Top Shelf Image
    - tvOS Launch Image (Deprecated)
    - ———
    - Image Stack
    - Image Stack Layer
    - ———
    - Game Center Dashboard Image
    - Game Center Leaderboard
    - Game Center Leaderboard Set
  - visionOS ▸
    - visionOS App Icon
    - visionOS App Icon Layer
  - ———
  - Folder
  - Folder with Namespace
  - Folder from Selection
  - ———
  - Import…
- Delete Selected Items
- ———
- Device Image Reps ▸
  - Universal
  - iPhone
  - iPad
  - Mac Catalyst Scaled
  - CarPlay
  - Mac
  - Apple Vision
  - Apple Watch
  - Apple TV
- ———
- Find References to Item
- ———
- Quick Look
- Show in Finder
- Open in External Editor
- ———
- [✓] Show Overview
- Show Slicing

## 2. Fidelity matrix

**Ycode evidence.**

- Source at aa1bf7c (`ycode/Sources/YcodeUI/...`, file:line).
- A debug build of YcodeApp running on the same sample. It was launched in
  the background with clean defaults (its own bundle identifier) and read
  through the same accessibility tools.
- Three read-only code audits, one each against `reference-ui.md` with
  `-2`, `-3` and `-4`.

**Classes.**

- **missing:** the reference has it and Ycode has nothing.
- **wrong:** Ycode does something different (label, binding, default,
  behavior).
- **partial:** some of it is there.
- **cosmetic:** a visible look-and-feel difference with no functional
  effect.
- **matches:** listed only where this audit confirmed it.

**Priority.**

- **P0:** a daily Xcode user notices it in the first minute.
- **P1:** noticed in a normal working session.
- **P2:** depth.

"Ref" points to the spec section, or to §1 above for new observations.

### 2.1 Launch, windows, persistence

| ID | Feature | Ref | Ycode now | Class | Pri |
|---|---|---|---|---|---|
| L1 | Launch with no document shows the Welcome window | §1.1 | Shows an Open panel (`App/AppSupport.swift`:152) | missing | P0 |
| L2 | Window ▸ Welcome to Xcode ⇧⌘1 (Ycode: Welcome to Ycode) | §1.9 | Listed disabled, no shortcut (`Model/CommandTable.swift`:398) | missing | P0 |
| L3 | File ▸ Open Recent (recent workspaces, name or "name — folder", Clear Menu) | §1.9 | Listed disabled (`CommandTable.swift`:119) | missing | P0 |
| L4 | Window title "<project> — <document>"; Window-menu entry the same with a check mark | §1.2 | "ObsApp.xcodeproj" (`Window/WorkspaceWindowController.swift`:102) | wrong | P1 |
| L5 | Default frame 1400 × 900 (frame, toolbar included) | §1.2 | Content set to 1400 × 900, so the frame is 1400 × 949 (`WorkspaceWindowController.swift`:211) | cosmetic | P2 |
| L6 | Breakpoints persist per user with the project | `reference-ui-4.md` §6.4 | Held in memory only (`Model/WorkspaceModel.swift`:10, `Session/WorkspaceSession.swift`:50) | missing | P1 |
| L7 | Areas at first open: navigator shown, inspector shown, debug area hidden | §1.2 | Same | matches | — |
| L8 | Editor at first open with nothing selected: jump bar "No Selection" visible | §1.2 | Start Page (Open Quickly + Recent Files) laid over the whole editor, hiding the jump bar (`Window/WorkspaceWindowController+EditorExtras.swift`:17) | wrong (to confirm live, §5) | P2 |
| L9 | Start Page recents survive relaunch | `reference-ui-4.md` §9 | Kept in memory only (`Navigator/NavigatorAreaController.swift`:160) | partial | P2 |

### 2.2 Menu bar

The reference menus are listed in §1.9. A title-by-title diff of the
validated reference menu bar (source editor focused) against Ycode's live
menu bar gives raw counts. These include system lists such as the
language list and the device rows:

- 418 reference items are absent from Ycode or titled differently.
- 94 of those carry a default shortcut.
- 71 items exist in both but Ycode lacks the reference shortcut or uses
  another one.

The table groups them.

| ID | Feature | Ref | Ycode now | Class | Pri |
|---|---|---|---|---|---|
| M1 | Shortcut conflicts: ⇧⌘A is View ▸ Show Quick Actions… (Ycode: Show Code Actions); ⌘0 is Show Coding Assistant (Ycode: Show/Hide Navigator); ⌥⌘0 is Editor ▸ Show Coding Tools ▸ Show Coding Tools… (Ycode: Show/Hide Inspector); ⌥⇧⌘← / → are Fold / Unfold Methods & Functions (Ycode: Fold All / Unfold All) | §1.9 | `CommandTable.swift`:195, 201; `Model/EditorMenu.swift`:28, 50-51 | wrong | P0 |
| M2 | Re-Indent ⌃I lives in Editor ▸ Structure | §1.9 | In Edit ▸ Format (`CommandTable.swift`:173) | wrong | P0 |
| M3 | Missing default shortcuts on commands Ycode lists: Save All ⌥⌘S, Duplicate… ⇧⌘S, Save As… ⌥⇧⌘S, Print… ⌘P, Add Files… ⌥⌘A, Workspace… ⌃⌘N, Duplicate ⌘D, Delete ⌘⌫, the four Bookmark ⌃⌘' shortcuts, the Find-in-Project / Find-and-Select / Select Occurrence group, the Navigate focus/reveal/bookmark/program-counter group, Run… ⌥⌘R and the other Product alternates, Build For ⇧⌘R/U/I, Run Without Building ⌃⌘R, Clean Build Folder Immediately ⌥⇧⌘K, Clear Test Results ⌃⌥⌘K, Build Documentation ⌃⇧⌘D, Continue To Current Line ⌃⌘C, Step Over/Into Instruction ⌃F6/⌃F7, Step Over/Into Thread ⌃⇧F6/⌃⇧F7, window-tab ⌥⇧⌘T ⌃⇧⇥ ⌃⇥, Show All Window Tabs ⇧⌘\, Edit All in Scope ⌃⌘E, Show Predictive Completion ⌃⌥Space | §1.9 | Listed without shortcut (most are `unavailable`) | missing | P0 |
| M4 | View ▸ Editor submenu holds the jump-bar commands: Focus Editor Pane ⌃⇧⌘↩, Show Related Items ⌃1, Show Previous History ⌃2, Show Previous Files History ⌃⌘2, Show Next History ⌃3, Show Next Files History ⌃⌘3, Show Top Level Items ⌃4, Show Group Files ⌃5, Show Document Items ⌃6 | §1.9 | Holds Canvas, Assistant, Code Review, Minimap, repeating the Editor menu's shortcuts (`CommandTable.swift`:180-185) | wrong | P0 |
| M5 | Editor ▸ Font Size ▸ Increase ⌘+, Decrease ⌘-, Reset ⌃⌘0 | §1.9 | Three disabled items without shortcuts (`EditorMenu.swift`:53) | missing | P0 |
| M6 | Editor ▸ Structure: Re-Indent ⌃I, Shift Left ⌘[, Shift Right ⌘] — Reformat To Width ⌃⌥I, Format to Multiple Lines ⌃M, Format Selection ⌃⌥⇧I, Format File ⌃⇧I (Swift files append " with ‘swift-format’") — Move Line Up ⌥⌘[, Move Line Down ⌥⌘], Comment Selection ⌘/, Add Documentation ⌥⌘/ | §1.9 | Shift Left, Shift Right, Comment Selection only (`EditorMenu.swift`:41-45) | partial | P0 |
| M7 | Editor ▸ Code Folding: Fold ⌥⌘←, Unfold ⌥⌘→, Unfold All — Fold/Unfold Methods & Functions ⌥⇧⌘← / → — Fold/Unfold Comment Blocks ⌃⇧⌘← / → | §1.9 | Fold, Unfold, Fold All ⌥⇧⌘←, Unfold All ⌥⇧⌘→ (`EditorMenu.swift`:46-52) | wrong | P0 |
| M8 | Option-alternates are hidden until ⌥ (or ⌃) is held: Run…, Test…, Profile…, Analyze…, Archive…; Close Other Tabs, Close Other Editor Panes, Close Other Window Tabs; Save All, Save As…; Choose Template…; Conversation in New Tab / in Editor Pane; the "using Tab" / "in Next Editor Pane" history, definition and counterpart variants; Minimize All, Zoom All, Arrange in Front | §1.9 | Shown as separate visible (mostly disabled) items. The Window menu lists Minimize All and Zoom All twice (Ycode's own plus AppKit's) | wrong | P1 |
| M9 | Dynamic titles (list in §1.9) | §1.9 | Static titles, except Close Window/Close Tab and Show/Hide toggles | partial | P1 |
| M10 | Edit submenus: Copy (Copy, Copy File and Line ⌃⌥⌘C, Copy Symbol Name ⌃⇧⌘C, Copy Qualified Symbol Name ⌃⌥⇧⌘C); Paste (Paste, Move Item Here ⌥⌘V, Paste and Preserve Formatting ⌥⇧⌘V); Sort (By Name, By Type); Format (the system text Format menu); Convert (To Group, To Folder, Preflight Conversion To Folder, To String Catalogs…) | §1.9 | Copy and Paste plain; Sort ▸ Sort Lines; Format ▸ Re-Indent; Convert ▸ To Uppercase (`CommandTable.swift`:160-174) | wrong | P1 |
| M11 | View: Show Quick Actions… ⇧⌘A; Reset Assistant Selection ⌥⇧⌘Z; Filter in Navigator ⌥⌘J; Open Library ⌥⇧⌘L; Reload Organizer ⌃R; Inspectors submenu lists the current inspector tabs (⌥⌘1…) then Show/Hide Inspector without shortcut; Debug Area submenu lists Activate Console ⇧⌘C first, then a separator, then Show/Hide Debug Area ⇧⌘Y | §1.9 | Quick Actions disabled; inspectors fixed; order differs | partial | P1 |
| M12 | Navigate additions: Reveal in Changes Navigator ⇧⌘M, Reveal in Debug Navigator ⇧⌘D, Open using Tab ⌥⌘, / Open in Next Editor Pane ⌥⌘<, Move Focus (⌥⌘`, ⌥⇧⌘`, ⌃`, ⌃⇧`, ⌘J), Jump to Selection ⌥⌘L, Jump to Last Destination, bookmarks ⌃; ⌃⌥; ⌃: ⌃⌥:, Jump to Program Counter ⌃⌘P, Jump to Next/Previous Counterpart ⌃⌘↑ / ⌃⌘↓, Jump to Line in “<file>”… ⌘L (after the counterpart group), Jump to Next/Previous Placeholder ⌃/ ⌃?, Jump to Next/Previous Change ⌃\ ⌃\| with "Local or Upstream" ⌥ variants | §1.9 | Most listed disabled without shortcuts; counterparts, placeholders and changes are absent; Jump to Line… ⌘L is present with a static title | partial | P1 |
| M13 | Find titles "… in Project" / "… in Workspace" by container, "Find in Project" without an ellipsis, and the workspace-search commands working | §1.9 | Static "Find in Workspace…"; the rest disabled | partial | P1 |
| M14 | Editor menu varies with the focused editor: source; property list (Add Item, Value Type ▸, Raw Keys and Values); storyboard (Align, Arrange, Size to Fit Content ⌘=, Update Frames ⌥⌘=, Embed In, Resolve Auto Layout Issues, Localization Locking, Document Outline, Canvas ▸, Zoom ▸, Snap to Guides, Guides ▸); asset catalog (Add New Asset ▸, Delete Selected Items, Device Image Reps ▸, Find References to Item, Quick Look, Show in Finder, Open in External Editor, Show Overview, Show Slicing). The canvas item is titled "Preview" for non-source editors. Layout ▸ is Automatic / Editor on Left / Editor on Top (source) or Automatic / Preview on Right / Preview on Bottom | §1.9 | One static source-editor menu, plus "Line Numbers" and "Add New Constraints…" always present (`EditorMenu.swift`:68, 76); Layout ▸ holds Assistant Mode and Split Editor | wrong | P1 |
| M15 | Editor ▸ Selection: Select All Symbols, Split Selection By Lines, Balance Delimiters — Select Column Up ⌃⇧↑, Select Column Down ⌃⇧↓ (multiple insertion points) | §1.9 | "Select Enclosing Scope", disabled | missing | P1 |
| M16 | Editor ▸ Show Coding Tools ▸ Show Coding Tools… ⌥⌘0 — Explain, Document, Generate a Playground, Generate a Preview | §1.9 | Holds Show Code Actions ⇧⌘A | wrong | P2 (Ycode has no assistant; only the binding matters, M1) |
| M17 | Editor ▸ Syntax Coloring ▸ Default for File Type, None, then one item per language | §1.9 | "Automatic", disabled | missing | P2 |
| M18 | Product: Build For ▸, Perform Action ▸ (Run/Test/Profile Without Building ⌃⌘R/U/I, Build with Timing Summary, Build and Export Test Products, Test (selected) ⌃⌥⌘U, Test Again ⌃⌥⌘G, Test Without Building Again, Profile, Profile Again, Compile “<file>” ⌃⌘B, Analyze “<file>” ⌃⇧⌘B, Preprocess / Assemble “<file>”, Generate Optimization Profile…), Export / Import Localizations…, Scheme ▸ list with check, Destination ▸, Test Plan ▸ | §1.9 | Mostly disabled placeholders; Destination ▸ has "Manage Run Destinations…", Test Plan ▸ "New Test Plan" | partial | P1 (build-system work) |
| M19 | Debug: Breakpoints ▸ (Create Breakpoint at Current Line ⌘\, Enable/Disable Breakpoints at Current Line, Create Column Breakpoint, Delete Column Breakpoints at Current Line, Create Swift Error Breakpoint, Create Exception Breakpoint…, Create Symbolic Breakpoint… ⌥⌘\, Create Test Failure Breakpoint, Delete All Breakpoints); Console ▸ (Copy Row with Visible Metadata ⌥⇧C, …, Jump To Source ⌥⇧⌘J, Hide/Show Similar Items ▸, Clear Console ⌘K, Reload Console ⌥⌘K, Select Last Output ⌥⇧⌘A); Debug Workflow ▸ (Navigate to Source File when Process Pauses, on; Synchronize Insertion Point to Program Counter; Always Show Disassembly; Show Library Info…; Load Symbols…; View Memory ⌃⌥⇧⌘M; Interrupt Debugger Operation ⌃C) | §1.9 | Breakpoints ▸ holds one item, "Add/Remove Breakpoint at Current Line"; Console ▸ holds Clear Console; Debug Workflow adds Ycode's "View Process by Queue" | partial | P1 |
| M20 | Integrate: "Source Control" and "Xcode Cloud" are disabled section labels, not submenus; selection-dependent titles; Create Pull Request… | §1.9; `reference-ui-4.md` §3 | "Source Control ▸ Branches" submenu, static titles | wrong | P1 |
| M21 | Window: Developer Documentation ⇧⌘0, Welcome ⇧⌘1, Downloads ⇧⌘9; Touch Bar ▸ and the tiling items come from the system | §1.9 | Developer Documentation and Welcome disabled, no shortcuts; no Downloads | partial | P2 |
| M22 | Help: Developer Documentation ⇧⌘0, Human Interface Guidelines ⇧⌘H, the help and documentation links, Provide Feedback…, Show/Hide Keyboard Hints ⌥⌘?, Show Quick Help for Selected Item ⌃⌘?, Search Documentation for Selected Text ⌃⌥⌘/ | §1.9 | "Ycode Help" only | missing | P2 |
| M23 | Application menu: Open Developer Tool ▸ (Instruments, Device Hub, Icon Composer, Accessibility Inspector, FileMerge, Create ML, More Developer Tools…); Behaviors ▸ shows "No Custom Behaviors" and Edit Behaviors…; Quit and Keep Windows ⌥⌘Q | §1.9 | Instruments only; Quit and Keep Windows disabled, no shortcut | partial | P2 |
| M24 | AppKit's automatic items must not clash: Ycode gets "Close All ⌥⇧⌘W" (the reference's Close Other Window Tabs) and "Enter Full Screen" fn-F (the reference uses ⌃⌘F) | §1.9 | As described | wrong | P1 |
| M25 | File ▸ New: New File from Clipboard, Choose Template… (⌥ alternate), Workspace… ⌃⌘N, Group / Group without Folder / Group from Selection / Group from Selection without Folder | §1.9 | Workspace…, Target…, Folder from Selection disabled; the rest absent | partial | P2 |
| M26 | File ▸ Packages ▸ Reset Package Caches, Resolve Package Versions, Update to Latest Package Versions; File ▸ Project Settings… / Workspace Settings… | §1.9 | Resolve only; Settings disabled | partial | P2 |

### 2.3 Toolbar and window chrome

| ID | Feature | Ref | Ycode now | Class | Pri |
|---|---|---|---|---|---|
| T1 | Default destination of an iOS app project is an iOS simulator | §1.2 | "My Mac" (seen running) | wrong | P0 |
| T2 | Navigators \| Coding Assistant: an exclusive pair whose selection follows the left area; clicking the selected segment hides the area | §1.3 | Independent checkbox segments; state set only by toolbar clicks, so it is wrong at open and after ⌘0 (`WorkspaceWindowController.swift`:1459-1464) | wrong | P1 |
| T3 | Editor Mode: at most one of Canvas, Assistant, Code Review; tooltips "Show Canvas" / "Show Assistant" / "Show Code Review" | §1.3 | Independent toggles (`.selectAny`, :41-44, 893, 934, 1878); tooltips "Canvas" … | wrong | P1 |
| T4 | Activity area: project icon + name, no idle subtitle | §1.3 | Name + "Ready" (`Window/ActivityView.swift`:8) | wrong | P1 |
| T5 | Tooltips on Run, Stop, Go Back, Go Forward | §1.3 | None | cosmetic | P2 |
| T6 | "New Conversation" button before the scheme pill | §1.3 | Absent | cosmetic | P2 |
| T7 | Accessibility names "Active Scheme" / "Active Run Destination" | §1.3 | Both "Scheme" | cosmetic | P2 |
| T8 | Project-level issues in the capsule (missing team, "Update to recommended settings") | §1.2 | No such checks | missing | P2 (project/build-system) |
| T9 | Account button vs Xcode Cloud Notices | §1.3 | Ycode keeps its account image (no cloud service) | matches (deliberate) | — |

### 2.4 Navigators

| ID | Feature | Ref | Ycode now | Class | Pri |
|---|---|---|---|---|---|
| N1 | Project navigator hides the Products group | §1.2 | Shows "Products ▸ ObsApp.app" | wrong | P0 |
| N2 | File extensions hidden by default (Hide All is the factory default) | §0 | Default Show All (`Model/Preferences.swift`:40) | wrong | P0 |
| N3 | Status letters on files only | §1.2 | "M" on the project and on folders (`NavigatorAreaController.swift`:853-868) | wrong | P1 |
| N4 | Root and first group expanded at open | §1.2 | Root only | wrong | P1 |
| N5 | Package root order: Package, Sources, Tests | `reference-ui-2.md` §10 | Plain alphabetical directory list; manifest shows as "Package.swift" | partial | P1 |
| N6 | Per-navigator bottom bars: toggles, "+" vs "…", tooltips; Find has a plain filter; Issues has no "+" | §1.4 | One shared bar whose two toggles change meaning; tooltips shorter; Bookmarks and Tests have no toggles; Reports' leading button shows Project items | partial | P1 |
| N7 | Empty states with a second line ("Click the '…' button to add bookmarks", "Click the ⊕ button to add test targets"); Reports reads "No Logs" | §1.4 | First lines only; Reports reads "No Reports" | partial | P2 |
| N8 | Test navigator header: plan pop-up, Mode: Group by Test Hierarchy / Group by Tags; status diamonds at the right end | §1.4; `reference-ui-2.md` §6.1-6.2 | No header; diamonds at the left | missing | P1 |
| N9 | Issue navigator: issues with no file sit directly under the root | §1.2 | Grouped under "Build System" (`Navigator/IssueNavigatorModel.swift`:102) | wrong | P2 |
| N10 | Stale issues are replaced by the next build, not only by Clean | `reference-ui-2.md` §1.5 | Cleared only on Clean (`WorkspaceWindowController.swift`:1354) | wrong | P1 |
| N11 | Issue groups use the file-type icon | `reference-ui-2.md` §1.1 | Generic document icon | cosmetic | P2 |
| N12 | Debug navigator bottom bar: three toggles as listed | §1.4 | Two | partial | P2 |
| N13 | Find navigator: recent-search history; kinds other than Text and Regular Expression | `reference-ui-2.md` §3 | Absent / disabled | partial | P2 |
| N14 | Bookmarks: "…" menu, "Incomplete Items" filter (bookmarks have a done state) | §1.4 | "+", no done state | missing | P2 |

### 2.5 Editor area and source editor

| ID | Feature | Ref | Ycode now | Class | Pri |
|---|---|---|---|---|---|
| E1 | Jump bar: Related Items then the path, no back/forward buttons | §1.5 | Grid, back, forward, path (`Editor/SourceEditorController.swift`:270-323) | wrong | P1 |
| E2 | Jump bar right end: previous issue, Issues pull-down, next issue | §1.5; `reference-ui-2.md` §2.4 | Absent | missing | P1 |
| E3 | Change gutter: bars for local changes left of the line numbers, in normal editing, with tooltips; Navigate ▸ Jump to Next/Previous Change | §1.5 | None outside Code Review | missing | P1 |
| E4 | Assistant jump bar: close button + mode pop-up, no history buttons | §1.8 | Related, back, forward, pop-up; no close button | wrong | P1 |
| E5 | Minimap width scales with the editor (about 13–15 %), with declaration landmarks | §1.5 | Fixed 110 pt | cosmetic | P2 |
| E6 | Branch button in the debug bar opens a branch menu; it sits left of the debug-area toggle, which is at the far right | §1.2 | A label; the toggle sits left of the branch | partial | P2 |
| E7 | Font size commands, line move, column selection, folding variants (M5–M7, M15) | §1.9 | See the menu rows | — | — |

### 2.6 Inspectors

| ID | Feature | Ref | Ycode now | Class | Pri |
|---|---|---|---|---|---|
| I1 | File inspector: Working Copy, Relative Path, On Demand Resource Tags, Target Membership (list, +, −, edit) | §1.6 | Absent (`Inspector/InspectorAreaController.swift`:124-170) | missing | P1 |
| I2 | History inspector: commits that touched the file | §1.6 | Always "No History" (:114) | missing | P1 |
| I3 | Quick Help empty: "No Quick Help" + "Search Documentation" | §1.6 | Text only | partial | P2 |
| I4 | Nothing selected: "Not Applicable", centered | §1.2 | "No Selection" at the top left | cosmetic | P2 |
| I5 | Tab bar: full-width segmented tabs with tooltips | §1.6 | Small icon buttons | cosmetic | P2 |
| I6 | Asset catalog attributes in a fourth inspector tab | `reference-ui-3.md` §3.1 | Drawn inside the editor | wrong | P2 |

### 2.7 Debug area and debugger

| ID | Feature | Ref | Ycode now | Class | Pri |
|---|---|---|---|---|---|
| D1 | Variables bar second button is "Print Description" | §1.7 | An info button | cosmetic | P2 |
| D2 | Debug-area height 135 when a behavior opens it | `reference-ui.md` §5 | Un-collapses to the last height | partial | P2 |
| D3 | Process row buttons; Energy Impact bar; third bottom toggle | `reference-ui-4.md` §5.3 | Absent | partial | P2 |
| D4 | Debug View Hierarchy, Memory Graph | `reference-ui-4.md` §5.4 | "Not available" popovers | partial | P2 (simulator-side) |
| D5 | Debug navigator, threads, frames, A/L badges, end-of-session lines, breakpoint navigator, Quick Help sections | `reference-ui-4.md` §5–§7 | Implemented | matches | — |

### 2.8 Settings

| ID | Feature | Ref | Ycode now | Class | Pri |
|---|---|---|---|---|---|
| S1 | General: Starting Points, Navigator size, three navigator-detail rows, independent sidebar widths, automatically unlock files, Issue presentation, Stop build on first error, Test Parallelization (2), Report history, Import/Export, Reset | `reference-ui.md` §4 | File extensions and Predictive Issues only (`App/SettingsPanes.swift`:131-139) | missing | P1 |
| S2 | Navigation pane rows (New Editor Tabs / Panes Open With, Pin Editor Tabs, Click on Code with modifiers, navigation destination and modifier routing, two toggles) | `reference-ui.md` §4 | Ycode's own "Activation" and "Navigation Style" (:307-318) | wrong | P1 |
| S3 | Editing ▸ Display rows (code structure headers, MARK separators, coverage counts, #endif condition, scope guides, reformat column / guide / auto, dim inactive code, overscroll, doc-comment fades) | `reference-ui.md` §4 | Absent; Ycode adds Minimap and Page guide | wrong | P1 |
| S4 | Editing main page: Convert existing files on save; string-catalog comments | `reference-ui.md` §4 | Absent | missing | P2 |
| S5 | Appearance: thumbnails, live preview, per-token theme and font rows | `reference-ui.md` §4 | Segmented control, five token wells | partial | P2 |
| S6 | Behaviors: categories, counts, action labels ("Debugger: Hide Debugger If No Output", "Notify with bezel or system notification") | `reference-ui.md` §4 | Fewer categories; Ycode's own labels | partial | P2 |
| S7 | Pane list names | `reference-ui.md` §4 | "Accounts" (no trademark) and an added "Simulators" | matches (deliberate) | — |

### 2.9 Project editor, catalogs, destinations, templates, schemes, reports

The rows below come from the reference-ui-3 code audit and the
reference-ui-2 audit, with file references in those audits.

| ID | Feature | Ref | Ycode now | Class | Pri |
|---|---|---|---|---|---|
| P1 | Build Settings default filter Basic | `reference-ui-3.md` §1.8 | Customized (`Project/ProjectEditorController.swift`:25) | wrong | P1 |
| P2 | Left-column footer (+, −, Filter) and collapse button | §1.2 | Absent | missing | P2 |
| P3 | Resource Tags, Build Rules, Project ▸ Info, Package Dependencies drawn as controls (+/−, scopes, tables, buttons) | §1.6, §1.10–§1.12 | Plain text rows | partial | P2 |
| P4 | Build Phases: Run Build Tool Plug-ins row; no configuration pop-up | §1.9 | Row missing; a configuration pop-up is shown | partial | P2 |
| P5 | Info tab: readable names for generated keys; expandable containers; `$(…)` values | §1.7 | Raw names for `INFOPLIST_KEY_*` rows; containers don't expand | partial | P2 |
| P6 | General: working +/−, info and "+" / "→" buttons; App Category list | §1.4 | Present but inert | partial | P2 |
| P7 | Asset catalog: folders as rows, all "+" items creatable | `reference-ui-3.md` §3 | Flat list; some items disabled | partial | P2 |
| P8 | Plist editor keeps key order for binary plists too | `reference-ui-3.md` §2 | Binary plists sorted | partial | P2 |
| P9 | Destination ordering: newest runtime first, then iPhone / iPad / Vision by name; Incompatible ▸ rows carry a reason; Vision rows "(Designed for iPad, <runtime>)" | §1.9 | Family then name, no runtime grouping; no reasons; extra "Ycode" section | partial | P2 |
| P10 | Choose Template… opens an empty workspace window; templates have content; save sheet Group list and current target | `reference-ui-3.md` §5 | Plain "Untitled" window; most templates create empty files | partial | P2 |
| P11 | Scheme editor footers, empty states, Test plan subtitle and go-to arrow, Duplicate Scheme | `reference-ui-2.md` §7 | Partial | partial | P2 |
| P12 | Test report Tests filters, expandable coverage | `reference-ui-2.md` §6 | Static filters, flat coverage | partial | P2 |
| P13 | Test run activity text | `reference-ui-2.md` §2.3 | "Test Succeeded" when all pass; the reference showed "Test Completed" with a failure (all-pass text unobserved) | to confirm | P2 |
| P14 | IB inspector leftovers (Key Commands table, colour tags, Arrange, Layout Margins, Sizing Rule, Shadow Offset, Stretching, per-trait "+", scene object icons, canvas overview) | `reference-ui-4.md` §13 | Absent | partial | P2 |
| P15 | Preview "Preparing <family> Simulator" activity | `reference-ui-4.md` §17.1 | Absent | missing | P2 (simulator-side) |
| P16 | Commit inspector Files with icons | `reference-ui-4.md` §2.6 | Plain text | cosmetic | P2 |

### 2.10 The remote "Run on Ycode Simulator" destination

| ID | Feature | Ref | Ycode now | Class | Pri |
|---|---|---|---|---|---|
| R1 | Simulators are listed in the "Simulators" section as "<name> <OS version>" | `reference-ui-3.md` §4 | The remote device is in a separate "Ycode" section | partial | P2 |
| R2 | Simulator run activity strings and console behavior | not observed (§5) | Ycode's own "(1 of 3)" status sequence (`specs/ide/run.md`) | to confirm | P2 (simulator-side) |

## 3. Gap counts

Rows of §2, not counting the four "matches" rows (L7, T9, D5, S7), the two
"to confirm" rows (P13, R2) and the pointer row E7:

| Class | P0 | P1 | P2 | Total |
|---|---|---|---|---|
| missing | 5 | 8 | 7 | 20 |
| wrong | 7 | 17 | 4 | 28 |
| partial | 1 | 8 | 27 | 36 |
| cosmetic | 0 | 0 | 10 | 10 |
| **Total** | **13** | **33** | **48** | **94** |

The rows in each cell:

- **P0** (13):
  - missing: L1, L2, L3, M3, M5;
  - wrong: M1, M2, M4, M7, T1, N1, N2;
  - partial: M6.
- **P1** (33):
  - missing: L6, M15, N8, E2, E3, I1, I2, S1;
  - wrong: L4, M8, M10, M14, M20, M24, T2, T3, T4, N3, N4, N10, E1, E4,
    S2, S3, P1;
  - partial: M9, M11, M12, M13, M18, M19, N5, N6.
- **P2** (48):
  - missing: M17, M22, T8, N14, S4, P2, P15;
  - wrong: L8, M16, N9, I6;
  - partial: L9, M21, M23, M25, M26, N7, N12, N13, E6, I3, D2, D3, D4,
    S5, S6, P3–P12, P14, R1;
  - cosmetic: L5, T5, T6, T7, N11, E5, I4, I5, D1, P16.

Row M3 alone stands for the 71 shortcut differences on items both menu bars share. The 94 shortcut-carrying items Ycode lacks are spread over M4–M7, M12, M15, M18, M19, M21 and M22.

## 4. Corrections this audit makes to earlier notes and specs

- **`reference-ui.md` §3: no back/forward in the jump bar.** It put
  back/forward buttons in the jump bar. In 27.1 the jump bar starts with
  Related Items and the path. History is in the toolbar.
- **Minimap width scales with the editor.** It is not a fixed ~110 pt
  (§1.5).
- **The ⌘0 and ⌥⌘0 shortcuts.**
  - ⌘0 is View ▸ Navigators ▸ Show Coding Assistant.
  - Show/Hide Navigator and Show/Hide Inspector have no default shortcut.
  - ⌥⌘0 is Editor ▸ Show Coding Tools ▸ Show Coding Tools….
  - `menus.md` and `workspace-window.md` had the shortcuts of older Xcode
    releases.
- **Code folding shortcuts.** ⌥⇧⌘← / → fold and unfold methods and
  functions. There is no "Fold All". "Unfold All" has no shortcut.
- **Jump to Line ⌘L.** It exists, with the title "Jump to Line in
  “<file>”…". It is placed after the counterpart commands in Navigate and is
  shown only while a source editor is focused.
- **Splits are not in the Editor menu.** Split commands are File ▸ New ▸
  Editor Pane On Right ⌃⌘T and Editor Pane Below ⌃⌥⌘T. The Editor menu's
  Layout ▸ chooses where the editor sits relative to the canvas.
- **No Devices and Simulators window item.** Product ▸ Destination ▸
  Manage Devices… ⇧⌘2 and the destination menu are the entry points (as
  `reference-ui-4.md` §14.3 said). Xcode ▸ Open Developer Tool also lists a
  "Device Hub".
- **Find navigator scope.** In a project the scope reads "In Project".
  This confirms the inference in `reference-ui-2.md` §3.5. It briefly read
  "In Workspace" while the project was loading.
- **Issues without a file** (the project-level "Update to recommended
  settings") are rows directly under the root. They are not in a group.
- **Destination ordering, refined.** Newest runtime first. Within a
  runtime: iPhones, then iPads, then Apple Vision, each group by name. The
  user-named devices in pass 3 came first only because they were on the
  newest runtime.

## 5. Observations that still need a live (frontmost) pass

Each needs Xcode frontmost with the sample project
(`/Volumes/MARCUS-PROJECTS/_inbox/ycode-observe-ide-audit/ObsApp`) in full
screen. Steps are given in order.

1. **Context menus.** Right-click, record the item order, separators and
   shortcuts, then press Escape:
   - a file row in the project navigator;
   - a group row;
   - the project row;
   - the source editor (a symbol, empty space, and a selection);
   - an editor tab (with the tab bar shown);
   - each jump-bar component;
   - an issue row;
   - a breakpoint in the gutter and in the Breakpoint navigator;
   - a Source Control navigator change row and a branch row;
   - a variables-view row;
   - the console.
2. **Toolbar and bar menus.** Click each and record its items:
   - Add Editor;
   - Editor Options;
   - the scheme pop-up (rows, "Edit Scheme…", "New Scheme…", "Manage
     Schemes…");
   - the Related Items menu (⌃1);
   - jump-bar ⌃4 / ⌃5 / ⌃6 (do the menus filter as you type?);
   - the Issues pull-down at the jump bar's right end;
   - the debug-bar branch button;
   - each navigator's "+" / "…" and filter-options menus;
   - the Welcome window's New Project pull-down.
3. **Settings (⌘,).** Skip Apple Accounts and Intelligence. Record each pane
   with its rows and defaults:
   - Notifications, Shortcuts (layout, search, conflict handling), Source
     Control, Components, Locations (where the build-system choice lives);
   - Editing ▸ Completion and Editing ▸ Indentation;
   - the rest of General.
4. **Open Quickly (⇧⌘O).**
   - Panel layout and row format.
   - Type "mod" and record the ranking and secondary text.
   - Type "Model.swift:7" (does it jump to a line?).
   - Type "Mo/Mo" (path matching).
5. **Show Quick Actions… (⇧⌘A):** palette layout, first rows, what typing
   matches.
6. **Start Page and first open.**
   - File ▸ New ▸ Tab (⌘T) with Settings ▸ Navigation "New Editor Tabs Open
     With: Start Page": record the Start Page.
   - Reopen the workspace with nothing selected and record whether the editor
     area is blank or shows the Start Page.
7. **Library (⇧⌘L):** the tabs, layout, and filter, with a Swift file and
   with the storyboard focused.
8. **Find bar (⌘F) in the source editor.**
   - Layout and the option pop-ups.
   - The Replace row (⌥⌘F).
   - The match-count text.
   - Then run Find in Project and record the result row format.
9. **Completion (⌃Space)** after "Counter().": popup layout, icons, detail
   column, documentation area.
10. **Edit ▸ Copy and Paste variants.** Open the Edit menu and hold ⌃, ⌥,
    ⌃⌥, ⌃⇧. Record whether "Copy File and Line" etc. replace "Copy" in place
    (alternates) or sit in a submenu.
11. **Debug menu.** Open it and hold ⌃ and ⌃⇧ to confirm the
    Instruction/Thread step items are alternates. Do the same for Find
    (⌥ on Find Next / Find Previous) and Navigate (⇧ on the Move Focus
    items).
12. **Run on a simulator.**
    - Create `ycode-test-ide-audit` (iPhone 18 Pro, iOS 27.1) with `xcrun
      simctl create`.
    - Choose it in the destination menu and press ⌘R.
    - Record the activity-view strings in order, the console, and the
      Simulator app behavior.
    - Stop with ⌘.
    - Delete the device afterwards.
13. **Test run with all tests passing** (package "Obs", fix the failing
    test in a copy): the activity-view result text ("Test Succeeded" or
    "Test Completed").
14. **Coding assistant shortcuts.**
    - With the coding assistant shown, is "Show Coding Assistant ⌘0"
      retitled "Hide Coding Assistant"?
    - Does ⌘0 toggle back to the navigator?
15. **Project editor's Editor menu.** Select the project row; record the
    Editor menu for General, Build Settings and Build Phases.
16. **Help ▸ Show/Hide Keyboard Hints (⌥⌘?):** what appears.
