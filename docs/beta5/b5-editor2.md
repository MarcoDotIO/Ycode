# B5-EDITOR2 (1.0.0-beta.5)

Clean-room workstream for beta 4's editor and language leftovers in
`specs/ide/parity-inventory.md`: P-054, P-065 (Linux), P-066, P-070, P-167.
Tests: `ycode/Tests/YcodeUITests/Beta5EditorTests.swift` (macOS, offscreen),
`YcodeEditorKitTests/DocCommentLayoutTests.swift` (the Linux editor's
layout), `YcodeIDECoreTests/LateArgumentsRecheckTests.swift` and
`YcodeBuildServerTests/B5LiveDiagnosticsTests.swift` (both IDEs' language
service), and the Linux walk `YCODE_IDE_B5EDITOR2=<prefix>`
(`ShellDriver+B5Editor2.swift`). Specs updated: `source-editor.md`
(documentation comments), `editor-area.md` (§Splits), `language.md`
(§Build server: the log, late arguments).

| P-item | What changed | macOS | Linux |
|---|---|---|---|
| P-054 Doc comments | The text after `///` (and inside `/** … */`) in the proportional system face at the source size; the delimiters stay in the source font; the comment grey (#6A7084 light, #ABB3CD dark) from beta 4. One rule, `EditorDocCommentStyle` (YcodeSyntax). A theme's own doc-comment font wins. Settings ▸ Appearance's sample follows (it highlights through `Theme`). | fixed (`Theme.font(for:)`, `Theme.apply`) | fixed: `EditorLineLayout` gives those characters the proportional face's widths (carets, selection, hit testing, wrapped rows), `SourceEditorView+DocComments.swift` draws them on the source font's baseline |
| P-065 Editor Options (Linux) | Code Coverage, Invisibles and Scope Guides toggle the shared settings and the Linux editor now draws them as the macOS editor does (`SourceEditorView+Guides.swift`: guides at the block's text column, `·` `→` `¬` in the tertiary label colour, a 4-pt coverage strip from the newest coverage run); Choose Workspace Theme… opens Settings ▸ Appearance | — (already) | partly: Inline / Side By Side Comparison stay disabled (no Code Review on Linux) and Authors stays disabled (no blame column on Linux) |
| P-066 Close Editor in a split | File ▸ Close "<file>" in a split empties only the focused pane, which keeps its half and shows "No Editor" centred (20 pt, tertiary label), as the assistant with no counterpart; a pane left alone turns back into the lone editor's start page (`EditorPanePlaceholder`). A new pane that Settings ▸ Navigation opens on the Start Page keeps it | fixed: 1400 × 880 window, editor area 850: panes 425 / 424 before and after; the assistant 424 (half) | fixed: panes 423 / 425, "No Editor" centred in the emptied pane |
| P-070 False live diagnostics | Not reproduced in the clean room (below). Build server: `--log` now names every file it answers without arguments and why, and every request answered after ≥ 500 ms (sourcekit-lsp's fallback threshold). Session: a document with errors is sent again once, 3 s after its errors arrive, so a diagnosis made with fallback settings is redone when the arguments came late and no work progress ends afterwards | partly (cause not reproduced; the late-arguments case handled) | as macOS (shared `LanguageService`) |
| P-167 Preview focus | Tried once, as the row describes: a macOS preview built and rendered in the canvas while watching every application Ycode starts and every activation. No new process could take the key window (all preview hosts `.prohibited`), no activation. Not reproduced; no code changed | not reproduced | not checked (no key-window concept tested) |

## P-070: what was tried

On a project from Ycode's iOS App template (SwiftUI, Swift Testing unit
tests, XCTest UI tests, synchronized folders) with `Counter` (an
`@Observable` class) in `Counter.swift` and `ContentView.swift` using it
twice:

- `ycode-bsp targets` / `args`: `Counter.swift` is in the app target and in
  `ContentView.swift`'s arguments (iOS Simulator SDK). Same with
  `Counter.swift` in a nested synchronized sub-folder (`Models/Sub`), in a
  classic `PBXGroup` ("Plain") built through the Sources phase, and through
  a `.xcworkspace` and the project's inner workspace.
- The IDE's timeline (`B5LiveDiagnosticsTests`): the language server starts
  with no scheme or destination, then the scheme and an iOS Simulator
  destination arrive and the server restarts; `ContentView.swift` ends
  with no errors and the build server's log has no "no arguments" line
  (Mac and x86).
- Model load for the template project: about 0.7 s cold, 0.02 s warm.

So the round-11 state (two "Cannot find 'Counter' in scope" and a red "2")
is sourcekit-lsp's fallback diagnosis, but its trigger in the council's
project is still unknown. The next council run's `ycode-bsp --log` lines
("sourceKitOptions: no arguments for …: <reason>", "… answered after N
ms") will say whether the file is outside the targets, the target has no
settings, or the answer came too late; the late recheck covers the last.

## Screenshots

- macOS: `ycode/.build-ide/b5-shots/mac-p054-doc-comments-light.png`,
  `-dark.png`, `mac-p066-assistant.png`, `mac-p066-close-in-split.png`.
- Linux (x86): `~/Ycode-B5-EDITOR2/shots/linux-b5-doc-light.png`,
  `-doc-dark.png`, `-guides.png`, `-no-editor.png`, `-options.png`.

## Known limits

- Linux: wrapped rows still break at the column count, so a wrapped
  documentation comment (narrower in the proportional face) breaks a
  little early.
- Linux: proportional text is drawn as one run per comment and measured
  per character; kerning can move a caret inside a comment by a fraction of
  a point.

## Tests

- Mac, focused: `Beta5EditorTests` (4 tests, 5 cases), `DocCommentLayoutTests`
  (3), `LateArgumentsRecheckTests` (2), `B5LiveDiagnosticsTests` (1),
  `CrossFileLiveIssuesTests` (1, now found under any scratch path),
  `EditorServicesPreparationTests` (2): all pass.
- Mac, full `YcodeUITests`: 862 tests, 4 failures under load
  (`SimulatorSideR37Tests` time limit, `AgentModeUITests`,
  `LanguageWindowTests`, and `SettingsR33Tests.navigationSettingsTakeEffect`,
  which was this branch's: a new pane opened on the Start Page by the
  setting; fixed, the No Editor placeholder is now only for Close
  "<file>"); all four pass alone after the fix.
- x86, full suite: 3002 Swift Testing tests pass (first run: two load
  failures, `EditorServicesPreparationTests` timing and
  `CrossFileLiveIssuesTests`, the second from this branch's late recheck
  sharing the progress-end refresh's record; fixed, both pass alone and in
  the second full run).
