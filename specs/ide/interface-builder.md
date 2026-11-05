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

## Reference Attributes inspector for UIKit kinds (observed 2026-11-05)

Observed in the reference (Xcode 27.1) by selecting each object of a test
storyboard in the Document Outline and reading the Attributes inspector
(see Evidence). This section adds to "Layout" ▸ Attributes above. It does
not change the four-inspector structure. View Controller, Label and View
were already covered by `reference-ui-4.md` §13. They are listed again
here only where this pass saw more.

### Layout of the inspector

- The inspector column is 260 pt wide.
- The inspector is a vertical stack of **sections**. Each section starts
  with a title row in the section's name. Sections are separated by a
  hairline.
- A section lists the class's own properties first, then the
  superclass's. For example, Switch shows *Switch*, then *Control*, then
  *View*.
- Each row has a right-aligned label, 77 pt wide, starting 4 pt from the
  left. The control starts at x 83 and is about 171 pt wide.
- Rows are about 22 pt apart. Check boxes stack at 18 pt.
- A number field is 153 × 21 with a 19 × 24 stepper to its right.
- A label is omitted when a check box continues the group above it.
- A small "+" at the far left of a row (x 3, 13 × 13) adds a trait
  variation for that property. In the lists below it is shown as [+].
- Rows for symbol images are hidden until an SF Symbol name is set:
  Symbol Scale, Value, and the Secondary and Tertiary palette colours.
- Selecting a scene row shows its controller's inspector. Placeholders
  (Exit, Storyboard Entry Point) and layout guides show "Not Applicable".

In the lists below:

- "pop-up (X)" means the pop-up shows X.
- "colour pop-up" is a pop-up with a colour swatch and a name.
- "number" is a number field with a stepper.
- "check “T” (on/off)" is a check box titled T, with its state.
- "icons (…; X)" is a row of icon toggles with X selected.

The values are what the inspector showed for our test objects. The XML
for those objects is the "Insert defaults" table in `library.md`. A value
that the XML did not set is the default the reference shows.

### Shared sections

- **View** (every view): Content Mode: pop-up (Scale To Fill);
  Semantic: pop-up (Unspecified); Tag: number (0); Interaction: check
  “User Interaction Enabled” (on), check “Multiple Touch” (off); Alpha:
  number (1); Background: colour pop-up (Default) [+]; Tint: colour pop-up
  (Default) [+]; Drawing: check “Opaque”, check “Hidden” [+], check “Clears
  Graphics Context” (on), check “Clips to Bounds”, check “Autoresize
  Subviews” (on); Stretching: four numbers, X 0 and Y 0, then Width 1 and
  Height 1, each with its caption under the field. For a subview, the
  last row is check “Installed” (on) [+]. A root view has no Installed
  row.
- **Control** (UIControl subclasses): Alignment: two icon rows,
  Horizontal (Leading, Left, Center, Trailing, Right, Fill) and Vertical
  (Top, Center, Bottom, Fill), each captioned below; Menu: check “Shows as
  Primary Action” (off); State: check “Selected” (off), check “Enabled”
  (on), check “Highlighted” (off); Tooltip: text field.
- **Scroll View** (scroll views, text views, table and collection views):
  Indicators: pop-up (Default Style), check “Show Horizontal Indicator”
  (on), check “Show Vertical Indicator” (on); Scrolling: check “Scrolling
  Enabled” (on), check “Paging Enabled” (off), check “Direction Lock
  Enabled” (off); Bounce: check “Bounce On Scroll” (on), check “Bounce On
  Zoom” (on), check “Bounce Horizontally” (off), check “Bounce Vertically”
  (off); Zoom: two numbers, min 1 and max 1; Content Touch: check “Delay
  Touch Down” (on), check “Can Cancel On Scroll” (on); Keyboard: pop-up
  (Do not dismiss).
- **Simulated Metrics** (every controller): Size, Top Bar, Bottom Bar,
  Keyboard: four pop-ups (Inferred). The split view controller has no
  Top Bar row.
