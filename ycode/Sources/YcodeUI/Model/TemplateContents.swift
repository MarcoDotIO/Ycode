import Foundation
import YcodePlist

/// What each New File template writes (reference-ui-5.md §11.3, P10):
/// Ycode's own minimal contents, with no header comments and no copied
/// wording. Every Source template gives a non-empty file that compiles.
/// Paths may name a folder ("Media.xcassets/Contents.json"): the first
/// component is the item added to the project. Formats follow public
/// documentation (asset catalogs, Settings bundles, DocC, GPX, GeoJSON,
/// privacy manifests, string catalogs, Interface Builder documents as in
/// `templates.md`).
enum TemplateContents {
    /// A Swift / C identifier made from a file name.
    static func identifier(_ name: String) -> String {
        var s = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        if s.first?.isNumber ?? true { s = "_" + s }
        return s
    }

    static func plist(_ root: PropertyListItem) -> String { PropertyListDocument(root: root).xml() }

    static func storyboard(cocoa: Bool, scene: Bool) -> String {
        let type = cocoa ? "com.apple.InterfaceBuilder3.Cocoa.Storyboard.XIB" : "com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB"
        let runtime = cocoa ? "MacOSX.Cocoa" : "iOS.CocoaTouch"
        guard scene else {
            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <document type="\(type)" version="3.0" toolsVersion="1" targetRuntime="\(runtime)" propertyAccessControl="none" useAutolayout="YES"\(cocoa ? "" : " useSafeAreas=\"YES\"")>
                <scenes/>
            </document>

            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <document type="\(type)" version="3.0" toolsVersion="1" targetRuntime="\(runtime)" propertyAccessControl="none" useAutolayout="YES" useSafeAreas="YES" launchScreen="YES" initialViewController="Ycd-vc-1">
            <scenes>
                <scene sceneID="Ycd-sc-1">
                    <objects>
                        <viewController id="Ycd-vc-1" sceneMemberID="viewController">
                            <view key="view" contentMode="scaleToFill" id="Ycd-vw-1">
                                <rect key="frame" x="0.0" y="0.0" width="393" height="852"/>
                                <autoresizingMask key="autoresizingMask" widthSizable="YES" heightSizable="YES"/>
                                <color key="backgroundColor" systemColor="systemBackgroundColor"/>
                            </view>
                        </viewController>
                        <placeholder placeholderIdentifier="IBFirstResponder" id="Ycd-fr-1" userLabel="First Responder" sceneMemberID="firstResponder"/>
                    </objects>
                </scene>
            </scenes>
            <resources>
                <systemColor name="systemBackgroundColor">
                    <color white="1" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"/>
                </systemColor>
            </resources>
        </document>

        """
    }

    static func xib(cocoa: Bool, view: Bool) -> String {
        let type = cocoa ? "com.apple.InterfaceBuilder3.Cocoa.XIB" : "com.apple.InterfaceBuilder3.CocoaTouch.XIB"
        let runtime = cocoa ? "MacOSX.Cocoa" : "iOS.CocoaTouch"
        let owner = cocoa ? "NSObject" : "UIResponder"
        let viewXML = !view ? "" : cocoa ? """

                <customView id="Ycd-vw-1">
                    <rect key="frame" x="0.0" y="0.0" width="480" height="272"/>
                    <autoresizingMask key="autoresizingMask" flexibleMaxX="YES" flexibleMinY="YES"/>
                </customView>
        """ : """

                <view contentMode="scaleToFill" id="Ycd-vw-1">
                    <rect key="frame" x="0.0" y="0.0" width="393" height="852"/>
                    <autoresizingMask key="autoresizingMask" widthSizable="YES" heightSizable="YES"/>
                </view>
        """
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <document type="\(type)" version="3.0" toolsVersion="1" targetRuntime="\(runtime)" propertyAccessControl="none" useAutolayout="YES">
            <objects>
                <placeholder placeholderIdentifier="IBFilesOwner" id="-1" userLabel="File's Owner"/>
                <placeholder placeholderIdentifier="IBFirstResponder" id="-2" customClass="\(owner)"/>\(viewXML)
            </objects>
        </document>

        """
    }

    static let catalogInfo = "{\n  \"info\" : {\n    \"author\" : \"ycode\",\n    \"version\" : 1\n  }\n}\n"

    /// (relative path, contents) for an entry and a name (without extension).
    static func files(_ entry: TemplateEntry, name n: String, platform: String) -> [(String, String)]? {
        let id = identifier(n)
        let cocoa = platform == "macOS"
        let ext = entry.fileExtension
        let file = "\(n).\(ext)"
        switch entry.title {
        case "C File": return [(file, "#include <stddef.h>\n\nint \(id)_value(void) {\n    return 0;\n}\n")]
        case "C++ File": return [(file, "#include <cstddef>\n\nnamespace \(id) {\nint value() { return 0; }\n}\n")]
        case "Metal File": return [(file, "#include <metal_stdlib>\nusing namespace metal;\n")]
        case "SwiftUI View":
            return [(file, "import SwiftUI\n\nstruct \(id): View {\n    var body: some View {\n        Text(\"\(n)\")\n    }\n}\n\n#Preview {\n    \(id)()\n}\n")]
        case "Storyboard": return [(file, storyboard(cocoa: cocoa, scene: false))]
        case "Launch Screen": return [(file, storyboard(cocoa: false, scene: true))]
        case "View": return [(file, xib(cocoa: cocoa, view: true))]
        case "Empty" where ext == "xib": return [(file, xib(cocoa: cocoa, view: false))]
        case "Swift Testing Unit Test":
            return [(file, "import Testing\n\nstruct \(id) {\n    @Test func example() {\n        #expect(Bool(true))\n    }\n}\n")]
        case "XCTest Unit Test":
            return [(file, "import XCTest\n\nfinal class \(id): XCTestCase {\n    func testExample() throws {\n        XCTAssertTrue(true)\n    }\n}\n")]
        case "XCTest UI Launch Test":
            return [(file, "import XCTest\n\nfinal class \(id): XCTestCase {\n    override class var runsForEachTargetApplicationUIConfiguration: Bool { true }\n\n    @MainActor\n    func testLaunch() throws {\n        let app = XCUIApplication()\n        app.launch()\n        let attachment = XCTAttachment(screenshot: app.screenshot())\n        attachment.lifetime = .keepAlways\n        add(attachment)\n    }\n}\n")]
        case "XCTest UI Test":
            return [(file, "import XCTest\n\nfinal class \(id): XCTestCase {\n    @MainActor\n    func testExample() throws {\n        let app = XCUIApplication()\n        app.launch()\n    }\n}\n")]
        case "Test Plan":
            return [(file, "{\n  \"configurations\" : [\n    {\n      \"id\" : \"\(UUID().uuidString)\",\n      \"name\" : \"Configuration 1\",\n      \"options\" : {\n\n      }\n    }\n  ],\n  \"defaultOptions\" : {\n\n  },\n  \"testTargets\" : [\n\n  ],\n  \"version\" : 1\n}\n")]
        case "Data Model":
            return [("\(file)/\(n).xcdatamodel/contents", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0" lastSavedToolsVersion="1" systemVersion="1" minimumToolsVersion="Automatic" sourceLanguage="Swift" userDefinedModelVersionIdentifier=""/>

                """)]
        case "App Privacy":
            return [(file, plist(.dictionary([.init(key: "NSPrivacyTracking", value: .bool(false)), .init(key: "NSPrivacyTrackingDomains", value: .array([])),
                                              .init(key: "NSPrivacyCollectedDataTypes", value: .array([])),
                                              .init(key: "NSPrivacyAccessedAPITypes", value: .array([]))])))]
        case "Asset Catalog": return [("\(file)/Contents.json", catalogInfo)]
        case "Sticker Catalog":
            return [("\(file)/Contents.json", catalogInfo), ("\(file)/Sticker Pack.stickerpack/Contents.json", catalogInfo)]
        case "GeoJSON File": return [(file, "{\n  \"type\" : \"FeatureCollection\",\n  \"features\" : [\n\n  ]\n}\n")]
        case "GPX File":
            return [(file, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Ycode\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n    <wpt lat=\"37.33182\" lon=\"-122.03118\">\n        <name>\(n)</name>\n    </wpt>\n</gpx>\n")]
        case "Module Map": return [(file, "module \(id) {\n    umbrella \".\"\n    export *\n}\n")]
        case "Rich Text File": return [(file, "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\n\\f0\\fs24 \\par\n}\n")]
        case "Settings Bundle":
            let root = plist(.dictionary([
                .init(key: "StringsTable", value: .string("Root")),
                .init(key: "PreferenceSpecifiers", value: .array([
                    .dictionary([.init(key: "Type", value: .string("PSGroupSpecifier")), .init(key: "Title", value: .string("Group"))]),
                    .dictionary([.init(key: "Type", value: .string("PSToggleSwitchSpecifier")), .init(key: "Title", value: .string("Enabled")),
                                 .init(key: "Key", value: .string("enabled_preference")), .init(key: "DefaultValue", value: .bool(true))]),
                ])),
            ]))
            return [("\(file)/Root.plist", root), ("\(file)/en.lproj/Root.strings", "\"Group\" = \"Group\";\n\"Enabled\" = \"Enabled\";\n")]
        case "String Catalog": return [(file, "{\n  \"sourceLanguage\" : \"en\",\n  \"strings\" : {\n\n  },\n  \"version\" : \"1.0\"\n}\n")]
        case "Strings File (Legacy)": return [(file, "\"\(n)\" = \"\(n)\";\n")]
        case "Stringsdict File (Legacy)", "Touch Alternatives": return [(file, plist(.dictionary([])))]
        case "SiriKit Intent Definition File":
            return [(file, plist(.dictionary([.init(key: "INEnums", value: .array([])), .init(key: "INIntentDefinitionModelVersion", value: .string("1.2")),
                                              .init(key: "INIntents", value: .array([])), .init(key: "INTypes", value: .array([]))])))]
        case "Documentation Catalog":
            return [("\(file)/\(n).md", "# ``\(id)``\n\nSummary.\n\n## Overview\n\nText.\n\n## Topics\n\n### Group\n\n- ``Symbol``\n")]
        case "Article File": return [(file, "# \(n)\n\nSummary.\n\n## Overview\n\nText.\n")]
        case "Extension File": return [(file, "# ``\(id)``\n\nSummary.\n\n## Topics\n\n### Group\n\n- ``Symbol``\n")]
        case "Empty" where ext == "md": return [(file, "# \(n)\n")]
        case "Tutorial Table of Contents File":
            return [(file, "@Tutorials(name: \"\(n)\") {\n    @Intro(title: \"\(n)\") {\n        Introduction.\n    }\n}\n")]
        case "Tutorial File":
            return [(file, "@Tutorial(time: 10) {\n    @Intro(title: \"\(n)\") {\n        Introduction.\n    }\n\n    @Section(title: \"Section\") {\n        @Steps {\n            @Step {\n                Step.\n            }\n        }\n    }\n}\n")]
        case "Assembly File": return [(file, "    .text\n")]
        case "CLIPS File": return [(file, "; \(n)\n")]
        case "Configuration Settings File": return [(file, "// \(n)\n")]
        case "Markdown File": return [(file, "# \(n)\n")]
        case "PCH File": return [(file, "#ifndef \(id)_pch\n#define \(id)_pch\n\n#endif\n")]
        case "Shell Script": return [(file, "#!/bin/sh\n")]
        case "StoreKit Configuration File":
            return [(file, "{\n  \"identifier\" : \"\(UUID().uuidString.prefix(8))\",\n  \"nonRenewingSubscriptions\" : [\n\n  ],\n  \"products\" : [\n\n  ],\n  \"settings\" : {\n\n  },\n  \"subscriptionGroups\" : [\n\n  ],\n  \"version\" : {\n    \"major\" : 4,\n    \"minor\" : 0\n  }\n}\n")]
        case "SceneKit Catalog", "GameKit Bundle", "Icon Composer Icon", "Mapping Model":
            // Folder documents whose inner format is not specified: the
            // folder itself (spec question in the round report).
            return [("\(file)/", "")]
        default: return nil
        }
    }
}
