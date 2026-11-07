import Foundation

// Council round 5 in Settings (`specs/ide/settings.md` R5.1–R5.5, checklist
// rows 117–124), shared by the macOS IDE (YcodeUI) and the Linux IDE
// (ycode-ide), so that both draw the same Appearance pane, Components pane
// and simulator-host page from one set of numbers, colours and texts.

// MARK: Appearance (R5.1)

/// The Appearance pane's measured geometry (window points, top-left origin).
/// The pane has a fixed top part (the Appearance card, the preview, the
/// Theme / Fonts / Editor control between two full-width separators) and a
/// list below it that scrolls on its own.
public enum SettingsAppearanceLayout {
    /// Card 1: x 200–690, y 72–160.
    public static let cardTop: CGFloat = 72
    public static let cardHeight: CGFloat = 88
    /// The "Appearance" label's cap top (13.5 inside the card).
    public static let labelCapTop: CGFloat = 85.5
    /// Three thumbnails 67 × 44, right-aligned, 8 apart, the last 10 inside
    /// the card: x 463, 538, 613; y 85–129.
    public static let thumbnailSize = CGSize(width: 67, height: 44)
    public static let thumbnailRadius: CGFloat = 4.5
    public static let thumbnailGap: CGFloat = 8
    public static let thumbnailTop: CGFloat = 85
    public static let thumbnailTrailingInset: CGFloat = 10
    /// The thumbnails' left edges (window x).
    public static var thumbnailXs: [CGFloat] {
        let right = SettingsLayout.detailX + SettingsLayout.cardInset + SettingsLayout.cardWidth - thumbnailTrailingInset
        return (0..<3).map { right - CGFloat(3 - $0) * thumbnailSize.width - CGFloat(2 - $0) * thumbnailGap }
    }
    /// The selection ring: 3 points wide, 1 point outside the thumbnail
    /// (its outer edge 4 outside), corner radius 8.
    public static let ringWidth: CGFloat = 3
    public static let ringGap: CGFloat = 1
    public static let ringRadius: CGFloat = 8
    /// Captions: about 11 points, centred, cap top 139 (10 under the thumbnails).
    public static let captionFontSize: CGFloat = 11
    public static let captionCapTop: CGFloat = 139

    /// The preview box: x 200–690, y 170–239.5, a 1-point border, radius 5.
    public static let previewTop: CGFloat = 170
    public static let previewHeight: CGFloat = 69.5
    public static let previewRadius: CGFloat = 5
    /// Line numbers end 28 inside the box (x 228); the code starts 43 inside (x 243).
    public static let lineNumberEnd: CGFloat = 28
    public static let codeInset: CGFloat = 43
    /// One row per line, 18 apart, from 5 inside the box; no wrapping.
    public static let linePitch: CGFloat = 18
    public static let firstLineTop: CGFloat = 5

    /// The full-width separators (x 180–710): 1 point at y 251.5, 0.5 at 304.5.
    public static let separator1Y: CGFloat = 251.5
    public static let separator1Height: CGFloat = 1
    public static let separator2Y: CGFloat = 304.5
    public static let separator2Height: CGFloat = 0.5
    /// Theme / Fonts / Editor: 210 × 28 centred on the detail pane (x 340–550),
    /// y 264.5–292.5; 70 per segment; the divider 18 tall between two
    /// unselected segments only.
    public static let segmentsTop: CGFloat = 264.5
    public static let segmentsSize = CGSize(width: 210, height: 28)
    public static let segmentDividerHeight: CGFloat = 18
    public static let segmentTitles = ["Theme", "Fonts", "Editor"]
    /// The list starts under the second separator.
    public static let listTop: CGFloat = 305

    /// List card A: Theme (39.5, a push button) and Name (36).
    public static let themeRowHeight: CGFloat = 39.5
    public static let nameRowHeight: CGFloat = 36
    /// A colour row (Foreground and the rows after it): 56 tall, the label's
    /// cap top 13 under the row's top, the slider and the well centred.
    public static let colorRowHeight: CGFloat = 56
    public static let colorLabelCapTop: CGFloat = 13
    /// The slider: x 421.5–624 (221.5–424 inside the card), a 14-point
    /// track and a knob about 27 across.
    public static let sliderX: CGFloat = 221.5
    public static let sliderWidth: CGFloat = 202.5
    public static let sliderTrackHeight: CGFloat = 14
    public static let sliderKnob: CGFloat = 27
    /// The colour well: a 48 × 28 capsule 10 inside the card, a 3-point rim.
    public static let wellSize = CGSize(width: 48, height: 28)
    public static let wellRim: CGFloat = 3

