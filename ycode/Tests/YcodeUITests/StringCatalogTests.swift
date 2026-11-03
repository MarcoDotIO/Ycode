import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

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
    @Test func editorShowsAndWrites() throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/strings")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Localizable.xcstrings")
        try sampleCatalog.write(to: file, atomically: true, encoding: .utf8)
        let ed = try StringCatalogEditorController(url: file)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = ed
        window.setContentSize(NSSize(width: 1000, height: 420))
        #expect(ed.language == "en" && ed.table.tableColumn(withIdentifier: .init("translation"))?.isHidden == true)
        ed.select(language: "de")
        #expect(ed.table.tableColumn(withIdentifier: .init("translation"))?.title == "German")
        ed.setTranslation("Einstellungen", key: "Settings")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("\"value\" : \"Einstellungen\""))
        ed.addLanguage("ja")
        #expect(ed.sidebar.numberOfRows == 4 && ed.language == "ja")
        ed.select(language: "de")
        window.layoutIfNeeded()
        _ = try WindowSnapshotTests().render(window.contentView!, to: "string-catalog-editor.png")
    }
}
