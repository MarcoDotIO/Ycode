# Spec: reference IDE behavior, pass 4 — source control, debugging, Quick Help, refactoring, previews, Interface Builder

Status: boundary spec from black-box observation (evidence level 3) of the
reference release. Two samples were used: an iOS app project in a git
repository (two commits, one modified file and one untracked file), and a
Swift package with a breakpoint, a background dispatch queue and a
doc-commented function. It continues `reference-ui.md` to
`reference-ui-3.md`. It records visible behavior, labels and defaults only.
It records no colors, no assets, and no user identity. Ycode chooses its own
icons.

## 1. Source control status outside the navigator

1. The project navigator shows a status letter at the right end of each
   changed file: `M` for modified, `?` for untracked. The same letters appear
   for files in synchronized folders.
2. The debug bar's right end shows the current branch with a branch glyph,
   for example `feature/observe`.

## 2. Source Control navigator (⌘2)

1. **Top control:** a segmented control, **Changes | Repositories**.
2. **Changes.**
   - A header row "`<repository> <branch>`", with the branch in secondary
     text.
   - A group "Uncommitted Changes" with the item count at the right.
   - One row per changed item: icon, name without extension, and a boxed
     status letter. Untracked user data of the workspace
     (`project.xcworkspace`, `xcuserdata`) is listed too.
3. **Commit editor.** Selecting a change opens it in the editor area.
   - **Header:** the author's avatar, name and email from git's
     configuration; a switch "Amend "`<short hash>`""; a **Commit** button
     with a menu chevron. Commit is disabled until the message is non-empty.
   - **Message:** a multi-line field with the placeholder "Commit message
     (required)".
   - **Scope:** "All Changes | Unstaged | Staged", and a **Stage All**
     button at the right.
   - **Cards:** one collapsible card per changed file. A card's title is the
     icon and name; a workspace card reads "`<project>` / project.xcworkspace".
     At its right are a discard button and the status letter. The body is the
     diff: line numbers, context lines, added lines highlighted with a bar in
     the margin, and removed lines shown the same way. An untracked file
     shows all of its content as added.
   - **File inspector** for the selected change: the usual Identity and
     Type rows plus "Working Copy" and "Relative Path"; then "On Demand
     Resource Tags" ("Only resources are taggable"); "Target Membership" (a
     list of targets with their membership kind, "Default", and +/−/edit
     buttons); and Text Settings.
4. **Repositories.**
   - Root "`<repository> <branch>`". Groups in order: **Branches, Recents,
     Tags, Stashes, Remotes**.
   - A branch name containing `/` is shown inside a folder named after its
     prefix (`feature` ▸ `observe`).
5. **Branch history.** Selecting a branch shows its history in the editor.
   - Scope bar: "All | Last 24 Hours | Last 7 Days | Last 30 Days" and a
     Filter.
   - One row per commit: avatar, author, branch and tag badges, the subject,
     and at the right the short hash and the relative day ("Today",
     "Yesterday", or a date).
   - The inspector gains a fourth tab with section **Branch**: Name, Remote
     ("No Remote"), Remote Branch ("No Remote Branch").
