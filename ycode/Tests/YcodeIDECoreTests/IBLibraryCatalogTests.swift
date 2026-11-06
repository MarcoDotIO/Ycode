import Foundation
import Testing
@testable import YcodeIDECore

/// The Library's UIKit objects and the Attributes inspector
/// (`library.md` §Reference Objects library, `interface-builder.md`
/// §Reference Attributes inspector), on the sample documents written for
/// Ycode: the lists and their order, the search rule, every kind inserted
/// into a storyboard and a xib with the spec's element and attributes, the
/// inspector's sections per kind, edits that write the document, and a
/// round trip that leaves unchanged documents byte-for-byte. Runs on macOS
/// and Linux.
@Suite struct IBLibraryCatalogTests {
    typealias K = IBDocument.NewObject

    func copy(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ib-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let to = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: IBEditorSessionTests.samples.appendingPathComponent(name), to: to)
        return to
    }

    // MARK: Lists and search

    @Test func listsInSpecOrder() {
        #expect(K.storyboardList.count == 80 && K.xibList.count == 79)
        #expect(K.storyboardList.first == .label && K.storyboardList.last == .customGesture)
        let names = K.storyboardList.map(\.rawValue)
        #expect(Array(names[0..<8]) == ["Label", "Button", "Gray Button", "Tinted Button", "Filled Button", "Pull Down Button", "Pop Up Button", "Segmented Control"])
        #expect(names[38] == "Web View (deprecated)" && names[53] == "Menu Command" && names[57] == "View" && names[71] == "Object")
        // The xib: no Main Menu, Container View or Storyboard Reference; Window
        // between Inline Section Menu and View, External Object after Object.
        let xib = K.xibList.map(\.rawValue)
        #expect(!xib.contains("Main Menu") && !xib.contains("Container View") && !xib.contains("Storyboard Reference"))
        #expect(xib[xib.firstIndex(of: "Inline Section Menu")! + 1] == "Window" && xib[xib.firstIndex(of: "Window")! + 1] == "View")
        #expect(xib[xib.firstIndex(of: "Object")! + 1] == "External Object" && xib[xib.firstIndex(of: "External Object")! + 1] == "Tap Gesture Recognizer")
        // Every kind has Ycode's own texts and an icon.
        #expect(K.allCases.allSatisfy { !$0.summary.isEmpty && !$0.details.isEmpty && !$0.icon.shapes.isEmpty })
        #expect(K.longPressGesture.element == "pongPressGestureRecognizer" && K.mapView.className == "MKMapView")
        #expect(K.button.subtitle() == "UIButton: \(K.button.summary)")
    }

    @Test func searchRule() {
        func q(_ s: String) -> [String] { K.matching(s).map(\.rawValue) }
        #expect(q("UISwitch") == ["Switch"] && q("uiswitch") == ["Switch"])
        #expect(q("UIButton") == ["Button", "Gray Button", "Tinted Button", "Filled Button", "Pull Down Button", "Pop Up Button"])
        #expect(q("ton") == K.storyboardList.map(\.rawValue).filter { $0.contains("Button") })
        #expect(q("stack view") == ["Horizontal Stack View", "Vertical Stack View"])
        #expect(q("map") == ["Map Kit View"] && q("MKMapView") == ["Map Kit View"])
        #expect(q("tap") == ["Tap Gesture Recognizer"])
        #expect(q("Page Control").contains("Page View Controller"))
        for nothing in ["toggle", "spinner", "checkbox", "picture", "html", "list", "grid", "Presents", "on and off"] { #expect(q(nothing).isEmpty, "\(nothing)") }
        #expect(K.matching("").count == 80)
    }

    // MARK: Inserting every kind

    /// Prepares the selection a kind needs (a table view for a cell, a
    /// toolbar for a bar button item, …) and inserts it.
    func insert(_ kind: K, in s: IBEditorSession) throws -> String {
        let root = try #require(IBEditorSession.firstView(in: s.document))
        s.select(id: root.id)
        func host(_ k: K) throws -> IBDocument.Object {
            s.select(id: root.id)
            return try #require(s.insert(k).flatMap { s.document.byID[$0] }, "\(k)")
        }
        switch kind.placement {
        case .tableCell: s.select(id: try host(.tableView).id)
        case .collectionCell, .reusableView: s.select(id: try host(.collectionView).id)
        case .barItem: s.select(id: try host(.toolbar).id)
        case .barItemGroup, .navigationItem: s.select(id: try host(.navigationBar).children.first { $0.element == "navigationItem" }?.id ?? root.id)
        case .tabBarItem: s.select(id: try host(.tabBar).id)
        case .menuElement: s.select(id: try host(.pullDownButton).children.first { $0.element == "menu" }?.id ?? root.id)
        default: break
        }
        if kind == .navigationItem { s.select(id: try host(.navigationBar).id) }
        return try #require(s.insert(kind), "\(kind) into \(s.url.lastPathComponent)")
    }

    /// The attributes the spec's tables give for each kind (`library.md`
    /// §Object list and §Insert defaults).
    static let expected: [K: [String: String]] = [
        .label: ["text": "Label", "textAlignment": "natural", "lineBreakMode": "tailTruncation", "baselineAdjustment": "alignBaselines", "userInteractionEnabled": "NO"],
        .button: ["buttonType": "system", "lineBreakMode": "middleTruncation", "contentHorizontalAlignment": "center"],
        .pullDownButton: ["showsMenuAsPrimaryAction": "YES"],
        .popUpButton: ["showsMenuAsPrimaryAction": "YES", "changesSelectionAsPrimaryAction": "YES"],
        .segmentedControl: ["segmentControlStyle": "plain", "selectedSegmentIndex": "0", "contentHorizontalAlignment": "left", "contentVerticalAlignment": "top"],
        .textField: ["borderStyle": "roundedRect", "textAlignment": "natural", "minimumFontSize": "17"],
        .slider: ["value": "0.5", "minValue": "0.0", "maxValue": "1"],
        .switchControl: ["on": "YES", "horizontalHuggingPriority": "750"],
        .progressView: ["progress": "0.5"],
        .activityIndicator: ["style": "medium"],
        .verticalStackView: ["axis": "vertical"],
        .tableView: ["dataMode": "prototypes", "style": "plain", "separatorStyle": "default", "rowHeight": "-1", "alwaysBounceVertical": "YES"],
        .tableViewCell: ["selectionStyle": "default", "indentationWidth": "10", "preservesSuperviewLayoutMargins": "YES"],
        .imageView: ["contentMode": "scaleAspectFit", "clipsSubviews": "YES", "userInteractionEnabled": "NO"],
        .collectionView: ["dataMode": "prototypes"],
        .textView: ["textAlignment": "natural"],
        .searchBar: ["contentMode": "redraw"],
        .fixedSpace: ["style": "plain", "systemItem": "fixedSpace"],
        .flexibleSpace: ["style": "plain", "systemItem": "flexibleSpace"],
        .swipeGesture: ["direction": "right"],
        .panGesture: ["minimumNumberOfTouches": "1"],
        .screenEdgePanGesture: ["minimumNumberOfTouches": "1"],
        .longPressGesture: ["allowableMovement": "10", "minimumPressDuration": "0.5"],
    ]

    /// Children the spec names, as "element" or "element@key".
    static let expectedChildren: [K: [String]] = [
        .label: ["fontDescription@fontDescription", "nil@textColor", "nil@highlightedColor"],
        .button: ["state@normal", "buttonConfiguration@configuration"],
        .pullDownButton: ["menu@menu", "state@normal", "buttonConfiguration@configuration"],
        .segmentedControl: ["segments"],
        .textField: ["fontDescription@fontDescription", "textInputTraits@textInputTraits"],
        .tableViewCell: ["tableViewCellContentView@contentView"],
        .collectionView: ["collectionViewFlowLayout@collectionViewLayout", "cells"],
        .collectionViewCell: ["collectionViewCellContentView@contentView"],
        .scrollView: ["viewLayoutGuide@contentLayoutGuide", "viewLayoutGuide@frameLayoutGuide"],
        .blurView: ["view@contentView", "blurEffect"],
        .vibrancyView: ["view@contentView", "blurEffect"],
        .webKitView: ["wkWebViewConfiguration@configuration"],
        .navigationBar: ["items"], .toolbar: ["items"], .tabBar: ["items"],
        .searchBar: ["textInputTraits@textInputTraits"],
        .textView: ["fontDescription@fontDescription", "textInputTraits@textInputTraits"],
        .navigationController: ["navigationBar@navigationBar"],
        .tableViewController: ["tableView@view"], .collectionViewController: ["collectionView@view"],
        .tabBarController: ["tabBar@tabBar"], .glkViewController: ["glkView@view"],
    ]

    @Test(arguments: ["Main.storyboard", "Card.xib"])
    func everyKindInsertsAsSpecified(_ name: String) throws {
        let url = try copy(name)
        let original = try Data(contentsOf: url)
        let s = try IBEditorSession(url: url)
        let list = K.list(for: s.document)
        #expect(list.count == (s.document.isStoryboard ? 80 : 79))
        for kind in list {
            let id = try insert(kind, in: s)
            let o = try #require(s.document.byID[id], "\(kind)")
            #expect(o.element == kind.element, "\(kind)")
            for (a, v) in Self.expected[kind] ?? [:] { #expect(o.attribute(a) == v, "\(kind) \(a)") }
            for c in Self.expectedChildren[kind] ?? [] {
                let parts = c.split(separator: "@").map(String.init)
                #expect(o.node.children.contains { $0.name == parts[0] && (parts.count == 1 || $0["key"] == parts[1]) }, "\(kind) child \(c)")
            }
            if kind.placement == .subview {
                // The three-part frame rule (library.md §Insert defaults, item 3).
                #expect(o.attribute("fixedFrame") == "YES" && o.attribute("translatesAutoresizingMaskIntoConstraints") == "NO", "\(kind)")
                let mask = try #require(o.node.child("autoresizingMask", key: "autoresizingMask"), "\(kind)")
                #expect(mask["flexibleMaxX"] == "YES" && mask["flexibleMaxY"] == "YES" && o.node.children.first?.name == "rect", "\(kind)")
                // The canonical order: fixedFrame after the common and hugging
                // attributes, translatesAutoresizingMaskIntoConstraints then id last.
                let names = o.attributes.map(\.0)
                #expect(Array(names.suffix(2)) == ["translatesAutoresizingMaskIntoConstraints", "id"], "\(kind)")
                if let h = names.firstIndex(of: "contentHorizontalAlignment") { #expect(names.firstIndex(of: "fixedFrame")! < h, "\(kind)") }
                if let size = kind.info.width, kind != .tableViewCell { #expect(o.frame?.width == size, "\(kind)") }
            }
            if kind.placement == .gesture {
                #expect(s.document.incomingConnections(to: id).contains { $0.connection.name == "gestureRecognizers" }, "\(kind)")
            }
            if kind.placement == .scene && s.document.isStoryboard {
                #expect(o.parent?.element == "scene" && o.parent?.canvasLocation != nil, "\(kind)")
                if kind != .mainMenu { #expect(o.attribute("sceneMemberID") == "viewController", "\(kind)") }
            }
            // The inspector shows the kind, and an edit is saved.
            let sections = s.inspectorSections(.attributes)
            #expect(!sections.isEmpty, "\(kind)")
            #expect(s.saveCount > 0)
        }
        // Defaults the spec marks: the label's older size; the spec's table views' background colour resource.
        let doc = try IBDocument(url: url)
        let text = String(decoding: doc.source, as: UTF8.self)
        #expect(text.contains("<systemColor name=\"systemBackgroundColor\">") && text.contains("<systemColor name=\"labelColor\">"))
        #expect(text.contains("<pongPressGestureRecognizer allowableMovement=\"10\" minimumPressDuration=\"0.5\""))
        #expect(K.label.defaultSize == CGSize(width: 42, height: 21) && K.switchControl.defaultSize == CGSize(width: 51, height: 31))
        // Undo everything: the original bytes.
        while s.canUndo { s.undo() }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func labelLinesMatchTheCanonicalForm() throws {
        let s = try IBEditorSession(url: try copy("Main.storyboard"))
        let id = try #require(s.insert(.label))
        let text = String(decoding: s.document.source, as: UTF8.self)
        let f = try #require(s.document.byID[id]?.frame)
        #expect(text.contains("""
            <label opaque="NO" userInteractionEnabled="NO" contentMode="left" horizontalHuggingPriority="251" verticalHuggingPriority="251" fixedFrame="YES" text="Label" textAlignment="natural" lineBreakMode="tailTruncation" baselineAdjustment="alignBaselines" adjustsFontSizeToFit="NO" translatesAutoresizingMaskIntoConstraints="NO" id="\(id)">
                                            <rect key="frame" x="\(IBDocument.number(f.minX))" y="\(IBDocument.number(f.minY))" width="42" height="21"/>
                                            <autoresizingMask key="autoresizingMask" flexibleMaxX="YES" flexibleMaxY="YES"/>
                                            <fontDescription key="fontDescription" type="system" pointSize="17"/>
                                            <nil key="textColor"/>
                                            <nil key="highlightedColor"/>
                                        </label>
            """))
    }

    // MARK: The Attributes inspector

    func sections(_ kind: K, file: String = "Main.storyboard") throws -> (IBEditorSession, String, [String]) {
        let s = try IBEditorSession(url: try copy(file))
        let id = try insert(kind, in: s)
        return (s, id, s.inspectorSections(.attributes).map(\.title))
    }

    @Test func sectionOrderPerKind() throws {
        let cases: [(K, [String])] = [
            (.label, ["Label", "View"]), (.button, ["Button", "Control", "View"]), (.switchControl, ["Switch", "Control", "View"]),
            (.segmentedControl, ["Segmented Control", "Control", "View"]), (.textField, ["Text Field", "Control", "View"]),
            (.activityIndicator, ["Activity Indicator View", "View"]), (.horizontalStackView, ["Stack View", "View"]),
            (.tableView, ["Table View", "Scroll View", "View"]), (.textView, ["Text View", "Scroll View", "View"]),
            (.scrollView, ["Scroll View", "View"]), (.pickerView, ["View"]), (.view, ["View"]), (.mapView, ["Map View", "View"]),
            (.webKitView, ["Web View", "View"]), (.navigationBar, ["Navigation Bar", "View"]), (.searchBar, ["Search Bar", "View"]),
            (.viewController, ["Simulated Metrics", "View Controller"]),
            (.navigationController, ["Simulated Metrics", "Navigation Controller", "View Controller"]),
            (.splitViewController, ["Simulated Metrics", "Split View Controller", "View Controller"]),
            (.storyboardReference, ["Storyboard Reference"]), (.object, ["Object"]),
            (.barButtonItem, ["Bar Button Item", "Bar Item"]), (.tabBarItem, ["Tab Bar Item", "Bar Item"]), (.navigationItem, ["Navigation Item"]),
            (.subMenu, ["Menu"]), (.command, ["Command"]), (.tapGesture, ["Tap Gesture Recognizer", "Gesture Recognizer"]),
            (.screenEdgePanGesture, ["Screen Edge Pan Gesture Recognizer", "Pan Gesture Recognizer", "Gesture Recognizer"]),
            (.customGesture, ["Gesture Recognizer"]),
        ]
        for (kind, expected) in cases { #expect(try sections(kind).2 == expected, "\(kind)") }
        // A scene shows its controller's inspector.
        let (ss, vcID, _) = try sections(.viewController)
        let scene = try #require(ss.document.byID[vcID]?.parent)
        #expect(ss.document.attributesSections(scene.id).map(\.title) == ["Simulated Metrics", "View Controller"])
        // Split view controllers have no Top Bar.
        let (s, _, _) = try sections(.splitViewController)
        #expect(s.inspectorSections(.attributes)[0].rows.map(\.label) == ["Size", "Bottom Bar", "Keyboard"])
    }

    @Test func sharedSectionsFollowTheSpec() throws {
        let (s, id, _) = try sections(.switchControl)
        let a = s.inspectorSections(.attributes)
        let view = try #require(a.first { $0.title == "View" })
        #expect(view.rows.map(\.key) == ["Content Mode", "Semantic", "Tag", "Interaction", "", "Alpha", "Background", "Tint", "Drawing", "", "", "", "",
                                         "Stretching", ""])
        #expect(view.rows.map(\.label).suffix(1) == ["Installed"])
        #expect(view.rows.contains(.popUp(key: "Content Mode", target: id, attribute: "contentMode",
                                          values: IBAttributeRows.pairs(["scaleToFill", "scaleAspectFit", "scaleAspectFill", "redraw", "center", "top", "bottom",
                                                                         "left", "right", "topLeft", "topRight", "bottomLeft", "bottomRight"]).values,
                                          titles: ["Scale To Fill", "Aspect Fit", "Aspect Fill", "Redraw", "Center", "Top", "Bottom", "Left", "Right",
                                                   "Top Left", "Top Right", "Bottom Left", "Bottom Right"], value: "scaleToFill")))
        let control = try #require(a.first { $0.title == "Control" })
        #expect(control.rows.map(\.label) == ["Horizontal", "Vertical", "Shows as Primary Action", "Selected", "Enabled", "Highlighted", "Tooltip"])
        let sw = try #require(a.first { $0.title == "Switch" })
        #expect(sw.rows.map(\.label) == ["Title", "Style", "State", "On Tint", "Thumb Tint"])
        #expect(sw.rows.map(IBDocument.rowKind) == ["text field", "pop-up", "pop-up", "colour pop-up", "colour pop-up"])
        // Controllers: the View Controller section's groups.
        let (vs, _, _) = try sections(.viewController)
        let vc = try #require(vs.inspectorSections(.attributes).first { $0.title == "View Controller" })
        #expect(vc.rows.map(\.label).prefix(4) == ["Title", "Is Initial View Controller", "Activity Name", "Adjust Scroll View Insets"])
        #expect(vc.rows.map(\.key).contains("Extend Edges") == false && vc.rows.contains { $0.label == "Under Top Bars" })
        // Gesture recognizers end with Gesture Recognizer.
        let (gs, _, _) = try sections(.longPressGesture)
        #expect(gs.inspectorSections(.attributes).first?.rows.map(\.label) == ["Min Duration", "Recognize", "Tolerance"])
    }

    @Test func editsWriteTheDocument() throws {
        let url = try copy("Main.storyboard")
        let s = try IBEditorSession(url: url)
        func row(_ label: String) -> IBInspectorRow? { s.inspectorSections(.attributes).flatMap(\.rows).first { $0.label == label } }
        func saved() throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

        // A pop-up by title, a check box, a number, a colour with its resource.
        let sw = try #require(s.insert(.switchControl))
        s.setChoice(try #require(row("State")), "Off")
        #expect(s.document.byID[sw]?.attribute("on") == "NO")
        s.setToggle(try #require(row("Hidden")), on: true)
        #expect(s.document.byID[sw]?.attribute("hidden") == "YES")
        s.setColor(try #require(row("On Tint")), "System Green Color")
        #expect(try saved().contains("<color key=\"onTintColor\" systemColor=\"systemGreenColor\"/>") && (try saved()).contains("<systemColor name=\"systemGreenColor\">"))
        s.setColor(try #require(row("On Tint")), "Default")
        #expect(try !saved().contains("onTintColor"))

        // Keyed child elements: Text Input Traits, made when missing.
        let tf = try #require(s.insert(.textField))
        s.setChoice(try #require(row("Keyboard Type")), "E-mail Address")
        #expect(s.document.value("keyboardType", at: "\(tf)>textInputTraits@textInputTraits") == "emailAddress")
        s.setChoice(try #require(row("Font")), "Headline")
        #expect(try saved().contains("<fontDescription key=\"fontDescription\" style=\"UICTFontTextStyleHeadline\"/>"))
        let label = try #require(s.insert(.label))
        let stretch = try #require(row("Stretching"))
        guard case .numbers(_, let fields) = stretch else { Issue.record("Stretching"); return }
        s.setAttribute(fields[2].attribute, "0.5", of: fields[2].target)
        #expect(try saved().contains("<rect key=\"contentStretch\" x=\"0.0\" y=\"0.0\" width=\"0.5\" height=\"1\"/>"))
        #expect(s.document.byID[label] != nil)

        // Segments: count, then the second segment's title.
        let seg = try #require(s.insert(.segmentedControl))
        s.setAttribute("@segments", "3", of: seg)
        #expect(s.document.byID[seg]?.node.child("segments")?.children.count == 3)
        s.setChoice(try #require(row("Segment")), "1")
        #expect(s.inspectorSegment == 1)
        s.setAttribute("title", "Middle", of: "\(seg)>segments>segment#1")
        #expect(s.document.value("title", at: "\(seg)>segments>segment#1") == "Middle")

        // Table view: prototype cells by count; collection view: section header.
        let table = try #require(s.insert(.tableView))
        s.setAttribute("@prototypes", "2", of: table)
        #expect(s.document.byID[table]?.children.filter { $0.element == "tableViewCell" }.count == 2)
        s.select(id: try #require(IBEditorSession.firstView(in: s.document)?.id))
        let cv = try #require(s.insert(.collectionView))
        s.setToggle(try #require(row("Section Header")), on: true)
        #expect(s.document.byID[cv]?.children.contains { $0.key == "sectionHeaderView" } == true)
        s.select(id: try #require(IBEditorSession.firstView(in: s.document)?.id))
        _ = try #require(s.insert(.navigationBar))
        s.setToggle(try #require(row("Standard")), on: true)
        #expect(try saved().contains("<navigationBarAppearance key=\"standardAppearance\"/>"))

        // Button title writes the state and the configuration.
        s.select(id: try #require(IBEditorSession.firstView(in: s.document)?.id))
        let b = try #require(s.insert(.filledButton))
        s.setAttribute("@title", "Go", of: b)
        #expect(s.document.byID[b]?.node.child("buttonConfiguration")?["title"] == "Go" && s.document.title(of: b) == "Go")
        #expect(row("Background") != nil)   // Filled buttons have a background colour row.
        #expect((try? IBDocument(url: url)) != nil)
    }

    // MARK: Round trip

    @Test(arguments: ["Main.storyboard", "Card.xib"])
    func unchangedDocumentsStayByteForByte(_ name: String) throws {
        // A document holding every kind, saved by Ycode, then reopened.
        let url = try copy(name)
        let s = try IBEditorSession(url: url)
        for kind in K.list(for: s.document) { _ = try insert(kind, in: s) }
        let full = try Data(contentsOf: url)
        // YCODE_IB_DUMP=<folder>: keep the document with every kind, for review.
        if let dump = ProcessInfo.processInfo.environment["YCODE_IB_DUMP"] { try? full.write(to: URL(fileURLWithPath: dump).appendingPathComponent("all-kinds-\(name)")) }
        for file in [url, IBEditorSessionTests.samples.appendingPathComponent(name)] {
            let before = try Data(contentsOf: file)
            let r = try IBEditorSession(url: file)
            r.writesFile = file == url
            var seen = 0
            for root in r.document.roots {
                root.walk { o in
                    r.select(id: o.id)
                    for t in IBInspectorTab.allCases { _ = r.inspectorSections(t) }
                    _ = IBIcon.of(object: o, in: r.document)
                    seen += 1
                }
            }
            _ = r.outlineRows
            #expect(seen > 1)
            #expect(try Data(contentsOf: file) == before && r.saveCount == 0 && !r.canUndo)
        }
        #expect(try Data(contentsOf: url) == full)
        // Every object is still where it was: the reopened file parses to the same IDs.
        #expect(Set(try IBDocument(url: url).byID.keys) == Set(s.document.byID.keys))
    }
}
