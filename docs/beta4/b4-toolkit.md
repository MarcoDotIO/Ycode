# Beta 4: B4-TOOLKIT (OpenViews menus, alerts, sheets)

Workstream B4-TOOLKIT closes the OpenViews parts of P-212, P-214 and P-215
(`specs/ide/parity-inventory.md`; Linux rows L-003, L-004, L-005, L-006,
L-063, L-081, L-153, L-180, L-220, L-221, L-232, L-238). The macOS IDE uses
AppKit's own menus, alerts and sheets for these, so the work is in OpenViews
(`frameworks/swiftui`) and the Linux IDE's walk only.

## P-212 Menus

- **Submenus on hover.** A submenu opens when the pointer rests on its row
  for 0.2 s (`MenuMetrics.submenuDelay`; the macOS IDE measured ≈ 0.2 s),
  as well as on a click or Right. Resting on another row closes the open
  submenu; passing over a row opens nothing. The row of an open submenu stays
  highlighted. Linux tour: all 38 submenus that open on a click now open on a
  1 s hover (before: none); the pop-up appears 172–272 ms after the pointer
  stops (debug build).
- **Widths and cuts.** Pop-ups were kept inside their main window, so in the
  480-point Welcome window the File menu was cut at the bottom and its
  submenu overlapped it, hiding titles and shortcuts. Pop-ups now go anywhere
  on the window's display (`PlatformWindow.popupArea`: X11's display usable
  bounds around the window; on Wayland the compositor keeps them on screen).
  Measured: File from Welcome is 361 × 837 in a 632-point window, its New
  submenu beside it at x 403 (`tk-menu-file-new.png`).
- **Shortcut glyphs.** Menus show ⌃ ⌥ ⇧ ⌘ and the key glyphs (↩ ⎋ ⌫ ⌦ ⇥ ← →
  ↑ ↓ ↖ ↘ ⇞ ⇟, F-keys as "F5") in the macOS order instead of "Ctrl+",
  "Super+Ctrl+": ⌘1 and ⌃1 read apart (L-006).
- **Keyboard.** ⌃F2 (Ctrl+F2) opens the menu bar, as on macOS; a Ctrl press
  that matches both a ⌘ and a ⌃ shortcut now runs the ⌘ one.
- **Opening cost (L-003).** The measuring tree of a pop-up is taken down
  after the pop-up is shown. Debug build, File from Welcome: 30 ms measuring,
  67 ms building and drawing the pop-up window. The rest of the latency is
  the shell rebuilding every item (`ShellMenus`) and drawing; P-195 and P-210
  carry it.
- Not done here: section headings (L-061, needs `ShellMenus`), symbols on
  system items (L-235), the Help search field (L-226).

## P-214 Alerts

- **Return and Escape.** Return chooses the alert's default button (one
  marked `.defaultAction`, else its first button that does not cancel),
  Escape its `.cancel` button; an alert with a single button goes away on
  Escape. Buttons chosen by a key (or an accessibility press) also dismiss
  the alert. Linux: "alert after Return: closed", "after Escape: closed"
  (before: open, open).
- **Keyboard routing.** While a sheet, alert or dialog is up, a view under it
  loses the keyboard (an editor or field under an alert took Return and
  Escape) and gets it back when the last presentation goes; only shortcuts
  of views inside the innermost presentation run (menu commands still do).
  Return in a one-line field of a sheet also chooses the sheet's default
  button, as AppKit fields do.
- **Look.** On a desktop host alerts and dialogs are drawn as the macOS IDE's
  alerts (measured from its Clone alert): 260 points wide (330 with a text
  field), the app icon 64 points at the top left (set with `_alertIcon(_:)`),
  a bold 13-point title and 13-point message left-aligned 20 in, 28-point
  capsule buttons, two side by side in a 228-point row (cancel leading, the
  default trailing in the accent colour), corners 20. The phone host keeps
  the reference phone's look.

## P-215 Sheets

- A desktop window grows to show a sheet larger than it (sheet plus the
  40-point margin, up to the display's usable size) and returns to its size
  when the sheet goes, unless it was resized meanwhile. Presentations now
  cover the whole window when the content is smaller than it. Linux from
  Welcome (480 × 632): Clone grows the window to 520 × 632, New Project to
  800 × 632; Clone/Cancel and Next/Cancel are inside the window; the window
  is 480 × 632 again after each.
- Deviation from macOS: AppKit draws a sheet as its own window that may hang
  past its parent; OpenViews has no such child window yet (L-225), so the
  parent grows instead. The merge sheet is not an OpenViews sheet (it is the
  shell's own overlay, sized from the window by `MergeSheetMetrics`, ending
  28 points below the window as on macOS), so growing does not apply to it:
  see the line asked of B4-WORKFLOWS in the report.

## Tests and walks

- `frameworks/swiftui/Tests/OpenViewsTests/B4/ToolkitParityTests.swift`
  (16 tests); `R11/CommandsTests.swift` updated for the glyphs.
- `ycode/Sources/ycode-ide/ShellDriver+Toolkit4.swift`
  (`YCODE_IDE_TOOLKIT4=<prefix>`): menus, alerts and sheets from Welcome.

## Follow-up: P-139 and L-072 (the Settings window)

- The Settings scene's window is resizable in height only, from its
  content's size (minimum = that size, maximum width = that width), as the
  macOS IDE's Settings window resizes from 710 × 452. On Linux the window
  opens at 710 × 452; the panes grow with it once `SettingsWindow.swift`
  lets its content flex in height (asked of B4-PANES).
- ⌘W (Ctrl+W or Super+W) and Escape close the Settings window when nothing
  in it takes the key and no sheet or alert is up. Linux walk: "after
  Ctrl+W: windows 1", "after Escape: windows 1" (before: 2, 2).
- Platform: `WindowConfiguration.minimumSize` / `maximumSize` (SDL's
  window size limits).
