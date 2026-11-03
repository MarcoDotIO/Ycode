import Foundation
import Testing
@testable import YcodeStrings

let sampleSwift = ##"""
import Foundation

struct Messages {
    let count: Int = 3
    let name = "Ann"
    func make(price: Double) -> [String] {
        [
            String(localized: "Welcome back!", comment: "Shown at launch"),
            String(localized: "Hello \(name), you have \(count) messages", table: "Inbox"),
            String(localized: "greeting.key", defaultValue: "Good morning", comment: "Morning greeting"),
            String(localized: "Price: \(price)"),
            NSLocalizedString("Legacy", comment: "An old call"),
            NSLocalizedString("legacy.table", tableName: "Old", bundle: .main, value: "From a table", comment: ""),
            String(localized: #"Raw "quoted" \#(count)"#),
            String(localized: "Escaped \"q\" \u{1F600}"),
            String(localized: "100% sure"),
            "not localized",
        ]
    }
    let resource = LocalizedStringResource("Resource key", defaultValue: "Resource value", comment: "A resource")
    let key: LocalizedStringKey = "Annotated key"
    // String(localized: "In a comment")
}
"""##

let sampleView = #"""
import SwiftUI

struct ContentView: View {
    @State private var on = false
    let items: [String]
    var body: some View {
        NavigationStack {
            VStack {
                Text("Title")
                Text("\(items.count) items", comment: "Item count")
                Text(verbatim: "Not localized")
                Text(items[0])
                Button("Save") {}
                Label("Inbox", systemImage: "tray")
                Toggle("Enabled", isOn: $on)
                SwiftUI.Text("Qualified", tableName: "Extra")
            }
            .navigationTitle("Home")
            .help("Help text")
            .padding()
        }
    }
}
"""#

let sampleObjC = #"""
#import <Foundation/Foundation.h>

// NSLocalizedString(@"Commented out", @"no")
#if 0
NSString *a = NSLocalizedString(@"Disabled", @"no");
#endif
NSString *b = NSLocalizedString(@"Hello ObjC", @"A greeting");
NSString *c = NSLocalizedStringFromTable(@"Tabled", @"Other", nil);
NSString *d = NSLocalizedStringWithDefaultValue(@"obj.key", nil, [NSBundle mainBundle], @"Default " "joined", @"With a value");
NSString *e = NSLocalizedString(@"Escapes \"q\"\n", @"");
CFStringRef f = CFCopyLocalizedString(CFSTR("From CF"), CFSTR("CF comment"));
NSString *g = MyLocalizedString(@"Custom", @"custom macro");
"""#

@Suite struct StringExtractionTests {
    @Test func swiftCalls() {
        let e = StringExtractor.extractSwift(sampleSwift, file: "Messages.swift")
        #expect(e.map(\.key) == [
            "Welcome back!", "Hello %@, you have %lld messages", "greeting.key", "Price: %lf", "Legacy", "legacy.table",
            "Raw \"quoted\" %lld", "Escaped \"q\" 😀", "100% sure", "Resource key", "Annotated key",
        ])
        #expect(e[0].comment == "Shown at launch" && e[0].table == "Localizable" && e[0].line == 8)
        #expect(e[1].table == "Inbox")
        #expect(e[2].defaultValue == "Good morning" && e[2].comment == "Morning greeting")
        #expect(e[5].table == "Old" && e[5].defaultValue == "From a table" && e[5].comment == nil)
        #expect(e[9].defaultValue == "Resource value" && e[9].comment == "A resource")
    }

    @Test func swiftUIView() {
        let e = StringExtractor.extractSwift(sampleView, file: "ContentView.swift")
        #expect(e.map(\.key) == ["Title", "%lld items", "Save", "Inbox", "Enabled", "Qualified", "Home", "Help text"])
        #expect(e[1].comment == "Item count" && e[5].table == "Extra")
        // Without SwiftUI support only the other calls are found.
        #expect(StringExtractor.extractSwift(sampleView, options: .init(swiftUI: false)).isEmpty)
    }

    @Test func objectiveC() {
        let e = StringExtractor.extractObjC(sampleObjC, file: "a.m", options: .init(macroNames: ["MyLocalizedString"]))
        #expect(e.map(\.key) == ["Hello ObjC", "Tabled", "obj.key", "Escapes \"q\"\n", "From CF", "Custom"])
        #expect(e[0].comment == "A greeting" && e[0].line == 7)
        #expect(e[1].table == "Other" && e[1].comment == nil)
        #expect(e[2].defaultValue == "Default joined" && e[2].table == "Localizable" && e[2].comment == "With a value")
        #expect(e[4].comment == "CF comment")
        #expect(StringExtractor.extractObjC(sampleObjC).count == 5)
    }
}

@Suite struct StringCatalogMergeTests {
    let existing = """
    {
      "sourceLanguage" : "en",
      "strings" : {
        "Gone" : {

        },
        "Hand" : {
          "extractionState" : "manual"
        },
        "Old" : {
          "extractionState" : "stale"
        },
        "Title" : {
          "comment" : "Old comment",
          "localizations" : {
            "de" : {
              "stringUnit" : {
                "state" : "translated",
                "value" : "Titel"
              }
            }
          }
        },
        "Valued" : {
          "extractionState" : "extracted_with_value",
          "localizations" : {
            "en" : {
              "stringUnit" : {
                "state" : "new",
                "value" : "Old value"
              }
            }
          }
        }
      },
      "version" : "1.0"
    }