- **View Controller** (every controller, after its own section): Title:
  text field; check “Is Initial View Controller”; Activity Name: text
  field; Layout: check “Adjust Scroll View Insets” (on), check “Hide
  Bottom Bar on Push” (off), check “Resize View From NIB” (on), check “Use
  Full Screen (Deprecated)” (off); Extend Edges: check “Under Top Bars”
  (on), check “Under Bottom Bars” (on), check “Under Opaque Bars” (off);
  Transition Style: pop-up (Cover Vertical); Presentation: pop-up
  (Automatic), check “Defines Context” (off), check “Provides Context”
  (off); Content Size: check “Use Preferred Explicit Size” (off) and two
  numbers (width, height); Key Commands: a table with + and − buttons,
  then Key and Selector fields for the selected row.
- **Bar Item** (bar button items and tab bar items, after their own
  section; it can be collapsed with Hide/Show): Title: text field; Image:
  image combo; Landscape: image combo; Accessibility: image combo (large
  content size image); Tag: number (0); check “Enabled” (on).
- **Gesture Recognizer** (every recognizer, last): State: check
  “Enabled” (on); Behavior: check “Cancels touches in view” (on), check
  “Delays touches began” (off), check “Delays touches ended” (on), check
  “Requires one touch type” (on).

Image fields ("Image", "Highlighted", "Min Image", …) are combo boxes.
They show their name as a grey placeholder and a pop-up arrow.

### Per kind

The section list comes first. Then each section the kind adds, with its
rows. Shared sections are not repeated.

- **Label** (UILabel). Sections: Label, View.
  - *Label*: Text: pop-up (Plain), text field (Label); Color: colour
    pop-up (Default (Label Color)) [+]; Font: pop-up (System 17.0) [+];
    Dynamic Type: check “Automatically Adjusts Font” (off); Alignment:
    icons (Left, Center, Right, Justified, Natural; Natural); Lines:
    number (1); Behavior: check “Enabled” (on), check “Highlighted” (off);
    Tooltip: check “Shows Expansion Text” (off); Baseline: pop-up (Align
    Baselines); Line Break: pop-up (Truncate Tail); Strategy: pop-up
    (Standard); Autoshrink: pop-up (Fixed Font Size), check “Tighten
    Letter Spacing” (off); Sizing Rule: pop-up (Typographic); Highlighted:
    colour pop-up (Default) [+]; Shadow: colour pop-up (Default) [+];
    Shadow Offset: two numbers (0, −1).
- **Button, Gray / Tinted / Filled Button, Pull Down Button, Pop Up
  Button** (UIButton). Sections: Button, Control, View.
  - *Button*: Type: pop-up (System); Style: pop-up (Plain / Gray /
    Tinted / Filled); Title: pop-up (Plain), text field (Button), font
    pop-up (shows "No Font" with a font button); Subtitle: pop-up (Plain),
    text field; Alignment: pop-up (Default); Foreground: colour pop-up
    (Default); for Gray, Tinted and Filled only, Background: colour pop-up
    (Default); Image: image combo; a **Background Configuration**
    sub-heading, then Background: pop-up (Default), Corner Style: pop-up
    (Default), Content Insets: pop-up (Default); Drawing: check “Shows
    Activity Indicator” (off); Role: pop-up (Normal); Menu: check
    “Selection as Primary Action” (off; on for Pop Up Button); Pointer:
    check “Interaction Enabled” (off); Accessibility: check “Adjusts Image
    Size” (off); Shadow Offset: two numbers (0, 0) captioned Width and
    Height; check “Reverses On Highlight” (off); Drawing: check “Shows
    Touch On Highlight” (off), check “Highlighted Adjusts Image” (on),
    check “Disabled Adjusts Image” (on); Line Break: pop-up (Truncate
    Middle); Drag and Drop: check “Spring Loaded” (off); Behavior: pop-up
    (Automatic).
  - Pull Down and Pop Up Button differ in *Control*: “Shows as Primary
    Action” is on.
- **Segmented Control** (UISegmentedControl). Sections: Segmented
  Control, Control, View.
  - *Segmented Control*: Style: pop-up (Plain); Selected Tint: colour
    pop-up (Default) [+]; State: check “Momentary” (off); Drag and Drop:
    check “Spring Loaded” (off); Segments: number (2); Segment: pop-up
    ("Segment 0 - First": index and title); Title: text field (First);
    Image: image combo; Behavior: check “Enabled” (on), check “Selected”
    (on); Content Offset: two numbers (0, 0).
  - Control's alignment defaults are Left and Top here.
