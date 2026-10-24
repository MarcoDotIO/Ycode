import AppKit
import Foundation
import Testing
@testable import YcodeUI

/// An iOS storyboard written for this test in the documented XML layout.
let iosStoryboard = """
<?xml version="1.0" encoding="UTF-8"?>
<document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" toolsVersion="1" targetRuntime="iOS.CocoaTouch" propertyAccessControl="none" useAutolayout="YES" useSafeAreas="YES" initialViewController="vc">
    <scenes>
        <scene sceneID="sc">
            <objects>
                <viewController id="vc" customClass="ViewController" customModule="Demo" customModuleProvider="target" sceneMemberID="viewController">
                    <view key="view" contentMode="scaleToFill" id="root">
                        <rect key="frame" x="0.0" y="0.0" width="393" height="852"/>
                        <subviews>
                            <label text="Hello" textAlignment="natural" translatesAutoresizingMaskIntoConstraints="NO" id="lbl">
                                <rect key="frame" x="20" y="100" width="100" height="21"/>
                            </label>
                            <button contentMode="scaleToFill" translatesAutoresizingMaskIntoConstraints="NO" id="btn">
                                <rect key="frame" x="20" y="200" width="60" height="35"/>
                                <state key="normal" title="Tap"/>
                            </button>
                        </subviews>
                        <viewLayoutGuide key="safeArea" id="safe"/>
                        <constraints>
                            <constraint firstItem="lbl" firstAttribute="leading" secondItem="safe" secondAttribute="leading" constant="20" id="c1"/>
                            <constraint firstItem="lbl" firstAttribute="top" secondItem="safe" secondAttribute="top" constant="41" id="c2"/>
                        </constraints>
                    </view>
                    <connections>
                        <outlet property="label" destination="lbl" id="o1"/>
                    </connections>
                </viewController>
                <placeholder placeholderIdentifier="IBFirstResponder" id="fr" sceneMemberID="firstResponder"/>
                <exit id="ex" userLabel="Exit" sceneMemberID="exit"/>
            </objects>
            <point key="canvasLocation" x="0" y="0"/>
        </scene>
    </scenes>
</document>
"""

/// reference-ui-4.md §11, §13: outline, jump bar, chrome, inspectors.
@MainActor
@Suite(.serialized) struct InterfaceBuilderReferenceUITests {
    func controller() throws -> InterfaceBuilderController {
        InterfaceBuilderController(document: try IBDocument(data: Data(iosStoryboard.utf8)))
    }

