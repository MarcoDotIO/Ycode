import Foundation

// AT-SPI2 constants, from the public interface descriptions of at-spi2-core
// (`xml/Accessible.xml`: the AtspiRole and AtspiStateType numbers in the
// GetRole and GetState documentation; `Component.xml`: coordinate types
// and layers; `Text.xml`: granularities and boundary types). These are
// interoperability facts (enumeration values on the wire); no at-spi2
// code is used. Sources and licences: package README, "AT-SPI export".

/// AT-SPI roles (`GetRole`), the subset Ycode maps to plus the
/// application root.
public enum ATSPIRole: UInt32, Sendable, CaseIterable {
    case invalid = 0
    case alert = 2
    case checkBox = 7
    case checkMenuItem = 8
    case comboBox = 11
    case dialog = 16
    case filler = 20
    case frame = 23
    case image = 27
    case label = 29
    case list = 31
    case listItem = 32
    case menu = 33
    case menuBar = 34
    case menuItem = 35
    case pageTab = 37
    case pageTabList = 38
    case panel = 39
    case passwordText = 40
    case popupMenu = 41
    case progressBar = 42
    case pushButton = 43
    case radioButton = 44
    case scrollPane = 49
    case separator = 50
    case slider = 51
    case spinButton = 52
    case splitPane = 53
    case text = 61
    case toggleButton = 62
    case toolBar = 63
    case tree = 65
    case unknown = 67
    case window = 69
    case application = 75
    case entry = 79
    case heading = 83
    case link = 88
    case treeItem = 91
    case listBox = 98
    case grouping = 99
    case pushButtonMenu = 129

    /// The role's name as AT-SPI writes it (`GetRoleName`).
    public var name: String {
        switch self {
        case .invalid: return "invalid"
        case .alert: return "alert"
        case .checkBox: return "check box"
        case .checkMenuItem: return "check menu item"
        case .comboBox: return "combo box"
        case .dialog: return "dialog"
        case .filler: return "filler"
        case .frame: return "frame"
        case .image: return "image"
        case .label: return "label"
        case .list: return "list"
        case .listItem: return "list item"
        case .menu: return "menu"
        case .menuBar: return "menu bar"
        case .menuItem: return "menu item"
        case .pageTab: return "page tab"
        case .pageTabList: return "page tab list"
        case .panel: return "panel"
        case .passwordText: return "password text"
        case .popupMenu: return "popup menu"
        case .progressBar: return "progress bar"
        case .pushButton: return "push button"
        case .radioButton: return "radio button"
        case .scrollPane: return "scroll pane"
        case .separator: return "separator"
        case .slider: return "slider"
        case .spinButton: return "spin button"
        case .splitPane: return "split pane"
        case .text: return "text"
        case .toggleButton: return "toggle button"
        case .toolBar: return "tool bar"
        case .tree: return "tree"
        case .unknown: return "unknown"
        case .window: return "window"
        case .application: return "application"
        case .entry: return "entry"
        case .heading: return "heading"
        case .link: return "link"
        case .treeItem: return "tree item"
        case .listBox: return "list box"
        case .grouping: return "grouping"
        case .pushButtonMenu: return "push button menu"
        }
    }
}

/// AT-SPI states (`GetState` bits).
public enum ATSPIState: UInt32, Sendable, CaseIterable {
    case invalid = 0, active, armed, busy, checked, collapsed, defunct, editable, enabled, expandable, expanded
    case focusable, focused, hasTooltip, horizontal, iconified, modal, multiLine, multiselectable, opaque, pressed
    case resizable, selectable, selected, sensitive, showing, singleLine, stale, transient, vertical, visible
    case managesDescendants, indeterminate, required, truncated, animated, invalidEntry, supportsAutocompletion
    case selectableText, isDefault, visited, checkable, hasPopup, readOnly