- **Text Field** (UITextField). Sections: Text Field, Control, View.
  - *Text Field*: Text: pop-up (Plain), text field; Color: colour pop-up
    (Default (Label Color)) [+]; Font: pop-up (System 14.0) [+]; Dynamic
    Type: check “Automatically Adjusts Font” (off); Alignment: icons (Left,
    Center, Right, Justified, Natural; Natural); Placeholder: text field;
    Background: image combo [+]; Disabled: image combo [+]; Border Style:
    icons (None, Line, Bezel, Round; Round); Clear Button: pop-up (Never
    appears), check “Clear when editing begins” (off); Min Font Size:
    number (17), check “Adjust to Fit” (on); Sizing Rule: pop-up
    (Typographic); then the **Text Input Traits** group, the same as for
    Search Bar below.
  - Control's alignment defaults are Left and Center here.
- **Slider** (UISlider). Sections: Slider, Control, View.
  - *Slider*: Value: number (0.5); Minimum: number (0); Maximum: number
    (1); Min Image: image combo [+]; Max Image: image combo [+]; Min Track:
    colour pop-up (Default) [+]; Max Track: colour pop-up (Default) [+];
    Thumb Tint: colour pop-up (Default) [+]; Events: check “Continuous
    Updates” (on); Behavior: pop-up (Automatic).
- **Switch** (UISwitch). Sections: Switch, Control, View.
  - *Switch*: Title: text field; Style: pop-up (Automatic); State: pop-up
    (On); On Tint: colour pop-up (Default) [+]; Thumb Tint: colour pop-up
    (Default) [+].
- **Activity Indicator View** (UIActivityIndicatorView). Sections:
  Activity Indicator View, View.
  - *Activity Indicator View*: Style: pop-up (Medium); Color: colour
    pop-up (Default) [+]; Behavior: check “Animating” (off), check “Hides
    When Stopped” (off; the XML had no `hidesWhenStopped`).
- **Progress View** (UIProgressView). Sections: Progress View, View.
  - *Progress View*: Style: pop-up (Default); Progress: number (0.5);
    Progress Tint: colour pop-up (Default) [+]; Track Tint: colour pop-up
    (Default) [+]; Progress (image): image combo [+]; Track (image): image
    combo [+].
- **Page Control** (UIPageControl). Sections: Page Control, Control,
  View.
  - *Page Control*: Pages: two numbers, number of pages (3) and current
    page (0); Behavior: check “Hides for Single Page” (off), check “Defers
    Page Display” (off); Tint Color: colour pop-up (Default) [+]; Current
    Page: colour pop-up (Default) [+].
- **Stepper** (UIStepper). Sections: Stepper, Control, View.
  - *Stepper*: Value: number (0); Minimum: number (0); Maximum: number
    (100); Step: number (1); Behavior: check “Autorepeat” (on), check
    “Continuous” (on), check “Wrap” (off).
- **Color Well** (UIColorWell). Sections: Color Well, Control, View.
  - *Color Well*: Color: colour pop-up (Default) [+], check “Supports
    Alpha” (on); Title: text field.
- **Paste Control** (UIPasteControl). Sections: Paste Control, Control,
  View.
  - *Paste Control*: Display Mode: pop-up (Icon and Label); Corner Style:
    pop-up (Default); Radius: number (empty); a **Base Colors**
    sub-heading, then Foreground: colour pop-up (Default), Background:
    colour pop-up (Default); Target: a button for choosing the anchor
    view.
- **Horizontal / Vertical Stack View** (UIStackView). Sections: Stack
  View, View.
  - *Stack View*: every row has [+]: Axis: pop-up (Horizontal /
    Vertical); Alignment: pop-up (Fill); Distribution: pop-up (Fill);
    Spacing: an editable pop-up (combo-like) (0); check “Baseline
    Relative” (off).
