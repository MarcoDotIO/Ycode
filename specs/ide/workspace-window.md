# Workspace window

Ycode module: `YcodeUI` (`WorkspaceWindowController`, `WorkspaceSession`).

## Opening

A workspace window opens one container: an `.xcodeproj`, an
`.xcworkspace`, a `Package.swift`, or a folder that contains
`Package.swift`. One container per window. Saving (⌘S) writes edited source
files and any changed project through the byte-exact pbxproj writer
(`specs/formats/pbxproj.md`); unchanged projects are not rewritten.

## Areas

```
+--------------------------------------------------------------------+
| toolbar                                                            |
+-----------+-------------------------------------+------------------+
| navigator | jump bar                            | inspector tabs   |
| selector  | editor (gutter | text | minimap)    |                  |
| bar       |                                     | inspector        |
|           +-------------------------------------+                  |
| content   | debug bar                           |                  |
|           | variables view   |  console         |                  |
| filter    |                                     |                  |
+-----------+-------------------------------------+------------------+
```

| Area | Toggle | Ycode default |
|---|---|---|
| Navigator (left, sidebar) | toolbar / View ▸ Navigators (no default shortcut; ⌘0 is Show Coding Assistant) | shown, 290 pt |
| Inspector (right) | toolbar / View ▸ Inspectors (no default shortcut) | shown, 265 pt (260 observed in pass 5) |
| Debug area (below editor) | ⇧⌘Y | hidden; shown when a debug session starts or on ⇧⌘C |
| Toolbar | ⌥⌘T | shown |

Default window frame 1400 × 900 pt including the toolbar
(`reference-ui.md` §2, `reference-ui-5.md` §3.3); the frame is remembered
per container. The window title (Window menu, Mission Control) is
"<workspace> — <document>" (`reference-ui-5.md` §3.4).
Menu titles for toggles read "Show …" or "Hide …" by current state.

## Toolbar

Superseded by the toolbar layout in the Evidence notes below and
`reference-ui-5.md` §4. The default toolbar has no Library button, and the
activity area shows no subtitle while idle. Ycode's earlier layout was:
navigator toggle; Run (▶, ⌘R) and Stop (■, ⌘.); the scheme pop-up and
run-destination pop-up joined by a chevron; the activity view; Library (+,
⇧⌘L); inspector toggle.

Activity view (no text while idle; correction 2026-10-19): container
name, then status text ("Building …",
"Compiling main.swift", "Build Succeeded | Today at 9:53 PM", "Running …",
"Paused: breakpoint"), then error and warning counts with their symbols.
A progress bar shows while busy.

Scheme list: shared then user schemes of the container (and of each project
in a workspace); if a project has none, one per target. Package: one scheme
named after the folder. Destinations: "My Mac" (`platform=macOS`),
"Any Mac" (`generic/platform=macOS`).

Run: build; ask `xcodebuild -showBuildSettings -json` for the first
application/tool target's `TARGET_BUILD_DIR/EXECUTABLE_PATH`; launch it
under lldb-dap (`specs/ide/debug.md`).

## Inspector area

Tabs for a source file, in order: File (⌥⌘1), History (⌥⌘2), Quick Help
(⌥⌘3). File inspector sections: Identity and Type (Name, Type, Location,
Full Path) and Text Settings (Text Encoding, Line Endings, Indent Using).

## Debug area

A debug bar (hide debug area, activate/deactivate breakpoints,
pause/continue, step over, step into, step out, current frame), then the
variables view on the left and the console on the right, split evenly.
While stopped, the variables view lists the non-expensive scopes of the top
frame and the editor highlights the stopped line.

## Icons

Ycode uses SF Symbols through the public runtime API only, and never a
trademark-shaped symbol: no Swift bird (`swift`), Apple logo, or Xcode
hammer. Swift files and package manifests use
`chevron.left.forwardslash.chevron.right`; projects use
`folder.badge.gearshape`; workspaces `square.stack.3d.up`; the build
system issue group `gearshape.2`. A test enforces this (CLAUDE.md rule 5).

## Evidence

- Correction 2026-10-19: area toggles without default shortcuts, the
  frame size, window title, toolbar exclusivity and tooltips, and the idle
  activity area: `reference-ui-5.md` §2.0, §3.3–§3.4, §4 (level 3).
- Area names, toggles and shortcuts (⌘0, ⌥⌘0, ⇧⌘Y, ⇧⌘C, ⌘R, ⌘., ⇧⌘L):
  Apple's public Xcode Help and keyboard-shortcut reference (level 1).
- Toolbar content (run/stop, scheme/destination, activity view, library,
  inspector toggle): Xcode Help and WWDC session descriptions (level 1).
- Inspector tab order for source files: Xcode Help (level 1).
- `-showBuildSettings -json`: `man xcodebuild` and black-box runs (level 3).
- OPEN QUESTION: default area widths/heights and window size (ours are
  guesses).
- Toolbar layout (reference-ui.md §2, §5, level 3): Navigators / Coding
  Assistant two-segment control at the left, Run/Stop, Back/Forward, the
  workspace name with the activity as a second line under it, the
  centered scheme › destination pill (re-centered by the inspector
  tracking separator when the inspector toggles), Canvas / Assistant /
  Code Review three-segment control, Show Inspector at the far right.
- Debug area (reference-ui.md §5, level 3): opened on run output or a
  pause, hidden on completion only when the run printed nothing; split
  50/50 between variables and console. Variables bar: scope pop-up
  (Auto), registers and info toggles, filter. Console bar: debugger and
  target output toggles, filter, clear, show/hide each half. Debug bar:
  breakpoint activation at the left, "Line: N Col: N" and a show/hide
  toggle at the right.
- File inspector (reference-ui.md §6, level 3): Name (editable; renames
  the file only in package workspaces), Type, Location with a chooser,
  Full Path with reveal, Text Encoding "No Explicit Encoding", Line
  Endings "No Explicit Line Endings", Indent Using, Tab/Indent steppers.
- OPEN QUESTION: exact activity-view status strings and date format.
- Window 1400 × 900, navigator 290, inspector 265, debug area 135 points
  (reference-ui.md §2, §5, §6). The debug bar sits under the editor and
  stays when the debug area is hidden; Continue and the step buttons show
  only during a debug session.
- Issue capsule (reference-ui-2.md §2): right of the scheme pill, errors,
  warnings and failed tests; zero counts left out, hidden when empty. The
  activity line after an action is "<Result> • Today at <time>" ("Test
  Completed" for a test run with failures; "Finished running
  <product>").
- OPEN QUESTION: autocreated scheme names for packages with several
  products.
