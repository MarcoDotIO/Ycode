# Ycode 1.0: the plan from beta 4 to 1.0.0

This is a proposal, for the owner and for the agents who will do the work. It turns the
2026-11-15 parity run into a release train. The list it closes is
[`specs/ide/parity-inventory.md`](../specs/ide/parity-inventory.md) (220 items, numbered
**P-001…**: H 62, M 123, L 35). Nothing here is started: the owner discusses
feature parity first. Dates are not promised; sizes are agent-days.

## At a glance

| Release | Theme | Items (H / M / L) | Item work | With specs, council and release |
|---|---|---|---|---|
| 1.0.0-beta.4 | Quick wins and broken workflows | 61 (25 / 33 / 3) | 53 | ≈ 63 |
| 1.0.0-beta.5 | Motion system, popovers and window layout | 43 (10 / 25 / 8) | 68 | ≈ 80 |
| 1.0.0-beta.6 | The editor in depth and its overlays | 25 (12 / 11 / 2) | 66.5 | ≈ 76 |
| 1.0.0-beta.7 | Project, schemes, build, debug and source control in depth | 35 (4 / 27 / 4) | 74 | ≈ 84 |
| 1.0.0-beta.8 | Non-source editors, Interface Builder and previews | 15 (4 / 8 / 3) | 54.5 | ≈ 66 |
| 1.0.0-beta.9 | Settings, Device Hub, Organizer, Library and documentation | 25 (7 / 15 / 3) | 67 | ≈ 77 |
| 1.0.0-rc | Polish, accessibility, performance and copy | 16 (0 / 4 / 12) | 15.5 | ≈ 30 |
| 1.0.0 | Release: no new items; the RC's council round scores ≥ 8 in every area | — | — | ≈ 5 |

Item work counts S as 0.5, M as 2, L as 5 and XL as 12 agent-days. The last column adds,
per beta, about 2–4 days of dirty-room observation and spec writing, a council round
(foreground capture, judges, spec rows: about 3), verification (full suites on macOS,
x86-64 and arm64 Linux: about 2) and the release itself (about 1). With five to seven clean
agents in parallel, as in beta 3, a beta is roughly two to three weeks of calendar time.

Every H item is scheduled. No item is deferred past 1.0.0 by this plan; the owner decisions
in §6 may move some (the XL items in particular).

## 1. Principles