- **Table View** (UITableView). Sections: Table View, Scroll View, View.
  - *Table View*: Content: pop-up (Dynamic Prototypes); Prototype Cells:
    number (1, the count of prototypes); Style: pop-up (Plain); Separator:
    pop-up (Default) and colour pop-up (Default) [+]; Separator Inset:
    pop-up (Automatic); Selection: pop-up (Single Selection); Editing:
    pop-up (No Selection During Editing); Drag and Drop: check “Spring
    Loaded” (off); a **Section Index** sub-heading, then Display Limit:
    number (0), Text, Background, Tracking: colour pop-ups (Default) [+].
- **Table View Cell** (UITableViewCell). Sections: Table View Cell,
  View.
  - *Table View Cell*: Style: pop-up (Custom); Identifier: text field;
    Selection: pop-up (Default); Accessory: pop-up (None); Editing Acc.:
    pop-up (None); Focus Style: pop-up (Default); Indentation: two numbers,
    level (0) and width (10); check “Indent While Editing” (on), check
    “Shows Re-order Controls” (off); Separator Inset: pop-up (Automatic).
- **Image View** (UIImageView). Sections: Image View, View.
  - *Image View*: Image: image combo [+]; Highlighted: image combo [+];
    State: check “Highlighted” (off); Accessibility: check “Adjusts Image
    Size” (off).
- **Collection View** (UICollectionView). Sections: Collection View,
  Scroll View, View.
  - *Collection View*: Items: number (count of prototype cells); Layout:
    pop-up (Flow); Scroll Direction: pop-up (Vertical); Accessories: check
    “Section Header”, check “Section Footer” (each on when the matching
    `collectionReusableView` exists); Prefetch: check “Prefetching
    Enabled” (on); Drag and Drop: check “Spring Loaded” (off).
- **Collection View Flow Layout** (outline child of a collection view).
  Section: Collection View Flow Layout, with Scroll Direction: pop-up
  (Vertical).
- **Collection View Cell, Collection Reusable View**. Sections:
  Collection Reusable View, View.
  - *Collection Reusable View*: Identifier: text field.
- **Text View** (UITextView). Sections: Text View, Scroll View, View.
  - *Text View*: Text: pop-up (Plain), text field (the text); Color:
    colour pop-up [+]; Font: pop-up (System 14.0) [+]; Dynamic Type: check
    “Automatically Adjusts Font” (off); Alignment: icons (as Label;
    Natural), check “Find & Replace” (off); Behavior: check “Editable”
    (on), check “Selectable” (on); Data Detectors: check “Phone Number”,
    “Link”, “Address”, “Calendar Event”, “Shipment Tracking Number”,
    “Flight Number”, “Lookup Suggestion” (all off); Text Layout: pop-up
    (Default); then Text Input Traits, with Capitalization: Sentences.
- **Scroll View** (UIScrollView). Sections: Scroll View, View.
- **Date Picker** (UIDatePicker). Sections: Date Picker, Control, View.
  - *Date Picker*: Preferred Style: pop-up (Compact); Mode: pop-up (Date
    and Time); Locale: pop-up (Default); Interval: pop-up; Date: pop-up
    (Current Date); check “Minimum Date” (off) with a date field; check
    “Maximum Date” (off) with a date field.
- **Picker View** (UIPickerView). Sections: View only.
- **Visual Effect View with Blur, … with Blur and Vibrancy**
  (UIVisualEffectView). Sections: Visual Effect View, View.
  - *Visual Effect View*: Blur Style: pop-up (Regular); check “Vibrancy”
    (off).
  - The inner vibrancy view: “Vibrancy” on, then Vibrancy Style: pop-up
    (Default).
  - The content views are plain Views. Their View section starts with
    Content Mode Center and Multiple Touch and Clips to Bounds on.
- **Map Kit View** (MKMapView). Sections: Map View, View.
  - *Map View*: Configuration: pop-up (Standard); Elevation: check
    “Realistic” (off); Emphasis: check “Muted” (off); Shows: check
    “Traffic” (off), “Compass” (on), “Scale” (off), “User Location”
    (off), “Points of Interest” (on), “User Tracking” (off); Pitch Button:
    pop-up (Hidden); Allows: check “Zooming”, “Scrolling”, “Rotating”, “3D
    View” (all on); a **Point of Interest** sub-heading, then Filter:
    pop-up (None).
