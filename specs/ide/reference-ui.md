# Reference IDE user interface (Xcode 27.1): observed layout and defaults

Spec status: boundary document. It records black-box observations (level 3)
of the reference IDE's user interface, so that Ycode's shell can match them.
It describes what was seen: names, order, placement, sizes and default
values. It describes no implementation. Theme color values were deliberately
not recorded; Ycode's themes stay its own. Where a value may be a user choice
on the observing machine rather than a factory default, the text says so.

Supersedes the OPEN QUESTIONs in workspace-window.md, menus.md, navigators.md,
source-editor.md, settings.md and debug.md wherever they conflict.

Observing conditions: our own sample Swift package ("Demo", one executable
target) on macOS in dark appearance. Sizes are in window points. The 1,400 ×
900 window size came from saved state, not a factory default.

## 1. Menu bar

Top-level menus, in order: (application menu) Xcode, File, Edit, View, Find,
Navigate, Editor, Product, Debug, Integrate, Window, Help. The source-control
menu is named **Integrate**.

- **Xcode:** About Xcode, Xcode Extensions…, Settings…, Behaviors (submenu),
  Open Developer Tool (submenu), Services, Hide Xcode, Hide Others, Show All,
  Quit Xcode, Quit and Keep Windows.
- **File:** New (submenu), Add Files…, Add Package Dependencies…, Open…,
  Open Recent, Open Quickly…, Close Tab, Editor Pane, Window Tab, or Window;
  Close Other Tabs, Close Document, Close Editor Pane, Close Other Editor
  Panes, Close Window Tab, Close Other Window Tabs, Close Workspace, Duplicate
  Editor Tab, Save, Save All, Duplicate…, Save As…, Revert to Saved…,
  Unlock…, Export…, Show in Finder, Open Terminal at Location, Open in New
  Tabs, Open in New Window, Open with External Editor, Packages (submenu),
  Save As Workspace…, Workspace Settings…, Page Setup…, Print….
- **Edit:** Undo, Redo, Cut, Copy, Paste, Duplicate, Delete, Select All,
  Bookmark Line, Bookmark Line With Dialog, Bookmark File, Bookmark File With
  Dialog, Sort, Format, Convert, AutoFill (submenus where applicable), Start
  Dictation…, Emoji & Symbols.
- **View:** Editor (submenu), Show Editor Tab Bar, Pin Editor Tab, Change
  Editor Orientation, Reset Editor Sizes, Reset Assistant Selection, Show
  Quick Actions…, Navigators (submenu), Debug Area (submenu), Inspectors
  (submenu), Show Library, Open Library, Reload Organizer, Choose Theme…,
  Show Toolbar, Customize Toolbar…, Show Window Tab Bar, Show All Window
  Tabs, Enter Full Screen.
  - View ▸ Navigators: Project, Source Control, Bookmarks, Find, Issues,
    Tests, Debug, Breakpoints, Reports, Show Coding Assistant, Show Navigator,
    Filter in Navigator.
- **Find:** Find in Workspace, Find and Replace in Workspace…, Find Next in
  Workspace, Find Previous in Workspace, Find Selected Text in Workspace,
  Find Selected Words in Workspace, Find Selected Symbol in Workspace, Find
  Call Hierarchy, Find Ancestor Types, Find Descendent Types, Find Conforming
  Types, Find in Selected Groups…, Find…, Find and Replace…, Find Next, Find
  Previous, Find and Select Next, Find and Select Previous, Replace, Replace
  All, Replace and Find Next, Replace and Find Previous, Use Selection for
  Find, Use Selection for Replace, Select Next Occurrence, Select Previous
  Occurrence, Select All Find Matches, Select Find Matches in Selection, Hide
  Find Bar.
- **Navigate:** Reveal in Project Navigator, Reveal in Changes Navigator,
  Reveal in Debug Navigator, Open in… (two variants), Move Focus to Next
  Area, Move Focus to Previous Area, Move Focus to Next Editor Pane, Move
  Focus to Previous Editor Pane, Move Focus to Editor Pane…, Show Previous
  Tab, Show Next Tab, Show Next/Previous Location in History (with option and
  shift+option variants), Jump to Next Active Conversation, Jump to
  Selection, Jump to Definition (with option and shift+option variants), Jump
  to Original Source/Generated Interface, Jump to Last Destination, Jump to
  Next Issue, Jump to Previous Issue, Jump to Next Bookmark, Jump to Next
  Bookmark In Workspace, Jump to Previous Bookmark, Jump to Previous Bookmark
  In Workspace, Jump to Program Counter.