6. **Commit detail.** Selecting a commit adds a lower pane.
   - The pane has a path bar "Commit › `<repository>` › `<file or No
     Selection>`", the author name and email, the date ("Oct 18, 2026 at
     11:46 PM"), a short-hash badge, and the full message.
   - The inspector gains a section **Commit**:
     - Identifier (full hash), Date, Author;
     - Verification ("Commit unverified" for unsigned commits);
     - Branches (every local branch that contains the commit);
     - "Commit Message";
     - "Files" (icon, name, and a status letter: A added, M modified, D
       deleted).

## 3. Integrate menu

1. **Section "Source Control":**
   - Commit… ⌥⌘C, Push…, Pull… ⌥⌘X, Fetch Changes, Refresh File Status
   - Stage All Changes, Stage Changes in Selected Files, Unstage All Changes,
     Unstage Changes in Selected Files, Mark Selected Files as Resolved
   - Add Selected Files, Cherry-Pick…, Stash Changes…
   - Discard All Changes…, Move Selected Files to Trash…
   - Clone…, New Git Repository…
2. **Section "Xcode Cloud":** Create Workflow…, Manage Workflows…. Ycode
   shows these disabled.
3. Items that don't apply to the current selection or state are disabled.
4. Pass 5 (`reference-ui-5.md` §2.11):
   - "Source Control" and the cloud section's title are disabled section
     labels, not submenus.
   - Several titles name the focused file ("Stage Changes in “<file>”",
     "Discard Changes in “<file>”…").
   - "Create Pull Request…" appears when it applies.
   - With no workspace the generic titles are "Stage Selected Files",
     "Unstage Selected Files", "Mark as Resolved", "Add" and "Discard
     Changes in Selected Files…".

## 4. Inline issues in the editor

1. Each line with an issue is tinted for its severity. At the right end of
   the line is the severity icon and the message, truncated with "…" when it
   doesn't fit. The offending symbol is underlined.
2. After the file is edited, the existing annotations turn grey (stale)
   until the next build replaces them.
3. A doc comment that the compiler warns about gets a warning icon at the
   right end of the comment line.

## 5. Running and debugging

1. **Activity view:** "Running `<product>`", then "Paused `<product>`" at a
   stop, then "Finished running `<product>`".
2. **On a breakpoint stop:**
   - The editor line is highlighted and annotated "Thread `<n>`: breakpoint
     `<id>` (`<hit count>`)".
   - The **Debug navigator (⌘7) is selected automatically**.
   - The console shows the debugger prompt "(lldb)".
3. **Debug navigator.**
   - **Process row:** "`<product>`  PID `<pid>`", with two buttons at its
     right (their functions were not observed).
   - **Gauges**, one row each with a value at the right: CPU ("0%"), Memory
     ("Zero KB"), Energy Impact ("Very High" … "Low", with a bar), Disk
     ("Zero KB/s"), Network ("Zero KB/s").
   - **Threads:** "Thread `<n>`  Queue: `<queue label>` (serial|concurrent)",
     with the queue label truncated in the middle. The main thread's queue is
     the main dispatch queue.
   - **Frames:** the stopped thread expands to "`<index>` `<function>`". User
     frames have a person icon. After them comes a dotted separator, then the
     first system frame greyed ("10 _pthread_wqthread"); the remaining system
     frames are hidden.
   - **Bottom bar:** a filter, then three buttons (a layers icon, a
     process-view-options gear, and a third control; tooltips not observed).
4. **Debug bar while paused**, from left to right:
   - toggle breakpoints, Continue, Step Over, Step Into, Step Out;
   - **Enable Backtrace in Editor**, **Debug View Hierarchy**, **Debug Memory
     Graph**, **Environment Overrides**, **Simulate Location**;
   - the path "`<process>` › Thread `<n>` › `<frame index> <function>`".
5. **Variables view (Auto):**
   - It shows a spinner while values load.
   - Rows read "`<badge> <name>: <Type> = <value>`". The badge is **A** for
     arguments (including `self`) and **L** for locals.
   - Aggregates have a disclosure triangle.
6. **Stopping** a paused session prints "Debug session ended with code 9:
   killed" (highlighted) and then "Program ended with exit code: 9".

## 6. Breakpoint navigator (⌘8)

1. **Tree:**
   - root "`<project>`  `<n>` Breakpoint(s)";
   - one group per file ("Shapes.swift");
   - one row per breakpoint: a kind badge (M was observed for a method; other kinds unobserved),
     "`<symbol>`  `<line>`", "ID `<n.m>`", and an enabled marker at the right.
     Clicking the marker toggles it (inferred, not observed).
2. **"+" menu:** Swift Error Breakpoint, Exception Breakpoint…, Symbolic
   Breakpoint…, Runtime Issue Breakpoint…, Constraint Error Breakpoint, Test
   Failure Breakpoint.
3. **Bottom bar:** "+", then a filter with two toggles.
4. Breakpoints are stored per user with the project or package (Ycode's
   storage format is in `debug.md`) and survive copying the folder.

## 7. Quick Help inspector

1. **Undocumented symbol:** title (the symbol name), a declaration box (for
   example "struct Circle"), a link to the defining file, and "Open in
   Developer Documentation".
2. **Documented symbol**, sections in this order, each present only when the
   comment provides it:
   1. the title, with the summary line under it;
   2. the declaration box, wrapped;
   3. the file link;
   4. **Parameters** (each name, then its description);
   5. **Return Value**;
   6. **Throws** (position inferred from Swift Markup, not observed);
   7. **Discussion** (the remaining paragraphs);
   8. callouts as boxed paragraphs titled with the callout name (**Note**
      was observed; others such as Important and Warning are inferred);
   9. "Open in Developer Documentation".

   Source: the symbol's doc comment in Swift Markup, as sourcekit-lsp
   returns it. `- Parameter`/`- Parameters:`, `- Returns:`, `- Throws:` and
   callout keywords (`- Note:`, …) are the standard Swift Markup forms (level
   1).

## 8. Editor menu and Refactor submenu

1. **Editor menu**, in order:
   1. Show Editor Only ⌘↩
   2. Canvas ⌥⌘↩ (check mark when shown), Assistant ⌃⌥⌘↩, Code Review ⌥⇧⌘↩,
      Layout ▸
   3. Show Completions ⌃Space, Show Predictive Completion ⌃⌥Space, Show
      Coding Tools ▸, Edit All in Scope ⌃⌘E, Show Callers…, Expand Macro,
      Hide All Macro Expansions, Refactor ▸
   4. Fix All Issues ⌃⌥⌘F, Show Issues ⌃⌥⌘L, Hide All Issues ⌃⌘L, Show
      Markdown
   5. Selection ▸, Structure ▸, Code Folding ▸, Syntax Coloring ▸, Font
      Size ▸, Choose Theme…
   6. Inline Comparison (checked by default), Side By Side Comparison
   7. Minimap ⌃⇧⌘M (checked), Authors ⌃⇧⌘A, Code Coverage
   8. Vim Mode, Relative Line Numbers
   9. Invisibles, Scope Guides, Wrap Lines ⌃⇧⌘L (checked)
   10. Show Last Change for Line, Create Code Snippet…
2. **Refactor ▸**, in order:
   1. Rename…
   2. Extract Selection to File, Extract to Function, Extract to Method,
      Extract to Variable, Extract All Occurrences
   3. Add Missing Abstract Class Overrides, Add Missing Protocol
      Requirements, Add Missing Switch Cases, Convert to Switch, Convert to
      Regex Builder, Expand Default, Generate Memberwise Initializer,
      Generate Missing Function Definitions, Wrap in NSLocalizedString
   4. Convert Function to Async, Change Localized String Key, Convert
      Localized String to Symbol, Convert to Localized String Literal

   Items that don't apply at the cursor are disabled. Ycode maps them to
   the refactoring actions sourcekit-lsp offers (code actions) where one
   exists; the others stay disabled.

## 9. Empty editor

With no document open, the editor area shows an **Open Quickly** search
field, a heading **Recent Files**, and a list of recently opened files. Each
row is the file icon, the name without extension, and a breadcrumb of its
folder path. Clicking a row opens the file. Typing in the field behaves like
Open Quickly.

## 10. SwiftUI preview canvas

1. **Placement.** With the canvas on (Editor ▸ Canvas), it sits beside the
   editor, or below it when the editor is narrow.
2. **Paused state.** Until the first build, the canvas shows a capsule
   "Canvas paused" with a resume button.
3. **Header.** After resume, a tab per preview: the preview's name
   (`#Preview("name")`, else the view type), with a spinner while building
   and then an eye icon.
