/// The guest task's Mach port name space (`stage3-contract.md` §8). There is
/// no IPC in stage 3: a name only records that it exists and what it is.
public struct MachPortTable: Equatable, Sendable {
    public enum Kind: Equatable, Sendable, CustomStringConvertible {
        case task, thread, host
        /// From `mach_port_allocate` with the given right.
        case allocated(right: UInt32)
        /// From `mach_port_construct`.
        case constructed
        /// From `mach_reply_port`.
        case reply

        public var description: String {
            switch self {
            case .task: "task"
            case .thread: "thread"
            case .host: "host"
            case let .allocated(right): "allocated(right \(right))"
            case .constructed: "constructed"
            case .reply: "reply"
            }
        }
    }

    public private(set) var names: [UInt32: Kind]
    private var nextName: UInt32

    public init() {
        names = [WellKnownPort.task: .task, WellKnownPort.thread: .thread, WellKnownPort.host: .host]
        nextName = WellKnownPort.firstDynamic
    }

    public func kind(of name: UInt32) -> Kind? { names[name] }
    public func contains(_ name: UInt32) -> Bool { names[name] != nil }

    /// Creates a new name: `0x1003`, `0x1103`, `0x1203`, …
    public mutating func allocate(_ kind: Kind) -> UInt32 {
        let name = nextName
        nextName &+= WellKnownPort.dynamicStep
        names[name] = kind
        return name
    }

    /// Removes a dynamic name. The well-known names stay. Returns false when
    /// the name does not exist.
    @discardableResult
    public mutating func remove(_ name: UInt32) -> Bool {
        guard let kind = names[name] else { return false }
        switch kind {
        case .task, .thread, .host: return true
        default:
            names[name] = nil
            return true
        }
    }
}
