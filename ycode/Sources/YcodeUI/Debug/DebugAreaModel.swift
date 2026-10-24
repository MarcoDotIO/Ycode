import Foundation

/// The variables view scope pop-up (specs/ide/reference-ui-2.md §9.1).
public enum VariableScope: Int, CaseIterable, Sendable {
    case auto, local, all

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .local: "Local Variables"
        case .all: "All Variables, Registers, Globals and Statics"
        }
    }

    /// Registers (names starting with "$" or a "Registers" group) appear
    /// only in the third scope.
    public static func isRegister(_ name: String) -> Bool { name.hasPrefix("$") || name == "Registers" }

    public var showsRegisters: Bool { self == .all }

    public func includes(_ name: String) -> Bool { showsRegisters || !Self.isRegister(name) }

    /// Variables shown for this scope and filter text.
    public func filter(_ names: [String], text: String) -> [String] {
        let f = text.lowercased()
        return names.filter { includes($0) && (f.isEmpty || $0.lowercased().contains(f)) }
    }
}
