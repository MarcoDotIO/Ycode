import Foundation

/// The workspace window's chrome as values that both IDEs read: the AppKit
/// IDE (`YcodeUI`) and the SwiftUI shell (`ycode-ide`, on OpenViews on
/// Linux). Metrics come from `specs/ide/metrics.md` and the specs it cites;
/// symbol names are interop identifiers (each toolkit draws its own
/// artwork: the system's on macOS, OpenViews' own set on Linux).
/// `docs/PARITY.md` §5.10 pairs the two IDEs' windows against these.
public enum WorkspaceChrome {
    // MARK: Window and areas (`workspace-window.md`, reference-ui.md §2, §6)

    public static let windowWidth: Double = 1400
    public static let windowHeight: Double = 900
    public static let navigatorWidth: Double = 290
    public static let inspectorWidth: Double = 260
    /// The toolbar band (`metrics.md` §3): the areas' content starts below it.
    public static let toolbarHeight: Double = 52
    /// Toolbar items' shapes: 36 tall, 8 from the window's top.
    public static let toolbarItemHeight: Double = 36
    public static let toolbarItemTop: Double = 8
    /// The debug area's height when first opened (`metrics.md` §7).
    public static let debugAreaHeight: Double = 135

    // MARK: Navigator area (`metrics.md` §2)

    /// The selector capsule: 30 tall, 6 from both sides of the area, its
    /// top 1 below the toolbar band (y 51).
    public static let selectorHeight: Double = 30
    public static let selectorInset: Double = 6
    /// The selected icon's pill.
    public static let selectorPillSize = (width: 30.0, height: 24.0)
    /// Rows are 22 tall; the first row's top is 7 below the selector.
    public static let rowHeight: Double = 22
    public static let firstRowGap: Double = 7
    /// Outline indentation per level and the level-0 disclosure triangle's
    /// x (source-list layout; `metrics.md` §11 item 1). 14 per level, both
    /// IDEs (`fidelity-council.md` row 19, `metrics.md` §12.1;
    /// `cross-platform-parity.md` §3: it was 12 here and 14 on macOS).
    public static let indentationPerLevel: Double = 14
    public static let disclosureX: Double = 12
    /// The bottom bar (`editor-area.md` F.9, checklist row 110): the "+"
    /// circle 28 × 28 at x 7–35 and the filter capsule 240 × 28 at
    /// x 42.5–282.5 of a 290-point navigator, 8 above the window's bottom
    /// edge (y 844–872 of 880). They were 31 × 30 and 243 × 30, 7 above.
    public static let filterBarHeight: Double = 28
    public static let filterBarBottomInset: Double = 8
    public static let plusCircleWidth: Double = 28
    public static let plusToFilter: Double = 7.5
    /// The bar's room at the navigator's leading and trailing edges.
    public static let filterBarLeading: Double = 7
    public static let filterBarTrailing: Double = 7.5
    /// The filter-options glyph in dark (#ABABAC).
    public static let filterGlyphDark: UInt32 = 0xABABAC
    /// The filter-options glyph and its chevron in light: #777777 with a
    /// 1-point stroke, the circle's ink 14.5 × 13 (`editor-area.md` H.9,
    /// council row 165; Ycode drew them black).
    public static let filterGlyphLight: UInt32 = 0x777777
    /// The glyph's colour in the light or dark appearance (0xRRGGBB).
    public static func filterGlyph(dark: Bool) -> UInt32 { dark ? filterGlyphDark : filterGlyphLight }

    /// The navigators in selector order (`CommandTable.navigators`).
    public static let navigatorSymbols = [
        "folder", "arrow.triangle.branch", "bookmark", "magnifyingglass", "exclamationmark.triangle",
        "checkmark.diamond", "gauge.with.dots.needle.33percent", "tag", "list.bullet.rectangle",
    ]

    // MARK: Editor area (`metrics.md` §4)

    /// The jump bar's band, then a 1-point separator.
    public static let jumpBarBandHeight: Double = EditorMetrics.jumpBarBand
    public static var jumpBarHeight: Double { jumpBarBandHeight + EditorMetrics.jumpBarSeparator }
    /// The gutter: line numbers right-aligned in the 36 points left of a
    /// 12-point folding-ribbon column.
    public static let gutterWidth: Double = 48
    public static let foldingRibbonWidth: Double = 12
    /// The text inset left of the first column, after the gutter.
    public static let textInset: Double = 9
    /// The minimap: 112 wide at an 845-point editor (13.3 %).
    public static let minimapFraction: Double = 112.0 / 845.0
    /// The debug bar under the editor (with the debug area hidden: at the
    /// window's bottom), with its separator.
    public static let debugBarHeight: Double = 36
    /// The debug area's bottom bars (variables, console).
    public static let bottomBarHeight: Double = 28
    public static let bottomBarSideInset: Double = 6

    // MARK: Inspector area (`metrics.md` §5)

