import Foundation
import Testing
@testable import YcodeXcodebuild

@Suite struct LocalizationFormatTests {
    @Test func stringsFiles() {
        let entries = StringsFile.parse(text: """
        /* Farewell */
        "Goodbye" = "Au revoir";
        // a line comment
        "Quote \\"x\\"" = "Line\\nbreak \\U00E9";
        "NoComment"="v";
        """)
        #expect(entries == [
            .init(key: "Goodbye", value: "Au revoir", comment: "Farewell"),
            .init(key: "Quote \"x\"", value: "Line\nbreak é", comment: nil),
            .init(key: "NoComment", value: "v", comment: nil),
        ])
        #expect(StringsFile.escape("a\"b\\c\nd") == "a\\\"b\\\\c\\nd")
    }

    let catalog: [String: Any] = [
        "sourceLanguage": "en", "version": "1.0",
        "strings": [
            "Hello": ["comment": "Greeting", "localizations": ["fr": ["stringUnit": ["state": "needs_review", "value": "Bonjour"]]]],
            "Unused": ["localizations": ["en": ["stringUnit": ["state": "translated", "value": "Unused value"]]]],
            "Skip": ["shouldTranslate": false],
        ],
    ]

    @Test func catalogUnits() {
        let fr = Localization.units(catalog: catalog, language: "fr")
        #expect(fr.map(\.id) == ["Hello", "Unused"])
        #expect(fr[0].target == "Bonjour" && fr[0].state == "needs-review-l10n" && fr[0].note == "Greeting")
        #expect(fr[1].source == "Unused value" && fr[1].target == nil && fr[1].note == nil)
        // The source language: keys without a value are new, with the key as text.
        let en = Localization.units(catalog: catalog, language: "en")
        #expect(en[0].target == "Hello" && en[0].state == "new")
        #expect(en[1].target == "Unused value" && en[1].state == "translated")
        let source = Localization.sourceCatalog(catalog)
        let hello = (source["strings"] as? [String: Any])?["Hello"] as? [String: Any]
        #expect(hello?["localizations"] == nil && hello?["comment"] as? String == "Greeting")
    }

    @Test func xliffRoundTrip() {
        let text = Localization.xliff(files: [("App/Localizable.xcstrings", Localization.units(catalog: catalog, language: "fr"))],
                                      sourceLanguage: "en", targetLanguage: "fr")
        #expect(text.contains("<file original=\"App/Localizable.xcstrings\" source-language=\"en\" target-language=\"fr\" datatype=\"plaintext\">"))
        #expect(text.contains("<target state=\"needs-review-l10n\">Bonjour</target>"))
        #expect(text.contains("        <note/>\n"))
        let files = Localization.XLIFFReader.read(Data(text.utf8))
        #expect(files.count == 1 && files[0].targetLanguage == "fr")
        #expect(files[0].units.map(\.id) == ["Hello", "Unused"])
        #expect(files[0].units[0].target == "Bonjour" && files[0].units[0].state == "needs-review-l10n")
        #expect(Localization.catalogState("needs-review-l10n") == "needs_review" && Localization.catalogState(nil) == "translated")
        #expect(Localization.escape("a<b>&\"", attribute: true) == "a&lt;b&gt;&amp;&quot;")
    }

    /// Export to `fr.xcloc`, translate, import (no helper: string extraction
    /// and the generated Info.plist catalog are skipped).
    @Test func exportAndImport() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ycodebuild-loc-\(UUID().uuidString)")
        for sub in ["Loc.xcodeproj", "Loc/en.lproj", "Loc/fr.lproj"] { try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
        try locProjectText.write(to: dir.appendingPathComponent("Loc.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        try "print(1)\n".write(to: dir.appendingPathComponent("Loc/main.swift"), atomically: true, encoding: .utf8)
        try JSONText.render(catalog).write(to: dir.appendingPathComponent("Loc/Localizable.xcstrings"), atomically: true, encoding: .utf8)
        try "/* Farewell */\n\"Goodbye\" = \"Goodbye\";\n".write(to: dir.appendingPathComponent("Loc/en.lproj/Greetings.strings"), atomically: true, encoding: .utf8)
        try "/* Farewell */\n\"Goodbye\" = \"Au revoir\";\n".write(to: dir.appendingPathComponent("Loc/fr.lproj/Greetings.strings"), atomically: true, encoding: .utf8)
        let e = runTool(["-exportLocalizations", "-localizationPath", "out", "-project", "Loc.xcodeproj", "-exportLanguage", "fr"], cwd: dir.path)
        #expect(e.code == 0, "\(e.err)")
        #expect(e.out.contains("Localization Export started for Loc project\n") && e.out.contains("An xcloc was created at \(dir.path)/out/fr.xcloc"))
        let xliffPath = dir.appendingPathComponent("out/fr.xcloc/Localized Contents/fr.xliff")
        var xliff = try String(contentsOf: xliffPath, encoding: .utf8)
        #expect(xliff.contains("<file original=\"Loc/en.lproj/Greetings.strings\""))
        #expect(xliff.contains("<target>Au revoir</target>") && xliff.contains("<target state=\"needs-review-l10n\">Bonjour</target>"))
        #expect(fm.fileExists(atPath: dir.path + "/out/fr.xcloc/Source Contents/Loc/Localizable.xcstrings"))
        #expect(fm.fileExists(atPath: dir.path + "/out/fr.xcloc/contents.json"))
        // A translator's edits come back into the catalog and the .strings file.
        xliff = xliff.replacingOccurrences(of: "<target>Au revoir</target>", with: "<target>Salut</target>")
            .replacingOccurrences(of: "<target state=\"needs-review-l10n\">Bonjour</target>", with: "<target state=\"translated\">Bonjour !</target>")
        try xliff.write(to: xliffPath, atomically: true, encoding: .utf8)
        let i = runTool(["-importLocalizations", "-localizationPath", "out/fr.xcloc", "-project", "Loc.xcodeproj"], cwd: dir.path)
        #expect(i.code == 0, "\(i.err)")
        #expect(try String(contentsOf: dir.appendingPathComponent("Loc/fr.lproj/Greetings.strings"), encoding: .utf8) == "/* Farewell */\n\"Goodbye\" = \"Salut\";\n\n")
        let c = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("Loc/Localizable.xcstrings"))) as? [String: Any]
        let unit = (((c?["strings"] as? [String: Any])?["Hello"] as? [String: Any])?["localizations"] as? [String: Any])?["fr"] as? [String: Any]
        #expect((unit?["stringUnit"] as? [String: Any])?["value"] as? String == "Bonjour !")
        #expect((unit?["stringUnit"] as? [String: Any])?["state"] as? String == "translated")
    }
}

