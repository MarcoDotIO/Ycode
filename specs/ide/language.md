# Language services

Ycode module: `YcodeLanguage` (`LSPClient`), wired into the window by
`YcodeUI` (`LanguageService`, editor completion popup). The server is
sourcekit-lsp, Apple's open-source Language Server Protocol server for Swift
and C-family languages.

## Locating the server

`YCODE_SOURCEKIT_LSP`, else `xcrun -f sourcekit-lsp` (macOS), else
`sourcekit-lsp` on PATH. One server per workspace window, started when the
window opens. The root is the package folder, or the folder that contains
the project or workspace.

## Protocol

JSON-RPC 2.0 messages with the same `Content-Length` framing as DAP
(`specs/ide/debug.md`). Requests have numeric ids 1, 2, 3, …; errors become
`ResponseError(code, message)`. Server-to-client requests are answered at
once: `workspace/configuration` with one `null` per item, others with
`null`.

Sequence: `initialize` (processId, rootUri, workspaceFolders, clientInfo
"Ycode", capabilities: didSave, completion with snippet support (snippet
placeholders become editor placeholders), definition,
publishDiagnostics with related information, workspace configuration) →
`initialized`. Closing: `shutdown` → `exit`.

Documents: `didOpen` when the editor opens a file (languageId from the
extension: swift, objective-c, objective-cpp, cpp, c); `didChange` with
the full text and an increasing version on every edit; `didSave` after
the editor writes the file; `didClose` when no editor shows the file any
more.

Positions are 0-based lines and UTF-16 code-unit columns; the editor's
line index converts both ways (clamping columns to the line).

## Features

- Live issues: `textDocument/publishDiagnostics` replaces that file's live
  issues. Severity 1 → error, 2 → warning; information and hints are
  dropped. Lines and columns become 1-based. The issue navigator, editor
  annotations and activity-view counts show build issues plus live issues,
  without duplicates.
- Completion: Show Completions (⌃Space), or typing `.` in a Swift file,
  sends `textDocument/completion` at the insertion point. The popup sits
  below the word being completed, shows up to 8 rows (kind letter, label,
  detail), and filters as the user types (prefix matches first, then
  substring matches). Placement: the popup's top edge is 2 pt below the
  line of the word being completed, and its label column starts at the
  word's first character; the caret rectangle comes from TextKit 2 line
  fragment geometry (laid out on demand after edits). Height: 20 pt per row
  (at most 8 rows, then it scrolls) plus 3 pt padding top and bottom, plus a
  22 pt documentation line when the selected item has `documentation`
  (plain text or MarkupContent value, shown on one line). The popup is
  hosted above the editor's scroll view. Up/Down move; Return, Enter or Tab insert (replacing
  from the item's `textEdit` start, else from the word start); Escape or
  moving before the word closes it. Double-click inserts.
- Jump to Definition (⌃⌘J): `textDocument/definition` at the insertion point;
  the first `Location`/`LocationLink` is opened and the insertion point
  placed at its start.

- Quick Help: ⌥-click on a symbol sends `textDocument/hover` at that
  position; the result (MarkupContent value, MarkedString, or an array of
  them, joined by blank lines) is shown as plain text — code fences
  dropped, rules as blank lines, backticks removed — in a popover at the
  symbol. The Quick Help inspector (⌥⌘3) parses the same result as Swift
  Markup and shows sections in the order of `reference-ui-4.md` §7: title
  and summary, declaration box, defining file link, Parameters, Return
  Value, Throws, Discussion, boxed callouts, "Open in Developer
  Documentation" (opens a developer.apple.com search). While the Quick Help
  inspector is showing, moving the insertion point refreshes it.
- ⌘-click on a symbol places the insertion point there and does Jump to
  Definition.

## Evidence

- LSP messages, positions and capabilities: the Language Server Protocol
  specification (Microsoft, open) and sourcekit-lsp's open-source
  documentation (level 1).
- Black-box runs of the public `sourcekit-lsp` tool on a small package
  (level 3): a semantic error was published for a file opened without
  building; completion after `g.` listed members; definition returned
  the declaration line.
- Shortcuts ⌃Space and ⌃⌘J: Apple's public Xcode shortcut reference
  (level 1).
- Quick Help gestures (⌥-click, Quick Help inspector) and ⌘-click: Xcode
  Help (level 1); hover verified against sourcekit-lsp: the hover for a
  struct included its declaration and doc comment (level 3).
- Quick Help inspector sections: `reference-ui-4.md` §7 (level 3).
- OPEN QUESTION: whether Xcode's ⌥-click popover uses the same sections
  (ours is plain text).
- OPEN QUESTION: Xcode's completion popup layout (icons, detail column,
  documentation pane), when it opens automatically, and how live issues
  and build issues are distinguished in the issue navigator.