    """

    @Test func mergeRules() throws {
        var c = try StringCatalog(data: Data(existing.utf8))
        let found = [ExtractedString(key: "Title", comment: "New comment"), ExtractedString(key: "Old"),
                     ExtractedString(key: "Valued", defaultValue: "New value"), ExtractedString(key: "Fresh"),
                     ExtractedString(key: "Fresh", comment: "Second mention"), ExtractedString(key: "With value", defaultValue: "Its value")]
        let s = c.merge(extracted: found)
        #expect(s.added == ["Fresh", "With value"])
        #expect(s.markedStale == ["Gone"])
        #expect(s.revived == ["Old"])
        #expect(s.updated == ["Title", "Valued"])
        let strings = c.json["strings"]!
        #expect(c.keys == ["Fresh", "Gone", "Hand", "Old", "Title", "Valued", "With value"])
        #expect(strings["Gone"]?["extractionState"]?.stringValue == "stale")
        #expect(strings["Hand"] == .object([("extractionState", .string("manual"))]))
        #expect(strings["Old"] == .object([]))
        #expect(strings["Title"]?["comment"]?.stringValue == "New comment")
        #expect(strings["Title"]?["localizations"]?["de"]?["stringUnit"]?["value"]?.stringValue == "Titel")
        #expect(strings["Valued"]?["localizations"]?["en"]?["stringUnit"]?["value"]?.stringValue == "New value")
        #expect(strings["Fresh"] == .object([("comment", .string("Second mention"))]))
        #expect(strings["With value"] == .object([
            ("extractionState", .string("extracted_with_value")),
            ("localizations", .object([("en", .object([("stringUnit", .object([("state", .string("new")), ("value", .string("Its value"))]))]))])),
        ]))
        // Merging the same strings again changes nothing.
        let before = c.data()
        #expect(c.merge(extracted: found).isEmpty)
        #expect(c.data() == before)
    }

    @Test func extractThenCompile() throws {
        var c = StringCatalog(sourceLanguage: "en")
        c.merge(extracted: StringExtractor.extractSwift(sampleView))
        c.setTranslation("Titel", key: "Title", language: "de")
        let r = StringCatalogCompiler.compile(c)
        #expect(r.tables.map(\.language) == ["en", "de"])
        #expect(r.tables[1].strings == [StringsFile.Entry(key: "Title", value: "Titel")])
        #expect(r.tables[0].strings.count == 8)
    }
}

@Suite struct StringCatalogConversionTests {
    let enStrings = """
    /* Greeting */
    "Hello" = "Hello";

