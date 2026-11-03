import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProject

/// A project with a `Localizable` table in two variant groups (`.strings`
/// in en and de, `.stringsdict` in de),
/// for Edit ▸ Convert ▸ To String Catalogs… (specs/ide/string-catalog.md,
/// "Ycode implementation").
struct LegacyStringsSample {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/StringTables/App.pbxproj")
    static var pbxproj: String { (try? String(contentsOf: fixture, encoding: .utf8)) ?? "" }
    static let files: [(String, String)] = [
        ("App/main.swift", "print(String(localized: \"Hello\"))\n"),
        ("App/en.lproj/Localizable.strings", "/* Greeting */\n\"Hello\" = \"Hello\";\n"),
        ("App/de.lproj/Localizable.strings", "/* Greeting */\n\"Hello\" = \"Hallo\";\n"),
        ("App/de.lproj/Localizable.stringsdict", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>%d files</key><dict>
        <key>NSStringLocalizedFormatKey</key><string>%#@n@</string>
        <key>n</key><dict><key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string>
        <key>NSStringFormatValueTypeKey</key><string>d</string><key>one</key><string>%d Datei</string><key>other</key><string>%d Dateien</string></dict>
        </dict></dict></plist>
        """),
    ]

    let top: URL
    var dir: URL { top.appendingPathComponent("proj") }
    var xcodeproj: URL { dir.appendingPathComponent("App.xcodeproj") }
    var bin: TrashBin { .folder(top.appendingPathComponent("trash")) }

    init() throws {
        top = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("ycode-legacy-strings-\(UUID().uuidString)")
        for (path, text) in [("App.xcodeproj/project.pbxproj", Self.pbxproj)] + Self.files {
            let u = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: top) }

    func operations() throws -> ProjectFileOperations {
        var proj = try PBXProj(contentsOf: xcodeproj)
        proj.idSequence = ObjectIDSequence(prefix: "AA")
        return ProjectFileOperations(project: proj, xcodeprojURL: xcodeproj, bin: bin)
    }

    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(rel).path) }
}

@Suite(.serialized) struct StringCatalogConversionTests {
    @Test func findsTheTables() throws {
        let s = try LegacyStringsSample()
        defer { s.remove() }
        let ops = try s.operations()
        let tables = ops.legacyStringTables()
        #expect(tables.map(\.name) == ["Localizable"])
        let t = try #require(tables.first)
        #expect(t.directory == s.dir.appendingPathComponent("App").path)
        #expect(t.languages == ["de", "en"] && t.files.count == 3)
        #expect(t.groupIDs == ["5D0000000000000000000020", "5D0000000000000000000030"] || t.groupIDs == ["5D0000000000000000000030", "5D0000000000000000000020"])
        #expect(t.targetNames == ["App"])
        #expect(ops.developmentRegion == "en")
    }

    @Test func convertsUndoesAndRedoes() throws {
        let s = try LegacyStringsSample()
        defer { s.remove() }
        var ops = try s.operations()
        let table = try #require(ops.legacyStringTables().first)
        var edit = try ops.convertToStringCatalogs([table])
        #expect(edit.actionName == "Convert to String Catalog")
        // The catalog replaces the variant groups, in the same group and target.
        let proj = try #require(ops.project)
        let text = proj.serialized(projectName: "App")
        #expect(!text.contains("PBXVariantGroup") && !text.contains("Localizable.strings in Resources"))
        #expect(text.contains("Localizable.xcstrings in Resources"))
        #expect(text.contains("lastKnownFileType = text.json.xcstrings; path = Localizable.xcstrings; sourceTree = \"<group>\";"))
        #expect(proj["5D0000000000000000000041"]?.references("children").count == 2)
        #expect(edit.result.count == 1)
        // On disk: the catalog, and the old files and empty .lproj folders gone.
        #expect(s.exists("App/Localizable.xcstrings") && !s.exists("App/en.lproj") && !s.exists("App/de.lproj"))
        let c = try StringCatalog(data: Data(contentsOf: s.dir.appendingPathComponent("App/Localizable.xcstrings")))
        #expect(c.sourceLanguage == "en" && c.keys == ["%d files", "Hello"] && c.languages == ["en", "de"])
        #expect(c.rows(language: "de").map(\.state) == [.variesByPlural, .translated])
        #expect(c.json["strings"]?["Hello"]?["comment"]?.stringValue == "Greeting")
        // Converting again is refused: the catalog exists.
        #expect(throws: NavigatorEditError.self) { _ = try ops.convertToStringCatalogs([table]) }

        let before = try edit.undo(bin: s.bin)
        #expect(before?.serialized(projectName: "App") == LegacyStringsSample.pbxproj)
        #expect(!s.exists("App/Localizable.xcstrings") && s.exists("App/en.lproj/Localizable.strings") && s.exists("App/de.lproj/Localizable.stringsdict"))
        _ = try edit.redo(bin: s.bin)
        #expect(s.exists("App/Localizable.xcstrings") && !s.exists("App/de.lproj"))
    }
}
