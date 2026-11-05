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

## Reference Objects library for UIKit documents (observed 2026-11-05)

Observed in the reference (Xcode 27.1) with an iOS storyboard and an iOS
xib open. This section is what B3-IB needs to grow the Objects tab to the
full UIKit set (#84). It adds to the sections above and does not replace
them.

### Panel

- **Opening it.** The canvas bottom bar has a toggle button, "Show
  Library", at its left end next to the outline toggle. Pressing it opens
  the Library as a small floating panel (a dialog-style window, not a
  sheet) above the workspace window. The panel closed by itself when the
  focused document changed (from one storyboard to a xib).
- **Size.** 681 × 504 pt with details shown. With details hidden it is
  272 × 504 pt and keeps the same horizontal centre. The panel could not
  be resized through accessibility (its size is not settable).
- **Header** (y measured from the panel's top, x from its left):
  - filter icon, 34 × 34 at (15, 11);
  - search field, 557 × 36 at (61, 10) (148 wide with details hidden);
  - two 18 × 18 toggle buttons at (616, 19) and (644, 19): "Switch to
    Icon View" / "Switch to List View", then "Hide Details" / "Show
    Details" (the help text names the action the click will do).
- **Tabs.** A row of four icon tabs, about 42 × 25 each, centred
  horizontally at y 61–86: Objects, Image, Color, Symbols. There is no
  Snippets tab while an Interface Builder document is focused.
- **List** (left column): from y 94 to the bottom, 272 wide (255 of
  content plus a 17 pt scroller).
  - List view: rows 255 × 48; a 34 × 34 icon at (17, 7) and the name at
    (59, 15), 180 × 18.
  - Icon view: four columns of cells about 64 × 48 (the first is 63),
    each holding only the 34 × 34 icon centred, 7 pt from the cell top.
    The name is not shown.
  - The list is flat. There are no group headers or sections.
- **Detail area** (right of the list, from x 273):
  - name, one line, 390 × 21 at (282, 103);
  - subtitle, one line, 16 high at (282, 123), in the form
    `ClassName: one-line summary`;
  - long description, in a scrollable text area 381 × 339 at
    (278, 152).

  Ycode writes its own summaries and descriptions. The reference's text
  is not copied.
- **Selection.** The detail area shows the selected item. Filtering
  selects the first match.
- **Drag preview, inserting.** Not observed: dragging and double-clicking
  need the pointer and a foreground Xcode (see Evidence).

### Search

The search field filters the list. This was observed after the text was
committed. Whether the list also filters on every keystroke was not
checked.

- Matching ignores case.
- A query matches an item when each whitespace-separated word of the
  query is a substring of the item's **name** or of its **class name**
  (the part of the subtitle before the colon). The words may match in any
  order and anywhere. For example, "Page Control" also finds "Page View
  Controller".
- The summary and the description are not searched.

| Query | Matches |
|---|---|
| `UISwitch`, `uiswitch` | Switch |
| `UIButton` | the six UIButton items (not Core Location Button, not the bar button items) |
| `ton` | every item whose name contains "Button" |
| `stack view` | Horizontal Stack View, Vertical Stack View |
| `map`, `MKMapView` | Map Kit View |
| `tap` | Tap Gesture Recognizer |
| `toggle`, `spinner`, `checkbox`, `picture`, `html`, `list`, `grid`, `Presents`, `on and off` | nothing |

### Object list

The order is the list order. "Element" is the XML element that the
reference reads and writes for the kind. Each element name was checked by
loading it in the reference (level 3). "Class" is the subtitle's class
name.

| # | Name | Class | Element (iOS) |
|---|---|---|---|
| 1 | Label | UILabel | `label` |
| 2 | Button | UIButton | `button` + `buttonConfiguration style="plain"` |
| 3 | Gray Button | UIButton | `button` + `buttonConfiguration style="gray"` |
| 4 | Tinted Button | UIButton | `button` + `buttonConfiguration style="tinted"` |
| 5 | Filled Button | UIButton | `button` + `buttonConfiguration style="filled"` |
| 6 | Pull Down Button | UIButton | `button showsMenuAsPrimaryAction="YES"` with a `menu key="menu"` |
| 7 | Pop Up Button | UIButton | as 6, plus `changesSelectionAsPrimaryAction="YES"` |
| 8 | Segmented Control | UISegmentedControl | `segmentedControl` |
| 9 | Text Field | UITextField | `textField` |
| 10 | Slider | UISlider | `slider` |
| 11 | Switch | UISwitch | `switch` |
| 12 | Activity Indicator View | UIActivityIndicatorView | `activityIndicatorView` |
| 13 | Progress View | UIProgressView | `progressView` |
| 14 | Page Control | UIPageControl | `pageControl` |
| 15 | Stepper | UIStepper | `stepper` |
| 16 | Color Well | UIColorWell | `colorWell` |
| 17 | Paste Control | UIPasteControl | `pasteControl` |
| 18 | Horizontal Stack View | UIStackView | `stackView` (no `axis`) |
| 19 | Vertical Stack View | UIStackView | `stackView axis="vertical"` |
| 20 | Table View | UITableView | `tableView` |
| 21 | Table View Cell | UITableViewCell | `tableViewCell` (inside `prototypes`) |
| 22 | Image View | UIImageView | `imageView` |
| 23 | Collection View | UICollectionView | `collectionView` |
| 24 | Collection View Cell | UICollectionViewCell | `collectionViewCell` (inside `cells`) |
| 25 | Collection Reusable View | UICollectionReusableView | `collectionReusableView` (`key="sectionHeaderView"` / `"sectionFooterView"`) |
| 26 | Text View | UITextView | `textView` |
| 27 | Scroll View | UIScrollView | `scrollView` |
| 28 | Date Picker | UIDatePicker | `datePicker` |
| 29 | Picker View | UIPickerView | `pickerView` |
| 30 | Visual Effect View with Blur | UIVisualEffectView | `visualEffectView` + `blurEffect` |
| 31 | Visual Effect Views with Blur and Vibrancy | UIVisualEffectView | a `visualEffectView` + `blurEffect` whose content view holds a second `visualEffectView` + `vibrancyEffect` |
| 32 | Map Kit View | MKMapView | `mapView` |
| 33 | MetalKit View | MTKView | `mtkView` |
| 34 | GLKit View | GLKView | `glkView` |
| 35 | SceneKit View | SCNView | `sceneKitView` |
| 36 | SpriteKit View | SKView | `skView` |
| 37 | ARKit SceneKit View | ARSCNView | `arscnView` |
| 38 | ARKit SpriteKit View | ARSKView | `arskView` |
| 39 | Web View (deprecated) | UIWebView | `webView` |
| 40 | WebKit View | WKWebView | `wkWebView` + `wkWebViewConfiguration key="configuration"` |
| 41 | RealityKit AR View | ARView | `arView` |
| 42 | Room Capture View | RoomCaptureView | `roomCaptureView` |
| 43 | Core Location Button | CLLocationButton | `clLocationButton` |
| 44 | Navigation Bar | UINavigationBar | `navigationBar` (items under `items`) |
| 45 | Navigation Item | UINavigationItem | `navigationItem` |
| 46 | Toolbar | UIToolbar | `toolbar` (items under `items`) |
| 47 | Bar Button Item | UIBarButtonItem | `barButtonItem` |
| 48 | Bar Button Item Group | UIBarButtonItemGroup | `barButtonItemGroup` |
| 49 | Fixed Space Bar Button Item | UIBarButtonItem | `barButtonItem style="plain" systemItem="fixedSpace"` |
| 50 | Flexible Space Bar Button Item | UIBarButtonItem | `barButtonItem style="plain" systemItem="flexibleSpace"` |
| 51 | Tab Bar | UITabBar | `tabBar` (items under `items`) |
| 52 | Tab Bar Item | UITabBarItem | `tabBarItem` |
| 53 | Search Bar | UISearchBar | `searchBar` |
| 54 | Menu Command | UICommand | `command` |
| 55 | Main Menu | UIMenu | `menu` (storyboards only) |
| 56 | Sub Menu | UIMenu | `menu` |
| 57 | Inline Section Menu | UIMenu | `menu` (Display Inline option set) |
| 58 | View | UIView | `view` |
| 59 | Container View | UIContainerView | `containerView` (storyboards only) |
| 60 | View Controller | UIViewController | `viewController` |
| 61 | Storyboard Reference | UIViewController | `viewControllerPlaceholder` (storyboards only) |
| 62 | Navigation Controller | UINavigationController | `navigationController` (+ `navigationBar key="navigationBar"`) |
| 63 | Table View Controller | UITableViewController | `tableViewController` (+ `tableView key="view"`) |
| 64 | Collection View Controller | UICollectionViewController | `collectionViewController` (+ `collectionView key="view"`) |
| 65 | Tab Bar Controller | UITabBarController | `tabBarController` (+ `tabBar key="tabBar"`) |
| 66 | Split View Controller | UISplitViewController | `splitViewController` |
| 67 | Page View Controller | UIPageViewController | `pageViewController` |
| 68 | Hosting View Controller | UIHostingController | `hostingController` |
| 69 | GLKit View Controller | GLKViewController | `glkViewController` (+ `glkView key="view"`) |
| 70 | AVKit Player View Controller | AVPlayerViewController | `avPlayerViewController` |
| 71 | Look Around View Controller | MKLookAroundViewController | `lookAroundViewController` |
| 72 | Object | NSObject | `customObject` |
| 73 | Tap Gesture Recognizer | UITapGestureRecognizer | `tapGestureRecognizer` |
| 74 | Pinch Gesture Recognizer | UIPinchGestureRecognizer | `pinchGestureRecognizer` |
| 75 | Rotation Gesture Recognizer | UIRotationGestureRecognizer | `rotationGestureRecognizer` |
| 76 | Swipe Gesture Recognizer | UISwipeGestureRecognizer | `swipeGestureRecognizer` |
| 77 | Pan Gesture Recognizer | UIPanGestureRecognizer | `panGestureRecognizer` |
| 78 | Screen Edge Pan Gesture Recognizer | UIScreenEdgePanGestureRecognizer | `screenEdgePanGestureRecognizer` |
| 79 | Long Press Gesture Recognizer | UILongPressGestureRecognizer | `pongPressGestureRecognizer` (sic: the file format spells it with a "p") |
| 80 | Custom Gesture Recognizer | UIGestureRecognizer | `gestureRecognizer` |

- **Storyboards vs. xibs.** A storyboard shows all 80 items. A xib shows
  79 items. It leaves out Main Menu, Container View and Storyboard
  Reference, and it adds Window (UIWindow, element `window`) between
  Inline Section Menu and View, and External Object (NSObject, a
  `placeholder` object) between Object and Tap Gesture Recognizer. The
  other items keep the same order.
- **Outline names of new objects.** An object with no `userLabel` and no
  content is named by its kind in words, as in the Name column. For
  example, Exit, First Responder, Safe Area, Content Layout Guide, Frame
  Layout Guide, Content View, Collection View Flow Layout, Storyboard
  Entry Point.

### Insert defaults

**Status.** Inserting from the Library could not be observed. Every
insert path in the reference (drag, double-click, Return in the list)
needs a foreground Xcode and pointer or key input, and this pass ran in
the background only (see Evidence). So the "before and after" diff for
each object is still OPEN. What is known:

1. **Canonical form (observed, level 3).** When the reference saves a
   document, each view element is written with its attributes in this
   order:
   - `opaque`, `clipsSubviews`, `multipleTouchEnabled`,
     `userInteractionEnabled`, `contentMode`;
   - kind-specific leading attributes (`showsMenuAsPrimaryAction`);
   - `horizontalHuggingPriority`, `verticalHuggingPriority`;
   - `fixedFrame`;
   - `contentHorizontalAlignment`, `contentVerticalAlignment`;
   - the other kind attributes (`buttonType`, `lineBreakMode`,
     `changesSelectionAsPrimaryAction`, `value`, `minValue`, `maxValue`,
     `on`, `style`, `progress`, `numberOfPages`, `maximumValue`,
     `datePickerMode`, …);
   - `translatesAutoresizingMaskIntoConstraints`, `id`, `userLabel`.

   The children are written in this order:
   1. `rect key="frame"`;
   2. `autoresizingMask key="autoresizingMask"`;
   3. value elements (`fontDescription`, `nil key="textColor"`, …);
   4. kind children (`menu`, `state`, `buttonConfiguration`, `segments`,
      `items`, `textInputTraits`, layout guides, `contentView`,
      `blurEffect`, …);
   5. `subviews`;
   6. `viewLayoutGuide key="safeArea"`;
   7. `color key="backgroundColor"`;
   8. `constraints`.

   The reference also does the following when it saves:
   - A view with `translatesAutoresizingMaskIntoConstraints="NO"` and no
     autoresizing mask gets `<autoresizingMask key="autoresizingMask"
     flexibleMaxX="YES" flexibleMaxY="YES"/>` right after its frame.
   - A `button` without `lineBreakMode` gets
     `lineBreakMode="middleTruncation"`.
   - A `command`'s `state="on"` is written as `menuElementState="on"`.
   - A `textView`'s `<string key="text">` is written as a `text`
     attribute.
   - A `navigationBar` inside a navigation controller loses its frame.
   - A `glkView` used as a controller's view gains a safe-area guide.
   - It writes `<device id="retina6_12" orientation="portrait"
     appearance="light"/>` after the root element.
   - It drops `<deployment identifier="iOS"/>` from `dependencies` and
     adds a `capability` for each feature in use ("UIMenu",
     "collection view cell content view").
   - It writes `<!--Controller Title-->` comments before scenes.
   - It sets `toolsVersion="25098"` and the Cocoa Touch plug-in version
     `25073`.
2. **Typical insert values (files written by earlier Xcode versions,
   level 2).** These are the values that Xcode documents carry for fresh
   objects. Use them until the insert diff is observed:

   | Kind | Attributes and children | Size seen |
   |---|---|---|
   | Label | `opaque="NO" userInteractionEnabled="NO" contentMode="left" horizontalHuggingPriority="251" verticalHuggingPriority="251" text="Label" textAlignment="natural" lineBreakMode="tailTruncation" baselineAdjustment="alignBaselines" adjustsFontSizeToFit="NO"`; `fontDescription type="system" pointSize="17"`, `nil key="textColor"`, `nil key="highlightedColor"` | 42 × 21 (older) |
   | Button (all four styles) | `opaque="NO" contentMode="scaleToFill" contentHorizontalAlignment="center" contentVerticalAlignment="center" buttonType="system" lineBreakMode="middleTruncation"`; `state key="normal" title="Button"`, `buttonConfiguration key="configuration" style="…" title="Button"` | OPEN |
   | Text Field | `opaque="NO" contentMode="scaleToFill" contentHorizontalAlignment="left" contentVerticalAlignment="center" borderStyle="roundedRect" textAlignment="natural" minimumFontSize="17"`; `fontDescription type="system" pointSize="14"`, `textInputTraits key="textInputTraits"` | width varies × 34 |
   | Slider | `opaque="NO" contentMode="scaleToFill" contentHorizontalAlignment="center" contentVerticalAlignment="center" value="0.5" minValue="0.0" maxValue="1"` | 118 × 30 (older) |
   | Switch | `opaque="NO" contentMode="scaleToFill" horizontalHuggingPriority="750" verticalHuggingPriority="750" contentHorizontalAlignment="center" contentVerticalAlignment="center" on="YES"` | 51 × 31 (older; 49 × 31 in still older files) |
   | Segmented Control | `opaque="NO" contentMode="scaleToFill" contentHorizontalAlignment="left" contentVerticalAlignment="top" segmentControlStyle="plain" selectedSegmentIndex="0"`; `segments` with `segment title="First"`, `segment title="Second"` | about 121–131 × 31–32 |
   | Progress View | `opaque="NO" contentMode="scaleToFill" verticalHuggingPriority="750" progress="0.5"` | width varies × 4 |
   | Activity Indicator View | `opaque="NO" contentMode="scaleToFill" horizontalHuggingPriority="750" verticalHuggingPriority="750" style="medium"` | 37 × 37 for the large style; medium OPEN |
   | Image View | `clipsSubviews="YES" userInteractionEnabled="NO" contentMode="scaleAspectFit" horizontalHuggingPriority="251" verticalHuggingPriority="251"` | 240 × 128 (older) |
   | Text View | `clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="scaleToFill" textAlignment="natural"`; `color key="backgroundColor"`, `fontDescription type="system" pointSize="14"`, `color key="textColor"`, `textInputTraits key="textInputTraits" autocapitalizationType="sentences"` | OPEN |
   | Stack View | `opaque="NO" contentMode="scaleToFill"` (+ `axis="vertical"`), `spacing` when non-zero | OPEN |
   | Table View | `clipsSubviews="YES" contentMode="scaleToFill" alwaysBounceVertical="YES" dataMode="prototypes" style="plain" separatorStyle="default" rowHeight="-1" estimatedRowHeight="-1" sectionHeaderHeight="-1" estimatedSectionHeaderHeight="-1" sectionFooterHeight="-1" estimatedSectionFooterHeight="-1"`; `color key="backgroundColor"` | OPEN |
   | Table View Cell | `clipsSubviews="YES" contentMode="scaleToFill" preservesSuperviewLayoutMargins="YES" selectionStyle="default" indentationWidth="10"`; `autoresizingMask key="autoresizingMask"`; `tableViewCellContentView key="contentView"` (`opaque="NO" clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="center" preservesSuperviewLayoutMargins="YES" insetsLayoutMarginsFromSafeArea="NO" tableViewCell="<cell id>"`) | row height 43.67 (older) |
   | Collection View | `clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="scaleToFill" dataMode="prototypes"`; `collectionViewFlowLayout key="collectionViewLayout" automaticEstimatedItemSize="YES" minimumLineSpacing="10" minimumInteritemSpacing="10"` with `size key="itemSize" 128 × 128`, `size key="headerReferenceSize" 0 × 0`, `size key="footerReferenceSize" 0 × 0`, `inset key="sectionInset"` all 0; `cells` | OPEN |
   | Collection View Cell | `opaque="NO" clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="center"`; `collectionViewCellContentView key="contentView"` (`opaque="NO" clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="center" insetsLayoutMarginsFromSafeArea="NO"`) | 128 × 128 (older) |
   | Scroll View | `clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="scaleToFill"`; `viewLayoutGuide key="contentLayoutGuide"`, `viewLayoutGuide key="frameLayoutGuide"` | OPEN |
   | Visual Effect View | `opaque="NO" contentMode="scaleToFill"`; `view key="contentView" opaque="NO" clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="center" insetsLayoutMarginsFromSafeArea="NO"`, `blurEffect style="regular"` | OPEN |
   | WebKit View | `contentMode="scaleToFill"`; `wkWebViewConfiguration key="configuration"` holding `audiovisualMediaTypes key="mediaTypesRequiringUserActionForPlayback" none="YES"` and `wkPreferences key="preferences"` | OPEN |
   | Search Bar | `contentMode="redraw"`; `textInputTraits key="textInputTraits"` | width × 44 (older) |
   | Navigation Bar | `contentMode="scaleToFill"`; `items` with one `navigationItem title="Title"` | width × 44 (older) |
   | Tab Bar | `contentMode="scaleToFill"`; `items` with two `tabBarItem`s (system items in older files) | width × 49 (older) |
   | Long Press Gesture Recognizer | `allowableMovement="10" minimumPressDuration="0.5"` | — |
   | Swipe / Pan / Screen Edge Pan | `direction="right"` / `minimumNumberOfTouches="1"` / `minimumNumberOfTouches="1"` | — |

   Values that Ycode should not take from this table because they are
   only seen in older files: every size marked "(older)", and anything
   marked OPEN. The attribute sets are safer: the reference kept them
   unchanged when it saved our test document.
3. **Objects inserted without constraints.** In files written by Xcode
   (level 2), every view that was placed by hand without constraints has
   three things together:
   - `fixedFrame="YES"`;
   - `translatesAutoresizingMaskIntoConstraints="NO"`;
   - `<autoresizingMask key="autoresizingMask" flexibleMaxX="YES"
     flexibleMaxY="YES"/>`.

   This combination was found in 133 of 134 such views. Ycode's current
   insert writes only `translatesAutoresizingMaskIntoConstraints="NO"`.
   Adding `fixedFrame="YES"` and that autoresizing mask matches the
   files. Whether the reference writes `fixedFrame` at insert or only
   later is OPEN.

## Evidence

- Correction 2026-10-19: no Library button in the default toolbar; Open Library ⌥⇧⌘L (`reference-ui-5.md` §2.4, level 3).
- Panel, shortcut and the double-click/drag behavior: Apple's public
  documentation for the Library and code snippets (level 1).
- Symbol drawing: the public AppKit API (level 1). The names were typed by
  hand from public documentation; no Apple file was read.
- OPEN QUESTION: the reference's other Library tabs (views, modifiers,
  colors, media), user-defined snippets and their storage, the exact
  insertion form for symbols, and placeholder token drawing.
- Reference Objects library (2026-11-05): the item names, their order,
  the class names, the xib/storyboard difference, the panel's layout and
  measurements, the icon/list toggle and the search rules were all read
  through the accessibility API from Xcode 27.1, run in the background on
  a test project made for the purpose (level 3). Only names and measured
  values are recorded here, not the reference's summary or description
  text.
- Element names: each was confirmed by loading a document that uses it
  in the reference (Xcode and `ibtool`), and by a check that unknown names
  are refused (level 3).
- Canonical attribute and child order, and the values added on save: our
  own test storyboard (one object of each kind) was saved by the
  reference and compared with what we wrote (levels 2 and 3).
- Typical insert values and sizes: iOS storyboards written by earlier
  Xcode versions (tools versions 15000–24000) on local drives, studied as
  a file format, statistics only (level 2). The `fixedFrame` triple
  occurs in 133 of 134 views without constraints.
- OPEN QUESTION (needs a foreground session, which this pass did not
  take): the bytes the reference writes when each Library object is
  inserted (drag or double-click, then diff); the default insert size of
  each object in Xcode 27.1; the drag preview; whether double-click or
  Return inserts into the selection; the long descriptions' layout
  rules. The reference also showed "An internal error occurred. Editing
  functionality may be limited." on every Interface Builder document in
  this environment, and its canvas did not render views (see
  `interface-builder.md`, "Canvas drawing"). So sizes could not be read
  off the canvas.