    /// The push button ("Choose…", 80.5 wide): 24 tall, its label about
    /// 12 from each end.
    public static let pushButtonHeight: CGFloat = 24
    public static let pushButtonPadding: CGFloat = 12.25
}

/// Round 5's colours as (light, dark) sRGB hex pairs: light as measured,
/// dark Ycode's own where round 5 did not capture it.
public enum SettingsR5Palette {
    public typealias Pair = SettingsPaletteHex.Pair
    /// The selection ring around a thumbnail.
    public static let ring: Pair = (0x0088FF, 0x0A84FF)
    public static let caption: Pair = (0x7C7C7C, 0x9D9D9D)
    public static let captionSelected: Pair = (0x262626, 0xDEDEDE)
    public static let previewBorder: Pair = (0xE6E6E6, 0x3A3A3A)
    public static let lineNumber: Pair = (0xB8B3B4, 0x6E6E6E)
    /// The full-width separators of the Appearance pane.
    public static let paneSeparator: Pair = (0xE5E5E5, 0x383838)
    public static let segmentsTrack: Pair = (0xECECEC, 0x3A3A3A)
    public static let segmentsDivider: Pair = (0xB5B5B5, 0x5A5A5A)
    public static let segmentsLabel: Pair = (0x242424, 0xDEDEDE)
    public static let segmentSelected: Pair = (0x0077F9, 0x0A7CFF)
    public static let pushButton: Pair = (0xE4E4E4, 0x3D3D3D)
    public static let pushButtonLabel: Pair = (0x232323, 0xE0E0E0)
    public static let wellRim: Pair = (0xE2E2E2, 0x4A4A4A)
    /// Components' subtitles, "Last used" and the info button (R5.2).
    public static let subtitle: Pair = (0x7C7C7C, 0x9D9D9D)
    /// Components' platform symbols: the accent colour in both appearances.
    public static let platformSymbol: Pair = (0x007AFF, 0x007AFF)
}

/// The Appearance thumbnails (R5.1), in Ycode's own drawing: a miniature
/// window over a wallpaper. Light: a light window with a light title area
/// and three window-button dots over a blue wave; Dark: the same in dark
/// over a deep blue; System: the Light picture's left half and the Dark
/// picture's right half. Coordinates are in the 67 × 44 thumbnail, top-left.
public enum AppearanceThumbnailArt {
    public struct Look: Sendable {
        /// The wallpaper's vertical gradient and its wave band.
        public let wallpaperTop: UInt32
        public let wallpaperBottom: UInt32
        public let wave: UInt32
        public let waveOpacity: Double
        public let window: UInt32
        public let titleArea: UInt32
        public let windowEdge: UInt32
    }

    public static let light = Look(wallpaperTop: 0x9DD0FF, wallpaperBottom: 0x2F7DF0, wave: 0xFFFFFF, waveOpacity: 0.35,
                                   window: 0xFFFFFF, titleArea: 0xF0F0F0, windowEdge: 0xD6D6D6)
    public static let dark = Look(wallpaperTop: 0x1D3B8F, wallpaperBottom: 0x0A1236, wave: 0x3D63D6, waveOpacity: 0.55,
                                  window: 0x262626, titleArea: 0x333333, windowEdge: 0x4A4A4A)

    /// The window: from (10, 9), 47 wide, running past the bottom edge.
    public static let window = CGRect(x: 10, y: 9, width: 47, height: 40)
    public static let windowRadius: CGFloat = 3
    public static let titleAreaHeight: CGFloat = 7
    /// The window buttons' dots (centres) and their diameter.
    public static let dots: [(x: CGFloat, color: UInt32)] = [(14, 0xFF5F57), (18, 0xFEBC2E), (22, 0x28C840)]
    public static let dotY: CGFloat = 12.5
    public static let dotDiameter: CGFloat = 2.5
    /// System's split, at the middle.
    public static var splitX: CGFloat { SettingsAppearanceLayout.thumbnailSize.width / 2 }

