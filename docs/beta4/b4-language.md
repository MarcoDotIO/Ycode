# B4-LANGUAGE (1.0.0-beta.4)

Clean-room workstream for the language service: P-070, P-080 and P-121 of
`specs/ide/parity-inventory.md`. Specs updated: `specs/ide/language.md`
(§Features: completion while typing, the typing hold, message form) and
`specs/ide/build.md` (§Diagnostics: display form).

## P-070: false live diagnostics (cross-file types, test imports)

What the reference shows: `Counter` (declared in another file of the app)
resolves in `ContentView.swift`; `import XCTest` is fine in a test target.

What was found:

- The build-server path (`ycode-bsp`, `docs/PARITY.md` §6 #2) already gives
  sourcekit-lsp each target's real arguments. Driven end to end (the
  session's language service, sourcekit-lsp, `ycode-bsp`) on a project from
  Ycode's own iOS App template with XCTest unit and UI tests (synchronized
  folders, app-hosted unit tests) plus a `Counter.swift`, it resolves
  `Counter` in `ContentView.swift` and accepts `import XCTest` in both test
  targets. The same holds for projects under paths with spaces and accents,
  symlinked paths, and a file added to a synchronized folder while the
  server runs.
- A real false error remained: sourcekit-lsp diagnoses an opened document
  before the modules of its target's dependencies are prepared, and does not
  publish again once they are. The unit tests' `@testable import CounterApp`
  stayed "No such module 'CounterApp'" until the next edit (reproduced by
  slowing module emission; seen once on a cold module cache). A
  `buildTarget/didChange` from the build server after preparation does not
  make it publish again; re-sending the document does.
- Fix: when the server's work progress ends (preparation and indexing,
  `$/progress`), the session sends every open document that has errors
  again, unchanged, once per set of errors and text
  (`LanguageService.refreshDiagnosticsWithErrors`, YcodeIDECore). Both IDEs
  go through it.

Not reproduced in the clean room: the parity run's exact state ("Cannot
find 'Counter'" and `import XCTest` flagged together). That pair is what
sourcekit-lsp gives with fallback settings, that is when the files get no
arguments from the build server at all. The build server works on every
template-shaped project tried; the parity project itself (made in the
dirty room) was not available here. If the state recurs, the build
server's log (`ycode-bsp --log`) for that project is the next thing to
look at.

The preview canvas's copy of the error (same row) comes from the preview
build, not the language service: left to the previews workstream.

Tests: `CrossFileLiveIssuesTests` (YcodeBuildServerTests; macOS: the iOS
App template; Linux: the same layout with portable sources), with a fresh
index arena and slowed module emission, and no edits from the test.

## P-080: completion while typing

- `CompletionTrigger` (YcodeLanguage, shared by both IDEs): the first
  character of a word (letter or `_` after a non-identifier character)
  asks for completions in Swift and C-family files; a `.` in Swift asks for
  members. Never in a comment or a string literal opened on the line, after
  a number, a range's `..`, `$`, `#`, `@` or `\`, nor for the name after a
  declaring keyword (`let`, `var`, `func`, `struct`, …).
- Order: sourcekit-lsp caps a list at 200 items in no useful order; the
  client now sorts by `sortText` (then the label). For "Co" in the template
  project the list starts Counter, ContentView, Codable…
- Incomplete lists (`isIncomplete`) are asked for again on each further
  character of the word; complete ones only filter. An answer that arrives
  after more typing still shows, filtered by the whole word (it used to be
  dropped if the caret had moved).
- The line being typed is not marked at once: `LiveIssueHold` keeps that
  line's live issues back until 1.5 s after its last edit (Ycode's value;
  none was measured), in the session, so the editors, the issue navigator
  and the toolbar counts agree.
- Linux: completion while typing is on by default (it was an opt-in for
  the beta), with the same rules (`EditorCompletion.shouldRequest`).

Tests: `TypingCompletionTests` (YcodeLanguage), `CompletionWhileTypingTests`
(YcodeUI, offscreen key events), `EditorCompletionTriggerTests`
(YcodeIDEShell); Linux walk `YCODE_IDE_B4LANG=<prefix>` (open a project
with `ContentView.swift`, `main.swift` and `CounterAppTests.swift`).

## P-121: issue message text

`Diagnostic.displayMessage` (YcodeBuild): the diagnostic-group suffix
(" [#VariableNeverMutated]") is dropped and a first word in lower-case
letters is capitalized. Applied where issues enter Ycode: the build-log
parser, swift-build's structured issues and the language server's live
issues, so the issue navigator, the editor annotations and the toolbar on
both IDEs show "Variable 'neverMutated' was never mutated…". Tool prefixes
("ld: …"), quoted names and clang's "[-W…]" flags stay.

Tests: `DiagnosticDisplayTextTests` (YcodeBuild); `DiagnosticParserTests`
updated for the display form.
