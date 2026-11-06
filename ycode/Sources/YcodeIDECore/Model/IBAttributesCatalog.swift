import Foundation

/// The Attributes inspector for every UIKit kind (`interface-builder.md`
/// §Reference Attributes inspector): the kind's own section first, then its
/// superclasses' (Control, Scroll View, View; Simulated Metrics and View
/// Controller for controllers; Bar Item; Gesture Recognizer), with the
/// spec's labels, control types and order. Each row names the attribute it
/// writes; the names are file-format facts and public UIKit property
/// names. The shared sections are written once below.
struct IBAttributeRows {
    let d: IBDocument
    let o: IBDocument.Object
    var id: String { o.id }

    // MARK: Row builders

    /// Pairs from "value|Title" strings ("value" alone: the title is the
    /// value in words).
    static func pairs(_ list: [String]) -> (values: [String], titles: [String]) {
        let split = list.map { s -> (String, String) in
            if let bar = s.firstIndex(of: "|") { return (String(s[..<bar]), String(s[s.index(after: bar)...])) }
            return (s, IBDocument.words(s))
        }
        return (split.map(\.0), split.map(\.1))
    }

    func value(_ attr: String, _ target: String?) -> String? { target.map { d.value(attr, at: $0) } ?? o.attribute(attr) }

    func check(_ key: String, _ title: String, _ attr: String, on def: Bool = false, at t: String? = nil) -> IBInspectorRow {
        let target = t ?? id
        if attr.hasPrefix("@child:") {
            let c = IBDocument.PathComponent(attr.dropFirst("@child:".count))
            return .check(key: key, title: title, target: target, attribute: attr, isOn: o.node.children.contains(where: c.matches), onValue: "YES", offValue: nil)
        }
        let v = value(attr, t)
        if def { return .check(key: key, title: title, target: target, attribute: attr, isOn: v != "NO", onValue: nil, offValue: "NO") }
        return .check(key: key, title: title, target: target, attribute: attr, isOn: v == "YES", onValue: "YES", offValue: nil)
    }

    /// A check box whose attribute says the opposite (`hidden` for "Shows").
    func inverseCheck(_ key: String, _ title: String, _ attr: String, at t: String? = nil) -> IBInspectorRow {
        .check(key: key, title: title, target: t ?? id, attribute: attr, isOn: value(attr, t) != "YES", onValue: nil, offValue: "YES")
    }

    func pop(_ key: String, _ attr: String, _ list: [String], _ def: String? = nil, at t: String? = nil) -> IBInspectorRow {
        let p = Self.pairs(list)
        return .popUp(key: key, target: t ?? id, attribute: attr, values: p.values, titles: p.titles, value: value(attr, t) ?? def ?? p.values[0])
    }

    /// A pop-up Ycode shows with its current choice only (its file form is
    /// not specified yet).
    func fixed(_ key: String, _ title: String) -> IBInspectorRow {
        .popUp(key: key, target: id, attribute: "@shown", values: [title], titles: [title], value: title)
    }

    func text(_ key: String, _ attr: String, _ ph: String = "", at t: String? = nil) -> IBInspectorRow {
        .text(label: key, target: t ?? id, attribute: attr, value: value(attr, t) ?? "", placeholder: ph)
    }

    func num(_ key: String, _ attr: String, _ def: String, at t: String? = nil) -> IBInspectorRow {
        .number(key: key, target: t ?? id, attribute: attr, value: value(attr, t) ?? def, placeholder: def)
    }

    func nums(_ key: String, _ fields: [(String, String, String)], at t: String? = nil) -> IBInspectorRow {
        .numbers(key: key, fields: fields.map { IBNumberField($0.0, target: t ?? id, attribute: $0.1, value: value($0.1, t) ?? $0.2, placeholder: $0.2) })
    }

    func combo(_ key: String, _ attr: String, _ ph: String, at t: String? = nil) -> IBInspectorRow {
        .combo(key: key, target: t ?? id, attribute: attr, value: value(attr, t) ?? "", placeholder: ph)
    }

    func color(_ key: String, _ colorKey: String, _ def: String = "Default", at t: String? = nil) -> IBInspectorRow {
        .color(key: key, target: t ?? id, colorKey: colorKey, value: d.colorTitle(colorKey, at: t ?? id, default: def))
    }

    func icons(_ key: String, _ attr: String, _ list: [String], _ def: String, at t: String? = nil) -> IBInspectorRow {
        let p = Self.pairs(list)
        return .icons(key: key, target: t ?? id, attribute: attr, values: p.values, titles: p.titles, value: value(attr, t) ?? def)
    }

    func font(_ def: String) -> IBInspectorRow {
        let titles = IBDocument.fontChoices.map(\.title)
        return .popUp(key: "Font", target: id, attribute: "@font", values: titles, titles: titles, value: d.fontTitle(o, default: def))
    }

    /// "Text: pop-up (Plain), text field": the kind of text, then the text.
    func textRows(_ attr: String, _ def: String = "") -> [IBInspectorRow] {
        [fixed("Text", o.node.child("attributedString") != nil ? "Attributed" : "Plain"), .text(label: "", target: id, attribute: attr, value: o.attribute(attr) ?? def, placeholder: "")]
    }

    // MARK: Shared value lists

    static let alignments = ["left|Left", "center|Center", "right|Right", "justified|Justified", "natural|Natural"]
    static let lineBreaks = ["clip|Clip", "characterWrap|Character Wrap", "wordWrap|Word Wrap", "headTruncation|Truncate Head",
                             "middleTruncation|Truncate Middle", "tailTruncation|Truncate Tail"]
    static let barStyles = ["default|Default", "black|Black"]
    static let triState = ["default|Default", "no|No", "yes|Yes"]
    static let dataDetectors = [("Phone Number", "phoneNumber"), ("Link", "link"), ("Address", "address"), ("Calendar Event", "calendarEvent"),
                                ("Shipment Tracking Number", "shipmentTrackingNumber"), ("Flight Number", "flightNumber"),
                                ("Lookup Suggestion", "lookupSuggestion")]

    // MARK: Shared sections

    /// View (every view). A subview ends with Installed.
    func viewSection() -> IBInspectorSection {
        var rows: [IBInspectorRow] = [
            pop("Content Mode", "contentMode", ["scaleToFill|Scale To Fill", "scaleAspectFit|Aspect Fit", "scaleAspectFill|Aspect Fill", "redraw|Redraw",
                                                "center|Center", "top|Top", "bottom|Bottom", "left|Left", "right|Right", "topLeft|Top Left",
                                                "topRight|Top Right", "bottomLeft|Bottom Left", "bottomRight|Bottom Right"]),
            pop("Semantic", "semanticContentAttribute", ["|Unspecified", "playback|Playback", "spatial|Spatial",
                                                         "forceLeftToRight|Force Left-to-Right", "forceRightToLeft|Force Right-to-Left"]),
            num("Tag", "tag", "0"),
            check("Interaction", "User Interaction Enabled", "userInteractionEnabled", on: true),
            check("", "Multiple Touch", "multipleTouchEnabled"),
            num("Alpha", "alpha", "1"),
            color("Background", "backgroundColor"),
            color("Tint", "tintColor"),
            check("Drawing", "Opaque", "opaque", on: true),
            check("", "Hidden", "hidden"),
            check("", "Clears Graphics Context", "clearsContextBeforeDrawing", on: true),
            check("", "Clips to Bounds", "clipsSubviews"),
            check("", "Autoresize Subviews", "autoresizesSubviews", on: true),
            nums("Stretching", [("X", "x", "0"), ("Y", "y", "0"), ("Width", "width", "1"), ("Height", "height", "1")], at: "\(id)>rect@contentStretch"),
        ]
        if o.parent?.isView == true && o.key == nil { rows.append(check("", "Installed", "@installed", on: true)) }
        return IBInspectorSection("View", rows)
    }

