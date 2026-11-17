# B4-WINDOWS (1.0.0-beta.4)

Clean-room workstream. Sources: `specs/ide/parity-inventory.md` rows P-022,
P-023, P-177, P-178, P-179, P-184, P-216, with `templates.md` (Save step,
Persistence), `reference-ui-3.md` §5 and `fidelity-council.md` row 241.

## P-177 New Project can finish

- **Cause (macOS).** Next on the options step began the save panel as a
  sheet of the empty workspace window, which already showed the template
  sheet. AppKit queues a second sheet on a window until the first ends, so
  nothing appeared and Next seemed dead.
- **Fix (macOS).** The save panel is attached to the template sheet's own
  window (`templates.md` § Save step: "a save panel attached to the
  sheet's window"). `NewProjectFlow.runSavePanel` and
  `NewProjectFlow.openDocument` are hooks so tests run the whole flow
  offscreen.
- **Fix (Linux).** New Project from Welcome no longer opens its sheet on the
  480-point Welcome window (where it was clamped and Next fell outside).
  As on macOS, an empty workspace window opens and the sheet sits on it;
  Welcome closes; Cancel goes back to Welcome; Create opens the project in
  that window. `ShellAppModel.presentsNewProject(in:)` routes the sheet.
- Tests: `B4WindowsUITests.newProjectFromWelcomeCreatesAndOpens` (Welcome ▸
  Choose Template… ▸ macOS Command Line Tool ▸ name, organization ▸ Next ▸
  save step on the sheet's window ▸ project written and opened as a
  `WorkspaceModel`), `B4WindowsShellTests.newProjectFromWelcomeOnAWorkspaceWindow`,
  Linux walk `YCODE_IDE_WINDOWS4`.

## P-178 Options step

- Organization Identifier starts from the last project's (the shared
  persisted value; it now gets stored because the flow finishes).
- Testing System starts at "Swift Testing with XCTest UI Tests" when nothing
  is stored (`NewProjectFlowModel.defaultTestingSystem`); a stored choice
  wins.
- Product Name has focus when the step opens; Tab goes Product Name ↔
  Organization Identifier (macOS: explicit key-view loop of the text
  fields; Linux: `@FocusState`, and Tab already walks only text fields).
- Every control and label has a help tag (`TemplateOptionField.help`,
  Ycode's own wording): tooltips on macOS, `.help` on Linux.
- With SwiftUI the Language pop-up offers Swift only (values the rules do
  not allow are hidden in that pop-up; `hidesDisallowedValues`).
- Not done: Team lists a signed-in team. Ycode does not sign in to
  accounts (`AccountsPage`), so Team stays "None".

## P-179 File ▸ New ▸ Project… at Welcome

- `WelcomeWindowController.newProject(_:)` (⇧⌘N): the compact picker as a
  sheet on Welcome; a row continues as Welcome's pull-down does (the
  template sheet on an empty window, Welcome closes).
  `chooseProjectTemplate(_:)` opens the template sheet directly.
- The Choose Template… alternate (⌥⇧⌘N) has no action in `CommandTable`;
  B4-MENUS adds `chooseProjectTemplate:` (implemented on Welcome and on
  workspace windows).

## P-023 Placement

- Welcome opens on the screen of the key workspace window (else the key or
  main window's), with row 241's rule inside that screen.
- New Project's empty window is centred on the screen of the window it was
  started from.
- Welcome closes when New Project's sheet opens, and the Window menu's list
  leaves it out (`isExcludedFromWindowsMenu`).
- Linux: the compositor places windows (L-176); not changed.

## P-022 Second windows (macOS)

- File ▸ New ▸ Window (⇧⌘T, `newWorkspaceWindow:`) opens another window on
  the workspace, 22 points down and right, owned by the same document; ⌘W
  closes that window only. Window Tab (`newWindowForTab:`) adds it as a
  tab of the window's group (the tab bar's + too).
- Linux: one workspace per app (L-008, L-225: needs per-window workspace
  models in `ShellAppModel`). Moved to beta 5.

## P-184 New File on macOS

- The macOS tab lists Cocoa Class, and User Interface: SwiftUI View,
  Storyboard, Application, Window, View (Ycode's own minimal AppKit
  documents for Application and Window).
- The New File grid has five columns of monochrome outline glyphs; the
  selection is a grey tile with the name on an accent capsule; Next is
  96 points wide.
- Not changed: the sections after User Interface (the run's capture showed
  fewer rows of the reference's grid; whether its macOS tab has Test, Core
  Data and Resource is not recorded) and the sheet's timing.
- Linux has no New File sheet (L-151, P-187, beta 5).

## P-216 Window ▸ Welcome on Linux

- `perform(.welcome)` opens Welcome's window beside the workspace instead
  of closing the workspace. Opening a project or New Project from it closes
  Welcome. While a workspace window is open, the app's sheets and alerts
  show only on it (`presents(in:)`), never twice.

## Tests and walks

- macOS (offscreen guard on): `B4WindowsUITests` (5 tests:
  `newProjectFromWelcomeCreatesAndOpens`, `optionsStepDefaultsAndLanguage`,
  `welcomeNewProjectPickerAndPlacement`, `secondWindowAndWindowTab`,
  `newFileMacOSTemplates`); shots `.build-ide/b4-shots/macos-*.png`.
- Linux model: `B4WindowsShellTests` (3 tests).
- Linux GUI: `YCODE_IDE_WINDOWS4=<prefix>` (`ShellDriver+Windows4.swift`)
  walks Welcome ▸ New Project ▸ macOS Command Line Tool ▸ typed name, Tab,
  organization ▸ Next ▸ Create (the project opens on `main.swift`) ▸
  Window ▸ Welcome beside the workspace; shots `<prefix>-*.png`.

## Left for later

- P-022 on Linux (second windows need per-window workspace models; L-008,
  L-009, L-225): beta 5.
- P-179: ⇧⌘N with no window at all (no Welcome) still does nothing; File ▸
  New ▸ Workspace… and Target… have no action yet.
- P-184: the sheet appears ≈ 190 ms sooner than the reference (motion).
- P-178: Team cannot list a signed-in team (no accounts); on Linux every
  value the rules disallow is left out of its pop-up, on macOS only
  Language's (others stay drawn disabled, Ycode's choice 9).

## Orchestrator requests (after merging B4-TOOLKIT)

- Linux alerts show the Ycode icon (`shellAlertIcon()`, OpenViews'
  `_alertIcon`, after the shell's `.alert` modifiers).
- Escape closes the Linux About sheet (a hidden cancel action).
- Both are checked at the end of the `YCODE_IDE_WINDOWS4` walk.
