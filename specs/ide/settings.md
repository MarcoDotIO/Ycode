# Settings

Ycode module: `YcodeUI` (`SettingsWindowController`, the panes in
`SettingsPanes.swift`, `SettingsController`, `Preferences`,
`EditorTheme`, `KeyBindings`, `BuildSystemPreference`), `YcodeBuild`
(`FallbackEngine`).

## Window

Ycode ▸ Settings… (⌘,) opens one shared sidebar window
(`specs/ide/reference-ui.md` §4): the pane list at the left, the selected
pane as grouped cards under its title and the back/forward capsule
(R3.1–R3.3 below give the measured layout). Panes, in order: General,
Appearance, Accounts, Coding Assistant, Behaviors, Navigation,
Notifications, Editing, Shortcuts, Source Control, Components, Locations
(the reference's twelve, in its order), then Simulators (Ycode's own, at
the end; council round 3). Accounts is
informational only. Coding Assistant (the reference's Intelligence
position, in Ycode's own words) holds the assistant's back ends, the
OpenAI sign-in or API key, agent-tool paths, context options and the
privacy note (`coding-assistant.md` §6); its secrets are in the keychain,
never in user defaults.

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

Layout (both IDEs, the card style of R3.3): one 240-point card holding the
account list, "No Accounts" centred in it while it is empty, and, under a
separator, a 28-point bar with + at its leading edge (10 inside the
card). The sheet's title is "Accounts Are Not
Supported"; its text is "Ycode does not sign in to accounts. Signing uses
identities already in your keychain; Ycode never asks for or stores
passwords." On Linux, where there is no keychain, "identities Ycode finds
on this computer" replaces "identities already in your keychain". The
texts are shared (`YcodeIDECore`'s `AccountsPage`).

The list's rows will be App Store Connect API keys (Apple's public REST
API; signing.md §8): the `.p8` file stays where the user keeps it, Ycode
records only its path, key ID and issuer ID, and any secret goes to the
keychain or the Secret Service. Until that work lands the list reads an
`AppStoreConnectKeyStore` that has no keys, and nothing is stored.

## Behaviors
A list of categories (Build, Testing, Running, Search, Localization
Import / Export, File) with the number of events that have actions; each
opens a sub-page listing its events with their actions, + to add an
action and − to remove one. Ycode's events: Build — when build starts,
generates errors, generates warnings, succeeds, fails; Testing — when
testing succeeds, fails; Running — when
running starts, pauses, generates output (the program's first output in
a run), completes, exits unexpectedly. Actions: show a navigator, show or
hide the debug area, hide the debug area if the run printed nothing,
play a system sound, notify (the result bezel over the window, or a
system notification when the window is not in front; see
`build-notifications.md`). Sounds only happen for a window on screen.
Defaults (reference-ui.md §4): build generates errors → Issues navigator;
build succeeds / fails → notify; testing succeeds / fails → notify
(Ycode's choice); running pauses → Debug navigator and debug
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
using spaces or tabs, tab width, indent width, the Tab key, syntax-aware
indenting, closing brackets and quotes, and enclosing selections
(`source-editor.md`, "Ycode implementation" ▸ Settings).

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
The `ycode build` command does not read this setting: on macOS it keeps
xcodebuild unless `--engine` is given, and on Linux it builds packages with
SwiftPM (`build.md`, "The command line").

Run (⌘R) asks the active engine for the executable: xcodebuild via
`-showBuildSettings`; swift-build from its derived-data layout
(`Products/<configuration>/<product>`, inside `Contents/MacOS` for apps).

## Language ▸ Build server (no pane yet)

`Ycode.buildServer` (Boolean, default YES) in the app's user defaults:
whether sourcekit-lsp gets compiler arguments for projects and workspaces
from Ycode's build server (`specs/ide/language.md` §Build server). Set it
with `defaults write org.ycode.Ycode Ycode.buildServer -bool NO`; the
environment variable `YCODE_BUILD_SERVER=0` turns it off for one run. With
it off, the language server opens the project's folder as before. A
checkbox in Settings is future work (the Settings code is being moved).

## The Linux IDE

`ycode-ide`'s Settings window (Ctrl+,; `SettingsWindow.swift`,
`SettingsCards.swift` and the `SettingsPane*.swift` files) is the macOS
IDE's: one fixed 710 × 452 window with the sidebar, capsule, title and
grouped cards of R3.1–R3.3, drawn from the same `SettingsLayout` metrics
and `SettingsPaletteHex` colours (YcodeIDECore). Panes, in the
reference's order: General, Appearance, Accounts, Coding Assistant,
Behaviors, Navigation, Notifications, Editing (with its Display,
Completion and Indentation pages), Shortcuts, Source Control, Components,
Locations. Components shows its empty state ("No Components", a note that
Linux builds with the Swift toolchain on the PATH, and Simulator
Runtimes…, which opens the runtime wizard). Simulators is not offered on
Linux.

- The cards are Ycode's own views (not OpenViews' `Form`): a card is a
  stack of rows one point apart over a separator-coloured strip inset 10,
  clipped to radius 12, so the line shows only between rows. Pop-ups are
  the value and a circular chevron button opening a menu with a check at
  the choice; switches are Ycode's 36 × 18 drawing. Symbols OpenViews has
  no artwork for (Appearance, Navigation, Shortcuts, Locations) are drawn
  by Ycode from the descriptions in R3.2. The appearance (System, Light,
  Dark) is the window's `preferredColorScheme`, so the in-window menu bar
  and the pop-ups follow it too.