- **MetalKit View** (MTKView). Sections: MTKView, View.
  - *MTKView*: a **Render Target** sub-heading; Clear Color: colour
    pop-up; Clear Depth: number (1); Clear Stencil: number (0); Color
    Pixel Format: pop-up (BGRA8 Unorm); Depth Stencil Pixel Format: pop-up
    (Depth 32 Float); Sample Count: number (1); Preferred FPS: number
    (60); check “Enable setNeedsDisplay” (off), check “Paused” (off),
    check “AutoResize Drawable” (on).
- **GLKit View** (GLKView). Sections: GLK View, View.
  - *GLK View*: Color Format: pop-up (RGBA8888); Depth Format, Stencil
    Format, Multisample: pop-ups (None); check “Enable setNeedsDisplay”
    (off).
- **SceneKit View** (SCNView). Sections: SceneKit View, View.
  - *SceneKit View*: Scene: combo box; Rendering API: pop-up (Default);
    Behavior: check “Allow camera control” (off); Rendering: check “Enable
    jittering”, “Enable multisampling”, “Enable default lighting” (off);
    Animations: check “Play” (off), check “Loop” (on).
  - **ARKit SceneKit View** has the same section without the Rendering
    API row.
- **SpriteKit View** (SKView) and **ARKit SpriteKit View**. Sections:
  SpriteKit View, View.
  - *SpriteKit View*: Scene: combo box; Frame Rate: number (empty);
    Rendering: check “Asynchronous” (on), “Allow Transparency” (off),
    “Cull Non-Visible Nodes” (on), “Ignore Sibling Order” (off);
    Animation: check “Paused” (off).
- **Web View (deprecated)** (UIWebView). Sections: Web View, View.
  - *Web View*: Scaling: check “Scales Page To Fit” (off); Data
    Detectors: as Text View, with Phone Number on; Options: check “Allows
    Inline Playback” (on), “Playback Requires User Action” (on), “Playback
    Allows AirPlay” (on), “Suppress Incremental Rendering” (off),
    “Keyboard Display Requires User Action” (on); Pagination: pop-up
    (Unpaginated).
- **WebKit View** (WKWebView). Sections: Web View, View.
  - *Web View*: User Agent: text field; App Name: text field;
    Interaction: check “Back/Forward Gestures” (off), “Find & Replace”
    (off); Selection: pop-up (Default); Display: check “Incremental
    Rendering” (on), “Link Preview” (on); Min Font Size: number (0);
    Media: check “AirPlay” (on), “Inline Playback” (off),
    “Picture-in-Picture” (on); a second Interaction row (user action
    required): check “For Audio Playback” (off), “For Video Playback”
    (off); Data Detectors: the seven check boxes (all on); JavaScript:
    check “Enabled” (on), “Can Auto-open Windows” (off).
- **RealityKit AR View** (ARView). Sections: AR View, View.
  - *AR View*: Rendering: one check box for ray-traced shadows on older
    systems (off).
- **Room Capture View** (RoomCaptureView). Sections: Room Capture View,
  View.
  - *Room Capture View*: Shows: check “Captured Model” (off).
- **Core Location Button** (CLLocationButton). Sections: Core Location
  Button, Control, View.
  - *Core Location Button*: Icon: pop-up (None); Label: pop-up (None);
    Font Size: number (empty); Corner Radius: number (empty).
- **Navigation Bar** (UINavigationBar). Sections: Navigation Bar, View.
  - *Navigation Bar*: Appearances: check “Standard”, “Compact”, “Scroll
    Edge”, “Compact Scroll Edge” (off); Style: pop-up (Default), check
    “Translucent” (on), check “Prefers Large Titles” (off); Bar Tint:
    colour pop-up (Default) [+]; Shadow, Back, Back Mask: image combos
    [+]; a **Title Text Attributes** sub-heading, then Title Font: font
    pop-up, Title Color: colour pop-up (Default), Title Shadow: colour
    pop-up (Default) with an offset pop-up (Default Position); a **Large
    Title Text Attributes** sub-heading, with the same three rows.
- **Toolbar** (UIToolbar). Sections: Toolbar, View.
  - *Toolbar*: Appearances: the four check boxes as Navigation Bar; Style:
    pop-up (Default), check “Translucent” (on); Bar Tint: colour pop-up
    (Default) [+].
