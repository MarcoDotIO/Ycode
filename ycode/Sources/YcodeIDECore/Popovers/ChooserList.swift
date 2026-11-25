import Foundation
import YcodeBuild

/// One row of a chooser popover (`specs/ide/popovers.md` §2.3): a heading
/// in small secondary type, a choice (checked when it is the current one,
/// with a glyph and an OS version at the right), a command, a separator or
/// a disclosure row (Incompatible ›) that expands in place.
public struct ChooserRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading
        case choice
        case command
        case separator
        case disclosure(expanded: Bool)
    }

    public var kind: Kind
    public var title: String
    /// Right-aligned secondary text (a destination's OS version).
    public var trailing: String?
    public var isChecked: Bool
    public var isEnabled: Bool
    /// The glyph before the title: a symbol name both IDEs draw (on macOS
    /// the system's, on Linux OpenViews' own artwork); nil for none.
    public var symbol: String?
    /// What choosing the row means: a scheme's name, a destination's key
    /// or a command's identifier.
    public var key: String?

    public init(kind: Kind, title: String = "", trailing: String? = nil, isChecked: Bool = false, isEnabled: Bool = true,
                symbol: String? = nil, key: String? = nil) {
        self.kind = kind
        self.title = title
        self.trailing = trailing
        self.isChecked = isChecked
        self.isEnabled = isEnabled
        self.symbol = symbol
        self.key = key
    }

    public static let separator = ChooserRow(kind: .separator)
    public static func heading(_ title: String) -> ChooserRow { ChooserRow(kind: .heading, title: title) }

    public var height: Double { kind == .separator ? PopoverMetrics.separatorHeight : PopoverMetrics.rowHeight }

    /// Rows the highlight stops on: enabled choices, commands and
    /// disclosures.
    public var isSelectable: Bool {
        switch kind {
        case .heading, .separator: false
        case .choice, .command, .disclosure: isEnabled
        }
    }

    public var isDisclosure: Bool {
        if case .disclosure = kind { return true }
        return false
    }
}

/// A chooser's rows and its highlight (§2.3, §2.5): the current row is
/// highlighted on opening; Up and Down move the highlight over selectable
/// rows and stop at the ends; hover moves it.
public struct ChooserList: Equatable, Sendable {
    public var rows: [ChooserRow]
    public var highlighted: Int?

    /// The checked row is highlighted, else the first selectable choice
    /// (a destination or scheme), else a disclosure; never a command such as
    /// Ycode's own rows (`popovers.md` §2.7 item 2): with nothing else,
    /// nothing is highlighted until Up or Down.
    public init(rows: [ChooserRow]) {
        self.rows = rows
        highlighted = rows.firstIndex { $0.isChecked && $0.isSelectable }
            ?? rows.firstIndex { $0.kind == .choice && $0.isSelectable }
            ?? rows.firstIndex { $0.isDisclosure && $0.isSelectable }
    }

    public var rowsHeight: Double { rows.reduce(0) { $0 + $1.height } }
    public var bodyHeight: Double { PopoverMetrics.bodyHeight(rowsHeight: rowsHeight) }

    /// Moves the highlight `delta` selectable rows (Up -1, Down +1).
    public mutating func move(_ delta: Int) {
        let selectable = rows.indices.filter { rows[$0].isSelectable }
        guard !selectable.isEmpty else { highlighted = nil; return }
        guard let h = highlighted, let at = selectable.firstIndex(of: h) else {
            highlighted = delta >= 0 ? selectable.first : selectable.last
            return
        }
        highlighted = selectable[min(max(at + delta, 0), selectable.count - 1)]
    }

    /// The highlighted row.
    public var current: ChooserRow? { highlighted.flatMap { rows.indices.contains($0) ? rows[$0] : nil } }

    /// Row `i`'s frame in the body (y down), across the body's width.
    public func rowFrame(_ i: Int, bodyWidth: Double) -> CGRect {
        let y = PopoverMetrics.rowsTop + rows[..<i].reduce(0) { $0 + $1.height }
        return CGRect(x: 0, y: y, width: bodyWidth, height: rows[i].height)
    }

    /// The highlight's rectangle for row `i` (inset from the body's sides).
    public func highlightFrame(_ i: Int, bodyWidth: Double) -> CGRect {
        rowFrame(i, bodyWidth: bodyWidth).insetBy(dx: PopoverMetrics.highlightInset, dy: 0)
    }

    /// The row at `y` in the body, if any.
    public func row(atY y: Double) -> Int? {
        var top = PopoverMetrics.rowsTop
        for (i, r) in rows.enumerated() {
            if y >= top && y < top + r.height { return i }
            top += r.height
        }
        return nil
    }