- **Editor:** context-dependent; it is empty when no editor has focus.
- **Product:** Run, Run…, Test, Test…, Profile, Profile…, Analyze, Analyze…,
  Archive, Archive…, Stop, Build For (submenu), Perform Action (submenu),
  Build, Clean Build Folder…, Clean Build Folder Immediately, Delete Derived
  Data…, Clear Test Results, Clear All Issues, Build Documentation, Show
  Build Folder in Finder, Copy Build Folder Path, Scheme (submenu),
  Destination (submenu), Test Plan (submenu), App Shortcuts Preview.
- **Debug:** Pause, Continue To Current Line, Step Over, Step Over
  Instruction, Step Over Thread, Step Into, Step Into Instruction, Step Into
  Thread, Step Out, Step Over and Follow Program Counter, Step Into and
  Follow Program Counter, Step Out and Follow Program Counter, Deactivate
  Breakpoints, Breakpoints (submenu), Console (submenu), Debug Workflow
  (submenu), Attach to Process by PID or Name…, Attach to Process (submenu),
  Detach, Debug Executable…, Debug Crash Log…, Capture GPU Workload, Simulate
  Location, Induce Device Conditions, View Debugging, StoreKit, GameKit.
- **Integrate:** Source Control (submenu), Commit…, Push…, Pull…, Fetch
  Changes, Refresh File Status, Stage All Changes, Stage Selected Files,
  Unstage All Changes, Unstage Selected Files, Mark as Resolved, Add,
  Cherry-Pick…, Stash Changes…, Create Pull Request…, Discard All Changes…,
  Discard Changes in Selected Files…, Clone…, New Git Repository…, Xcode
  Cloud (submenu), Create Workflow…, Manage Workflows….
- **Window:** Minimize, Minimize All, Zoom, Zoom All, Fill, Center, Move &
  Resize, Full Screen Tile, Rename Window Tab…, Show Previous Window Tab, Show
  Next Window Tab, Move Tab to New Window, Merge All Windows, Developer
  Documentation, Welcome to Xcode, Downloads, Organizer, Touch Bar, Bring All
  to Front, Arrange in Front (two variants), Remove Window from Set, then one
  entry per open window.

## 2. Workspace window (sample package open, nothing selected)

- **Window:** 1,400 × 900 points as opened. The title shows the workspace
  name ("Demo").
- **Toolbar**, left to right, with frames in window points (x from the left
  edge):
  - Traffic lights at x 18–79.
  - A two-segment control: "Navigators" (x 94) and "Coding Assistant"
    (x 131), each about 38 points wide.
  - "Run" (x 205) and "Stop" (x 241), a joined pair.
  - "Go Back" (x 292) and "Go Forward" (x 328), a joined pair.
  - The workspace icon and name.
  - Near the horizontal center, a "New Conversation" button (x 698, 39
    points wide).
  - The "Active Scheme" pop-up (x 741, 83 wide) and the "Active Run
    Destination" pop-up (x 824, 91 wide), shown together in one pill with a
    › separator.
  - A three-segment control near the right edge: "Canvas" (x 1201),
    "Assistant" (x 1242) and "Code Review" (x 1282), each about 40 points
    wide.
  - "Show Inspector" (x 1333).
- **Navigator area:** about 290 points wide.
  - **Selector bar:** nine tab buttons at y 52, each about 28–34 points wide,
    in this order: Project, Source Control, Bookmarks, Find, Issues, Tests,
    Debug, Breakpoints, Reports. There is no Symbol navigator in 27.1;
    Bookmarks takes its place in the order.
  - **Bottom bar:** a "+" menu button at x 6, then a filter search field
    ("Project navigator filter") with a leading "Icon View Drop Down" menu,
    then two toggle checkboxes inside the field: "Recent files" and "Files
    with source-control status".
- **Editor area with nothing selected:** a jump bar showing a grid icon and
  "No Selection", and an empty editor.
- **Bottom of the window** (debug area collapsed): a "Breakpoints" toggle
  button at the left (x 292, just right of the navigator) and a "show debug
  area" button at the right edge (x 1335).
- **Project tree for a package:** the package (root), "Package" (the
  manifest), then "Sources" ▸ "Demo".


## 3. Source editor (main.swift of the sample package open)

- **Jump bar:** a grid button, then the path components with their icons:
  workspace › group › group › file, then the symbol component. (Correction
  2026-10-19, `reference-ui-5.md` §6.1: the jump bar has no back/forward
  buttons in 27.1; "back/forward" here was the toolbar's Go Back / Go
  Forward.)
  The symbol component reads "No Selection" when the insertion point is not
  inside a declaration.
- **Gutter:** line numbers, with the current line's number drawn brighter.
  The current line also has a subtle full-width background.
