# Source editor

Ycode module: `YcodeUI` (`SourceEditorController`, `GutterView`,
`Theme`), `YcodeSyntax` (tokens, structure, typing rules; portable) and
`YcodeIDECore` (`SourceTokenizer`, the settings). See "Ycode
implementation" at the end.

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

⌘/ comments or uncomments the selected lines with the language's comment
(`// `, `# `, or `<!-- … -->` around the lines; all commented →
uncomment; "Ycode implementation", Typing). ⌘L (Navigate ▸ Jump to Line in “<file>”…) jumps to a line.
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

Superseded (2026-10-30) by "Ycode implementation" ▸ Highlighting: Swift
through swift-syntax's parser, eleven languages through Ycode's own line
lexers. Colors come from the theme's role colors, else system colors
(keyword pink semibold, string red, comment secondary label, doc comment
green, number blue, preprocessor orange, attribute brown, type purple)
so light and dark appearance work.

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

- Each edit re-colors only the lines whose tokens changed
  (`SyntaxDocument`, "Ycode implementation" ▸ Highlighting). Block
  comment and multi-line string markers no longer force a full pass.
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

## Code coverage (IDE-QUICKWINS, 2026-10-30)

Editor ▸ Code Coverage (a user setting, default off) shows a coverage
ribbon in the gutter for the open file, from the newest test report with
coverage (the scheme's test action gathers it, `testing.md`). Each
executable line gets a strip just left of the change bars: red where the
line never ran, faint grey where it ran. Line counts: projects from
ycodebuild's coverage summary (`lines`, one count per line, -1 for lines
that are not executable; `YcodeXcodebuild` `Coverage.summaryJSON`);
packages from llvm-cov's export segments through LLVM's line-coverage
rules (`Coverage.lineCounts`). The look is Ycode's (the reference's
ribbon, with its execution counts, was not observed). Tests:
`IDEQuickWinsTests.coverageLines`, `IDEQuickWinsUITests.codeCoverageRibbon`.

## Ycode implementation

Ycode's own design (2026-10-30, EDITOR-TYPING). The text rules below are
in the portable `YcodeSyntax` module, which builds and tests on macOS and
Linux; the macOS editor (`SourceEditorController+Typing.swift`) applies
them, and the Linux editor (EditorKit, `docs/PARITY.md` §5.3) will too.

### Languages