- **Tab Bar** (UITabBar). Sections: Tab Bar, View.
  - *Tab Bar*: Appearances: check “Standard”, “Scroll Edge” (off);
    Background, Shadow, Selection: image combos [+]; Image Tint: colour
    pop-up (Default) [+]; Style: pop-up (Default), check “Translucent”
    (on); Bar Tint: colour pop-up (Default) [+]; Item Positioning: pop-up
    (Automatic).
- **Search Bar** (UISearchBar). Sections: Search Bar, View.
  - *Search Bar*: Text, Placeholder, Prompt: text fields; Search Style:
    pop-up (Default); Bar Style: pop-up (Default), check “Translucent”
    (on); Bar Tint: colour pop-up (Default) [+]; Background, Scope Bar:
    image combos [+]; Search Text: offset pop-up (Default Position);
    Background: offset pop-up (Default Position); Behavior: check
    “Enabled” (on); Capabilities: check “Shows Search Results Button”,
    “Shows Bookmarks Button”, “Shows Cancel Button”, “Shows Scope Bar”
    (all off); Scope Titles: a table with + and −.
  - Then the **Text Input Traits** group, the same for Text Field and
    Text View: Content Type: pop-up (Unspecified); Capitalization: pop-up
    (None); Correction, Smart Dashes, Smart Insert, Smart Quotes, Spell
    Checking, Keyboard Type, Keyboard Look, Return Key: pop-ups
    (Default); check “Auto-enable Return Key” (off); check “Secure Text
    Entry” (off).
- **View, Container View** (UIView). Sections: View only.
- **Controllers.** Each has the sections Simulated Metrics, its own
  section (if any), then View Controller.
  - **View Controller**, **Tab Bar Controller**, **Hosting Controller**:
    no own section.
  - **Navigation Controller**: Bar Visibility: check “Shows Navigation
    Bar”, check “Shows Toolbar” (off); Hide Bars: check “On Swipe”, “On
    Tap”, “When Keyboard Appears”, “When Vertically Compact” (all off).
  - **Table View Controller**: Selection: check “Clear on Appearance”
    (on); Refreshing: pop-up (Disabled).
  - **Collection View Controller**: Selection: check “Clear on
    Appearance” (on).
  - **Split View Controller**: Style: pop-up (Unspecified (Discouraged));
    Compact Width: check “Use Separate View Controller” (off), check
    “Present Primary With Gesture” (on); Display Mode: pop-up (Automatic);
    Behavior: pop-up (Automatic); Primary Edge: pop-up (Leading); Primary
    Style: pop-up (None).
  - **Page View Controller**: Navigation: pop-up (Horizontal); Transition
    Style: pop-up (Page Curl); Page Spacing: number (0); Spine Location:
    pop-up (Min), check “Double Sided” (off).
  - **GLKit View Controller**: Preferred FPS: number (30); check “Pause
    on Deactivate” (on); check “Resume on Activate” (on).
  - **AVKit Player View Controller**: check “Shows Playback Controls”
    (on); Video Gravity: pop-up (Resize Aspect).
  - **Look Around View Controller**: Navigation: check “Enabled” (off);
    Shows: check “Road Labels” (off); a **Point of Interest**
    sub-heading, then Filter: pop-up (None).
  - **Storyboard Reference**: one section only, Storyboard Reference:
    Storyboard: combo box (the storyboard name); Referenced ID: text
    field; Bundle: text field.
- **Object** (NSObject): one section, Object, with two combo boxes (class
  and module) and check “Inherit Module From Target” (off).
- **First Responder**: one section, First Responder, with a User Defined
  actions table with + and −.

### Non-view objects

- **Bar Button Item** (UIBarButtonItem). Sections: Bar Button Item, Bar
  Item.
  - *Bar Button Item*: Style: pop-up (Bordered for a plain item; Plain
    for the fixed and flexible spaces); System Item: pop-up (Custom /
    Fixed Space / Flexible Space); Tint: colour pop-up (Default) [+];
    Drawing: check “Hidden” (off); Drag and Drop: check “Spring Loaded”
    (off); Menu: check “Selection as Primary Action” (off).
