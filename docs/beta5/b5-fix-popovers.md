# Beta 5 fix round: B5-FIX-POPOVERS

Items 4–7 of the fix round after council round 12: P-083, P-113, P-086 and
P-197. Clean room: written from `specs/ide/popovers.md` §2.7, §4.1, §4.2,
§5.1 and `specs/ui/control-states.md` §8, §8.1 (commit `cabb60ab`), Ycode's
own code and public documentation.

## Shared model (`YcodeIDECore`)

| File | What |
|---|---|
| `Popovers/ChooserList.swift` | The initial highlight: the checked row, else the first choice, else a disclosure; never a command. `ChooserPointerGate`: hover moves the highlight only after the pointer has moved since opening. A current destination without a Recent section stays in its own section. |
| `Popovers/QuickHelpPopoverLayout.swift` | `QuickHelpPopoverMetrics` (417 body, 16 side insets, 385-wide borderless box, 17.5-pt lines + 7.5 above and below, radius 6, #262626 dark), `QuickHelpDeclarationLines` (attributes and modifiers before the keyword on their own line), `ModuleQuickHelp` (the module named at an offset of an `import` line; its document from the module's DocC catalog in the workspace). |
| `Model/QuickHelpDocument.swift` | `isModule`, `overview`; a module has no declaration or file link and always the documentation link. |
| `Popovers/QuickActionRows.swift` | `QuickActionEntry` (title with the sub-menu path, subtitle the parent's menu path, glyph), `QuickActionRanking` (ranking and the semibold ranges), `QuickActionGlyphs`, `QuickActionRowMetrics` (56-pt rows, glyph centre 33, text 64, 17/14 pt, highlight inset 8/21 radius 14 #0059D1, hairline at 55, rows from 66, panel ≤ 495). |
| `Window/TooltipTiming.swift` | `TooltipTiming` (1.56 s, tab 1.1 s, 350 ms hold, 460 ms linear fade) and `TooltipSession`, §8.1's state machine (waiting, shown, leaving, swapping). |

## Per item

| P-id | macOS | Linux |
|---|---|---|
| P-113 | The chooser opens with the checked row highlighted (the session's destination, else the capsule's selected row); Ycode's rows stay last in Simulators and never take the first highlight; `ChooserRowsView` ignores hover until the pointer moves from where it was at opening. | The same rows from `ShellPopoverModel`; hover through `onContinuousHover` on the body and `chooserPointer(at:bodyY:)` behind the same gate. Linux has no Get a Simulator Runtime… row (as before). |
| P-083 | `QuickHelpPopover.content`: 417 wide, the title, the borderless 385-wide box (two lines for `nonisolated let name: String`, 385 × 50, syntax-coloured from the editor theme), the file link with the file's own glyph (the Swift logo in orange) and the name in the accent colour. A module in an `import` (`+ModuleQuickHelp.swift`, hooked in `showQuickHelp`): title, abstract, hairline, Overview, the link at the bottom right; without a catalog the title and the link. ≈ 417 × 132 for `name`. | `QuickHelpContent(popover: true)` and `QuickHelpDeclarationBox`, the same metrics; `showModuleQuickHelp(at:)` before the language server is asked. |
| P-086 | `QuickActionsController`: the hairline at 55, two-line 56-pt rows from 66 in an overlay-scroller list, the glyph, the title with the match semibold (17 pt), the menu path (14 pt, #B0B0B4), the key equivalent (14 pt, #A8A8A8) 30 from the highlight's right; the selected row #0059D1, radius 14, inset 8 / 21, all white; the first selected; the panel grows to 495 then scrolls. | `QuickActionsCapsule` / `QuickActionRowView`: the same; `ShellPopoverModel` ranks with `QuickActionRanking`. |
| P-197 | **Ycode's own tooltips** (`Window/ToolTipPresenter.swift`): AppKit's tooltips cannot hold 350 ms then swap or fade on Ycode's curve, so Ycode draws them. So that only Ycode's shows (the owner saw both on 2026-11-24: `NSInitialToolTipDelay` did not stop AppKit's), a control the pointer reaches gives its text up to the presenter: its `toolTip`, its segments' and its toolbar item's move into a store on the control and are left as "" (AppKit shows no empty tooltip; nil set later still means none), a tooltip owner's rectangles are removed (the presenter asks the owner); the text stays the control's (each segment's) accessibility help; `ToolTipPresenter.text(of:)` reads it either way; a local event monitor follows `mouseMoved` (key windows accept moves), finds the control's text (a segment's, a tooltip owner's such as the gutter, the view's own, its toolbar item's) and shows it in a borderless panel (#444446, 1-pt #101012 in dark; left edge at the pointer's x, top 18 below) on `TooltipSession`; a click, drag, key, scroll or the app resigning removes it. Installed from `wireEditorExtras` (every workspace window); app-wide once installed. | OpenViews' `help(_:)` (`Input/Help.swift`): new public `TooltipTimings` (delay, hold, fade, grace; defaults keep the old behaviour), a hold then a linear opacity fade, a swap after the hold when the pointer reaches another view with help. `ShellTooltips.apply()` sets Ycode's timing from `TooltipTiming` (called at launch in `YcodeIDEApp.init()` and from `WorkspacePopovers`). |

## Values taken where the spec leaves them open

1. §2.7 item 2: no checked row → the first destination row; with no
   destination at all, nothing is highlighted (Up or Down starts it).
2. §4.2: narrower Quick Help bodies — none; every popover is 417.
3. §4.2: several attributes or modifiers before the keyword go together on
   one line (one case recorded).
4. §4.2: box padding 7.5 above and below each set of lines (50 for two
   lines); a one-line declaration is 32.5 tall. Side insets 16, top and
   bottom 14 (the recorded 132-pt body).
5. §4.1: Ycode's documentation source for a module is its DocC catalog in the
   workspace (the root article `# ``Module```: the first paragraph is the
   abstract, `## Overview` the overview). An SDK module (no catalog) shows the
   title and the documentation link.
6. §5.1: ranking beyond prefix matches: titles that begin with the query
   (top-level commands before sub-menu ones, then menu order); sub-menu
   commands whose own title begins with it; titles with a word beginning with
   it; titles containing it. Ycode's Product menu lists Build For before
   Build, so the depth rule keeps the reference's order (Build, Build
   Documentation, Build For › …).
7. §5.1: the path separator "〉" is drawn as "›" (in every Ycode font).
8. §5.1: light colours follow the system label colours (not recorded).
9. §8.1 item 3: after a tooltip has faded out completely, the next control
   waits the full 1.56 s (no grace on Linux either).
10. §8: the fade is smooth and linear over 460 ms (not the reference's 50-ms
    steps).
11. §8: the light tooltip (not recorded): the window background colour with
    the separator colour as its outline on macOS; OpenViews' own palette on
    Linux.

## Tests

- `YcodeIDECoreTests/B5FixPopoversTests` (14): initial highlight, Ycode's rows,
  pointer gate, Quick Help metrics, declaration lines, import module names,
  catalog documents, Quick Actions ranking, titles, glyphs and metrics,
  tooltip timing, hold and fade, swaps.
- `YcodeIDEShellTests/B5FixPopoverShellTests` (3): the Linux chooser, Quick
  Actions rows and module Quick Help.
- `OpenViewsTests/B5/TooltipHoldFadeTests` (2): hold, fade, swap, press.
- `YcodeUITests/B5FixPopoversUITests` (6, offscreen guard): the chooser's
  highlight and hover gate, no current destination, the 417-pt popover and
  385 × 50 box, module Quick Help through ⌥-click's path, Quick Actions rows,
  the tooltip presenter on the toolbar's Run/Stop segments (hit test, 1.56 s,
  swap after 350 ms, linear fade, click) with the panel kept off screen.
