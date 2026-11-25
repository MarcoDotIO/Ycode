# B5-NAVIGATOR: the Linux IDE's half

The Linux navigators for 1.0.0-beta.5 (P-037, P-039, P-040, P-041, P-042,
P-043, P-051, P-052, P-199). The shared contracts are in
`ycode/Sources/YcodeIDECore/Navigator/` (`NavigatorFilterModel`,
`ProjectRowMenu`, `NavigatorEmptyStyle`, `NavigatorBars.specs`,
`ProjectFileOperations`); the macOS half is in `docs/beta5/b5-navigator.md`.

## Where it is

- Model (headless, tested): `YcodeIDEShell/ShellNavigatorState.swift` (the
  navigators' state beside the workspace model),
  `WorkspaceShellModel+FileOperations.swift` (the file operations, undo and
  redo, the context menus' and the menu bar's commands),
  `WorkspaceShellModel+NavigatorFilter.swift` (the filter, the multiple
  selection, ⌥←/⌥→, the Package Dependencies section),
  `OutlineRows.swift` (filtered rows, type-select), `NavigatorItems.swift`
  (rows carry their pbxproj object).
- Views: `ycode-ide/NavigatorArea.swift` (the outline, its rows, the empty
  state), `NavigatorBottomBar.swift` (the bottom bar),
  `ProjectNavigatorViews.swift` (context menus, rename in place, Delete's
  question, Add Files…, drag to move), `NavigatorKeyboard.swift` (keys for
  the outlines that draw their own rows).
- Tests: `YcodeIDEShellTests/NavigatorFileOperationsShellTests.swift`.
  Walk: `YCODE_IDE_NAVIGATOR5=<prefix>` (`ShellDriver+Navigator5.swift`).

## Per item

- **P-052** Every operation goes through `ProjectFileOperations` and the
  pbxproj writer (`session.model.saveProjects()`); the tests read the
  written file back (same object graph) and undo to the original bytes.
  Delete asks Move to Trash / Remove References (only when every item has
  a reference) / Cancel; the trash is the freedesktop trash. Open editors
  follow a moved or renamed file. The Package Dependencies section follows
  the project (L-110). Add Files… uses OpenViews' file dialog with the last
  options and the selection's targets (no options accessory on Linux).
  New File from Template… is disabled until the shell has a New File sheet
  (`navigatorState.newFileFromTemplate`).
- **P-041** Context menus from `ProjectRowMenu.entries(for:)`; the clicked
  row is acted on alone unless it is in the selection; the selection does
  not change. Open Terminal, Open in New Window, External Editor, Add
  Package Dependencies…, Migrate to String Catalog…, Bookmark, Add, Mark as
  Resolved are disabled on Linux.
- **P-051** Return renames, Delete/Backspace asks to delete, type-select,
  ⇧-click and Ctrl-click, ⌥←/⌥→ over a row and its descendants, Ctrl+Z and
  Ctrl+Shift+Z undo and redo the file operations; the Test, Report, Debug,
  Breakpoint and Symbol outlines take the keyboard; the selection scrolls
  into view; the navigator outlines no longer hide their scrollers.
- **P-037** Every navigator's filter works: rows follow
  `NavigatorFilterModel.settleDelay` after the last key; the match is bold,
  the rest dimmed; "No Filter Results" and the inspector's "No Selection";
  the options glyph turns accent; its menu lists the recent filters and
  Clear Recents; the Project toggles (recent files, source-control status)
  filter; the field's value is exposed to accessibility.
- **P-039** `NavigatorEmptyStyle`; Source Control says "No Git
  Repositories".
- **P-040** Source Control (Commit…, Refresh File Status, Fetch Changes),
  Tests (its add items) and Reports have the "…" button; the Project "+"
  is `ProjectRowMenu.addMenu`; Find's scope reads "In Workspace".
- **P-043** The name is edited on the row's band, no border, as wide as
  the name; Return commits, Escape cancels; a new group is open.
- **P-042** A drag over the rows highlights a group or folder, or draws the
  insertion line with its ring; the dragged rows keep a grey band and a
  translucent image follows the pointer; the drop calls
  `ProjectFileOperations.move` (not into itself, not while filtering).
- **P-199** Measured with the walk; see the report for the values.