    /// The wave: a band from the left edge to the right edge, as a closed
    /// polygon of points (thumbnail coordinates).
    public static let wave: [CGPoint] = {
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        let w = SettingsAppearanceLayout.thumbnailSize.width
        for i in 0...16 {
            let x = w * CGFloat(i) / 16
            let t = Double(i) / 16 * 2 * Double.pi
            top.append(CGPoint(x: x, y: 20 + 7 * CGFloat(sin(t + 0.6))))
            bottom.append(CGPoint(x: x, y: 31 + 6 * CGFloat(sin(t + 1.4))))
        }
        return top + bottom.reversed()
    }()
}

/// The theme's colour rows, in order, on both IDEs: Foreground (the text),
/// the token kinds, then the editor's background, selection and current line.
public enum ThemeColorRows {
    public static let all: [(title: String, key: String)] = [
        ("Foreground", "foreground"), ("Comments", "comment"), ("Documentation Comments", "docComment"), ("Strings", "string"),
        ("Numbers", "number"), ("Keywords", "keyword"), ("Preprocessor Statements", "preprocessor"), ("Attributes", "attribute"),
        ("Type Names", "typeName"), ("Background", "background"), ("Selection", "selection"), ("Current Line", "currentLine"),
    ]

    /// The theme's own value for a row ("#RRGGBB"; nil: the system colour).
    public static func value(_ key: String, in t: EditorTheme) -> String? {
        switch key {
        case "foreground": t.foreground
        case "background": t.background
        case "selection": t.selection
        case "currentLine": t.currentLine
        default: t.tokens[key]
        }
    }

    /// Sets a row's value (nil: the system colour).
    public static func set(_ key: String, _ hex: String?, in t: inout EditorTheme) {
        switch key {
        case "foreground": t.foreground = hex
        case "background": t.background = hex
        case "selection": t.selection = hex
        case "currentLine": t.currentLine = hex
        default: t.tokens[key] = hex
        }
    }

    /// "#RRGGBB" from sRGB components (0–1).
    public static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    /// sRGB components of "#RRGGBB" (nil for anything else).
    public static func components(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// The slider of a colour row (R5.1's track from a pale to a full tint
    /// of the colour): the colour's strength over the editor's background.
    /// At 1 (where the knob starts) it is the colour itself; at 0 it keeps
    /// `minimumStrength` of it.
    public static let minimumStrength = 0.15

    public static func tint(_ base: (r: Double, g: Double, b: Double), over bg: (r: Double, g: Double, b: Double),
                            strength s: Double) -> (r: Double, g: Double, b: Double) {
        let k = minimumStrength + (1 - minimumStrength) * min(max(s, 0), 1)
        return (bg.r + (base.r - bg.r) * k, bg.g + (base.g - bg.g) * k, bg.b + (base.b - bg.b) * k)
    }
}

// MARK: The pane title and the sidebar (R5.3)

public enum SettingsTitleR5 {
    /// The title at 17 points (cap height 12), the same weight in both
    /// appearances; the selected sidebar row's label is semibold.
    public static let selectedSidebarLabelIsSemibold = true
}

// MARK: Components (R5.2)

/// Components' measured geometry (window points).
public enum SettingsComponentsLayout {
    /// "Platform Support": cap top 59; its card from y 82.
    public static let firstHeaderCapTop: CGFloat = 59
    /// A row: 51.5 tall plus a 1-point separator (52.5 pitch).
    public static let rowHeight: CGFloat = 51.5
    /// The icon centred on x 226 (26 inside the card).
    public static let iconCenterInset: CGFloat = 26
    /// The title's ink at x 251 (51 inside), its cap top 13.5 under the row's top.
    public static let titleInset: CGFloat = 51
    public static let titleCapTop: CGFloat = 13.5
    /// The subtitle's baseline 15 under the title's; about 11 points.
    public static let subtitleBaselineGap: CGFloat = 15
    public static let subtitleFontSize: CGFloat = 11
    /// "Last used …" ends at x 655.5 (34.5 inside the card's right edge).
    public static let lastUsedTrailingInset: CGFloat = 34.5
    /// The info button: 13 × 13, its right edge 11.5 inside the card.
    public static let infoSize: CGFloat = 13
    public static let infoTrailingInset: CGFloat = 11.5
}

/// A symbol of a Components row, in Ycode's own drawing: strokes and fills
/// in a small box (points, top-left origin), drawn in the accent colour.
public enum ComponentGlyph: String, Sendable, CaseIterable {
    /// This computer: a laptop.
    case computer
    /// iOS: a tablet with a phone in front of it.
    case iOS
    /// watchOS: a watch.
    case watchOS
    /// tvOS: a display on a stand.
    case tvOS
    /// visionOS: a headset seen from the front.
    case visionOS
    /// Predictive code completion: a cluster of sparkles.
    case sparkles
    /// The simulator host: two stacked machines with lights.
    case simulatorHost