    /// The state's name in `object:state-changed:<name>` events
    /// (`multi-line`, `has-popup`, …).
    public var eventName: String {
        switch self {
        case .hasTooltip: return "has-tooltip"
        case .multiLine: return "multi-line"
        case .singleLine: return "single-line"
        case .managesDescendants: return "manages-descendants"
        case .invalidEntry: return "invalid-entry"
        case .supportsAutocompletion: return "supports-autocompletion"
        case .selectableText: return "selectable-text"
        case .isDefault: return "is-default"
        case .hasPopup: return "has-popup"
        case .readOnly: return "read-only"
        default: return "\(self)"
        }
    }
}

/// A set of states; on the wire two UINT32 words (bit n of word n / 32).
public struct ATSPIStateSet: Hashable, Sendable, CustomStringConvertible {
    public var bits: UInt64

    public init(_ states: [ATSPIState] = []) {
        bits = 0
        for s in states { insert(s) }
    }

    public func contains(_ s: ATSPIState) -> Bool { bits & (1 << UInt64(s.rawValue)) != 0 }
    public mutating func insert(_ s: ATSPIState) { bits |= 1 << UInt64(s.rawValue) }
    public mutating func remove(_ s: ATSPIState) { bits &= ~(1 << UInt64(s.rawValue)) }
    public mutating func set(_ s: ATSPIState, _ on: Bool) { if on { insert(s) } else { remove(s) } }

    public var states: [ATSPIState] { ATSPIState.allCases.filter(contains) }

    /// The `au` value.
    public var words: [UInt32] { [UInt32(truncatingIfNeeded: bits), UInt32(truncatingIfNeeded: bits >> 32)] }

    public init(words: [UInt32]) {
        bits = UInt64(words.first ?? 0) | UInt64(words.count > 1 ? words[1] : 0) << 32
    }

    public var description: String { states.map(\.eventName).joined(separator: ",") }
}

/// `Component` coordinate types.
public enum ATSPICoordType: UInt32, Sendable {
    case screen = 0, window = 1, parent = 2
}

/// `Component.GetLayer` values.
public enum ATSPILayer: UInt32, Sendable {
    case invalid = 0, background, canvas, widget, mdi, popup, overlay, window
}

/// `Text.GetStringAtOffset` granularities.
public enum ATSPITextGranularity: UInt32, Sendable {
    case character = 0, word, sentence, line, paragraph
}

/// `Text.GetTextAtOffset` boundary types.
public enum ATSPITextBoundary: UInt32, Sendable {
    case character = 0, wordStart, wordEnd, sentenceStart, sentenceEnd, lineStart, lineEnd
}

/// Interface, path and bus names of the protocol.
public enum ATSPI {
    public static let accessible = "org.a11y.atspi.Accessible"
    public static let application = "org.a11y.atspi.Application"
    public static let component = "org.a11y.atspi.Component"
    public static let action = "org.a11y.atspi.Action"
    public static let text = "org.a11y.atspi.Text"
    public static let editableText = "org.a11y.atspi.EditableText"
    public static let value = "org.a11y.atspi.Value"
    public static let selection = "org.a11y.atspi.Selection"
    public static let cache = "org.a11y.atspi.Cache"
    public static let socket = "org.a11y.atspi.Socket"
    public static let registryInterface = "org.a11y.atspi.Registry"
    public static let eventObject = "org.a11y.atspi.Event.Object"
    public static let eventWindow = "org.a11y.atspi.Event.Window"
    public static let eventFocus = "org.a11y.atspi.Event.Focus"

    /// The registry daemon's bus name, its root (the desktop) and its
    /// event-listener object.
    public static let registryName = "org.a11y.atspi.Registry"
    public static let registryRootPath = "/org/a11y/atspi/accessible/root"
    public static let registryPath = "/org/a11y/atspi/registry"

    /// The application's root object, the cache and the null reference.
    public static let rootPath = "/org/a11y/atspi/accessible/root"
    public static let cachePath = "/org/a11y/atspi/cache"
    public static let nullPath = "/org/a11y/atspi/null"
    /// Other objects live below this prefix.
    public static let objectPrefix = "/org/a11y/atspi/accessible/"

    /// The accessibility bus launcher on the session bus.
    public static let busLauncherName = "org.a11y.Bus"
    public static let busLauncherPath = "/org/a11y/bus"
}