4. **Content.** The rendered preview inside a device frame.
5. **Bottom bar:**
   - left: four mode buttons, the first being **Live** (selected by
     default), then selectable mode, then two more;
   - centre: the zoom pop-up ("30%");
   - right: three buttons (zoom to fit, device settings, canvas settings).

## 11. Interface Builder (storyboard)

1. **Layout.**
   - A **document outline** column left of the canvas, with a Filter at its
     bottom and a toggle in the canvas bar.
   - Each scene on the canvas has a title bar (the controller's title, for
     example "View Controller") above a device-shaped frame.
   - The initial scene has an entry-point arrow pointing at it.
2. **Outline tree:**
   - "`<Controller>` Scene" › "`<Controller>`" › "View" › Safe Area;
   - then the subviews, named by their content or class with a kind badge
     ("Hello" for a label, "Tap" for a button);
   - then "Constraints" (collapsible);
   - then, at the scene level, First Responder, Exit, and Storyboard Entry
     Point.
3. **Selection.** Selecting an element in the outline selects it on the
   canvas (resize handles, plus guide lines for its constraints). The jump
   bar shows the full path down to the element.
4. **Inspector tabs** for a storyboard: File, History, Quick Help,
   Identity, Attributes, Size, Connections.
5. **Canvas bottom bar**, from left to right:
   - outline toggle, "+", issues indicator, appearance toggle, orientation,
     layout;
   - the device pop-up ("iPhone 16");
   - zoom "− 79% +";
   - update frames, align, add constraints (pin), resolve auto-layout
     issues, embed in.

## 12. Differences to implement in Ycode

