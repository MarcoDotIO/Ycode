# B5-NEWPROJECT (1.0.0-beta.5)

Clean-room workstream. Sources: `specs/ide/parity-inventory.md` rows P-181,
P-182, P-183, P-186, P-187 and P-022 (Linux), with `templates.md`
(Template chooser, Options step, Save step), `reference-ui-3.md` §5 and
council round 11's New Project finding (B03). Shared measurements live in
`YcodeIDECore/Model/NewProject/TemplateChooserMetrics.swift`
(`TemplateChooserMetrics`, `TemplateGridNavigation`), read by both IDEs.

## P-181 Template chooser: keyboard, filter, grid

- **Keyboard.** The grid takes keyboard focus when the template step shows.
  Left and Right step through the templates in order (across sections), Up
  and Down keep the column and cross into the neighbouring section's
  nearest row (`TemplateGridNavigation`, one rule for both IDEs). Tab goes
  between the filter and the grid (macOS: an explicit key-view loop; Linux:
  `@FocusState`).
- **Filter.** Always drawn, 202 points wide, at the right of the tab row;
  it never collapses (required compression resistance on macOS).
- **Tabs.** Small segments with 10-point labels, each as wide as its label
  (Linux: Ycode's own `PlatformTabs`, so "Multiplatform" is never cut,
  L-234).
- **Grid.** Five columns of outlined glyphs (a 32-point box, ≈ 31.5 points
  of ink) on a 137-point pitch (133-point tiles, 4 apart); the selection is
  a grey tile with the name on an accent capsule; section headers on a
  darker band; no frame and no background box. The New File grid shares it.
- **Heading.** Regular weight, 13 points.
- **No description line.** A template's summary is its tile's tooltip; the
  caption line shows only the filter's empty state.
- **Next** fades the options step in over 190 ms (ease-out; none with
  Reduce Motion). The constant is `TemplateChooserMetrics.optionsFadeDuration`
  until B5-MOTION's shared constants exist.
