import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixture = ycodeDir.appendingPathComponent("Tests/YcodeIDECoreTests/Fixtures/StringTables/App.pbxproj")

/// Edit ▸ Convert ▸ To String Catalogs… and the String Catalog editor's
/// Refresh from Source, through the window (specs/ide/string-catalog.md,
/// "Ycode implementation"). The project is the one of the core's
/// `StringCatalogConversionTests`.
@MainActor
@Suite(.serialized) struct StringCatalogConversionUITests {
    @MainActor final class Sample {
        let top: URL
        var dir: URL { top.appendingPathComponent("proj") }
        var xcodeproj: URL { dir.appendingPathComponent("App.xcodeproj") }
        let prefs = IsolatedPreferences("strings-convert")
        let oldBin = WorkspaceWindowController.navigatorTrashBin

        init() throws {
            top = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ycode-strings-ui-\(UUID().uuidString)")
            let files: [(String, String)] = [
                ("App.xcodeproj/project.pbxproj", try String(contentsOf: fixture, encoding: .utf8)),
                ("App/main.swift", "print(String(localized: \"Hello\"), String(localized: \"Added in code\", comment: \"New\"))\n"),
                ("App/en.lproj/Localizable.strings", "/* Greeting */\n\"Hello\" = \"Hello\";\n\"Unused\" = \"Unused\";\n"),
                ("App/de.lproj/Localizable.strings", "\"Hello\" = \"Hallo\";\n"),
            ]
            for (path, text) in files {
                let u = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: u, atomically: true, encoding: .utf8)
            }
            // The stringsdict variant group's file.
            try StringsDictFile.data([("%d files", .dict([("NSStringLocalizedFormatKey", .string("%#@n@")),
                                                          ("n", .dict([("NSStringFormatSpecTypeKey", .string("NSStringPluralRuleType")),
                                                                       ("NSStringFormatValueTypeKey", .string("d")),
                                                                       ("one", .string("%d Datei")), ("other", .string("%d Dateien"))]))]))])
                .write(to: dir.appendingPathComponent("App/de.lproj/Localizable.stringsdict"))
            WorkspaceWindowController.navigatorTrashBin = .folder(top.appendingPathComponent("trash"))
        }

        func remove() {
            WorkspaceWindowController.navigatorTrashBin = oldBin
            prefs.restore()
            try? FileManager.default.removeItem(at: top)
        }

        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(rel).path) }
        var written: String { (try? String(contentsOf: xcodeproj.appendingPathComponent("project.pbxproj"), encoding: .utf8)) ?? "" }
    }

    func validated(_ wc: WorkspaceWindowController, _ action: String) -> Bool {
        wc.validateMenuItem(NSMenuItem(title: "", action: NSSelectorFromString(action), keyEquivalent: ""))
    }

    @Test func menuItemIsImplemented() {
        #expect(CommandTable.command(titled: "To String Catalogs…")?.action == "convertToStringCatalogs:")
    }

    @Test func convertThroughTheSheetThenRefreshFromSource() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try WindowChromeR32Tests().window(s.xcodeproj)
        #expect(validated(wc, "convertToStringCatalogs:"))

        // The sheet lists the table, checked; unchecking it disables Convert.
        wc.convertToStringCatalogs(nil)
        let sheet = try #require(wc.pendingStringCatalogConversion)
        _ = sheet.view
        #expect(sheet.tables.map(\.name) == ["Localizable"])
        #expect(sheet.checkboxes.map(\.title) == ["Localizable in App (de, en) — App"] && sheet.checkboxes.first?.state == .on)
        sheet.setChecked(false, table: sheet.tables[0].id)
        #expect(sheet.convertButton?.isEnabled == false && sheet.checkboxes.first?.state == .off)
        sheet.setChecked(true, table: sheet.tables[0].id)
        sheet.convertClicked()

        // The project now has the catalog in the target; the tables are gone.
        #expect(wc.pendingStringCatalogConversion == nil)
        #expect(s.written.contains("Localizable.xcstrings in Resources") && !s.written.contains("PBXVariantGroup"))
        #expect(s.exists("App/Localizable.xcstrings") && !s.exists("App/en.lproj") && !s.exists("App/de.lproj"))
        #expect(!validated(wc, "convertToStringCatalogs:"))
        #expect(wc.window?.undoManager?.undoActionName == "Convert to String Catalog")

        // Refresh from Source in the catalog's editor: the code's new string
        // is added; migrated keys stay as they are.
        let catalog = s.dir.appendingPathComponent("App/Localizable.xcstrings").path
        wc.open(path: catalog, line: nil)
        let ed = try #require(wc.stringCatalogEditor)
        #expect(ed.catalog.keys == ["%d files", "Hello", "Unused"])
        let summary = ed.refreshFromSource()
        #expect(summary.added == ["Added in code"] && summary.revived == ["Hello"] && summary.markedStale.isEmpty)
        #expect(ed.rows.map(\.key) == ["%d files", "Added in code", "Hello", "Unused"])
        let saved = try StringCatalog(data: Data(contentsOf: URL(fileURLWithPath: catalog)))
        #expect(saved.json["strings"]?["Added in code"] == .object([("comment", .string("New"))]))
        #expect(saved.json["strings"]?["Unused"]?["extractionState"]?.stringValue == "migrated")
        #expect(ed.refreshButton?.title == "Refresh from Source")

        // Undo brings the tables back.
        wc.window?.undoManager?.undo()
        #expect(s.exists("App/en.lproj/Localizable.strings") && s.exists("App/de.lproj/Localizable.stringsdict"))
        #expect(s.written.contains("PBXVariantGroup") && !s.written.contains("Localizable.xcstrings"))
    }
}