| Language | File extensions (examples) | Lexer |
|---|---|---|
| Swift | `swift`, `swiftinterface` | swift-syntax's parser and classification, after a lexical pass |
| C | `c` | C family |
| C++ | `cpp`, `cc`, `cxx`, `hpp`, `hh`, `modulemap` | C family |
| Objective-C | `m`, `mm`, `h`, `pch` | C family (its keywords include C++'s) |
| Metal | `metal` | C family with Metal's keywords and vector, matrix and texture types |
| JSON | `json`, `jsonc`, `xcstrings`, `Package.resolved` | JSON (comments allowed) |
| XML | `xml`, `plist`, `entitlements`, `xib`, `storyboard`, `xcscheme`, `xcworkspacedata`, `svg`, `html` | XML |
| Markdown | `md`, `markdown` | CommonMark with task lists |
| YAML | `yml`, `yaml` | YAML 1.2 subset |
| Shell Script | `sh`, `bash`, `zsh`, `command` | POSIX shell, bash and zsh |
| Build Configuration File | `xcconfig` | build settings files |

Editor ▸ Syntax Coloring lists them alphabetically by these names after
None. Other files are plain text (no tokens; Return keeps the line's
indentation).

### Highlighting

- **Tokens.** Each token has a kind: code kinds (keyword, comment, doc
  comment, string, character, number, preprocessor, attribute, type name,
  regex, escape, variable, placeholder) and data and markup kinds (key,
  tag name, attribute name, entity, heading, emphasis, strong, code span,
  link, URL, list marker, quote). Offsets are UTF-16 code units.
- **Theme mapping.** Each kind is drawn with one of the theme's color
  roles (`EditorTheme.tokens` keys, `SyntaxTokenKind.role`), so themes
  need no new entries:

  | Role | Kinds |
  |---|---|
  | keyword (bold by default) | keyword, heading, tag name, list marker |
  | comment | comment, quote |
  | docComment | doc comment |
  | string | string, character, regex, code span, URL |
  | number | number, entity, escape |
  | preprocessor | preprocessor |
  | attribute | attribute, attribute name, key, strong (bold), emphasis (italic) |
  | typeName | type name, variable, link |
  | (text color) | identifier, placeholder (placeholders keep their token look) |

- **Line lexers.** Every language has a lexer that colors one line at a
  time and carries a state across line ends: an open block comment (with
  its nesting depth in Swift), a multi-line or raw string (with its `#`
  count or C++ delimiter), a preprocessor continuation, an XML tag,
  comment, CDATA section or attribute value, a Markdown fence, a YAML
  block scalar (with its indentation) or quoted scalar, a shell quote or
  here-document word. Highlights per language:
  - Swift: `//`, `///`, nested `/* */`, `/** */`; `"…"`, `"""…"""`,
    `#"…"#` with `\( … )` interpolations; numbers (`0x`, `_`, exponents);
    keywords; `@attributes`; `#if` / `#elseif` / `#else` / `#endif` /
    `#sourceLocation` / `#warning` / `#error` as preprocessor, other `#`
    words as keywords; `<#…#>` placeholders; capitalized identifiers as
    type names.
  - C family: `//`, `/* */`, doc forms `///`, `//!`, `/** */`, `/*! */`;
    strings with `L`, `u`, `U`, `u8` prefixes, ObjC `@"…"`, C++ raw
    strings `R"d(…)d"` over lines; character literals; numbers with `'`
    separators; preprocessor lines from `#` with `\` continuations up to
    a comment; `[[attributes]]`; ObjC `@keywords`; `__attribute__`;
    keywords per dialect; type names (capitalized, `…_t`, Metal's
    `float4`, `half3x3`, `texture2d`, …).
  - JSON: keys (a string followed by `:`), strings, numbers, `true`,
    `false`, `null`, comments.
  - XML: `<?…?>`, `<!DOCTYPE …>`, `<!-- -->`, `<![CDATA[…]]>`, tag names,
    attribute names and values, entity references.
  - Markdown: ATX and setext headings, `*em*` / `_em_`, `**strong**`,
    code spans with matching backtick runs, fences (``` and `~~~`), links
    and images, autolinks and bare `http(s)://` URLs, block quotes, list
    markers and task boxes, thematic breaks, backslash escapes, HTML
    comments and tags.
  - YAML: `#` comments (at a word start), `---` / `...`, `%` directives,
    keys, quoted scalars, block scalars (`|`, `>`), numbers, booleans and
    null, anchors and aliases, tags, list markers.
  - Shell: `#!` on the first line, `#` comments, quotes (over lines),
    `$NAME`, `${…}`, `$(`, `$1`…, here-documents (`<<WORD`, `<<-WORD`,
    quoted words), keywords and built-ins, `NAME=` assignments, numbers.
  - Build configuration files: `//` comments, `#include` / `#include?`,
    setting names, `[condition=value]`, `$(VAR)` / `${VAR}` / `$VAR`,
    strings, `YES` / `NO`.
- **Swift's parser pass.** swift-syntax's `SwiftParser` parses the file
  and `SwiftIDEUtils` classifies its tokens (keywords including
  contextual ones, types in type position, attributes and modifiers,
  `#if` clauses, regex literals, …); capitalized identifiers are type
  names as in the lexical pass. The parse is incremental: the edits since
  the last pass go to the parser, which reuses unchanged nodes.
- **Incremental re-highlighting.** Tokens are stored per line, relative
  to the line start, with the lexer state at each line end. An edit
  re-lexes the edited lines, then the following ones only while a line
  starts in a different state than before (typing in a line re-lexes that
  line; opening `/*` re-lexes to the comment's new end). The editor then
  recolors exactly those lines. Swift's parser pass re-classifies the
  edited text, from the start of a multi-line string or comment it is in
  (a closing `"""` decides how earlier lines split into indentation and
  text), and the following lines until two in a row come out unchanged.
  It runs after each edit while it takes under 8 ms, else 0.3 s after
  typing pauses; files over 2,000 lines show the lexical colors first and
  are parsed right after opening. Incremental results equal a full pass
  (tested with random edits in every language).

### Structure

- **Block events.** Per line, outside comments, strings, placeholders and
  (C family) preprocessor lines and `[[attributes]]`: brackets `(` `[`
  `{` and their closers; XML start and end tags (not self-closing ones);
  shell `then`, `do`, `case` (open), `fi`, `done`, `esac` (close), `else`
  (close and open), `elif` (close), and braces. Markdown and YAML have
  none.
- **Enclosing block.** The innermost block opened before an offset and
  not closed before it, found by scanning back (at most 5,000 lines);
  events are cached per line.
- **Matching bracket** and **blocks** (opener and closer on different
  lines, with their depth): the scope guides use blocks that span three
  or more lines.

### Indentation

A line's indentation is one step (the indent width) past the
indentation of the line holding its enclosing block, written with tabs
and spaces per the settings (tab width for tab stops). Then:

1. A line that starts by closing that block (a closer, `</`, `fi`,
   `done`, `esac`, `else`, `elif`) sits at the opener line's indentation.
2. Swift and C family: a `case`, `default` or `@unknown default` label
   inside a `switch` body sits at the `switch` line's indentation (the
   statements under it one step in).