    public enum Part: Sendable {
        /// A rounded rectangle; `knockout` paints it with the card colour first
        /// (a shape in front of another).
        case roundedRect(CGRect, radius: CGFloat, knockout: Bool)
        case polyline([CGPoint])
        case dot(CGPoint, diameter: CGFloat)
        /// A four-pointed star.
        case sparkle(CGPoint, radius: CGFloat)
    }

    /// The box the parts are drawn in.
    public var size: CGSize {
        switch self {
        case .computer: CGSize(width: 21, height: 15)
        case .iOS: CGSize(width: 19, height: 19)
        case .watchOS: CGSize(width: 13, height: 18.5)
        case .tvOS: CGSize(width: 22, height: 17)
        case .visionOS: CGSize(width: 25, height: 14)
        case .sparkles: CGSize(width: 19, height: 19)
        case .simulatorHost: CGSize(width: 20, height: 17)
        }
    }

    public static let lineWidth: CGFloat = 1.4

    public var parts: [Part] {
        switch self {
        case .computer:
            [.roundedRect(CGRect(x: 2.5, y: 0.7, width: 16, height: 11), radius: 1.6, knockout: false),
             .polyline([CGPoint(x: 0.7, y: 13.6), CGPoint(x: 20.3, y: 13.6)])]
        case .iOS:
            [.roundedRect(CGRect(x: 0.7, y: 0.7, width: 13, height: 17.5), radius: 2, knockout: false),
             .roundedRect(CGRect(x: 10, y: 6.5, width: 8.3, height: 12), radius: 1.8, knockout: true)]
        case .watchOS:
            [.polyline([CGPoint(x: 3.5, y: 3.6), CGPoint(x: 4.2, y: 0.7), CGPoint(x: 8.8, y: 0.7), CGPoint(x: 9.5, y: 3.6)]),
             .polyline([CGPoint(x: 3.5, y: 14.9), CGPoint(x: 4.2, y: 17.8), CGPoint(x: 8.8, y: 17.8), CGPoint(x: 9.5, y: 14.9)]),
             .roundedRect(CGRect(x: 1.2, y: 3.6, width: 10.6, height: 11.3), radius: 3, knockout: false),
             .dot(CGPoint(x: 12.4, y: 8.5), diameter: 1.6)]
        case .tvOS:
            [.roundedRect(CGRect(x: 0.7, y: 0.7, width: 20.6, height: 12.6), radius: 1.6, knockout: false),
             .polyline([CGPoint(x: 11, y: 13.3), CGPoint(x: 11, y: 16)]),
             .polyline([CGPoint(x: 7, y: 16.3), CGPoint(x: 15, y: 16.3)])]
        case .visionOS:
            [.roundedRect(CGRect(x: 0.7, y: 0.7, width: 23.6, height: 12.6), radius: 6.3, knockout: false),
             .polyline([CGPoint(x: 10, y: 13.3), CGPoint(x: 11.2, y: 10.4), CGPoint(x: 13.8, y: 10.4), CGPoint(x: 15, y: 13.3)])]
        case .sparkles:
            [.sparkle(CGPoint(x: 7.5, y: 10.5), radius: 7), .sparkle(CGPoint(x: 15, y: 4), radius: 3.6), .sparkle(CGPoint(x: 15.5, y: 15.5), radius: 2.6)]
        case .simulatorHost:
            [.roundedRect(CGRect(x: 0.7, y: 0.7, width: 18.6, height: 6.8), radius: 1.8, knockout: false),
             .roundedRect(CGRect(x: 0.7, y: 9.5, width: 18.6, height: 6.8), radius: 1.8, knockout: false),
             .dot(CGPoint(x: 15.2, y: 4.1), diameter: 2), .dot(CGPoint(x: 15.2, y: 12.9), diameter: 2)]
        }
    }

