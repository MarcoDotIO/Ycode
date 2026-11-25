# Beta 5: B5-OPENVIEWS (the Linux frame pipeline, pop-ups, file dialog, on-demand menu bar, Settings keys)

Workstream B5-OPENVIEWS closes the OpenViews parts of P-200, P-211, P-217,
P-033 and P-155 (`specs/ide/parity-inventory.md`; Linux rows L-001, L-002,
L-071, L-072, L-198, L-213–L-216, L-222, L-229). The macOS IDE already
behaves as the reference for these rows (AppKit), so the work is in
OpenViews (`frameworks/swiftui`) and the Linux IDE's Settings files.

All timings: the x86-64 workstation, release build, 1400 × 900 window on
its Wayland desktop, the `YCODE_IDE_FRAMES5` walk on a 42-file package
(`Long.swift` 1150 lines). "Work" is the main thread's time for one frame
(update, layout, drawing, presenting). Before = `OV_INCREMENTAL=0` on the
same build (the beta 4 pipeline) and the beta 4 build itself (same numbers
within noise). The workstation is shared, so single runs vary by ±15 %.

## P-200 The frame pipeline

Before, every pass lowered the whole window to layout nodes again, measured
and placed every node, reduced every preference, built the display list of
every node and flattened it by copying every item at every level. Now:

- **Lowering** (`ViewNode.lower`): a subtree in which nothing changed (no
  new value for a primitive, no body run, no state, environment or
  suspension change) returns the layout nodes of its last lowering.
  Containers whose lowering reads their own state (scroll offset, split
  positions, navigation and presentation motion) mark themselves with
  `setNeedsLayout()`. Removed views (transitions) always lower afresh.
- **Measuring and placing** (`LayoutNode`, `LayoutEngine`): the layout
  context is kept between passes; a kept node keeps its size and placement
  memos, and a kept node placed where it was is not walked again.
- **Environment**: an environment modifier whose new value (a closure)
  writes the same values keeps the old revision, so its subtree does not
  count as changed (`EnvironmentValues.hasSameValues`).
- **Preferences** are cached per subtree with the lowering.
- **Display list**: a node whose subtree did not change in its own
  coordinates gives its items from the last frame (moving does not count);
  live drawings (`Canvas`, text fields, scrollers) and animations draw every
  frame; subtrees of more than 24 items stay translating groups instead of
  being copied at every level.
- **Commands host**: buttons in the window's commands host (never drawn)
  build no look; a shortcut registered again keeps its place without
  sorting the registry.
- `OV_INCREMENTAL=0` restores the whole-window pass. `OV_FRAME_PHASES=<ms>`
  prints each frame over that long by phase (bodies, layout, preferences,
  display list, drawing), `OV_FRAME_PHASES_BODIES=1` adds the views whose
  bodies ran most.

| | before | after |
|---|---|---|
| Inspector hide slide | 2–3 frames, 6–11 fps, work median 240–290 ms | 11–13 frames, 38–43 fps, median 22–27 ms |
| Inspector show slide | 3 frames, 7–8 fps, median 208–318 ms | 12–15 frames, 26–38 fps, median 21–27 ms |
| Navigator slide (divider dragged, a pointer move each 8 ms) | not measured before (whole-window frames of ≈ 300 ms) | 19–25 fps, median 22–31 ms |
| Selection change (click a file row) | first frame ≈ 440 ms after the click, work ≈ 420 ms | ≈ 230–280 ms, work ≈ 210–265 ms |

A slide frame is now ≈ 22 ms: layout 4, display list 8, drawing and
presenting 8 (CPU rasteriser). That is ≈ 40 fps, not yet every frame of a
60 Hz display. Left: the drawing of the damaged area on the CPU (a slide
damages the whole editor column: ThorVG on the CPU, then upload), the
editor's and minimap's `Canvas` drawing again at the new width, and text
typeset again where it changed size. The toggle's own first frame
(150–180 ms, from 290) and the selection's (≈ 230 ms) are now mostly the
Linux IDE's menu bar rebuilding its ≈ 500 items on every change of the
workspace model (`ShellMenus.swift`, `ShellMenuModel.title` computing
`WorkspaceShellModel.menuContext` once per item): see "Lines for others".

## P-211 Latencies

| Action | before (first frame / its work) | after |
|---|---|---|
| Open a file (`open`) | 440–460 / 420–450 ms | 210–260 / 205–250 ms |
| Split Editor | 470–520 / 450–500 ms | 160–210 / 160–205 ms |
| Open Quickly | 305–320 / 220–233 ms | 33–55 / 23–55 ms |
| Find bar (Ctrl+F) | 158–217 / 157–196 ms | 24–33 / 24–32 ms |