    /* No comment provided by engineer. */
    "Bye" = "Goodbye";
    """
    let deStrings = """
    /* Greeting */
    "Hello" = "Hallo";
    "Bye" = "Tschüss";
    "%d files" = "should lose to the stringsdict";
    """
    let deDict = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>%d files</key>
        <dict>
            <key>NSStringLocalizedFormatKey</key><string>%#@files@</string>
            <key>files</key>
            <dict>
                <key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string>
                <key>NSStringFormatValueTypeKey</key><string>d</string>
                <key>one</key><string>%d Datei</string>
                <key>other</key><string>%d Dateien</string>
            </dict>
        </dict>
        <key>%@ shared %d photos</key>
        <dict>
            <key>NSStringLocalizedFormatKey</key><string>%@ hat %#@photos@ geteilt</string>
            <key>photos</key>
            <dict>
                <key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string>
                <key>NSStringFormatValueTypeKey</key><string>d</string>
                <key>one</key><string>ein Foto</string>
                <key>other</key><string>%d Fotos</string>
            </dict>
        </dict>
        <key>Tap</key>
        <dict>
            <key>NSStringDeviceSpecificRuleType</key>
            <dict><key>mac</key><string>Klicken</string><key>other</key><string>Tippen</string></dict>
        </dict>
    </dict>
    </plist>
    """

    @Test func convertsTablesAndCompilesBack() throws {
        let tables = [StringCatalogConverter.LanguageTable(language: "en", strings: try StringsFile.parse(enStrings)),
                      StringCatalogConverter.LanguageTable(language: "de", strings: try StringsFile.parse(deStrings),
                                                           stringsdict: try StringsDictFile.parse(Data(deDict.utf8)))]
        let (c, warnings) = StringCatalogConverter.catalog(sourceLanguage: "en", tables: tables)
        #expect(warnings.isEmpty)
        #expect(c.keys == ["%@ shared %d photos", "%d files", "Bye", "Hello", "Tap"])
        let s = c.json["strings"]!
        #expect(s["Hello"]?["comment"]?.stringValue == "Greeting" && s["Bye"]?["comment"] == nil)
        #expect(s["Hello"]?["extractionState"]?.stringValue == "migrated")
        #expect(s["Hello"]?["localizations"]?["de"] == .object([("stringUnit", .object([("state", .string("translated")), ("value", .string("Hallo"))]))]))
        let files = s["%d files"]?["localizations"]?["de"]
        #expect(files?["variations"]?["plural"]?["other"]?["stringUnit"]?["value"]?.stringValue == "%d Dateien")
        let photos = s["%@ shared %d photos"]?["localizations"]?["de"]
        #expect(photos?["stringUnit"]?["value"]?.stringValue == "%@ hat %#@photos@ geteilt")
        #expect(photos?["substitutions"]?["photos"]?["argNum"] == .number("2"))
        #expect(photos?["substitutions"]?["photos"]?["variations"]?["plural"]?["other"]?["stringUnit"]?["value"]?.stringValue == "%arg Fotos")
        #expect(s["Tap"]?["localizations"]?["de"]?["variations"]?["device"]?["mac"]?["stringUnit"]?["value"]?.stringValue == "Klicken")
        // The written catalog parses again to the same document.
        #expect(try StringCatalog(data: c.data()).json == c.json)

        // Compiled back, the German table means what the original did.
        let de = StringCatalogCompiler.compile(c).tables.first { $0.language == "de" }!
        #expect(de.strings.map(\.key) == ["Bye", "Hello"])
        let dict = Dictionary(de.stringsdict, uniquingKeysWith: { a, _ in a })
        #expect(dict["%d files"]?["count"]?["other"]?.string == "%d Dateien")
        #expect(dict["%d files"]?["count"]?["NSStringFormatValueTypeKey"]?.string == "d")
        // The variable takes the second argument in order: no positions needed.
        #expect(dict["%@ shared %d photos"]?["NSStringLocalizedFormatKey"]?.string == "%@ hat %#@photos@ geteilt")
        #expect(dict["%@ shared %d photos"]?["photos"]?["other"]?.string == "%d Fotos")
        #expect(dict["Tap"] == .dict([("NSStringDeviceSpecificRuleType", .dict([("mac", .string("Klicken")), ("other", .string("Tippen"))]))]))
    }