- **Navigation Item** (UINavigationItem). One section, Navigation Item:
  Title: text field (Title); Prompt: text field; Style: pop-up
  (Navigator); Back Button: text field, check “Left Items Supplement”
  (off); Large Title: pop-up (Automatic); Identifier: text field.
- **Tab Bar Item** (UITabBarItem). Sections: Tab Bar Item, Bar Item.
  - *Tab Bar Item*: Badge: text field with a colour pop-up (Default);
    System Item: pop-up (the system item, e.g. Favorites, More);
    Selected Image: image combo; Title Position: pop-up (Default
    Position); Drag and Drop: check “Spring Loaded” (off).
- **Menu** (UIMenu). One section, Menu: Title: text field; Identifier:
  text field; Options: check “Display Inline”, “Destructive”, “Single
  Selection” (all off). Inline Section Menu is a Menu with Display Inline
  on.
- **Command** (UICommand). One section, Command: Title: text field; HUD
  Title: text field; Property List: text field; a Key Equivalent row;
  Attributes: check “Disabled”, “Destructive”, “Hidden” (off); State:
  pop-up (Off / On); Localize: pop-up (Automatic); Alternates: a table
  with + and −, with Modifier and Selector fields for the selected
  alternate.
- **Gesture recognizers.** Each has its own section(s), then Gesture
  Recognizer:
  - Tap: Recognize: two numbers, taps (1) and touches (1); Pointer: check
    “Primary Button” (on), “Secondary Button” (off).
  - Pinch: Scale: number (1).
  - Rotation: Rotation: number (0, degrees).
  - Swipe: Swipe: pop-up (the direction, Right); Touches: number (1).
  - Pan: Touches: two numbers, minimum (1) and maximum (empty); Scroll
    Types: check “Continuous (trackpad)”, “Discrete (scroll wheel)”
    (off).
  - Screen Edge Pan: its own Edges section (check Top, Left, Bottom, Right,
    two per row, all off), then the Pan section, then Gesture Recognizer.
  - Long Press: Min Duration: number (0.5); Recognize: two numbers, taps
    (0) and touches (1); Tolerance: number (10).
  - Custom Gesture Recognizer: only Gesture Recognizer.

## Reference outline details (observed 2026-11-05)

- Rows are about 20 pt high. Each nesting level indents 16 pt.
- An object whose element has a `userLabel` shows that label.
- Exit and Storyboard Entry Point rows are synthesized. They are not
  written to the file, and they get IDs that the reference generates, in
  the `xxx-xx-xxx` form. A GLKit view used as a controller's view had no
  safe-area guide in our file. The reference added one (`viewLayoutGuide
  key="safeArea"` with a generated ID), showed it in the outline, and
  wrote it on save.
- Under a collection view the order is: the section header/footer
  reusable view, the cells, then the flow layout.
- Under a button with a menu, the Menu row holds its Command rows.
- Bar items appear under their bar. A navigation item is named by its
  title. A bar button item is named by its title, or by its system item
  ("Fixed Space", "Flexible Space"). A tab bar item is named by its title
  or system item ("Favorites", "More").

### Outline icons (described, not copied)

Every icon is a 16 pt glyph to the left of the name.

- **Scenes**: a yellow rounded square with a lighter top strip carrying
  three small marks. A white glyph inside names the controller kind:
  - plain rectangle: View Controller, Tab Bar Controller, Hosting
    Controller, Storyboard Reference;
  - left chevron: Navigation Controller;
  - stacked rows: Table View Controller;
  - three columns: Collection View Controller;
  - two panes: Split View Controller;
  - a page: Page View Controller;
  - a circle with a cross: GLKit View Controller;
  - a play triangle: AV Player View Controller.
- **Controller row**: a yellow circle with a white mark. **First
  Responder**: an orange square with a white "1". **Exit**: an orange
  square with an arrow leaving a box. **Storyboard Entry Point**: a pale
  blue circle with a right-pointing arrow.
- **Generic views** (View, Container View, Content View, the root view):
  a white rounded square with a thin blue-grey border. **Safe Area** and
  other layout guides: a grey square drawn as a dashed outline.
- **Text**:
  - Label: black square, white bold "L".
  - Text Field: black square, white "T" in a field-like box.
  - Text View: pale blue square with text lines.
