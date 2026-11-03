import Foundation
import Testing
@testable import YcodeIDECore

/// A catalog written by hand in the documented layout.
let sampleCatalog = """
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
              "one" : {
                "stringUnit" : {
                  "state" : "translated",
                  "value" : "%lld Element"
                }
              },
              "other" : {
                "stringUnit" : {
                  "state" : "translated",
                  "value" : "%lld Elemente"
                }
              }
            }
          }
        }
      }
    },
    "Hello, world!" : {
      "comment" : "Greeting on the \\"main\\" screen",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Hallo, Welt!"
          }
        },
        "fr" : {
          "stringUnit" : {
            "state" : "needs_review",
            "value" : "Bonjour/le monde"
          }
        }
      }
    },
    "Old" : {
      "extractionState" : "stale"
    },
    "Settings" : {

    },
    "Ycode" : {
      "shouldTranslate" : false
    }
  },
  "version" : "1.0"
}
"""

@MainActor
@Suite(.serialized) struct StringCatalogTests {
    @Test func byteStableRoundTrip() throws {
        let c = try StringCatalog(data: Data(sampleCatalog.utf8))
        #expect(String(decoding: c.data(), as: UTF8.self) == sampleCatalog)
        let nl = try StringCatalog(data: Data((sampleCatalog + "\n").utf8))
        #expect(String(decoding: nl.data(), as: UTF8.self) == sampleCatalog + "\n")
        // Escapes and unicode survive.
        let odd = "{\n  \"a\" : \"tab\\there \\u00e9 ü \\ud83d\\ude00\",\n  \"n\" : 1.50\n}"
        let o = try StringCatalog(data: Data(odd.utf8))
        #expect(o.json["a"]?.stringValue == "tab\there é ü 😀")
        #expect(o.json.written() == "{\n  \"a\" : \"tab\\there é ü 😀\",\n  \"n\" : 1.50\n}")
        #expect(throws: OrderedJSON.ParseError.self) { try StringCatalog(data: Data("{\"a\" 1}".utf8)) }
    }

    @Test func rowsStatesAndEdits() throws {
        var c = try StringCatalog(data: Data(sampleCatalog.utf8))
        #expect(c.languages == ["en", "de", "fr"])
        let de = c.rows(language: "de")
        #expect(de.map(\.key) == ["", "%lld items", "Hello, world!", "Old", "Settings", "Ycode"])
        #expect(de.map(\.state) == [.new, .variesByPlural, .translated, .stale, .new, .dontTranslate])
        #expect(de[1].variations == ["plural.one: %lld Element", "plural.other: %lld Elemente"])
        #expect(de[2].comment == "Greeting on the \"main\" screen" && de[2].translation == "Hallo, Welt!")
        #expect(c.rows(language: "fr")[2].state == .needsReview)
        #expect(c.progress(language: "de") == 40 && c.progress(language: "en") == 100)

        c.setTranslation("Einstellungen", key: "Settings", language: "de")
        let text = String(decoding: c.data(), as: UTF8.self)
        #expect(text.contains("""
            "Settings" : {
              "localizations" : {
                "de" : {
                  "stringUnit" : {
                    "state" : "translated",
                    "value" : "Einstellungen"
                  }
                }
              }
            },
        """))
        // Undoing the edit gives back the original bytes.
        c.setTranslation("", key: "Settings", language: "de")
        #expect(String(decoding: c.data(), as: UTF8.self) == sampleCatalog)

        c.addKey("Added")
        #expect(c.keys == ["", "%lld items", "Added", "Hello, world!", "Old", "Settings", "Ycode"])
        c.setComment("A note", key: "Added")
        #expect(c.json["strings"]?["Added"] == .object([("comment", .string("A note")), ("extractionState", .string("manual"))]))
        c.addLanguage("ja")
        #expect(c.languages == ["en", "de", "fr", "ja"] && c.progress(language: "ja") == 0)
    }
}
