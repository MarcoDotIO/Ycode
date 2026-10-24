import Foundation

/// The kind of editor that has focus; each has its own Editor menu
/// (`specs/ide/reference-ui-5.md` §2.7, §2.8).
public enum EditorKind: String, CaseIterable, Sendable {
    /// A source file, or no document (the generic menu bar).
    case source
    case propertyList
    case interfaceBuilder
    case assetCatalog
    /// Any other editor (project editor, string catalog, reports): the
    /// first block only (§2.8; the project editor's menu is still to be
    /// observed, §12).
    case other
}

/// The Editor menu per editor kind, in `reference-ui-5.md` §2.7 / §2.8
/// order. Commands Ycode does not perform are listed disabled (§1.1).
public enum EditorMenu {
    public typealias M = MenuCommand.Modifiers

    /// Items of the source editor's menu shown with a check mark by default.
    public static let checkedByDefault: Set<String> = ["Inline Comparison", "Minimap", "Wrap Lines"]

    /// Disabled items that carry a check mark (§2.8: "Nothing ✓", …). Items
    /// Ycode performs get their state from validation instead.
    public static let checkedDisabled: [EditorKind: Set<String>] = [
        .interfaceBuilder: ["Nothing", "Constraints", "Device Bezels", "Placeholder Backgrounds", "Snap to Guides"],
        .assetCatalog: ["Show Overview"],
    ]

    /// The source editor's menu (the generic menu bar's Editor menu).
    static var items: [MenuItemSpec] { items(for: .source) }

    public static func items(for kind: EditorKind) -> [MenuItemSpec] {
        switch kind {
        case .source: sourceItems
        case .propertyList: firstBlock(source: false) + propertyListItems
        case .interfaceBuilder: firstBlock(source: false) + interfaceBuilderItems
        case .assetCatalog: firstBlock(source: false) + assetCatalogItems
        case .other: firstBlock(source: false)
        }
    }

    private static func c(_ t: String, _ s: String = "", _ a: String, tag: Int = 0) -> MenuItemSpec { CommandTable.c(t, s, a, tag: tag) }
    private static func u(_ t: String, _ s: String = "") -> MenuItemSpec { CommandTable.u(t, s) }
    private static let sep = MenuItemSpec.separator

    /// Show Editor Only … Layout ▸ (§2.7 items 1–4; §2.8's first block,
    /// where the canvas is titled Preview).
    static func firstBlock(source: Bool) -> [MenuItemSpec] {
        [
            c("Show Editor Only", "⌘↩", "showEditorOnly:"),
            sep,
            c(source ? "Canvas" : "Preview", "⌥⌘↩", "toggleCanvas:"),
            c("Assistant", "⌃⌥⌘↩", "toggleAssistant:"),
            c("Code Review", "⌥⇧⌘↩", "toggleComparison:"),
            .submenu("Layout", [
                c("Automatic", "", "setCanvasLayout:", tag: 0),
                sep,
                c(source ? "Editor on Left" : "Preview on Right", "", "setCanvasLayout:", tag: 1),
                c(source ? "Editor on Top" : "Preview on Bottom", "", "setCanvasLayout:", tag: 2),
            ]),
        ]
    }

    /// Syntax Coloring ▸ languages Ycode colors, alphabetical.
    public static let syntaxLanguages: [(title: String, language: SourceTokenizer.Language)] = [
        ("C", .c), ("Objective-C", .objc), ("Swift", .swift),
    ]
    /// Syntax Coloring ▸ Default for File Type's tag; the others carry the
    /// language's index in `SourceTokenizer.Language.allCases`.
    public static let defaultSyntaxTag = -1

    public static func syntaxTag(_ l: SourceTokenizer.Language) -> Int { SourceTokenizer.Language.allCases.firstIndex(of: l) ?? 0 }

