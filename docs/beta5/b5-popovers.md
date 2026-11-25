# Beta 5: B5-POPOVERS (popovers, in-window panels, sheets)

Workstream B5-POPOVERS of 1.0.0-beta.5 (`docs/ROADMAP-1.0.md`): one
component model for Ycode's transient surfaces, built once per IDE and used
by every chooser, palette and sheet of P-014, P-031, P-083, P-086, P-111,
P-112, P-113, P-180 and P-195. Clean room: written from
`specs/ide/popovers.md`, `specs/ui/glass-materials.md`, the inventory rows
(`specs/ide/parity-inventory.md`), Ycode's own code and public AppKit
documentation.

## The component model (`popovers.md` §11)

Shared numbers and models live in `YcodeIDECore/Popovers/` and both IDEs
lay out from them:

| File | What |
|---|---|
| `PopoverMetrics.swift` | `PopoverMetrics` (arrow 26 × 11, corners 17, frame margin 14, rows 24, separators 12, Filter 30 inset 7, highlight inset 12 radius 8, the row columns), `PopoverPlacement` (centred on the anchor, on the preferred edge, never flipped, shifted only to stay inside its bounds with the arrow on the anchor), `InWindowPanel` (Jump to Line 640 × 55 at +17, Quick Actions 560 × 55 at +3, Open Quickly 640 × 55 at +18, Quick New Project 640 at +17; field 61 in, 10 down, 36 tall), `NewSchemeSheetMetrics`, `PopoverMaterial`; the timings are in B5-MOTION's `Motion` catalogue (`popoverOpen`, `panelClose`, `jumpToLineFadeOut`, `sheetEntrance`, …) (the §1 colours where a toolkit draws them) |
| `ChooserList.swift` | `ChooserRow`/`ChooserList` (rows, highlight, Up/Down over selectable rows stopping at the ends, hover, row frames), `SchemeChooser`, `DestinationChooser` (Recent, Devices, Simulators, Build, each destination once; Incompatible as a disclosure; Ycode's rows under Simulators), `DestinationProductMenu` |
| `NewScheme.swift` | `NewSchemeModel`: the targets, the name, OK's write |
| `PaletteModels.swift` | `PaletteList` (fuzzy results), `QuickNewProject`, `JumpToLineInput` |

macOS (`YcodeUI`): `AnchoredPopover` (the system popover: `animates =
false`, `.transient`, edge mapped for flipped views), `ChooserPopoverController`
and `ChooserRowsView` (`Window/ChooserPopover.swift`), `PaletteController`
and `PaletteRowsView` on `GlassPanel` (`Window/InWindowPanels.swift`),
`QuickHelpPopover` (`Inspector/QuickHelpView.swift`), the choosers and New
Scheme (`Window/WorkspaceWindowController+Choosers.swift`).

Linux (`ycode-ide`): `ShellPopoverModel` (`YcodeIDEShell`) and
`PopoverOverlay.swift`: `AnchoredPopoverShape` (body and arrow one outline),
`ChooserPopoverLayer`/`ChooserPopoverView`/`ChooserRowView`,
`ChooserCapsuleHalf`, `InWindowPanelLayer` (Jump to Line, Quick Actions,
Quick New Project), `NewSchemeSheetView`, all installed by one modifier,
`WorkspacePopovers`. Walk: `YCODE_IDE_POPOVERS5` (`ShellDriver+Popovers5.swift`).

## Per item

| P-id | macOS | Linux |
|---|---|---|
| P-111 | The scheme half opens a popover on **mouse-down** (`SchemePopUpButton.mouseDown`; Choose Scheme ⌃0 too): Filter, ✓ schemes with the app icon, Edit Scheme…, New Scheme…, Manage Schemes…; body 213 × 163, frame 241 × 191, centred on the half, arrow tip at the capsule's bottom; the current row highlighted; Up/Down, hover, Return, Escape | the same rows and keys from `ShellPopoverModel`, drawn under the half (`ChooserCapsuleHalf` records its window frame), opened on mouse-down (a zero-distance drag); Edit and Manage disabled (no scheme editor on Linux yet) |
| P-112 | `NewSchemeSheetController`: 493 × 122, Target pop-up, Name (selected), Cancel / OK 84 × 23, 12 apart, 20 from the right, 17 from the bottom; OK writes a **shared** scheme (OPEN: the reference's default was not observed) built as Ycode's autocreated scheme for the target, writing the project's autocreated schemes first so they stay listed; the new scheme becomes active. Product ▸ Scheme ▸ New Scheme… needs the menu line below | `NewSchemeSheetView`, same model and write |
| P-113 | Destination half on mouse-down: Recent ✓ (OS version right-aligned), Devices, Simulators, Build ("Any Mac (arm64, x86_64)"), each destination once; Incompatible a disclosure row expanding **in place** (click, or Right; Left collapses), the popover growing downward in one frame; Manage Devices… last; Get a Simulator Runtime… and Set Up Ycode Simulator… under Simulators. Show All Run Destinations opens it expanded | the same list from the host's groups (this computer under Devices, simulator hosts under Simulators); Incompatible empty and disabled (no Apple platforms on Linux) |
| P-014 | `DynamicMenus.fillDestinationMenu`: empty headings (and their separator) hidden, rows "<name> <version>", "Any Mac (arm64, x86_64)", Incompatible rows enabled and choosable. Needs the `MenuBarDelegate` line below | `DestinationMenuItems`: headings drawn as headings, the same titles, Incompatible ▸; needs the `ShellMenus` lines below |
| P-083 | `QuickHelpPopover`: the rendered Quick Help (`QuickHelpView`) in the popover, **above** the symbol, arrow down, tip 3 over the line, centred on the whole word (TextKit 2 segment rects); a popover window of its own, so never clipped to the window; NSPopover keeps the preferred edge unless the screen has no room (OPEN §12.2: the system then flips) | `QuickHelpPopoverLayer` now places the popover above the symbol, centred, bottom-aligned at the tip so it grows upward past the editor (over the jump bar and toolbar) instead of flipping |
| P-086 | Jump to Line (⌘L): a 640 × 55 glass capsule, 17 under the toolbar, centred on the window, borderless "Line Number" field; Return jumps and closes in one frame; Escape fades (140 ms ease-in). Quick Actions (⇧⌘A): 560 × 55, 3 under the toolbar, "Quick Actions", **empty until typed**, matching commands growing downward | the same capsules (`JumpToLineCapsule`, `QuickActionsCapsule` over `ShellQuickActions.collect`); Return closes Jump to Line (L-064). Quick Actions needs the command lines below to be reachable from the menu and ⇧⌘A |
| P-180 | ⇧⌘N with a workspace open: the 640 × 355 panel (`showQuickNewProject`) over the compact picker's five rows with glyphs and subtitles; Down, typing filters, Return does the row's action (App makes the untitled project; Choose Template… the sheet), Escape closes | `QuickNewProjectPanel`; choosing calls `showNewProject(row:)` |
| P-031 | Every panel is a child `GlassPanel` that **never becomes main** (`canBecomeMain` false) and every popover a system popover, so the workspace stays the main window and keeps its active look; nothing of this workstream is a sheet any more except New Scheme. About and Settings are not this workstream's windows (see Candidates) | everything is drawn in the workspace window |
| P-195 | Popovers in and out in one frame (`animates = false`), Incompatible in one frame; no menu fade; Jump to Line's Escape fade | the same (no animation except Jump to Line's fade) |

Open Quickly's default top is now **70** (18 under the toolbar), the
2026-11-20 default place, instead of round 9's 200 (OPEN §12.3: probably a
position the reference had stored; Ycode stores none).

