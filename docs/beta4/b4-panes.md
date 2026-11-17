# B4-PANES (1.0.0-beta.4)

Clean-room workstream for the navigators, the inspector, Settings, the editors' bottom bars, the previews canvas, the command palette and the activity view. Spec: `specs/ide/parity-inventory.md`. Tests: `YcodeUITests/Beta4PanesTests` and `Beta4PanesShotTests` (macOS), `YcodeIDEShellTests/Beta4PanesShellTests` (Linux model), the `YCODE_IDE_PANES4=<prefix>` walk (Linux IDE).

| Item | What changed | macOS | Linux |
|---|---|---|---|
| P-026 | Wrapping and single-line labels in the Coding Assistant transcript (hint, status, message lines) no longer resist compression, so they cannot widen the left area. The navigator's dark fill stays under the pane. | fixed: 289.5 pt kept (a long attachment line took it to 973 pt before) | not checked by the inventory; the Linux pane is a fixed-width column |
| P-035 | A project-navigator reload (the source-control status read that arrives after a file opens) keeps the selected rows, their expansion and the scroll position. | fixed | the band in other navigators (L-118) not changed |
| P-036 | ⌘1–⌘9 (a menu item) on the navigator already shown hides the area; the issue capsule still only shows. | fixed | fixed (`show(_:)` toggles; `showNavigator(_:)` for the capsule) |
| P-038 | The filter field's editor uses the text rectangle after the options glyph. | fixed: editor from x 28, glyph ends at 27 | as before (OpenViews field) |
| P-047 | `NavigatorFlatIconView` fills template symbols with their tint (it drew them black). | fixed: grey #B6B7BC in dark | already grey |
| P-089 | A single folder or group row selected shows its File inspector (no Type, Tags or Localization). | fixed | fixed (`inspectedFolder`) |
| P-138 | Drill-in rows are accessibility buttons (keyboard focus, Space/Return, press tint); the push records a back/forward step; the title shows the page ("Display", "Build"); the inline "‹ Editing" links are gone. | fixed | fixed (steps in `ShellSettingsModel`, `SettingsDrillPressStyle`) |
| P-139 | The window resizes in height from 710 × 452, the green button zooms (no full screen). | fixed | needs OpenViews: the Settings scene is not resizable |
| P-140 | Components' values are read when the Settings window opens and kept for the process. | fixed | fixed |
| P-148, P-202 | The Shortcuts table and the command palette reuse their cells. | fixed (walks of 420 / 822 elements in < 1 ms) | n/a |
| P-156 | The asset list's bar, the IB canvas bar and outline and the preview canvas bar end at the editor area's safe area, above the status bar. | fixed | already drawn |
| P-166 | The preview's colour scheme follows the canvas's appearance unless one is chosen; an 18-pt building spinner; a Mac preview sits in a window frame titled "Ycode Previews". | fixed | header and banner differences (L-206, L-246) left |
| P-167 | Not reproduced; nothing in the previews code takes key status (the Mac host sets `.prohibited`). | open | not checked |
| P-204 | The title area is an accessibility group with a progress indicator (while busy), the title and the status line. Stop's accessibility state follows the segment's enabled state. | fixed (title area) | not checked |
| Decision 5 | The Report navigator's Local / Cloud control is removed. | fixed | had none |
