# Property list editor

Ycode modules: `YcodePlist` (`PropertyListDocument`, `PropertyListItem`),
`YcodeUI` (`PlistTree`, `PlistEditorController`).

Opening a `.plist` or `.entitlements` file shows the property-list editor
in the editor area: an outline with the columns Key, Type, Value under a
Root row, and + / − buttons.

- Types: Array, Dictionary, Boolean, Data, Date, Number, String (Number
  covers `<integer>` and `<real>`).
- Editor menu while this editor is focused: Add Item; Value Type ▸ (Array,
  Dictionary, Boolean, Data, Date, Number, String); Raw Keys and Values
  (`reference-ui-5.md` §2.8). The Key, Type and Value column headers sort
  the view.
- Key: editable for dictionary children (a key already used in the same
  dictionary is refused); array children show "Item N".
- Value: editable for non-containers; text must parse for the type
  (Number: integer, else real; Boolean: YES/NO/true/false/1/0; Date:
  ISO 8601; Data: hex bytes, `<…>` optional), otherwise the edit is
  refused. Containers show "(N items)".
- Type: a pop-up; changing it converts what it can (numbers ↔ booleans by
  zero/non-zero, text parsed) and otherwise uses an empty or zero value.
- + inserts a String item after the selected row ("New item", made unique
  with " - 2", " - 3" …), or as the first child when a container is
  selected; − removes the selected row.
- Every edit is written at once, in the file's format.

## Reading and writing

XML property lists are read with an XML parser that keeps dictionary key
order, and written in this layout: the XML declaration, the
`-//Apple//DTD PLIST 1.0//EN` doctype line, `<plist version="1.0">`, one
element per line indented with tabs, `<key>` lines before values,
`<true/>`/`<false/>`, `<dict/>`/`<array/>` for empty containers, `<data>`
as base64 in lines of 68 characters indented like its tags, dates as
`YYYY-MM-DDThh:mm:ssZ`, and `&`, `<`, `>` escaped. A file written by
Foundation's XML property-list writer reads and writes back byte for
byte. Binary property lists (`bplist` magic, format `bplist00`) are read
and written by Ycode's own reader and writer, which keep the file's
dictionary key order (`reference-ui-5.md` §11.2; `reference-ui-3.md` §2).
The writer lays the objects out as Foundation's binary writer does
(depth-first, shared strings, numbers, dates and data, one object per
Boolean occurrence), so a binary list written by Foundation reads and
writes back byte for byte. Known limits: 4-byte reals are written back as
8-byte reals, UID objects (keyed archives) are not read, and a container
referenced twice is written twice.

## Evidence

- The property list format and DTD: Apple's public documentation
  (level 1); XML layout and byte-exact round trip verified against
  Foundation's writer (level 3).
- The editor's columns, types and +/− behavior: Xcode Help
  ("Edit property lists") (level 1).
- The editor keeps the file's key order, shows integers as "Number" and
  containers as "(N items)": `specs/ide/reference-ui-3.md` §2 (level 3).
  Info.plist keys show readable names in the target Info tab (same spec
  §1.7).
- The Editor menu items: `reference-ui-5.md` §2.8 (level 3). Readable
  versus raw key names: the editor offers both, switched by Editor ▸ Raw
  Keys and Values (same section).
- Binary layout: the public `bplist00` format of Core Foundation's
  open-source binary property list code (level 1); byte-for-byte round
  trips verified against Foundation-written lists (level 3).
- OPEN QUESTION: whether saving keeps the key order, and the exact
  new-item naming.