    /// A sparkle's outline: four points, curved sides.
    public static func sparklePoints(_ c: CGPoint, _ r: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        for i in 0..<32 {
            let a = Double(i) / 32 * 2 * Double.pi
            // An astroid: |x|^(2/3) + |y|^(2/3) = r^(2/3).
            let x = CGFloat(pow(abs(cos(a)), 3)) * (cos(a) < 0 ? -1 : 1)
            let y = CGFloat(pow(abs(sin(a)), 3)) * (sin(a) < 0 ? -1 : 1)
            out.append(CGPoint(x: c.x + r * x, y: c.y + r * y))
        }
        return out
    }
}

/// What Components lists: the SDKs (macOS) and the simulator runtimes of
/// this computer and of the simulator host.
public struct ComponentsInventory: Sendable, Equatable {
    public struct SDK: Sendable, Equatable {
        public var canonicalName: String
        public var version: String
        public init(canonicalName: String, version: String) {
            self.canonicalName = canonicalName
            self.version = version
        }
    }

    public var sdks: [SDK]
    public var runtimes: [SimRuntimeRecord]
    public init(sdks: [SDK] = [], runtimes: [SimRuntimeRecord] = []) {
        self.sdks = sdks
        self.runtimes = runtimes
    }

    /// The platform an SDK is for (nil: this computer's own).
    public static func platform(ofSDK name: String) -> SimPlatform?? {
        let n = name.lowercased()
        if n.hasPrefix("macosx") { return .some(nil) }
        if n.hasPrefix("iphone") { return .iOS }
        if n.hasPrefix("watch") { return .watchOS }
        if n.hasPrefix("appletv") { return .tvOS }
        if n.hasPrefix("xr") { return .visionOS }
        return .none
    }

    /// Reads it: the runtime wizard's checks (this computer's and the
    /// host's runtimes) and, on macOS, the SDKs given. Runs processes:
    /// call it off the main thread.
    public static func read(choices: RuntimeSetupChoices, sdks: [SDK] = []) async -> ComponentsInventory {
        let report = await RuntimeSetupChecker(choices: choices).run()
        return ComponentsInventory(sdks: sdks, runtimes: report.local + report.host)
    }
}

/// One row of Components (R5.2): a symbol, a title, a subtitle, "Last used"
/// when known, and what its info button shows.
public struct ComponentsRow: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// This computer (macOS or Linux), the SDKs Ycode builds with.
        case thisComputer
        case platform(SimPlatform)
        case predictiveCompletion
        case simulatorHost
    }

    public var kind: Kind
    public var glyph: ComponentGlyph
    public var title: String
    public var subtitle: String
    public var lastUsed: String?
    /// The info button's lines (SDKs and runtimes, or a description).
    public var details: [String]
    public var id: String { title + "|" + glyph.rawValue }
}

/// Components' two sections, built the same way on both IDEs.
public enum ComponentsPage {
    public static let platformHeader = "Platform Support"
    public static let otherHeader = "Other Components"
    public static let builtIn = "Built-in"
    public static let notInstalled = "Not installed"

    public static func glyph(_ p: SimPlatform) -> ComponentGlyph {
        switch p {
        case .iOS: .iOS
        case .watchOS: .watchOS
        case .tvOS: .tvOS
        case .visionOS: .visionOS
        }
    }