1. **Parity rule.** Where the reference has the element, match it: layout, place, wording,
   behaviour, timing. Ycode-only elements (simulator hosts, the coding assistant's providers,
   Ycode's Settings additions) follow the HIG and the OS 26 Liquid Glass language. Owner
   exceptions stand (line-art language logos, the Ycode mark in the title area, the system
   overflow item until decided).
2. **Both IDEs land together.** A P-item is closed only when the macOS IDE and the Linux IDE
   both match, with stills of both. Where Linux needs an OpenViews capability first, that
   capability lands in the same beta's toolkit workstream or an earlier beta.
3. **Clean room.** Every clean brief says: read only `specs/`, public documentation and
   suitably licensed open source; do not open the reference tools, `research/` or Ghidra
   projects; do not run or watch the reference IDE or its simulator. Observations come first,
   from the dirty room, as spec rows with measured values.
4. **Each beta ends with a council round and a release.** The round is a foreground capture
   with the owner away (asked first), judged by three judges, the same steps as before plus
   the beta's new areas. Rows below 8 become spec rows for the next beta, not scope creep in
   this one.
5. **Scope discipline.** A beta takes its listed P-items and nothing else. New findings go
   into the inventory with a new P-id and a target release. A beta ships when its H items
   are closed on both IDEs and its suites are green; M and L items that miss move to the next
   beta by name.
6. **Shared hot files have one owner per beta.** `ShellCommands.swift`, `ShellMenus.swift`,
   `WorkspaceWindowController.swift`, `AppCommands.swift`, `MenuBarDelegate.swift` and the
   `ShellDriver*.swift` walk lists collect edits from many features. In each beta one
   workstream owns them; the others add their code in new extension files and send the owner
   the few lines that must go into the shared file. Walk-list conflicts are resolved by
   keeping every walk.

## 2. Why this order

- **Beta 4 first fixes what is broken.** About a third of the H items are plain bugs: a
  project cannot be created from the assistant, Find does nothing, typed debugger commands
  land in the source file, the capability library cannot be closed, the merge sheet cannot be
  cancelled, the selection band disappears, Build Settings widens the window. They are small,
  they block the council's own steps, and every later beta's capture depends on them.
- **Beta 5 builds the shared layers** that later features stand on: one motion layer
  (measured curves for panes, popovers, sheets, tooltips, lists) before any per-feature
  animation; one popover and overlay component (anchored glass panel, in-window capsule that
  keeps the workspace active) before the scheme and destination choosers, Quick Help,
  completion's detail pane, Jump to Line and Quick Actions; hover, press and focus states
  (#63/#64); and on Linux the OpenViews frame pipeline, without which no Linux transition can
  match (the inspector slide shows two jumps today).
- **Beta 6 is the editor**, the most-used surface: folding, multi-cursor, tabs, jump-bar
  menus, minimap, find, completion, Quick Help, rename. Its overlays use beta 5's popover
  component and motion layer.
- **Beta 7 deepens project and workflow features**: the project editor (on Linux it does not
  exist yet), the scheme editor, tests, the build log, the debugger and source control. These
  use beta 5's popovers (scheme chooser, data tips) and beta 6's editor (Code Review, change
  bars), and need OpenViews' `Table` (#54) on Linux.
- **Beta 8 is the non-source editors, Interface Builder and previews**: XL items (Core Data,
  macOS IB) that stand alone and can slip without blocking anything else.
- **Beta 9 is Settings, Device Hub, Organizer, the Library and documentation.** Several
  need owner decisions (§6); placing them last gives time for those decisions, and the Linux
  Device Hub depends on the remote-simulator work (#50).
- **The RC** is polish only: copy, glyphs, accessibility roles, measured latencies.

## 3. The betas

Items marked * are H. The full rows are in the inventory.

### 1.0.0-beta.4: quick wins and broken workflows

**Goals.** Every quick win (inventory §3) and every broken workflow fixed on both IDEs:
New Project, schemes, Find, the console, menus and key equivalents, the selection band, the
editors' bottom bars, second windows, the capability library, the merge sheet, Settings
drill-in. Start the dirty observations beta 5 needs.

**Closes** 61 items (H 25, M 33, L 3), about 53 agent-days of item work:

- Menus & commands: P-001, P-002, P-003*, P-004, P-006, P-007*, P-008*, P-009, P-011, P-012, P-013, P-015, P-016
- Window & toolbar chrome: P-022*, P-023, P-026
- Navigators: P-035*, P-036, P-038, P-047
- Editor core: P-054*, P-059, P-062, P-064, P-065, P-066, P-068*, P-070*, P-071
- Editor overlays: P-080*, P-083, P-084*
- Inspectors: P-089
- Project editor & build settings: P-096, P-098*, P-100*
- Schemes, destinations & tests: P-108*, P-109*, P-110
- Build, run & debug: P-121, P-123*
- Source control: P-131*, P-132
- Settings: P-138*, P-139, P-140, P-148
- Non-source editors: P-156*
- Interface Builder & previews: P-166*, P-167
- Welcome, New Project & templates: P-177*, P-178, P-179*, P-184
- Accessibility: P-202, P-203, P-204
- Linux-only gaps: P-212*, P-214*, P-215*, P-216*

**Workstreams** (clean, in parallel; disjoint file ownership):

| Workstream | P-items | Owns (macOS / Linux) |
|---|---|---|
| B4-MENUS | P-001, P-002, P-004, P-006, P-007, P-008, P-009, P-011, P-012, P-013, P-015, P-016 | `YcodeUI/App/AppCommands.swift`, `MenuBarDelegate.swift`, `Window/WorkspaceWindowController+MenuBar.swift`, `+MenuCleanUp.swift`, `+EditorMenu.swift`, `+DebugMenu.swift`, `+Product.swift` / `ycode-ide/ShellMenus.swift`, `YcodeIDEShell/ShellCommands.swift` (the beta's owner of both hot files) |
| B4-EDITOR | P-003, P-054, P-059, P-062, P-064, P-065, P-066, P-068, P-071, P-083, P-084, P-203 | `Editor/FindBar.swift`, `SourceEditorController+FindCommands.swift`, `+Commands.swift`, `GutterView.swift`, `EditorAreaController*.swift`, `EmptyEditorView.swift`, `Theme.swift`, `DefaultTheme.swift`, `Inspector/QuickHelpView.swift`, `Window/WorkspaceWindowController+Refactoring.swift` / `EditorBars.swift`, `EditorPanes.swift`, `SourceEditorView.swift` |
| B4-LANGUAGE | P-070, P-080, P-121 | `YcodeLanguage`, `YcodeBuildServer`, `Editor/CompletionPopup.swift` (trigger only), `InlineIssues.swift` / `YcodeIDEShell/WorkspaceShellModel+Language.swift`, `EditorCompletions.swift` |
| B4-WINDOWS | P-022, P-023, P-177, P-178, P-179, P-184, P-216 | `Window/NewProjectSheet.swift`, `NewFileTemplateGrid.swift`, `NewItemSheets.swift`, `WelcomeWindowController.swift`, `Model/UntitledWorkspace+Window.swift`, `YcodeApp` window creation / `NewProjectSheet.swift`, `WelcomeView.swift`, `YcodeIDEApp.swift`, `YcodeIDEShell/ShellAppModel.swift`, `NewProjectShellModel.swift` |
| B4-WORKFLOWS | P-096, P-098, P-100, P-108, P-109, P-110, P-123, P-131, P-132 | `Project/*`, `Schemes/*`, `Debug/DebugAreaController.swift`, `SourceControl/MergeSheet*.swift`, `SourceControlCoordinator+Branches.swift` / `DebugArea.swift`, `MergeSheetView.swift` (with B4-TOOLKIT's clamp fix) |
| B4-PANES | P-026, P-035, P-036, P-038, P-047, P-089, P-138, P-139, P-140, P-148, P-156, P-166, P-167, P-202, P-204 | `Navigator/*`, `Inspector/InspectorAreaController.swift`, `App/Settings*.swift`, `Editor/AssetCatalogEditorController.swift`, `InterfaceBuilderChrome.swift`, `PreviewCanvas*.swift`, `Window/QuickActionsPanel.swift`, `ActivityView.swift`, `WorkspaceWindowController+CodingAssistant.swift` / `NavigatorArea.swift`, `NavigatorRowIcons.swift`, `SettingsWindow.swift`, `SettingsCards.swift`, `PreviewCanvasView.swift` |
| B4-TOOLKIT | P-212, P-214, P-215 | `frameworks/swiftui/Sources/SwiftUI/Controls/Menu.swift`, `MenuBar`, `Presentation` (sheet clamp), the alert card, keyboard routing |

**Specs and observations first.** The inventory rows are the spec for every beta 4 item
(measured values in each row); the clean agents get the rows, not the dirty tables. In
parallel the dirty room starts: **#63** (hover, press, focus), **#57** (glass materials,
scroll edges), a **motion catalogue** (one spec of every measured curve in this run plus the
missing ones: list collapse, popover arrows, tab close), the **live warning's source**
(P-120), the **flick study** at 1x/100 Hz and 2x/120 Hz with one logged input (P-078), the
**Navigators segment** click, and Ycode's **save sheet** once P-177 lands.

**Linux and OpenViews.** Sub-menus on hover, menu widths, alert Return/Escape and the sheet
clamp (B4-TOOLKIT) are needed by New Project, Clone and the merge sheet on Linux. Second
windows (P-022) need OpenViews windows for the Linux half (L-225): if that is not ready, the
macOS half ships and the Linux half moves to beta 5 by name.

**Engineering hygiene** (not P-items, carried from beta 3): the MergeSheet UI-test flakes,
and tests that wait on `git` hanging forever if `git` dies.

**Verification.** Council round 11: rounds 9–10 steps, plus New Project to a created
project, Edit/Manage Schemes, ⌘F, ⇧⌘C + `p 1 + 2`, the capability library, merge Cancel,
Settings ▸ Editing ▸ Display and Back, Build Settings then a resize, a second window, the
asset catalog's + menu. Tests: offscreen UI tests for each bug (the `CYcodeTestOffscreen`
guard on), `ParityMenuTableTests` extended so the macOS and Linux menu tables are compared
item by item for every item this beta touches, Linux walks for New Project, alerts, menus and
the merge sheet.

**Size.** 53 agent-days of item work; ≈ 63 with observations, council and release.

### 1.0.0-beta.5: motion system, popovers and window layout

**Goals.** One motion layer and one popover/overlay component, used by panes, choosers,
palettes and sheets on both IDEs; hover, press and focus states; narrow-window layout and the
toolbar overflow; the navigator's depth (filter, context menus, drag); the OpenViews frame
pipeline so Linux can draw every frame of a transition.

**Closes** 43 items (H 10, M 25, L 8), about 68 agent-days of item work:

- Menus & commands: P-014
- Window & toolbar chrome: P-024, P-025, P-028, P-029, P-031, P-033
- Navigators: P-037*, P-039, P-040, P-041*, P-042*, P-043, P-051*, P-052*
- Editor core: P-078
- Editor overlays: P-086
- Schemes, destinations & tests: P-111*, P-112, P-113
- Build, run & debug: P-120*
- Source control: P-137
- Settings: P-155
- Welcome, New Project & templates: P-180, P-181, P-182, P-183, P-186, P-187*
- Motion system: P-190*, P-191, P-192, P-193, P-194, P-195, P-196, P-197, P-198, P-199, P-200*, P-201
- Performance: P-211
- Linux-only gaps: P-217

| Workstream | P-items | Owns (macOS / Linux) |
|---|---|---|
| B5-MOTION | P-024, P-078, P-137, P-190, P-191, P-192, P-193, P-194, P-196, P-197, P-201 | shared motion constants in `YcodeIDECore` (with `EditorMetrics`), `Window/WorkspaceWindowController+InspectorSlide.swift`, `Navigator/NavigatorAreaController+SelectorBackdrop.swift`, `Debug/DebugAreaController.swift`, `SourceControl/MergeOverlay.swift`, `Editor/EditorScrollView.swift` / `WorkspaceView.swift`, `InspectorSlide.swift`, `DebugArea.swift`, `MergeOverlay.swift`, `SourceEditorController+Flick.swift` |
| B5-TOOLBAR | P-025, P-028, P-029 | `Window/WorkspaceWindowController+ToolbarBand.swift`, `+ToolbarRight.swift`, `+ToolbarStates.swift`, `ActivityView.swift`, `BuildRingView.swift` / `ToolbarChrome.swift`, `BuildRing.swift` |
| B5-POPOVERS | P-014, P-031, P-086, P-111, P-112, P-113, P-180, P-195 | `Window/GlassPanel.swift`, `QuickActionsPanel.swift`, `SchemeCapsuleImages.swift`, `WorkspaceWindowController+Destinations.swift`, a new shared popover component / `DestinationMenuItems.swift`, `OpenQuicklyPanel.swift`, a new overlay view |
| B5-NAVIGATOR | P-037, P-039, P-040, P-041, P-042, P-043, P-051, P-052, P-199 | `Navigator/*` (except the selector backdrop), `YcodeIDECore` project file operations / `NavigatorArea.swift`, `YcodeIDEShell/OutlineRows.swift`, `NavigatorItems.swift`, `NavigatorRows.swift` |
| B5-NEWPROJECT | P-181, P-182, P-183, P-186, P-187 | `Window/NewProjectSheet.swift`, `NewFileTemplateGrid.swift`, `WelcomeWindowController.swift` / `NewProjectSheet.swift`, `WelcomeView.swift`, a new New File sheet |
| B5-STATES | P-198 (#64), #58 | OpenViews `PlainLook` and control styles; the macOS custom-drawn controls (capsules, outline rows, segments) |
| B5-OPENVIEWS | P-033, P-155, P-200, P-211, P-217 | `frameworks/swiftui` frame pipeline (incremental update instead of a whole-window rebuild), pop-up placement, file dialog, menu bar overlay / `SettingsWindow.swift` keys |
| B5-ISSUES | P-120 | `YcodeBuild` project validation, `Window/IssueCapsuleView.swift`, `Editor/JumpBarIssueStepper.swift` / the Linux issue capsule and stepper |

**Specs first.** From beta 4's dirty work: `specs/ui/control-states.md` (#63),
`specs/ui/glass-materials.md` (#57), the motion catalogue (curves already measured here:
navigator 240 ms ease-out/ease-in, debug area ≈ 200 ms, inspector 275/240 ms, selector disc
≈ 280 ms ease-out, list collapse 75 ms, sheet exits 250–315 ms, tooltip 290 ms hold + 310 ms
fade; to measure: popover arrows, narrow-window auto-hide thresholds, the overflow's item
priority), the live warning's text, the flick study's result.

**Linux and OpenViews.** B5-OPENVIEWS is the critical path for every Linux motion row:
until a slide draws every display frame, P-190–P-197 cannot close on Linux. If it slips, the
macOS halves ship and the Linux halves move to beta 6 by name.

**Verification.** Council round 12: navigator, inspector and debug-area slides, the scheme and
destination popovers (hover, keys, Escape), Jump to Line, Quick Actions, narrow windows at
817, 700 and 503 pt, navigator filter and drag, hover states. The motion probe's timing tests
(`R8_TIMING=1` style) for every curve, on macOS and Linux; Linux release-build frame counts.

**Size.** 68 agent-days of item work; ≈ 80 in all.

### 1.0.0-beta.6: the editor in depth and its overlays

**Goals.** Folding, multi-cursor, editor tabs and window tabs, jump-bar menus, Related Items,
minimap, find bar, completion, Quick Help, rename and Open Quickly match on both IDEs; Linux
gets the editor features it lacks and the menu commands that drive them.

**Closes** 25 items (H 12, M 11, L 2), about 66.5 agent-days of item work:

- Window & toolbar chrome: P-032, P-034
- Navigators: P-050*, P-053*
- Editor core: P-055, P-056, P-057, P-058*, P-060*, P-061*, P-063*, P-069, P-072, P-074*, P-075, P-076, P-077*
- Editor overlays: P-079, P-081*, P-082*, P-085, P-087
- Inspectors: P-095*
- Accessibility: P-206
- Linux-only gaps: P-213*

| Workstream | P-items | Owns (macOS / Linux) |
|---|---|---|
| B6-TEXT | P-055, P-056, P-057, P-058, P-060, P-072 | `Editor/SourceEditorController+Guides.swift`, `+BlockRuns.swift`, `+Layout.swift`, `GutterView.swift`, `InlineIssues.swift`, `SourceEditorDisplayExtras.swift`, `Theme.swift` / `SourceEditorView.swift`, `SourceEditorView+CellGlyphs.swift`, `SourceEditorController+Minimap.swift`, `YcodeEditorKit/EditorLineLayout.swift` |
| B6-EDITING | P-061, P-077 | `YcodeEditorKit/EditorBuffer.swift`, `EditorKeyBindings.swift`, `Editor/SourceEditorController+Typing.swift`, `+Places.swift` / `SourceEditorController.swift`, `YcodeIDEShell/EditorCompletions.swift` |
| B6-TABS | P-032, P-034, P-063, P-069, P-074, P-075, P-076 | `Editor/EditorChrome.swift`, `JumpBar+*.swift`, `EditorAreaController+Panes.swift`, `Window/WorkspaceWindowController+FileSwitch.swift`, `+Restore.swift` / `EditorArea.swift`, `JumpBarPath.swift`, `EditorPanes.swift`, a new `EditorTabs.swift`, `WindowRestoreViews.swift` |
| B6-OVERLAYS | P-079, P-081, P-082, P-085, P-087, P-206 | `Editor/CompletionPopup.swift`, `FindBar.swift`, `Inspector/QuickHelpView.swift`, `Navigator/OpenQuicklyController.swift`, `Window/WorkspaceWindowController+Refactoring.swift` / `EditorBars.swift`, `LanguageViews.swift`, `OpenQuicklyPanel.swift` |
| B6-LINUX | P-050, P-053, P-095, P-213 | `ShellMenus.swift`, `ShellCommands.swift` (this beta's owner), `FileInspectorView.swift`, `SymbolNavigatorView.swift`, the Find section of `NavigatorArea.swift` |

**Specs first.** Already measured: fold animation (squash 10–90 % +229 → +488 ms, ease-in;
unfold ease-out ≈ 300 ms), tab close (250 ms ease-out), completion metrics (247 pt, 22-pt rows,
tiles, detail pane), Quick Help popover anchoring and one-frame appearance, find bar slide
(≈ 184 ms in, 200 ms out), minimap click scroll (≈ 210 ms). To observe: the Counterparts mode
menu, fold-ribbon hover, editor-tab hover and pin, rename mode's layout in detail, the
completion detail pane's type sizes, the jump-bar menus' type-to-filter.

**Linux and OpenViews.** Multi-cursor needs per-selection carets in the OpenViews text path;
editor tabs need draggable split dividers (L-147) and a tab bar control.

**Verification.** Council round 13: an editor session (fold, multi-cursor, tabs, jump-bar
menus, Related Items, ⌘F, completion, ⌥-click Quick Help, rename, Open Quickly with SDK
results). EditorKit unit tests on all three platforms; Linux walks `_EDITOR*`, `_LSP`.

**Size.** 66.5 agent-days of item work; ≈ 76 in all.

### 1.0.0-beta.7: project, schemes, build, debug and source control in depth

**Goals.** The project editor's tabs match and exist on Linux; the scheme editor's Test
action and Manage Schemes are complete; tests, the build log, the debugger (data tips,
breakpoint menus and popover) and source control (commit mode, history diffs, change-bar
menu, Code Review deletions) match.

**Closes** 35 items (H 4, M 27, L 4), about 74 agent-days of item work:

- Navigators: P-046, P-049
- Editor core: P-067*, P-073
- Inspectors: P-090, P-091, P-093
- Project editor & build settings: P-097, P-099, P-101, P-102, P-103, P-104, P-105, P-106, P-107*
- Schemes, destinations & tests: P-114, P-115, P-116, P-117, P-118, P-119
- Build, run & debug: P-122, P-124, P-125, P-126, P-127, P-128, P-129, P-130*
- Source control: P-133*, P-134, P-135, P-136
- Performance: P-209

| Workstream | P-items | Owns (macOS / Linux) |
|---|---|---|
| B7-PROJECT | P-090, P-097, P-099, P-101, P-102, P-103, P-104, P-105, P-106 | `Project/*` |
| B7-PROJECT-LINUX | P-107 | new `ycode-ide/ProjectEditor*.swift`, `YcodeIDEShell/ProjectEditorShellModel.swift` (the model is shared in `YcodeIDECore/Project`) |
| B7-SCHEMES | P-114, P-115, P-116, P-117, P-118, P-119 | `Schemes/*`, `Window/WorkspaceWindowController+TestRepetition.swift`, a new test-report view file / new `SchemeEditorSheet.swift`, `TestNavigator.swift`, `YcodeIDEShell/TestShellModel.swift` |
| B7-DEBUG | P-046, P-122, P-124, P-125, P-126, P-127, P-128, P-129, P-130, P-209 | `Debug/*`, `Window/ReportViews.swift`, `WorkspaceWindowController+Debugger.swift`, `YcodeBuild` start-up path / `DebugViews.swift`, `DebugEditors.swift`, `DebugChrome.swift`, a new `BuildLogView.swift`, `YcodeIDEShell/ShellDebugModel*.swift` |
| B7-SCM | P-049, P-067, P-073, P-091, P-093, P-133, P-134, P-135, P-136 | `SourceControl/*`, `Editor/CodeReviewViews.swift`, `SourceEditorController+Authors.swift`, `Window/WorkspaceWindowController+CodeReview.swift` / `SourceControlNavigator.swift`, `SourceControlEditor.swift`, a new `CodeReviewView.swift` |
| Platform: SIGNING | #43, #90 | `YcodeSigning`, the Accounts pane's signing parts (with B7-PROJECT for the Signing tab's text) |

**Specs first.** Already in this run: Build Phases, Build Rules (system rules listed per
target type), test-target General, project Info, the build log's "Prepare build" titles, data
tip timing, the breakpoint popover's fields and placement, commit mode. To observe: the
scheme editor's Test tabs at full detail, Build Rules' rule list per platform, commit mode's
staging views and Amend, Code Review's deletion layout.

**Linux and OpenViews.** OpenViews `Table` with sortable, resizable columns (#54) before
B7-PROJECT-LINUX's Build Settings and Build Phases.

**Verification.** Council round 14: project editor tabs, scheme editor (Test tabs, Escape),
⌘U to the report, a breakpoint with data tip and popover, Integrate ▸ Commit…, a commit's
diff, a change-bar menu, Code Review. Project round-trip tests (pbxproj written and reread),
Linux walks `_TESTS`, `_DEBUG*`, `_SCM`, a new project-editor walk.

**Size.** 74 agent-days of item work; ≈ 84 in all. P-107 (XL) is the largest single
item; if it slips it slips alone.

### 1.0.0-beta.8: non-source editors, Interface Builder and previews

**Goals.** Asset catalog, property list, String Catalog, image viewer and file-type glyphs
match; a test plan editor, a Core Data model editor and the rendered Markdown editor exist on
both IDEs; Interface Builder handles macOS documents with the macOS object library; the
preview canvas has its bar, menu and layout.

**Closes** 15 items (H 4, M 8, L 3), about 54.5 agent-days of item work:

- Navigators: P-048
- Inspectors: P-092
- Non-source editors: P-157, P-158, P-159, P-160*, P-161*, P-162, P-163, P-164, P-165
- Interface Builder & previews: P-168, P-169*, P-170*, P-171

| Workstream | P-items | Owns (macOS / Linux) |
|---|---|---|
| B8-STRUCTURED | P-048, P-092, P-157, P-158, P-159, P-163, P-164, P-165 | `Editor/AssetCatalogEditorController.swift`, `PlistEditorController.swift`, `StringCatalogEditorController.swift`, `ImageViewerController.swift`, `Navigator/NavigatorRowIcons.swift` / `AssetCatalogEditorView.swift`, `PlistEditorView.swift`, `StringCatalogEditorView.swift`, `StructuredEditorChrome.swift`, `YcodeIDEShell/StructuredEditors.swift` |
| B8-NEWEDITORS | P-160, P-161 | new test plan and data model editors on both IDEs; `YcodeProject` model formats (with a format spec for `.xcdatamodel` if missing) |
| B8-MARKDOWN | P-162 | a new rendered Markdown editor on both IDEs; `YcodeEditorKit` Markdown styles |
| B8-IB | P-169, P-170, P-171 | `Editor/InterfaceBuilder*.swift`, `IBIconDrawing.swift`, `LibraryController.swift` (IB part) / `InterfaceBuilder*.swift`, `YcodeIDEShell/InterfaceBuilderShellModel.swift` |
| B8-PREVIEWS | P-168 | `Editor/PreviewCanvas*.swift`, `YcodePreviews` / `PreviewCanvasView.swift`, `YcodeIDEShell/PreviewCanvas*.swift` |

**Specs first.** To observe: the test plan editor's layout and Configurations tab; the data
model editor's layout and its Editor menu; the rendered Markdown editor (format bar, heading
styles); the macOS object library list with each object's label and preview size (facts);
macOS storyboard scene drawing (window controller chrome, segues); the canvas bar and Canvas
menu.

**Verification.** Council round 15: each file type opened from the navigator, a colour set,
an Add Item in a plist, a String Catalog row, a test plan, a data model, NOTES.md rendered, a
macOS storyboard with a Push Button dragged in, the preview canvas's bar. Format round-trip
tests for every editor; Linux walks `_EDITORS`, `_IB`, `_PREVIEWS`.

**Size.** 54.5 agent-days of item work; ≈ 66 in all. P-161 and P-170 are XL and can
move after 1.0.0 if the owner chooses (§6, decision 9) without blocking anything else.

### 1.0.0-beta.9: Settings, Device Hub, Organizer, Library and documentation

**Goals.** Every Settings pane matches (or follows the owner's decisions for rows tied to
Apple services); the Device Hub's menus, actions and controls match and Linux gets its Device
Hub; the Organizer, Clone window, About, Library and documentation follow the decisions in §6.

**Closes** 25 items (H 7, M 15, L 3), about 67 agent-days of item work:

- Menus & commands: P-018, P-021
- Window & toolbar chrome: P-027
- Editor overlays: P-088*
- Settings: P-141, P-142, P-143, P-144, P-145*, P-146*, P-147*, P-149, P-150, P-151, P-152, P-153, P-154
- Device Hub & Organizer: P-172*, P-173, P-174, P-175, P-176
- Welcome, New Project & templates: P-185*
- Documentation, Help & About: P-188*, P-189

| Workstream | P-items | Owns (macOS / Linux) |
|---|---|---|
| B9-SETTINGS-A | P-141, P-142, P-143, P-144, P-149, P-150 | `App/SettingsPanes.swift`, `SettingsComponentsPane.swift`, `TextEditingSettingsPane+Prediction.swift`, `SettingsNavigationRow.swift` / `SettingsPanes.swift`, `SettingsPanesEditing.swift`, `SettingsPaneComponents.swift` |
| B9-SETTINGS-B | P-145, P-146, P-147, P-151, P-152, P-153, P-154 | `App/SettingsAppearancePane.swift`, `CodingAssistantSettingsPane.swift`, `SettingsChrome.swift`, `SettingsWindow.swift`, `SettingsR5Views.swift`, `SettingsR7Views.swift`, the Behaviors, Notifications and Shortcuts panes / `SettingsPanesSystem.swift`, `SettingsPaneShortcuts.swift`, `SettingsPaneAppearance.swift`, `SettingsPaneCodingAssistant.swift`, `SettingsWindow.swift`, `SettingsR*Controls.swift` |
| B9-DEVICES | P-172, P-173, P-174, P-175, #50, #85 | `Window/Devices*.swift`, `DeviceHub*.swift`, `DeviceInspectorCard.swift`, `HubSectionHeaderView.swift`, `YcodeDeviceUI` / new `DeviceHub*.swift` reusing `YcodeRemoteViewer` |
| B9-WINDOWS | P-018, P-021, P-176, P-185, P-188, P-189 | `Window/OrganizerController.swift`, `App/AboutWindow.swift`, the Clone window, the documentation window / `OrganizerWindow.swift`, `AboutSheet.swift`, `YcodeIDEShell/CloneShellModel.swift` |
| B9-LIBRARY | P-027, P-088 | `Editor/LibraryController.swift` (code library), `Assistant/*` / `AssistantPane.swift`, a shared Library panel (with `InterfaceBuilderLibrary.swift`) |

**Specs first.** Most values are in the inventory. To observe: each Settings drill-in page in
full (the run reached Display, Build, Running, Git settings), Device Hub at normal load (zoom,
rotation), the Organizer's report filter bars. Ycode-authored content: the Library's snippet
set (decision 8).

**Linux and OpenViews.** The Linux Device Hub embeds the device view (#50) and needs the
display stream (#85 for Wi-Fi hosts).

**Verification.** Council round 16: every Settings pane in light and dark, drill-ins and
Back, the Device Hub with a Ycode simulator (menus, More Actions, zoom, rotate), the
Organizer, Clone, About, the Library, ⇧⌘0. Settings persistence tests; Linux walks
`_SETTINGS*`, `_ORGANIZER`, a new device-hub walk on a host.

**Size.** 67 agent-days of item work; ≈ 77 in all. P-172 and P-188 are XL.

### 1.0.0-rc: polish, accessibility, performance and copy

**Closes** 16 items (H 0, M 4, L 12), about 15.5 agent-days of item work:

- Menus & commands: P-005, P-010, P-017, P-019, P-020
- Window & toolbar chrome: P-030
- Navigators: P-044, P-045
- Inspectors: P-094
- Accessibility: P-205, P-207, P-208
- Performance: P-210
- Linux-only gaps: P-218, P-219, P-220

Workstreams: **RC-COPY** (menu titles, Format/Convert sub-menus, Window menu, Syntax
Coloring per decision 12, tooltips, Ycode-only items per decision 4), **RC-GLYPHS** (toolbar,
selector and inspector glyphs; undo targets), **RC-A11Y** (roles, menu AX recheck, Tab chain
with and without Full Keyboard Access), **RC-PERF** (menu and command latency, the packaging
fault). Then a council round over every area of rounds 11–16; any area below 8 gets a fix
before 1.0.0, not a new feature.

**1.0.0** ships when the RC round scores 8 or more in every area on both IDEs, the full
suites are green on macOS, x86-64 and arm64 Linux, and the owner has opened the release
build.

## 4. The existing 1.0.0-beta.4 milestone

| Issue | Proposal | Where |
|---|---|---|
| #63 Observe hover, press and focus states | keep in beta 4 (dirty observation) | feeds P-198 |
| #64 Implement hover, press and focus states | move to beta 5; merge with P-198 | B5-STATES |
| #57 Observe glass materials and scroll edges | keep in beta 4 (dirty observation) | feeds #58, P-154 |
| #58 Implement glass materials and scroll edges | move to beta 5 | B5-STATES (and P-154's scroll-edge blur in beta 9) |
| #54 OpenViews milestones | keep as the umbrella; split across beta 4 (menus, alerts, sheets: P-212, P-214, P-215), beta 5 (frame pipeline, pop-ups, materials: P-200, P-217) and beta 7 (`Table`) | B4-TOOLKIT, B5-OPENVIEWS, B7 |
| #43 Signing, distribution, physical devices | move to beta 7, beside the Signing tab rows (P-096, P-097); physical devices may follow in beta 9 | platform track |
| #90 Borrow xtool's signing and device install | merge into #43's beta 7 work | platform track |
| #50 Remote simulator: debugging and embedded device view | move to beta 9; the embedded view is the Linux Device Hub (P-172) | B9-DEVICES |
| #85 Display stream over Wi-Fi | move to beta 9 with #50 (may slip to after 1.0.0: not a parity item) | B9-DEVICES |
| #87 macOS apps on Linux, stage B | platform track, not gated by parity: beta 5–6 | parallel, own worktrees |
| #88 stage C, the process model | platform track: beta 7–8 | parallel |
| #89 stage D, windows and Ycode's AppKit subset | platform track: after 1.0.0 unless B and C finish early | parallel |

The platform track (signing, remote simulator, macOS apps on Linux, the simulator's boot
target) runs beside the parity train in its own worktrees and on the simulator hosts. It does
not block a parity beta, and a parity beta does not wait for it.

**Beta 3's known limitations and deferred council items:**

| Item | Where |
|---|---|
| Linux slide and selection frame rate (OpenViews rebuilds the window every frame) | P-200, beta 5 |
| No live warning on an unbuilt project; split jump bars collapse later | P-120, beta 5 |
| Scroll flicks differ between displays; linear drag sampling (main 03) | P-078, beta 5 (study in beta 4) |
| Selecting a file ≈ 0.4 s; Bands latency (row 225) | P-199, beta 5 |
| Live resize latency (main 17) | P-201, beta 5 |
| Narrow subtitle truncation (N02) | P-029, beta 5 |
| macOS overflow gap (row 218) | P-025 and decision 11 |
| Linux Welcome placement | P-023, beta 4 |
| Rendered Markdown editor | P-162, beta 8 |
| Settings scroll-edge blur, back chevron, late scrolling, Foreground slider via AX (X13) | P-138 (beta 4), P-154 (beta 9) |
| The conflict token's menu ≈ 67 ms later (conflict 04) | P-137, beta 5 |
| Reopen scroll position (row 202), activity subtitle on reopen (row 201), merge alert size, assistant pressed state, dark build ring, "Available" header | open observations (inventory §8) |
| MergeSheet test flakes; tests that hang when `git` dies | beta 4 engineering hygiene |

## 5. Risks and open questions

- **The flicks depend on the display.** The reference's overscroll for the same input is
  ≈ 38 pt at 2x/120 Hz and 182–190 pt at 1x/100 Hz. Retuning to one display breaks the other.
  The beta 4 study must find what the response depends on before P-078 is retuned.
- **Device Hub on macOS.** Ycode does not run the simctl simulators it lists; parity of the
  stage and its Settings inspector (P-172, XL) depends on decision 2.
- **Three XL items stand alone:** macOS Interface Builder (P-170), the Core Data editor
  (P-161) and the Developer Documentation window (P-188), plus the Linux project editor
  (P-107) and the Linux Device Hub (part of P-172). Each is placed so that slipping it does
  not block other work.
- **The OpenViews frame pipeline** (P-200) gates every Linux motion row; it is the highest
  single risk to "both IDEs land together".
- **The language service** (P-070) may need the build-server work of `docs/PARITY.md` §6 #2
  to resolve cross-file types in `.xcodeproj` workspaces; it is sized L and starts in beta 4
  because false errors appear in every multi-file project.
- **Captures need the owner away** from the Mac, at low load; Device Hub timings in this run
  were not usable (load up to 506). Each council round needs a window of about an hour.
- **Hot files** (`ShellCommands.swift`, `ShellDriver*.swift`, `WorkspaceWindowController.swift`)
  caused merge conflicts in every beta 3 wave; the one-owner rule (principle 6) is the
  mitigation.
- **Agents may be stopped** by usage limits: briefs say commit often and clean up first on
  resume.
- **The reference moves.** Version 2 targets Xcode 27.2 (`docs/FUTURE.md`); 1.0.0 stays on
  27.1.
- **Open question:** whether six betas before the RC is acceptable, or whether betas 8 and 9
  should be merged with the XL items moved after 1.0.0 (the last row of §6).

## 6. Decisions for the owner

The inventory (§4) states each with its options; the plan needs them by the beta shown.

| # | Decision | Needed by |
|---|---|---|
| 1 | Coding assistant pane and Settings: the reference's structure or Ycode's own | beta 9 (P-027, P-152) |
| 2 | Device Hub for simulators Ycode does not run on macOS; its own menu bar | beta 9 (P-172, P-173) |
| 3 | About window | beta 9 (P-189) |
| 4 | Ycode-only and Linux-only items: keep, gather or port | RC (P-020, P-165, P-219) |
| 5 | Cloud entries everywhere — **decided 2026-11-16: remove them** (no Cloud submenu, no Reports Local/Cloud control, no toolbar Cloud button) | beta 4 (menus) |
| 6 | The reference's own tools and Help items | beta 9 (P-018, P-021) |
| 7 | Settings rows tied to Apple services | beta 9 (P-141, P-142, P-146) |
| 8 | Library content | beta 9 (P-088) |
| 9 | macOS Interface Builder and the Core Data editor in 1.0.0 or after | beta 7 (to plan beta 8) |
| 10 | Developer Documentation | beta 8 (to plan beta 9) |
| 11 | The macOS toolbar overflow gap | beta 5 (P-025) |
| 12 | Syntax Coloring languages | beta 8 (to plan the RC) |
| 13 | ⌘3 on Linux | beta 6 (P-050) |
| 14 | The capability list | beta 7 (P-099) |
| 15 | Built-in theme editing and Notifications | beta 9 (P-146, P-151) |
| — | The train itself — **decided 2026-11-16: six betas (4–9) then the RC, every item in 1.0.0**; an XL item that runs late slips by name | before beta 4 starts |