- The values are the same `Preferences` keys as on macOS, in the user
  defaults of the `ycode-ide` process (swift-corelibs-foundation keeps
  them in `$XDG_CONFIG_HOME/ycode-ide.plist`); every change is written at
  once, so a quit or killed app keeps it. Themes are in
  `$XDG_DATA_HOME/Ycode/Themes`.
- Applied at once: the appearance (System, Light, Dark; both windows), the
  theme and font sizes (editors), indentation and typing (open buffers),
  File extensions (the project navigator), Notify (the build bezel) and
  shortcuts (the menu bar is rebuilt). The other rows are stored for the
  macOS IDE and for when the Linux editor gains the feature.
- Appearance: colors are edited as `#RRGGBB` text with a swatch (an empty
  field is the system color); a live preview shows sample code in the
  selected theme. Built-in themes are read-only. Import and Export use the
  file dialogs.
- Behaviors: the events by category, each with a summary of its actions;
  an event's page sets them with pop-ups (navigator, debug area: No
  Change, Show, Hide, Hide If No Output; sound) and a Notify checkbox, and
  Restore Default Actions.
- Shortcuts are written as the Linux menus show them: "Ctrl+Shift+K" (⌘
  is Ctrl, ⌥ is Alt, ⇧ is Shift, ⌃⌘ is Super+Ctrl). The field also reads
  the ⌃⌥⇧⌘ notation. Because ⌘ and ⌃ are both Ctrl on Linux, conflicts
  are checked in the Linux notation (⌃K conflicts with ⌘K there). A
  shortcut needs a modifier unless it is a function or arrow key. Overrides are
  the shared `Ycode.keyBindings`.
- Locations: Linux builds packages with SwiftPM and projects with
  ycodebuild, so the pane lists the tools found (Swift, sourcekit-lsp,
  ycodebuild, git) and the themes folder instead of the Build System
  pop-up.

## Council round 3: the Settings window, measured (2026-11-05)

Measured from one Retina still of the reference's Settings window on the
General pane (active, light), and the same pane in Ycode. Values are in
points, half-point precision; positions are from the window's top-left
corner. Checklist rows 62–64 in `fidelity-council.md`.

### R3.1 Window and title area

