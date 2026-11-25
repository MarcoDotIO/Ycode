# B5-FIX-UNDO: text undo belongs to the file (1.0.0-beta.5 fix round)

Item 9 of the fix round, added 2026-11-23. Spec: `specs/ide/source-editor.md`,
"Text undo belongs to the file". Both IDEs.

## The problem

- **macOS.** The editor reuses one text view for every file it shows, and
  that view used the window's undo manager. `open(_:)` replaced the text
  without separating its history, so ⌘Z after a file switch could apply the
  old file's edits to the new file's text.
- **Linux.** Already one buffer, with its own history, per open file. Its
  gaps: a reload after a change on disk was an undoable edit (the spec says
  it clears the history), and a navigator move dropped the moved file's
  buffer, so its history went with it.

## What changed

### macOS

- **One undo manager per file.** `TextUndoHistories` (new) holds the window's
  histories, keyed by the file's standardized path. The editor area shares
  one instance among all its editors; a single-file window has its own. The
  text view asks its delegate for its undo manager
  (`SourceEditorController.undoManager(for:)`) and gets the manager of the
  file it shows. An editor with no file, or with read-only text, gets an
  empty manager.
- **Switching** (navigator, jump bar, Open Quickly, tabs, Go Back / Go
  Forward, a drag move that opens the moved file) keeps each file's history.
  The editor saves the file it leaves, as before. When the file comes back,
  the history stays only if the text is still the one it was left with.
- **Undo is disabled** in a file that has no edits of its own. The Edit menu's
  title names the file's own last action (the file's manager, for example
  "Undo Typing").
- **Reload clears the history.** This covers the disk follower's reload of
  an unedited file, a file that changed on disk while no editor showed it,
  and a re-open of the shown file with new text.
- **Closing clears the history.** File ▸ Close "file" ends it when no other
  editor shows the file. A history whose entries all came from editors that
  closed (a closed tab or pane) is dropped. Reopening starts empty.
- **Saving keeps the history.**
- **Two editors on one file share its history and its text.** Ycode's panes
  used to hold separate copies of a file, so pane 2 did not show pane 1's
  typing.
  - A change in one pane is now copied to the others (`mirror`), with no
    undo entry of its own.
  - A new pane on an open file shows that file's current text, unsaved edits
    included, instead of the disk's.
  - ⌘Z in either pane undoes the file's last edit in both.
- **A navigator move or rename keeps the moved file's history**
  (`TextUndoHistories.move`).
- **Undo and Redo now update the editor.** NSTextView sends no change
  notification for an undo or a redo (checked black-box). Before this
  change, the editor stayed "unedited" after ⌘Z, its line index and colours
  were stale, and the disk follower put the saved text back about a second
  later. The editor now notes the storage's change, and after the file's
  undo or redo it runs its normal change path. This also gives Undo's result
  to the language server.
- **The window's history is the navigator's and Find's.**
  - The navigator's undo is unchanged.
  - The Find navigator's Replace All is still one step of the window's
    history. That step now restores every changed file through the
    conflict-checked `ReplaceHistory.restore`: an open editor's text through
    the editor, other files on disk.
  - An open editor's change is also an entry in that file's own history.
  - The find bar's Replace All is an entry of the file.

### Linux

- `EditorBuffer.clearUndoHistory()` (new).
- A reload after a change on disk clears the history. This covers the
  unedited follower (`checkOpenFilesOnDisk`) and the banner's Reload.
- File ▸ Revert to Saved and the recovery banner's Discard keep their
  undoable reload. The spec names only reloads after a change on disk.
- `EditorDocument.moved(to:)` (new). A navigator move or rename now moves the
  open document with its buffer, so the history survives a drag move that
  opens the moved file. Before, the document was dropped and read again.
- Unchanged, because it already matched the spec:
  - Per-file buffers survive a switch.
  - Close Document drops the buffer when no other pane shows the file.
  - Panes on one file share one buffer.
  - Ctrl+Z acts on the shown buffer.

