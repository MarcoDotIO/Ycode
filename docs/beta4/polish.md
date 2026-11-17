# B4-POLISH (1.0.0-beta.4, fix round after council round 11)

Clean-room fix round for six items council round 11 found not or only
partly fixed in beta 4. Tests: `ycode/Tests/YcodeUITests/B4PolishTests.swift`
(macOS, offscreen), `ycode/Tests/YcodeIDEShellTests/B4PolishShellTests.swift`
(Linux model), the Linux walk `YCODE_IDE_B4POLISH=<prefix>`
(`ycode/Sources/ycode-ide/ShellDriver+B4Polish.swift`). The rule both IDEs
share is `YcodeIDECore/Model/B4PolishChrome.swift` (`TitleAreaIcon`).

| Item | What changed | macOS | Linux |
|---|---|---|---|
| 1. Find bar (P-003) | Escape (`cancelOperation:`) in the find or replace field, or with another control of the bar focused, closes the bar and gives the text view the keyboard. When the bar changes the editor's content insets, the gutter is redrawn in the same pass (`gutter.needsDisplay`), so its numbers move with the text. | fixed: Escape closes it, focus in the text view. Line 1's number and text both move 32 pt (787 → 755 in the window) and the gutter draws at the new scroll position. The 1–2 line offset did not reproduce offscreen (old code is aligned there too), so the redraw is the fix for the cause found by reading the code (the inset change scrolls the text without invalidating the ruler). The bar is still 32 pt tall with three pop-ups (the optional 22 pt not done). | already: Escape closes it; the bar is in the pane's stack, so text and gutter move down together |
| 2. ⌘0 (P-026) | The Coding Assistant pane fills the left area but can no longer set its width: the content is at least the area's width and equal to it at priority 260 (above the labels' 250 compression resistance, below the split view's hold on the divider); the container clips. | fixed: 289.5 → ⌘0 289.5 (editor 850.5) → ⌘1 289.5, also with a control that cannot be narrower than 425 pt in the pane (old code: 901.5, and it stayed after ⌘1) | already: the column keeps its width (the toolbar's Back at x 302.5 before, after Ctrl+0 and after Ctrl+1) |
| 3. Selection band (P-035) | The navigators share one outline, and each switch reloads it. The Project navigator's selected rows and scroll position are kept aside when another navigator shows, and selected again when it comes back. | fixed: after ⌘2–⌘5 and ⌘1 the open file's row is selected and draws its band (old code: no row selected) | already: `projectSelection` is model state; kept after Ctrl+2–5, Ctrl+1 |
| 4. Settings width (P-139) | The window resizes in width too (maximum 4000 × 4000, minimum 710 × 452). Appearance's card and preview box follow the width; its thumbnails keep their place from the card's right end. Linux: OpenViews' Settings scene has no width limit any more (`AppHost.openWindow`), the content is flexible in width with an ideal of 710 × 452, and `OpenViewsAutomation.resize` lets a walk resize a window. | fixed: 900 × 760, every pane's cards end 20 pt inside the right edge | fixed: opens at 710 × 452 (it opened at 710 × 900 before), widened to 900 × 760, General's pop-up ends at 870 (card end − 10) |
| 5. Canvas beside the project editor | After the focused editor shows something other than source text (the project editor, an asset catalog, an IB document, a property list, a string catalog, an image), the canvas is hidden (canvas mode stays on); the next file with previews brings it back. | fixed: the project editor is 850 pt wide with no canvas (old code: 718 pt beside the canvas); back on ContentView.swift the canvas returns; a property list shows none | Linux has no project editor (P-107); the structured editors (property list) already hide the canvas and it comes back with the file |
| 6. Spinner while paused | `TitleAreaIcon.shown(busy:paused:)`: while the session's activity is paused, the title area shows Ycode's mark, not the build ring, with "Paused <product>" under the title; the accessibility tree has no progress indicator then. Running again brings the ring back. | fixed | fixed (`TitleMark(isPaused:)`, `WorkspaceShellModel.isActivityPaused`) |

## Screenshots

- macOS: `ycode/.build-ide/b4-polish-shots/mac-before/` (the old code, the
  same tests) and `mac-after/`: `mac-find-{1-closed,2-open,3-escape}`,
  `mac-p026-cmd0-after`, `mac-p035-{1-opened,2-after-cmd2-5-cmd1}`,
  `mac-p139-900x760-{General,Appearance,Editing,Accounts}`,
  `mac-canvas-{1-source,2-project-editor,3-source-again}`,
  `mac-paused-{1-running,2-paused}`.
- Linux (x86): `~/Ycode-B4-POLISH/shots/linux-before-*.png` and
  `linux-after-*.png`: `find-{closed,open,escape}`, `assistant`, `band`,
  `canvas-{source,plist,source-again}`, `running`, `paused`,
  `settings-{710,900,900-appearance,900-editing}`.

## Candidates (not done)

- The find bar's height and controls: the reference's bar is about 22 pt;
  Ycode's is 32 pt with three pop-ups on macOS, and a Find/Replace menu with
  three switches on Linux (P-079, beta 6).
- At 900 pt the Appearance pane's Foreground and Background sliders keep
  their width on macOS but grow with the row on Linux.
- Settings help texts wrap at the 710-pt window's width (`helpWidth`) when
  the window is wider, on both IDEs.
- The Linux IDE has no project editor (P-107).