| Element | Reference | Ycode now |
|---|---|---|
| Window size | **710 × 452** | 860 × 560 |
| Window buttons | 14-point circles at x **19, 42, 65**, centred on **y 26**; all three enabled (minimize yellow) | x 9, 32, 55 on y 16; minimize disabled |
| Back / forward | **one glass capsule** x 187.5–261 (73.5 wide), y 8.5–43 (34.5 tall), near-white fill (#F8F8F8–#FCFCFC) with a faint rim and soft shadow; a 1-point divider #C8C8C8 at its centre (y 16–36); a left chevron and a right chevron (each 8 wide, 14.5 tall), 14 from the capsule's ends, **#AEAEAE when there is no history** | two separate small circles, x 212–256, y 10.5–28.5 |
| Title | the pane's name ("General"), starting **x 273.5** (12.5 after the capsule), cap top y 20, cap height 12 (about 17 points); **#4D4D4D**; stems 1.5–2.0 points, i.e. regular to medium weight, not bold; vertically centred on the window buttons (y 26) | x 264.5, cap top 13.5; #272727, bold |
| Title-bar band | no separate band: the title area is part of the white detail pane over the detail column and of the sidebar's grey over the sidebar | — |

### R3.2 Sidebar

| Element | Reference | Ycode now |
|---|---|---|
| Placement | **flush**: it fills the window's left side from the top edge to the bottom edge (no inset, no floating panel) | flush |
| Width | **179.5**, then a 0.5-point divider #D4D4D4 at x 179.5; the detail pane starts at 180 | 200, no divider |
| Fill | #EDEDED, uniform | #EDEDEE |
| Rows | **32-point pitch**; the first row's band at y 52–84 | 26-point pitch, first band at y 42–68 |
| Selection | a rounded band x **10–170** (160 wide, 10 inset each side), **32 tall**, corner radius about 7, fill **#0070F5**; label and symbol white | x 10–190, 26 tall, #007AFF |
| Symbol | monochrome, **tinted with the accent colour** (about #0575FA) on unselected rows; 15–21 wide, centred on x **29**; white on the selected row | grey (#767676), 12–16 wide, left-aligned at x 21 |
| Label | starts at x **46.5–47** on every row (aligned regardless of the symbol's width); black (#000000); cap height 9.5 (about 13 points), regular | starts at x 42–47.5 depending on the symbol; black |
| Items, in order | General, Appearance, **Apple Accounts**, **Intelligence**, Behaviors, Navigation, Notifications, Editing, Shortcuts, Source Control, Components, Locations (12) | General, Appearance, Accounts, Coding Assistant, Behaviors, Navigation, Notifications, Editing, Shortcuts, Source Control, Components, Simulators, Locations (13) |

Ycode keeps its own names where the clean-room protocol requires: "Accounts"
(no Apple trademark in Ycode's UI, AGENTS.md rule 5) and "Coding Assistant"
(§Window). Simulators is Ycode's own pane with no reference counterpart.

Symbols, in words (Ycode draws its own): General a gear; Appearance a
circle split into light and dark halves; accounts an at-sign in a circle;
Intelligence a four-pointed sparkle with speed lines; Behaviors two
stacked rounded rectangles; Navigation a diamond road sign with a turning
arrow; Notifications a bell; Editing a pencil on a square; Shortcuts a
keyboard; Source Control a square with a branch mark; Components stacked
layers; Locations a drive.

### R3.3 The General pane: grouped cards

The detail pane is white (#FFFFFF) from x 180 to 710. Its content scrolls
vertically under the title area; a scroll bar shows at the right edge
(x 696–707; the Mac's setting showed a track, #F3F3F3, with the knob
#7C7C7C). Sections:

| Element | Value |
|---|---|
| Section header | bold, #272727, cap height 9 (about 13 points), left edge **x 210.5** (the cards' inner edge); its cap top **22.5 above** its card's top |
| Card | x **200–690** (20 from the sidebar's divider and 20 from the window's right edge; 490 wide), fill **#F7F7F7**, corner radius **about 12**, no border, no shadow |
| Card to the next section header | 33 from a card's bottom to the next header's cap top |
| Row | **37.5 tall + a 1-point separator** (38.5 pitch) for a one-line row; taller with help text |
| Separator | 1 point, **#EBEBEB**, inset **10** from both card edges (x 210–680); none above the first row or below the last |
| Row label | left-aligned at **x 211** (card + 11 of ink; card + 10 of frame), #262626, regular, cap height 9.5 (about 13 points), **no colon**; vertically centred in a one-line row |
| Help text | under the label, same left edge, **#7C7C7C**, about 11 points, **14-point line pitch**, wrapping at the card's inner width less the control column (here up to about 416 wide, 2 lines); its first baseline about 19 below the label's baseline |
| Trailing control | right-aligned in the card: **pop-up** = the value text (#262626, regular) ending 13 before a **20 × 20 circular button** (fill #E5E5E5, up/down chevrons #232323) whose right edge is **13.5 inside** the card (x 676.5); **switch** = a track about 36 × 18 (off: light grey, about #DDDDDD, with a white pill-shaped knob about 21 wide at the leading end), right edge **10 inside** the card (x 680) |
| Control's vertical position | centred on the **label's line**, not on the whole row (in a row with help text the control sits beside the label) |

Rows seen (the pane continues below the window; the rest of the order is
`reference-ui-5.md` §9.1):

| Section | Row | Control | Help text | Card geometry |
|---|---|---|---|---|
| Starting Points | Restore open projects and workspaces | pop-up, "Use System Setting" | 2 lines: explains that the value follows the system's close-windows-when-quitting setting | card y 98–167 (69): label cap top 13 below the card's top, help ends about 11 above its bottom |
| Navigation and Files | Navigator size | pop-up, "Use System Setting" | none | card from y 223; row 223–260.5 |
| | Bookmark navigator detail | pop-up, "Up to 3 Lines" | none | 261.5–298.5 |
| | Find navigator detail | pop-up, "Up to 3 Lines" | none | 299.5–337 |
| | Issue navigator detail | pop-up, "Up to 3 Lines" | none | 338–375 |
| | Window tabs have independent sidebar widths | **switch**, off | 2 lines: each window tab keeps its own sidebar widths and the tab bar moves when switching | 376–442 (66) |

The header-to-card rhythm: header cap top y 76 (first) and y 200.5
(second); cards at 98 and 223.

**Ycode now:** a single form with right-aligned labels ending in colons
(the label column ends at x 427), bordered pop-ups beside them, checkboxes
for the switches, bold section headings with no cards, and no help text.
Issues and Test Parallelization rows are visible because nothing is
grouped; whether the reference keeps them in General below the fold is
not settled by this still (`reference-ui-5.md` §9.1 lists them there).

### Ycode implementation (round 3)

Both IDEs implement R3.1–R3.3 (`SettingsChrome.swift` in YcodeUI,
`SettingsCards.swift` and `SettingsWindow.swift` in ycode-ide, the shared
`SettingsLayout`):

- The window is 710 × 452 and fixed. On macOS an empty unified toolbar
  gives the 52-point title area with the window buttons at x 19, 42, 65 on
  y 26, all enabled. The capsule and its chevrons are drawn by Ycode with
  the measured colours (chevrons #AEAEAE without history); the title is
  17-point regular, #4D4D4D.
- The sidebar is flush, 179.5 wide with the 0.5 divider; rows are 32
  points from y 52; the selection is the 160 × 32 band, radius 7,
  #0070F5; symbols are accent-tinted (white on the selection), centred on
  x 29; every label's ink starts at x 47. Thirteen rows on macOS are
  taller than the window, so the list scrolls to show Simulators.
- Every pane is grouped cards: headers bold 13 points with their cap top
  22.5 above the card, cards x 200–690 (a legacy scroller's track covers
  the right margin, not the cards), one-line rows 37.5 with separators,
  labels without colons at x 211, help text under its row's label, pop-ups
  ending with the circle 13.5 inside the card, switches (not checkboxes) 10
  inside. Rows that are not a label and a control (the appearance
  thumbnails, the theme preview, the account list, the shortcut table) sit
  in a card of their own, inset 10.
- General keeps the §9.1 order: Issues and Test Parallelization stay
  General's sections, as cards under Navigation and Files. The help texts
  of Restore open projects and workspaces and of Window tabs have
  independent sidebar widths are Ycode's own words.
- Dark colours (R3.4) are Ycode's own (`SettingsPaletteHex`).

### R3.4 Not settled

- The rows below the fold, and the pane's full height (the knob's size
  suggests about 3 × the visible height).
- The window's size on other panes (the reference may size Settings per
  pane), and whether it animates between panes.
- The selected row's colour when the window is not key, and the sidebar
  in dark mode.
- The switch's on state and size precisely (only one switch, off, was
  visible); the pop-up button's pressed state and its menu.

## Evidence

- Correction 2026-10-19: General, Navigation and Editing ▸ Display rows and
  defaults per `reference-ui-5.md` §9 (level 3); the File extensions factory
  default (Hide All) per `reference-ui-5.md` §5.1 (level 3).

- Accounts' layout, texts and the App Store Connect key seam are Ycode's
  own (the macOS IDE's pane, ported); App Store Connect API keys are
  Apple's public App Store Connect API documentation (level 1).
- The Linux IDE's layout, its shortcut notation (Ctrl for ⌘, as the
  OpenViews menus write it) and its persistence are Ycode's own.
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
- Round 3 implementation: the palette's dark values, the help texts, the
  card rows for non-control content, the Linux symbols' drawings and the
  Components empty state are Ycode's own.
- Council round 3 measurements (window size and buttons, title, back and
  forward capsule, sidebar placement, width, rows, symbols' tint, item
  order, the General pane's cards, rows, separators, help text and
  controls): one Retina still of the reference's Settings window on
  General, active, and Ycode's matching still; colour runs and ink boxes
  measured in the dirty room (level 3). The window size is the capture
  manifest's window frame.
