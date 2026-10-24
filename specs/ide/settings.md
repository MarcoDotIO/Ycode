# Settings

Ycode module: `YcodeUI` (`SettingsWindowController`, the panes in
`SettingsPanes.swift`, `SettingsController`, `Preferences`,
`EditorTheme`, `KeyBindings`, `BuildSystemPreference`), `YcodeBuild`
(`FallbackEngine`).

## Window

Ycode ▸ Settings… (⌘,) opens one shared sidebar window
(`specs/ide/reference-ui.md` §4): the pane list at the left, the selected
pane as a form under its title with back/forward buttons. Panes, in
order: General, Appearance, Accounts, Intelligence, Behaviors,
Navigation, Notifications, Editing, Shortcuts, Source Control,
Components, Simulators (Ycode's own), Locations. Accounts and
Intelligence are informational only: Ycode stores no credentials and has
no coding assistant.

Values live in the user defaults under `Ycode.` keys. Every change posts
one notification; open editors, consoles, workspace windows and the menu
bar apply it at once (no restart).

## General
Correction (2026-10-19): the full General pane, with the reference's rows
and defaults, is `reference-ui-5.md` §9.1.
- Navigation and Files ▸ File extensions: Hide All (**default**) / Show All
  (project navigator file rows). Hide All is the reference's factory
  default (`reference-ui-5.md` §5.1).
- Issues ▸ Predictive Issues: show live issues (language-server issues in the editor and the
  Issue navigator; build issues always show).

## Accounts
An empty account list and +. Ycode does not sign in: + shows a sheet
explaining that signing uses identities already in the keychain and that
Ycode never asks for or stores passwords. Nothing is stored.

## Behaviors
A list of categories (Build, Testing, Running, Search, Localization
Import / Export, File) with the number of events that have actions; each
opens a sub-page listing its events with their actions, + to add an
action and − to remove one. Ycode's events: Build — when build starts,
generates errors, generates warnings, succeeds, fails; Running — when
running starts, pauses, generates output (the program's first output in
a run), completes, exits unexpectedly. Actions: show a navigator, show or
hide the debug area, hide the debug area if the run printed nothing,
play a system sound, notify (bounce the Dock icon). Sounds and
notifications only happen for a window on screen. Defaults
(reference-ui.md §4): build generates errors → Issues navigator; build
succeeds / fails → notify; running pauses → Debug navigator and debug
area; running generates output → debug area; running completes → hide
the debug area if no output. Stored per event under
`Ycode.behavior.<caseName>`.

## Notifications
One toggle per event: the event's Notify action.

## Navigation
Superseded (2026-10-19) by `reference-ui-5.md` §9.2, which uses the
reference's rows: New Editor Tabs / Panes Open With, Pin Editor Tabs,
Click on Code with modifiers, navigation destination and modifier routing,
and two toggles. Ycode's former rows were:
- Activation: Focused Editor (default) or Primary Editor (the tab's first
  editor) receives files opened from a navigator.
- Navigation Style: Open in Place (default) or Open in Tabs (a navigator
  selection opens in a new tab, or selects the tab already showing it).

## Appearance
System / Light / Dark at the top, then Theme / Fonts / Editor segments
(Theme: the theme and its colors as below; Fonts: editor and console
font sizes; Editor: cursor style). Built-in themes, written for Ycode (not copied from any other product):
Ycode Default (system colors, follows light/dark), Ycode Paper, Ycode
Dusk, Ycode High Contrast. A theme has a source font and size, background,
text, selection and current-line colors, a color per token kind
(keyword, comment, doc comment, string, number, preprocessor, attribute,
type name), and a console font, size, background and text color.
- Built-ins are read-only; Duplicate makes "<name> Copy" (numbered when
  taken) as a user theme, which can be edited (font size, token colors,
  console font size) and deleted.
- User themes are `.ycodetheme` files (JSON, sorted keys, colors as
  `#RRGGBB`, an absent color falls back to the system color) in
  `~/Library/Application Support/Ycode/Themes`. Import copies a file in
  (and selects it); Export writes the selected theme.

## Editing
Rows opening the Display, Completion and Indentation sub-pages; default
encoding (UTF-8) and line endings (LF); trim trailing whitespace (on save,
one undo group; default on) and trim whitespace-only lines (off).
Display (superseded by `reference-ui-5.md` §9.3, which removes the
minimap row, turns the page guide into "Show reformatting guide" at the
"Reformat code at column" setting, and adds the reference's other rows):
line numbers, code folding ribbon (default off), minimap, page
guide at a column, highlight instances of the selected symbol (on) with
its delay (0.25 s), wrap lines to the editor width (on; off: horizontal
scrolling) and the wrapped-line indent (4 spaces). Indentation: indent
using spaces or tabs, tab width, indent width (Tab inserts one
indentation step).

## Shortcuts (key bindings)
A searchable list of every menu command (title, shortcut, menu path).
Editing a shortcut (`⌃⌥⇧⌘` prefixes and a key) is refused when another
command uses it; the conflicting commands are named. Customized rows are
bold. Overrides are saved per user (`Ycode.keyBindings`) and the menu bar
is rebuilt with them; an empty shortcut removes it.

## Source Control
"Enable source control", and the author name and email read from git's
global configuration (`git config --global --get user.name|user.email`),
read-only.

## Components
Read-only list: the SDKs of the active developer directory (each SDK's
`SDKSettings.json`) and simulator runtimes from `xcrun simctl list
runtimes -j` (`name`, `version`, `isAvailable`). Nothing is downloaded or
deleted.

## Debugger (variables view)
The Registers toggle in the debug bar (saved as a setting) adds the
register scopes to the variables view. Watch Variable offers Write, Read
and Read & Write (`write`, `read`, `readWrite`; the first offered type
when the requested one is not).

## Locations ▸ Build System

A pop-up with **xcodebuild** and **swift-build**; the default is marked
"(Default)". The choice is stored in the user defaults key
`YcodeBuildSystem` (`xcodebuild` | `swift-build`) and applies to new
workspace windows and, immediately, to the next build of open ones. Under
the pop-up a note shows the `swbuild` path in use, or says it was not found.

Engines:

| Choice | Engine used |
|---|---|
| xcodebuild | `xcrun xcodebuild` (`specs/ide/build.md`) |
| swift-build, `swbuild` found | swift-build for packages and for projects whose targets the PIF generator supports (apps, tools, static libraries); xcodebuild for everything else (workspaces, other product types) |
| swift-build, `swbuild` not found | xcodebuild |

**Default: swift-build**, since it now builds macOS apps, command-line
tools and packages (`specs/ide/build-pif.md`) and falls back per request.
The `ycode build` command keeps xcodebuild unless `--engine swift-build` is
given.

Run (⌘R) asks the active engine for the executable: xcodebuild via
`-showBuildSettings`; swift-build from its derived-data layout
(`Products/<configuration>/<product>`, inside `Contents/MacOS` for apps).

## Evidence

- Correction 2026-10-19: General, Navigation and Editing ▸ Display rows and
  defaults per `reference-ui-5.md` §9 (level 3); the File extensions factory
  default (Hide All) per `reference-ui-5.md` §5.1 (level 3).

- Xcode's settings live under the application menu with Locations among
  the panes, and Xcode offers a build-system choice: Apple's public Xcode
  Help (level 1). The swift-build choice and fallback rule are Ycode's own.
- Pane names and order, the options listed per pane: Apple's public Xcode
  Help (level 1). Values, defaults, the theme file format and the
  built-in themes are Ycode's own.
- OPEN QUESTION: where the build-system choice appears in the reference
  release (Xcode puts some of it in File ▸ Workspace Settings); the
  reference's default behaviors; its theme format (deliberately not
  matched); key-binding sets; Components' download actions (not offered).
