import AppKit
import Foundation
import Testing
@testable import YcodeUI

/// The Editor menu of each editor kind, transcribed from
/// `specs/ide/reference-ui-5.md` §2.7 (source editor) and §2.8 (property
/// list, storyboard / xib, asset catalog; other editors get the first
/// block). Notation as in `menuBarGolden` (MenuBarGoldenTests.swift).
let editorFirstBlockGolden = """
Show Editor Only | ⌘↩
—
Preview | ⌥⌘↩
Assistant | ⌃⌥⌘↩
Code Review | ⌥⇧⌘↩
Layout ▸
  Automatic
  —
  Preview on Right
  Preview on Bottom
"""

let editorMenuGolden: [EditorKind: String] = [
    .source: """
    Show Editor Only | ⌘↩
    —
    Canvas | ⌥⌘↩
    Assistant | ⌃⌥⌘↩
    Code Review | ⌥⇧⌘↩
    Layout ▸
      Automatic
      —
      Canvas on Right
      Canvas on Bottom
    —
    Show Completions | ⌃Space
    Show Predictive Completion | ⌃⌥Space
    Show Coding Tools ▸
      Show Coding Tools… | ⌥⌘0
      —
      Explain
      Document
      Generate a Playground
      Generate a Preview
    Edit All in Scope | ⌃⌘E
    Show Callers…
    Expand Macro
    Hide All Macro Expansions
    Refactor ▸
      Rename…
      —
      Extract to File
      Extract Selection to File
      Extract to Function
      Extract to Method
      Extract to Variable
      Extract All Occurrences
      —
      Add Missing Abstract Class Overrides
      Add Missing Protocol Requirements
      Add Missing Switch Cases
      Convert to Switch
      Convert to Regex Builder
      Expand Default
      Generate Memberwise Initializer
      Generate Missing Function Definitions
      Wrap in NSLocalizedString
      —
      Convert Function to Async
      Change Localized String Key
      Convert Localized String to Symbol
      Convert to Localized String Literal
    —
    Fix All Issues | ⌃⌥⌘F
    Show Issues | ⌃⌥⌘L
    Show All Issues | ⌃⌘L
    —
    Show Markdown
    —
    Selection ▸
      Select All Symbols
      Split Selection By Lines
      Balance Delimiters
      —
      Select Column Up | ⌃⇧↑
      Select Column Down | ⌃⇧↓
    Structure ▸
      Re-Indent | ⌃I
      Shift Left | ⌘[
      Shift Right | ⌘]
      —
      Reformat To Width | ⌃⌥I
      Format to Multiple Lines | ⌃M
      Format Selection | ⌃⌥⇧I
      Format File | ⌃⇧I
      —
      Move Line Up | ⌥⌘[
      Move Line Down | ⌥⌘]
      Comment Selection | ⌘/
      Add Documentation | ⌥⌘/
    Code Folding ▸
      Fold | ⌥⌘←
      Unfold | ⌥⌘→
      Unfold All
      —
      Fold Methods & Functions | ⌥⇧⌘←
      Unfold Methods & Functions | ⌥⇧⌘→
      —
      Fold Comment Blocks | ⌃⇧⌘←
      Unfold Comment Blocks | ⌃⇧⌘→
    Syntax Coloring ▸
      Default for File Type
      None
      —
      C
      Objective-C
      Swift
    Font Size ▸
      Increase | ⌘+
      Decrease | ⌘-
      —
      Reset | ⌃⌘0
    Choose Theme...
    —
    Inline Comparison
    Side By Side Comparison
    —
    Minimap | ⌃⇧⌘M
    Authors | ⌃⇧⌘A
    Code Coverage
    —
    Vim Mode
    Relative Line Numbers
    —
    Invisibles
    Scope Guides
    Wrap Lines | ⌃⇧⌘L
    —
    Show Last Change for Line
    Create Code Snippet…
    """,
    .propertyList: editorFirstBlockGolden + """

    —
    Add Item
    Value Type ▸
      Array
      Dictionary
      —
      Boolean
      Data
      Date
      Number
      String
    —
    Raw Keys and Values
    """,
    .interfaceBuilder: editorFirstBlockGolden + """

    —
    Align ▸
      Left Edges | ⌘[
      Right Edges | ⌘]
      Top Edges
      Bottom Edges
      —
      Horizontal Centers
      Vertical Centers
      Baselines
      —
      Horizontally in Container
      Vertically in Container
    Arrange ▸
      Send to Front
      Send to Back
      Send Forward
      Send Backward
    Size to Fit Content | ⌘=
    Update Frames | ⌥⌘=
    Add New Constraints…
    —
    Embed In ▸
      View
      View Without Inset
      Scroll View
      Stack View
      —
      Navigation Controller
      Tab Bar Controller
    Unembed
    —
    Resolve Auto Layout Issues ▸
      [Selected Views]
      Update Frames
      Update Constraint Constants
      Add Missing Constraints
      Reset to Suggested Constraints | ⌥⇧⌘=
      Clear Constraints
      —
      [All Views in Container]
      Update Frames
      Update Constraint Constants
      Add Missing Constraints
      Reset to Suggested Constraints
      Clear Constraints
    Refactor to Storyboard…
    Localization Locking ▸
      Nothing
      All Properties
      Localizable Properties
      Non-localizable Properties
      —
      Reset Locking Controls
    —
    Document Outline
    Reveal in Document Outline
    Minimap | ⌃⇧⌘M
    —
    Canvas ▸
      Constraints
      Intrinsic Size Constraints Contributing To Ambiguity
      Involved Views For Selected Constraints
      Layout Rectangles
      Bounds Rectangles
      Device Bezels
      Placeholder Backgrounds
    Zoom ▸
      Zoom to 6.25%
      Zoom to 12.5%
      Zoom to 25%
      Zoom to 50%
      Zoom to 75%
      Zoom to 100% | ⌃⌘=
      Zoom to 125%
      Zoom to 150%
      Zoom to 200%
      Zoom to 300%
      Zoom to 400%
      —
      Zoom to Fit
      —
      Zoom In
      Zoom Out
    —
    Snap to Guides
    Guides ▸
      Add Horizontal Guide | ⌘_
      Add Vertical Guide | ⌃⌘|
    """,
    .assetCatalog: editorFirstBlockGolden + """

    —
    Add New Asset ▸
      Image Set
      Color Set
      Symbol Image Set
      Data Set
      AR and Textures ▸
        Texture Set
        Sprite Atlas
        Cube Texture Set
        —
        AR Resource Group
        AR Reference Image
        AR Reference Object
      iOS ▸
        iOS App Icon
        iOS Launch Image (Deprecated)
        Messages Extension Icon
        —
        Sticker Pack
        Sticker
        Sticker Sequence
        Sticker Sequence Frame
      macOS ▸
        macOS App Icon
        macOS Generic Icon
        Icon Status Badge
        Sidebar Icon
      watchOS ▸
        watchOS App Icon
        Complication Placeholder
      tvOS ▸
        tvOS App Icon and Top Shelf Image
        tvOS Launch Image (Deprecated)
        —
        Image Stack
        Image Stack Layer
        —
        Game Center Dashboard Image
        Game Center Leaderboard
        Game Center Leaderboard Set
      visionOS ▸
        visionOS App Icon
        visionOS App Icon Layer
      —
      Folder
      Folder with Namespace
      Folder from Selection
      —
      Import…
    Delete Selected Items
    —
    Device Image Reps ▸
      Universal
      iPhone
      iPad
      Mac Catalyst Scaled
      CarPlay
      Mac
      Apple Vision
      Apple Watch
      Apple TV
    —
    Find References to Item
    —
    Quick Look
    Show in Finder
    Open in External Editor
    —
    Show Overview
    Show Slicing
    """,
    .other: editorFirstBlockGolden,
]