- Linux walk `YCODE_IDE_POPOVERSFIX=<prefix>` (`ShellDriver+PopoversFix.swift`).
- `PopoverMetrics.quickHelpBodyWidth` is now 417 (the older test reads it).

## For other workstreams

- B5-FIX-LAYOUT (shared motion constants): `Motion.tooltipDelay` (1.6),
  `tooltipChainedDelay`, `tooltipHold` (0.290) and `tooltipFade` (0.310) in
  `MotionCatalog.swift` contradict §8 now; `TooltipTiming` (new,
  `YcodeIDECore/Window/TooltipTiming.swift`) holds 1.56 / 0.35 / 0.46. Set
  the catalogue's to these values or point it at `TooltipTiming`
  (`B5MotionTests.tooltipFade` and `tooltipAppearance` pin the old ones).
- `ycode-ide/YcodeIDEApp.swift`: `ShellTooltips.apply()` is called in
  `init()` (added at the orchestrator's request), so the Welcome window has
  the timing too; `WorkspacePopovers` still calls it (idempotent).
- OpenViews (B5-OPENVIEWS's toolkit): `Input/Help.swift` gained
  `TooltipTimings` and the hold, fade and swap; its look is still the
  toolkit's palette (Ycode's #444446 / #101012 would need a style hook).
