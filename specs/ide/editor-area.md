# Editor area: tabs, splits, history, assistant

Ycode module: `YcodeUI` (`EditorAreaController`, `NavigationHistory`,
`Counterparts`, `WorkspaceWindowController`).

## Tabs

- The editor area holds tabs. A tab bar (one button per tab, titled with
  the file name without its extension, with the file icon; the tooltip
  shows the name and the group path) appears with two or more tabs, or
  always after View ▸ Show Editor Tab Bar (reference-ui-2.md §8).
- View ▸ Pin Editor Tab (⇧⌘P) pins the current tab (a pin icon at its
  right end). Opening a file from the navigator replaces the current tab
  unless it is pinned; then the file opens in a new tab to its right.
- File ▸ Close "<file>" (⌃⌘W) empties the focused editor ("No
  Selection"); Close Editor Pane (⌃⇧⌘W, disabled with one pane) closes the
  focused split; Close Window (⇧⌘W); Close Project / Package (⌃⌥⌘W) closes
  the workspace. Duplicate Editor Tab and Open in New Tab (⌥⌘O, the
  navigator's selected file) add a tab.
- The window opens with nothing selected: an empty editor whose jump bar
  reads "No Selection" (reference-ui.md §2).
- File ▸ New ▸ Tab (⌘T): a new tab after the current one, showing the
  same file.
- File ▸ Close Tab (⌘W): closes the tab; with one tab it closes the
  window.
- Navigate ▸ Show Previous Tab (⇧⌘[) / Show Next Tab (⇧⌘]): wrap around
  (reference-ui.md §1 puts them in Navigate).

## Splits

- File ▸ New ▸ Editor Pane On Right (⌃⌘T): a new editor right of the
  focused one, showing the same file; Editor Pane Below (⌃⌥⌘T) stacks it
  below. (Correction 2026-10-19: these are File ▸ New items, not Editor
  menu items; `reference-ui-5.md` §2.2. The Editor menu's Layout ▸ places
  the editor relative to the canvas, §2.7.) The
  first split of a tab chooses the direction for that tab.
- Splits share the space equally when added; each has its own jump bar.
- File ▸ Close Editor Pane (⌃⇧⌘W) closes the focused split (not the last).
- Focus: the editor whose text view became first responder. Commands
  (find, open from the navigator, history) act on the focused editor.

## History

Each editor keeps its own list of the files it showed. Opening a file
appends it (dropping forward entries; reopening the current file adds
nothing). Navigate ▸ Show Previous / Next Location in History (⌃⌘← / ⌃⌘→) and the
toolbar's Go Back / Go Forward buttons move through it without recording.
The jump bar has no history buttons (`reference-ui-5.md` §6.1).

## Counterparts and the assistant

Counterparts of a file, in order (same folder first, then by path):

1. header (`h`, `hpp`, `hh`) ↔ implementation (`m`, `mm`, `c`, `cpp`,
   `cc`, `cxx`) with the same base name;
2. `Foo.swift` ↔ `FooTests.swift`;
3. a class file (`Foo.swift`, `.h`, `.m`) ↔ the storyboards and xibs whose
   `customClass="Foo"` appears; a storyboard/xib ↔ the class files of its
   custom classes.

- The jump bar of the focused editor shows a "Counterparts" pull-down
  when the file has any; choosing one opens it (in the assistant when it
  is shown).
- Editor ▸ Assistant (⌃⌥⌘↩) toggles an assistant editor right of the
  others. It shows the first counterpart of the focused editor's file and
  follows it when another file is opened; with none it shows "No
  Counterparts". Close Editor in the assistant closes it.

## Assistant modes

**Correction (2026-10-19).** The reference has no Editor ▸ Assistant
Mode submenu. Modes are chosen only in the mode pop-up of the assistant's
jump bar, whose list is `reference-ui-4.md` §16. The assistant's jump bar
starts with a close button, then the mode pop-up (`reference-ui-5.md`
§6.1). The table below is Ycode's mapping of the modes it can fill; Manual,
Top Level Objects, Includes and Tests are Ycode's earlier names and give
way to the §16 names (Includes and Included By, Test Classes and Test
Callers; Manual and Top Level Objects are dropped).

Before the correction: Editor ▸ Assistant Mode ▸ (Counterparts, Manual,
Top Level Objects, Includes, Tests), and a mode pop-up at the start of the
assistant's jump bar listing the modes available for the focused file;
the assistant's related-files pull-down is titled with the mode and lists
its files.

| Mode | Offered for | Files |
|---|---|---|
| Counterparts | every file | §Counterparts |
| Manual | every file | none; the assistant keeps what was opened in it |
| Top Level Objects | `.storyboard`, `.xib` | class files (`.swift`, `.h`, `.m`) named after the `customClass` of objects directly inside an `objects` element |
| Includes | C-family files | workspace files named by `#include "…"` / `#import "…"` (angle-bracket includes are skipped) |
| Tests | `.swift`, `.m`, `.mm`, `.h`, `.c`, `.cpp` | `<Base>Tests` files, and test files (`…Tests`/`…Test`) whose text contains the file's first declared type |

The assistant shows the mode's first file (Counterparts, Top Level
Objects, Includes, Tests), or "No <mode>" when there is none; a mode not
offered for the file falls back to Counterparts.

Code Review moved to ⌥⇧⌘↩ so the assistant keeps ⌃⌥⌘↩ (no two commands
share a shortcut).

## Evidence

- Commands, shortcuts and the assistant/counterparts behavior: Apple's
  published Xcode keyboard-shortcut reference and Xcode Help (level 1).
- Counterpart pairing rules: Xcode Help's description of counterparts
  (level 1); the test-file and storyboard rules are Ycode's reading.
- Tab bar look, when it shows, pinning, and the close commands (⌘W closes
  the tab): `specs/ide/reference-ui-2.md` §8 (level 3).
- With one tab, ⌘W is Close Window: `specs/ide/reference-ui-3.md` §5.2
  (level 3).
- Code Review ⌥⇧⌘↩ and Assistant ⌃⌥⌘↩ are the reference's own
  shortcuts; the assistant's modes are `reference-ui-4.md` §16; split
  commands, history buttons and the assistant jump bar:
  `reference-ui-5.md` §2.2, §6.1 (level 3).
- OPEN QUESTION: whether split history is shared with the tab.
