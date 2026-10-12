/// The `sysctl` names the guest may read (`stage3-contract.md` §8). Shared by
/// BSD 202 (`sysctl`, MIB form), BSD 274 (`sysctlbyname`), and the private
/// `sysctlbyname` trap.
public struct SysctlTable: Sendable {
    public enum Value: Equatable, Sendable {
        /// An integer. `size` is its natural size (4 or 8); a caller whose
        /// buffer is exactly 4 or 8 bytes gets that size instead.
        case integer(Int64, size: Int)
        /// A string, returned with its NUL.
        case string(String)
        /// The name exists but reading it fails with this errno.
        case error(Int32)

        /// The bytes returned for a buffer of `oldLength` bytes (nil = size query).
        func bytes(forBufferOf oldLength: UInt64?) -> [UInt8] {
            switch self {
            case let .integer(v, size):
                let n = oldLength == 4 || oldLength == 8 ? Int(oldLength!) : size
                var b: [UInt8] = []
                if n == 4 { b.appendLE(Int32(truncatingIfNeeded: v)) } else { b.appendLE(v) }
                return b
            case let .string(s):
                return cString(s)
            case .error:
                return []
            }
        }
    }

    public struct Entry: Equatable, Sendable {
        public var name: String
        /// The MIB the name translates to (`{0, 3}` name-to-OID query).
        public var mib: [Int32]
        public var value: Value
    }

    public var entries: [Entry]

    /// The contract's table.
    public static let standard = SysctlTable(entries: [
        Entry(name: "hw.optional.arm.caps", mib: [6, 1000], value: .integer(0, size: 8)),
        Entry(name: "kern.grade_cputype", mib: [1, 1000], value: .error(DarwinKernel.Errno.ENOENT)),
        Entry(name: "hw.pagesize", mib: [6, 7], value: .integer(16384, size: 8)),
        Entry(name: "hw.ncpu", mib: [6, 3], value: .integer(1, size: 4)),
        Entry(name: "hw.activecpu", mib: [6, 1001], value: .integer(1, size: 4)),
        Entry(name: "kern.osproductversion", mib: [1, 1001], value: .string("27.1")),
    ])

    public init(entries: [Entry]) { self.entries = entries }

    public func lookup(name: String) -> Entry? { entries.first { $0.name == name } }
    public func lookup(mib: [Int32]) -> Entry? { entries.first { $0.mib == mib } }
}
