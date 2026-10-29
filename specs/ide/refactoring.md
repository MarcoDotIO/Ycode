# Refactoring and code navigation (language server)

Ycode modules: `YcodeLanguage` (`LSPClient` requests, `TextEdit`,
`WorkspaceEdit`, `CodeAction`, `CallHierarchyItem`), `YcodeUI`
(`WorkspaceWindowController+Refactoring`, `SourceEditorController`,
`GutterView`). All of it goes through the Language Server Protocol to
sourcekit-lsp; Ycode adds no semantic analysis of its own.

## Client capabilities added

`textDocument.rename.prepareSupport`, `references`, `callHierarchy`,
`declaration`, `codeAction.codeActionLiteralSupport` (kinds `quickfix`,
`refactor`, `refactor.extract`, `refactor.inline`, `refactor.rewrite`,
`source`, `source.organizeImports`),
`publishDiagnostics.codeActionsInline` (fix-its attached to diagnostics),
`workspace.applyEdit`, `workspace.workspaceEdit.documentChanges`.
The server's `workspace/applyEdit` requests are answered `{applied:
true}` and applied by the window.

## Applying edits

A `WorkspaceEdit` (`changes` or `documentChanges`) is applied file by
file, edits last-to-first:

- Files open in any editor change in that editor as one undo group
  ("Refactor"), so ⌘Z undoes the whole change in that file.
- Other files are rewritten on disk; their previous text is kept, and
  `revertDiskRefactorings()` restores them. The server is told with
  `workspace/didChangeWatchedFiles` (never `didChange` for a file it does
  not have open).

## Rename (Editor ▸ Refactor ▸ Rename…)

1. `textDocument/prepareRename` at the caret; when it returns nothing,
   the command beeps.
2. Every whole-word occurrence of the name in the file is highlighted,
   and a rename field opens over the symbol (Return commits, Escape
   cancels).
3. `textDocument/rename`. One file: applied at once. Several files: a
   preview sheet lists the files with their edit counts; Rename applies,
   Cancel drops it.

## Find

- Find ▸ Find Selected Symbol in Workspace (⌃⇧⌘F):
  `textDocument/references` (with the declaration). The Find navigator
  shows `<name> — <n> references`, then files (`File.swift  (n)`), then
  `line: text` rows that open the location.
- Find ▸ Find Call Hierarchy (⌃⇧⌘H): `prepareCallHierarchy`, then
  `callHierarchy/incomingCalls` two levels deep, as a tree under
  `Callers of <name>`.
- Navigate ▸ Jump to Original Source: `textDocument/declaration`, else
  the definition. (Jump to Definition is unchanged.)

## Code actions and fix-its

- Editor ▸ Show Code Actions (⇧⌘A): `textDocument/codeAction` for the
  selection with the diagnostics on its lines; a menu at the caret
  ("No Actions Available" when empty). Choosing one applies its `edit`
  and then runs its `command` (`workspace/executeCommand`); edits the
  server makes come back as `workspace/applyEdit`.
- Editor ▸ Refactor: the fixed items of `reference-ui-4.md` §8.2 in that
  order, each mapped to a sourcekit-lsp code action by title and kind and
  disabled when no action matches at the caret; then any other
  non-quickfix actions last fetched at the caret, without duplicates.
  Opening the menu fetches again. Items with no sourcekit-lsp equivalent
  (Extract Selection to File, Add Missing Abstract Class Overrides,
  Generate Missing Function Definitions, the three localized-string items)
  are always disabled.
- Fix-its: inline `codeActions` of a diagnostic whose edits stay in the
  file become the issue's fix-its. Clicking the issue's annotation (right
  of the code) opens a menu with the message and "Fix", which applies the
  line's fix-its. (Corrected by `reference-ui-6.md` §4.3.2: the gutter
  draws no issue dot or lightbulb.)
- Editor ▸ Fix All Issues: every distinct fix-it of the focused file, as
  one undo group.

Observed with sourcekit-lsp 6.4 (tests): on a struct name "Add
documentation", "Generate Memberwise Initializer", "Add Equatable
Conformance"; on an expression "Extract Expression", "Extract Method",
"Extract Repeated Expression"; a never-mutated `var` gets a `let` fix-it.

## Evidence

- Requests, results and capabilities: the Language Server Protocol
  specification (level 1); sourcekit-lsp's open source for
  `codeActionsInline`, `semantic.refactor.command` and the action list
  (level 1); behavior checked against the real server in
  `RefactoringTests` (level 3, Ycode).
- Menu names and shortcuts: Apple's published Xcode shortcut reference
  (level 1).
- OPEN QUESTION: the reference's in-place multi-cursor rename look and
  its cross-file preview layout; caller levels shown by default; whether
  Fix All Issues also covers build issues of other files.