    @Test func convertCommandFindsLprojTables() throws {
        let dir = try tempDir("convert")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (lang, text) in [("en", enStrings), ("de", deStrings)] {
            let l = dir.appendingPathComponent("\(lang).lproj")
            try FileManager.default.createDirectory(at: l, withIntermediateDirectories: true)
            try StringsFile.data(try StringsFile.parse(text), encoding: .utf16).write(to: l.appendingPathComponent("Localizable.strings"))
        }
        try Data(deDict.utf8).write(to: dir.appendingPathComponent("de.lproj/Localizable.stringsdict"))
        #expect(StringsCLI.legacyTables(directory: dir.path, table: "Localizable").map(\.language) == ["de", "en"])
        #expect(StringsCLI.run(["convert", dir.path]) == 0)
        let c = try StringCatalog(data: Data(contentsOf: dir.appendingPathComponent("Localizable.xcstrings")))
        #expect(c.keys.count == 5 && c.languages == ["en", "de"])
    }
}

@Suite struct StringSymbolTests {
    @Test func symbolsForManualKeys() throws {
        let c = try StringCatalog(data: Data(compileCatalog.utf8))
        let syms = StringSymbolGenerator.symbols(c)
        #expect(syms.map(\.name) == ["apples"])
        #expect(syms[0].arguments.map(\.label) == ["arg1", "apples"] && syms[0].arguments.map(\.type) == ["String", "Int"])
        #expect(StringSymbolGenerator.identifier("Welcome to %@!", lowerFirst: true) == "welcomeTo")
        #expect(StringSymbolGenerator.identifier("2 lines", lowerFirst: true) == "_2Lines")
        #expect(StringSymbolGenerator.identifier("default", lowerFirst: true) == "`default`")
        #expect(StringSymbolGenerator.defaultValueLiteral("100%% of %lld \"x\"", arguments: [("n", "Int")]) == #""100% of \(n) \"x\"""#)
        let src = StringSymbolGenerator.swiftSource(c, table: "Localizable")
        #expect(src.contains("static func apples(arg1: String, apples: Int) -> LocalizedStringResource {"))
        #expect(src.contains(#"LocalizedStringResource("Apples", defaultValue: "\(arg1) has \(apples)", table: "Localizable""#))
        // A catalog without manual keys gives a file with no symbols.
        #expect(!StringSymbolGenerator.swiftSource(StringCatalog(), table: "T").contains("extension"))
    }

    #if os(macOS)
    /// The generated file type-checks (the Mac's own Swift compiler, building our sample).
    @Test func generatedSourceTypeChecks() throws {
        let dir = try tempDir("symbols")
        defer { try? FileManager.default.removeItem(at: dir) }
        var c = try StringCatalog(data: Data(compileCatalog.utf8))
        c.addKey("Welcome")
        c.addKey("Price %.2f for %u")
        let file = dir.appendingPathComponent("GeneratedStringSymbols_Localizable.swift")
        try Data((StringSymbolGenerator.swiftSource(c, table: "Localizable")
                  + "\n@available(macOS 13, *) func use() { _ = LocalizedStringResource.welcome; _ = LocalizedStringResource.priceFor(arg1: 1.5, arg2: 2) }\n").utf8)
            .write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["swiftc", "-typecheck", file.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(msg)")
    }
    #endif
}
