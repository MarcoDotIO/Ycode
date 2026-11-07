// The Linux device window's frame, laid out as the macOS device window
// (device-hub.md §3, §6, §11; cross-platform-parity.md §13): a 52-point
// toolbar across the top, the device canvas below it, the Settings
// inspector (280 wide) at the right. The toolbar holds the window's title
// and subtitle (the device and its OS), then, right-aligned over the canvas,
// [Capture Keyboard │ resize mode] [Zoom Out · Zoom to Fit · Actual Size ·
// Zoom In] [More Actions], and over the inspector its tabs [Settings ·
// Reports · Info]. The canvas keeps the control capsules at its bottom
// (DeviceControlsLayout), as on macOS.
//
// Ycode's choices where the Linux window differs from the hub: it shows one
// device (no sidebar, so no Add Device, Filter or sidebar toggle) and has
// no Open in New Window (it is the device's own window).

import Foundation
import YcodeDeviceModel

public struct DeviceWindowFrame: Equatable, Sendable {
    public static let toolbarHeight = 52.0
    /// The inspector's width (device-hub.md §11.3: 279.5).
    public static let inspectorWidth = 280.0
    /// The toolbar's capsules: 36 tall, centred in the band.
    public static let capsuleHeight = 36.0
    /// One segment of a capsule.
    public static let segmentWidth = 36.0
    /// Between capsules, and from the last one to the canvas's right edge.
    public static let groupGap = 8.0
    public static let trailingInset = 10.0
    /// The title's left edge (no window buttons or sidebar toggle here).
    public static let titleX = 20.0

    public var width: Double
    public var height: Double
    public var inspectorShown: Bool

    public init(width: Double, height: Double, inspectorShown: Bool = true) {
        self.width = width
        self.height = height
        self.inspectorShown = inspectorShown
    }

    /// The toolbar's items.
    public enum Item: String, CaseIterable, Sendable {
        case captureKeyboard, resizeMode, zoomOut, zoomFit, zoomActual, zoomIn, more, settingsTab, reportsTab, infoTab

        public var title: String {
            switch self {
            case .captureKeyboard: "Capture Keyboard"
            case .resizeMode: "Enter resize mode"
            case .zoomOut: "Zoom Out"
            case .zoomFit: "Zoom to Fit"
            case .zoomActual: "Zoom To Actual Size"
            case .zoomIn: "Zoom In"
            case .more: "More Actions"
            case .settingsTab: "Settings"
            case .reportsTab: "Reports"
            case .infoTab: "Info"
            }
        }

        /// The symbol (the macOS window's names; OpenViews draws its own artwork).
        public var symbol: String {
            switch self {
            case .captureKeyboard: "keyboard"
            case .resizeMode: "rectangle.inset.filled"
            case .zoomOut: "minus.magnifyingglass"
            case .zoomFit: "arrow.up.left.and.down.right.magnifyingglass"
            case .zoomActual: "1.magnifyingglass"
            case .zoomIn: "plus.magnifyingglass"
            case .more: "ellipsis"
            case .settingsTab: "slider.horizontal.3"
            case .reportsTab: "doc.text"
            case .infoTab: "info"
            }
        }
    }

    /// The groups, left to right: each capsule's items.
    public static let groups: [[Item]] = [[.captureKeyboard, .resizeMode], [.zoomOut, .zoomFit, .zoomActual, .zoomIn], [.more]]
    public static let tabs: [Item] = [.settingsTab, .reportsTab, .infoTab]

    public var toolbar: ViewerRect { ViewerRect(x: 0, y: 0, width: width, height: Self.toolbarHeight) }

    public var inspector: ViewerRect? {
        guard inspectorShown else { return nil }
        return ViewerRect(x: width - Self.inspectorWidth, y: Self.toolbarHeight, width: Self.inspectorWidth,
                          height: max(0, height - Self.toolbarHeight))
    }

    /// Where the device and its capsules go.
    public var canvas: ViewerRect {
        ViewerRect(x: 0, y: Self.toolbarHeight, width: max(1, width - (inspectorShown ? Self.inspectorWidth : 0)),
                   height: max(1, height - Self.toolbarHeight))
    }

