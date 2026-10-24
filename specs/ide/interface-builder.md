# Interface Builder documents

Ycode module: `YcodeUI` (`XMLSource`, `IBDocument`, `IBEditing`,
`InterfaceBuilderController`, `IBCanvasView`). Selecting a `.storyboard`
or `.xib` file opens it. The editor area shows the Document Outline and
the canvas; the inspectors are in the window's inspector area.

## File format (as studied)

Both are XML. The root element is `document`, with `type` (contains
`Storyboard` for storyboards; `…Cocoa.XIB` / `…CocoaTouch.XIB` for xibs),
`version`, `toolsVersion`, `targetRuntime` (`MacOSX.Cocoa`,
`iOS.CocoaTouch`, …), `useAutolayout`, and for storyboards
`initialViewController` (an object ID).

- Storyboards: `scenes` → `scene` (`sceneID`) → `objects` → the scene's
  objects (a view or window controller with `sceneMemberID="viewController"`,
  placeholders such as the first responder, …), then
  `<point key="canvasLocation" x= y=/>`.
- Xibs: `objects` → top-level objects (placeholders with
  `placeholderIdentifier`, `userLabel` such as "File's Owner", then views,
  windows, custom objects).
- Objects: elements with an `id`. The element name is the kind (`view`,
  `button`, `textField`, `label`, `viewController`, …); `key` names its
  role in the parent (`view`, `cell`, `contentView`); `customClass`,
  `customModule`, `userLabel` are optional.
- Views: `<rect key="frame" x y width height/>` in the parent's
  coordinates; children under `subviews`. In `MacOSX` runtimes the
  origin is the parent's bottom-left; in the others it is the top-left.
- Constraints under the view that holds them: `constraint` with
  `firstItem` (absent = the holding view), `firstAttribute`, `relation`
  (absent = equal; `greaterThanOrEqual`, `lessThanOrEqual`),
  `secondItem`, `secondAttribute`, `constant`, `multiplier`, `priority`,
  `id`.
- Connections under an object's `connections`: `outlet` (`property`,
  `destination`), `outletCollection`, `action` (`selector`, `target`),
  `segue` (`kind`, `destination`).
- Value elements without an `id` (`color`, `font`, `fontDescription`,
  `autoresizingMask`, keyed elements) are properties of their object.

## Layout

- Editor area: a jump bar strip showing the full path to the selection,
  the Document Outline (left, with a Filter at its bottom; the canvas bar
  toggles it) and the canvas. Each scene has a title bar naming its
  controller above a device-shaped frame drawn by Ycode; the initial scene
  has the entry arrow (`reference-ui-4.md` §11).
- Canvas bottom bar: outline toggle, +, issues, appearance, orientation,
  layout; the device pop-up; zoom "− n% +"; update frames, align, pin (Add
  Constraints), resolve, embed in (§11.5). Align, Resolve, Embed and
  Layout menus are present but their items are disabled; orientation and
  device are stored state only.
- Inspector area: while an IB document is shown, four inspectors follow
  File / History / Quick Help: Identity, Attributes, Size, Connections
  (seven tabs in all). Their contents follow `reference-ui-4.md` §13, which
  supersedes the per-inspector rows below where they differ.
  Opening the document selects Attributes; showing any other file removes
  the four.
  - Identity: Class (`customClass`, else the element name), Module
    (`customModule`), Storyboard ID (`storyboardIdentifier`), Object ID,
    Label.
  - Attributes: for views, Title, Placeholder (text fields), Alignment
    (pop-up: left, center, right, justified, natural), Enabled and
    Hidden check boxes; then every attribute, value element and cell
    attribute, read-only.
  - Size: X, Y, Width, Height fields (the stored frame), autoresizing
    flags, the constraints that mention the view.
  - Connections: outlets, outlet collections, sent actions, triggered
    segues, then connections from other objects ("Referencing").

## Outline

Scenes ("<first object> Scene") → objects → view hierarchy (cells
included), and a "Constraints" row under each view holding constraints,
one row per constraint written as
`Item.attribute = Other.attribute × multiplier + constant @priority`.
Names: `userLabel`, else the content (text or title) with a kind badge
("Hello" with an L badge for a label, "Tap" with a B badge for a button),
else the custom class or the element name in words. Under a view the
order is Safe Area, the subviews, then Constraints; at scene level First
Responder, Exit, and a synthetic "Storyboard Entry Point" row for the
initial scene (`reference-ui-4.md` §11.2). The older constraint-row
names (`Item.attribute = …`) remain.

## Canvas

- Each scene's top-level view is drawn as a white box with every subview
  as a labeled rectangle (frames converted to top-left). A view whose
  parent is a window (`contentRect` present) gets a 28-point title bar
  with three circles drawn above it.
- Placement: a scene with `canvasLocation` is centred on that point
  (canvas points, y down); others go right of the previous one. The whole
  layout is shifted so it starts 200 points from the canvas edge.
- Segues: a curve with an arrow head from the source scene's right edge to
  the destination scene's left edge, with a small circle at its middle.
- Entry point: a thick arrow into the left edge of the scene that holds
  `initialViewController`.
- Zoom: pinch, ⌘+ / ⌘− (×1.25 per step), ⌘0 zoom to fit (never above
  100%); range 10%–400%.
- Selecting: a click selects the deepest view under the point (also from
  the outline); the selection gets an accent outline and eight handles
  (non-root views).

## Editing

Every edit makes new file bytes by splicing only what changes, writes the
file at once, rebuilds the model, and keeps the selection. ⌘Z / ⇧⌘Z
(and `undo()` / `redo()`) restore earlier bytes exactly.