1. Status letters in the project navigator, and the branch in the debug bar
   (§1).
2. The Source Control navigator (§2):
   - Changes and Repositories, with their groups;
   - the commit editor (header, amend, message, scope, Stage All, file
     cards with diffs and discard);
   - branch history and commit detail;
   - the Branch and Commit inspector sections.

   Use git through its command line (porcelain output) or libgit2 (public
   documentation).
3. The Integrate menu items and their enablement (§3).
4. Inline issue annotations, stale greying after edits, and the underline
   (§4).
5. The debugger (§5):
   - activity titles;
   - auto-select the debug navigator on a stop;
   - process gauges, thread rows with queue labels, frame grouping with
     system frames collapsed;
   - the full debug bar;
   - the A/L variable badges and the loading state;
   - the end-of-session console lines.
6. The breakpoint navigator tree, ID column, enabled marker, "+" menu kinds
   and bottom bar (§6).
7. The Quick Help sections and their order (§7).
8. The Editor menu and Refactor submenu, with their enablement (§8).
9. The empty editor with Open Quickly and Recent Files (§9).
10. The preview canvas states, the tab header and the bottom bar (§10).
11. Interface Builder: the outline tree, scene title bars, the entry arrow,
    the seven inspector tabs and the canvas bottom bar (§11). The
    inspectors' contents were not observed, so keep Ycode's current
    content.

## 13. Interface Builder inspectors (pass 4b)

1. **View controller ▸ Attributes**, sections in order:
   - Simulated Metrics: Size, Top Bar, Bottom Bar, Keyboard (each
     "Inferred").
   - View Controller: Title; Is Initial View Controller; Activity Name.
   - Layout: Adjust Scroll View Insets (on), Hide Bottom Bar on Push,
     Resize View From NIB (on), Use Full Screen (Deprecated).
   - Extend Edges: Under Top Bars (on), Under Bottom Bars (on), Under Opaque
     Bars.
   - Transition Style (Cover Vertical); Presentation (Automatic); Defines
     Context; Provides Context.
   - Content Size: "Use Preferred Explicit Size", with Width and Height.
   - Key Commands: a table with +/−, then Key and Selector fields.
2. **Identity** (any object):
   - Custom Class: Class (placeholder = the base class), Module ("None"),
     Inherit Module From Target.
   - Identity: Storyboard ID, Restoration ID, Use Storyboard ID.
   - User Defined Runtime Attributes: Key Path | Type | Value, +/−.
   - Document: Label (placeholder "Xcode Specific Label"), colour tags,
     Object ID (the XML `id`), Lock ("Inherited - (Nothing)"), Localizer
     Hint.
