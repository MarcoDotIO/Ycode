# Beta 5: B5-STATES (hover, press and focus; glass and scroll edges)

Workstream B5-STATES of 1.0.0-beta.5 (`docs/ROADMAP-1.0.md`): P-198 (issues
#63 and #64) and the glass materials and scroll edges (#57, #58), on both
IDEs. Clean room: written from `specs/ui/control-states.md`,
`specs/ui/glass-materials.md`, the P-198 row of
`specs/ide/parity-inventory.md`, Ycode's own code and public documentation.

## The shared model

`YcodeIDECore/Window/ControlStates.swift` holds one table that both IDEs
draw from: per control kind its hover state (only toolbar glass, the
Settings pop-ups and editor tabs have one), its trigger (mouse-down for
choosers, pop-ups, the filter options menu and Settings sidebar rows;
release for glass tab bars; mouse-up elsewhere), its fills and label
colours at rest, under the pointer and held, in dark and light, its grow
(1–2 pt for toolbar glass, none for flat controls) and timings (hover in one
frame; the tab ×'s bezel fades over 150 ms; held glass 120 ms in, 200 ms
settle). `GlassTabLens` is the lens state machine of the navigator selector
and the inspector's tab bar (rises over the selected tab, follows the
pointer while held, selects on release, release outside is not a cancel).
`EditorTabStates` holds the tab × values. Focus rings: only with Full
Keyboard Access.