3. C family preprocessor lines start at column 0; Swift `#if` lines
   follow the code.
4. Swift lines starting with `.member` are one more step in (member
   chains).
5. Top level: column 0.
6. Lines that start inside a multi-line comment, string, XML tag or
   comment are left alone; Re-Indent empties whitespace-only lines.
7. Markdown, YAML and plain text have no structural indentation: Re-Indent
   leaves them, Return keeps the line's indentation (with the cases
   below).

### Typing

All of these follow Settings ▸ Editing ▸ Indentation (below) and apply
to an editable file with one selection and no input-method composition.

- **Return.** The newline gets the indentation the structure gives the
  new line; spaces after the insertion point are dropped; a line left
  with only whitespace is emptied. Between a bracket pair or an XML
  element (`{|}`, `(|)`, `<a>|</a>`) the closer moves to its own line at
  the opener's indentation and the insertion point sits one step in
  between them. When the text after the insertion point closes the block
  (`b|}`), the closer moves down at the opener's indentation. Inside a
  comment or string the line's indentation is kept, and a `///` line
  continues with `/// `. Swift: after an opening `"""`, the closing
  `"""` is added on the line below. Markdown: `- `, `* `, `+ `, `1. ` /
  `1) ` (counting up), `- [ ] ` and `> ` continue on the new line; Return
  on an empty item removes its marker. YAML: one step in after a line
  ending in `:`, `|`, `>` or a lone `-`. With syntax-aware indenting off,
  Return keeps the line's indentation.
- **Re-indent while typing.** The line re-indents when typing makes it
  start with a closer (`}`, `)`, `]`), completes a `case …` / `default`
  label (on the space after `case`, or the `:`), types `#else`,
  `#elseif` or `#endif` (Swift, C family), `</` (XML), or `fi`, `done`,
  `esac`, `else`, `elif` (shell).
- **Re-Indent (⌃I).** The touched lines re-indent in order (each line's
  opener already re-indented); an insertion point keeps its place in the
  line's text.
