# B4-EDITOR (1.0.0-beta.4)

Clean-room workstream for the editor items of `specs/ide/parity-inventory.md`.
Tests: `ycode/Tests/YcodeUITests/Beta4EditorTests.swift` (macOS, offscreen) and
the Linux walk `YCODE_IDE_B4EDITOR=<prefix>` (`ShellDriver+B4Editor.swift`).

| P-item | What changed | macOS | Linux |
|---|---|---|---|
| P-003 Find menu | The text view validates the Find menu through the editor instead of NSTextView's own finder; the window controller performs `performFindPanelAction:` and the find-bar actions for the focused editor when the navigator has the keyboard (⌘F opens the editor's bar); Hide Find Bar and Find Selected Text / Words in Workspace are enabled with a file open (no selection: the word at the caret) | fixed | Replace, Replace All, Replace and Find Next / Previous, Use Selection for Replace, Hide Find Bar, Find Selected Text / Words enabled and performed through the editor-action hook (`WorkspaceShellModel+FindMenu.swift`); the items that add to the selection stay disabled (no multiple selections on Linux) |
| P-054 Doc comments | Light doc comments in the comment grey #6A7084 (one table for both IDEs) | colour fixed; proportional face not done | as macOS |
| P-059 Fold ribbon | The 12-point ribbon column before the code is always there: a click places the caret at the line's start (ribbon hidden) or folds (ribbon shown); never a breakpoint | fixed | fixed (`isInRibbonColumn`) |
| P-062 Tab titles | Tabs named with the extension ("main.swift"); the tab bar reloads when a file opens, so Open in New Tab never reads "Untitled" | fixed | no editor tabs (L-136, not this item) |
| P-064 Pane Below | Lanes: a split along the tab's axis adds a lane, a split across it stacks in the focused pane's lane (nested split view) | fixed | fixed (`ShellEditorPane.lane`, `EditorPanesView`) |
| P-065 Add Editor / Editor Options | Add Editor: Tab, —, Editor Pane On Right, Editor Pane Below with ⌘T / ⌃⌘T / ⌃⌥⌘T; Editor Options: Layout ▸ Automatic / Canvas on Right / Canvas on Bottom, Minimap (checked, enabled, ⌃⇧⌘M), Authors ⌃⇧⌘A, Code Coverage enabled, Wrap Lines ⌃⇧⌘L | fixed | partly: both pull-downs with the macOS items and key equivalents (`EditorOptionsMenu.swift`); Layout, Minimap (now honoured) and Wrap Lines work; the comparison styles, Authors, Code Coverage, Invisibles, Scope Guides and Choose Workspace Theme… show disabled (no Linux feature yet) |
| P-066 No Editor | The assistant with no counterpart shows a centred "No Editor" placeholder, no text, gutter or scroll bar | fixed | no assistant editor (L-012) |
| P-068 Disk changes | Once a second an unedited editor follows its file on disk (caret and first line kept); an edited one keeps its text | fixed | already followed the disk |
| P-071 Tab focus | The source text view is never a key view (Tab cycles outside it); the empty editor takes no Tab or typing | fixed | not checked (toolbar Tab chain is P-208) |
| P-083 Quick Help Markup | `QuickHelpRun` / `QuickHelpBlock`: emphasis, strong, code voice, headings, numbered lists, code blocks with line breaks, entities and "---"; no file link for `.swiftinterface`, no documentation link for project symbols | fixed | fixed (`QuickHelpBlocks.swift`) |
| P-084 Rename | Edit box exactly on the identifier, growing with the text; other occurrences outlined (no yellow fill) | fixed | in place too (`InlineRename.swift`); the sheet only for the multi-file preview |
| P-203 Accessibility | The hidden find bar is `isHidden`; without a document the text view and its scroll view are not accessibility elements | fixed | not checked |