- **Order.** macOS ▸ Framework & Library: Framework, Library, Metal Library,
  XPC Service, Bundle (Metal Library's sort key 11; `templates.md` updated).

## P-182 Options step look

- Pop-ups 20 points tall (the small control size, 13-point text), every
  control 267 points wide, rows on a 33-point pitch (20-point rows, 13
  apart; a bordered field overhangs its row evenly).
- The pop-ups' fill is #2F2F31 in the dark appearance (`bezelColor`; the
  light appearance keeps the system's).
- Product Name is borderless with no focus ring.
- The heading is regular weight.
- Not changed: the sheet colour (#1E1E1E against #1F1F21) is the system's
  sheet material on macOS 26+.
- Linux: the same rows, widths and pitch; pop-ups use OpenViews' borderless
  pop-up (value, then chevrons at the end, 267 × 20); its fill is the
  toolkit's (request to B5-OPENVIEWS / B5-STATES below).

## P-183 The window behind the chooser

`WorkspaceWindowController.makeBareChooserHost()` (new
`WorkspaceWindowController+ChooserHost.swift`), called by
`NewProjectFlow.emptyWorkspaceWindow`: no navigator rows, no toolbar title,
no scheme or destination, the editor and inspector hidden (no text area or
find bar exposed to accessibility). The window keeps its accessibility
title "Untitled". Linux: the empty workspace window was already bare
(`Color.clear`).

## P-186 Welcome

- **Open…** fades Welcome out (100 ms), closes it, then runs the Open
  panel on its own; Cancel brings Welcome back when no workspace window is
  open. `WelcomeWindowController.runOpenPanel` is the tests' hook.
- **Close button.** A drawn 37-point circle (centred where the 36-point one
  was) with a 13-point ×; dark fill #3C3D3E, #505152 under the pointer.
- **Accessibility.** The close button is first; the buttons' names are
  descriptions (no titles); the recent list is an outline.
- **Menu.** New Project's menu opens 10 points below the button, without
  its title item.
- **Recent rows.** The text moves 2.75 points left and 0.5 points up
  (`WelcomeRecentRow`, both IDEs).
- **Linux.** The same close button with the hover fill (L-237); the buttons'
  names as accessibility labels; New Project is a pull-down of the compact
  picker's rows; the recent list takes the keyboard (Up, Down, Return;
  L-070), its selection is the accent colour while focused, the full path is
  the row's tooltip (L-177).
- Not done on Linux: Open… cannot close Welcome first (OpenViews' file
  dialog lives in a window; closing the last window quits the app), and the
  menu opens 4 points below its button (the toolkit's offset).
- Not done: the menu's 48 ms (motion).

## P-187 New Project and New File on Linux

- The New Project sheet is 720 × 480, with the macOS layout (P-181, P-182).
- File ▸ New ▸ Project… opens the compact picker first (`Step.picker`), as on
  macOS; its rows continue in the same sheet (App makes the untitled
  project).
- The save step stays a page of the sheet (OpenViews' file dialog takes no
  accessory); it now offers "Save both projects in a new workspace" when Add
  to names a project (L-154).
- New File (⌘N, `newFile:`): `NewFileShellModel` and `NewFileSheet`, 720 ×
  480: the same chooser, then Save As, Group (the project's groups, the
  selection's preselected) and Targets (the selection's targets checked);
  Create writes through `ProjectFileOperations` (as the macOS
  `createNavigatorFiles`), saves the project, rebuilds the navigator
  (`WorkspaceShellModel.reloadProjectTree()`) and opens the file.
- L-153 (clamped on Welcome) was closed in beta 4 (the sheet on a workspace
  window).

## P-022 Second windows on Linux

- File ▸ New ▸ Window (⇧⌘T, `newWorkspaceWindow:`) opens another workspace
  window on the open workspace (OpenViews' `WindowGroup` opens a second
  instance). Only the first window presents the app's sheets and alerts.
- With two or more workspace windows, Close Window (⇧⌘W) and ⌘W without a
  file close the active window only (`closeActiveWorkspaceWindow`, installed
  by the window whose `appearsActive` became true).
- Not done: the windows share one `WorkspaceShellModel`, so they show the
  same navigator selection and editor (per-window state needs the model
  split into document and window parts); Window Tab stays disabled (OpenViews
  has no window tabs); opening a second project still replaces the first
  (L-008).

## Tests and walks

- macOS (offscreen guard on): `B5NewProjectUITests` (6 tests); shots
  `.build-ide/b5-shots/macos-b5-*.png`.
- Linux model: `B5NewProjectShellTests` (6 tests).
- Linux GUI: `YCODE_IDE_NEWPROJECT5=<prefix>` (`ShellDriver+NewProject5.swift`).

## Requests to other workstreams

- **B5-OPENVIEWS:** (1) a file dialog that can take an accessory view (the
  Linux save step could then be the save panel, as on macOS) and that can
  open without a parent window (Welcome's Open… could close Welcome
  first); (2) a per-`Menu` offset for the pop-up (Welcome's New Project
  menu 10 points below its button; OpenViews uses 4); (3) a window's views
  get `onDisappear` when its window closes (a second workspace window
  closed by its own close button leaves the shell's window count high;
  Close Window counts it itself); (4) window tabs (File ▸ New ▸ Window Tab,
  P-022); (5) the borderless pop-up's fill as a style parameter, so the
  options step's pop-ups can be #2F2F31 (P-182; B5-STATES owns the control
  styles).
- **B5-MOTION:** a shared constant for the options step's 190 ms fade-in
  (now `TemplateChooserMetrics.optionsFadeDuration`) and Welcome's 100 ms
  fade-out before the Open panel (`WelcomeWindowController.openFadeDuration`).
- **B5-MENUS2:** none needed; the Linux shell's `newFile:`,
  `newWorkspaceWindow:`, `newWindowForTab:`, `chooseProjectTemplate:` and
  the two-window Close Window go through `ShellAppModel+NewItems.swift`,
  reached by one line each at the top of `menuActionState` and
  `performMenuAction` (`ShellAppModel+MenuActions.swift`).

## Hooks in shared files

- `ShellAppModel.swift`: `newFile` and `closeActiveWorkspaceWindow`
  properties; `.newProject` performs `showNewProjectPicker()`.
- `ShellAppModel+MenuActions.swift`: one line in each of `menuActionState`
  and `performMenuAction`.
- `WorkspaceShellModel.swift`: `reloadProjectTree()`.
- `YcodeIDEApp.swift`: the New File sheet; the workspace windows' order
  (`ShellWorkspaceWindows`) and the active window's closer.
- `ShellDriver.swift`: the walk's switch name and its one line.
- `ShellDriver+Windows4.swift`: the beta 4 walk opens Choose Template…
  directly (Welcome's New Project is a pull-down now).
- `NewItemSheets.swift` (`NewFileSheetController`): the chooser's top row,
  regular heading and grid focus, as New Project's.