- **Minimap:** on by default (in this user's settings), about 110 points wide
  at the right edge of the editor. (Pass 5: the width scales with the
  editor, about 13–14 % of its width; `reference-ui-5.md` §6.5. Pass 6b:
  the factory default is on; `reference-ui-6.md` §4.5.)
- **Code-folding ribbon:** not visible at rest.
- **Position indicator:** "Line: N Col: N" appears at the right end of the
  bottom bar (the bar shared with the collapsed debug area).
- **Extensions:** the navigator showed "main" for main.swift. Settings ▸
  General ▸ File extensions was set to "Hide All" on this machine; whether
  that is the factory default was not established. (Pass 5: it is; the
  user's preferences hold no file-extension key. `reference-ui-5.md` §5.1.)

## 4. Settings window

- **Style:** a sidebar window in the style of System Settings, not a toolbar
  of pane icons. Each pane is a grouped form (sections of rows, with a
  setting's explanation in small text under some rows), with back/forward
  buttons and the pane's title at the top.
- **Sidebar panes, in order:** General, Appearance, Apple Accounts,
  Intelligence, Behaviors, Navigation, Notifications, Editing, Shortcuts,
  Source Control, Components, Locations. Apple Accounts and Intelligence were
  not opened, to avoid capturing the user's account details.
- **General**, sections and rows. Values are as observed on this machine and
  may be user choices.
  - Starting Points: "Restore open projects and workspaces" pop-up (Use System
    Setting), explained as following macOS's "Close windows when quitting an
    application" setting.
  - Navigation and Files:
    - Navigator size (Use System Setting).
    - Bookmark navigator detail, Find navigator detail and Issue navigator
      detail, each "Up to 3 Lines".
    - "Window tabs have independent sidebar widths" toggle (off).
    - "Automatically unlock files" toggle (off).
    - File extensions (Hide All).
  - Issues: Issue presentation (Show Inline); "Predictive Issues" toggle (on),
    which shows potential build issues as files are edited; "Stop build on
    first error" toggle (on).
  - Test Parallelization: "Testing on Mac" (Automatic) and "Testing on
    Simulator" (Automatic).
  - Report Navigator: Local report history (Up to 20 Reports).
  - Settings Import & Export: "Keep a copy in iCloud" toggle, with Export… and
    Import… buttons.
  - Reset Xcode: Reset Settings (Reset…) and "Don't ask me" warnings (Reset
    All).
- **Appearance:**
  - Appearance chooser: three thumbnails, System, Light and Dark.
  - A live code preview.
  - A three-segment control: Theme, Fonts and Editor.
    - Theme: a "Choose…" button, the theme Name ("Standard" here), a
      Foreground slider with a color well, then one color row per token kind
      (Plain Text, Comments, Documentation Comments, …).
    - Fonts: one font row per token kind, each with a pop-up; the Standard
      theme uses SF Mono weights for code and SF Pro for documentation
      comments.
    - Editor: Cursor Style (Vertical Bar).
  - Theme color values were deliberately not recorded (clean-room rule:
    Ycode's themes are its own).
- **Behaviors**: a list of categories, each showing how many behaviors are
  set and drilling into a sub-page: Build (3 behaviors), Testing (4),
  Running (3), Intelligence, Search, Localization Import / Export (2), File,
  Playgrounds (1), …. Each sub-page lists events as collapsible groups; each
  group lists its actions (for example "Navigator: Issues"), with +/− to add
  or remove actions.
  - Build: "When build starts" (none), "When build generates errors" →
    Navigator: Issues, "When build generates warnings" (none), "When build
    succeeds" → "Notify with bezel or system notification", "When build
    fails" → the same notification.
  - Running: "When running starts" (none), "When running pauses" →
    Navigator: Debug and Debugger: Show Current Views, "When running
    generates output" → Debugger: Show Current Views, "When running
    completes" → Debugger: **Hide Debugger If No Output**, "When running
    exits unexpectedly" (collapsed).
- **Navigation**:
  - New Editor Tabs Open With: Start Page. New Editor Panes Open With: Same
    Document. Pin Editor Tabs: Manually.
  - Click on Code: With Option → Shows Quick Help; With Command → Jumps to
    Definition; With Command & Control → Jumps to Definition.
  - Navigation: Destination → Focused Editor Pane; With Option → Uses New
    Unpinned Tab; With Option & Shift → Uses Next Editor Pane; With
    Double-click → Same as Click.
  - Toggles: "Use Window Tabs In Full Screen" (on) and "Animate Open Quickly
    With Multiple Editor Panes" (on).
- **Editing**:
  - Rows that open sub-pages: Display, Completion, Indentation.
  - Default text encoding: Unicode (UTF-8). Default line endings: macOS /
    Unix (LF). "Convert existing files on save" (off).
  - When Editing: "Automatically trim trailing whitespace" (on) and "Trim
    whitespace-only lines" (off).
  - Localized Strings: "Automatically generate string catalog comments" (on).
  - **Editing ▸ Display**:
    - Line numbers (on); Code folding ribbon (**off**); Code structure headers
      (on); MARK separators (on); Code coverage iteration counts (on);
      Condition on #endif lines (on); Scope guides (None).
    - Reformat code at column (80); Show reformatting guide (off);
      Automatically reformat when completing (off).
    - Dim inactive code (on); Highlight instances of selected symbol (on);
      Highlighting delay (0.25); Editor overscroll (Medium).
    - Line Wrapping: "Wrap lines to editor width" (on); "Indent wrapped
      lines" 4 spaces.
    - Documentation Comments: "Fade delimiters" and "Fade comment delimiters"
      (both appeared on).

## 5. Running, the activity view and the debug area (Run on the sample)

- **Activity view:** at the left of the toolbar, as a second line under the
  workspace name (for example "Configuring Debugger Actions", then "Finished
  running Demo"). The centered pill holds only the scheme and run
  destination.
- **Debug area:** opened automatically while the program produced output,
  and stayed open after the program ended (the Running behavior "Hide
  Debugger If No Output").
  - Height about 135 points in a 900-point window. It is split about 50/50
    between the variables view (left) and the console (right).
  - Variables view bottom bar: an "Auto" scope pop-up, two toggles (view
    options and info), and a filter field.
  - Console bottom bar: two icon toggles, a filter field, a trash (clear)
    button, and two buttons that show or hide the variables view and the
    console.
  - The console ends with "Program ended with exit code: 0".
  - The debug bar above the debug area shows the breakpoint-activation toggle
    at the left, "Line: N Col: N" and a show/hide debug-area toggle at the
    right.
- **Navigator and inspector:** both span the full window height; the debug
  area sits only below the editor area.

## 6. Inspector (File inspector for main.swift)

- About 265 points wide, toggled by the toolbar's right-most button.
- Three tabs for a source file: File, History, Quick Help.
- File inspector:
  - Identity and Type: Name (editable text field); Type pop-up ("Default -
    Swift Source"); Location pop-up ("Relative to Group") with the file name
    and a folder chooser button; Full Path (wrapped) with a reveal-in-Finder
    arrow button.
  - Text Settings: Text Encoding pop-up ("No Explicit Encoding"); Line
    Endings pop-up ("No Explicit Line Endings"); Indent Using pop-up
    (Spaces); Widths: Tab and Indent steppers (4 and 4) with labels under
    them.
- When the inspector opens, the toolbar's centered scheme and destination
  pill moves to stay centered in the remaining width.

## 7. Differences from Ycode at the time of observation (for implementers)

- **Navigators:** the third navigator is **Bookmarks**, not Symbol. The order
  is Project, Source Control, Bookmarks, Find, Issues, Tests, Debug,
  Breakpoints, Reports. Edit has Bookmark Line / Bookmark File commands, and
  Navigate has Jump to Next/Previous Bookmark.
- **Toolbar:**
  - The activity view is a second line under the workspace name at the left,
    not inside the centered pill.
  - The centered pill holds only scheme › destination.
  - Navigator and Coding Assistant form a two-segment control at the left.
  - Canvas, Assistant and Code Review form a three-segment control at the
    right.
- **Menus:** the source-control menu is named **Integrate**, and Find, View
  and Navigate carry the items listed in §1.
- **Settings:** a sidebar window with twelve panes, grouped-form rows and
  drill-down sub-pages (Behaviors categories, Editing ▸ Display / Completion
  / Indentation). It replaces a tabbed pane window. The defaults are those in
  §4.
- **Editor defaults:** the code-folding ribbon is off by default; wrap lines
  is on, with wrapped lines indented 4 spaces; trimming trailing whitespace
  is on; highlighting instances of the selected symbol is on (0.25 s delay).
- **Debug area:** it opens on run output or a pause, and on completion it
  hides only if there was no output. The default variables/console split is
  about 50/50.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Everything in §1–§6 | 3 | Black-box observation of the running reference app (Xcode 27.1, installed copy), its accessibility tree and menu bar, through screen observation tools, 2026-10-17. No binaries were opened. |
| §7 | — | Comparison of §1–§6 with Ycode's specs at the time. |
| §1 shortcuts and full item lists, §3 corrections | 3 | `reference-ui-5.md` §2, §5.1, §6 (pass 5, 2026-10-19). |