    /// Control (UIControl subclasses), with the kind's alignment defaults.
    func controlSection(h: String = "center", v: String = "center") -> IBInspectorSection {
        IBInspectorSection("Control", [
            icons("Horizontal", "contentHorizontalAlignment", ["leading|Leading", "left|Left", "center|Center", "trailing|Trailing", "right|Right", "fill|Fill"], h),
            icons("Vertical", "contentVerticalAlignment", ["top|Top", "center|Center", "bottom|Bottom", "fill|Fill"], v),
            check("Menu", "Shows as Primary Action", "showsMenuAsPrimaryAction"),
            check("State", "Selected", "selected"),
            check("", "Enabled", "enabled", on: true),
            check("", "Highlighted", "highlighted"),
            text("Tooltip", "toolTip"),
        ])
    }

    /// Scroll View (scroll views, text views, table and collection views).
    func scrollSection() -> IBInspectorSection {
        IBInspectorSection("Scroll View", [
            pop("Indicators", "indicatorStyle", ["default|Default Style", "black|Black Style", "white|White Style"]),
            check("", "Show Horizontal Indicator", "showsHorizontalScrollIndicator", on: true),
            check("", "Show Vertical Indicator", "showsVerticalScrollIndicator", on: true),
            check("Scrolling", "Scrolling Enabled", "scrollEnabled", on: true),
            check("", "Paging Enabled", "pagingEnabled"),
            check("", "Direction Lock Enabled", "directionalLockEnabled"),
            check("Bounce", "Bounce On Scroll", "bounces", on: true),
            check("", "Bounce On Zoom", "bouncesZoom", on: true),
            check("", "Bounce Horizontally", "alwaysBounceHorizontal"),
            check("", "Bounce Vertically", "alwaysBounceVertical"),
            nums("Zoom", [("Min", "minimumZoomScale", "1"), ("Max", "maximumZoomScale", "1")]),
            check("Content Touch", "Delay Touch Down", "delaysContentTouches", on: true),
            check("", "Can Cancel On Scroll", "canCancelContentTouches", on: true),
            pop("Keyboard", "keyboardDismissMode", ["|Do not dismiss", "onDrag|Dismiss on drag", "interactive|Dismiss interactively"]),
        ])
    }

    /// Simulated Metrics (every controller; split view controllers have no Top Bar).
    func simulatedMetrics(topBar: Bool = true) -> IBInspectorSection {
        IBInspectorSection("Simulated Metrics", ["Size", "Top Bar", "Bottom Bar", "Keyboard"].filter { topBar || $0 != "Top Bar" }.map { fixed($0, "Inferred") })
    }

    /// View Controller (every controller, after its own section).
    func viewControllerSection() -> IBInspectorSection {
        let size = "\(id)>size@preferredContentSize"
        return IBInspectorSection("View Controller", [
            text("Title", "title"),
            .toggle(label: "Is Initial View Controller", target: id, attribute: "initialViewController", isOn: d.initialViewController == id, onValue: id, offValue: nil),
            text("Activity Name", "userActivityType"),
            check("Layout", "Adjust Scroll View Insets", "automaticallyAdjustsScrollViewInsets", on: true),
            check("", "Hide Bottom Bar on Push", "hidesBottomBarWhenPushed"),
            check("", "Resize View From NIB", "autoresizesArchivedViewToFullSize", on: true),
            check("", "Use Full Screen (Deprecated)", "wantsFullScreenLayout"),
            .edgeToggle(label: "Under Top Bars", target: id, edge: "top", isOn: d.extendedEdge(o, "top")),
            .edgeToggle(label: "Under Bottom Bars", target: id, edge: "bottom", isOn: d.extendedEdge(o, "bottom")),
            check("", "Under Opaque Bars", "extendedLayoutIncludesOpaqueBars"),
            pop("Transition Style", "modalTransitionStyle", ["coverVertical|Cover Vertical", "flipHorizontal|Flip Horizontal",
                                                             "crossDissolve|Cross Dissolve", "partialCurl|Partial Curl"]),
            pop("Presentation", "modalPresentationStyle", ["automatic|Automatic", "fullScreen|Full Screen", "pageSheet|Page Sheet", "formSheet|Form Sheet",
                                                           "currentContext|Current Context", "overFullScreen|Over Full Screen",
                                                           "overCurrentContext|Over Current Context", "popover|Popover", "none|None"]),
            check("", "Defines Context", "definesPresentationContext"),
            check("", "Provides Context", "providesPresentationContextTransitionStyle"),
            check("Content Size", "Use Preferred Explicit Size", "usesPreferredContentSize"),
            nums("", [("Width", "width", "0"), ("Height", "height", "0")], at: size),
            .list(key: "Key Commands", items: d.keyCommands(o).map { "\($0.input) \($0.action)" }),
        ])
    }

    /// Bar Item (bar button items and tab bar items, after their own section).
    func barItemSection() -> IBInspectorSection {
        IBInspectorSection("Bar Item", [
            text("Title", "title"), combo("Image", "image", "Image"), combo("Landscape", "landscapeImage", "Image"),
            combo("Accessibility", "largeContentSizeImage", "Image"), num("Tag", "tag", "0"), check("", "Enabled", "enabled", on: true),
        ])
    }

    /// Gesture Recognizer (every recognizer, last).
    func gestureSection() -> IBInspectorSection {
        IBInspectorSection("Gesture Recognizer", [
            check("State", "Enabled", "enabled", on: true),
            check("Behavior", "Cancels touches in view", "cancelsTouchesInView", on: true),
            check("", "Delays touches began", "delaysTouchesBegan"),
            check("", "Delays touches ended", "delaysTouchesEnded", on: true),
            check("", "Requires one touch type", "requiresExclusiveTouchType", on: true),
        ])
    }

    /// The Text Input Traits group (text fields, text views, search bars).
    func textInputTraits(capitalization: String = "none") -> [IBInspectorRow] {
        let t = "\(id)>textInputTraits@textInputTraits"
        return [
            .subheading("Text Input Traits"),
            pop("Content Type", "textContentType", ["|Unspecified", "name|Name", "username|Username", "password|Password", "new-password|New Password",
                                                    "one-time-code|One Time Code", "email|Email Address", "tel|Telephone Number", "url|URL",
                                                    "street-address-line1|Address Line 1", "postal-code|Postal Code"], at: t),
            pop("Capitalization", "autocapitalizationType", ["none|None", "words|Words", "sentences|Sentences", "allCharacters|All Characters"], capitalization, at: t),
            pop("Correction", "autocorrectionType", Self.triState, at: t),
            pop("Smart Dashes", "smartDashesType", Self.triState, at: t),
            pop("Smart Insert", "smartInsertDeleteType", Self.triState, at: t),
            pop("Smart Quotes", "smartQuotesType", Self.triState, at: t),
            pop("Spell Checking", "spellCheckingType", Self.triState, at: t),
            pop("Keyboard Type", "keyboardType", ["default|Default", "ASCIICapable|ASCII Capable", "numbersAndPunctuation|Numbers and Punctuation",
                                                  "URL|URL", "numberPad|Number Pad", "phonePad|Phone Pad", "namePhonePad|Name Phone Pad",
                                                  "emailAddress|E-mail Address", "decimalPad|Decimal Pad", "twitter|Twitter", "webSearch|Web Search",
                                                  "ASCIICapableNumberPad|ASCII Capable Number Pad"], at: t),
            pop("Keyboard Look", "keyboardAppearance", ["default|Default", "dark|Dark", "light|Light"], at: t),
            pop("Return Key", "returnKeyType", ["default|Default", "go|Go", "google|Google", "join|Join", "next|Next", "route|Route", "search|Search",
                                                "send|Send", "yahoo|Yahoo", "done|Done", "emergencyCall|Emergency Call", "continue|Continue"], at: t),
            check("", "Auto-enable Return Key", "enablesReturnKeyAutomatically", at: t),
            check("", "Secure Text Entry", "secureTextEntry", at: t),
        ]
    }

