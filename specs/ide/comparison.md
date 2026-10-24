# Comparison (code review) editor

Ycode module: `YcodeUI` (`LineDiff`, `ComparisonView`,
`GitRepository.headContents`/`diff`, commit-sheet diff pane).

## Code review editor

View ▸ Editor ▸ Code Review (⌥⇧⌘↩; ⌃⌥⌘↩ is the Assistant's, see
editor-area.md) toggles the focused file's editor between the
normal text and a side-by-side comparison: the HEAD version on the left
("name (HEAD)", from `git show HEAD:<path>`; empty for a new file) and the
editor's current text on the right ("name (Local)", unsaved edits
included). Rows are aligned; each side shows its own line numbers. Colors:
removed lines red on the left with a blank filler row on the right, added
lines green on the right with a filler on the left, changed lines red left
and green right. The two sides scroll together. Opening another file
returns to the normal editor. Both sides are read-only.

## Diff

A line diff by longest common subsequence after trimming the common prefix
and suffix; at each step removals are emitted before additions. Side by
side, a run of removals followed by additions pairs up line by line as
"changed" rows; leftovers are removed or added rows.

## Commit sheet diff pane

The commit sheet shows, beside the file list, the selected file's changes
against HEAD as a unified diff (` `, `-`, `+` prefixed lines, three lines
of context, "…" between separated hunks), `-` lines tinted red and `+`
lines green. The first file is selected when the sheet opens.

## Evidence

- Code review / comparison mode, its shortcut, and the commit sheet's
  diff: Apple's public Xcode Help ("Compare changes", "Commit changes")
  and shortcut reference (level 1).
- `git show HEAD:<path>`: git documentation (level 1); verified on a test
  repository (level 3).
- OPEN QUESTION: Xcode's diff algorithm and change-bar decorations,
  whether it compares against HEAD or the index by default, and its
  inline (non side-by-side) presentation.