    public static let inspectorSymbols = ["doc", "clock", "questionmark.circle"]
    public static let inspectorTabPillSize = (width: 78.0, height: 24.0)
    /// The content's side insets (`metrics.md` §12.4): 7 from the divider,
    /// 8 from the window's edge; views with one inset use their mean.
    public static let inspectorLeadingInset: Double = 7
    public static let inspectorTrailingInset: Double = 8
    public static let inspectorContentInset: Double = 7.5
    public static let inspectorContentTopInset: Double = 4
    /// The right-aligned key column ("Name", "Type", …): its ink ends at
    /// the inspector's edge + 78; values start 5 after it.
    public static let inspectorKeyColumnWidth: Double = 72
    public static let inspectorKeyToValue: Double = 5

    // MARK: Toolbar (`liquid-glass-ycode.md` §2, `liquid-glass.md` §2.2)

    /// One toolbar item: its symbols (a segmented item has several) and
    /// tooltips, in the order the toolbar shows them.
    public struct ToolbarItem: Equatable, Sendable {
        public var id: String
        public var symbols: [String]
        public var toolTips: [String]
    }

    /// The leading capsule: a list glyph (the navigators) and a sparkle
    /// (the coding assistant), as the reference's (`editor-area.md` H.9,
    /// council row 166; Ycode had a sidebar glyph and a speech bubble).
    public static let leftPanes = ToolbarItem(id: "leftPanes", symbols: ["list.bullet", "sparkles"],
                                              toolTips: ["Navigators", "Coding Assistant"])
    public static let runStop = ToolbarItem(id: "run", symbols: ["play.fill", "stop.fill"],
                                            toolTips: ["Build and then run the current scheme", "Stop the running scheme or application"])
    public static let history = ToolbarItem(id: "history", symbols: ["chevron.left", "chevron.right"],
                                            toolTips: ["Show Previous Location in History", "Show Next Location in History"])
    public static let newConversation = ToolbarItem(id: "newConversation", symbols: ["plus.bubble"], toolTips: ["New Conversation"])
    /// New Conversation's glyph is filled with a pink-to-purple gradient,
    /// top leading to bottom trailing (H.9, row 166; the reference's fill
    /// style, in Ycode's own colours): 0xRRGGBB at each end.
    public static let newConversationGradient: (start: UInt32, end: UInt32) = (0xF2559E, 0x8E5BF5)
    public static let addEditor = ToolbarItem(id: "addEditor", symbols: ["plus.rectangle.on.rectangle"],
                                              toolTips: ["Add Editor Tabs or Editor Panes"])
    public static let editorOptions = ToolbarItem(id: "editorOptions", symbols: ["line.3.horizontal"], toolTips: ["Adjust Editor Options"])
    public static let editorModes = ToolbarItem(id: "editorModes",
                                                symbols: ["rectangle.righthalf.inset.filled", "rectangle.split.2x1", "arrow.left.arrow.right"],
                                                toolTips: ["Canvas", "Assistant", "Code Review"])
    public static let inspectorToggle = ToolbarItem(id: "inspectorToggle", symbols: ["sidebar.right"], toolTips: ["Hide Inspector"])

    // MARK: Symbols of rows

    /// A project navigator row's symbol.
    public static func symbol(for node: NavigatorNode) -> String {
        symbol(kind: node.kind, name: node.name, path: node.path)
    }

    public static func symbol(kind: NavigatorNode.Kind, name: String, path: String?) -> String {
        switch kind {
        case .container:
            if path?.hasSuffix(".xcworkspace") == true { return "square.stack.3d.up" }
            return path?.hasSuffix(".xcodeproj") == true ? "folder.badge.gearshape" : "shippingbox"
        case .group, .folder: return "folder.fill"
        case .file: return fileSymbol(name)
        }
    }

    /// The file-type glyph of a file name or path.
    public static func fileSymbol(_ name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension {
        case "swift": "chevron.left.forwardslash.chevron.right"
        case "h", "m", "c", "mm", "cpp": "c.square"
        case "xcassets": "photo.on.rectangle"
        case "xcstrings": "character.book.closed"
        case "plist", "json": "list.bullet.rectangle"
        case "storyboard", "xib": "rectangle.on.rectangle"
        case "xcconfig": "gearshape"
        case "app", "framework", "xctest", "a", "dylib": "shippingbox"
        case "png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "bmp", "webp": "photo"
        default: "doc.text"
        }
    }

    /// The colour family of a project navigator row's icon (`navigators.md`
    /// "Council round 1" item 4; Ycode's own glyphs, only the family
    /// follows the reference): Swift sources orange, folders and groups
    /// light blue, the project and images blue; other files keep the
    /// accent colour.
    /// Round 2 (`metrics.md` §13.1): a `PBXGroup` gets a neutral grey
    /// filled folder, even with a folder on disk; synchronized folders and
    /// the folders in them stay blue.
    public enum IconTint: Equatable, Sendable { case orange, lightBlue, blue, grey, accent }

    public static func iconTint(kind: NavigatorNode.Kind, name: String) -> IconTint {
        switch kind {
        case .container: return .blue
        case .group: return .grey
        case .folder: return .lightBlue
        case .file:
            switch URL(fileURLWithPath: name).pathExtension {
            case "swift": return .orange
            case "png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "bmp", "webp", "xcassets": return .blue
            default: return .accent
            }
        }
    }