    func dataDetectorRows(_ path: String, on: (String) -> Bool) -> [IBInspectorRow] {
        Self.dataDetectors.enumerated().map { check($0.offset == 0 ? "Data Detectors" : "", $0.element.0, $0.element.1, on: on($0.element.1), at: path) }
    }

    // MARK: Per kind

    /// The sections for the object, in the reference's order.
    func sections(segment: Int) -> [IBInspectorSection] {
        let e = o.element
        if d.isController(o) || e == "viewControllerPlaceholder" { return controllerSections() }
        if let own = nonViewSections() { return own }
        var out: [IBInspectorSection] = []
        let controls: [String: (String, String)] = ["button": ("center", "center"), "segmentedControl": ("left", "top"), "textField": ("left", "center"),
                                                    "slider": ("center", "center"), "switch": ("center", "center"), "pageControl": ("center", "center"),
                                                    "stepper": ("center", "center"), "colorWell": ("center", "center"), "pasteControl": ("center", "center"),
                                                    "datePicker": ("center", "center"), "clLocationButton": ("center", "center")]
        if let own = ownSection(segment: segment) { out.append(own) }
        if let c = controls[e] { out.append(controlSection(h: c.0, v: c.1)) }
        if ["tableView", "collectionView", "textView", "scrollView"].contains(e) { out.append(scrollSection()) }
        if o.isView { out.append(viewSection()) }
        return out
    }

    func controllerSections() -> [IBInspectorSection] {
        let e = o.element
        if e == "viewControllerPlaceholder" {
            return [IBInspectorSection("Storyboard Reference", [combo("Storyboard", "storyboardName", "Storyboard"), text("Referenced ID", "referencedIdentifier"),
                                                                 text("Bundle", "bundleIdentifier")])]
        }
        var own: IBInspectorSection?
        switch e {
        case "navigationController":
            own = IBInspectorSection("Navigation Controller", [
                inverseCheck("Bar Visibility", "Shows Navigation Bar", "navigationBarHidden"),
                .check(key: "", title: "Shows Toolbar", target: id, attribute: "toolbarHidden", isOn: o.attribute("toolbarHidden") == "NO", onValue: "NO", offValue: nil),
                check("Hide Bars", "On Swipe", "hidesBarsOnSwipe"), check("", "On Tap", "hidesBarsOnTap"),
                check("", "When Keyboard Appears", "hidesBarsWhenKeyboardAppears"), check("", "When Vertically Compact", "hidesBarsWhenVerticallyCompact"),
            ])
        case "tableViewController":
            own = IBInspectorSection("Table View Controller", [check("Selection", "Clear on Appearance", "clearsSelectionOnViewWillAppear", on: true),
                                                               pop("Refreshing", "@child:refreshControl@refreshControl", ["NO|Disabled", "YES|Enabled"],
                                                                   o.children.contains { $0.key == "refreshControl" } ? "YES" : "NO")])
        case "collectionViewController":
            own = IBInspectorSection("Collection View Controller", [check("Selection", "Clear on Appearance", "clearsSelectionOnViewWillAppear", on: true)])
        case "splitViewController":
            own = IBInspectorSection("Split View Controller", [
                pop("Style", "style", ["unspecified|Unspecified (Discouraged)", "doubleColumn|Double Column", "tripleColumn|Triple Column"]),
                check("Compact Width", "Use Separate View Controller", "@compactColumn"),
                check("", "Present Primary With Gesture", "presentsWithGesture", on: true),
                pop("Display Mode", "preferredDisplayMode", ["automatic|Automatic", "secondaryOnly|Secondary Only", "oneBesideSecondary|One Beside Secondary",
                                                             "oneOverSecondary|One Over Secondary", "twoBesideSecondary|Two Beside Secondary",
                                                             "twoOverSecondary|Two Over Secondary", "twoDisplaceSecondary|Two Displace Secondary"]),
                pop("Behavior", "preferredSplitBehavior", ["automatic|Automatic", "tile|Tile", "overlay|Overlay", "displace|Displace"]),
                pop("Primary Edge", "primaryEdge", ["leading|Leading", "trailing|Trailing"]),
                pop("Primary Style", "primaryBackgroundStyle", ["none|None", "sidebar|Sidebar"]),
            ])
        case "pageViewController":
            own = IBInspectorSection("Page View Controller", [
                pop("Navigation", "navigationOrientation", ["horizontal|Horizontal", "vertical|Vertical"]),
                pop("Transition Style", "transitionStyle", ["pageCurl|Page Curl", "scroll|Scroll"]),
                num("Page Spacing", "interPageSpacing", "0"),
                pop("Spine Location", "spineLocation", ["min|Min", "mid|Mid", "max|Max", "none|None"]),
                check("", "Double Sided", "doubleSided"),
            ])
        case "glkViewController":
            own = IBInspectorSection("GLKit View Controller", [num("Preferred FPS", "preferredFramesPerSecond", "30"),
                                                               check("", "Pause on Deactivate", "pauseOnWillResignActive", on: true),
                                                               check("", "Resume on Activate", "resumeOnDidBecomeActive", on: true)])
        case "avPlayerViewController":
            own = IBInspectorSection("AVKit Player View Controller", [
                check("", "Shows Playback Controls", "showsPlaybackControls", on: true),
                pop("Video Gravity", "videoGravity", ["AVLayerVideoGravityResizeAspect|Resize Aspect", "AVLayerVideoGravityResizeAspectFill|Resize Aspect Fill",
                                                      "AVLayerVideoGravityResize|Resize"]),
            ])
        case "lookAroundViewController":
            own = IBInspectorSection("Look Around View Controller", [check("Navigation", "Enabled", "navigationEnabled"), check("Shows", "Road Labels", "showsRoadLabels"),
                                                                     .subheading("Point of Interest"), fixed("Filter", "None")])
        default: break
        }
        return [simulatedMetrics(topBar: e != "splitViewController")] + (own.map { [$0] } ?? []) + [viewControllerSection()]
    }