## Decisions on OPEN items

1. Destination chooser timing in dark under load: one frame (the 2x and
   light measurements).
2. Quick Help with no room above: left to the system popover on macOS (it
   flips only at the screen's edge); the Linux overlay grows upward without
   limit.
3. Jump to Line, Quick Actions and Open Quickly cannot be moved or resized;
   no position is stored.
4. Open Quickly and the Library leave in one frame on Escape.
5. The Incompatible list's height: from its content (the macOS popover is
   limited by the screen).
6. Quick New Project: the inventory row's 640 × 355, field placeholder
   "New Project" (not observed).
7. New Scheme writes a shared scheme.
8. Light Quick Help: near-white like the choosers until the mid grey is
   confirmed at 2x (`glass-materials.md` §7 item 2).

## Menu lines (applied at the merge with the main line, as the orchestrator asked)

1. `CommandTable.swift`: Product ▸ Scheme ▸ New Scheme… is `newScheme:`
   (macOS `newScheme(_:)`; Linux `ShellAppModel.performMenuAction` calls
   `showNewScheme()`).
2. `MenuBarDelegate.swift`: Product ▸ Destination is filled by
   `fillDestinationMenu` (P-014).
3. `ShellMenus.swift`: the Destination submenu is `DestinationMenuItems`.
4. Linux: View ▸ Show Quick Actions… (⇧⌘A) opens the Quick Actions capsule;
   File ▸ New ▸ Project… (⇧⌘N) with a workspace open opens Quick New
   Project (Welcome's compact picker otherwise).

## Requests for other workstreams

1. B5-OPENVIEWS: a sheet that takes its content's size (New Scheme's
   493 × 122 card is drawn taller) and dims the window behind it by a third
   (dark) or a sixth (light) (`glass-materials.md` §1, P-215); a pop-up
   button bezel for `Picker` in a form row; a blur under the popover and
   capsule fills (`PopoverMaterial` holds the opaque fills).
2. The Linux scheme capsule (`SchemeCapsule`) moved to
   `ToolbarOverflowChrome.swift` beside `CenterToolbar` at the merge.

## Tests

- `YcodeIDECoreTests/PopoverModelTests` (14): placement, rows, keys,
  heights, Incompatible, Ycode rows, Linux groups, Destination menu titles,
  capsule frames, the sheet's buttons, palettes, New Scheme's write.
- `YcodeIDEShellTests/PopoverShellTests` (4): the Linux model's choosers,
  New Scheme, Jump to Line's fade, Quick Actions and Quick New Project.
- `YcodeUITests/PopoversB5UITests` (7, offscreen guard on): the scheme
  chooser on mouse-down, New Scheme from the chooser, the destination
  chooser's Incompatible, Quick Help above the word, the capsules' frames
  and P-031, Quick New Project, Product ▸ Destination.
- Linux walk `YCODE_IDE_POPOVERS5=<prefix>` (with a project path).
