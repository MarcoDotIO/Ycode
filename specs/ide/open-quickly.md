# Open Quickly

Ycode modules: `YcodeIDECore` (`FuzzyMatch`, `OpenQuicklyLayout`), `YcodeUI`
(`OpenQuicklyController`), the Linux IDE (`ShellOpenQuicklyModel`,
`OpenQuicklyPanel`).

File ▸ Open Quickly… (⇧⌘O) shows a panel: a large search field, then a
list of matches (icon, name, and below it the folder for files or
`file:line` for symbols). Typing updates the list; Up/Down move the
selection; Return (or double-click) opens the selected item — a file at
its top, a symbol at its declaration line — and closes the panel; Escape
closes it.

## Layout

The panel, field, separator and rows follow `fidelity-council.md` round 9,
row 215 (`OpenQuicklyLayout`): 640 wide, its top 200 below the window's; a
borderless 22-point field after a 21-point magnifier; a separator 54 down;
620 × 56 rows, the selected one #0064E1 / #0059D1 with white text; a file's
row shows its name (extension dimmed) and under it the project's mark and
its group path. An empty query shows no results.

## Candidates

Every file of the workspace tree, and every declaration the symbol
scanner finds in them (types, members, functions; `specs/ide/navigators.md`
§Symbol navigator). Candidates are rebuilt each time the panel opens.

## Matching

A candidate matches when all query characters (spaces ignored) occur in
its name in order, ignoring case. Score per matched character: 1, +8 at
the first character, +6 after `/ . _ -` or space, +5 at a lower→upper case
change, +3·n for the n-th character of a contiguous run. Total = sum × 10
− name length. Results: the 20 best, ties with files first.

## Evidence

- Open Quickly's purpose, shortcut and behavior (files and symbols, Return
  opens): Apple's public Xcode Help and shortcut reference (level 1).
- The scoring rule is Ycode's own.
- The layout: the round 9 council capture of one file result (level 3).
- OPEN QUESTION: Xcode's ranking, whether it matches paths (e.g. `dir/file`)
  and `file:line` queries, and its rows for several results and for symbols.