`YcodeIDECore/Window/GlassMaterials.swift` holds §1–§5 of the glass spec
(surfaces, radii, the dimming under sheets) and Part B's rule for Ycode-only
surfaces (`GlassRole` → `Material`), plus the scroll-edge facts: no
progressive edge in the workspace, the jump bar's 2-pt divider (two rows:
dark #3D3D3C over #363636, light #E4E4E4 over #E5E5E5), the sticky band
(20 pt, starting on the divider's second row) and its separator (dark
#3C3A3C over #353636, light #E6E5E6 over #E5E5E5), and `stickyLines`, the
enclosing-declaration lookup both editors use.

## Per item

| Item | macOS | Linux |
|---|---|---|
| Settings pop-up hover | a bezel over the whole control (8 pt before the value, 24 tall, radius 6), one frame in and out, none when disabled (`HoverBezelTracker`, a sibling view behind the pop-up) | the same bezel (`hoverBezel(.settingsPopUp)`) |
| Pop-ups open on mouse-down | AppKit's own | OpenViews' desktop `Menu` acts on mouse-down (Menu.swift hook); the menu stays open on release |
| Settings sidebar rows select on mouse-down | NSTableView's own | `MouseDownRowStyle` |
| Disabled controls dimmed once | — | Settings switch, pop-up and push button no longer dim themselves on top of the toolkit's dimming |
| Sheet push buttons | every sheet's system push buttons get `StatePushButtonCell` as the sheet becomes key: default #0078FE, held #2C85FD dark / #006CE5 light; others #2F2F31 → #434345 / #EBEBEB → #D3D3D3; no hover, one frame | OpenViews' desktop bordered and prominent buttons tint while held (white 10–14 % dark, black 10 % light) instead of fading to 65 % |
| Plain buttons held | — | OpenViews' desktop plain buttons keep their look while held (was 50 % opacity) |
| Focus rings | the sheet cell draws none without Full Keyboard Access | OpenViews' desktop buttons draw none without it (`fullKeyboardAccess`, `OV_FULL_KEYBOARD_ACCESS=1`) |
| Editor tab × | 18 × 18, a 16-pt round bezel (#606060 dark) in one frame, fading over 150 ms after the pointer leaves, held #686868 (`TabCloseButton`) | no editor tabs on Linux (L-136, P-063) |
| Inspector tabs | a glass lens (98 × 40) over the selected tab glides to the pressed one, follows the pointer while held, the tab selects on release (`GlassTabLensController`, `GlassTabButton`); no hover | the same (`glassTabLens`) |
| Jump bar divider (#58) | two fixed rows from the table, the same at every offset | the same two rows (`JumpBarRule`); the canvas is clipped at the divider, so text no longer draws over the jump bar |
| Sticky declaration line (#58) | opaque band (was the 3.5 % veil), starting on the divider's second row; separator from the table | new: drawn by the source editor's painter (`SourceEditorView+Sticky.swift`), 19 pt below the 2-pt rule so the separator lands on the reference's rows |
| No progressive scroll edge | none drawn (unchanged) | none drawn (unchanged) |

## Not done, and why

- **Segmented controls on macOS** (Build Settings' Basic / Customized / All,
  the target tabs' pressed #5A5A5A): on macOS 27 `NSSegmentedControl` draws
  through a hosted view, so a custom cell does not change it; matching the
  measured pressed fill needs a Ycode-drawn control. Candidate for P-102
  (the project editor's chrome, beta 7).
- **Segmented pickers and pop-up pickers on Linux**: drawn in OpenViews'
  `Picker.swift` (B5-OPENVIEWS): pressed segments still fade to 50–60 %, the
  pop-up picker opens on mouse-up and fades to 40 %.
- **Settings switch held look** (±4–8 levels around the knob): not drawn.
- **Toolbar controls** (hover bezels, held grow and brightening, the
  Run/Stop divider hiding on hover, disabled presses dragging the window)
  and the **navigator selector's lens and outline rows**: B5-TOOLBAR's,
  B5-MOTION's and B5-NAVIGATOR's; the model is ready and the lines they
  need are in the report.
- **Tab order without Full Keyboard Access** (Tab should not stop on
  buttons): OpenViews' focus system (ControlSupport.swift), B5-OPENVIEWS.

## Tests

- `YcodeIDECoreTests/B5ControlStatesTests` (macOS and Linux): the table,
  timings, triggers, the lens, the scroll-edge values and the sticky lookup.
- `OpenViewsTests/B5/ControlStateTests`: plain and push buttons held, focus
  rings, a desktop menu open on mouse-down, `StatefulButtonStyle`'s hover,
  press and trigger.
- `YcodeUITests/B5ControlStatesUITests` (offscreen): the pop-up bezel, the
  tab ×, sheet buttons, the inspector lens, the divider and the sticky
  separator, in pixels. `YCODE_B5_SHOTS=<dir>` saves pictures.
- Linux walk `YCODE_IDE_STATES5=<prefix>` (ShellDriver+States5.swift): the
  sticky line at 392 and 48 pt, the lens held and dragged off the bar, the
  pop-up's hover and mouse-down menu, a sidebar row on mouse-down.

## After merging the main line (24568472)

- **Toolbar, macOS:** the toolbar items are the system's glass items, so
  their hover, held tint and grow are AppKit's (`control-states.md` §9).
  Ycode adds: a press on a disabled Run | Stop or Back | Forward segment
  moves the window (`ToolbarSegmentedControl`), and the scheme › destination
  halves each show their own 28-pt hover bezel (`ToolbarControlStates`).
- **Toolbar, Linux:** `GlassSegments`, `GlassCircleButton`, Stop, the issue
  capsule use `ToolbarGlassStyle` (hover bezel 28 tall, held fill, grow
  1–1.5 pt a side over 120 ms, settling over 200 ms); Run, Add Editor and
  Editor Options (menus) and the chooser halves show the hover bezel. A
  disabled glyph is the table's grey (#7A7A7B / #A5A6A7), dimmed once. A
  disabled control takes no pointer, so a press on it moves the window.
- **OpenViews pickers:** a held desktop segment takes the selected fill and
  its label dims (0.84); a desktop pop-up picker opens on mouse-down and does
  not fade while held.
- **Focus without Full Keyboard Access (desktop):** buttons and pickers are
  no Tab stops, and neither they nor rounded text fields draw a focus ring;
  the palettes' fields (B5-POPOVERS) were already caret-only on both IDEs.
- Not done: the Run | Stop divider hiding while Run is hovered (Linux), the
  navigator selector's lens (B5-NAVIGATOR).