    /// §2.7.
    static var sourceItems: [MenuItemSpec] {
        firstBlock(source: true) + [
            sep,
            c("Show Completions", "⌃Space", "complete:"),
            u("Show Predictive Completion", "⌃⌥Space"),
            // §2.0: ⌥⌘0 shows the code actions at the caret (Ycode has no
            // coding assistant; the rest is disabled).
            .submenu("Show Coding Tools", [
                c("Show Coding Tools…", "⌥⌘0", "showCodeActions:"),
                sep,
                u("Explain"),
                u("Document"),
                u("Generate a Playground"),
                u("Generate a Preview"),
            ]),
            c("Edit All in Scope", "⌃⌘E", "editAllInScope:"),
            c("Show Callers…", "", "showCallHierarchy:"),
            u("Expand Macro"),
            u("Hide All Macro Expansions"),
            .submenu("Refactor", RefactorCatalog.menuItems),
            sep,
            c("Fix All Issues", "⌃⌥⌘F", "fixAllIssues:"),
            c("Show Issues", "⌃⌥⌘L", "showInlineIssues:"),
            // "Show / Hide All Issues" (§1.3: the generic title is the first).
            c("Show All Issues", "⌃⌘L", "toggleInlineIssues:"),
            sep,
            u("Show Markdown"),
            sep,
            .submenu("Selection", [
                c("Select All Symbols", "", "selectAllSymbols:"),
                c("Split Selection By Lines", "", "splitSelectionByLines:"),
                c("Balance Delimiters", "", "balanceDelimiters:"),
                sep,
                c("Select Column Up", "⌃⇧↑", "selectColumnUp:"),
                c("Select Column Down", "⌃⇧↓", "selectColumnDown:"),
            ]),
            .submenu("Structure", [
                // §2.0 (M2): Re-Indent moved here from Edit ▸ Format.
                c("Re-Indent", "⌃I", "reindent:"),
                c("Shift Left", "⌘[", "shiftLeft:"),
                c("Shift Right", "⌘]", "shiftRight:"),
                sep,
                c("Reformat To Width", "⌃⌥I", "reformatToWidth:"),
                c("Format to Multiple Lines", "⌃M", "formatToMultipleLines:"),
                c("Format Selection", "⌃⌥⇧I", "formatSelection:"),
                c("Format File", "⌃⇧I", "formatFile:"),
                sep,
                c("Move Line Up", "⌥⌘[", "moveLineUp:"),
                c("Move Line Down", "⌥⌘]", "moveLineDown:"),
                c("Comment Selection", "⌘/", "commentSelection:"),
                c("Add Documentation", "⌥⌘/", "addDocumentation:"),
            ]),
            // §2.0 (M1): ⌥⇧⌘← / → fold and unfold methods and functions.
            .submenu("Code Folding", [
                c("Fold", "⌥⌘←", "fold:"),
                c("Unfold", "⌥⌘→", "unfold:"),
                c("Unfold All", "", "unfoldAll:"),
                sep,
                c("Fold Methods & Functions", "⌥⇧⌘←", "foldMethodsAndFunctions:"),
                c("Unfold Methods & Functions", "⌥⇧⌘→", "unfoldMethodsAndFunctions:"),
                sep,
                c("Fold Comment Blocks", "⌃⇧⌘←", "foldCommentBlocks:"),
                c("Unfold Comment Blocks", "⌃⇧⌘→", "unfoldCommentBlocks:"),
            ]),
            .submenu("Syntax Coloring", [
                c("Default for File Type", "", "setSyntaxColoring:", tag: defaultSyntaxTag),
                c("None", "", "setSyntaxColoring:", tag: syntaxTag(.plain)),
                sep,
            ] + syntaxLanguages.map { c($0.title, "", "setSyntaxColoring:", tag: syntaxTag($0.language)) }),
            .submenu("Font Size", [
                c("Increase", "⌘+", "increaseFontSize:"),
                c("Decrease", "⌘-", "decreaseFontSize:"),
                sep,
                c("Reset", "⌃⌘0", "resetFontSize:"),
            ]),
            // The title as the reference spells it (three periods).
            c("Choose Theme...", "", "chooseTheme:"),
            sep,
            c("Inline Comparison", "", "showInlineComparison:"),
            c("Side By Side Comparison", "", "showSideBySideComparison:"),
            sep,
            c("Minimap", "⌃⇧⌘M", "toggleMinimap:"),
            u("Authors", "⌃⇧⌘A"),
            u("Code Coverage"),
            sep,
            u("Vim Mode"),
            u("Relative Line Numbers"),
            sep,
            u("Invisibles"),
            u("Scope Guides"),
            c("Wrap Lines", "⌃⇧⌘L", "toggleWrapLines:"),
            sep,
            u("Show Last Change for Line"),
            u("Create Code Snippet…"),
        ]
    }

    /// §2.8, property list.
    static var propertyListItems: [MenuItemSpec] {
        let types = PlistTree.types
        func t(_ name: String) -> MenuItemSpec { c(name, "", "setPlistValueType:", tag: types.firstIndex(of: name) ?? 0) }
        return [
            sep,
            c("Add Item", "", "addPlistItem:"),
            .submenu("Value Type", [t("Array"), t("Dictionary"), sep, t("Boolean"), t("Data"), t("Date"), t("Number"), t("String")]),
            sep,
            c("Raw Keys and Values", "", "toggleRawKeysAndValues:"),
        ]
    }

    /// Editor ▸ Zoom ▸ "Zoom to N%" (tag = N × 100).
    public static let zoomPercents: [Double] = [6.25, 12.5, 25, 50, 75, 100, 125, 150, 200, 300, 400]

    static func zoomTitle(_ p: Double) -> String {
        "Zoom to " + (p == p.rounded() ? String(Int(p)) : String(p)) + "%"
    }