3. **Size:**
   - A view controller shows only Simulated Size (Fixed).
   - A view shows:
     - Show (Frame Rectangle), with X, Y, Width and Height steppers;
       Arrange; Layout ("Inferred (Constraints)"); Layout Margins;
       Preserve Superview Margins, Follow Readable Width, Safe Area
       Relative Margins;
     - a Constraints diagram with the scope "All | This Size Class";
     - constraints listed under "Horizontal" and "Vertical" as "`<kind>`
       to: `<item>`" with an Edit button, then "Showing N of N";
     - Content Hugging Priority (H/V, default 250) and Content Compression
       Resistance Priority (H/V, default 750);
     - Intrinsic Size ("Default (System Defined)") and Ambiguity ("Always
       Verify").
4. **Connections:**
   - Triggered Segues; Outlets (a connected outlet shows its target as a
     capsule with ×); Presenting Segues (Relationship, Show, Show Detail,
     Present Modally, Present As Popover, Embed, Push (deprecated), Modal
     (deprecated), Custom); Referencing Outlets ("New Referencing Outlet");
     Referencing Outlet Collections.
   - Every row ends in a connection circle.
5. **Label ▸ Attributes:**
   - A "Label" section: Text (Plain or Attributed) and the text; Color;
     Font; Dynamic Type; Alignment (5 segments); Lines; Behavior (Enabled,
     Highlighted); Tooltip; Baseline; Line Break; Strategy; Autoshrink;
     Tighten Letter Spacing; Sizing Rule; Highlighted; Shadow; Shadow
     Offset.
   - Then a "View" section: Content Mode, Semantic, Tag, Interaction, Alpha,
     Background, Tint, Drawing flags, Stretching.
   - A "+" before a row adds a per-trait variation. The property names
     follow the public UIKit API.
6. Selecting a controller shows the scene's objects as icons in the scene
   title bar. A canvas overview (minimap) appears at the canvas's top right.

## 14. Toolbar right group and editor options (pass 4b)

1. From left to right:
   - an account/cloud button;
   - **Add Editor Tabs or Editor Panes**;
   - **Adjust Editor Options**;
   - a three-way toggle: **Show Canvas**, **Show Assistant**, **Code
     Review**.
2. **Adjust Editor Options** menu: Layout ▸ | Inline Comparison (checked),
   Side By Side Comparison | Minimap, Authors, Code Coverage | Invisibles,
   Scope Guides, Wrap Lines (checked) | Choose Workspace Theme…. The choices
   apply to the focused editor.
3. The Window menu has **no** Devices and Simulators item. Devices are
   managed from the destination menu's "Manage Devices…".

## 15. Code Review (comparison) mode (pass 4b)

1. **Inline.** Changed lines are tinted, with a bar in the gutter. The debug
   bar shows "‹ N change(s) ›" (previous/next), then the left source
   ("Uncommitted Changes"), a swap button, and the right source ("Last
   Commit").
2. **Source picker.** Either source opens a two-column popover:
   - "Branches & Tags": a search field, Recents, and branches, with the
     current one marked "(current)";
   - "Commits": a search field, Uncommitted Changes, Unstaged/Staged
     Changes, and the commit list (author, date, short hash, subject).
3. **Side By Side.** The working copy on the left (editable) and the
   comparison source on the right (read-only). Change regions are joined by
   ribbons, and an insertion marker shows where added lines would go on the
   other side.

## 16. Assistant editor (pass 4b)

1. A second pane with its own jump bar: a close button, then the mode
   pop-up. It shows "No Editor" when the mode has nothing to show.
2. Modes, in order:
   - Counterparts
   - Superclasses, Subclasses, Siblings, Extensions, Categories, Protocols
   - User Interfaces
   - Includes, Included By
   - Callers, Callees
   - Test Classes, Test Callers
   - Preprocess, Assembly
   - Disassembly
   - Generated Interface ▸
   - Documentation Preview

## 17. Preview canvas details (pass 4b)

1. **Placement.** In a wide window the canvas sits to the right of the
   editor. While the preview builds, the activity view reads "Preparing
   `<device family>` Simulator".
2. **Bottom bar:**
   - left: Live (selected), Selectable, a third mode button and a variants
     button;
   - centre: the zoom pop-up;
   - right: capture, device, canvas settings.
3. **Device menu:** "Automatic – `<device>`" (checked) | Recent | generic
   classes (iPhone "Dynamic Island", iPhone "Touch ID", iPad 11-inch, iPad
   13-inch, each with grey secondary text) | Devices (connected devices) |
   More ▸.
4. **Canvas settings:** a popover of switches: Display, Color Scheme,
   Contrast, Control Borders, Orientation, Dynamic Type (all off by
   default).

## 18. Differences added by pass 4b

1. IB inspectors as in §13. Read and write the matching storyboard XML
   attributes, which are file-format facts (level 2): the `id`, `userLabel`,
   `customClass`/`customModule`, `storyboardIdentifier`,
   `userDefinedRuntimeAttributes`, `connections`, and constraint elements.
2. The toolbar right group and the Adjust Editor Options menu (§14).
3. Code Review mode, the source picker and side-by-side ribbons (§15).
4. Assistant modes (§16). Implement Counterparts, Callers/Callees (via
   call hierarchy), Generated Interface and Documentation Preview; the
   others stay disabled when there's no data.
5. Preview canvas placement, device menu and canvas settings (§17).

## Evidence

| Claim | Level | Source |
|---|---|---|
| §1–§6, §8–§11 | 3 | Black-box observation of the reference app (Xcode 27.1, installed copy) on throwaway samples, 2026-10-18/19, through screenshots, menus and tooltips. No binaries were opened. |
| §7 structure | 3 | The same observation, with a doc comment written for the test. |
| §7 markup keywords | 1 | Swift Markup (public Apple documentation) and sourcekit-lsp. |
| §8 mapping to code actions, §2 git access | — | Ycode's own design choice, not observed. |
| §12, §18 | — | Comparison with Ycode's specs at the time. |
| §3.4 | 3 | Pass 5 menu-bar listing (`reference-ui-5.md` §2.11). |
| §13–§17 | 3 | Second session (pass 4b), 2026-10-19, with Xcode in full screen. Storyboard XML names in §18 come from the file format (level 2). |