@MainActor
@Suite(.serialized) struct EditorMenuGoldenTests {
    func compare(_ actual: [String], _ expected: [String], _ label: String) {
        guard actual != expected else { return }
        let n = min(actual.count, expected.count)
        let i = (0..<n).first { actual[$0] != expected[$0] } ?? n
        let ctx = max(0, i - 3)
        Issue.record("""
            \(label): first difference at line \(i + 1):
            expected: \(expected[ctx..<min(expected.count, i + 3)].joined(separator: "\n          "))
            actual:   \(actual[ctx..<min(actual.count, i + 3)].joined(separator: "\n          "))
            """)
    }

    /// §1.9 for the Editor menu: each kind's menu against §2.7 / §2.8.
    @Test(arguments: EditorKind.allCases) func editorMenuMatchesSpec(_ kind: EditorKind) {
        MenuBarGoldenTests().withFactoryBar { _ in
            let m = MainMenu.menu("Editor", EditorMenu.items(for: kind), path: "Editor")
            compare(renderMenu(m), canonicalGolden(editorMenuGolden[kind]!), "\(kind)")
        }
    }

    /// The menu bar's Editor menu is the source editor's (the generic bar)
    /// and is rebuilt for the focused editor's kind, and back.
    @Test func menuBarEditorMenuFollowsTheFocusedKind() throws {
        try MenuBarGoldenTests().withFactoryBar { bar in
            let m = try #require(bar.item(withTitle: "Editor")?.submenu as? CommandMenu)
            compare(renderMenu(m), canonicalGolden(editorMenuGolden[.source]!), "bar")
            for kind in EditorKind.allCases + [.source] {
                DynamicMenus.fillEditor(m, kind: kind)
                #expect(m.editorKind == kind)
                compare(renderMenu(m), canonicalGolden(editorMenuGolden[kind]!), "bar as \(kind)")
                // Submenus keep their paths (the Refactor delegate, labels).
                if kind == .source {
                    let refactor = m.item(withTitle: "Refactor")?.submenu
                    #expect(refactor?.delegate === RefactorMenuDelegate.shared)
                }
            }
        }
    }

