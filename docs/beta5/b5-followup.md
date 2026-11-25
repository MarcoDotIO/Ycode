# B5-FOLLOWUP (1.0.0-beta.5)

Clean-room follow-up after every other beta 5 workstream: the navigator's
menu hooks on Linux, P-199 (file selection), P-024 (narrow windows), a
flaky test, the Linux Run button, and the P-120 warning in the test
fixtures and new projects. Written from `specs/ide/parity-inventory.md`
(P-024, P-025, P-120, P-199), `specs/ide/window-layout.md`,
`specs/ide/issues.md`, `specs/ide/templates.md`, `specs/ui/control-states.md`
and Ycode's own code.

## 1. Navigator commands in the Linux menu bar

`ShellMenuModel.isEnabled` asks `validateProjectNavigatorAction` before the
editor's actions, `perform` tries `performProjectNavigatorAction` first, and
`fillMenuBarContext` adds `fillNavigatorMenuContext` (New ▸ Group hidden in
a folder, Paste ▸ Move Item Here after a Cut). The macOS window's dead
`projectRowMenuItems()` and `projectOps.rowMenu` are gone (the rows' menu
is `NavigatorAreaController+RowMenu.swift`). Test:
`YcodeIDEShellTests/NavigatorMenuBarShellTests` (New ▸ Group disabled, then
enabled and run from the menu bar, written to disk with its undo; hidden in
a synchronized folder; Move Item Here enabled after a Cut and moving the
file).

## 2. P-199: selecting a file

- **macOS, the parse.** `open(_:)` calls `resetSyntax(deferringParse: true)`:
  the lexer's colours cover every line at once, the parser pass follows on
  a run-loop timer (`openRefineDelay`, 16 ms, so the display pass comes
  first). The parser timer is a common-modes `Timer` now (it fires while the
  mouse is tracked and in nested run loops). The first parse settles the
  text's height again (`settleAfterFirstFrame`): the parser's styles moved
  a 200-line file's end by 6.5 pt.
  Measured offscreen (`B5FollowupUITests.openingDrawsBeforeTheParserPass`,
  400-line Swift file, open + layout + display): **152–160 ms**, was ≈ 460
  (B5-NAVIGATOR); the synchronous pass alone is 331–565 ms on this loaded
  Mac.
- **The ease.** `Motion.fileSelectionEase` = +93 → +188 ms (95 ms; the
  reference's start is +89 to +97), ease-in-out (the shape is not
  measured). macOS: selecting another file in the focused pane cross-fades
  the text area (`CATransition` fade, `WorkspaceWindowController+
  FileSelectionEase.swift`); the old file stays until the curve's start;
  when the open's work ends later, the fade starts with the first frame.
  No fade with Reduce Motion, for the same file, or from an empty editor.
- **Linux.** Not eased: a cross-fade needs the old and new editors drawn
  together (two `Canvas` editors, about 18 ms a frame each on the x86) or a
  re-identified editor view (it would lose its focus state), and the Linux
  editor's first frame comes after the reference's whole ease. Linux
  already parses after the first frame (`EditorBuffer(deferParse: true)`).
  Timing: the `YCODE_IDE_FOLLOWUP5` walk (`followup5 select`).

## 3. P-024: narrow windows

