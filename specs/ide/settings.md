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
(the reference's twelve, in its order). Simulators (Ycode's own
simulator-host page) is reached from the Simulator Host row at the end of
Components' "Other Components" (R5.5, "Ycode implementation (round 5)").
Accounts is
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
Read-only: "Platform Support" (this computer and one row per simulator
platform, from the SDKs of the active developer directory, each SDK's
`SDKSettings.json`, and the runtime wizard's runtime records of this
computer and the simulator host), then "Other Components" (R5.2, R5.5).
Nothing is downloaded or deleted here; Simulator Runtimes… opens the
runtime wizard.

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
Locations. Components and its simulator-host page are the macOS IDE's
(round 5): "Linux" is the built-in platform. The runtime wizard opens in a
window of its own, as on macOS (a hidden title bar with only the close
button, the content's size).

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

## Council round 4: the Editing pane and General's details (2026-11-06)

Measured from one Retina still each of the reference's Settings window on
the General pane (step 20) and on the Editing pane (step 21, titled
"Editing" in the sidebar of both apps), active, **dark appearance**, and
the same panes in Ycode (`45c676aa`). The window is 710 × 452 in both.
Values are in points from the window's top-left corner, half-point
precision. Checklist rows 89–96 in `fidelity-council.md`. R3.1–R3.3 stay
valid for geometry; R4.3 gives the dark colours.

### R4.1 The Editing pane

The reference's pane, top to bottom (cards x 200/201–689/690, 490 wide,
as in R3.3):

| Card | y | Rows |
|---|---|---|
| 1, navigation rows | **72–206** | Display, Completion, Indentation: **44 tall** each, with 1-point separators (pitch 45) |
| 2 | **216–253.5** | Default text encoding: one 37.5 row with a pop-up |
| 3 | **263.5–338** | Default line endings (pop-up), separator, Convert existing files on save (switch): 37 + 1 + 36.5 |
| header "When Editing" | ink y 371–383.5, x 210.5 | — |
| 4 | from **394** | Automatically trim trailing whitespace (switch, on), Trim whitespace-only lines (switch), … (continues below the window) |

- **No header** between card 1 and card 2 and none between cards 2 and
  3: the cards are 10 apart. Text encoding is alone in its card; line
  endings and the convert switch share the next card.