    // MARK: Jump bar (reference-ui-6.md §4.1)

    /// A file's jump-bar title: without its extension when extensions are hidden.
    public static func jumpBarFileTitle(_ name: String, hideExtension: Bool) -> String {
        guard hideExtension else { return name }
        let bare = (name as NSString).deletingPathExtension
        return bare.isEmpty ? name : bare
    }

    /// The jump bar's path components (title, symbol) for a file: the
    /// project tree's nodes down to the file, else the workspace and the file.
    public static func jumpPath(for url: URL, root: NavigatorNode, workspaceName: String, hideExtension: Bool) -> [(String, String)] {
        var trail: [NavigatorNode] = []
        func search(_ n: NavigatorNode, _ path: [NavigatorNode]) -> Bool {
            if n.path == url.path && n.kind == .file { trail = path + [n]; return true }
            return n.children.contains { search($0, path + [n]) }
        }
        _ = search(root, [])
        if trail.isEmpty {
            return [(workspaceName, "folder.badge.gearshape"), (jumpBarFileTitle(url.lastPathComponent, hideExtension: hideExtension), "doc.text")]
        }
        return trail.map { ($0.kind == .file ? jumpBarFileTitle($0.name, hideExtension: hideExtension) : $0.name, symbol(for: $0)) }
    }

    /// The symbol component after the path outside a declaration.
    public static let jumpBarNoSymbol = "No Selection"

    // MARK: File inspector (reference-ui.md §6)

    /// The File inspector's Type pop-up: "Default - <type name>".
    public static func fileTypeName(for url: URL) -> String {
        switch url.pathExtension {
        case "swift": "Swift Source"
        case "m": "Objective-C Source"
        case "h": "C Header"
        case "c": "C Source"
        case "plist": "Property List"
        case "xcconfig": "Configuration Settings File"
        case "png": "PNG Image"   // editor-area.md §C.6
        case "jpg", "jpeg": "JPEG Image"
        case "gif": "GIF Image"
        case "tif", "tiff": "TIFF Image"
        case "heic": "HEIC Image"
        default: "Default"
        }
    }

    // MARK: Activity view (reference-ui-6.md §3.1)

    /// The activity line after an action: "<result> • Today at <time>"
    /// (the time in the locale's short style).
    public static func activityFinishedText(_ result: String, at date: Date) -> String {
        "\(result) \u{2022} Today at \(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))"
    }

    public static let textEncodingItems = ["No Explicit Encoding", "Unicode (UTF-8)"]
    public static let lineEndingItems = ["No Explicit Line Endings", "macOS / Unix (LF)"]
}

// MARK: - "Ycode Default" as values

extension WorkspaceChrome {
    /// "Ycode Default" (the first built-in theme) has no colors of its own:
    /// the AppKit IDE draws it with the measured reference values where the
    /// council measured them (`editor-area.md` §C.2 and §C.4 for light, F.3
    /// for dark; `fidelity-council.md` rows 10, 85, 86) and the system's
    /// dynamic colors elsewhere. A toolkit without those draws it with
    /// these values (the unmeasured roles as read from the AppKit IDE's own
    /// windows, `docs/PARITY.md` §5.10): the editor's background, text,
    /// current line, line numbers and the role colors, in light and dark.
    public struct DefaultThemeColors: Equatable, Sendable {
        public var background: ThemeColor
        public var foreground: ThemeColor
        public var currentLine: ThemeColor
        public var lineNumber: ThemeColor
        public var selection: ThemeColor
        /// By `SyntaxTokenKind.Role` raw value (`SourceTokenizer.Kind` names).
        public var tokens: [String: ThemeColor]
    }

    public static func defaultThemeColors(dark: Bool) -> DefaultThemeColors {
        func c(_ hex: String) -> ThemeColor { ThemeColor(hex: hex)! }
        if dark {
            return DefaultThemeColors(
                background: c("#262626"), foreground: c("#FAF1F3"), currentLine: c("#353535"), lineNumber: c("#706D6E"),
                selection: c("#3F638B"),
                tokens: ["keyword": c("#FF83B4"), "comment": c("#ABB3CD"), "docComment": c("#68CE67"), "string": c("#FF8E7B"),
                         "number": c("#ECA900"), "preprocessor": c("#FF9F0A"), "attribute": c("#AC8E68"), "typeName": c("#D997FF"),
                         "typeDeclaration": c("#00CAFB"), "otherDeclaration": c("#27A7C1"), "propertyReference": c("#20AD9D")])
        }
        return DefaultThemeColors(
            background: c("#FFFFFF"), foreground: c("#322529"), currentLine: c("#EEEEEE"), lineNumber: c("#B8B3B4"),
            selection: c("#B3D7FF"),
            tokens: ["keyword": c("#C4246E"), "comment": c("#6A7084"), "docComment": c("#67C468"), "string": c("#CA2B1C"),
                     "number": c("#0178B8"), "preprocessor": c("#FF9500"), "attribute": c("#A2845E"), "typeName": c("#9D31CF"),
                     "typeDeclaration": c("#007D9E"), "otherDeclaration": c("#006178")])
    }
}