    /// Sections of objects without a frame (bar items, menus, gesture
    /// recognizers, placeholders); nil for views.
    func nonViewSections() -> [IBInspectorSection]? {
        switch o.element {
        case "barButtonItem":
            return [IBInspectorSection("Bar Button Item", [
                pop("Style", "style", ["|Bordered", "plain|Plain", "done|Done"]),
                pop("System Item", "systemItem", ["|Custom", "done|Done", "cancel|Cancel", "edit|Edit", "save|Save", "add|Add",
                                                  "flexibleSpace|Flexible Space", "fixedSpace|Fixed Space", "compose|Compose", "reply|Reply",
                                                  "action|Action", "organize|Organize", "bookmarks|Bookmarks", "search|Search", "refresh|Refresh",
                                                  "stop|Stop", "camera|Camera", "trash|Trash", "play|Play", "pause|Pause", "rewind|Rewind",
                                                  "fastForward|Fast Forward", "undo|Undo", "redo|Redo", "close|Close"]),
                color("Tint", "tintColor"),
                check("Drawing", "Hidden", "hidden"),
                check("Drag and Drop", "Spring Loaded", "springLoaded"),
                check("Menu", "Selection as Primary Action", "changesSelectionAsPrimaryAction"),
            ]), barItemSection()]
        case "barButtonItemGroup":
            return [IBInspectorSection("Bar Button Item Group", [check("Drawing", "Hidden", "hidden")])]
        case "navigationItem":
            return [IBInspectorSection("Navigation Item", [
                text("Title", "title"), text("Prompt", "prompt"),
                pop("Style", "style", ["navigator|Navigator", "browser|Browser", "editor|Editor"]),
                text("Back Button", "backButtonTitle"), check("", "Left Items Supplement", "leftItemsSupplementBackButton"),
                pop("Large Title", "largeTitleDisplayMode", ["automatic|Automatic", "always|Always", "never|Never", "inline|Inline"]),
                text("Identifier", "customizationIdentifier"),
            ])]
        case "tabBarItem":
            return [IBInspectorSection("Tab Bar Item", [
                text("Badge", "badgeValue"), color("", "badgeColor"),
                pop("System Item", "systemItem", ["|Custom", "more|More", "favorites|Favorites", "featured|Featured", "topRated|Top Rated",
                                                  "recents|Recents", "contacts|Contacts", "history|History", "bookmarks|Bookmarks", "search|Search",
                                                  "downloads|Downloads", "mostRecent|Most Recent", "mostViewed|Most Viewed"]),
                combo("Selected Image", "selectedImage", "Selected Image"),
                fixed("Title Position", "Default Position"),
                check("Drag and Drop", "Spring Loaded", "springLoaded"),
            ]), barItemSection()]
        case "menu":
            let opts = "\(id)>menuOptions@options"
            return [IBInspectorSection("Menu", [text("Title", "title"), text("Identifier", "identifier"),
                                                check("Options", "Display Inline", "displayInline", at: opts), check("", "Destructive", "destructive", at: opts),
                                                check("", "Single Selection", "singleSelection", at: opts)])]
        case "command":
            let attrs = "\(id)>menuElementAttributes@attributes"
            return [IBInspectorSection("Command", [
                text("Title", "title"), text("HUD Title", "discoverabilityTitle"), text("Property List", "propertyList"),
                text("Key Equivalent", "keyEquivalent"),
                check("Attributes", "Disabled", "disabled", at: attrs), check("", "Destructive", "destructive", at: attrs), check("", "Hidden", "hidden", at: attrs),
                pop("State", "menuElementState", ["|Off", "on|On", "mixed|Mixed"]),
                fixed("Localize", "Automatic"),
                .list(key: "Alternates", items: (o.node.child("alternates")?.children ?? []).map { $0["action"] ?? $0.name }),
            ])]
        case "customObject":
            return [IBInspectorSection("Object", [combo("Class", "customClass", "NSObject"), combo("Module", "customModule", "None"),
                                                  .check(key: "", title: "Inherit Module From Target", target: id, attribute: "customModuleProvider",
                                                         isOn: o.attribute("customModuleProvider") == "target", onValue: "target", offValue: nil)])]
        case "placeholder":
            let pid = o.attribute("placeholderIdentifier")
            if pid == "IBFirstResponder" || o.attribute("sceneMemberID") == "firstResponder" {
                return [IBInspectorSection("First Responder", [.list(key: "User Defined", items: [])])]
            }
            if pid == "IBFilesOwner" { return [IBInspectorSection("", [.info(label: "Not Applicable", value: "")])] }
            return [IBInspectorSection("External Object", [text("Identifier", "placeholderIdentifier")]),
                    IBInspectorSection("Object", [combo("Class", "customClass", "NSObject"), combo("Module", "customModule", "None")])]
        case "viewLayoutGuide", "exit":
            return [IBInspectorSection("", [.info(label: "Not Applicable", value: "")])]
        case "collectionViewFlowLayout":
            return [IBInspectorSection("Collection View Flow Layout", [pop("Scroll Direction", "scrollDirection", ["vertical|Vertical", "horizontal|Horizontal"])])]
        default:
            return gestureSections()
        }
    }

    func gestureSections() -> [IBInspectorSection]? {
        let pan = { IBInspectorSection("Pan Gesture Recognizer", [
            nums("Touches", [("Minimum", "minimumNumberOfTouches", "1"), ("Maximum", "maximumNumberOfTouches", "")]),
            check("Scroll Types", "Continuous (trackpad)", "continuous", at: "\(id)>scrollTypeMask@allowedScrollTypesMask"),
            check("", "Discrete (scroll wheel)", "discrete", at: "\(id)>scrollTypeMask@allowedScrollTypesMask"),
        ]) }
        var own: [IBInspectorSection]
        switch o.element {
        case "tapGestureRecognizer":
            let mask = "\(id)>eventButtonMask@buttonMaskRequired"
            own = [IBInspectorSection("Tap Gesture Recognizer", [
                nums("Recognize", [("Taps", "numberOfTapsRequired", "1"), ("Touches", "numberOfTouchesRequired", "1")]),
                check("Pointer", "Primary Button", "primary", on: true, at: mask), check("", "Secondary Button", "secondary", at: mask),
            ])]
        case "pinchGestureRecognizer": own = [IBInspectorSection("Pinch Gesture Recognizer", [num("Scale", "scale", "1")])]
        case "rotationGestureRecognizer": own = [IBInspectorSection("Rotation Gesture Recognizer", [num("Rotation", "rotation", "0")])]
        case "swipeGestureRecognizer":
            own = [IBInspectorSection("Swipe Gesture Recognizer", [pop("Swipe", "direction", ["right|Right", "left|Left", "up|Up", "down|Down"]),
                                                                   num("Touches", "numberOfTouchesRequired", "1")])]
        case "panGestureRecognizer": own = [pan()]
        case "screenEdgePanGestureRecognizer":
            let edges = "\(id)>rectEdge@edges"
            own = [IBInspectorSection("Screen Edge Pan Gesture Recognizer", [
                check("Edges", "Top", "top", at: edges), check("", "Left", "left", at: edges),
                check("", "Bottom", "bottom", at: edges), check("", "Right", "right", at: edges),
            ]), pan()]
        case "pongPressGestureRecognizer":
            own = [IBInspectorSection("Long Press Gesture Recognizer", [
                num("Min Duration", "minimumPressDuration", "0.5"),
                nums("Recognize", [("Taps", "numberOfTapsRequired", "0"), ("Touches", "numberOfTouchesRequired", "1")]),
                num("Tolerance", "allowableMovement", "10"),
            ])]
        case "gestureRecognizer": own = []
        default: return nil
        }
        return own + [gestureSection()]
    }

