# B4-WORKFLOWS: broken workflows (1.0.0-beta.4)

Clean-room workstream. Spec: the P-item rows of `specs/ide/parity-inventory.md`
plus `specs/ide/schemes.md`, `merge-sheet.md`, `signing.md`, `project-editor.md`.

| P-item | What changed | macOS | Linux |
|---|---|---|---|
| P-096 | The Signing section names Ycode: caption "Ycode will choose matching installed profiles and certificates.", profile "Ycode Managed Profile". A Mac box without a team signs to run locally: "None Required", "Sign to Run Locally", no "requires a development team" warning (device platforms still warn). | `ProjectEditorModel.signingBoxes` | no project editor on Linux (beta 7) |
| P-098 | The capability library is a floating panel over the window (`CapabilityLibraryPanel`), not a sheet: Escape (in the filter too) and ⌘. close it without adding, a click outside (the panel stops being key) closes it, a row double-click adds that row. | `CapabilityLibraryController.swift` | no project editor on Linux |
| P-100 | A tab's minimum width no longer reaches the window: the tab fills the editor below the window's size priorities and is clipped when wider, so Build Settings and Build Phases keep a 1400-point window and a resize back to 1400 works. | `ProjectEditorController.showTab` | no project editor on Linux |
| P-108 | Edit Scheme… opens autocreated schemes (`WorkspaceModel.schemeForEditing`); Manage Schemes lists them (`schemesForManaging`) with their container; an autocreated scheme is written (with its siblings) only once changed; Shared writes it first. | `WorkspaceWindowController+SchemeEditing.swift` | no scheme editor on Linux (L-155) |
| P-109 | Every scheme option with a known attribute is editable (`SchemeOptionBinding`, `Scheme.setAttribute`, schemes.md §Options); Duplicate Scheme works. Rows without an attribute in the clean evidence stay disabled (listed in schemes.md). | `SchemeEditorController.swift`, `SchemeEditorOptions.swift` | no scheme editor on Linux |
| P-110 | The first Escape (or ⌘.) ends a field's editing and discards the typed value; the second closes the sheet. | `SchemeEditorEscapeView` | no scheme editor on Linux |
| P-123 | Activate Console (⇧⌘C) shows the console half and gives it the keyboard: the lldb command line during a debug session, else the console's output, so typing never reaches the source. | `DebugAreaController.focusConsole` | `DebugArea.swift` (`consoleFocusPending`) |
| P-131 | The merge sheet's Cancel closes the sheet at once (no app-modal question, which kept it from answering); an operation Ycode started is aborted, one started elsewhere stays stopped. A sheet with nothing left to show closes instead of staying "0/0"; a closing overlay is never reused. | `SourceControlCoordinator+Merge.swift`, `MergeOverlay.swift` | `SourceControlShellModel+Conflicts.swift`; the sheet is laid out for a window 28 points shorter (the macOS overhang) so Cancel and Merge sit inside the window (`MergeOverlay.swift`, completing P-215 for the merge sheet) |
| P-132 | New Branch… is a sheet "Create new branch in “<repository>”:" with From and To; Create is disabled until a name is typed. | `NewBranchSheet.swift` | the prompt's wording, From row (`SourceControlPrompt.info`) |

Hygiene: `Subprocess.run(timeout:)` stops a child that hangs (SIGTERM, then
SIGKILL); every git command of a test process runs with a 120-second
timeout, so a test that waits on git fails instead of hanging. The merge
sheet's Cancel no longer starts an app-modal alert when the window is on
screen (a source of the MergeSheet test stalls).

Tests: `WorkflowsProjectEditorB4Tests`, `WorkflowsSchemesB4Tests`,
`WorkflowsSourceControlB4Tests` (YcodeUITests), `SigningTrademarkTests`
(YcodeIDECoreTests), `SubprocessTimeoutTests`, `WorkflowsShellB4Tests`
(YcodeIDEShellTests); Linux walk `YCODE_IDE_WORKFLOWS4`
(`ShellDriver+Workflows4.swift`) and the conflict walk.

## Verification

- P-100's test reproduces the defect without the fix (Build Settings and
  Build Phases widen a 1400-point window to 1530, Info needs 1307 against
  General's 1187, the resize back is refused) and passes with it.
- Linux: `scripts/linux-conflict/run.sh` passes every check, the rebase now
  cancelled from the sheet with one click (no question); the
  `YCODE_IDE_WORKFLOWS4` walk reports the source unchanged after ⇧⌘C and
  typing, and New Branch's Create disabled until a name is typed.

## Lines for B4-MENUS (hot files)

Done after the merge (B4-FINISH, commit `481b400c`): `editSchemeThenPerform`
(Product ▸ Run… / Test… / Profile… / Analyze… / Archive…) opens autocreated
schemes through `schemeForEditing(named:)` and `configuredSchemeEditor`
(test: `WorkflowsSchemesB4Tests.ellipsisVariantOpensAnAutocreatedScheme`).

## Left for later betas

- No project editor or scheme editor on Linux (beta 7: L-155), so P-096,
  P-098, P-100, P-108, P-109 and P-110 have no Linux half yet.
- P-109: options without an attribute in the clean evidence stay disabled
  (schemes.md §Options, "Still disabled").