    /// §1.9 second test, per kind: with each Editor menu in the bar no two
    /// items share a shortcut.
    @Test(arguments: EditorKind.allCases) func noSharedShortcutsWithEachEditorMenu(_ kind: EditorKind) throws {
        try MenuBarGoldenTests().withFactoryBar { bar in
            let m = try #require(bar.item(withTitle: "Editor")?.submenu as? CommandMenu)
            DynamicMenus.fillEditor(m, kind: kind)
            var seen: [String: (String, String)] = [:]
            @MainActor func walk(_ m: NSMenu, _ path: String) {
                for i in m.items {
                    if let s = i.submenu { walk(s, path + " ▸ " + i.title); continue }
                    let sc = MainMenu.canonicalShortcut(i)
                    guard !sc.isEmpty else { continue }
                    let action = i.action.map(NSStringFromSelector) ?? ""
                    if let (p, a) = seen[sc] {
                        #expect(a == action, "\(sc): \(p) and \(path) ▸ \(i.title)")
                    } else {
                        seen[sc] = (path + " ▸ " + i.title, action)
                    }
                }
            }
            for top in bar.items { walk(top.submenu!, top.title) }
        }
    }

    /// §2.8: disabled items shown checked keep their check mark; the
    /// performed ones get theirs from validation.
    @Test func checkedDisabledItems() throws {
        try MenuBarGoldenTests().withFactoryBar { bar in
            let m = try #require(bar.item(withTitle: "Editor")?.submenu as? CommandMenu)
            DynamicMenus.fillEditor(m, kind: .interfaceBuilder)
            #expect(m.item(withTitle: "Localization Locking")?.submenu?.item(withTitle: "Nothing")?.state == .on)
            #expect(m.item(withTitle: "Canvas")?.submenu?.item(withTitle: "Device Bezels")?.state == .on)
            #expect(m.item(withTitle: "Canvas")?.submenu?.item(withTitle: "Layout Rectangles")?.state == .off)
            #expect(m.item(withTitle: "Snap to Guides")?.state == .on)
            DynamicMenus.fillEditor(m, kind: .assetCatalog)
            #expect(m.item(withTitle: "Show Overview")?.state == .on && m.item(withTitle: "Show Slicing")?.state == .off)
        }
    }

    /// Dynamic titles (§1.3) of the source Editor menu.
    @Test func editorTitlesInContext() {
        var ctx = MenuContext()
        ctx.fileName = "Model.swift"
        #expect(MenuTitles.title(generic: "Format File", in: ctx) == "Format File with \u{2018}swift-format\u{2019}")
        #expect(MenuTitles.title(generic: "Format Selection", in: ctx) == "Format Selection with \u{2018}swift-format\u{2019}")
        ctx.fileName = "main.c"
        #expect(MenuTitles.title(generic: "Format File", in: ctx) == "Format File")
        #expect(MenuTitles.title(generic: "Show All Issues", in: ctx) == "Hide All Issues")
        ctx.inlineIssuesShown = false
        #expect(MenuTitles.title(generic: "Show All Issues", in: ctx) == "Show All Issues")
        #expect(MenuTitles.title(generic: "Format File", in: nil) == "Format File")
    }
}