    /// The kind's own section (views); nil for plain views.
    func ownSection(segment: Int) -> IBInspectorSection? {
        let e = o.element
        switch e {
        case "label":
            let offset = "\(id)>size@shadowOffset"
            return IBInspectorSection("Label", textRows("text") + [
                color("Color", "textColor", "Default (Label Color)"),
                font("System 17.0"),
                check("Dynamic Type", "Automatically Adjusts Font", "adjustsFontForContentSizeCategory"),
                icons("Alignment", "textAlignment", Self.alignments, "natural"),
                num("Lines", "numberOfLines", "1"),
                check("Behavior", "Enabled", "enabled", on: true), check("", "Highlighted", "highlighted"),
                check("Tooltip", "Shows Expansion Text", "showsExpansionTextWhenTruncated"),
                pop("Baseline", "baselineAdjustment", ["alignBaselines|Align Baselines", "alignCenters|Align Centers", "none|None"]),
                pop("Line Break", "lineBreakMode", Self.lineBreaks, "tailTruncation"),
                pop("Strategy", "lineBreakStrategy", ["|Standard", "none|None", "pushOut|Push Out", "hangulWordPriority|Hangul Word Priority"]),
                pop("Autoshrink", "adjustsFontSizeToFit", ["NO|Fixed Font Size", "YES|Minimum Font Scale"]),
                check("", "Tighten Letter Spacing", "allowsDefaultTighteningForTruncation"),
                pop("Sizing Rule", "sizingRule", ["typographic|Typographic", "oversize|Oversize"]),
                color("Highlighted", "highlightedColor"),
                color("Shadow", "shadowColor"),
                nums("Shadow Offset", [("Width", "width", "0"), ("Height", "height", "-1")], at: offset),
            ])
        case "button": return buttonSection()
        case "segmentedControl":
            let segs = o.node.child("segments")?.children.filter { $0.name == "segment" } ?? []
            let i = min(max(segment, 0), max(segs.count - 1, 0))
            let seg = "\(id)>segments>segment#\(i)"
            return IBInspectorSection("Segmented Control", [
                pop("Style", "segmentControlStyle", ["plain|Plain", "bordered|Bordered", "bar|Bar"]),
                color("Selected Tint", "selectedSegmentTintColor"),
                check("State", "Momentary", "momentary"),
                check("Drag and Drop", "Spring Loaded", "springLoaded"),
                num("Segments", "@segments", "\(segs.count)"),
                .popUp(key: "Segment", target: id, attribute: "@segmentIndex", values: segs.indices.map(String.init),
                       titles: segs.enumerated().map { "Segment \($0.offset) - \($0.element["title"] ?? "")" }, value: "\(i)"),
                text("Title", "title", at: seg),
                combo("Image", "image", "Image", at: seg),
                check("Behavior", "Enabled", "enabled", on: true, at: seg),
                .check(key: "", title: "Selected", target: id, attribute: "selectedSegmentIndex", isOn: o.attribute("selectedSegmentIndex") == "\(i)",
                       onValue: "\(i)", offValue: nil),
                nums("Content Offset", [("Width", "width", "0"), ("Height", "height", "0")], at: seg + ">size@contentOffset"),
            ])
        case "textField":
            return IBInspectorSection("Text Field", textRows("text") + [
                color("Color", "textColor", "Default (Label Color)"),
                font("System 14.0"),
                check("Dynamic Type", "Automatically Adjusts Font", "adjustsFontForContentSizeCategory"),
                icons("Alignment", "textAlignment", Self.alignments, "natural"),
                text("Placeholder", "placeholder"),
                combo("Background", "background", "Background Image"),
                combo("Disabled", "disabledBackground", "Disabled Background Image"),
                icons("Border Style", "borderStyle", ["none|None", "line|Line", "bezel|Bezel", "roundedRect|Round"], "none"),
                pop("Clear Button", "clearButtonMode", ["never|Never appears", "whileEditing|Appears while editing",
                                                        "unlessEditing|Appears unless editing", "always|Is always visible"]),
                check("", "Clear when editing begins", "clearsOnBeginEditing"),
                num("Min Font Size", "minimumFontSize", "0"),
                check("", "Adjust to Fit", "adjustsFontSizeToFit", on: true),
                pop("Sizing Rule", "sizingRule", ["typographic|Typographic", "oversize|Oversize"]),
            ] + textInputTraits())
        case "slider":
            return IBInspectorSection("Slider", [
                num("Value", "value", "0"), num("Minimum", "minValue", "0"), num("Maximum", "maxValue", "1"),
                combo("Min Image", "minimumValueImage", "Min Image"), combo("Max Image", "maximumValueImage", "Max Image"),
                color("Min Track", "minimumTrackTintColor"), color("Max Track", "maximumTrackTintColor"), color("Thumb Tint", "thumbTintColor"),
                check("Events", "Continuous Updates", "continuous", on: true),
                pop("Behavior", "behavioralStyle", ["automatic|Automatic", "pad|Pad", "mac|Mac"]),
            ])
        case "switch":
            return IBInspectorSection("Switch", [
                text("Title", "title"),
                pop("Style", "preferredStyle", ["automatic|Automatic", "checkbox|Checkbox", "sliding|Sliding"]),
                pop("State", "on", ["NO|Off", "YES|On"]),
                color("On Tint", "onTintColor"), color("Thumb Tint", "thumbTintColor"),
            ])
        case "activityIndicatorView":
            return IBInspectorSection("Activity Indicator View", [
                pop("Style", "style", ["medium|Medium", "large|Large"]), color("Color", "color"),
                check("Behavior", "Animating", "animating"), check("", "Hides When Stopped", "hidesWhenStopped"),
            ])
        case "progressView":
            return IBInspectorSection("Progress View", [
                pop("Style", "progressViewStyle", ["default|Default", "bar|Bar"]), num("Progress", "progress", "0"),
                color("Progress Tint", "progressTintColor"), color("Track Tint", "trackTintColor"),
                combo("Progress", "progressImage", "Progress Image"), combo("Track", "trackImage", "Track Image"),
            ])
        case "pageControl":
            return IBInspectorSection("Page Control", [
                nums("Pages", [("# of Pages", "numberOfPages", "3"), ("Current", "currentPage", "0")]),
                check("Behavior", "Hides for Single Page", "hidesForSinglePage"), check("", "Defers Page Display", "defersCurrentPageDisplay"),
                color("Tint Color", "pageIndicatorTintColor"), color("Current Page", "currentPageIndicatorTintColor"),
            ])
        case "stepper":
            return IBInspectorSection("Stepper", [
                num("Value", "value", "0"), num("Minimum", "minimumValue", "0"), num("Maximum", "maximumValue", "100"), num("Step", "stepValue", "1"),
                check("Behavior", "Autorepeat", "autorepeat", on: true), check("", "Continuous", "continuous", on: true), check("", "Wrap", "wraps"),
            ])
        case "colorWell":
            return IBInspectorSection("Color Well", [color("Color", "selectedColor"), check("", "Supports Alpha", "supportsAlpha", on: true), text("Title", "title")])
        case "pasteControl":
            return IBInspectorSection("Paste Control", [
                pop("Display Mode", "displayMode", ["iconAndLabel|Icon and Label", "iconOnly|Icon Only", "labelOnly|Label Only"]),
                pop("Corner Style", "cornerStyle", ["dynamic|Default", "fixed|Fixed", "capsule|Capsule", "large|Large", "medium|Medium", "small|Small"]),
                num("Radius", "cornerRadius", ""),
                .subheading("Base Colors"),
                color("Foreground", "baseForegroundColor"), color("Background", "baseBackgroundColor"),
                .info(label: "Target", value: "None"),
            ])
        case "stackView":
            let vertical = o.attribute("axis") == "vertical"
            return IBInspectorSection("Stack View", [
                pop("Axis", "axis", ["|Horizontal", "vertical|Vertical"]),
                pop("Alignment", "alignment", ["|Fill", vertical ? "leading|Leading" : "top|Top", "firstBaseline|First Baseline", "center|Center",
                                               vertical ? "trailing|Trailing" : "bottom|Bottom", "lastBaseline|Last Baseline"]),
                pop("Distribution", "distribution", ["|Fill", "fillEqually|Fill Equally", "fillProportionally|Fill Proportionally",
                                                     "equalSpacing|Equal Spacing", "equalCentering|Equal Centering"]),
                num("Spacing", "spacing", "0"),
                check("", "Baseline Relative", "baselineRelativeArrangement"),
            ])
        case "tableView":
            let selection = o.attribute("allowsSelection") == "NO" ? "none" : o.attribute("allowsMultipleSelection") == "YES" ? "multiple" : "single"
            let editing = o.attribute("allowsMultipleSelectionDuringEditing") == "YES" ? "multiple"
                : o.attribute("allowsSelectionDuringEditing") == "YES" ? "single" : "none"
            return IBInspectorSection("Table View", [
                pop("Content", "dataMode", ["prototypes|Dynamic Prototypes", "static|Static Cells"]),
                num("Prototype Cells", "@prototypes", "\(o.children.filter { $0.element == "tableViewCell" }.count)"),
                pop("Style", "style", ["plain|Plain", "grouped|Grouped", "insetGrouped|Inset Grouped"]),
                pop("Separator", "separatorStyle", ["default|Default", "none|None", "singleLine|Single Line", "singleLineEtched|Single Line Etched"]),
                color("", "separatorColor"),
                pop("Separator Inset", "separatorInsetReference", ["|Automatic", "fromCellEdges|From Cell Edges"]),
                pop("Selection", "@selection", ["none|No Selection", "single|Single Selection", "multiple|Multiple Selection"], selection),
                pop("Editing", "@editingSelection", ["none|No Selection During Editing", "single|Single Selection During Editing",
                                                     "multiple|Multiple Selection During Editing"], editing),
                check("Drag and Drop", "Spring Loaded", "springLoaded"),
                .subheading("Section Index"),
                num("Display Limit", "sectionIndexMinimumDisplayRowCount", "0"),
                color("Text", "sectionIndexColor"), color("Background", "sectionIndexBackgroundColor"), color("Tracking", "sectionIndexTrackingBackgroundColor"),
            ])
        case "tableViewCell":
            return IBInspectorSection("Table View Cell", [
                pop("Style", "style", ["|Custom", "IBUITableViewCellStyleDefault|Basic", "IBUITableViewCellStyleSubtitle|Subtitle",
                                       "IBUITableViewCellStyleValue1|Right Detail", "IBUITableViewCellStyleValue2|Left Detail"]),
                text("Identifier", "reuseIdentifier"),
                pop("Selection", "selectionStyle", ["default|Default", "none|None", "blue|Blue", "gray|Gray"]),
                pop("Accessory", "accessoryType", ["|None", "disclosureIndicator|Disclosure Indicator", "detailDisclosureButton|Detail Disclosure",
                                                   "checkmark|Checkmark", "detailButton|Detail"]),
                pop("Editing Acc.", "editingAccessoryType", ["|None", "disclosureIndicator|Disclosure Indicator", "detailDisclosureButton|Detail Disclosure",
                                                             "checkmark|Checkmark", "detailButton|Detail"]),
                pop("Focus Style", "focusStyle", ["|Default", "custom|Custom"]),
                nums("Indentation", [("Level", "indentationLevel", "0"), ("Width", "indentationWidth", "10")]),
                check("", "Indent While Editing", "shouldIndentWhileEditing", on: true),
                check("", "Shows Re-order Controls", "showsReorderControl"),
                fixed("Separator Inset", "Automatic"),
            ])
        case "imageView":
            return IBInspectorSection("Image View", [
                combo("Image", "image", "Image"), combo("Highlighted", "highlightedImage", "Highlighted"),
                check("State", "Highlighted", "highlighted"),
                check("Accessibility", "Adjusts Image Size", "adjustsImageSizeForAccessibilityContentSizeCategory"),
            ])
        case "collectionView":
            let layout = "\(id)>collectionViewFlowLayout@collectionViewLayout"
            return IBInspectorSection("Collection View", [
                num("Items", "@items", "\(o.children.filter { $0.element == "collectionViewCell" }.count)"),
                fixed("Layout", o.node.child("collectionViewFlowLayout") != nil ? "Flow" : "Custom"),
                pop("Scroll Direction", "scrollDirection", ["vertical|Vertical", "horizontal|Horizontal"], at: layout),
                .check(key: "Accessories", title: "Section Header", target: id, attribute: "@sectionHeader",
                       isOn: o.children.contains { $0.key == "sectionHeaderView" }, onValue: "YES", offValue: nil),
                .check(key: "", title: "Section Footer", target: id, attribute: "@sectionFooter",
                       isOn: o.children.contains { $0.key == "sectionFooterView" }, onValue: "YES", offValue: nil),
                check("Prefetch", "Prefetching Enabled", "prefetchingEnabled", on: true),
                check("Drag and Drop", "Spring Loaded", "springLoaded"),
            ])
        case "collectionViewCell", "collectionReusableView":
            return IBInspectorSection("Collection Reusable View", [text("Identifier", "reuseIdentifier")])
        case "textView":
            let detectors = "\(id)>dataDetectorType@dataDetectorTypes"
            return IBInspectorSection("Text View", textRows("text") + [
                color("Color", "textColor"),
                font("System 14.0"),
                check("Dynamic Type", "Automatically Adjusts Font", "adjustsFontForContentSizeCategory"),
                icons("Alignment", "textAlignment", Self.alignments, "natural"),
                check("", "Find & Replace", "findInteractionEnabled"),
                check("Behavior", "Editable", "editable", on: true), check("", "Selectable", "selectable", on: true),
            ] + dataDetectorRows(detectors) { _ in false } + [fixed("Text Layout", "Default")] + textInputTraits(capitalization: "none"))
        case "datePicker":
            return IBInspectorSection("Date Picker", [
                pop("Preferred Style", "style", ["automatic|Automatic", "compact|Compact", "inline|Inline", "wheels|Wheels"]),
                pop("Mode", "datePickerMode", ["time|Time", "date|Date", "dateAndTime|Date and Time", "countDownTimer|Count Down Timer",
                                               "yearAndMonth|Year and Month"], "dateAndTime"),
                fixed("Locale", "Default"),
                pop("Interval", "minuteInterval", ["1|1 minute", "2|2 minutes", "3|3 minutes", "4|4 minutes", "5|5 minutes", "6|6 minutes",
                                                   "10|10 minutes", "12|12 minutes", "15|15 minutes", "20|20 minutes", "30|30 minutes"]),
                fixed("Date", "Current Date"),
                check("", "Minimum Date", "@minimumDate"),
                check("", "Maximum Date", "@maximumDate"),
            ])
        case "visualEffectView":
            let vibrancy = o.node.child("vibrancyEffect") != nil
            var rows: [IBInspectorRow] = [
                pop("Blur Style", "style", ["regular|Regular", "prominent|Prominent", "extraLight|Extra Light", "light|Light", "dark|Dark",
                                            "systemUltraThinMaterial|System Ultra Thin Material", "systemThinMaterial|System Thin Material",
                                            "systemMaterial|System Material", "systemThickMaterial|System Thick Material",
                                            "systemChromeMaterial|System Chrome Material"], at: vibrancy ? "\(id)>vibrancyEffect>blurEffect" : "\(id)>blurEffect"),
                .check(key: "", title: "Vibrancy", target: id, attribute: "@vibrancy", isOn: vibrancy, onValue: "YES", offValue: nil),
            ]
            if vibrancy {
                rows.append(pop("Vibrancy Style", "style", ["|Default", "fill|Fill", "secondaryFill|Secondary Fill", "label|Label",
                                                            "secondaryLabel|Secondary Label", "tertiaryLabel|Tertiary Label", "separator|Separator"],
                                at: "\(id)>vibrancyEffect"))
            }
            return IBInspectorSection("Visual Effect View", rows)
        case "mapView":
            return IBInspectorSection("Map View", [
                pop("Configuration", "mapType", ["standard|Standard", "satellite|Satellite", "hybrid|Hybrid", "satelliteFlyover|Satellite Flyover",
                                                 "hybridFlyover|Hybrid Flyover", "mutedStandard|Muted Standard"]),
                check("Elevation", "Realistic", "@realisticElevation"),
                check("Emphasis", "Muted", "@mutedEmphasis"),
                check("Shows", "Traffic", "showsTraffic"), check("", "Compass", "showsCompass", on: true), check("", "Scale", "showsScale"),
                check("", "User Location", "showsUserLocation"), check("", "Points of Interest", "showsPointsOfInterest", on: true),
                check("", "User Tracking", "showsUserTrackingButton"),
                fixed("Pitch Button", "Hidden"),
                check("Allows", "Zooming", "zoomEnabled", on: true), check("", "Scrolling", "scrollEnabled", on: true),
                check("", "Rotating", "rotateEnabled", on: true), check("", "3D View", "pitchEnabled", on: true),
                .subheading("Point of Interest"), fixed("Filter", "None"),
            ])
        case "mtkView":
            return IBInspectorSection("MTKView", [
                .subheading("Render Target"),
                color("Clear Color", "clearColor"),
                num("Clear Depth", "clearDepth", "1"), num("Clear Stencil", "clearStencil", "0"),
                pop("Color Pixel Format", "colorPixelFormat", ["BGRA8Unorm|BGRA8 Unorm", "BGRA8Unorm_sRGB|BGRA8 Unorm sRGB", "RGBA16Float|RGBA16 Float",
                                                               "BGR10A2Unorm|BGR10 A2 Unorm"], "BGRA8Unorm"),
                pop("Depth Stencil Pixel Format", "depthStencilPixelFormat", ["Depth32Float|Depth 32 Float", "Invalid|Invalid", "Depth16Unorm|Depth 16 Unorm",
                                                                              "Stencil8|Stencil 8", "Depth32Float_Stencil8|Depth 32 Float Stencil 8"], "Depth32Float"),
                num("Sample Count", "sampleCount", "1"), num("Preferred FPS", "preferredFramesPerSecond", "60"),
                check("", "Enable setNeedsDisplay", "enableSetNeedsDisplay"), check("", "Paused", "paused"),
                check("", "AutoResize Drawable", "autoResizeDrawable", on: true),
            ])
        case "glkView":
            return IBInspectorSection("GLK View", [
                pop("Color Format", "drawableColorFormat", ["RGBA8888|RGBA8888", "RGB565|RGB565", "SRGBA8888|SRGBA8888"]),
                pop("Depth Format", "drawableDepthFormat", ["none|None", "16|16", "24|24"]),
                pop("Stencil Format", "drawableStencilFormat", ["none|None", "8|8"]),
                pop("Multisample", "drawableMultisample", ["none|None", "4X|4X"]),
                check("", "Enable setNeedsDisplay", "enableSetNeedsDisplay", on: true),
            ])
        case "sceneKitView", "arscnView":
            var rows: [IBInspectorRow] = [combo("Scene", "sceneName", "Scene")]
            if e == "sceneKitView" { rows.append(pop("Rendering API", "preferredRenderingAPI", ["|Default", "metal|Metal", "openGLES2|OpenGL ES 2.0"])) }
            rows += [
                check("Behavior", "Allow camera control", "allowsCameraControl"),
                check("Rendering", "Enable jittering", "jitteringEnabled"),
                .check(key: "", title: "Enable multisampling", target: id, attribute: "antialiasingMode",
                       isOn: o.attribute("antialiasingMode").map { $0 != "none" } ?? false, onValue: "multisampling4X", offValue: nil),
                check("", "Enable default lighting", "autoenablesDefaultLighting"),
                check("Animations", "Play", "playing"), check("", "Loop", "loops", on: true),
            ]
            return IBInspectorSection("SceneKit View", rows)
        case "skView", "arskView":
            return IBInspectorSection("SpriteKit View", [
                combo("Scene", "sceneName", "Scene"), num("Frame Rate", "preferredFramesPerSecond", ""),
                check("Rendering", "Asynchronous", "asynchronous", on: true), check("", "Allow Transparency", "allowsTransparency"),
                check("", "Cull Non-Visible Nodes", "shouldCullNonVisibleNodes", on: true), check("", "Ignore Sibling Order", "ignoresSiblingOrder"),
                check("Animation", "Paused", "paused"),
            ])
        case "webView":
            let detectors = "\(id)>dataDetectorType@dataDetectorTypes"
            return IBInspectorSection("Web View", [check("Scaling", "Scales Page To Fit", "scalesPageToFit")]
                + dataDetectorRows(detectors) { $0 == "phoneNumber" } + [
                    check("Options", "Allows Inline Playback", "allowsInlineMediaPlayback", on: true),
                    check("", "Playback Requires User Action", "mediaPlaybackRequiresUserAction", on: true),
                    check("", "Playback Allows AirPlay", "mediaPlaybackAllowsAirPlay", on: true),
                    check("", "Suppress Incremental Rendering", "suppressesIncrementalRendering"),
                    check("", "Keyboard Display Requires User Action", "keyboardDisplayRequiresUserAction", on: true),
                    pop("Pagination", "paginationMode", ["unpaginated|Unpaginated", "leftToRight|Left to Right", "topToBottom|Top to Bottom",
                                                         "bottomToTop|Bottom to Top", "rightToLeft|Right to Left"]),
                ])
        case "wkWebView":
            let config = "\(id)>wkWebViewConfiguration@configuration"
            let prefs = config + ">wkPreferences@preferences"
            let media = config + ">audiovisualMediaTypes@mediaTypesRequiringUserActionForPlayback"
            return IBInspectorSection("Web View", [
                text("User Agent", "customUserAgent"), text("App Name", "applicationNameForUserAgent", at: config),
                check("Interaction", "Back/Forward Gestures", "allowsBackForwardNavigationGestures"),
                check("", "Find & Replace", "findInteractionEnabled"),
                pop("Selection", "selectionGranularity", ["|Default", "character|Character"], at: config),
                .check(key: "Display", title: "Incremental Rendering", target: config, attribute: "suppressesIncrementalRendering",
                       isOn: d.value("suppressesIncrementalRendering", at: config) != "YES", onValue: nil, offValue: "YES"),
                check("", "Link Preview", "allowsLinkPreview", on: true),
                num("Min Font Size", "minimumFontSize", "0", at: prefs),
                check("Media", "AirPlay", "allowsAirPlayForMediaPlayback", on: true, at: config),
                check("", "Inline Playback", "allowsInlineMediaPlayback", at: config),
                check("", "Picture-in-Picture", "allowsPictureInPictureMediaPlayback", on: true, at: config),
                check("Interaction", "For Audio Playback", "audio", at: media), check("", "For Video Playback", "video", at: media),
            ] + dataDetectorRows(config + ">dataDetectorTypes@dataDetectorTypes") { _ in true } + [
                check("JavaScript", "Enabled", "javaScriptEnabled", on: true, at: prefs),
                check("", "Can Auto-open Windows", "javaScriptCanOpenWindowsAutomatically", at: prefs),
            ])
        case "arView":
            return IBInspectorSection("AR View", [check("Rendering", "Ray-Traced Shadows on Older Systems", "rayTracedShadowsOnOlderSystems")])
        case "roomCaptureView":
            return IBInspectorSection("Room Capture View", [check("Shows", "Captured Model", "showsCapturedModel")])
        case "clLocationButton":
            return IBInspectorSection("Core Location Button", [
                pop("Icon", "icon", ["|None", "arrowFilled|Arrow Filled", "arrowOutline|Arrow Outline"]),
                pop("Label", "label", ["|None", "currentLocation|Current Location", "sendCurrentLocation|Send Current Location",
                                       "sendMyCurrentLocation|Send My Current Location", "shareCurrentLocation|Share Current Location",
                                       "shareMyCurrentLocation|Share My Current Location"]),
                num("Font Size", "fontSize", ""), num("Corner Radius", "cornerRadius", ""),
            ])
        case "navigationBar":
            func attributes(_ heading: String, _ key: String) -> [IBInspectorRow] {
                let t = "\(id)>textAttributes@\(key)"
                return [.subheading(heading), fixed("Title Font", "Default"), color("Title Color", "textColor", at: t), color("Title Shadow", "shadowColor", at: t),
                        fixed("", "Default Position")]
            }
            return IBInspectorSection("Navigation Bar", [
                check("Appearances", "Standard", "@child:navigationBarAppearance@standardAppearance"),
                check("", "Compact", "@child:navigationBarAppearance@compactAppearance"),
                check("", "Scroll Edge", "@child:navigationBarAppearance@scrollEdgeAppearance"),
                check("", "Compact Scroll Edge", "@child:navigationBarAppearance@compactScrollEdgeAppearance"),
                pop("Style", "barStyle", Self.barStyles), check("", "Translucent", "translucent", on: true), check("", "Prefers Large Titles", "largeTitles"),
                color("Bar Tint", "barTintColor"),
                combo("Shadow", "shadowImage", "Shadow Image"), combo("Back", "backIndicatorImage", "Back Image"),
                combo("Back Mask", "backIndicatorTransitionMaskImage", "Back Mask Image"),
            ] + attributes("Title Text Attributes", "titleTextAttributes") + attributes("Large Title Text Attributes", "largeTitleTextAttributes"))
        case "toolbar":
            return IBInspectorSection("Toolbar", [
                check("Appearances", "Standard", "@child:toolbarAppearance@standardAppearance"),
                check("", "Compact", "@child:toolbarAppearance@compactAppearance"),
                check("", "Scroll Edge", "@child:toolbarAppearance@scrollEdgeAppearance"),
                check("", "Compact Scroll Edge", "@child:toolbarAppearance@compactScrollEdgeAppearance"),
                pop("Style", "barStyle", Self.barStyles), check("", "Translucent", "translucent", on: true), color("Bar Tint", "barTintColor"),
            ])
        case "tabBar":
            return IBInspectorSection("Tab Bar", [
                check("Appearances", "Standard", "@child:tabBarAppearance@standardAppearance"),
                check("", "Scroll Edge", "@child:tabBarAppearance@scrollEdgeAppearance"),
                combo("Background", "backgroundImage", "Background Image"), combo("Shadow", "shadowImage", "Shadow Image"),
                combo("Selection", "selectionIndicatorImage", "Selection Image"),
                color("Image Tint", "selectedImageTintColor"),
                pop("Style", "barStyle", Self.barStyles), check("", "Translucent", "translucent", on: true), color("Bar Tint", "barTintColor"),
                pop("Item Positioning", "itemPositioning", ["automatic|Automatic", "fill|Fill", "centered|Centered"]),
            ])
        case "searchBar":
            return IBInspectorSection("Search Bar", [
                text("Text", "text"), text("Placeholder", "placeholder"), text("Prompt", "prompt"),
                pop("Search Style", "searchBarStyle", ["default|Default", "prominent|Prominent", "minimal|Minimal"]),
                pop("Bar Style", "barStyle", Self.barStyles), check("", "Translucent", "translucent", on: true),
                color("Bar Tint", "barTintColor"),
                combo("Background", "backgroundImage", "Background Image"), combo("Scope Bar", "scopeBarBackgroundImage", "Scope Bar Image"),
                fixed("Search Text", "Default Position"), fixed("Background", "Default Position"),
                check("Behavior", "Enabled", "userInteractionEnabled", on: true),
                check("Capabilities", "Shows Search Results Button", "showsSearchResultsButton"),
                check("", "Shows Bookmarks Button", "showsBookmarkButton"),
                check("", "Shows Cancel Button", "showsCancelButton"),
                check("", "Shows Scope Bar", "showsScopeBar"),
                .list(key: "Scope Titles", items: (o.node.child("scopeButtonTitles")?.children ?? []).compactMap { $0["value"] }),
            ] + textInputTraits())
        default:
            return nil
        }
    }