    /// "Platform Support": this computer first ("Built-in"), then one row
    /// per simulator platform with its newest runtime's version in the
    /// title, its size (or "Not installed") under it and "Last used" when
    /// the runtime was used.
    public static func platformRows(_ inv: ComponentsInventory, isMac: Bool, now: Date = Date()) -> [ComponentsRow] {
        var rows: [ComponentsRow] = []
        let hostSDKs = inv.sdks.filter { ComponentsInventory.platform(ofSDK: $0.canonicalName) == .some(nil) }
        let hostName = isMac ? "macOS" : "Linux"
        let hostVersion = hostSDKs.map(\.version).max(by: versionLess)
        rows.append(ComponentsRow(kind: .thisComputer, glyph: .computer, title: hostVersion.map { "\(hostName) \($0)" } ?? hostName,
                                  subtitle: builtIn, lastUsed: nil,
                                  details: hostSDKs.isEmpty ? [isMac ? "Builds for this Mac with the active developer directory."
                                                                    : "Builds for this computer with the Swift toolchain on the PATH."]
                                      : hostSDKs.map { "\($0.canonicalName) SDK" }))
        for p in SimPlatform.allCases {
            let runtimes = inv.runtimes.filter { $0.platform == p }.sorted { versionLess($0.version, $1.version) }
            let sdks = inv.sdks.filter { ComponentsInventory.platform(ofSDK: $0.canonicalName) == .some(p) }
            let newest = runtimes.last
            let size = newest.flatMap { $0.sizeBytes ?? $0.unpackedBytes }
            let subtitle = newest == nil ? notInstalled : (size.map(sizeText) ?? "Installed")
            let used = runtimes.compactMap { $0.lastUsed.flatMap(date) }.max()
            var details = sdks.map { "\($0.canonicalName) SDK" }
            for r in runtimes.reversed() {
                let place: String = switch r.location {
                case .thisMachine: isMac ? "on this Mac" : "on this computer"
                case .host(let h): h.isEmpty ? "on the simulator host" : "on \(h)"
                }
                details.append("\(p.title) \(r.version) (\(r.build)) simulator runtime, \(place)" + ((r.sizeBytes ?? r.unpackedBytes).map { ", \(sizeText($0))" } ?? ""))
            }
            if details.isEmpty { details = ["No \(p.title) simulator runtime yet. Simulator Runtimes\u{2026} adds one."] }
            rows.append(ComponentsRow(kind: .platform(p), glyph: glyph(p), title: newest.map { "\(p.title) \($0.version)" } ?? p.title,
                                      subtitle: subtitle, lastUsed: used.map { lastUsedText($0, now: now) }, details: details))
        }
        return rows
    }

    /// "Other Components": predictive code completion, then the simulator
    /// host (Ycode's own; its info button opens the host page).
    public static func otherRows(predictiveEnabled: Bool, predictiveBackend: String, predictiveModel: String,
                                 hostDestination: String) -> [ComponentsRow] {
        let predictive = predictiveEnabled ? (predictiveModel.isEmpty ? predictiveBackend : "\(predictiveBackend), \(predictiveModel)") : "Off"
        return [
            ComponentsRow(kind: .predictiveCompletion, glyph: .sparkles, title: "Predictive Code Completion", subtitle: predictive, lastUsed: nil,
                          details: ["Suggestions from a local model server you run (Ycode includes no model). Settings \u{25B8} Editing \u{25B8} Completion sets it up."]),
            ComponentsRow(kind: .simulatorHost, glyph: .simulatorHost, title: SimulatorHostPage.title,
                          subtitle: SimulatorHostPage.subtitle(destination: hostDestination), lastUsed: nil, details: [SimulatorHostPage.summary]),
        ]
    }

    /// "15.94 GB", "820 MB" (decimal units, as disk sizes are shown).
    public static func sizeText(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1e9
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        return String(format: "%.0f MB", max(1, Double(bytes) / 1e6))
    }

    /// "Last used today", "… yesterday", "… 3 days ago", "… 2 weeks ago",
    /// "… 5 months ago", "… 2 years ago".
    public static func lastUsedText(_ d: Date, now: Date = Date()) -> String {
        let days = Int((now.timeIntervalSince(d) / 86_400).rounded(.down))
        let when: String
        switch days {
        case ..<1: when = "today"
        case 1: when = "yesterday"
        case 2..<14: when = "\(days) days ago"
        case 14..<60: when = "\(days / 7) weeks ago"
        case 60..<365: when = "\(days / 30) months ago"
        default: when = days < 730 ? "a year ago" : "\(days / 365) years ago"
        }
        return "Last used " + when
    }

    /// An ISO 8601 date (with or without fractional seconds).
    public static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// Dotted versions compared numerically ("27.10" after "27.9").
    public static func versionLess(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r }
        }
        return false
    }
}