    /// §2.8, storyboard / xib.
    static var interfaceBuilderItems: [MenuItemSpec] {
        let resolve: [MenuItemSpec] = [u("Update Frames"), u("Update Constraint Constants"), u("Add Missing Constraints")]
        return [
            sep,
            .submenu("Align", [
                u("Left Edges", "⌘["), u("Right Edges", "⌘]"), u("Top Edges"), u("Bottom Edges"), sep,
                u("Horizontal Centers"), u("Vertical Centers"), u("Baselines"), sep,
                u("Horizontally in Container"), u("Vertically in Container"),
            ]),
            .submenu("Arrange", [u("Send to Front"), u("Send to Back"), u("Send Forward"), u("Send Backward")]),
            u("Size to Fit Content", "⌘="),
            c("Update Frames", "⌥⌘=", "updateCanvasFrames:"),
            // Ycode's constraint sheet (reference-ui-4.md §13) belongs here, after Update Frames.
            c("Add New Constraints…", "", "showAddConstraints:"),
            sep,
            .submenu("Embed In", [
                u("View"), u("View Without Inset"), u("Scroll View"), u("Stack View"), sep,
                u("Navigation Controller"), u("Tab Bar Controller"),
            ]),
            u("Unembed"),
            sep,
            .submenu("Resolve Auto Layout Issues", [.label("Selected Views")] + resolve
                + [u("Reset to Suggested Constraints", "⌥⇧⌘="), u("Clear Constraints"), sep, .label("All Views in Container")]
                + resolve + [u("Reset to Suggested Constraints"), u("Clear Constraints")]),
            u("Refactor to Storyboard…"),
            .submenu("Localization Locking", [
                u("Nothing"), u("All Properties"), u("Localizable Properties"), u("Non-localizable Properties"), sep,
                u("Reset Locking Controls"),
            ]),
            sep,
            c("Document Outline", "", "toggleDocumentOutline:"),
            u("Reveal in Document Outline"),
            u("Minimap", "⌃⇧⌘M"),
            sep,
            .submenu("Canvas", [
                u("Constraints"), u("Intrinsic Size Constraints Contributing To Ambiguity"), u("Involved Views For Selected Constraints"),
                u("Layout Rectangles"), u("Bounds Rectangles"), u("Device Bezels"), u("Placeholder Backgrounds"),
            ]),
            .submenu("Zoom", zoomPercents.map { p in
                c(zoomTitle(p), p == 100 ? "⌃⌘=" : "", "zoomCanvasToPercent:", tag: Int(p * 100))
            } + [sep, c("Zoom to Fit", "", "zoomCanvasToFit:"), sep, c("Zoom In", "", "zoomCanvasIn:"), c("Zoom Out", "", "zoomCanvasOut:")]),
            sep,
            u("Snap to Guides"),
            .submenu("Guides", [u("Add Horizontal Guide", "⌘_"), u("Add Vertical Guide", "⌃⌘|")]),
        ]
    }

    /// §2.8, asset catalog.
    static var assetCatalogItems: [MenuItemSpec] {
        func spec(_ entries: [AssetCatalog.AddMenuEntry]) -> [MenuItemSpec] {
            entries.map { e in
                switch e {
                case .separator: sep
                case let .submenu(t, children): .submenu(t, spec(children))
                case let .item(t, enabled):
                    if enabled, let tag = AssetCatalogEditorController.creatable[t] { c(t, "", "addNewAsset:", tag: tag) } else { u(t) }
                }
            }
        }
        return [
            sep,
            .submenu("Add New Asset", spec(AssetCatalog.editorAddMenu())),
            c("Delete Selected Items", "", "deleteSelectedAssets:"),
            sep,
            .submenu("Device Image Reps", ["Universal", "iPhone", "iPad", "Mac Catalyst Scaled", "CarPlay", "Mac", "Apple Vision", "Apple Watch", "Apple TV"].map { u($0) }),
            sep,
            u("Find References to Item"),
            sep,
            u("Quick Look"),
            c("Show in Finder", "", "showAssetInFinder:"),
            c("Open in External Editor", "", "openAssetInExternalEditor:"),
            sep,
            u("Show Overview"),
            u("Show Slicing"),
        ]
    }
}

extension AssetCatalog {
    /// Editor ▸ Add New Asset (`reference-ui-5.md` §2.8): the "+" menu with
    /// the platform submenus' further items.
    public static func editorAddMenu() -> [AddMenuEntry] {
        func items(_ ts: [String]) -> [AddMenuEntry] { ts.map { .item($0, enabled: true) } }
        return addMenu().map { e in
            guard case let .submenu(t, children) = e else { return e }
            switch t {
            case "macOS": return .submenu(t, children + items(["macOS Generic Icon", "Icon Status Badge", "Sidebar Icon"]))
            case "watchOS": return .submenu(t, children + items(["Complication Placeholder"]))
            case "tvOS":
                return .submenu(t, children + items(["tvOS Launch Image (Deprecated)"]) + [.separator] + items(["Image Stack", "Image Stack Layer"])
                    + [.separator] + items(["Game Center Dashboard Image", "Game Center Leaderboard", "Game Center Leaderboard Set"]))
            case "visionOS": return .submenu(t, children + items(["visionOS App Icon Layer"]))
            default: return e
            }
        }
    }
}