    /// Hover: highlights a selectable row (others leave it).
    public mutating func hover(_ i: Int?) {
        guard let i, rows.indices.contains(i), rows[i].isSelectable else { return }
        highlighted = i
    }
}

/// Whether the pointer has moved since a chooser opened (§2.7): the
/// chooser opens with the current row highlighted *whatever row the pointer
/// is near*, so hover moves the highlight only once the pointer has moved.
/// The first place reported (or `origin`) is where it was at opening.
public struct ChooserPointerGate: Equatable, Sendable {
    public private(set) var origin: CGPoint?
    public private(set) var moved = false

    public init(origin: CGPoint? = nil) { self.origin = origin }

    /// Whether a hover at `p` may move the highlight.
    public mutating func admit(_ p: CGPoint) -> Bool {
        if moved { return true }
        guard let o = origin else { origin = p; return false }
        if abs(p.x - o.x) >= 1 || abs(p.y - o.y) >= 1 { moved = true }
        return moved
    }
}

/// The scheme chooser's rows (§2.3, P-111): the Filter field, one checked
/// row per scheme with its app icon, a separator, then Edit Scheme…, New
/// Scheme… and Manage Schemes….
public enum SchemeChooser {
    public enum Command: String, Sendable, CaseIterable {
        case edit, new, manage

        public var title: String {
            switch self {
            case .edit: "Edit Scheme…"
            case .new: "New Scheme…"
            case .manage: "Manage Schemes…"
            }
        }
    }

    /// The scheme rows' glyph: the app icon, drawn by each IDE.
    public static let schemeSymbol = "app"
    public static let commandPrefix = "command:"

    public static func list(schemes: [String], current: String?, filter: String = "", canEdit: Bool = true, canManage: Bool = true) -> ChooserList {
        let f = filter.trimmingCharacters(in: .whitespaces)
        var rows = schemes.filter { f.isEmpty || $0.localizedCaseInsensitiveContains(f) }.map {
            ChooserRow(kind: .choice, title: $0, isChecked: $0 == current, symbol: schemeSymbol, key: $0)
        }
        if !rows.isEmpty { rows.append(.separator) }
        for c in Command.allCases {
            rows.append(ChooserRow(kind: .command, title: c.title, isEnabled: c == .edit ? canEdit && current != nil : c == .manage ? canManage : true, key: commandPrefix + c.rawValue))
        }
        return ChooserList(rows: rows)
    }

    /// The command a row runs, if it is one.
    public static func command(_ row: ChooserRow) -> Command? {
        guard row.kind == .command, let k = row.key, k.hasPrefix(commandPrefix) else { return nil }
        return Command(rawValue: String(k.dropFirst(commandPrefix.count)))
    }
}

/// The destination chooser's rows (§2.3–§2.4, P-113): headings Recent,
/// Devices, Simulators and Build with their rows, each destination listed
/// once (the current one under Recent), the OS version right-aligned;
/// Incompatible as a disclosure row that lists its destinations in place;
/// Manage Devices… last. Ycode's own rows (setting up its simulator,
/// getting a runtime) go under the Simulators heading.
public enum DestinationChooser {
    public static let incompatibleKey = "incompatible"
    public static let manageDevicesKey = "command:manageDevices"
    public static let commandPrefix = "command:"

    /// The key that names one destination: its identifier, else its
    /// specifier (as the AppKit IDE's `menuKey`).
    public static func key(_ d: Destination) -> String { d.identifier ?? d.specifier }

    /// A row's title: "Any Mac" with its architectures (§2.3, P-014).
    public static func title(_ d: Destination) -> String {
        d.kind == .generic && d.platform == "macOS" && !d.name.contains("(") ? "\(d.name) (arm64, x86_64)" : d.name
    }

    /// The row's glyph, neutral shapes only (no product-shaped symbols, no
    /// hammer: AGENTS.md rule 5): this computer's laptop, a desktop for
    /// Any Mac, a dashed square for other build-only destinations, a plain
    /// phone, clock, screen or glasses for devices and simulators.
    public static func symbol(_ d: Destination) -> String {
        switch (d.kind, d.platform) {
        case (.mac, _): "laptopcomputer"
        case (.generic, "macOS"): "desktopcomputer"
        case (_, "watchOS"): "clock"
        case (_, "tvOS"): "tv"
        case (_, "visionOS"): "eyeglasses"
        case (.generic, _): "square.dashed"
        default: "candybarphone"
        }
    }

