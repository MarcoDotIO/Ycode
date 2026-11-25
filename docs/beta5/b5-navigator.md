# B5-NAVIGATOR: the navigators' depth (1.0.0-beta.5)

Items P-037, P-039, P-040, P-041, P-042, P-043, P-051, P-052 and P-199 of
`specs/ide/parity-inventory.md`. The Linux half is described in
`docs/beta5/b5-navigator-linux.md`; this file covers the shared core and
the macOS half. The behaviour is written down in `specs/ide/navigators.md`
§"Ycode implementation: project navigator file operations".

## Shared core (`YcodeIDECore/Navigator/`)

- `NavigatorFilterModel`, `NavigatorFilterRecents`: the filter's pause
  (50 ms after the last key), matching, the bold/dimmed split of a row's
  title, "No Filter Results", the inspector's "No Selection", the options
  menu (recent filters, Clear Recents).
- `ProjectRowMenu`: the rows' context menus by row kind (the reference's
  items and order), the "+" menu, the titles, the 240-point width.
- `NavigatorEmptyStyle`: the empty state's 16-point medium title in
  #9D9FA1 (dark), raised 4.5 points.
- `NavigatorBars.specs`: Source Control, Tests and Reports carry the action
  (…) button; Source Control's empty state is "No Git Repositories".

## macOS (`YcodeUI/Navigator/`)

- **P-037** `NavigatorAreaController+Filter.swift`. The field sends every
  key; the rows follow after the pause (`filterTyped`, `applyFilterNow`).
  A filtered row draws its match bold and the rest at 55 % (white on the
  accent band). With nothing left: "No Filter Results", and the inspector
  reads "No Selection" (`inspectorPlaceholderIsNoSelection`, one line in
  `WorkspaceWindowController.swift`). The options glyph is the accent
  colour while text is present. The options menu lists the navigator's
  recent filters (noted when editing ends or the navigator is left) and
  Clear Recents, and opens upward from the glyph's left edge
  (`NavigatorOptionsButton.opensUpward`). The field's value is its
  accessibility value. The Issue navigator keeps its own options menu; the
  Debug navigator's view options follow the recents.
- **P-039** `updateEmpty()`: the title 16 points medium (the reference's
  ink widths, "No Logs" 60 and "No Issues" 71.5, fit medium, not regular),
  #9D9FA1 in dark, raised 4.5 points; Source Control "No Git Repositories".
- **P-040** The Project "+" is `ProjectRowMenu.addMenu`; Source Control,
  Tests and Reports show the "…" button with the window's items; the Find
  scope reads "In Workspace" (the parity run; `reference-ui-5.md` §5.4's
  "In Project"/"In Package" is older). The Reports Local/Cloud control was
  already gone (owner decision 5).
- **P-041** `NavigatorAreaController+RowMenu.swift`: the menu is built from
  `ProjectRowMenu` with the window's actions (validated by the window) and
  the navigator's own (Open Terminal at Location, Open in New Tabs, Open
  with External Editor, Bookmark on the clicked row). A right click leaves
  the selection alone; `selectedProjectRows` stands for the clicked row
  while the menu is open and its command runs. Rename is gone from the
  menu (Return renames); the project row has no Delete. Open in New Window
  is disabled (Ycode has none); Open As ▸, Help and Services ▸ are not
  listed.
- **P-042** `draggingDestinationFeedbackStyle = .regular` (the blue
  insertion line with its ring, the blue outline on a group or folder);
  the drag image is the row's icon and name at 60 % (no band); the dragged
  rows' band turns grey while the drag lasts.
- **P-043** The rename field is borderless and bezel-less, no focus ring,
  label colour on the text background. Empty groups and folders keep their
  disclosure triangle, shown open; that open state is not saved as an
  expansion.
- **P-051** The macOS outline already had these keys; nothing changed.
- **P-052** Linux only (the macOS operations exist since NAV-OPS).
- **P-199** `NavigatorAreaController+SelectionOpen.swift`: a plain single
  click opens the file when the button goes down, as soon as the outline
  selects the row; the release does not open it again. A click with
  modifiers, a second click, or a press on the selected row still opens on
  release. Measured offscreen (a loaded Mac): a short file opens, lays out
  and draws in ≈ 30–60 ms; a 400-line Swift file in ≈ 460 ms, of which
  ≈ 330 ms is the editor's synchronous parser pass at open
  (`SourceEditorController.resetSyntax`: files up to `syncParseLines`,
  2 000 lines, are parsed before the first frame). Deferring that pass at
  open (`scheduleRefine(after: 0)`, the lexical colours first) is the next
  step; it is the editor's file, so it is listed for its owner. The
  reference's ≈ 95 ms ease of the editor content is not Ycode's yet (the
  editor swap, with a B5-MOTION constant).

## Asks from other workstreams (after the main-line merge)

- **P-024 (B5-MOTION).** The selector bar now gives way to ≈ 135 points
  (its tabs compress, glyphs shrink). The navigator as a whole is still
  held ≈ 259 points wide by the Test header's 194-point pop-up (priority
  750, also while hidden). Releasing that hold (tried: the pop-up's width
  only while the Test navigator is shown, and every header row
  compressible) makes the navigator narrower in a narrow window, which
  breaks `B5MotionUITests.narrowWindowsKeepTheEditor` (it expects the
  navigator collapsed) and `Beta5ToolbarTests` (Navigators goes into "»"
  at 817 points because the navigator's toolbar section narrows). The
  navigator's minimum, the auto-collapse width and the toolbar's leading
  section must be changed together; left for B5-MOTION and B5-TOOLBAR.
- **P-193, P-194 on Linux (B5-MOTION).** The selector's disc slides on
  `Motion.selectorDisc`; rows expand and collapse with
  `OutlineRows.toggleDuration` (`Motion.outlineDuration`: Left ≈ 75 ms,
  Right and the triangle ≈ 175 ms).
- **P-198 (B5-STATES).** The selector tabs are `GlassTabButton`s with the
  navigator lens (`selectorLens`) on macOS, and `.glassTabLens(.navigator…)`
  on Linux; no hover, selection on release.
