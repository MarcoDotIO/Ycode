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

## Ycode implementation: conflict editor and Compare Files (SCM-BRANCHES, 2026-10-31)

Ycode's design; the reference's conflict view and its file-merge tool
were not observed (open question below).

### Three-way merge (`YcodeIDECore/SourceControl/ThreeWayMerge.swift`)

The textbook diff3 procedure: line-diff the base against each side with
`LineDiff`, take base lines both diffs keep (in order) as sync points, and
classify each stretch between them: **unchanged**, **ours only**, **theirs
only**, **both the same**, or **conflict**. Changes on touching lines
conflict, as in git's merge. A two-way comparison is the merge of the
right side against the left (every difference "theirs only").

`MergeDocument` holds the chunks, one choice per hunk (every chunk that
is not unchanged) and the result:

| Choice | Result lines | Default for |
|---|---|---|
| Left (ours) | ours | ours only, both the same |
| Right (theirs) | theirs | theirs only |
| Left + Right / Right + Left | both, in that order | — |
| Base | the ancestor's | — |
| Edit | hand-written | — |
| Unresolved | `<<<<<<< <ours label>`, ours, `=======`, theirs, `>>>>>>> <theirs label>` | conflict |

`ConflictMarkers` parses git's markers (with the optional `|||||||` base
section) back into chunks; a marker is seven characters alone or followed
by a space.

### Conflict editor (`YcodeUI/SourceControl/ConflictEditorController.swift`)

Since B3-MERGE (2026-11-05) a repository's conflicts are resolved in the
merge sheet (`merge-sheet.md`, §12 for Ycode's implementation); this
controller remains Compare Files' view.

Its state and every text it shows are the core's `ConflictEditorState`,
which the Linux IDE's conflict editor draws too (`source-control.md`,
"Ycode implementation: the Linux IDE").

Shown over the editor area like the commit editor. Top row: "Conflicts in
<file>", a pop-up of the conflicted files, the unresolved count ("1
conflict unresolved", "Resolved", "All conflicts resolved"), **Mark as
Resolved** (enabled with nothing unresolved), **Continue <operation>**
(enabled once no file is conflicted) and **Abort <operation>**. The hunk
bar: ‹ "Change 2 of 5 (conflict)" ›, the choice control **Left | Right |
Left + Right | Right + Left | Base | Edit**, and the pair control **Left ↔
Right | Base ↔ Left | Base ↔ Right**, which picks the two versions the
comparison view shows (the old side on the left, titles "Left: main",
"Right: feature", "Base: …"). Edit opens a small text editor with the
hunk's text (ours then theirs for a conflict). Below: the **Result**,
read-only, with each hunk tinted (red unresolved, green resolved, darker
for the selected one). Choosing for a hunk moves to the next unresolved
one. Mark as Resolved writes the result and stages it, then shows the
next conflicted file.

### Compare Files

Ycode's file-merge tool: **Ycode ▸ Open Developer Tool ▸ Compare Files…**
asks for a left file, a right file, then an optional common ancestor, and
opens a "Compare Files" window with the same controller. Two files: the
hunks read "Difference n of m", the pair control is hidden and Base is
disabled; the result starts as the right file. Three files: a three-way
merge against the ancestor. **Save Merge…** writes the result (refused
while a conflict is unresolved).

**`ycode compare <left> <right> [--ancestor <base> [--merge <out>]]`** does
the same without a window: two files print a unified diff (`---`/`+++`
headers, `@@ -a,b +c,d @@` hunks, three context lines; exit 1 when they
differ), three print or write the merged text with conflict markers
labelled by the file names (exit 1 with conflicts, and "N conflicts" on
standard error); 2 for bad arguments.

### Evidence

- diff3 merging and git's conflict markers: git's public documentation
  (`git-merge` "How conflicts are presented", `git-merge-file`; level 1).
- The unified diff format: POSIX `diff -u` (level 1).
- That Xcode resolves conflicts in a comparison view and ships a file-merge
  tool comparing two files or three with an ancestor: Apple's public Xcode
  Help and the `opendiff` manual page (level 1).
- OPEN QUESTION: the reference conflict view's layout and per-conflict
  controls; the file-merge tool's window, its choice menu and folder
  comparison (not done in Ycode).