    /// - Parameters:
    ///   - sections: titled groups in order (Recent first when there is a
    ///     current destination).
    ///   - extras: Ycode's own command rows, listed under Simulators.
    public static func list(sections: [(title: String, destinations: [Destination])], incompatible: [Destination], current: Destination?,
                            expanded: Bool, extras: [ChooserRow] = [], manageDevicesEnabled: Bool = true) -> ChooserList {
        let currentKey = current.map(key)
        var rows: [ChooserRow] = []
        var extrasPlaced = extras.isEmpty
        func choice(_ d: Destination) -> ChooserRow {
            ChooserRow(kind: .choice, title: title(d), trailing: d.osVersion, isChecked: key(d) == currentKey, symbol: symbol(d), key: key(d))
        }
        let hasRecent = sections.contains { $0.title == "Recent" && !$0.destinations.isEmpty }
        for s in sections {
            // The current destination is listed once, under Recent (when
            // there is no Recent section, in its own section, checked).
            let ds = s.title == "Recent" || !hasRecent ? s.destinations : s.destinations.filter { key($0) != currentKey }
            if s.title == "Build" && !extrasPlaced {
                rows.append(.heading("Simulators"))
                rows += extras
                extrasPlaced = true
            }
            guard !ds.isEmpty || (s.title == "Simulators" && !extrasPlaced) else { continue }
            rows.append(.heading(s.title))
            rows += ds.map(choice)
            if s.title == "Simulators" && !extrasPlaced {
                rows += extras
                extrasPlaced = true
            }
        }
        if !extrasPlaced {
            rows.append(.heading("Simulators"))
            rows += extras
        }
        rows.append(.separator)
        rows.append(ChooserRow(kind: .disclosure(expanded: expanded && !incompatible.isEmpty), title: DestinationMenuModel.incompatibleTitle,
                               isEnabled: !incompatible.isEmpty, key: incompatibleKey))
        if expanded {
            rows += incompatible.map { d in
                ChooserRow(kind: .choice, title: title(d), trailing: d.osVersion, symbol: symbol(d), key: key(d))
            }
        }
        rows.append(.separator)
        rows.append(ChooserRow(kind: .command, title: DestinationMenuModel.manageDevicesTitle, isEnabled: manageDevicesEnabled, key: manageDevicesKey))
        return ChooserList(rows: rows)
    }

    /// The rows of a `DestinationMenuModel` (the AppKit IDE).
    public static func list(model: DestinationMenuModel, current: Destination?, expanded: Bool, extras: [ChooserRow] = []) -> ChooserList {
        list(sections: model.sections.map { ($0.title, $0.destinations) }, incompatible: model.incompatible, current: current,
             expanded: expanded, extras: extras)
    }

    /// The Linux IDE's groups as the same headings (§2.3): the current
    /// destination under Recent, this computer's group under Devices, the
    /// simulator hosts' groups under Simulators.
    public static func sections(groups: [DestinationGroup], current: Destination?, filter: String = "") -> [(title: String, destinations: [Destination])] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        func match(_ d: Destination) -> Bool { f.isEmpty || d.name.localizedCaseInsensitiveContains(f) }
        var out: [(title: String, destinations: [Destination])] = []
        if let current, match(current) { out.append(("Recent", [current])) }
        let devices = groups.first.map { $0.destinations.filter(match) } ?? []
        if !devices.isEmpty { out.append(("Devices", devices)) }
        let sims = groups.dropFirst().flatMap(\.destinations).filter(match)
        if !sims.isEmpty { out.append(("Simulators", sims)) }
        return out
    }

    /// Whether choosing `row` toggles the Incompatible disclosure.
    public static func isIncompatible(_ row: ChooserRow) -> Bool { row.key == incompatibleKey }
}

/// Product ▸ Destination's rows (`popovers.md` §9, P-014), both IDEs: the
/// Devices, Simulators and Build headings, each only when it has rows,
/// every row "<name> <OS version>"; the Incompatible cascade lists its
/// rows enabled.
public enum DestinationProductMenu {
    public static let headings = ["Devices", "Simulators", "Build"]

    /// "My Mac 27.2", "Any Mac (arm64, x86_64)".
    public static func title(_ d: Destination) -> String {
        let t = DestinationChooser.title(d)
        return d.osVersion.map { "\(t) \($0)" } ?? t
    }

    /// The headings with rows, in menu order.
    public static func sections(_ model: DestinationMenuModel) -> [(title: String, destinations: [Destination])] {
        headings.compactMap { h in
            let rows = model.rows(h)
            return rows.isEmpty ? nil : (h, rows)
        }
    }

    /// The Linux IDE's groups under the same headings (no Recent).
    public static func sections(groups: [DestinationGroup]) -> [(title: String, destinations: [Destination])] {
        DestinationChooser.sections(groups: groups, current: nil)
    }
}