- **Buttons**: a square with a "B".
  - Button, Pull Down and Pop Up Button: dark square, blue "B".
  - Gray Button: grey square, blue "B".
  - Tinted Button: tinted blue square, blue "B".
  - Filled Button: solid blue square, white "B".
- **Controls**:
  - Segmented Control: dark square with two small numbered segments.
  - Slider: a horizontal track with a white round knob.
  - Switch: a green capsule with a white knob on the right.
  - Activity Indicator: grey spokes in a circle.
  - Progress View: a thin bar, blue then grey.
  - Page Control: pale blue square with a row of dots.
  - Stepper: a minus and a plus side by side.
  - Color Well: a multicoloured ring.
- **Containers**:
  - Stack views: pale blue squares split by a vertical line (horizontal
    stack) or a horizontal line (vertical stack).
  - Image View: pale blue square with a small landscape picture.
  - Scroll View: pale blue square with a scroll bar at the right edge.
  - Visual Effect View: a frosted grey-blue square.
- **Pickers**: Date Picker and Picker View are black squares with tiny
  wheel text.
- **Framework views**, each a coloured rounded square with a white
  glyph:
  - Map Kit View: blue, map with a route.
  - MetalKit View: teal.
  - GLKit View: blue, circle with a cross.
  - SceneKit View: red, cube.
  - SpriteKit View: violet.
  - ARKit SceneKit and ARKit SpriteKit View: red and violet, with an AR
    mark.
  - WebKit View: blue compass.
- **Bars**:
  - Navigation Bar: dark bar with a blue chevron.
  - Toolbar: dark bar with blue items.
  - Tab Bar: dark bar with blue tab icons.
  - Search Bar: a magnifying glass.
- **Gesture recognizers**: blue round glyphs.
  - Tap: a dot with a ring.
  - Pinch: two dots on a diagonal.
  - Rotation: curved arrows.
  - Swipe: a dot with motion lines.
  - Pan: a dot with a trail.
  - Screen Edge Pan: a dot against an edge line.
  - Long Press: a dot with a thick ring.
- **Object**: a blue-grey cube.

## Canvas drawing and overview (reference, 2026-11-05: OPEN)

In this environment, every Interface Builder document in the reference
showed the banner "An internal error occurred. Editing functionality may
be limited." The canvas did not render the views:

- The device frame was drawn as a dark rounded rectangle.
- Each view was drawn only as its selection tint.
- No auto-layout warnings were computed.

The reference's design-time rendering helper (it uses an Interface
Builder simulator device set that was empty here) evidently did not
start. So these remain OPEN:

- how each control draws at rest, and its measured size;
- the intrinsic sizes the reference uses for "Size to Fit Content" and
  for misplaced-frame warnings;
- the canvas overview: what a click or drag does, and the visible-area
  outline.

The canvas's accessibility tree showed only:

- the canvas;
- two scroll bars;
- the bottom bar (Show Library, Accessibility, Appearance, Orientation,
  Layout, Devices, the device toggle, zoom, and the trailing buttons).

It showed no overview or minimap control. Scene title strips above the
device frame show the scene's dock icons (controller, First Responder,
Exit) as three small coloured squares.

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
- Reference Attributes inspector (2026-11-05): every object of a test
  storyboard we wrote (one object of each UIKit Library kind, plus the
  controllers, bar items, menus and gesture recognizers) was selected
  through the accessibility API in Xcode 27.1, running in the background,
  and its inspector's accessibility tree was read: section titles, row
  labels, control roles, titles and values (level 3). A few inspectors
  were captured as still images in the git-ignored dirty folder, to check
  which rows are hidden. No image is reproduced here.
- Outline row names, IDs of synthesized rows, child order and the 16 pt
  indent: the same accessibility reads (level 3). Outline icons:
  described in words from window stills (level 3). No artwork was copied.
- Canvas: the internal-error banner and the unrendered canvas were
  observed directly (level 3). The empty Interface Builder simulator
  device set was read with `simctl --set … list` (level 3).
- OPEN QUESTION: the drawing at rest and the sizes of each control on the
  canvas, the overview interaction, and the Attributes inspector rows
  that appear only after an image or symbol is set. Their sizes and
  ordering were not measured. These need a reference whose canvas
  renders, and, for the overview, pointer input in the foreground.

