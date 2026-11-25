# B5-FIX-NAV: a drag move and ⌘Z (1.0.0-beta.5 fix round)

Item 8 of the fix round: P-042, `specs/ide/navigators.md` "A drag move and
⌘Z" (council round 12 C11; the owner's decision of 2026-11-21: match the
reference). Both IDEs.

## What changed

- **After a drop that moves rows**, the topmost moved file (in the
  navigator's order) opens in the editor and the editor takes keyboard
  focus. The moved rows stay selected; with the editor focused they draw in
  the unfocused grey. A drop that moves only groups or folders opens
  nothing and leaves the editor as it was.
- **⌘Z / Edit ▸ Undo after the move change nothing**: the drag move is not
  registered with the undo history.
- **The project's earlier navigator undo and redo entries are dropped with
  the move.** They could no longer apply (an undo is refused once the
  project changed since, with an alert on macOS), so ⌘Z right after the move
  would otherwise show "The project changed since; it cannot be undone".
  Other projects' entries in a workspace, the editor's text undo and the
  Find navigator's replace undo stay.
- **Unchanged:** Edit ▸ Paste ▸ Move Item Here (⌥⌘V) and every other file
  operation (new group, rename, delete, sort, convert, Add Files…) keep
  their undo, as the spec says.

## Where

- macOS: `YcodeUI/Window/WorkspaceWindowController+NavigatorDragMove.swift`
  (new: the per-project undo target, `finishNavigatorDragMove`, the editor
  focus); `WorkspaceWindowController+ProjectNavigatorOps.swift`
  (`performNavigatorEdit(_:registersUndo:_:)`; navigator undo is registered
  with a per-project `NavigatorUndoTarget` instead of the window controller,
  so one project's entries can be removed with
  `removeAllActions(withTarget:)`; `moveNavigatorRows` is the drop).
- Linux: `YcodeIDEShell/WorkspaceShellModel+NavigatorDragMove.swift` (new);
  `WorkspaceShellModel+FileOperations.swift` (the same `registersUndo`
  parameter; `moveNavigatorRows` is the drop). The editor focus is the
  model's `focusEditor()` (`editorFocusCount`). The walk
  `YCODE_IDE_NAVIGATOR5` now shoots `drop` and `drop-undo`.

## Open spec facts taken at their best-evidence value

- **Edit ▸ Undo's title after a move** (spec: not captured). The move adds
  no entry, so the item reads whatever came before it on the window's
  history (plain "Undo", disabled, when nothing did).
- **Which file opens when several rows move** (spec: "the (first) moved
  file"). The topmost moved file in the navigator's order.
- **Earlier entries of the same project** (spec: not observed). Dropped, as
  above, since they can no longer apply.
- **Move Item Here and the other operations** (spec: OPEN) keep their undo.

## Tests

- macOS: `NavigatorDragMoveUITests` (offscreen): the drop opens README.md
  with the editor's text view first responder and the row selected, the
  undo manager has nothing to undo and ⌘Z leaves the files and the project
  as moved; an earlier New Group's entry goes with no refusal while Move
  Item Here keeps "Undo Move"; screenshots.
  `ProjectNavigatorOperationsTests.dragMovesRowsIntoGroupsAndFolders` no
  longer undoes the drag.
- Linux: `NavigatorDragMoveShellTests` (the same three cases; a dragged
  group opens no file). `NavigatorFileOperationsShellTests.moveSortAndEditorsFollowARename`
  moves the file back by hand instead of undoing.

## Screenshots

- macOS: `.build-ide/b5-shots/fixnav-1-before.png`, `fixnav-2-after-drop.png`,
  `fixnav-3-after-undo.png` (the window; the editor shows README.md with the
  caret line after the drop and after ⌘Z), and `fixnav-nav-1-before.png`,
  `fixnav-nav-2-after-drop.png`, `fixnav-nav-3-after-undo.png` (the
  navigator alone: README under Nav, selected). Offscreen captures do not
  draw the glass, the selector bar or the unfocused row band's grey (it
  comes out black); on a display the band is the unfocused grey.
- Linux: `~/Ycode-B5FIX-NAV/shots/nav5-drop.png`, `nav5-drop-undo.png`.
