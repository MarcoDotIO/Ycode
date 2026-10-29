# Source editor

Ycode module: `YcodeUI` (`SourceEditorController`, `GutterView`,
`SourceTokenizer`, `Theme`).

## Layout

Jump bar on top; below it the gutter, the text (TextKit 2, monospaced
12 pt, wraps lines), and an optional minimap at the right edge.

## Jump bar

Left: the Related Items button. Then the path of the open file in the
navigator tree: container › groups › file, each with its icon. There are
no Back / Forward buttons in the jump bar; history is in the toolbar
(correction 2026-10-19, `reference-ui-5.md` §6.1, which also adds the
issue buttons at the right end and the ⌃1–⌃6 keyboard menus).

## Gutter

- Line numbers (toggle: Editor ▸ Line Numbers).
- Breakpoints: click an empty line → add (enabled). Click a breakpoint →
  toggle enabled/disabled. Drag a breakpoint out of the gutter → delete.
  Drag it along the gutter → move to that line. ⌘\ adds or removes at the
  insertion point. ⌘Y deactivates all (drawn pale, not sent to the
  debugger).
- Issue marks: a dot (red error, yellow warning) on lines with issues.
- Change gutter: source-control change bars left of the line numbers, in
  normal editing (`reference-ui-5.md` §6.3).
- Current-instruction marker while the debugger is stopped.
- A code-folding ribbon on the gutter's right edge with a triangle on each
  fold start (down = open, right = folded); clicking the ribbon on a line
  toggles the region starting there, else the innermost one containing it.
- Test diamonds are drawn in place of the line number
  (`reference-ui-6.md` §4.3.1). Issues have no gutter glyph (§4.3.2).

## Annotations

Lines with issues get a tinted background and the first message in a
rounded label at the line's right end. The stopped line is tinted green.

## Commands

⌘/ comments or uncomments the selected lines with `// ` (all commented →
uncomment). ⌘L (Navigate ▸ Jump to Line in “<file>”…) jumps to a line.
⌃⇧⌘M toggles the minimap. ⌘S saves. The rest of the editing commands
(Move Line Up / Down, Font Size, column selection, …) are in
`reference-ui-5.md` §6.4.

## Code folding

Regions are `{ … }` pairs (comments, strings and preprocessor lines
ignored) spanning at least three lines. Folding hides the lines strictly
between the opening and closing brace lines; the opening line shows a
"⋯" token after its last character. Fold (⌥⌘←) folds the innermost open
region around the insertion point; Unfold (⌥⌘→) opens the folds that
contain it; Unfold All (no shortcut) opens every fold. Correction
(2026-10-19): the reference has no "Fold All"; ⌥⇧⌘← / ⌥⇧⌘→ are Fold /
Unfold Methods & Functions, and ⌃⇧⌘← / ⌃⇧⌘→ Fold / Unfold Comment
Blocks (`reference-ui-5.md` §2.7, §6.4). Folding never changes
the text; edits keep folds whose start line still begins a region. Hidden
lines are skipped by layout (the TextKit 2 content manager does not
enumerate those paragraphs), so line numbers jump over them.

## Find bar