- Attribute edits replace the value in place, or append
  ` name="value"` before the start tag's `>` / `/>`, or remove
  ` name="value"`; values are escaped (`&amp; &lt; &gt; &quot; &#10;`).
- Frame: the `x`, `y`, `width`, `height` of `<rect key="frame">`. Numbers
  are written whole (`120`), zero as `0.0`, otherwise with up to two
  decimals (`24.5`). Moving (drag the body) and resizing (drag a handle)
  round to whole points and convert back to the parent's stored
  coordinates (bottom-left in `MacOSX` runtimes).
- Title: `text` (labels, or when present), else `title` on the object,
  else on its cell, else the `normal` `state` element's `title`.
- Placeholder: the cell's `placeholderString`, else `placeholder`; empty
  removes it.
- Hidden: `hidden="YES"` on the view; visible removes it. Enabled:
  `enabled="NO"` on the cell (or the control); enabled removes it.
- Alignment: the cell's `alignment`, else `textAlignment`.

Invariant (tested): after an edit only the touched lines differ; undoing
every edit gives the original bytes.

## Inserting objects

With an IB document shown, the Library (⇧⌘L) adds an Objects tab: Label,
Button, Text Field, Image View, View, Stack View, each with an icon drawn
by Ycode's code and a one-line description. Double-click (or Return)
inserts into the selected view, centered; dragging a row (pasteboard type
`io.ycode.ib-object`, the object's name) onto the canvas inserts into the
view under the drop point, centered there, at the object's default size.

- The new element is appended as the last child of the parent's
  `subviews`, indented one level (four spaces) deeper than `<subviews>`;
  without `subviews`, a `subviews` element is added right after the
  parent's `<rect key="frame">`.
- Elements written: per runtime, the matching kind (`label`, `button`
  with `<state key="normal" title="Button"/>`, `textField`, `imageView`,
  `view`, `stackView` for iOS; `textField` + `textFieldCell`, `button` +
  `buttonCell`, `imageView` + `imageCell`, `customView`, `stackView` for
  macOS), each with `translatesAutoresizingMaskIntoConstraints="NO"`, an
  `id`, and a frame.
- IDs: three, two and three characters from `[A-Za-z0-9]` joined by `-`
  (`atN-xg-zXb`), the form observed in files; unused in the document.

## Structure edits

- ⌫ (canvas or outline) deletes the selected constraint, else the
  selected view (not a root view or top-level object). Deleting a view
  removes its element's whole lines, every `constraint` whose
  `firstItem`/`secondItem` is the view or one of its descendants, and
  outlets/segues (`destination`) and actions (`target`) pointing at them.
  A `subviews`, `constraints` or `connections` element left empty is
  removed whole.
- Dragging a view row onto another view row in the Document Outline moves
  it: its lines are cut, re-indented to the new parent's `subviews` (made
  if missing, after the frame) and appended last; constraints that name it
  are removed; its frame is rewritten so it keeps its place on the canvas.
  A view cannot move into itself or a descendant, nor to another scene.

## Constraints

- Constraint rows in the outline can be selected (and deleted).
- Size inspector: each constraint mentioning the view, with an editable
  constant; writing 0 removes `constant`.
- Editor ▸ Add New Constraints… (a popover for the selected view): four
  "Spacing to nearest neighbor" boxes (top, leading, bottom, trailing)
  with values prefilled from the current layout, Width, Height
  (prefilled from the frame), Horizontally / Vertically in Container.
  The nearest neighbor on a side is the closest sibling lying wholly on
  that side whose span overlaps the view's, else the superview.
- Written forms (IDs as in §Inserting):
  - top / leading: `<constraint firstItem="V" firstAttribute="top"
    secondItem="N" secondAttribute="bottom|top" constant="…" id="…"/>`
    (`top`/`leading` when N is the superview, else the neighbor's
    `bottom`/`trailing`);
  - bottom / trailing to the superview: `<constraint
    firstAttribute="bottom" secondItem="V" secondAttribute="bottom"
    constant="…"/>` (no `firstItem`: the holding view); to a sibling:
    `firstItem="N" firstAttribute="top|leading" secondItem="V"
    secondAttribute="bottom|trailing"`;
  - centering: `firstItem="V" firstAttribute="centerX|centerY"
    secondItem="S" secondAttribute="centerX|centerY"` (no constant);
  - width / height: `<constraint firstAttribute="width" constant="…"/>`
    in the view's own `constraints`.
  - `constant` is omitted when 0. Spacing and centering go in the
    superview's `constraints` (appended; made after `subviews` if
    missing), size in the view's own (made after its `subviews`, else its
    frame). The view gets `translatesAutoresizingMaskIntoConstraints="NO"`.

## Evidence

- Format: sample files written for the tests and files from open-source
  projects, studied as a format (level 2); class, element and attribute
  names are interop identifiers. The ID form is observed in such files
  (level 2).
- Inspector set and order, canvas zoom commands, the Library's object
  drag: Apple's public Interface Builder documentation (level 1).
- OPEN QUESTION: the reference outline's naming rules; flipped NSView
  subclasses in macOS documents (Ycode treats every macOS view as
  bottom-left); whether `canvasLocation` is the scene's centre (Ycode
  assumes so); the attribute order and default attributes the reference
  writes for new objects, and whether it writes `0.0` / fractions as
  Ycode does; how IDs are generated (character set and uniqueness scope);
  segue drawing details; size classes and trait variations; which
  element holds each new constraint and its attribute order in the
  reference; whether moving a view keeps compatible constraints; the
  popover's exact layout and its "Constrain to margins" option.