    /// The Button section (all six UIButton kinds).
    func buttonSection() -> IBInspectorSection {
        let config = "\(id)>buttonConfiguration@configuration"
        let style = d.value("style", at: config)
        var rows: [IBInspectorRow] = [
            pop("Type", "buttonType", ["|Custom", "system|System", "detailDisclosure|Detail Disclosure", "infoLight|Info Light", "infoDark|Info Dark",
                                       "contactAdd|Add Contact", "close|Close"]),
            pop("Style", "style", ["plain|Plain", "gray|Gray", "tinted|Tinted", "filled|Filled"], at: config),
            fixed("Title", "Plain"),
            .text(label: "", target: id, attribute: "@title", value: d.title(of: id) ?? "", placeholder: ""),
            fixed("", "No Font"),
            fixed("Subtitle", "Plain"),
            text("", "subtitle", at: config),
            pop("Alignment", "titleAlignment", ["automatic|Default", "leading|Leading", "center|Center", "trailing|Trailing"], at: config),
            color("Foreground", "baseForegroundColor", at: config),
        ]
        if ["gray", "tinted", "filled"].contains(style ?? "") { rows.append(color("Background", "baseBackgroundColor", at: config)) }
        rows += [
            combo("Image", "image", "Image", at: config),
            .subheading("Background Configuration"),
            fixed("Background", "Default"),
            pop("Corner Style", "cornerStyle", ["dynamic|Default", "fixed|Fixed", "small|Small", "medium|Medium", "large|Large", "capsule|Capsule"], at: config),
            fixed("Content Insets", "Default"),
            check("Drawing", "Shows Activity Indicator", "showsActivityIndicator", at: config),
            pop("Role", "role", ["normal|Normal", "primary|Primary", "cancel|Cancel", "destructive|Destructive"]),
            check("Menu", "Selection as Primary Action", "changesSelectionAsPrimaryAction"),
            check("Pointer", "Interaction Enabled", "pointerInteraction"),
            check("Accessibility", "Adjusts Image Size", "adjustsImageSizeForAccessibilityContentSizeCategory"),
            nums("Shadow Offset", [("Width", "width", "0"), ("Height", "height", "0")], at: "\(id)>size@titleShadowOffset"),
            check("", "Reverses On Highlight", "reversesTitleShadowWhenHighlighted"),
            check("Drawing", "Shows Touch On Highlight", "showsTouchWhenHighlighted"),
            check("", "Highlighted Adjusts Image", "adjustsImageWhenHighlighted", on: true),
            check("", "Disabled Adjusts Image", "adjustsImageWhenDisabled", on: true),
            pop("Line Break", "lineBreakMode", Self.lineBreaks, "middleTruncation"),
            check("Drag and Drop", "Spring Loaded", "springLoaded"),
            pop("Behavior", "behavioralStyle", ["automatic|Automatic", "pad|Pad", "mac|Mac"]),
        ]
        return IBInspectorSection("Button", rows)
    }
}