Find… (⌘F) shows a bar between the jump bar and the text: option pop-ups
(Text | Regular Expression, Containing | Matching Word, Ignoring | Matching
Case — the Find navigator's options), the query field, "N of M" (or "No
matches"), previous/next and Done. Find and Replace… (⌥⌘F) adds a
replacement field with Replace and All. Find Next (⌘G) / Find Previous
(⇧⌘G) move through matches, wrapping, and select the match; Use Selection
for Find (⌘E) makes the selection the query. The first current match is
the first one at or after the insertion point. All matches are tinted
(pale yellow), the current one stronger. In regular-expression mode the
replacement is a template (`$1` …); in text mode it is literal. Done
hides the bar and the tints.

## Syntax coloring

Our own lexer (not a parser) for Swift, Objective-C and C/C++:
comments (`//`, `/* */`, nested in Swift), doc comments (`///`, `/**`),
strings (incl. Swift `"""` and ObjC `@"…"`, C char literals), numbers,
keywords per language, preprocessor lines (C/ObjC `#…` at line start, with
continuations; Swift `#if` etc.), Swift `@attributes`, and capitalized
identifiers as type names. Colors come from system colors (keyword pink
semibold, string red, comment secondary label, doc comment green, number
blue, preprocessor orange, type purple) so light and dark appearance work.

## Placeholders

Text of the form `<#text#>` (on one line, not empty) is a placeholder.
The file keeps the delimiters; the editor draws the token: the `<#` and
`#>` are invisible and take no visible width, and the text sits on a
rounded tint (stronger when the token is selected).

- Tab selects the next placeholder after the selection, wrapping to the
  first; Shift-Tab the previous one. With no placeholder in the file, Tab
  inserts a tab.
- Return with exactly a placeholder selected replaces it with its text.
- Typing with a placeholder selected replaces the whole token.
- A click inside a token selects the whole token.
- Inserting a Library snippet or accepting a completion selects the first
  placeholder of the inserted text. Completion items in LSP snippet form
  (`insertTextFormat` 2; Ycode announces `snippetSupport`) are converted:
  `${n:text}` → `<#text#>`, `$n` / `${n}` → `<#value#>`, `$0` dropped,
  `\$` → `$`.

## Editing performance

- Each edit re-colors only the lines it touches: the edited range is
  widened to whole lines and lexed alone. The whole file is re-colored
  instead when the edit (inserted or removed text, or the edited lines)
  contains a block-comment or multi-line-string marker (`/*`, `*/`,
  `"""`, `#"`), when a token spanning lines (kept from the last full pass,
  shifted by each edit) touches the edited lines, or when several edits
  arrive before one change notification.
- The line index (line starts) is updated for each edit instead of being
  rebuilt: starts inside the edited range are replaced by those of the
  new text, later ones shift (tested equal to a rebuild).
- Files over 3,000 lines update folding regions and the minimap 0.25 s
  after typing pauses; the minimap's line data is computed only while it
  is shown.
- Measured (`EditorPerformanceTests`, 10,000-line Swift file, 30
  keystrokes, this Mac): 1,034 ms per keystroke re-coloring the whole
  file and re-scanning folds, 24 ms with incremental coloring, 21.8 ms
  with the incremental line index as well (most of the rest is text
  layout). Incremental coloring
  produces the same colors as a full pass (tested).

## Evidence

- Gutter breakpoint gestures, ⌘\, ⌘Y, ⌘/, ⌘L, minimap and folding
  shortcuts: Apple's public Xcode Help and keyboard-shortcut reference
  (level 1).
- Language lexical rules: The Swift Programming Language (lexical
  structure), C and Objective-C public documentation (level 1).
- OPEN QUESTION: Xcode's default theme colors and font size (ours are our
  own choices).
- OPEN QUESTION: annotation placement and wording.
- Defaults (reference-ui.md §4, level 3): wrapping on with wrapped lines
  indented 4 spaces; folding ribbon off; trim trailing whitespace on;
  instances of the identifier at the caret highlighted after 0.25 s
  (skipped while the find bar is shown).
- Jump bar (reference-ui.md §3, level 3): after the file, a symbol
  component naming the innermost declaration at or before the caret's
  line (Ycode's approximation by declaration start lines), "No Selection"
  when there is none.
- Find bar commands and shortcuts: Apple's public Xcode Help and shortcut
  reference (level 1). OPEN QUESTION: the bar's exact layout and the
  match-highlight colors.
- Folding commands and shortcuts, the ribbon: Xcode Help and shortcut
  reference (level 1). The folding commands and their shortcuts:
  `reference-ui-5.md` §2.7 (level 3). OPEN QUESTION: whether Xcode's fold
  hides the closing brace line too, and its folded-token look.
- Placeholders: the `<#…#>` token form and Tab navigation from Apple's
  public documentation on code snippets (level 1); LSP snippet syntax from
  the Language Server Protocol specification (level 1). OPEN QUESTION: the
  reference token colors and shape, and whether Return on an unselected
  token does anything.
