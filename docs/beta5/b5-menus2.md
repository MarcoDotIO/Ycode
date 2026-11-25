# Beta 5: B5-MENUS2 (the menu bar, second pass)

Workstream B5-MENUS2 of 1.0.0-beta.5 (`docs/ROADMAP-1.0.md`): beta 4's menu
leftovers as council round 11 measured them on macOS, on both IDEs, and the
menu test hygiene of beta 4's candidates. Clean room: written from
`specs/ide/parity-inventory.md` (P-001, P-006, P-007–P-016), the reference
specs it cites, Ycode's own code and public documentation.

## Per item

| P-id | Change | macOS | Linux |
|---|---|---|---|
| P-001 | Save All (⌥⌘S) is Save's ⌥ alternate: holding ⌥ turns Save into Save All instead of listing both | `CommandTable` (shared) | the toolkit lists no alternates yet (L-048): Save alone; ⌥⌘S still saves all through `ShellAlternateShortcuts` (every performable alternate's key) |
| P-001 | Save As… (⌥ under Duplicate…), Export…, Open in New Window, Save As Workspace… performed and enabled | `WorkspaceWindowController+FileCommands.swift`; what is written is `FileMenuCommands` (YcodeIDECore) | `ShellFileCommands` + the save dialog `ShellSaveDialogs` (installed on the workspace window); Open in New Window stays disabled (one workspace window, L-225) |
| P-001 | Project Settings… / Workspace / Package Settings… | not done: no sheet and no spec of its contents (`settings.md`, open question) | same |
| P-013 | Product's Run, Test, Profile, Analyze, Archive, Stop and Debug's steps carry their glyph from the moment the menu bar is built | system symbols asked for at run time (`MainMenu.applyGlyph`), no artwork shipped | OpenViews' own artwork of the same symbol names (`ShellMenus`); the other rows of those menus keep the glyph column so titles line up |
| P-016 | In a workspace the item reads "Stage Changes in Selected Files" (the generic "Stage Selected Files" with no workspace) | `MenuTitles` (shared) | same |
| P-006 | With only Welcome open, Editor ▸ Preview is unchecked | `DynamicMenus` | `ShellMenuModel.checked` |
| P-006 | With only Welcome open (council round 11, B02): View ▸ Inspectors holds Show Inspector alone, disabled; Editor ▸ Layout lists Automatic, —, Editor on Left, Editor on Top, all disabled (`EditorMenu.welcomeItems`). In a workspace with no file open: View ▸ Inspectors lists File ⌥⌘1, History ⌥⌘2, Quick Help ⌥⌘3, —, Hide Inspector | `DynamicMenus` (Welcome's Editor menu, the inspector rows) | `ShellMenuModel.items` / `submenuItems`; History is listed disabled (the Linux IDE has no History inspector yet) |

Save As… writes the focused document (its unsaved edits included) to the
chosen place and edits the new file there; the original keeps what was last
saved. Export… writes the same copy and the editor keeps the original. With
no file focused both act on the workspace's own document (a `.xcodeproj` or
`.xcworkspace` bundle; a package folder has none, so they are disabled
there), as the reference enables them with nothing open (P-008). Save As
Workspace… writes a `.xcworkspace` whose `contents.xcworkspacedata` refers to
the project or package relative to the workspace's folder, then opens it.

The glyph names are ones both toolkits have: Profile's is
`gauge.with.dots.needle.33percent` (was `gauge.with.needle`, which OpenViews
does not draw).

## Menu test hygiene

- `MenuBarBehaviorTests.openIsEnabledUnbundled` depended on test order: the
  first `NSDocumentController` made becomes the shared one, and another
  suite's plain AppKit controller disables Open…. The application delegate
  now performs File ▸ Open… (it is asked before the document controller), so
  Open… is enabled whichever controller is shared; the test checks the
  delegate, and `ParityMenuCompareTests` drops its workaround.
- `IsolatedPreferences.restore()` (both test targets) posts
  `Preferences.didChange` for the restored preferences.
- The `duplicateEditorTab:` case in `+Availability.swift` was dead (the
  parity validation answers first): removed.
- The spelling panel: not reproduced. A full `YcodeUITests` run with the
  offscreen guard's trace (`YCODE_OFFSCREEN_TRACE=1`, which names every
  window ordered in and the test that did it) ordered in no spelling panel,
  nor did the menu suites run alone with `YCODE_PARITY_MENU_DIR`; no test or
  source sends `showGuessPanel:`. Left open.
- The macOS menu drawings of `ParityMenuTableTests` tint each glyph on its
  own canvas (they were drawn as filled squares).

## Not done (with the reason)

- P-006: Code Review with no file open needs
  Code Review to start without a document (beta 7, P-135). Customize
  Toolbar… needs toolbar customisation (B5-TOOLBAR's toolbar files).
- The enabled-state differences: the reference rows P-004 and P-007–P-016
  were checked against the macOS table (`ParityMenuTableTests`). Still
  different, each because the feature is not in Ycode yet: at Welcome Open
  Quickly…, Test Plan ▸ New Test Plan…, Debug Executable…, Show Quick
  Actions…, App Shortcuts Preview; in a workspace Duplicate…, Print… with no
  document, Project Settings…, Build with Timing Summary, Build and Export
  Test Products, Generate Optimization Profile…, Test Plan ▸ Edit / Manage,
  Convert Scheme to use Test Plans…, Move Focus to Editor Pane…, Jump to Last
  Destination; with a file open Vim Mode and Create Code Snippet….
- Linux: about 150 items macOS performs are still disabled on Linux with a
  file open (`menu-diff-Sample.swift.txt`; the list in `docs/beta4/b4-menus.md`
  is unchanged), because the Linux IDE has nothing behind them yet.

## Tests

- macOS: `MenusB5Tests` (Save All alternate, the File commands and what they
  write, the workspace data, the glyphs, Stage title and Welcome Preview,
  Duplicate Editor Tab), `MenuBarBehaviorTests.openIsEnabledUnbundled`,
  `isolatedPreferencesRestorePostsDidChange`; `MenuBarGoldenTests` (Save All
  marked alt), `MenuBarBehaviorTests.titlesInContext` (YcodeIDECoreTests).
- Linux: `ShellMenusB5Tests` (the same items through `ShellMenuModel` and
  `ShellFileCommands`).
- Walk: `YCODE_IDE_MENUS4=<prefix>` (beta 4's menu walk) at Welcome and with
  a file open.

## Follow-ups

- **The Linux menu bar's cost.** Each item rebuilt the workspace's menu
  context (with `SourceControlShellModel.menuState`, which reads the change
  list and the disk) for its title and enabled state. `ShellMenuModel.Pass`
  now builds the context and Integrate's state once per menu body and the
  items share it; shell commands are found by a table instead of a scan of
  every case. Measured on the x86 in a release build with
  `YCODE_IDE_MENUS5` (24 file selections, the first frame's work after each):
  median 444 / 429 ms before, 411 / 413 ms after (two runs each, a small
  git package); the menu model itself, every title and enabled state, 4.6 ms
  with a context per item against 0.6 ms with one pass (3.6 against 0.9 ms
  on the parity repository). The rest of the frame is OpenViews' whole-window
  rebuild (B5-OPENVIEWS).
- **Editor ▸ Invisibles, Scope Guides, Code Coverage on Linux** (the Linux
  editor draws them since B5-EDITOR2): enabled with an editor open, checked
  from `showInvisibles`, `scopeGuides` (none / lines) and `showCodeCoverage`,
  which choosing them switches, as the macOS items.