/// An application with a String Catalog and a localized .strings file.
let locProjectText = """
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {
		F10000000000000000000001 = {isa = PBXBuildFile; fileRef = F10000000000000000000002; };
		F10000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
		F10000000000000000000003 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Loc.app; sourceTree = BUILT_PRODUCTS_DIR; };
		F10000000000000000000004 = {isa = PBXGroup; children = (F10000000000000000000005, F10000000000000000000006); sourceTree = "<group>"; };
		F10000000000000000000005 = {isa = PBXGroup; children = (F10000000000000000000002, F10000000000000000000020, F10000000000000000000022); path = Loc; sourceTree = "<group>"; };
		F10000000000000000000006 = {isa = PBXGroup; children = (F10000000000000000000003); name = Products; sourceTree = "<group>"; };
		F10000000000000000000007 = {isa = PBXNativeTarget; buildConfigurationList = F10000000000000000000008; buildPhases = (F10000000000000000000009, F10000000000000000000010); buildRules = (); dependencies = (); name = Loc; productName = Loc; productReference = F10000000000000000000003; productType = "com.apple.product-type.application"; };
		F10000000000000000000008 = {isa = XCConfigurationList; buildConfigurations = (F1000000000000000000000A, F1000000000000000000000B); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		F10000000000000000000009 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (F10000000000000000000001); runOnlyForDeploymentPostprocessing = 0; };
		F10000000000000000000010 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (F10000000000000000000021, F10000000000000000000023); runOnlyForDeploymentPostprocessing = 0; };
		F10000000000000000000020 = {isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = Localizable.xcstrings; sourceTree = "<group>"; };
		F10000000000000000000021 = {isa = PBXBuildFile; fileRef = F10000000000000000000020; };
		F10000000000000000000022 = {isa = PBXVariantGroup; children = (F10000000000000000000024, F10000000000000000000025); name = Greetings.strings; sourceTree = "<group>"; };
		F10000000000000000000023 = {isa = PBXBuildFile; fileRef = F10000000000000000000022; };
		F10000000000000000000024 = {isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = en; path = en.lproj/Greetings.strings; sourceTree = "<group>"; };
		F10000000000000000000025 = {isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = fr; path = fr.lproj/Greetings.strings; sourceTree = "<group>"; };
		F1000000000000000000000A = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = org.ycode.samples.Loc; GENERATE_INFOPLIST_FILE = YES; CODE_SIGN_IDENTITY = "-"; SWIFT_VERSION = 5.0; SWIFT_EMIT_LOC_STRINGS = YES; LOCALIZATION_PREFERS_STRING_CATALOGS = YES; }; name = Debug; };
		F1000000000000000000000B = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = org.ycode.samples.Loc; GENERATE_INFOPLIST_FILE = YES; CODE_SIGN_IDENTITY = "-"; SWIFT_VERSION = 5.0; SWIFT_EMIT_LOC_STRINGS = YES; LOCALIZATION_PREFERS_STRING_CATALOGS = YES; }; name = Release; };
		F1000000000000000000000C = {isa = PBXProject; buildConfigurationList = F1000000000000000000000D; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, fr, Base); mainGroup = F10000000000000000000004; productRefGroup = F10000000000000000000006; preferredProjectObjectVersion = 77; projectDirPath = ""; projectRoot = ""; targets = (F10000000000000000000007); };
		F1000000000000000000000D = {isa = XCConfigurationList; buildConfigurations = (F1000000000000000000000E, F1000000000000000000000F); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		F1000000000000000000000E = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; ONLY_ACTIVE_ARCH = YES; }; name = Debug; };
		F1000000000000000000000F = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; }; name = Release; };
	};
	rootObject = F1000000000000000000000C;
}

"""
