# Beta 4 — B4-MENUS: the menu bar

Workstream B4-MENUS of 1.0.0-beta.4 (`docs/ROADMAP-1.0.md`), from the rows of
`specs/ide/parity-inventory.md`. Clean room: written from the spec, Ycode's
own code and public documentation only.

## How the two IDEs are kept one to one

- **One table.** Both menu bars come from `CommandTable` / `EditorMenu`
  (YcodeIDECore). Titles in context are `MenuTitles`, conditional items
  `MenuConditions`, Integrate's enablement `IntegrateMenuState`; all three
  are shared.
- **The Linux menu model.** `ShellMenuModel` (YcodeIDEShell, new) decides
  what the Linux menu bar lists and does: which items show (conditions are
  now evaluated as on macOS, not "shown when the shell performs them"), the
  title, shortcut, enablement and check mark, and the action. `ShellMenus`
  (ycode-ide) only draws it. Items without a `ShellCommand` are performed
  by `ShellAppModel+MenuActions.swift` (new) or, for Settings panes, by the
  view layer.
- **The test.** `ParityMenuCompareTests` (in `ParityMenuTableTests.swift`)
  builds the AppKit menu bar and the Linux `ShellMenuModel` rows for the
  same repository in three states (Welcome, a workspace with nothing open,
  a Swift file in the editor) and compares them item by item by menu path,
  action and tag. Titles must match everywhere; enablement and check marks
  for every item this pass touched. With `YCODE_PARITY_MENU_DIR` it writes
  the full difference lists (`menu-diff-<state>.txt`).

## Per item

| P-id | Change |
|---|---|
| P-001 | Alternates in the table: Save As… (of Duplicate…), Open Library, Clean Build Folder Immediately, Step Over/Into Instruction and Thread (⌃), Show Previous/Next Files History, Group (from Selection) without Folder (⌥), the bookmark dialogs, Move Focus to Previous Area / Editor Pane, Quit and Keep Windows. Open in Next Editor Pane is its own row (⌥⌘<). Shifted shortcuts spelled ⇧ + base key: ⌃⇧0, ⌥⇧⌘`, ⌃⇧`, ⌃⇧⌘', ⇧⌘\. |
| P-002 | Quit and Keep Windows performs (`terminateKeepingWindows:`, one quit with the system's keep-windows preference) and AppKit's own copy is removed: listed once, enabled. |
| P-004 | With only Welcome: Organizer, Device Hub / Manage Devices…, Clone…, Choose Theme… work (application delegate); Induce Device Conditions is disabled; Create Pull Request… is listed. |
| P-006 | No editor: the Editor menu is the first block with "Preview" (checked at Welcome); View ▸ Inspectors has Show Inspector only; Linux evaluates Jump to Line's condition. |
| P-007 | "Show All Issues" keeps its title; Format Selection / File name clang-format for JSON and C-family files; JSON's comment item reads Toggle Comments. |
| P-008 | Close Window ⇧⌘W and Close Other Window Tabs ⌥⇧⌘W always listed; Save All, Open Terminal at Location, Print… performed; Save / Page Setup… need a document; Linux: ⌘W / ⇧⌘W close, Save enabled before an edit, Open Recent filled. |
| P-009 | Add Line Bookmark ⌃⌘', Add File Bookmark ⌃⇧⌘' (dialogs ⌥ alternates); Move Item Here always listed; Copy Symbol Name items with code focused; rich-text Format items disabled and unchecked in code. |
| P-011 | Change Editor Orientation performed (both); Show All Window Tabs needs window tabs; View ▸ Editor's Related Items, Group Files, Document Items enabled. |
| P-012 | Open using Tab, Open in Next Editor Pane, Move Focus to Next/Previous Area and Editor Pane, Jump to Definition using Tab / in Next Editor Pane performed; the change jumps enabled in a source file; Jump to Next Issue, history, Reveal and Clear All Issues need something to act on. |
| P-013 | Test needs a test target (both); Convert Scheme to use Test Plans… listed; glyphs on Run, Test, Profile, Analyze, Archive, Stop and the step items (macOS). |
| P-015 | Similar Items titles "Type '-'"…; GameKit separator; Breakpoint at Current Line / Column need an editor; Test Failure Breakpoint, Delete All Breakpoints, Reload Console enabled; Simulate Location lists Don’t Simulate Location, the places and Add GPS Exchange to Project… (both); Attach to Process fills off the main thread. |
| P-016 | Stage / Unstage Selected Files, Mark as Resolved, Add keep their titles; Commit…, Push…, Pull…, Fetch, Cherry-Pick…, Stash…, Discard All… enabled in any repository, New Git Repository… always. |
| Decision 5 | Integrate's Cloud section removed. |

## Left for later (Linux gaps the comparison lists)

`ParityMenuCompareTests` writes every remaining difference. With a Swift
file open, about 150 items macOS performs are listed disabled on Linux
because the Linux IDE has no implementation behind them yet (not a menu
question): the Editor menu's folding, selection, structure (Re-Indent,
formatters, Reformat), Syntax Coloring, Font Size, comparison, Authors,
Code Coverage, Invisibles, Scope Guides and completion items; File's New
▸ Tab / Empty File / File from Template… / Folder, Add Files…, Add Package
Dependencies…, Duplicate Editor Tab, Open in New Tab, Show in Finder,
Resolve Package Versions, Print…, Page Setup…; Edit's bookmark, Copy File
and Line, Copy Symbol Name and Duplicate; View's jump-bar menus (⌃1–⌃6),
editor and window tab bars, Pin Editor Tab, Quick Actions, Library, Filter
in Navigator, Full Screen and toolbar; Find's selection and replace
variants; Navigate's Open using Tab / in Next Editor Pane and Move Focus to
Next Area; Product's Profile, Analyze, Build For ▸, Without Building,
Scheme ▸ and Destination ▸ commands, Build Documentation and build-folder
items; Debug's Attach by PID, Debug Executable, Test Failure / Column
breakpoints, Reload Console. Platform items (Hide Others, Bring All to
Front, Minimize, Zoom, the font, colour and spelling panels) have no Linux
counterpart. The Linux toolkit shows no alternates (L-048) and prints ⌘
and ⌃ alike (L-006, L-075): B4-TOOLKIT.