    /// The capsules over the canvas, right-aligned to its right edge.
    public var capsules: [(items: [Item], rect: ViewerRect)] {
        var x = canvas.width - Self.trailingInset
        var out: [(items: [Item], rect: ViewerRect)] = []
        for g in Self.groups.reversed() {
            let w = Double(g.count) * Self.segmentWidth
            x -= w
            out.insert((g, ViewerRect(x: x, y: (Self.toolbarHeight - Self.capsuleHeight) / 2, width: w, height: Self.capsuleHeight)), at: 0)
            x -= Self.groupGap
        }
        if let i = inspector {
            let w = Double(Self.tabs.count) * Self.segmentWidth
            out.append((Self.tabs, ViewerRect(x: i.x + i.width - Self.trailingInset - w, y: (Self.toolbarHeight - Self.capsuleHeight) / 2,
                                               width: w, height: Self.capsuleHeight)))
        }
        return out
    }

    /// Each item's rectangle.
    public func rect(of item: Item) -> ViewerRect? {
        for c in capsules {
            if let i = c.items.firstIndex(of: item) {
                return ViewerRect(x: c.rect.x + Double(i) * Self.segmentWidth, y: c.rect.y, width: Self.segmentWidth, height: c.rect.height)
            }
        }
        return nil
    }

    public func item(at x: Double, _ y: Double) -> Item? {
        Item.allCases.first { rect(of: $0)?.contains(x, y) == true }
    }

    /// The title's leading edge and the room it has before the first capsule.
    public var titleWidth: Double { max(0, (capsules.first?.rect.x ?? width) - Self.titleX - 12) }

    /// The window that shows a canvas of `canvasWidth` × `canvasHeight`.
    public static func windowSize(canvasWidth: Double, canvasHeight: Double, inspectorShown: Bool = true) -> (width: Double, height: Double) {
        (canvasWidth + (inspectorShown ? inspectorWidth : 0), canvasHeight + toolbarHeight)
    }
}

/// The Settings inspector's cards (device-hub.md §6, §11.3; the macOS
/// `InspectorCard` metrics): cards 260 wide, 10 inside the inspector, the
/// first 8 under the toolbar, 10 apart, radius 12; rows 42 tall with a
/// 1-point separator inset to the label column; the symbol 13.5 inside the
/// card, the label at 38, the control at the trailing edge.
public struct DeviceInspectorContent: Equatable, Sendable {
    public static let cardInset = 10.0
    public static let cardTop = 8.0
    public static let cardGap = 10.0
    public static let cardRadius = 12.0
    public static let rowHeight = 42.0
    public static let separator = 1.0
    public static let symbolX = 13.5
    public static let labelX = 38.0
    public static let trailing = 13.0

    public enum Control: Equatable, Sendable {
        /// A pop-up: its value.
        case popUp(String)
        case slider(Double)
        case toggle(Bool)
    }

    public struct Row: Equatable, Sendable {
        public var symbol: String
        public var label: String
        public var control: Control
        public var enabled: Bool
        public init(symbol: String, label: String, control: Control, enabled: Bool) {
            self.symbol = symbol
            self.label = label
            self.control = control
            self.enabled = enabled
        }
    }

    public var cards: [[Row]]
    /// A note under the cards (why the rows are disabled).
    public var note: String?

    public init(cards: [[Row]], note: String?) {
        self.cards = cards
        self.note = note
    }

    /// The iOS simulator's settings as the macOS inspector groups them
    /// (§11.3), every row disabled, with `note` under them: what the window
    /// shows until the device's settings can be read here.
    public static func standard(note: String?) -> DeviceInspectorContent {
        func row(_ s: String, _ l: String, _ c: Control) -> Row { Row(symbol: s, label: l, control: c, enabled: false) }
        return DeviceInspectorContent(cards: [
            [row("circle.lefthalf.filled", "Appearance", .popUp("Light")), row("drop", "Liquid Glass", .slider(0.5)),
             row("camera.filters", "Color Filter", .popUp("None")), row("textformat.size", "Text Size", .slider(0.5)),
             row("circle.dotted.and.circle", "Reduce Motion", .toggle(false)), row("circle.righthalf.filled", "Increase Contrast", .toggle(false)),
             row("square.dashed", "Show Borders", .toggle(false)), row("square.on.square.intersection.dashed", "Reduce Transparency", .toggle(false)),
             row("speaker.wave.2.bubble", "VoiceOver", .toggle(false))],
            [row("location", "Location", .popUp("None"))],
            [row("speaker.wave.2", "Sound", .slider(0.5)), row("hifispeaker", "Output", .popUp("System")),
             row("mic", "Input", .popUp("System"))],
        ], note: note)
    }