extension IBDocument {
    /// The Attributes inspector's sections for object `id`; empty when
    /// unknown. `segment` is the segmented control segment the Segment
    /// pop-up shows.
    public func attributesSections(_ id: String, segment: Int = 0) -> [IBInspectorSection] {
        guard let o = byID[id] else { return [] }
        // A scene row shows its controller's inspector.
        if o.element == "scene", let c = o.children.first(where: isController) { return attributesSections(c.id, segment: segment) }
        let rows = IBAttributeRows(d: self, o: o)
        if !isFlippedRuntime {
            // macOS documents: the View Controller and View sections.
            if isController(o) { return [rows.simulatedMetrics(), rows.viewControllerSection()] }
            return o.isView ? [rows.viewSection()] : []
        }
        return rows.sections(segment: segment)
    }

    /// Every attribute row's control type, for tests and the walk.
    public static func rowKind(_ r: IBInspectorRow) -> String {
        switch r {
        case .text: "text field"
        case .toggle, .check, .edgeToggle: "check box"
        case .choice, .popUp: "pop-up"
        case .number: "number"
        case .numbers: "numbers"
        case .combo: "combo box"
        case .color: "colour pop-up"
        case .icons: "icons"
        case .subheading: "sub-heading"
        case .list: "table"
        default: "other"
        }
    }
}
