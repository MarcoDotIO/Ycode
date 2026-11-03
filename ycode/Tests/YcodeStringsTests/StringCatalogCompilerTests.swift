import Foundation
import Testing
@testable import YcodeStrings

/// A catalog with every compiled form, written by hand in the documented layout.
let compileCatalog = #"""
{
  "sourceLanguage" : "en",
  "strings" : {
    "" : {

    },
    "%lld items" : {
      "localizations" : {
        "de" : {
          "variations" : {
            "plural" : {
              "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld Element" } },
              "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld Elemente" } }
            }
          }
        }
      }
    },
    "Apples" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : { "state" : "translated", "value" : "%1$@ has %#@apples@" },
          "substitutions" : {
            "apples" : {
              "argNum" : 2,
              "formatSpecifier" : "lld",
              "variations" : {
                "plural" : {
                  "one" : { "stringUnit" : { "state" : "translated", "value" : "%arg apple" } },
                  "other" : { "stringUnit" : { "state" : "translated", "value" : "%arg apples" } }
                }
              }
            }
          }
        }
      }
    },
    "Escapes" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Tab\tquote \" backslash \\ newline\n bell \u0007 emoji 😀 𝄞" } }
      }
    },
    "Hello" : {
      "comment" : "Greeting",
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Hallo" } },
        "fr" : { "stringUnit" : { "state" : "new", "value" : "Bonjour" } },
        "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "こんにちは" } }
      }
    },
    "Logo" : {
      "shouldTranslate" : false
    },
    "Photos" : {
      "localizations" : {
        "en" : {
          "variations" : {
            "device" : {
              "iphone" : {
                "variations" : {
                  "plural" : {
                    "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld photo on this iPhone" } },
                    "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld photos on this iPhone" } }
                  }
                }
              },
              "other" : {
                "variations" : {
                  "plural" : {
                    "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld photo" } },
                    "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld photos" } }
                  }
                }
              }
            }
          }
        }
      }
    },
    "Tap" : {
      "localizations" : {
        "en" : {
          "variations" : {
            "device" : {
              "mac" : { "stringUnit" : { "state" : "translated", "value" : "Click" } },
              "other" : { "stringUnit" : { "state" : "translated", "value" : "Tap" } }
            }
          }
        }
      }
    }
  },
  "version" : "1.0"
}
"""#

func tempDir(_ name: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-strings-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite struct FormatSpecifierTests {
    @Test func parsesPrintfAndVariables() {
        let s = FormatSpecifier.parse("%1$@ has %2$#@apples@, %lld, %.2f%%, %-5d %hhu %@ %q")
        #expect(s.map(\.text) == ["%1$@", "%2$#@apples@", "%lld", "%.2f", "%%", "%-5d", "%hhu", "%@"])
        #expect(s.map(\.position) == [1, 2, nil, nil, nil, nil, nil, nil])
        #expect(s.map(\.valueType) == ["@", "", "lld", "f", "", "d", "hhu", "@"])
        #expect(s[1].variable == "apples" && !s[4].takesArgument)
        // Offsets are UTF-16 offsets (a non-BMP character is two units).
        #expect(FormatSpecifier.parse("😀%d")[0].offset == 2)
    }
}

@Suite struct StringCatalogCompilerTests {
    func compiled(_ options: StringCatalogCompiler.Options = .init()) throws -> StringCatalogCompiler.Result {
        StringCatalogCompiler.compile(try StringCatalog(data: Data(compileCatalog.utf8)), options: options)
    }

    func table(_ r: StringCatalogCompiler.Result, _ lang: String) -> StringCatalogCompiler.Table { r.tables.first { $0.language == lang }! }

    @Test func languagesAndStates() throws {
        let r = try compiled()
        #expect(r.diagnostics.isEmpty)
        #expect(r.tables.map(\.language) == ["en", "de", "fr", "ja"])
        // The source language has every key: its own value, else the key.
        let en = table(r, "en")
        #expect(en.strings.map(\.key) == ["%lld items", "Escapes", "Hello", "Logo"])
        #expect(en.strings.allSatisfy { $0.key == $0.value })
        #expect(en.stringsdict.map(\.0) == ["Apples", "Photos", "Tap"])
        // Other languages: their units; `new` units only when forced;
        // keys marked don't translate never.
        #expect(table(r, "de").strings.map(\.key) == ["Escapes", "Hello"])
        #expect(table(r, "fr").strings.isEmpty)
        #expect(table(r, "ja").strings == [StringsFile.Entry(key: "Hello", value: "こんにちは")])
        #expect(table(try compiled(.init(forceBuildAllStrings: true)), "fr").strings.map(\.value) == ["Bonjour"])
        // -l restricts the languages.
        #expect(try compiled(.init(languages: ["de"])).tables.map(\.language) == ["de"])
    }

    @Test func pluralDeviceAndSubstitutionDictionaries() throws {
        let r = try compiled()
        let de = table(r, "de").stringsdict
        #expect(de.map(\.0) == ["%lld items"])
        #expect(de[0].1 == .dict([
            ("NSStringLocalizedFormatKey", .string("%#@count@")),
            ("count", .dict([("NSStringFormatSpecTypeKey", .string("NSStringPluralRuleType")), ("NSStringFormatValueTypeKey", .string("lld")),
                             ("one", .string("%lld Element")), ("other", .string("%lld Elemente"))])),
        ]))
        let en = Dictionary(table(r, "en").stringsdict, uniquingKeysWith: { a, _ in a })
        // The substitution's argument is 2, so the variable and its cases are positional.
        #expect(en["Apples"] == .dict([
            ("NSStringLocalizedFormatKey", .string("%1$@ has %2$#@apples@")),
            ("apples", .dict([("NSStringFormatSpecTypeKey", .string("NSStringPluralRuleType")), ("NSStringFormatValueTypeKey", .string("lld")),
                              ("one", .string("%2$lld apple")), ("other", .string("%2$lld apples"))])),
        ]))
        #expect(en["Tap"] == .dict([("NSStringDeviceSpecificRuleType", .dict([("mac", .string("Click")), ("other", .string("Tap"))]))]))
        // Device, then plural: each device case is a format dictionary.
        let photos = en["Photos"]?["NSStringDeviceSpecificRuleType"]
        #expect(photos?.pairs.map(\.0) == ["iphone", "other"])
        #expect(photos?["iphone"]?["NSStringLocalizedFormatKey"]?.string == "%#@count@")
        #expect(photos?["other"]?["count"]?["other"]?.string == "%lld photos")
    }

    @Test func errorsUseSwiftBuildsFormat() throws {
        let bad = """
        {"sourceLanguage":"en","strings":{"k":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"%#@missing@"}}}}},"version":"1.0"}
        """
        let r = StringCatalogCompiler.compile(try StringCatalog(data: Data(bad.utf8)))
        #expect(r.errors.map(\.description) == ["error: Referencing undefined substitution 'missing' (en: k)"])
    }

    @Test func dryRunPathsAreTheFilesWritten() throws {
        let dir = try tempDir("write")
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try compiled()
        let planned = r.outputPaths(directory: dir.path, tableName: "Localizable")
        let written = try r.write(directory: dir.path, tableName: "Localizable")
        #expect(planned == written)
        #expect(planned.map { String($0.dropFirst(dir.path.count + 1)) } == [
            "en.lproj/Localizable.strings", "en.lproj/Localizable.stringsdict", "de.lproj/Localizable.strings",
            "de.lproj/Localizable.stringsdict", "ja.lproj/Localizable.strings",
        ])
        // The written files read back: escapes, controls and non-BMP characters survive.
        let de = try StringsFile.parse(Data(contentsOf: dir.appendingPathComponent("de.lproj/Localizable.strings")))
        #expect(de.first { $0.key == "Escapes" }?.value == "Tab\tquote \" backslash \\ newline\n bell \u{07} emoji 😀 𝄞")
        // The stringsdict is a valid property list.
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: dir.appendingPathComponent("en.lproj/Localizable.stringsdict")),
                                                               format: nil) as? [String: Any]
        #expect(Set(plist.map { Array($0.keys) } ?? []) == ["Apples", "Photos", "Tap"])
    }
}

@Suite struct StringsFileTests {
    @Test func writeAndParseRoundTrip() throws {
        let entries = [StringsFile.Entry(key: "a \"q\"", value: "line\nnext\ttab \\ \u{01} 😀 𝄞", comment: "A comment"),
                       StringsFile.Entry(key: "plain", value: "x")]
        for enc in [StringsFile.Encoding.utf8, .utf16] {
            #expect(try StringsFile.parse(StringsFile.data(entries, encoding: enc)) == entries)
        }
        #expect(StringsFile.text([entries[1]]) == "\"plain\" = \"x\";\n")
        #expect(StringsFile.data([entries[1]], encoding: .utf16).prefix(2) == Data([0xFF, 0xFE]))
    }

    @Test func parsesTheFormatsVariants() throws {
        let text = """
        // line comment
        "k1" = "v1"; /* trailing, not this key's */
        /* Block
           comment */
        "k2"="\\U00e9\\U00E9\\101";
        unquoted = also_unquoted;
        "only";
        "pair" = "\\UD83D\\UDE00";
        """
        let e = try StringsFile.parse(text)
        #expect(e.map(\.key) == ["k1", "k2", "unquoted", "only", "pair"])
        #expect(e[0].comment == "line comment" && e[1].comment == "Block\n   comment")
        #expect(e[1].value == "ééA" && e[2].value == "also_unquoted" && e[3].value == "only" && e[4].value == "😀")
        #expect(throws: StringsFile.ParseError.self) { try StringsFile.parse("\"a\" = \"b\"") }
    }
}

#if os(macOS)
/// The compiled tables as Foundation reads them (public API only).
@Suite struct CompiledTablesRuntimeTests {
    @Test func foundationFormatsTheCompiledTables() throws {
        let dir = try tempDir("bundle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundleURL = dir.appendingPathComponent("T.bundle")
        let resources = bundleURL.appendingPathComponent("Contents/Resources")
        try StringCatalogCompiler.compile(try StringCatalog(data: Data(compileCatalog.utf8)), options: .init(languages: ["en"]))
            .write(directory: resources.path, tableName: "Localizable")
        let info: [String: Any] = ["CFBundleIdentifier": "dev.ycode.strings-test", "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        let bundle = try #require(Bundle(url: bundleURL))
        func format(_ key: String, _ args: CVarArg...) -> String {
            String(format: bundle.localizedString(forKey: key, value: nil, table: nil), locale: Locale(identifier: "en"), arguments: args)
        }
        #expect(format("Hello") == "Hello")
        #expect(format("Apples", "Ann", 1) == "Ann has 1 apple")
        #expect(format("Apples", "Bob", 3) == "Bob has 3 apples")
        #expect(format("Tap") == "Click")
        #expect(format("Photos", 1) == "1 photo")
        #expect(format("Photos", 2) == "2 photos")
    }
}
#endif
