/// The guest task's Mach port name space (`stage3-contract.md` §8). There is
/// no IPC in stage 3: a name only records that it exists and what it is.
public struct MachPortTable: Equatable, Sendable {
    public enum Kind: Equatable, Sendable, CustomStringConvertible {
        case task, thread, host
        /// The bootstrap port (`host-libraries.md` §10); `mach_msg` to it
        /// fails until stage 4.
        case bootstrap
        /// A clock service port from `host_get_clock_service` (0 system, 1 calendar).
        case clock(id: Int32)
        /// A semaphore from `semaphore_create`, with its count.
        case semaphore(count: Int32)
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
            case .bootstrap: "bootstrap"
            case let .clock(id): "clock(\(id))"
            case let .semaphore(count): "semaphore(count \(count))"
            case let .allocated(right): "allocated(right \(right))"
            case .constructed: "constructed"
            case .reply: "reply"
            }
        }
    }

    public private(set) var names: [UInt32: Kind]
    private var nextName: UInt32

    public init() {
        names = [WellKnownPort.task: .task, WellKnownPort.thread: .thread, WellKnownPort.host: .host,
                 WellKnownPort.bootstrap: .bootstrap]
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

    /// Replaces the kind of an existing name (semaphore counts). Returns
    /// false when the name does not exist.
    @discardableResult
    public mutating func update(_ name: UInt32, to kind: Kind) -> Bool {
        guard names[name] != nil else { return false }
        names[name] = kind
        return true
    }

    /// Removes a dynamic name. The well-known names stay. Returns false when
    /// the name does not exist.
    @discardableResult
    public mutating func remove(_ name: UInt32) -> Bool {
        guard let kind = names[name] else { return false }
        switch kind {
        case .task, .thread, .host, .bootstrap: return true
        default:
            names[name] = nil
            return true
        }
    }
}