// MARK: The simulator host page (R5.5)

/// Ycode's simulator-host page (no reference counterpart): Settings ▸
/// Components ▸ Simulator Host, the same on both IDEs. Per-device settings
/// (the camera among them) are in the device window's Settings inspector;
/// this page holds the host's own: where it is, its runtimes, how devices
/// boot, and the launcher's options. The Host and Data folder rows are the
/// runtime wizard's host and the macOS IDE's run host at once.
public enum SimulatorHostPage {
    public static let title = "Simulator Host"
    public static let summary = "The arm64 Linux machine with KVM that runs Ycode\u{2019}s simulators. Ycode logs in with an ssh key only and never asks for a password."
    public static let notSetUp = "Not set up"
    public static let runtimesButton = "Simulator Runtimes\u{2026}"
    public static let runtimesHelp = "Copies runtimes to the host, checks it and removes runtimes Ycode copied."

    /// Under the title on the page and in Components: the host, or "Not set up".
    public static func subtitle(destination: String) -> String { destination.isEmpty ? notSetUp : destination }

    public enum Field: String, CaseIterable, Sendable {
        case host, dataFolder, linkName, ports, runtimeRoot, otherRuntimeRoots, simdPath, deviceName, additionalArguments, keepServices

        public var title: String {
            switch self {
            case .host: "Host"
            case .dataFolder: "Data folder"
            case .linkName: "Link name"
            case .ports: "Ports (TCP/UDP)"
            case .runtimeRoot: "Runtime root"
            case .otherRuntimeRoots: "Other runtime roots"
            case .simdPath: "ycode-simd path"
            case .deviceName: "Device name"
            case .additionalArguments: "Additional arguments"
            case .keepServices: "Keep services"
            }
        }

        public var placeholder: String {
            switch self {
            case .host: "user@sim-host"
            case .dataFolder: "/data/ycode"
            case .linkName: "As the host"
            case .ports: "47800/47801"
            case .runtimeRoot: "/data/ycode/runtime"
            case .otherRuntimeRoots: "/data/ycode/runtimes/iOS-27.0, \u{2026}"
            case .simdPath: "/data/ycode/bin/ycode-simd"
            case .deviceName: "ycode-device"
            case .additionalArguments: "--timeout-ms 600000"
            case .keepServices: "com.example.label, \u{2026}"
            }
        }

        public var help: String? {
            switch self {
            case .dataFolder: "Holds runtimes and devices; choose a volume with room for them (about 16 GB per iOS runtime)."
            case .linkName: "The host\u{2019}s name on Ycode\u{2019}s link, when it differs from its ssh name."
            case .otherRuntimeRoots: RemoteSimulatorSettings.runtimesHelp
            default: nil
            }
        }
    }

    public enum Switch: String, CaseIterable, Sendable {
        case leanBoot, warmBoot
        public var title: String { self == .leanBoot ? "Lean boot" : "Warm boot from snapshot" }
        public var help: String { self == .leanBoot ? RemoteSimulatorSettings.leanBootHelp : RemoteSimulatorSettings.warmBootHelp }
    }

    public enum Section: String, CaseIterable, Sendable {
        case host = "Host", runtimes = "Runtimes", boot = "Boot", advanced = "Advanced"
        public var fields: [Field] {
            switch self {
            case .host: [.host, .dataFolder, .linkName, .ports]
            case .runtimes: [.runtimeRoot, .otherRuntimeRoots]
            case .boot: []
            case .advanced: [.simdPath, .deviceName, .additionalArguments, .keepServices]
            }
        }
        public var switches: [Switch] { self == .boot ? [.leanBoot, .warmBoot] : [] }
    }

    /// The host's ssh destination: the wizard's, else the run settings'.
    public static func destination(_ d: UserDefaults) -> String {
        let h = RuntimeSetupChoices.load(d).host.destination
        return h.isEmpty ? RemoteSimulatorSettings.load(d).destination : h
    }