- **Closing brackets and quotes.** Typing `(`, `[` or `{` inserts its
  closer after the insertion point, and so does a quote of the language
  (`"` everywhere; `'` in the C family, XML, YAML and shell; `` ` `` in
  Markdown and shell; Swift has no `'` quote), when the next character is
  a space, a line end, a closer or `,` `;` `:` `.`, and not inside a
  comment or string. A quote does not pair after a word character, a
  backslash or the same quote (so `""` then `"` gives `"""`).
- **Stepping over.** Typing a closer or quote right before the closer that
  was inserted for it moves past it instead of inserting another. Only
  automatically inserted closers are stepped over; they stop counting when
  the insertion point leaves their line or the text around them is
  replaced.
- **Delete Backward** between an automatically inserted pair deletes both.
- **Enclosing a selection.** Typing an opening bracket or a quote with a
  selection puts the pair around it and keeps the selected text selected
  (a quote does not enclose a selection over several lines).
- **Tab and Shift-Tab.** A selection over several lines shifts them one
  step right (Tab) or left (Shift-Tab). Shift-Tab shifts the insertion
  point's line left. Tab with an insertion point or a one-line selection
  follows the Tab key setting:
  - *Indents in leading whitespace* (default): in the line's leading
    whitespace, the line gets its computed indentation when it has less
    (a blank line counts as its block's), the insertion point moves to the
    text when the line has exactly that, and one more step is added when
    it has more; elsewhere, spaces up to the next indentation stop (a tab
    with tabs).
  - *Indents always*: the line re-indents wherever the insertion point is.
  - *Inserts indentation*: one indentation step at the insertion point.
  Placeholders keep their Tab / Shift-Tab behavior (§Placeholders).
- **Comment Selection (⌘/).** Swift, the C family, JSON and build
  configuration files: `// ` at the start of each touched non-empty
  line; YAML and shell: `# `. When every touched non-empty line already
  has the comment, it is removed (with one following space). XML and
  Markdown: `<!-- ` before the first line's text and ` -->` after the last
  line, or both removed. A selection ending at a line start does not touch
  that line; an insertion point keeps its place in the text.

### Settings (Editing ▸ Indentation)

Ycode's own rows and defaults (the reference's page is still to observe,
`reference-ui-5.md` §12): Prefer indent using Spaces / Tabs (Spaces),
Tab width (4), Indent width (4; with tabs one step is one tab), Tab key
(Indents in leading whitespace / Indents always / Inserts indentation),
Syntax-aware indenting (on), Automatically insert closing brackets and
quotes (on), Enclose selection in matching delimiters (on). Stored under
`Ycode.indentWithTabs`, `Ycode.tabWidth`, `Ycode.indentWidth`,
`Ycode.tabKey`, `Ycode.autoIndent`, `Ycode.autoInsertClosers`,
`Ycode.encloseSelection`.

### Scope guides and invisibles

- Editor ▸ Scope Guides toggles Editing ▸ Display ▸ Scope guides between
  None (default) and Lines (Ycode's own choice): a thin line down each
  block spanning three or more lines, from below its first line to above
  its last, half a character in from the column where the first line's
  text starts. In large files the guides update with the folds, after
  typing pauses.
- Editor ▸ Invisibles (a user setting, `Ycode.showInvisibles`, default
  off) draws `·` for spaces, `→` for tabs and `¬` at line ends in the
  visible lines, in the tertiary label color.

### Dependencies and licenses

| Dependency | Use | License |
|---|---|---|
| swift-syntax 604.0.0 (`SwiftSyntax`, `SwiftParser`, `SwiftIDEUtils`), pinned exactly in `ycode/Package.swift` | Swift parsing, incremental reparse, syntax classification | Apache-2.0 |

tree-sitter (MIT) was considered for the other languages and not used:
each grammar is a generated C parser of several megabytes to vendor and
build on three hosts, and these languages' highlighting needs are
lexical. Ycode's line lexers are written from the languages' public
specifications (Evidence) and carry their state per line, which gives the
incremental behavior directly. A grammar can still replace a lexer behind
the same `LineLexer` interface later.

### Performance

A generated 20,000-line Swift file (`SyntaxBenchmark.swiftSource`), this
Mac (arm64), 2026-10-30.

Optimized build (`swift build -c release --product ycode-syntax-bench`):

| Measurement | Time |
|---|---|
| Full highlight, lexical | 9–11 ms |
| Full highlight, swift-syntax parse and classification | 76–128 ms |
| Per keystroke in a line: lexical pass | 0.02–0.04 ms |
| Per keystroke: parser pass (3 lines re-classified) | 1.1–2.4 ms |
| Typing `/*` (5,996 lines re-lexed to the end of the file) | 1.0 ms |
| Return (indentation from the structure) | under 0.002 ms |

Debug build, in the editor (`EditorPerformanceTests`):

| Measurement | Time |
|---|---|
| Open, with lexical colors | 941 ms |
| swift-syntax parse after opening | 2,143 ms |
| Per keystroke: lexical pass | 1.18 ms |
| Per keystroke: parser pass (runs after a pause in debug builds, over the 8 ms budget) | 106 ms |
| Keystroke to repaint (typed through the typing rules, then drawn) | 36.3 ms |
| 10,000 lines: keystroke with incremental coloring / full re-coloring | 24.2 ms / 1,011 ms |

Two costs found on the way and fixed: the theme was read (listing the
themes folder) once per token while coloring, and the jump bar's symbol
component re-scanned the file's symbols on every keystroke; colors are now
resolved once per kind per pass, and in files over 3,000 lines the symbol
component waits for the typing pause, as folds do.

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
- "Ycode implementation" (2026-10-30): the typing rules, indentation
  rules, settings, theme mapping, scope guides and invisibles are Ycode's
  own design. Lexical rules from public specifications (level 1): The
  Swift Programming Language, "Lexical Structure"; the C and C++
  standards' public drafts; Apple's public Objective-C and Metal Shading
  Language documentation; RFC 8259 (JSON); XML 1.0 (W3C); the CommonMark
  specification (CC BY-SA 4.0; behavior only, no text copied) and GitHub's
  public task-list documentation; YAML 1.2; the POSIX Shell Command
  Language; the build-setting file format in `specs/build-settings.md`.
  Swift classification from swift-syntax (Apache-2.0, level 1).
- OPEN QUESTION: the reference's Editing ▸ Indentation rows and defaults
  (Tab key choices, closing-brace and enclose-selection options, whether
  `case` labels are indented inside `switch`), which closers it steps
  over, and its Scope guides pop-up's other values (`reference-ui-5.md`
  §12).
