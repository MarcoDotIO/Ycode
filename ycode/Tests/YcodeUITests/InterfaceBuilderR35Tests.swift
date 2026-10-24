import AppKit
import Foundation
import Testing
@testable import YcodeUI

/// reference-ui-4.md §13 leftovers (reference-ui-5.md §11.6, P14).
@MainActor
@Suite struct InterfaceBuilderR35Tests {
    func controller() throws -> InterfaceBuilderController {
        InterfaceBuilderController(document: try IBDocument(data: Data(iosStoryboard.utf8)))
    }

    func labels(_ sections: [IBInspectorSection], _ title: String) -> [String] { sections.first { $0.title == title }?.rows.map(\.label) ?? [] }

    @Test func identitySectionForEveryObject() throws {
        let c = try controller()
        c.select(id: "lbl")
        #expect(c.inspectorSections(.identity).map(\.title) == ["Custom Class", "Identity", "User Defined Runtime Attributes", "Document"])
        #expect(labels(c.inspectorSections(.identity), "Identity") == ["Storyboard ID", "Restoration ID", "Use Storyboard ID"])
    }

    @Test func labelAndViewAttributesInReferenceOrder() throws {
        let c = try controller()
        c.select(id: "lbl")
        let a = c.inspectorSections(.attributes)
        #expect(labels(a, "Label") == ["Text", "", "Color", "Font", "Dynamic Type", "Alignment", "Lines", "Enabled", "Highlighted", "Tooltip",
                                       "Baseline", "Line Break", "Strategy", "Autoshrink", "Tighten Letter Spacing", "Sizing Rule",
                                       "Highlighted Color", "Shadow", "Shadow Offset"])
        let label = try #require(a.first { $0.title == "Label" })
        #expect(label.rows.contains(.info(label: "Color", value: "Default (Label Color)")) && label.rows.contains(.info(label: "Font", value: "Default")))
        #expect(label.rows.contains(.info(label: "Shadow Offset", value: "0, -1")))
        let view = labels(a, "View")
        for l in ["Content Mode", "Semantic", "Tag", "Alpha", "Background", "Tint", "Stretching"] { #expect(view.contains(l), "\(l)") }
        #expect(a.first { $0.title == "View" }?.rows.contains(.info(label: "Stretching", value: "0, 0, 1, 1")) == true)
        // Tooltip and Sizing Rule write attributes.
        c.setAttribute("toolTip", "Greeting", of: "lbl")
        c.setAttribute("sizingRule", "oversize", of: "lbl")
        #expect(c.document.byID["lbl"]?.attribute("toolTip") == "Greeting" && c.document.byID["lbl"]?.attribute("sizingRule") == "oversize")
    }

    @Test func valueChildElementsAreDescribed() throws {
        let frame = "<rect key=\"frame\" x=\"20\" y=\"100\" width=\"100\" height=\"21\"/>"
        let text = iosStoryboard.replacingOccurrences(of: frame, with: frame
            + "\n<fontDescription key=\"fontDescription\" type=\"system\" pointSize=\"17\"/>"
            + "\n<color key=\"textColor\" systemColor=\"secondaryLabelColor\"/>"
            + "\n<size key=\"shadowOffset\" width=\"1\" height=\"2\"/>")
        #expect(text != iosStoryboard)
        let c = InterfaceBuilderController(document: try IBDocument(data: Data(text.utf8)))
        c.select(id: "lbl")
        let label = try #require(c.inspectorSections(.attributes).first { $0.title == "Label" })
        #expect(label.rows.contains(.info(label: "Font", value: "System 17.0")))
        #expect(label.rows.contains(.info(label: "Color", value: "Secondary Label Color")))
        #expect(label.rows.contains(.info(label: "Shadow Offset", value: "1, 2")))
    }

    @Test func sizeFrameFieldsEditTheFrame() throws {
        let c = try controller()
        c.select(id: "lbl")
        let view = try #require(c.inspectorSections(.size).first { $0.title == "View" })
        #expect(view.rows.map(\.label).prefix(8) == ["Show", "X", "Y", "Width", "Height", "Arrange", "Layout", "Layout Margins"])
        #expect(view.rows.contains(.frameValue(label: "Width", target: "lbl", component: "width", value: "100")))
        #expect(view.rows.contains(.info(label: "Layout Margins", value: "Default")))
        c.setFrameComponent("width", 140, of: "lbl")
        c.setFrameComponent("x", 24, of: "lbl")
        #expect(c.document.byID["lbl"]?.frame == CGRect(x: 24, y: 100, width: 140, height: 21))
        #expect(String(decoding: c.document.source, as: UTF8.self).contains("<rect key=\"frame\" x=\"24\" y=\"100\" width=\"140\" height=\"21\"/>"))
    }

    @Test func extendEdgesToggles() throws {
        let c = try controller()
        c.select(id: "vc")
        let edges = try #require(c.inspectorSections(.attributes).first { $0.title == "Extend Edges" })
        #expect(edges.rows.prefix(2) == [.edgeToggle(label: "Under Top Bars", target: "vc", edge: "top", isOn: true),
                                         .edgeToggle(label: "Under Bottom Bars", target: "vc", edge: "bottom", isOn: true)])
        c.setExtendedEdge("top", false, of: "vc")
        let src = String(decoding: c.document.source, as: UTF8.self)
        #expect(src.contains("<extendedEdge key=\"edgesForExtendedLayout\" left=\"YES\" bottom=\"YES\" right=\"YES\"/>"))
        #expect(c.document.extendedEdge(c.document.byID["vc"]!, "top") == false && c.document.extendedEdge(c.document.byID["vc"]!, "bottom"))
        c.setExtendedEdge("top", true, of: "vc")
        #expect(c.document.extendedEdge(c.document.byID["vc"]!, "top"))
        // The file still parses after each edit.
        #expect((try? IBDocument(data: Data(c.document.source))) != nil)
        let content = try #require(c.inspectorSections(.attributes).first { $0.title == "Content Size" })
        #expect(content.rows.map(\.label) == ["Use Preferred Explicit Size", "Width", "Height"])
    }
}