    /// The note this window shows: its settings are changed from the IDE's
    /// device window on macOS, or with `ycode sim` commands (Ycode's choice).
    public static let notAvailableNote = "This window can't change the device's settings yet."

    /// The cards' rectangles in an inspector `width` wide (inspector coordinates).
    public func cardRects(width: Double) -> [ViewerRect] {
        var y = Self.cardTop
        return cards.map { rows in
            let h = Double(rows.count) * Self.rowHeight + Double(max(0, rows.count - 1)) * Self.separator
            defer { y += h + Self.cardGap }
            return ViewerRect(x: Self.cardInset, y: y, width: width - 2 * Self.cardInset, height: h)
        }
    }
}

/// What the toolbar and the inspector show; the window asks its chrome
/// renderer for a picture of each part when this changes.
public struct DeviceChromeRequest: Equatable, Sendable {
    public enum Part: Sendable { case toolbar, inspector }
    public var frame: DeviceWindowFrame
    public var title: String
    public var subtitle: String
    public var dark: Bool
    public var scaleMode: ViewerScaleMode
    public var capturesKeyboard: Bool
    public var inspectorTab: DeviceWindowFrame.Item
    public var inspector: DeviceInspectorContent
    /// Output pixels per point.
    public var pixelDensity: Double

    public init(frame: DeviceWindowFrame, title: String, subtitle: String, dark: Bool, scaleMode: ViewerScaleMode, capturesKeyboard: Bool,
                inspectorTab: DeviceWindowFrame.Item, inspector: DeviceInspectorContent, pixelDensity: Double) {
        self.frame = frame
        self.title = title
        self.subtitle = subtitle
        self.dark = dark
        self.scaleMode = scaleMode
        self.capturesKeyboard = capturesKeyboard
        self.inspectorTab = inspectorTab
        self.inspector = inspector
        self.pixelDensity = pixelDensity
    }

    /// The items drawn selected: the zoom in effect, Capture Keyboard when
    /// on, the inspector's tab.
    public var selectedItems: Set<DeviceWindowFrame.Item> {
        var s: Set<DeviceWindowFrame.Item> = [inspectorTab]
        switch scaleMode {
        case .fit: s.insert(.zoomFit)
        case .point: s.insert(.zoomActual)
        case .pixel: break
        }
        if capturesKeyboard { s.insert(.captureKeyboard) }
        return s
    }

    /// Items drawn disabled: resize mode (not built, as on macOS).
    public static let disabledItems: Set<DeviceWindowFrame.Item> = [.resizeMode]
}

/// A part of the chrome as pixels: straight (not premultiplied) RGBA8, rows
/// top to bottom.
public struct DeviceChromeImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var rgba: [UInt8]
    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

/// The window's colours for the toolbar band and the inspector (sRGB hex):
/// the canvas colour under the toolbar (§12.1: #1E1E1F in dark, white in
/// light), the inspector #EDEDEE / #252627, cards #E6E6E7 / #313133,
/// separators #DCDCDD / white at 9 %.
public enum DeviceChromePalette {
    public static func toolbar(dark: Bool) -> UInt32 { dark ? 0x1E1E1F : 0xFFFFFF }
    public static func inspector(dark: Bool) -> UInt32 { dark ? 0x252627 : 0xEDEDEE }
    public static func card(dark: Bool) -> UInt32 { dark ? 0x313133 : 0xE6E6E7 }
    public static func separator(dark: Bool) -> (hex: UInt32, alpha: Double) { dark ? (0xFFFFFF, 0.09) : (0xDCDCDD, 1) }
    /// Enabled toolbar glyphs: #E1E1E1 in dark (§12.2), black in light.
    public static func glyph(dark: Bool) -> UInt32 { dark ? 0xE1E1E1 : 0x1F1F1F }
    public static func label(dark: Bool) -> UInt32 { dark ? 0xFFFFFF : 0x000000 }
    public static func secondaryLabel(dark: Bool) -> UInt32 { dark ? 0x98989D : 0x6E6E73 }
    /// The toolbar capsules' glass (the device capsules' fill, §12.1).
    public static func capsule(dark: Bool) -> UInt32 { dark ? 0x3B3B3D : 0xF5F5F5 }
    public static func capsuleRim(dark: Bool) -> UInt32 { dark ? 0x5F5F60 : 0xE7E7E7 }
    /// A selected segment's pill.
    public static func selected(dark: Bool) -> UInt32 { dark ? 0x5A5A5C : 0xDCDCDE }
}