- The navigator compresses to ≈ 135 pt again (848d6fe2: no header row,
  not even the hidden Test header's pop-up, holds it). A live drag now
  narrows it from 850 pt (817: 257, 790: 230, 700: 140) and hides it below
  ≈ 698 (was ≈ 828); the inspector then gets back what the drag took on the
  way (`restoreInspectorWidth`), and shrinks to 201.5–203 at the 503-pt
  minimum; the editor never goes below 300; a hidden navigator stays hidden.
- The toolbar's leading items track the navigator's section: Navigators
  goes into "»" below ≈ 822 pt (AppKit's section needs ≈ 262 pt for the two
  capsules with its padding; the reference keeps them at ≈ 817) and comes
  back when the window widens.
- `applyDefaultLayout` refits the toolbar: the first layout's narrow
  navigator had left Navigators in "»" at 1400 pt
  (`ToolbarIssuesR39R41Tests.schemeCapsuleGlyphsOnly`).
- Tests changed where the spec says so: `B5MotionUITests.
  narrowWindowsKeepTheEditor` (the navigator shrinks at 790 and 700, hides
  at 690, `window-layout.md` §4 rule 4); `Beta5ToolbarTests` (the ranks and
  the shared order leave out Navigators and Run | Stop once the navigator is
  narrower than 290, as `ToolbarOverflow`'s note and §4 say; the 817 check
  is at 825 for Navigators). New: `B5FollowupUITests.
  liveDragShrinksTheNavigatorThenHidesIt`.
- **Gaps (AppKit's sidebar section).** (a) It never empties: below ≈ 740 pt
  it keeps Run | Stop, where the reference moves it into "»" at ≈ 725
  (making both leave with a lower priority only swapped which one stays).
  (b) With the navigator hidden it hides the section's items on macOS 27
  (the system sidebar split item), so at 503 Navigators and Run | Stop do
  not come back as the reference's do, and with ⌘0 at any width they are
  in "»". The plain split item Ycode uses on macOS 26 (`FlushSidebar`)
  keeps them, but it never moves them into "»" either. Candidate below.
- Linux already follows `NarrowWindowLayout` (B5-MOTION). The walk's
  narrowing drag (25-pt steps): the editor keeps 300 (its text area 226
  plus the gutter), the navigator hides between 700 and 675, the inspector
  is 254 wide until the window reaches the editor's floor again (550), then
  243, 218, and 196 at 503 (under the 201.5 the shared model asks for);
  Run | Stop stays in the Linux toolbar at every width (the reference's
  leaves at ≈ 725).
- Linux file selection (debug build, the walk's `followup5 select`): the
  first frame 310–340 ms after the model's selection for a 4-line file,
  427–492 ms for 400 lines; the selection call itself 2–10 ms. The time is
  the frame's own work (B5-OPENVIEWS' pipeline), not the parse.

## 4. The flaky test

`EditorServicesPreparationTests.subtitleStaysUntilTheRestoredEditorsHave
TheirFirstAnswer` rested on a 200 ms sleep against a 400 ms answer. The
test's server now holds its answer until the test releases it: the test
waits for the document to be opened, checks the subtitle is still up
300 ms later and that no diagnostics came, releases, and checks the
subtitle ends with the answer. Same checks, no clock race.

## 5. The Linux Run button

Run takes `ToolbarGlassStyle` (hover bezel, held fill, the 1–1.5-pt grow)
like the other toolbar glass controls: OpenViews' `.menuStyle(.button)`
now draws a menu's button with the ambient button style, as SwiftUI's
`ButtonMenuStyle` does (`Menu.swift`; test `OpenViewsTests/B5/
ControlStateTests.buttonStyledMenuTakesTheStyleAndKeepsItsPrimaryAction`).
The Run | Stop divider hides while Run is hovered. Shots: the walk's
`followup5-run-rest`, `-run-hover`, `-run-held`.

## 6. P-120 in fixtures and new projects

The check is gated by the project's `LastUpgradeCheck` (`issues.md` §1
item 5, §8 item 8): only a project whose `LastUpgradeCheck` is missing or
lower than Ycode's version (`RecommendedSettings.ideVersionDigits`, 2710, the
value `ProjectRecipe` writes) is checked, and then only the §5 rows that
apply are offered (`changes(in:gated:)`, `isCheckDue`). Perform Changes
writes the running version into `LastUpgradeCheck` with the checked rows
(`markUpgradeChecked`); Cancel, or nothing checked, writes nothing.

- Templates: unchanged from the reference again (the `DEAD_CODE_STRIPPING`
  addition of `d721bdac` is reverted, `templates.md` restored). The untitled
  App, the iOS App generator and the older macOS App and Command Line Tool
  now record `LastSwiftUpdateCheck` / `LastUpgradeCheck` like the
  templates. `TemplateRecommendedSettingsTests`: every template and
  generator project carries 2710 and shows no warning; the templates add no
  `DEAD_CODE_STRIPPING`; the two version constants agree.
- `RecommendedSettingsTests.lastUpgradeCheckGatesTheCheck`: none or 2700
  with missing rows warns; 2710 or 2800 does not. The round-trip tests now
  allow exactly one more added line, `LastUpgradeCheck = 2710;`. After a
  partial Perform Changes the warning goes (the macOS UI and Linux shell
  Perform tests say so).
- The seven tests that check other features open fixtures stamped with the
  current `LastUpgradeCheck` (`RecommendedSettingsFixture`); their settings
  are untouched.

## Tests and shots

- Mac, focused (fresh build): 257 tests in the B5 suites, the seven P-120
  suites, the template, editor and council suites: all pass.
- x86, full suite: 3154 tests, one failure under load
  (`NavigatorFileOperationsShellTests.filterSettlesEmphasizesAndRemembers`,
  B5-NAVIGATOR's timing test), which passes alone 3 of 3. It failed again
  in every whole-shell run, so it now waits for the settle (up to 10 s)
  after the pause instead of sleeping the pause plus 100 ms; the "not
  before the pause" check stays. The shell suite then passed twice (284).
- Mac shots (offscreen, the window with its toolbar):
  `.build-ide/b5-shots/followup-narrow-817.png`, `-700`, `-503`.
- Linux shots (x86): `~/Ycode-B5-FOLLOWUP/shots/fu5-followup5-run-rest.png`,
  `-run-hover`, `-run-held`, `-narrow-817`, `-narrow-700`, `-narrow-503`.

## Walk

`YCODE_IDE_FOLLOWUP5=<prefix>` (`ShellDriver+Followup5.swift`): Run's
states, file selection timing, a narrowing drag from 1400 to 503 pt.
