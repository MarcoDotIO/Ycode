// The hub window's sidebar (device-hub.md §5, "Ycode implementation"):
// devices in an "Available" and an "Unavailable" section, filtered by kind
// (All Devices / Simulators / Physical Devices), searched by name, sorted.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One device in the sidebar.
public struct HubDevice: Equatable, Sendable {
    public var id: String
    public var name: String
    /// "iOS", "visionOS", …
    public var platform: String
    public var osVersion: String
    public var family: DeviceFamily
    public var isSimulator: Bool
    /// The model name, shown for a physical device instead of "Simulator".
    public var model: String
    /// Running (a simulator) or connected (a device): the glyph is coloured.
    public var isRunning: Bool
    /// Listed under Available; else under Unavailable.
    public var isAvailable: Bool

    public init(id: String, name: String, platform: String, osVersion: String, family: DeviceFamily, isSimulator: Bool,
                model: String = "", isRunning: Bool, isAvailable: Bool = true) {
        self.id = id
        self.name = name
        self.platform = platform
        self.osVersion = osVersion
        self.family = family
        self.isSimulator = isSimulator
        self.model = model
        self.isRunning = isRunning
        self.isAvailable = isAvailable
    }

    /// The row's second line (§5.2): "Simulator", or the model for a device.
    public var subtitle: String { isSimulator ? "Simulator" : (model.isEmpty ? platform : model) }
    /// The row's trailing text: the OS version, major.minor.
    public var shortVersion: String { HubDevice.shortVersion(osVersion) }
    /// The window subtitle and status-view line: "iOS 27.1".
    public var osTitle: String { osVersion.isEmpty ? platform : "\(platform) \(osVersion)" }

    public static func shortVersion(_ v: String) -> String { v.split(separator: ".").prefix(2).joined(separator: ".") }

    /// The family from a platform and a device or model name (a fallback
    /// when the device type is not known).
    public static func family(platform: String, name: String) -> DeviceFamily {
        if platform == "visionOS" || platform == "xrOS" || name.contains("Vision") { return .vision }
        if name.contains("iPad") { return .pad }
        return .phone
    }
}

/// The Filter menu (§5.3).
public enum HubFilter: String, Sendable, CaseIterable {
    case all = "All Devices"
    case simulators = "Simulators"
    case physical = "Physical Devices"

    public func includes(_ d: HubDevice) -> Bool {
        switch self {
        case .all: true
        case .simulators: d.isSimulator
        case .physical: !d.isSimulator
        }
    }
}

/// Filter ▸ Sort By (Q10, Ycode decision: Name, the default, and OS Version).
public enum HubSort: String, Sendable, CaseIterable {
    case name = "Name"
    case osVersion = "OS Version"
}

/// A row of the sidebar list.
public enum HubSidebarRow: Equatable, Sendable {
    case header(String, collapsed: Bool)
    case device(HubDevice)

    public var device: HubDevice? { if case .device(let d) = self { d } else { nil } }
}

public struct HubSidebarModel: Equatable, Sendable {
    public static let available = "Available"
    public static let unavailable = "Unavailable"

    public var devices: [HubDevice]
    public var filter: HubFilter = .all
    public var sort: HubSort = .name
    public var search: String = ""
    /// Collapsed section titles (persisted).
    public var collapsed: Set<String> = []

    public init(devices: [HubDevice] = []) { self.devices = devices }

    /// The devices the filter and the search let through, sorted.
    public var visible: [HubDevice] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let shown = devices.filter { filter.includes($0) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
        return shown.sorted { a, b in
            switch sort {
            case .name:
                let c = a.name.localizedStandardCompare(b.name)
                if c != .orderedSame { return c == .orderedAscending }
                return a.osVersion.compare(b.osVersion, options: .numeric) == .orderedDescending
            case .osVersion:
                let c = a.osVersion.compare(b.osVersion, options: .numeric)
                if c != .orderedSame { return c == .orderedDescending }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// The list: a header per non-empty section, then its devices unless collapsed.
    public var rows: [HubSidebarRow] {
        var out: [HubSidebarRow] = []
        let v = visible
        for (title, list) in [(Self.available, v.filter(\.isAvailable)), (Self.unavailable, v.filter { !$0.isAvailable })] where !list.isEmpty {
            let isCollapsed = collapsed.contains(title)
            out.append(.header(title, collapsed: isCollapsed))
            if !isCollapsed { out += list.map { .device($0) } }
        }
        return out
    }

    /// The search found nothing (the sidebar shows the no-results message).
    public var showsNoResults: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty && visible.isEmpty }

    /// The no-results message (§5.1).
    public var noResultsTitle: String { "No Results for “\(search.trimmingCharacters(in: .whitespaces))”" }
    public static let noResultsMessage = "Check the spelling or try a new search."

    public mutating func toggle(section: String) {
        if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
    }

    /// The row index of a device (nil: not shown).
    public func rowIndex(of id: String) -> Int? { rows.firstIndex { $0.device?.id == id } }
}

/// What the canvas shows (§4.1).
public enum HubCanvasState: Equatable, Sendable {
    case noSelection
    case multipleSelection
    /// A simulator that is not running: its picture, name, OS and Start.
    case stopped(HubDevice)
    /// Starting (Q1, Ycode decision: the picture with a spinner and "Starting…").
    case starting(HubDevice)
    /// Running: the live screen (or a problem while the display connects).
    case running(HubDevice)

    public static func of(selection: [HubDevice], starting: Set<String>) -> HubCanvasState {
        guard let d = selection.first else { return .noSelection }
        if selection.count > 1 { return .multipleSelection }
        if starting.contains(d.id) { return .starting(d) }
        return d.isRunning ? .running(d) : .stopped(d)
    }

    public var message: String? {
        switch self {
        case .noSelection: "No Selection"
        case .multipleSelection: "Multiple Devices Selected"
        default: nil
        }
    }
}
