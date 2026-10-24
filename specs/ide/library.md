# Library

Ycode module: `YcodeUI` (`LibraryContent`, `LibraryController`,
`SourceEditorController.insertLibraryText`).

View ▸ Show Library (⇧⌘L) shows the Library: a floating utility panel
near the top of the workspace window that hides when Ycode is inactive.
View ▸ Open Library (⌥⇧⌘L) opens it so that it stays open. Correction
(2026-10-19): the reference's default toolbar has no Library button; the
"+" there is the Add Editor menu (`reference-ui-5.md` §2.4, §4).

## Layout

A segmented control (Snippets, Symbols, and Objects while an Interface
Builder document is the focused editor), a filter field, a list, and a
detail area showing the selected item's text.

- Objects: the UIKit or AppKit object kinds Ycode can insert into the
  focused document (the insertion rules are in `interface-builder.md`
  "Inserting objects"), with their class names; Ycode's own icons.

- Snippets: Ycode's own code snippets (written for Ycode from scratch):
  title in bold, then summary and language. Filter matches title, summary
  or language, case-insensitively.
- Symbols: a hand-written list of generic symbol names, each drawn through
  the public `NSImage(systemSymbolName:accessibilityDescription:)`; names
  the running system cannot draw are skipped. Filter matches the name.
  The list leaves out names of Apple products and logos (tested).

## Inserting

- Double-click (or Return on the selected row) inserts into the source
  editor at the selection, as one undoable edit. A snippet inserts its body;
  a symbol inserts its name as a string literal (`"star.fill"`). After a
  snippet, its first `<#…#>` placeholder is selected so typing replaces it.
  With no editable file shown, nothing is inserted (a beep).
- Dragging a row carries the same text as a plain string, so dropping it
  in the editor inserts it at the drop point.

Placeholders use the `<#text#>` token form documented for code snippets;
Ycode does not yet draw them as tokens or move between them with Tab.

## Evidence

- Correction 2026-10-19: no Library button in the default toolbar; Open Library ⌥⇧⌘L (`reference-ui-5.md` §2.4, level 3).
- Panel, shortcut and the double-click/drag behavior: Apple's public
  documentation for the Library and code snippets (level 1).
- Symbol drawing: the public AppKit API (level 1). The names were typed by
  hand from public documentation; no Apple file was read.
- OPEN QUESTION: the reference's other Library tabs (views, modifiers,
  colors, media), user-defined snippets and their storage, the exact
  insertion form for symbols, and placeholder token drawing.