Open Quickly and the find bar now show in two to four frames. File open and
split are dominated by bodies (the editor's new content and the menu bar's
rebuild). Previews (edit to pixels, 1.22 s, L-231) were not measured here:
their time is the preview build and render on the host, not OpenViews.

## P-217 Pop-ups, file dialog, UI font

- **Pop-ups** (L-222): on a desktop, a pop-up button's menu (`Picker` with
  the menu style, and a `Menu` whose content is a picker's choices, as the
  IDE's Settings pop-ups are built) opens over the button with the chosen
  row on it and its title over the button's; near the screen's edge the
  menu moves, it does not flip. Action menus still open below. Linux:
  Settings ▸ General ▸ Navigator size: button 231–251, menu 224–338
  (before: below, 255–369).
- **File dialog** (L-229): `fileImporter` and `fileExporter` ask the
  desktop portal's FileChooser (`OpenFile`, `SaveFile`; the desktop's own
  Open and Save dialogs, as the macOS IDE shows NSOpenPanel), with folder,
  filters, accept label, multiple selection and a suggested name; the
  answer's URIs go to the completion. OpenViews' in-window panel stays
  where there is no portal or it fails, on headless hosts, and with
  `OV_FILE_DIALOG=sheet` (`OV_QUIT_AFTER`, set by every walk, implies it).
  Tested against a stand-in portal on a private bus.
- **UI font** (L-227): not changed. The IDE already sets Inter with the
  tracking measured against the macOS IDE's system font
  (`FontTracking.desktopUI`), so widths match within 1 %; glyph shapes stay
  Inter's (the system face cannot be shipped). Left as a known difference.

## P-033 On-demand menu bar

- **L-001**: while the on-demand bar shows (pointer at the top edge, Alt,
  F10, or a menu open), the window's content moves down by its 26 points
  instead of being covered; the window buttons and the title-bar band move
  with it, and the bar stays while the pointer is over the band under it. A
  fixed-size window (Welcome) keeps its content at the top and loses its
  bottom 26 points meanwhile. Linux: the toolbar moved 26.0 points down and
  back.
- **L-002**: titles keep their full width; those the window has no room for
  move into an overflow title "»" whose menu lists them as submenus (Left
  and Right still step through every menu). Welcome (480 points): "Ycode
  File Edit View Find Navigate Editor Product Debug »", the overflow lists
  Integrate, Window, Help (before: "Yc…", "Vi…").

## P-155 Linux Settings keys and fields

- **L-071**: the pane list has the keyboard when Settings opens and after a
  click in it; Up and Down show the pane above or below (no wrap). Linux:
  Down twice from General shows Accounts, Up shows Appearance.
- **L-072**: Ctrl+W and Escape close Settings (beta 4, B4-TOOLKIT);
  checked again: windows 1 after Ctrl+W.
- **L-198**: Simulator Host fields save when editing ends: Return, Tab, a
  click elsewhere, or the page going away while the field has focus.
  Linux: a value left with Tab is kept.

## Tests and walks

- OpenViews (`frameworks/swiftui/Tests/OpenViewsTests/B5/`):
  `FramePipelineTests` (8: an incremental and a whole-window graph lay out
  and draw the same through selection, slides, insertions and removals; what
  lowers and what is placed again; live canvases and animations every
  frame), `OnDemandMenuBarTests` (4), `PopUpPlacementTests` (5),
  `FileChooserPortalTests` (5).
- Linux walks: `YCODE_IDE_FRAMES5=<prefix>` (`ShellDriver+Frames5.swift`:
  slides, selection, latencies; `YCODE_IDE_FRAMES5_PROFILE=slide|select|drag`
  with `YCODE_IDE_SAMPLE`), `YCODE_IDE_OPENVIEWS5=<prefix>`
  (`ShellDriver+OpenViews5.swift`: P-033, P-155, P-217; run it with
  `XDG_CONFIG_HOME` in a scratch folder, with and without a workspace).
- `OpenViewsAutomation.pointer(_:at:window:)` (new): single pointer events
  for drags and timed clicks.

## Requests from other workstreams

- B5-NEWPROJECT: `_menuOffset(_:)` (OpenViews, not SwiftUI API) sets the gap
  between a `Menu`'s button and its menu (10 for its menus); closing a
  window with its own close button removes its content first, so
  `onDisappear` runs. Left for beta 6: a file dialog with extra controls and
  no parent window, window tabs, a borderless pop-up with a fill parameter
  (with B5-STATES' `ControlStates.swift`).
- Shared files: `Controls/Button.swift` (commands-host buttons build no
  look: one `if` at the top of `body`) and `Controls/Menu.swift` (pop-up
  placement over the chosen row, `_menuOffset`) also change for B5-STATES;
  the edits are small and separate from its hooks.