    public static func value(_ f: Field, _ d: UserDefaults) -> String {
        let h = RuntimeSetupChoices.load(d).host, s = RemoteSimulatorSettings.load(d)
        switch f {
        case .host: return h.destination.isEmpty ? s.destination : h.destination
        case .dataFolder: return h.dataDirectory.isEmpty ? s.dataDirectory : h.dataDirectory
        case .linkName: return h.linkName
        case .ports: return "\(h.tcpPort)/\(h.udpPort)"
        case .runtimeRoot: return s.runtimeRoot
        case .otherRuntimeRoots: return s.otherRuntimeRoots.joined(separator: ", ")
        case .simdPath: return s.simdPath
        case .deviceName: return s.deviceName
        case .additionalArguments: return s.additionalArguments
        case .keepServices: return s.keepServices
        }
    }

    /// Saves a field (trimmed). Host and Data folder go to both the wizard's
    /// host and the run settings; a malformed Ports value is ignored.
    public static func set(_ f: Field, _ raw: String, _ d: UserDefaults) {
        let v = raw.trimmingCharacters(in: .whitespaces)
        var c = RuntimeSetupChoices.load(d)
        var s = RemoteSimulatorSettings.load(d)
        switch f {
        case .host: c.host.destination = v; s.destination = v
        case .dataFolder: c.host.dataDirectory = v; s.dataDirectory = v
        case .linkName: c.host.linkName = v
        case .ports:
            guard let (t, u) = RuntimeHostSettings.ports(v) else { return }
            (c.host.tcpPort, c.host.udpPort) = (t, u)
        case .runtimeRoot: s.runtimeRoot = v
        case .otherRuntimeRoots: s.otherRuntimeRoots = RemoteSimulatorSettings.runtimeRoots(fromText: v)
        case .simdPath: s.simdPath = v
        case .deviceName: s.deviceName = v.isEmpty ? "ycode-device" : v
        case .additionalArguments: s.additionalArguments = v
        case .keepServices: s.keepServices = v
        }
        if [.host, .dataFolder, .linkName, .ports].contains(f) { c.save(d) }
        if ![.linkName, .ports].contains(f) { s.save(d) }
    }

    public static func isOn(_ sw: Switch, _ d: UserDefaults) -> Bool {
        let s = RemoteSimulatorSettings.load(d)
        return sw == .leanBoot ? s.leanBoot : s.warmBoot
    }

    public static func set(_ sw: Switch, _ on: Bool, _ d: UserDefaults) {
        var s = RemoteSimulatorSettings.load(d)
        if sw == .leanBoot { s.leanBoot = on } else { s.warmBoot = on }
        s.save(d)
    }

    /// The page's text fields: 220 × 22, radius 6, 6 inside, 12 points,
    /// a 1-point border (the same drawing on both IDEs).
    public static let fieldSize = CGSize(width: 220, height: 22)
    public static let fieldRadius: CGFloat = 6
    public static let fieldPadding: CGFloat = 6
    public static let fieldFontSize: CGFloat = 12
    public static let fieldFill: SettingsPaletteHex.Pair = (0xFFFFFF, 0x1F1F1F)
    public static let fieldBorder: SettingsPaletteHex.Pair = (0xD9D9D9, 0x3F3F3F)

    /// The hero card's icon: a 40-point rounded square with the
    /// simulator row icon's gradient and the host symbol in white.
    public static let heroIconSize: CGFloat = 40
    public static let heroIconRadius: CGFloat = 9
    /// The hero card: 14 inside, the title 13-point bold, the summary in the help style.
    public static let heroInset: CGFloat = 14
}

// MARK: The runtime wizard's host step (cross-platform parity §11)

/// The host step's form on both IDEs: right-aligned labels, fields 320
/// wide (Ports 120), 22 tall in the host page's field style, monospaced
/// 12-point text, the note under them.
public enum RuntimeSetupLayout {
    /// The labels' column (macOS sizes it to "Ports (TCP/UDP):").
    public static let labelWidth: CGFloat = 112
    public static let fieldWidth: CGFloat = 320
    public static let portsWidth: CGFloat = 120
    public static let fieldHeight: CGFloat = 22
    public static let fieldRadius: CGFloat = 6
    public static let fieldPadding: CGFloat = 6
    public static let hostNote = "Ycode logs in with an ssh key only and never asks for a password. The data folder holds runtimes and devices; choose a volume with room for them (about 16 GB per iOS runtime)."
}
