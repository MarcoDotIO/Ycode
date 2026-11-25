# B5-ISSUES: the live project warning (P-120)

Spec: `specs/ide/issues.md` (§1–§6 from the 2026-11-20 capture; §8 Ycode's
choices for the open items). Clean room: built from `specs/` and Ycode's own
code only.

## What was there

The toolbar issue capsule, the Issue navigator's project row and the jump
bar's ‹ ⚠ › stepper already showed whenever the workspace had warnings, on
both IDEs. The gap was the warning itself: Ycode had no project validation,
so an unbuilt project showed nothing (and the Linux IDE ran no project checks
at all, so the signing warning was macOS-only too).

## What B5-ISSUES added

- **Detection** (`YcodeProject/RecommendedSettings.swift`): the §5 rows, from
  the project file and its build settings (and, for the catalog rows, the
  catalogs in file references and synchronized folders). `ProjectChecks`
  reports one file-less warning, "Update to recommended settings", before the
  signing warnings, for each project that needs it. Packages have no check.
- **Perform Changes** (`RecommendedSettings.apply`,
  `WorkspaceSession.performRecommendedSettings`): the checked rows' keys, in
  the configurations that lack them, through the pbxproj writer; the check
  runs again at once. Cancel writes nothing.
- **The checklist's state and measures** (`YcodeIDECore`
  `RecommendedSettingsChecklist`): groups, rows, the group checkbox's on /
  off / mixed, 581 × 364, the 522-wide list, row heights 18 / 30 / 44,
  Cancel 84 × 23 and Perform Changes 130 × 23 (default), 12 apart, 20 from
  the right, 17 from the bottom. Shared by both IDEs.
- **macOS** (`YcodeUI/Window/RecommendedSettingsSheet.swift`): the Issue
  navigator's warning row opens the project editor and the sheet over it;
  the stepper (no issue in a file) opens the project editor alone.
- **Linux** (`YcodeIDEShell/ShellRecommendedSettings.swift`,
  `ycode-ide/RecommendedSettingsSheet.swift`): the project checks run when a
  workspace opens; the warning's row opens the sheet; the stepper selects the
  row only. Walk: `YCODE_IDE_ISSUES5=<prefix>` (`ShellDriver+Issues5.swift`).

## Gaps

- Linux has no project editor: the row opens the sheet alone, the stepper
  only selects the row.
- OpenViews' checkbox has no public mixed state: a partly checked group shows
  checked on Linux (macOS shows the dash). Toolkit request to B5-OPENVIEWS.
- The sheet's placement (centred both ways) and the dimming are the window's
  sheet behaviour (B5-POPOVERS, `popovers.md` §7); this sheet uses each IDE's
  ordinary sheet presentation.

## Tests

- `YcodeProjectTests/RecommendedSettingsTests`: rows, wording, round trip
  (only the changed keys differ), partial apply, inheritance and stricter
  values, `.xcconfig`, catalogs in file references and synchronized folders.
- `YcodeUITests/RecommendedSettingsUITests` (offscreen): the live warning
  (capsule, navigator, stepper), the sheet's measures, Cancel, Perform Changes.
- `YcodeIDEShellTests/RecommendedSettingsShellTests`: the same on the Linux
  model.
- `ProductActionsR36Tests.projectLevelSigningCheck` now looks at the signing
  warning beside the new one.

## After merging the main line (1aeb0bac)

- The live warning puts the issue capsule in the toolbar of every unbuilt
  project, which exposed a miss in P-029's subtitle fit: the step before the
  one that fits was judged on the title bar's layout alone and could be
  rejected by a few points. `widestActivity` now probes that step's cap with a
  full layout first and searches above it when it fits
  (`Beta5ToolbarTests.subtitleTakesTheRoomLeft`).
- Runs: Mac focused (`RecommendedSettings*`, `ProductActionsR36Tests`,
  `Beta5ToolbarTests`, `B5ControlStatesUITests`, `PopoversB5UITests`,
  `MenusB5Tests`, `CouncilRound9FileTypeShellTests`, `ToolbarFitLivelockTests`,
  `CouncilRound9ToolbarTests`): 76 tests passed. x86 full suite: 3144 tests
  passed. The Linux walk ran in light and dark; the project file was left
  unchanged by Cancel.