- **Navigation rows** (card 1) each lead with a **row icon**: a rounded
  square **24 × 24**, its left edge 10 inside the card (x 210–234),
  vertically centred in the 44-point row (10 above and below), corner
  radius about 4–5 (a continuous corner: the fill reaches the edge 2–2.5
  points from the corner along each side), filled with a **vertical
  gradient**, lighter at the top, and a white symbol. The label starts at
  **x 245** (11 after the icon), regular, #DEDEDE. A disclosure chevron
  pointing right, about 5 wide and 9 tall, #5C5C5C, at x 674–679 (11
  inside the card). The separators run from **x 210 to 680** (they start
  under the icon's left edge, not under the label).

| Row | Icon fill, top → bottom (median) | Symbol, in words (Ycode draws its own) |
|---|---|---|
| Display | blue, #2BAFFF → #0091FE (#139CFF) | a white rounded rectangle outline with a filled bar along its right side (a window with a side panel) |
| Completion | cyan, #63E3FF → #3BD3FE (#4EDAFF) | the lowercase letters "abc" in white, regular weight, filling about two thirds of the width |
| Indentation | periwinkle, #94A1FF → #6D7CFF (#7B89FF) | a white arrow pointing right into a vertical bar |

- **Pop-up rows** (cards 2 and 3): the value text right-aligned, #DEDEDE
  (the label's colour, not grey), ending **12.5–13 before** a **20 × 20
  round well** (fill #363636, up and down chevrons in light grey) whose
  right edge is **13.5 inside** the card (x 656.5–676.5). This is R3.3's
  pop-up in dark.
- **Switch**: track **36 × 16** (x 644–680, 10 inside the card), off
  #3B3B3B with a white pill knob about 21 × 12 at the leading end; on: the
  accent #0679F7 with the knob at the trailing end.
- Header "When Editing": bold, #DDDDDD, its ink 33 below card 3's bottom
  and 10.5 above card 4's top.

**Ycode now** (the same window):

| Element | Ycode now | Change |
|---|---|---|
| Card 1 | y 73–187.5, rows **37.5** + separators, **no icons**, labels at x 211 | rows 44 tall; the three icons; labels at x 245 |
| Header "Files" | present (ink y 220–230.5) | remove it |
| Encoding, line endings, convert | one card y 243–357.5 | two cards (216–253.5 and 263.5–338), 10 apart, no header |
| Pop-up values | plain grey text #9F9F9F ending at x 678.5, **no well** | #DEDEDE text, the round well, the value ending 12.5–13 before it |
| Switch | 44 × 20 (x 636–680, y 329–349), off #3F3F3F, knob 26 × 14 | 36 × 16, knob about 21 × 12 |
| "When Editing" | ink y 390–403, card at 413 (19–20 lower) | ink 371–383.5, card at 394 |

### R4.2 General: the remaining differences

The General pane's card rhythm now matches (cards at 98–167 and from 223,
rows 37.5 with separators, within 0.5 in Ycode). What remains:

| Element | Reference | Ycode now |
|---|---|---|
| Sidebar rows | **12** (General … Locations), 32-point pitch from y 52; the last row ends at y 436, 16 above the window's bottom; **no scroller** | **13** (adds Simulators): the list overflows the 452-point window, shows a permanent scroller (thumb x 165.5–176.5, #A4A4A4, track to y 444) and the 13th row is cut off at the bottom |
| Selection | **x 10–170** (160 × 32), y 52–84 for General; fill **#007AFF** in dark (R3.2: #0070F5 in light) | x 10–162.5 (its right end clipped by the scroller), fill **#0A62D9** |
| Pane title | "General", "Editing": cap top y 20, cap height 12 (about 17 points), **#E8E8E8**, **semibold** (the G's stem 2.3 points) | the same place and size, **#C4C4C4**, regular (stem 1.8) |
| Pop-up well | present; value ends **12.5** before the 20-point well | present in General now, but the value text ends about **2–3 points** before the well (it is not moved left to make room) |
| Well fill | #363636 on the #262626 card | #434343 on the #2A2A2A card |
| Switch | 36 × 16 (knob about 21 × 12) | 44 × 20 (knob 26 × 14) |
| Sidebar fill / divider | #262627, a 0.5-point divider #414142 at x 179.5 | #2B2B2B, divider #111111 |

**Simulators.** The reference has no Simulators row: its 12 rows fit the
window without scrolling. Where Ycode's simulator settings go is the
implementer's decision (for example inside an existing pane, such as
Components or Locations, or reached from elsewhere); the constraint is
that the sidebar shows at most 12 rows at 32 points in the 452-point
window, with no scroller.

### R4.3 Dark colours (measured)

| Element | Reference | Ycode now |
|---|---|---|
| Detail pane (window) background | #1F1F1F | #1E1E1E |
| Card fill | **#262626** | #2A2A2A |
| Row separator | **#303030**, x 210–680 | #3A3A3A |
| Labels and values | #DEDEDE | labels #DFDFDF; values #9F9F9F (Editing) |
| Section header | #DDDDDD, bold | #DEDEDE, bold |
| Content scroller (both apps) | thumb #9F9F9F at x 696–707 | the same |
| Sidebar | #262627, selection #007AFF, symbols accent-tinted (about #118BFF) | #2B2B2B, #0A62D9, symbols about #007BFF |

### Ycode implementation (round 4)

Both IDEs implement R4.1–R4.3 from the shared `SettingsLayout`,
`SettingsRowIcon` and `SettingsPaletteHex` (YcodeIDECore):

- Editing's main page starts with a card 20 under the title area (y 72):
  Display, Completion and Indentation as **navigation rows**, 44 tall,
  each led by a 24 × 24 rounded square (radius 5) filled with the
  measured vertical gradient and a white symbol that Ycode draws with
  paths and text from the descriptions above (no system artwork on either
  platform), the label's ink at x 245, a drawn 5 × 9 disclosure chevron
  ending 11 inside the card. Then Default text encoding alone in a card
  and Default line endings with Convert existing files on save in the
  next, 10 apart with no header; "When Editing" follows at the usual
  header rhythm (its card at about 394). Cards with no header between
  them are 10 apart in every pane. Ycode reads and writes UTF-8 with LF
  only, so each of the two pop-ups offers that one value.
- Pop-ups everywhere draw the value in the label colour, ending 12.5
  before the 20-point well; the switch is Ycode's own drawing, a 36 × 16
  track with a 21 × 12 knob (on: #0679F7 dark, #0070F5 light).
- The sidebar lists the reference's twelve panes and has no scroller
  (the last row ends at y 436); the selection band is x 10–170.
- **Simulators** (Ycode's remote simulator host, boot and camera
  settings) is not a sidebar row: it is a navigation row, "Ycode
  Simulator" (a green icon with two stacked bars), at the top of
  Components, because Components is where the simulator runtimes it runs
  are listed and managed (Simulator Runtimes…). The page shows Components
  selected in the sidebar and as the title, with a way back ("‹
  Components"); every command that opened the Simulators pane (Add
  Simulator, the destination menu, the canvas) opens this page. The Linux
  IDE does not offer it.
- The title is 17-point semibold in both appearances (R3.1's light still
  read regular to medium; R4.2's dark still semibold: one weight is kept).
- The dark palette is R4.3's: detail #1F1F1F, cards #262626, separators
  #303030, sidebar #262627 with the #414142 divider, selection #007AFF,
  labels and values #DEDEDE, headers #DDDDDD, title #E8E8E8, wells
  #363636, the switch off #3B3B3B, the disclosure #5C5C5C. The light
  disclosure (#B0B0B0) and the Simulator icon's green are Ycode's own.

## Council round 5: Appearance, Components, the title and the selection (2026-11-06)

New panes, both appearances. Each app's **own** Appearance setting was set
to Light from its Appearance pane while the system stayed dark (step 23),
then General, Editing and Components were captured in light (24–26);
Components also in dark (22). One Retina still each, the 710 × 452 window,
active; values in points from the window's top-left corner, half-point
precision. Ycode `a1f82372`. Checklist rows 117–124 in
`fidelity-council.md`. R3–R4 stay valid; the cards, rows and controls
below use R3.3's anatomy unless a value says otherwise.

**Owner's design rules for this round:** where the reference has the
element, match it; where Ycode has an element the reference lacks (the
Linux simulator host), design it to the platform's human interface
guidelines in the OS 26+ glass language; and Ycode's macOS and Linux IDEs
look one to one.

### R5.1 Appearance (light; the Theme segment)

The pane has a **fixed top part** and a **separately scrolling list**
below a full-width separator. Top to bottom:

| Part | Reference |
|---|---|
| Card 1 | x 200–690, **y 72–160** (88 tall), R3.3's card |
| Its label | "Appearance" at **x 210.5**, cap top **85.5** (13.5 inside the card, level with the thumbnails' tops), the row-label style (#262626, regular, about 13 points) |
| Thumbnails | three, each **67 × 44**, corner radius about 4–5, **right-aligned**: System x 463–530, Light 538–605, Dark 613–680 (8 apart; the last 10 inside the card); y **85–129** |
| What they show (in words; Ycode draws its own) | each a miniature of a window over a wallpaper: **Light** a light window with a light title area and three small window-button dots (red, yellow, green) over a blue wave wallpaper; **Dark** the same in dark over a deep blue wallpaper; **System** split down the middle (x 496.5): the left half is the Light picture, the right half the Dark one |
| Selection | a **ring 3 points wide, #0088FF**, 1 point outside the thumbnail (outer box x 534–609, y 81–133, corner radius about 8) |
| Captions | centred under each thumbnail, cap top **139** (10 below it), about 11 points; unselected **#7C7C7C regular**, the selected one **#262626 bold**; the card ends 11 below them |
| Preview box | x 200–690, **y 170–239.5** (10 below card 1), white, a **1-point border #E6E6E6**, small corner radius (about 5); a code sample in the current theme's colours and the editor's font (about 7.9 points per character, **18-point line pitch**) |
| Its line numbers | right-aligned, ending x 228, light grey **#B8B3B4**; the code starts at **x 243** |
| Wrapping | **none**: long lines run past the box and a horizontal scroller shows along its bottom (knob y 225.5–236.5, #7A7A7A on a #F3F3F3 track to x 670), with a vertical one inside its right edge (x 676.5–686.5). Their style follows the system's scroll-bar setting (this Mac showed them always) |
| Separator | the full width of the detail pane (x 180–710), 1 point **#E5E5E5**, y **251.5–252.5** (12 below the box) |
| Segmented control | "Theme", "Fonts", "Editor"; **x 340–550 (210 × 28), centred on the detail pane** (centre x 445), y **264.5–292.5** (12 below the separator); track #ECECEC, fully rounded; segments 70 wide each; the selected one a full-height accent capsule (#0077F9) with a white label; a 1-point divider **#B5B5B5** (y 269.5–287.5) between two unselected segments only; labels about 13 points, #242424, centred |
| Separator | x 180–710, 0.5 point #E5E5E5, **y 304.5–305** (12 below the control) |
| The list | everything below scrolls on its own (its scroller x 696–707 starts at y 307.5); the top part stays |
| List card A | from the list's top (y 305): **Theme** (37.5 tall): label at x 210.5; a **push button "Choose…"** x 599.5–680 (80.5 × 24, y 310.5–334.5), fill #E4E4E4, label #232323 centred, no chevron. Separator 344.5–345.5 #EBEBEB. **Name** (36 tall): label; the theme's name right-aligned, ending x 678.5, #242424 |
| List card B | from **y 391.5** (10 below): **Foreground** (56 tall): label (cap top 404.5); a **slider** x 421.5–624 whose 14-point track (y 412.5–426.5) shows a gradient from a pale to a full tint of the row's colour, with a round knob about 27 across (white rim, the colour inside); then a **colour well**: a capsule x 632–680, y 405.5–433.5 (48 × 28), a 3-point grey rim #E2E2E2 around the colour. Further rows continue below the window |

**Ycode now** (light):

| Part | Ycode now | Change |
|---|---|---|
| Card 1 | y 72–154; **no label**; three flat swatches 66 × 42 **left-aligned** at x 211.5, 297.5, 383 (y 83–125): System half #EDEDED and half #2F2E2E, Light #EDEEED, Dark #292929; grey captions (#7A7B7A), **none bold**, **no ring** | the label; window-and-wallpaper thumbnails 67 × 44, right-aligned; the 3-point ring; the selected caption bold and dark |
| Preview | no box, no line numbers; text x 214–668, y 174–281.5, **wraps** long lines to the left edge, 16-point pitch | the bordered box, line numbers, no wrap, the 18-point pitch, the box's scrollers |
| Segmented control | x 200–371.5 (171.5 × 24), **left-aligned**, no separators | 210 × 28, centred, between the two full-width separators |
| Below | one scroll for the whole pane; Theme row with the theme's name in bold and a "Choose…" **pop-up with a chevron** (104 × 24); then a row per syntax element (Plain Text, Comments, …) each with a colour well | the fixed top part and a separately scrolling list; Theme with a push button, Name with the name, then the reference's rows (Foreground's slider and well, and the rows below, not captured) |

Fonts and Editor were not opened, and Appearance was not captured in
dark (R5.5).

### R5.2 Components (light and dark)

| Part | Reference (light / dark) |
|---|---|
| First header | "Platform Support", R3.3's header (bold, x 211), cap top **y 59**, #272727 / #DDDDDD; there is no row above it |
| Card | x 200–690, **y 82–343.5**, five rows |
| Row | **51.5 tall + a 1-point separator (52.5 pitch)**; separators x **210–680** (from the card's inner edge, under the icon), #EBEBEB / #303030 |
| Icon | a monochrome platform symbol in the **accent colour #007AFF** (both appearances), centred on x **226** and on the row; sizes from 13 × 18.5 to 25 × 14. In words: macOS a laptop; iOS a tablet with a phone in front of it; watchOS a watch; tvOS a display on a stand; visionOS a headset seen from the front; Predictive Code Completion a cluster of sparkles. Ycode draws its own |
| Title | x **251**, cap top **13.5 below the row's top**, about 13 points, #262626 / #DEDEDE, regular |
| Subtitle | under the title, **baselines 15 apart**, about 11 points, #7C7C7C / #9D9D9D: "Built-in" for the Mac's own platform, else the installed size ("15.94 GB"); a size starts 3.5 points right of the title's edge |
| "Last used …" | only on a platform used recently (iOS here: the label followed by a relative time): right-aligned, ending **x 655.5**, vertically centred on the row, the subtitle's colour, about 13 points |
| Info button | a **13 × 13** circle outline with a small "i", the subtitle's colour, x **665.5–678.5** (11.5 inside the card), centred on the row |
| Second header | "Other Components", cap top **376.5** (33 below the card, R3.3's rhythm); its card from **y 399.5**; first row Predictive Code Completion, 2.25 GB, with the same anatomy |
| Scrolling | the pane scrolls (knob x 696–707, about 30 % of the track) |

The rows are platforms and installed runtimes; their names and sizes are
data, not text to copy. **Ycode now:** a "Ycode Simulator" navigation row
(44 tall, green icon, chevron) in its own card at y 72–116; a header
"Installed (read-only)" (cap top 149) and from y 171.5 one row per SDK:
"SDK" at x 210.5 and the SDK's name and version in grey right-aligned
(ending 679), **37.5 + 1** pitch, no icon, no subtitle, no info button.
Target: the reference's two sections and row anatomy, with one row per
platform Ycode supports (its icon, name and version as the title, "Built-in"
or the size as the subtitle, "Last used" when known, the info button
showing the platform's SDKs and runtimes).

### R5.3 The pane title and the selected sidebar row

| | Reference | Ycode now |
|---|---|---|
| Title size | cap height **12** (about 17 points) in both appearances; ink widths "General" **54.5**, "Editing" 48, "Components" 90.5, "Appearance" 85.5; from x 273.5, cap top 20 | cap height 13.5 (about 19 points); "General" 60, "Editing" 54, "Components" 101, "Appearance" 95.5: **10–12.5 % larger**; from x 272.5, cap top 19 |
| Title weight | the same in light and dark: the "l" stem **2.0–2.1** | 2.25–2.36: the same weight scaled with the size (not bolder) |
| Title colour | #E8E8E8 dark, **#4D4D4D** light | the same |
| Selected sidebar row's label | **heavier than the unselected rows** (semibold): "Components" selected is 3.5 points wider (ink x 46.5–126 against 46.5–122.5) and carries about 1.3–1.4 times the ink of the same word unselected | the same weight as unselected (ink 46.5–122.5, about 1.15 times, from the white-on-accent rendering alone) |

Target: draw the title at 17 points (cap 12) and the selected row's label
in the semibold weight.

### R5.4 Scroll bars (a judge's claim, checked)

Both apps draw the same Settings scroll bars: light, knob **#7A7A7A** on a
**#F3F3F3** track; dark, #9F9F9F on #2A2A2A; x 696–707. The reference's
General pane scrolls too (knob y 55.5–176), so Ycode's General scroller is
not spurious. The knob lengths differ a little because the panes' content
heights differ (General: 120.5 against 138; Editing: 284 against 269.5).

### R5.5 Where Ycode's simulator-host settings belong

The reference has **no simulator settings in Settings**: its sidebar has
twelve panes, Components lists platform support, other components and the
installed simulator runtimes, and General has only test parallelisation.
Per-device settings (appearance, accessibility switches, location, sound)
are in **Device Hub's Settings inspector** for the selected device
(`device-hub.md` §6, §11.3); Device Hub has no settings window. Ycode's
remote simulator **host** (the Linux machine that runs the simulators,
its connection, boot and camera options) has no counterpart.

Under the owner's rules:
1. **Per-device settings** go to the hub's Settings inspector, as the
   reference keeps them (match).
2. **The host's settings** are Ycode's own element: design that page to
   the human interface guidelines in the glass language, with the same
   card, row and control anatomy as the rest of Settings, so it reads as
   part of the window.
3. **Its entry point** must not change the reference's structure:
   Components must start with "Platform Support" (R5.2), not with a
   navigation row. A fitting place is a row with Components' own anatomy
   (icon, title, subtitle such as the host's name and state, info button
   that opens the host page) at the end of "Other Components", or a
   section of its own after it. Round 4's twelve-row sidebar rule stays.
   The choice is the implementer's; the macOS and Linux IDEs make the
   same one.

### R5.6 Not settled by round 5

- Appearance in dark; the Fonts and Editor segments; the list's rows
  below Foreground; what Choose… opens.
- Components below the first "Other Components" row; what the info
  button opens; the pane with no recently used platform.
- Whether "Last used" ever shows on more than one row.

### Ycode implementation (round 5)

Both IDEs draw rows 117–124 from the shared `SettingsAppearanceLayout`,
`SettingsComponentsLayout`, `SettingsR5Palette`, `AppearanceThumbnailArt`,
`ComponentGlyph`, `ComponentsPage` and `SimulatorHostPage` (YcodeIDECore
`SettingsRound5.swift`); YcodeUI `SettingsAppearancePane.swift`,
`SettingsComponentsPane.swift`, `SettingsR5Views.swift`; ycode-ide
`SettingsPaneAppearance.swift`, `SettingsPaneComponents.swift`,
`SettingsR5Controls.swift`.

- **Appearance (rows 117–120).** The fixed top part and the list below it
  as R5.1 measures them: card 1 at y 72–160 with the "Appearance" label;
  the thumbnails at x 463, 538, 613 (67 × 44, radius 4.5), each a window
  with a title area and three dots over a wallpaper gradient and a wave
  band (light: a light window over blue; dark: a dark window over deep
  blue; System split at the middle), drawn by Ycode from the words; the
  ring 3 points wide, 1 outside; captions 11 points, cap top 139, the
  chosen one bold #262626. The preview box (x 200–690, y 170–239.5, 1-point
  #E6E6E6 border, radius 5, the theme's background) shows the sample with
  line numbers (#B8B3B4, ink ending at x 228, on the code's baselines) and
  the code from x 243 on an 18-point pitch, not wrapped; it scrolls both
  ways. The separators run x 180–710 at y 251.5 (1 point) and 304.5 (0.5);
  Theme / Fonts / Editor is Ycode's own drawing of R5.1's control (210 × 28
  centred, the divider only between two unselected segments). The list
  starts flush at y 305: Theme (39.5 tall) with a Choose… push button
  (80.5 × 24, fully rounded, #E4E4E4; it lists the themes in a menu) and
  Name (36) with the theme's name; 10 below, one 56-point row per colour
  (Foreground, the token kinds, Background, Selection, Current Line):
  the label's cap top 13 under the row's top, a slider x 421.5–624 and a
  48 × 28 well ending 10 inside the card. The slider is Ycode's meaning
  of the gradient: the colour's strength over the editor's background
  (15 % at the left end, the colour itself at the right, where the knob
  starts); the well opens a popover with the colour as #RRGGBB (empty: the
  system's), the same on both IDEs. Built-in themes show both disabled.
  Theme File (Duplicate, Delete, Import…, Export…) follows in push buttons.
  Fonts and Editor keep their rows under the same control (not captured).
- **Components (rows 121, 124).** "Platform Support" first (cap top 59,
  card from y 82): this computer ("macOS" or "Linux" with the macOS SDK's
  version, "Built-in"), then iOS, watchOS, tvOS and visionOS, each titled
  with its newest runtime's version, the runtime's size in decimal units
  ("15.94 GB") or "Not installed", and "Last used …" when the runtime
  records a use (Ycode's words: today, yesterday, n days, weeks, months or
  years ago). Rows are 51.5 + 1; the symbol (Ycode's drawings of a laptop,
  a tablet with a phone, a watch, a display on a stand, a headset, a
  cluster of sparkles, two stacked machines) in #007AFF centred on x 226;
  the title at x 251; the subtitle's baseline 15 under it; the 13-point
  info button at x 665.5. "Other Components": Predictive Code Completion
  (subtitle "Off" or the back end and model; its info button opens Editing
  ▸ Completion) and, **last, Simulator Host** (subtitle the host or "Not set
  up"; its info button opens the host page). A platform's info button
  shows its SDKs and runtimes with Simulator Runtimes….
- **The simulator-host page (row 124).** Titled Components (the sidebar
  keeps Components selected), with "‹ Components" above it. A header card
  in the system settings' style: a 40-point icon (the Simulator row icon's
  green gradient, the host symbol in white), "Simulator Host" bold with
  "Experimental", the host or "Not set up", and what the host is. Then
  Host (Host, Data folder, Link name, Ports), Runtimes (Runtime root,
  Other runtime roots, Simulator Runtimes…), Boot (Lean boot, Warm boot)
  and Advanced (ycode-simd path, Device name, Additional arguments, Keep
  services), in the card anatomy, with 220 × 22 text fields drawn by Ycode
  (radius 6, a 1-point border). Host and Data folder are the runtime
  wizard's host and the macOS run settings at once. The **camera** is a
  per-device setting and stays in the device window's Settings inspector
  (`devices.md` §Camera); the page no longer has it. On Linux the run
  settings are stored for when the Linux run path reads them (it pairs
  over Ycode's link).
- **Title and selection (rows 122, 123).** The title is **15 points**
  semibold: the reference's "General" ink is 54.5 wide with the same stem
  as Ycode's 17-point title scaled down, and a 15-point face gives that
  ink (53.7–55 wide, 12 tall from the "l" to the "G"'s overshoot, which is
  what the council's "cap height 12" measured). The selected sidebar row's
  label is semibold.
- **Back rows.** "‹ <pane>" in the accent colour, 13 points, 10 inside the
  cards' edge, on both IDEs.
- Dark values not captured are Ycode's own (`SettingsR5Palette`).

## Council round 6: the Foreground row, Choose…, Components' details, row heights (2026-11-07)

Both apps were captured with the **system in Light** (round 5: Dark), so
steps 20–22 are light; each app's own Appearance was set to Light for
23–26 and to Dark for a supplement (General, Editing, Components and
Appearance in dark). One Retina still each, the 710 × 452 window,
active; values in points from the window's top-left corner. Ycode
`0f1408a4` (a fresh instance; the Settings area scored 9.00, up from
7.33). Checklist rows 149–153 in `fidelity-council.md`.

**Owner's design rules:** where the reference has the element, match it;
where Ycode has an element the reference lacks, design it to the
platform's human interface guidelines in the OS 26+ glass language; and
Ycode's macOS and Linux IDEs look one to one.

Settled from the stills: the sidebar's base colour is the **same** in both
apps (#EDEDED light, #262627 dark; a judge's "translucent against opaque"
is not borne out); the scroll bars match (R5.4); the pane title's size,
Appearance's top card, preview and segments, and Components' card
structure now match (rows 117–119, 121–122).

### R6.1 Appearance: the Theme row and the Foreground row (light, step 23)

| Part | Reference | Ycode now |
|---|---|---|
| List card A | from y 305; Theme row to the separator at 344.5 | the same |
| Theme row's content | **5.5 below the card's top**: the label's cap top **317.5**, the button y **310.5–334.5**, so the content sits about 2.25 above the row's centre | 2.5 lower: label 320, button 313–337 (centred in the row) |
| Choose… button | x 599.5–680 (80.5 × 24), fill #E4E4E4, label #232323; a **rounded rectangle, corner radius about 6** (at its top edge the fill spans 603.5–675.5; 1.5 lower, 601–678) | the same box and colours, but a **capsule** (radius 12: the column 1.5 inside its end starts 4.5 below its top) |
| Name row | label cap top 359, the name right-aligned | the same |
| Foreground: slider track | x **421.5–624**, y 412.5–426.5 (14 tall), a gradient in **one hue** from a pale tint at the left (#EED3DB) through #F1C4D1, #ECA6BC, #DD84A2, #EA719D to the **full colour at the right (#E5538E)**, a 1-point darker edge (#CD4379) | x 425.5–621, a **grey** gradient #EAE8E9 → #A59FA1 |
| Foreground: knob | about 28 across, a white rim around **the colour at its position (#F09AB6)**, centred on x **522**: the track's middle (**50 %**) | at the right end (x 597–621), fill #7F787A |
| Foreground: colour well | a capsule x **632–680**, y 405.5–433.5 (**48 × 28**), a **3-point rim #DFDFDF** around the colour **#EF98B4** (the knob's colour), with a darker inner edge (#CF7894) | x 635–677, y 408.5–430.5 (42 × 22), **no rim**, #948D8F |

The judges saw the same pink row in the dark supplement (D02). What the
row controls was not captured (no control was moved); by its look the
slider sets how strong the theme's foreground colour is, from a pale
tint to the full colour, and the well shows the result. **Target:** the
reference's anatomy; the gradient in the theme's own foreground hue
(Ycode's default theme takes its own hue, never grey), the knob at the
theme's stored value (50 % for the default), the well showing the colour
under the knob inside a 3-point light rim; Choose… a rounded rectangle
of radius 6; the Theme row's content 2.5 higher than centred.

### R6.2 Components: the subtitle and "Last used" (light, steps 22, 26; refines R5.2)

| Part | Reference | Ycode now |
|---|---|---|
| Title | x 251 (ink from 250–251), cap top 13.5 below the row's top | the same |
| Subtitle "Built-in" | ink from **251**, aligned with the title | the same |
| Subtitle with a size ("15.94 GB", "3.81 GB") | ink from **253.5–254.5**: **3 to 3.5 right of the title** (a "3" has almost no left bearing, so this is an inset, not the glyph's shape) | ink from 250.5–251, aligned with the title |
| "Last used …" | the **subtitle's size** (cap height 8; "Last used" 36 wide), #7C7C7C, right-aligned to x 655, centred on the row | about 13 points (cap 9.5; "Last used" 39 wide), the same colour and end |
| Info button | 13 × 13, x 665.5–678.5 | the same |

R5.2's "about 13 points" for "Last used" was wrong: it is the subtitle's
size. **Target:** a size subtitle starts 3–3.5 right of the title
("Built-in" does not); "Last used" at the subtitle's size. The rows'
names and sizes are data.

### R6.3 Row heights: the "drift" (light, steps 20–21, 24–25)

Row tops (the separators) and label ink tops in two panes; the cards
start at the same y in both apps:

| Pane, row | Reference | Ycode now |
|---|---|---|
| General, card "Navigation and Files" | from 223; separators **260.5, 298.5, 337, 375**: pop-up rows of 37.5, 37, 37.5, 37 (**about 37.25 + 1**) | separators 260.5, 299, 337.5, 376: every row **37.5 + 1** |
| Their labels | 236, 274.5, 312.5, 351: **13** below each row's top | 237, 275.5, 314, 352.5: 14 below |
| General, the switch row with a two-line description | 376–442 (66): title cap top 389, description from **406.5** (17.5 below the title's top) | 377–446 (69): title 389, description from 409.5 (20.5 below) |
| Editing, single pop-up row card | 216–253.5 (37.5) | the same |
| Editing, pop-up row then switch row | 263.5–300.5 (**37**), 301.5–338 (**36.5**) | 263.5–301, 302–339.5 (37.5 each) |
| Editing, next card's switch row | 394–430.5 (36.5) | 395–432.5 (37.5) |

So the reference's rows are **content-sized**: about 37.25 for a pop-up
row (drawn as 37 or 37.5 on the half-point grid), 36.5 for a switch row,
66 for a switch with a two-line description; Ycode uses 37.5 for all,
and its labels sit 1 lower in each row, which adds up to the 1–3.5
points the judge saw further down. **Target:** those heights, the label
13 below the row's top, a description 17.5 below its title's top.

### R6.4 Items raised by one judge, checked

- **Description lengths (Sol).** Ycode's descriptions are its own words
  (the clean-room rule), so their lengths differ. Only General shows
  descriptions in the captured panes, and each takes the **same number
  of lines** as the reference's (two lines each in both apps).
  Target: keep each description to the reference's line count at the
  window's default width; no change is needed in the captured panes.
- **Sidebar "translucent" (Opus):** not borne out (above).

### R6.5 Not settled by round 6

- What the Foreground slider changes, and the rows below it; the Fonts
  and Editor segments.
- Whether the Theme row's raised content is a rule for every row whose
  card starts a scrolling list, or for this row only.

### Ycode implementation (round 6)

Both IDEs draw rows 149–153 from `SettingsRowMetrics`,
`SettingsAppearanceR6`, `SettingsComponentsR6` and the `ThemeColorRows`
hue and strength functions (YcodeIDECore `SettingsRound6.swift`); YcodeUI
`SettingsChrome.swift`, `SettingsR5Views.swift`,
`SettingsAppearancePane.swift`; ycode-ide `SettingsCards.swift`,
`SettingsR5Controls.swift`, `SettingsPaneAppearance.swift`.

- **Foreground and the colour rows (row 149).** Each row shows a **full
  colour** and a **strength**. The track runs from a pale tint (a quarter
  of the full colour over white) to the full colour, edged 1 point in the
  same gradient scaled to 0.88; the knob (28 across, a 3-point white rim)
  sits at the strength; the well (48 × 28, a 3-point #DFDFDF rim, the
  colour edged 1 point at 0.86) shows the colour under the knob. A theme
  colour with a hue is its own full colour at full strength; a system
  colour (the default theme) or a grey is shown at **50 %**, in its own
  hue or, for a grey, in **Ycode's hue for the row** (Foreground #E35590;
  the other rows' hues are listed in `ThemeColorRows.fallbackHues`), so no
  track is grey. In a user theme, moving the knob writes the knob's colour
  as the row's colour and stores the strength in the theme file
  (`strengths`, per row; absent in older files); a typed colour becomes
  the row's full colour and drops the stored strength. A built-in theme's
  rows are read-only but **drawn in full** (no dimming). What the
  reference's slider changes stays open (R6.5); this is Ycode's meaning.
- **Choose… (row 150).** The card push buttons (Choose… and the theme
  file's) are rounded rectangles of radius 6.
- **Theme row (row 151).** Its label and button sit 2.25 above the row's
  centre (the button 310.75–334.75 in a 39.5 row from 305). Name stays
  centred.
- **Components (row 152).** A subtitle that is a size (it starts with a
  digit) starts 3.25 right of the title; "Built-in", "Not installed" and
  the other words stay aligned. "Last used …" is 11 points.
- **Row heights (row 153).** A card row is 37.25 (a pop-up, a value, a
  button) or 36.5 (a switch); the label's cap top is 13 under the row's
  top and the controls are centred on the label's line; a description's
  cap top is 17.5 under the label's, and the row ends 13.75 under the
  description's last baseline (a switch with two lines: 66). A pop-up row
  with a description ends 3.5 lower (Ycode's choice: General's first card
  keeps 69.5, so the cards after it start where the reference's do, y 223).
  Navigation rows stay 44. Row edges fall on the device-pixel grid when
  laid out (`SettingsRowMetrics.snappedSeparatorTops` gives the
  reference's 260.5, 298.5, 337, 375 for General's card from 223).

## Council round 7: Appearance below the first screen, the dark Foreground row, the slider's accessibility, the thumbnails (2026-11-08)

Round 7 ran with the **system in Dark** (steps 20–22 dark; each app's own
Appearance set to Light for 23–26 and to Dark for the supplement D02–D05)
and added **X13**: Settings ▸ Appearance (system dark) with its list
scrolled **360 points** down by a 60-event scroll. The list below the
first screen was rebuilt from X13's recording (each frame matched to the
previous one and pasted into one tall picture), so every row from Theme
to Keywords is measured, not only what the after still shows. The
accessibility trees of both panes were recorded at X10 (the unscrolled
pane). 710 × 452 window, 2x; y below is the window's y **as if the list
were not scrolled** (the list's first card starts at 305, as in R6.1).
Ycode `0afb3bd7`. Checklist rows 182–185 in `fidelity-council.md`.

**Owner's design rules:** where the reference has the element, match it;
where Ycode has an element the reference lacks, design it to the
platform's human interface guidelines in the OS 26+ glass language; and
Ycode's macOS and Linux IDEs look one to one.

### R7.1 The Theme list, row by row (X13, dark)

The default theme ("Standard" in the reference, Ycode's own default in
Ycode), Theme segment. Cards are separated by **10-point gaps**
(#1F1F1F); rows inside a card by a 1-point line (#303031). Every label's
cap top is **13 below its row's top**, whatever the row's height.

| # | Row (card) | Reference: y, height | Its control | Ycode now |
|---|---|---|---|---|
| 1 | Theme (card A) | to 344.5 | Choose… (R6.1) | the same |
| 2 | Name (card A) | 345.5–381.5 (36) | the name, right-aligned | the same |
| — | gap | 381.5–391.5 | | the same |
| 3 | **Foreground** (card B) | 391.5–447.5 (**56**) | slider track x 421.5–624 (R6.1); colour button x 632–680, y 405.5–433.5 (**48 × 28**) | the same row (colours: R7.2) |
| 4 | **Background** (card B) | 448.5–504.5 (**56**) | slider: the knob at the **left end** (centre about x 436), filled with the background colour (#484748) and a white rim; to its left the track is that grey, to its right a **blue gradient** #4A5A69 → #5695C4 → #3B93CE at x 624; colour button 48 × 28 showing **#484748** (accessibility value "rgb 0.277 0.277 0.277") | **missing** |
| 5 | **Background Gradient** (card B) | 505.5–542 (**36.5**) | a switch x **644–680**, y 516–532 (**36 × 16**), **on**: blue fill #067DFF, white knob on the right | **missing** |
| — | gap | 542–552 | | |
| 6 | **Customize All Colors** (card C, alone) | 552–588.5 (36.5) | a switch 36 × 16 at x 644–680, **off**: track #393939–#3B3B3C, white knob on the left | **missing** |
| — | gap | 588.5–598.5 | | |
| 7 | **Plain Text** (card D, alone) | 598.5–645.5 (**47**) | **a colour button only**, x 632–680, **48 × 24**, centred in the row (11.5 from its top and bottom), showing #FBF2F4 | **missing** |
| — | gap | 645.5–655.5 | | |
| 8 | **Comments** (card E) | 655.5–702.5 (47) | colour button only, 48 × 24, #ACB4CE | a **56** row with a slider and a 48 × 28 well (#CCD1E0) |
| 9 | **Documentation Comments** (card E) | 703.5–750.5 (47) | colour button only, #ACB4CE | 56, slider and well (a green, #7EE397) |
| 10 | **Keywords** (card E) | 751.5–798.5 (47) | colour button only, #FF83B4 | Ycode's 6th row (after Strings and Numbers), 56, slider and well |
| … | card E continues | (the scroll ended here) | | Preprocessor Statements, Attributes, Type Names, Background, Selection, Current Line, then a note that built-in themes cannot be changed and the Theme File buttons |

So the colour-only rows are **47 + 1 = 48** on centre, the slider rows
**56 + 1 = 57**, the switch rows 36.5. The colour button in a
colour-only row is 4 points shorter than in a slider row (24 against
28), the same width (48), the same right edge (680). The reference's
order is **Foreground, Background, Background Gradient │ Customize All
Colors │ Plain Text │ Comments, Documentation Comments, Keywords, …**;
its rows after Keywords were not reached (R7.5).

What the switches do was not captured (none was pressed). By their
names and the list: Background Gradient draws the editor's background as
a gradient (on in the default theme); Customize All Colors, when on,
gives each syntax row its own full control (it was off, and the syntax
rows showed colour buttons only). Ycode's per-row strength sliders
(round 6's implementation) are therefore the reference's
Customize-All-Colors state at most, not its default.

**Target:** the reference's rows, order, cards, heights and controls as
in the table; syntax rows as colour buttons only (48 × 24) while
Customize All Colors is off; Ycode's rows that the reference lacks
(Strings, Numbers and the others it has not been seen to show) follow
the reference's order once it is captured, and until then come after
Keywords; Ycode's note and Theme File buttons stay at the end (rule 2).

### R7.2 The Foreground row in dark (D02, X13; refines R6.1)

| Part | Reference, light (23) | Reference, dark (D02) | Ycode now, light and dark alike |
|---|---|---|---|
| Track, left end → right end | a pale tint #E5C8D0, #F1C5D2 → #F1B6C7, #E9A1B8 → the knob → #E984A7, #EB759F, #E86496 → **deep #DA4982** | a **muted mid pink** #DCAAB9, #DD9FB3 → #E99EB9, #ED99B9 → the knob → #FBA7C7, #FFB5D1, #FFC0D7 → **pale #FFD4E7** | pale #F7D2E3 → #F0A4C2 → knob → #EB83AE, #E66399 → deep **#E35691** |
| Knob (50 %) and the colour button | **#EF98B4** | **#FF9EC4** (accessibility value "rgb 1 0.618 0.767") | #EE96BA |

In dark the reference's track runs the **other way in tone**: from a
muted, slightly greyed pink at the left to a pale tint at the right, and
the colour at 50 % is lighter (#FF9EC4 against light's #EF98B4). In both
appearances the right end is the one that stands out more from the
editor's background (deep on white, pale on dark), so the slider reads
as low contrast at the left and high contrast at the right (an inference
from the look; the slider was not moved, R7.3). **Target:** in dark,
the track from a muted tone of the colour (#DCAAB9 here) to a pale tint
(#FFD4E7), the knob and the button at the dark 50 % colour (#FF9EC4 for
the default theme); in light, unchanged (R6.1, met in round 7).

### R7.3 The Foreground slider in the accessibility tree (X10)

| | Reference | Ycode now |
|---|---|---|
| Elements of the Foreground row, in order | the label (static text at x 210, y 401.5, 70.5 × 16); **an element for the slider, x 421.5–624, y 401.5–437.5 (202.5 × 36)**, role *unknown*, no value; the colour **button**, x 632–680, y 405.5–433.5, value "rgb 1 0.617596 0.766966 1", actions Press and one that opens the colour panel | the label; a **colour well** "Foreground", x 631–681, y 404.5–434.5 (50 × 30), value "System"; **nothing for the slider** |
| Background row | the same three (slider element 202.5 × 36; button value "rgb 0.277317 …") | — |
| Background Gradient, Customize All Colors | switches (check boxes of subrole switch), 36 × 16, values 1 and 0 | — |

Neither app exposes the track as a slider, so the capture tool could not
move it in either (round 7 artefact 9). **Target:** expose the slider as
an element with the reference's frame (the track plus 11 above and
below: 202.5 × 36 at x 421.5, y 401.5 for Foreground) between the label
and the colour button. Its role: the reference's is *unknown* with no
value, which a screen reader cannot use; Ycode gives it the **slider**
role, the row's label as its title, and its value as a percentage, with
increment and decrement actions (rule 2: the platform's accessibility
guidelines; the frame and the order match). The colour control is a
**button** whose value is the colour, as in the reference.

### R7.4 The Appearance thumbnails (X10, 23, D02)

Three thumbnails of **67 × 61** (System x 463–530, Light 538–605, Dark
613–680; y 81–142), the selected one in the blue ring (R5.1). What they
show:

| | Reference | Ycode now |
|---|---|---|
| Composition | a **close-up of a desktop**: a thin bar along the top with a small round mark at its left; a wide translucent rounded panel at the upper left (about x 2–39, y 8–20 of the thumbnail); and the **top-left corner of a large window** filling the lower right, its top edge about **40 %** down (y 24 of 61) and its left edge about 17 in (6 in the split System thumbnail) | a **small whole window** centred on a blue background, its top edge 9 down |
| Traffic lights | **large**: about 6 across, centres about **10** apart (x 28, 38, 48 in the Light thumbnail), at about **59 %** of the height (y 36 of 61), along the window's top edge | tiny (about 2.5 across, 4–5 apart) at the window's top left, about 13 down |
| Light / Dark | the light desktop and a white window; the dark desktop (deep blue) and a near-black window; System split down the middle | the same split, Ycode's own blue backgrounds |

**Target:** the reference's composition and scale (Ycode's own drawing:
its own wallpaper and mark, no Apple artwork): a close-up of a window's
top-left corner with large traffic lights at about 59 % of the height, a
translucent panel above it and a thin bar at the top.

### R7.5 Not settled by round 7

- The rows after Keywords and the end of the list (scroll further:
  about 900 points).
- What Background Gradient and Customize All Colors change (press each),
  and what the Foreground slider changes (drag it in a duplicated theme,
  not the built-in one).
- The Fonts and Editor segments.

### Ycode implementation (round 7)

Both IDEs draw rows 182–185 from `SettingsAppearanceR7`,
`ThemeColorTrack` and `AppearanceThumbnailCloseUp` (YcodeIDECore
`SettingsRound7.swift`); YcodeUI `SettingsAppearancePane.swift`,
`SettingsR7Views.swift`; ycode-ide `SettingsPaneAppearance.swift`,
`SettingsR7Controls.swift`.

- **The list (row 182).** After card A: [Foreground, Background, Background
  Gradient] [Customize All Colors] [Plain Text] [Comments, Documentation
  Comments, Keywords, then Strings, Numbers, Preprocessor Statements,
  Attributes, Type Names, Selection, Current Line], 10 apart; the note and
  Theme File last. Slider rows 56 (the slider x 421.5–624 in a 202.5 × 36
  frame, a 48 × 28 button); colour-only rows 47 (a 48 × 24 button centred,
  x 632–680); switch rows 36.5 with the switch 10.5 under the row's top.
  Plain Text is the plain-text token colour (`tokens.identifier`, absent:
  the text colour). The two switches are stored in the theme file
  (`backgroundGradient`, absent = on; `customizeAllColors`, absent = off);
  with Customize All Colors on every colour row gets a slider. A built-in
  theme's switches are read-only and drawn in full. What Background
  Gradient changes in the editor is not implemented (R7.5: not captured).
- **Background (row 182).** Ycode's meaning: the slider tints the
  background toward blue; the track runs from the background colour (the
  knob, strength 0) through #5695C4 at 60 % to #3B93CE. The default theme's
  row shows #484748 in dark (the reference's swatch) and the editor's
  background in light. A user theme stores the strength; past 60 % the base
  is the system's.
- **Dark tracks (row 183).** In dark a slider runs muted → the colour at
  50 % → pale: the muted end half the colour and half #B4B4B4, the pale end
  the colour 55 % toward white. A grey row takes the reference's #FF9EC4 for
  Foreground and, for the other rows, its light hue with its largest
  channel at 1, 38 % toward white. A stored strength puts the theme's colour
  under the knob in both appearances. Light is round 6's track.
- **Accessibility (row 184).** The slider is an element of role slider
  (macOS `NSAccessibility` slider; Linux OpenViews'
  `accessibilitySliderElement`, a small additive modifier), titled by the
  row, value the percentage (macOS: 0–100 with "50%" as its description),
  increment and decrement by 5 %; the colour control a button whose value is
  "rgb r g b 1" (sRGB, up to six decimals); the switches switches (macOS:
  check box, subrole switch; Linux: a button with the toggle trait, value
  1 or 0).
- **Thumbnails (row 185).** R7.4's proportions applied to the 67 × 44
  picture (R5.1's size, met): the wallpaper and wave as before; a bar 3.5
  tall along the top (white 55 %, dark black 35 %) with a 2-point mark at
  x 4.5; a translucent panel x 2–39, y 5.8–14.4; the window from x 17 (6 in
  System) and y 17.5 (40 %), radius 5, its title area to 8 under the
  buttons; three buttons 6 across at x 28, 38, 48 (17, 27, 37 in System),
  y 26 (59 %). R7.4's "67 × 61" and "y 81–142" overlap the captions R5.1
  measured at 139; Ycode keeps the 44-point picture.

## Evidence

- Round 7 implementation: the Background slider's meaning and track, the
  dark track's muted and pale ends and the fallback middles, the switches'
  storage, the 5 % step, the accessibility value forms on each IDE and the
  thumbnails' proportions on the 44-point picture are Ycode's own (from
  R7.1–R7.4 and the owner's rules).
- Round 6 implementation: the colour rows' strength and full colour, the
  pale tint (a quarter over white), the edge factors, the fallback hues,
  the 50 % for system colours, the stored `strengths`, the pop-up
  description row's extra 3.5 and the size-subtitle test (a leading digit)
  are Ycode's own (from R6.1–R6.3 and the owner's rules).
- Round 5 implementation: the thumbnails' drawing, the slider's meaning,
  the colour popover, the push button's padding, the platform symbols, the
  "Last used" and size wording, the info buttons' targets, the host row's
  place and anatomy, the host page's sections and header card, the field
  style, the 15-point title and the dark colours not captured are Ycode's
  own (from R5.1–R5.5 and the owner's rules).
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
- Round 4 implementation: where Simulators goes, the light disclosure
  colour, the Simulator icon, the single-value encoding and line-ending
  pop-ups and the title's weight in light are Ycode's own.
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
- Council round 4 measurements (R4.1–R4.3): one Retina still each of the
  reference's Settings window on General and on Editing (dark, active)
  and Ycode's matching stills; colour runs, ink boxes, the icons' boxes
  from saturated pixels, stem widths from intensity profiles; measured
  in the dirty room (level 3). Symbols are described in words only.
- Council round 5 measurements (R5.1–R5.4): one Retina still each of the
  reference's Settings window on Appearance (light, the app's own
  setting), General, Editing and Components (light) and Components
  (dark), and Ycode's matching stills; colour runs, ink boxes, stem
  widths and ink areas from intensity profiles; measured in the dirty
  room (level 3). Thumbnails and symbols are described in words only.
- R5.5: where the reference keeps simulator settings is from the same
  stills and the capture's notes on the reference's menus (level 3); the
  placement of Ycode's host page is the owner's rule and Ycode's choice.
- Round 6 (R6.1–R6.4): the council round 6 Settings stills of both apps
  (710 × 452, 2x; light 20–26, the dark supplement), measured in the
  dirty room with colour runs along rows and columns (separators, button
  ends, the slider's gradient, the well's rim), ink boxes and per-row
  ink tops (level 3). The Foreground row's meaning is inferred from its
  look only.
- Round 7 (R7.1–R7.4): the council round 7 Settings stills and the X13
  recording of both apps (710 × 452, 2x, dark; light 23), measured in the
  dirty room: the scrolled list stitched from the recording by per-frame
  vertical matching, then colour runs down a column (card gaps,
  separators) and along each row (tracks, knobs, buttons, switches),
  ink tops of the labels; the accessibility trees the capture tool
  recorded at X10 (roles, frames, values, order); the thumbnails' parts
  from enlarged crops, described in words (level 3). The meanings of
  the switches and the slider are inferred from labels and looks only.
