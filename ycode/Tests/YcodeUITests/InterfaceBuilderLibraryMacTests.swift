import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// The macOS IDE's Library and Attributes inspector for every UIKit kind
/// (#84; `library.md`, `interface-builder.md`): each kind inserted through
/// the editor, its inspector built as controls, one field edited and
/// saved; the Library panel at the measured sizes, the icon/list and
/// details toggles, the search rule. Screenshots go to
/// `.build-ide/b3-shots/`.
private let ycodeRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized) struct InterfaceBuilderLibraryMacTests {
    typealias K = IBDocument.NewObject
    static let shots = ycodeRoot.appendingPathComponent(".build-ide/b3-shots")
    static let samples = ycodeRoot.appendingPathComponent("Samples/InterfaceBuilderSamples/Interface")

    func copy(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ib-mac-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let to = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: Self.samples.appendingPathComponent(name), to: to)
        return to
    }

    func shot(_ view: NSView, _ name: String, dark: Bool = false) throws {
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try FileManager.default.createDirectory(at: Self.shots, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: Self.shots.appendingPathComponent(name))
    }

    /// Selects what a kind needs (a table view for a cell, …) and inserts it.
    func insert(_ kind: K, in c: InterfaceBuilderController) throws -> String {
        let root = try #require(IBEditorSession.firstView(in: c.document))
        func host(_ k: K) throws -> IBDocument.Object {
            c.select(root)
            return try #require(c.insert(k).flatMap { c.document.byID[$0] }, "\(k)")
        }
        c.select(root)
        switch kind.placement {
        case .tableCell: c.select(try host(.tableView))
        case .collectionCell, .reusableView: c.select(try host(.collectionView))
        case .barItem: c.select(try host(.toolbar))
        case .barItemGroup: c.select(try host(.navigationBar).children.first { $0.element == "navigationItem" })
        case .navigationItem, .tabBarItem: c.select(try host(kind == .navigationItem ? .navigationBar : .tabBar))
        case .menuElement: c.select(try host(.pullDownButton).children.first { $0.element == "menu" })
        default: break
        }
        return try #require(c.insert(kind), "\(kind)")
    }

    /// Edits the first editable row of the Attributes inspector through the
    /// editor (as the controls do). False when there is none.
    func editOneField(_ c: InterfaceBuilderController) -> Bool {
        for row in c.inspectorSections(.attributes).flatMap(\.rows) {
            switch row {
            case .check(_, _, let t, let a, let on, let onV, let offV) where !a.hasPrefix("@"):
                c.setAttribute(a, on ? offV : onV, of: t)
                return true
            case .popUp(_, _, let a, let values, _, let value) where !a.hasPrefix("@") && values.count > 1:
                c.setChoice(row, values.first { $0 != value } ?? value)
                return true
            case .text(_, let t, let a, _, _) where !a.hasPrefix("@"):
                c.setAttribute(a, "Edited", of: t)
                return true
            default: continue
            }
        }
        return false
    }

    @Test(arguments: ["Main.storyboard", "Card.xib"])
    func everyKindInsertsInspectsEditsAndSaves(_ name: String) throws {
        _ = NSApplication.shared
        let url = try copy(name)
        let c = try InterfaceBuilderController(url: url)
        _ = c.view
        for kind in K.list(for: c.document) {
            let id = try insert(kind, in: c)
            #expect(c.selected?.id == id, "\(kind)")
            let before = try Data(contentsOf: url)
            let v = c.inspectorView(.attributes)
            #expect(!v.subviews.isEmpty, "\(kind)")
            #expect(editOneField(c), "\(kind)")
            #expect(try Data(contentsOf: url) != before, "\(kind)")
            #expect((try? IBDocument(url: url))?.byID[id] != nil, "\(kind)")
        }
    }

    @Test func colourAndIconRowsWriteThroughTheControls() throws {
        _ = NSApplication.shared
        let url = try copy("Main.storyboard")
        let c = try InterfaceBuilderController(url: url)
        _ = c.view
        c.select(id: "Rv1-aa-bb1")
        let id = try #require(c.insert(.label))
        let rows = c.inspectorSections(.attributes).flatMap(\.rows)
        let color = try #require(rows.first { $0.label == "Color" })
        c.setColor(color, "System Red Color")
        #expect(try String(contentsOf: url, encoding: .utf8).contains("<color key=\"textColor\" systemColor=\"systemRedColor\"/>"))
        let align = try #require(c.inspectorSections(.attributes).flatMap(\.rows).first { $0.label == "Alignment" })
        c.setChoice(align, "center")
        #expect(c.document.byID[id]?.attribute("textAlignment") == "center")
        let stack = NSStackView()
        stack.orientation = .vertical
        c.addSections(c.inspectorSections(.attributes), to: stack)
        let popUps = stack.subviews.flatMap(\.subviews).compactMap { $0 as? NSPopUpButton }
        #expect(popUps.contains { $0.titleOfSelectedItem == "System Red Color" })
        let segments = stack.subviews.flatMap(\.subviews).compactMap { $0 as? NSSegmentedControl }
        #expect(segments.contains { $0.segmentCount == 5 && $0.selectedSegment == 1 })
    }

    @Test func libraryPanelLayoutAndSearch() throws {
        _ = NSApplication.shared
        let doc = try IBDocument(url: Self.samples.appendingPathComponent("Main.storyboard"))
        let lib = LibraryController()
        lib.setObjects(for: doc)
        _ = lib.view
        #expect(lib.visibleTabs == [.objects, .image, .color, .symbols] && lib.tab == .objects)
        #expect(lib.objects.count == 80 && lib.view.frame.size == LibraryController.size)
        #expect(lib.search.frame == NSRect(x: 61, y: 10, width: 557, height: 36) && lib.filterIcon.frame == NSRect(x: 15, y: 11, width: 34, height: 34))
        #expect(lib.viewToggle.frame.origin == NSPoint(x: 616, y: 19) && lib.detailsToggle.frame.origin == NSPoint(x: 644, y: 19))
        #expect(lib.listScroll.frame == NSRect(x: 0, y: 94, width: 272, height: 410) && lib.table.rowHeight == 48)
        #expect(lib.detailName.frame == NSRect(x: 282, y: 103, width: 390, height: 21) && lib.detailScroll.frame.size == NSSize(width: 381, height: 339))
        // Filtering selects the first match; the detail area follows.
        lib.filter = "UIButton"
        #expect(lib.objects.count == 6 && lib.selectedObject == .button)
        #expect(lib.detail.name == "Button" && lib.detail.subtitle.hasPrefix("UIButton: "))
        try shot(lib.view, "library-mac-list.png")
        try shot(lib.view, "library-mac-list-dark.png", dark: true)
        lib.filter = ""
        lib.toggleIconView()
        #expect(lib.isIconView && lib.numberOfRows(in: lib.table) == 20 && lib.selectedObject == .label)
        try shot(lib.view, "library-mac-icons.png")
        lib.toggleDetails()
        #expect(!lib.showsDetails && lib.view.frame.width == 272 && lib.search.frame.width == 148 && lib.detailName.isHidden)
        try shot(lib.view, "library-mac-no-details.png")
        // Inserting reports the chosen kind.
        var inserted: K?
        lib.onInsertObject = { inserted = $0 }
        #expect(lib.insert(row: 3) && inserted == .tintedButton)
        // A xib lists 79 kinds; a source file shows Snippets and Symbols.
        lib.setObjects(for: try IBDocument(url: Self.samples.appendingPathComponent("Card.xib")))
        #expect(lib.objects.count == 79 && lib.objects.contains(.window) && !lib.objects.contains(.containerView))
        lib.setObjects(for: nil)
        #expect(lib.visibleTabs == [.snippets, .symbols] && lib.tab == .snippets)
    }

    @Test func inspectorAndOutlineShots() throws {
        _ = NSApplication.shared
        let url = try copy("Main.storyboard")
        let c = try InterfaceBuilderController(url: url)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        c.view.translatesAutoresizingMaskIntoConstraints = false
        w.contentView!.addSubview(c.view)
        NSLayoutConstraint.activate([c.view.widthAnchor.constraint(equalToConstant: 900), c.view.heightAnchor.constraint(equalToConstant: 700),
                                     c.view.topAnchor.constraint(equalTo: w.contentView!.topAnchor), c.view.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor)])
        for k: K in [.label, .filledButton, .switchControl, .tableView, .tapGesture, .navigationController] { _ = try insert(k, in: c) }
        c.select(id: "Rv1-aa-bb1")
        let sw = try #require(c.document.byID.values.first { $0.element == "switch" })
        for (kind, id) in [("switch", sw.id), ("label", try #require(c.document.byID.values.first { $0.element == "label" && $0.attribute("fixedFrame") != nil }).id)] {
            c.select(id: id)
            for dark in [false, true] {
                let v = c.inspectorView(.attributes)
                let box = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 260, height: max(400, v.fittingSize.height + 20)))
                v.translatesAutoresizingMaskIntoConstraints = false
                box.addSubview(v)
                NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: box.topAnchor, constant: 10), v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4)])
                try shot(box, "inspector-mac-\(kind)\(dark ? "-dark" : "").png", dark: dark)
            }
        }
        w.appearance = NSAppearance(named: .aqua)
        c.select(sw)
        c.view.layoutSubtreeIfNeeded()
        let rep = try #require(c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds))
        c.view.cacheDisplay(in: c.view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: Self.shots.appendingPathComponent("outline-mac.png"))
        // Outline rows carry Ycode's icons.
        #expect(IBIcon.of(object: sw, in: c.document) == IBIcon.of(element: "switch"))
    }
}