    @Test func outlineTree() throws {
        let c = try controller()
        #expect(c.outlineTitlesWithBadges == [
            "ViewController Scene",
            "  ViewController",
            "    View",
            "      Safe Area",
            "      Hello [Label]",
            "      Tap [Button]",
            "      Constraints",
            "        Label - Hello.leading = Safe Area.leading + 20",
            "        Label - Hello.top = Safe Area.top + 41",
            "  First Responder",
            "  Exit",
            "  Storyboard Entry Point",
        ].map { $0.replacingOccurrences(of: "Safe Area.", with: "View Layout Guide.") })
        c.outlineFilter = "tap"
        #expect(c.outlineTitles == ["ViewController Scene", "  ViewController", "    View", "      Tap [Button]"].map { $0.replacingOccurrences(of: " [Button]", with: "") })
    }

    @Test func selectionJumpBarAndChrome() throws {
        let c = try controller()
        _ = c.view
        c.select(id: "lbl")
        #expect(c.jumpBarPath == ["/", "ViewController Scene", "ViewController", "View", "Hello"])
        #expect(c.jumpBarText.hasSuffix("View › Hello"))
        #expect(c.canvas.selectedID == "lbl" && c.canvas.constraintGuides(for: c.selected!).count == 2)
        #expect(c.canvasBarItems == ["Hide Document Outline", "Library", "No Issues", "Appearance", "Orientation", "Layout",
                                     "device:iPhone 16", "−", c.zoomText, "+",
                                     "Update Frames", "Align", "Add New Constraints", "Resolve Auto Layout Issues", "Embed In"])
        #expect(c.isOutlineVisible)
        c.toggleOutline(nil)
        #expect(!c.isOutlineVisible)
        c.setZoom(0.5)
        #expect(c.bar.zoomLabel.stringValue == "50%")
        // Scene title bar names the controller; the entry arrow exists.
        c.canvas.frame = NSRect(origin: .zero, size: c.canvas.frame.size)
        _ = c.canvas.bitmapImageRepForCachingDisplay(in: c.canvas.bounds).map { c.canvas.cacheDisplay(in: c.canvas.bounds, to: $0) }
        #expect(c.canvas.sceneBars.map(\.title) == ["ViewController"])
        #expect(c.canvas.entryPoint != nil)
    }

    @Test func identityAndAttributesWriteXML() throws {
        let c = try controller()
        c.select(id: "vc")
        let id = c.inspectorSections(.identity)
        #expect(id.map(\.title) == ["Custom Class", "Identity", "User Defined Runtime Attributes", "Document"])
        #expect(id[3].rows.contains(.info(label: "Object ID", value: "vc")))
        c.setAttribute("storyboardIdentifier", "Main", of: "vc")
        c.setAttribute("userLabel", "Home", of: "vc")
        #expect(c.document.byID["vc"]?.attribute("storyboardIdentifier") == "Main")
        #expect(c.document.byID["vc"]?.attribute("userLabel") == "Home")
        c.addRuntimeAttribute(keyPath: "layer.cornerRadius", type: "number", value: "4")
        #expect(c.document.runtimeAttributes(of: "vc") == [.init(keyPath: "layer.cornerRadius", type: "number", value: "4")])
        c.removeRuntimeAttribute("layer.cornerRadius")
        #expect(c.document.runtimeAttributes(of: "vc").isEmpty && c.document.byID["vc"]?.node.child("userDefinedRuntimeAttributes") == nil)
        let attrs = c.inspectorSections(.attributes).map(\.title)
        #expect(attrs == ["Simulated Metrics", "View Controller", "Layout", "Extend Edges", "Presentation", "Content Size", "Key Commands"])
        c.setAttribute("initialViewController", nil, of: "vc")
        #expect(c.document.initialViewController == nil)
        c.setAttribute("initialViewController", "vc", of: "vc")
        #expect(c.document.initialViewController == "vc")
        c.select(id: "lbl")
        #expect(c.inspectorSections(.attributes).map(\.title) == ["Label", "View"])
        c.setAttribute("numberOfLines", "0", of: "lbl")
        #expect(c.document.byID["lbl"]?.attribute("numberOfLines") == "0")
        // Runtime attributes on a self-closing element.
        c.select(id: "fr")
        c.addRuntimeAttribute(keyPath: "k")
        #expect(c.document.runtimeAttributes(of: "fr").map(\.keyPath) == ["k"])
    }

    @Test func sevenInspectorTabs() {
        #expect(CommandTable.inspectors + InterfaceBuilderController.InspectorTab.allCases.map(\.title)
                == ["File", "History", "Quick Help", "Identity", "Attributes", "Size", "Connections"])
    }

    /// Off-screen PNGs for review (scratch directory from YCODE_SHOTS).
    @Test func renders() throws {
        guard let dir = ProcessInfo.processInfo.environment["YCODE_SHOTS"] else { return }
        let c = try controller()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        c.view.translatesAutoresizingMaskIntoConstraints = false
        w.contentView!.addSubview(c.view)
        NSLayoutConstraint.activate([c.view.widthAnchor.constraint(equalToConstant: 1100), c.view.heightAnchor.constraint(equalToConstant: 900),
                                     c.view.topAnchor.constraint(equalTo: w.contentView!.topAnchor), c.view.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor)])
        c.view.appearance = NSAppearance(named: .aqua)
        c.select(id: "lbl")
        c.zoomToFit()
        c.view.layoutSubtreeIfNeeded()
        let rep = try #require(c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds))
        c.view.cacheDisplay(in: c.view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ib-storyboard.png"))
    }

    @Test func sizeAndConnections() throws {
        let c = try controller()
        c.select(id: "vc")
        #expect(c.inspectorSections(.size) == [IBInspectorSection("Simulated Size", [.info(label: "Simulated Size", value: "Fixed")])])
        let conns = c.inspectorSections(.connections)
        #expect(conns.map(\.title) == ["Triggered Segues", "Outlets", "Presenting Segues", "Referencing Outlets", "Referencing Outlet Collections"])
        #expect(conns[1].rows == [.connection(name: "label", other: "Label - Hello", id: "o1")])
        #expect(conns[2].rows.count == 9)
        c.disconnect("o1")
        #expect(c.document.byID["vc"]?.connections.isEmpty == true && c.document.byID["vc"]?.node.child("connections") == nil)
        c.select(id: "lbl")
        let size = c.inspectorSections(.size)
        let cons = try #require(size.first { $0.title == "Constraints" })
        #expect(cons.rows.contains(.constraint(text: "Leading Space to: View Layout Guide", id: "c1")))
        #expect(cons.rows.contains(.constraint(text: "Top Space to: View Layout Guide", id: "c2")))
        #expect(cons.rows.contains(.info(label: "Showing 2 of 2", value: "")))
        #expect(size.contains { $0.title == "Content Hugging Priority" && $0.rows.first == .text(label: "Horizontal", target: "lbl", attribute: "horizontalHuggingPriority", value: "250", placeholder: "250") })
        _ = c.inspectorView(.size)
        _ = c.inspectorView(.identity)
        _ = c.inspectorView(.attributes)
        _ = c.inspectorView(.connections)
    }
}