## Open spec facts taken at their best-evidence value

- **A closed file that stays in the back/forward history** (spec: OPEN). Its
  history is kept while the file stays in the window and the text is
  unchanged: it is in an editor's back/forward list, or, on Linux, in the
  window's open documents. File ▸ Close "file" with no other editor on the
  file ends it. So does closing the last tab or pane whose editor made its
  entries.
- **Revert to Saved (Linux)**: not named by the spec. It keeps its undoable
  reload.

## Known gaps

- **macOS, a split where both panes edited one file.** An NSTextView entry
  applies to the text of the text view that made it. When a pane that made
  entries for a file moves to another file while another pane still shows
  the first file, that file's history is cleared (its text stays). Otherwise
  ⌘Z could later act on the other file. A pane that only showed the file
  leaves the history alone. Closing this gap needs one text storage per file
  shared by its text views (TextKit 2, several layout managers on one
  content storage). Linux has no such gap: its panes share one buffer.
- **Linux Edit ▸ Undo's title.** It does not name the action ("Undo" rather
  than "Undo Typing"). The buffer keeps no action names, and the menu is in a
  hot file (`ShellMenus.swift`). This is a candidate.

## Tests

- macOS: `TextUndoPerFileUITests` (offscreen). It uses the temporary files of
  `ProjectNavigatorOperationsTests.Sample` and covers:
  - Edit A, switch to B, ⌘Z: B is unchanged and A is unchanged on disk.
  - Back in A, ⌘Z undoes A's edit.
  - Save keeps the history; Go Back keeps it.
  - A reload after a change on disk, a change on disk while away, and
    Close clear the history.
  - Two and three panes on one file share the text and the history.
  - The navigator's New Group undo stays on the window.
  - A drag move that opens the moved file keeps its history.
  - The find bar's and the Find navigator's Replace All, with their undo.
  - Screenshots.
- `FindNavigatorWindowTests`: the editor's undo manager is now the file's,
  not the window's.
- Linux: `TextUndoPerFileShellTests` (`YcodeIDEShell`) covers the same cases
  on the shell model. `ShellEditingTests.aCleanFileFollowsTheDiskAnEditedOneAsks`
  now expects the banner's Reload to clear the history.
- Linux walk: `YCODE_IDE_TEXTUNDO=<prefix>` (`ShellDriver+TextUndo.swift`).
  `YCODE_IDE_TEXTUNDO_FILES=A.swift:B.swift` names the two files. It shoots
  `a-edited`, `b-ctrl-z` and `a-ctrl-z`, with real Ctrl+Z key presses.

## Counts

- Mac:
  - The focused run passed 137 tests in 23 suites (the editor, Find,
    navigator, refactoring, assistant and menu suites, plus this item's).
  - The full `YcodeUITests` run had 950 tests. Three failed under load
    (`DeviceHubYcrunTests`, `B5NewProjectUITests.welcomeOpenClosesWelcomeFirst`
    and `PairIDEHubTests.pairWatch…`); all three passed when rerun alone.
- x86: the full suite passed 1991 tests. The Linux walk passed with
  `unchanged=true`, `aOnDiskUnchanged=true` and `undone=true`.

## Screenshots

- macOS: `.build-ide/b5-shots/fixundo-1-model-edited.png`,
  `fixundo-2-helpers-after-cmd-z.png`, `fixundo-3-model-after-cmd-z.png`.
- Linux: `~/Ycode-B5FIX-UNDO/shots/textundo-a-edited.png`,
  `textundo-b-ctrl-z.png`, `textundo-a-ctrl-z.png`.

## Evidence

- Level 1: public AppKit documentation (NSTextViewDelegate
  `undoManager(for:)`, NSUndoManager notifications), and the spec.
- Level 3, black-box tests of public AppKit in Ycode's own test process:
  - An NSTextView undo sends no `textDidChange`.
  - The text storage's `didProcessEditing` does fire.
