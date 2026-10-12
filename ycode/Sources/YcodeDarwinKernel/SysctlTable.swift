import Foundation

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
        /// A structure, returned as these bytes.
        case bytes([UInt8])

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
            case let .bytes(b):
                return b
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
        // Stage 3b: names libc and the host libraries read at start-up. The
        // fixed MIB numbers are the public `sys/sysctl.h` ones; names that the
        // kernel registers with OID_AUTO get Ycode numbers ≥ 1000.
        Entry(name: "kern.ostype", mib: [1, 1], value: .string("Darwin")),
        Entry(name: "kern.osrelease", mib: [1, 2], value: .string("26.1.0")),
        Entry(name: "kern.osrevision", mib: [1, 3], value: .integer(199506, size: 4)),
        Entry(name: "kern.version", mib: [1, 4], value: .string("Darwin Kernel Version 26.1.0: Ycode micro-VM; root:ycode/RELEASE_ARM64")),
        Entry(name: "kern.maxproc", mib: [1, 6], value: .integer(2000, size: 4)),
        Entry(name: "kern.maxfiles", mib: [1, 7], value: .integer(12288, size: 4)),
        Entry(name: "kern.argmax", mib: [1, 8], value: .integer(1 << 20, size: 4)),
        Entry(name: "kern.securelevel", mib: [1, 9], value: .integer(0, size: 4)),
        Entry(name: "kern.hostname", mib: [1, 10], value: .string("ycode-sim")),
        Entry(name: "kern.boottime", mib: [1, 21], value: .bytes(SysctlTable.bootTime())),
        Entry(name: "kern.maxfilesperproc", mib: [1, 29], value: .integer(256, size: 4)),
        Entry(name: "kern.usrstack64", mib: [1, 59], value: .integer(Int64(Stage3Layout.userStack), size: 8)),
        Entry(name: "kern.osversion", mib: [1, 65], value: .string("24A94401")),
        Entry(name: "kern.secure_kernel", mib: [1, 1002], value: .integer(0, size: 4)),
        Entry(name: "kern.hv_vmm_present", mib: [1, 1003], value: .integer(0, size: 4)),
        Entry(name: "kern.osvariant_status", mib: [1, 1004], value: .integer(0, size: 8)),
        Entry(name: "hw.machine", mib: [6, 1], value: .string("arm64")),
        Entry(name: "hw.model", mib: [6, 2], value: .string("YcodeVM1,1")),
        Entry(name: "hw.byteorder", mib: [6, 4], value: .integer(1234, size: 4)),
        Entry(name: "hw.physmem", mib: [6, 5], value: .integer(Int64(Stage3Layout.memorySize), size: 4)),
        Entry(name: "hw.usermem", mib: [6, 6], value: .integer(Int64(Stage3Layout.memorySize) / 2, size: 4)),
        Entry(name: "hw.cachelinesize", mib: [6, 16], value: .integer(64, size: 8)),
        Entry(name: "hw.l1icachesize", mib: [6, 17], value: .integer(128 << 10, size: 8)),
        Entry(name: "hw.l1dcachesize", mib: [6, 18], value: .integer(64 << 10, size: 8)),
        Entry(name: "hw.l2cachesize", mib: [6, 20], value: .integer(4 << 20, size: 8)),
        Entry(name: "hw.tbfrequency", mib: [6, 23], value: .integer(1_000_000_000, size: 8)),
        Entry(name: "hw.memsize", mib: [6, 24], value: .integer(Int64(Stage3Layout.memorySize), size: 8)),
        Entry(name: "hw.availcpu", mib: [6, 25], value: .integer(1, size: 4)),
        Entry(name: "hw.cputype", mib: [6, 1002], value: .integer(0x0100_000C, size: 4)),
        Entry(name: "hw.cpusubtype", mib: [6, 1003], value: .integer(0, size: 4)),
        Entry(name: "hw.cpu64bit_capable", mib: [6, 1004], value: .integer(1, size: 4)),
        Entry(name: "hw.logicalcpu", mib: [6, 1005], value: .integer(1, size: 4)),
        Entry(name: "hw.logicalcpu_max", mib: [6, 1006], value: .integer(1, size: 4)),
        Entry(name: "hw.physicalcpu", mib: [6, 1007], value: .integer(1, size: 4)),
        Entry(name: "hw.physicalcpu_max", mib: [6, 1008], value: .integer(1, size: 4)),
        Entry(name: "hw.cpufamily", mib: [6, 1009], value: .integer(0, size: 4)),
        Entry(name: "hw.nperflevels", mib: [6, 1010], value: .integer(1, size: 4)),
        Entry(name: "hw.memsize_usable", mib: [6, 1011], value: .integer(Int64(Stage3Layout.memorySize), size: 8)),
        Entry(name: "vm.pagesize", mib: [2, 1000], value: .integer(16384, size: 4)),
    ])

    /// `struct timeval` of the host's boot time, approximated as the VMM's start.
    static func bootTime() -> [UInt8] {
        let t = Date().timeIntervalSince1970
        var b: [UInt8] = []
        b.appendLE(Int64(t))
        b.appendLE(Int32((t - t.rounded(.down)) * 1e6))
        b.appendLE(Int32(0))
        return b
    }

    /// MIB numbers for `hw.optional.*` names that are not in the table.
    static let optionalMIBBase: Int32 = 0x4000


    public init(entries: [Entry]) { self.entries = entries }

    /// Every `hw.optional.*` name that is not in the table reads as 0 (the
    /// feature is absent).
    public func lookup(name: String) -> Entry? {
        if let e = entries.first(where: { $0.name == name }) { return e }
        if name.hasPrefix("hw.optional.") {
            var h: UInt32 = 2166136261
            for b in name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
            return Entry(name: name, mib: [6, Self.optionalMIBBase + Int32(h & 0x3FFF)], value: .integer(0, size: 4))
        }
        return nil
    }

    public func lookup(mib: [Int32]) -> Entry? {
        if let e = entries.first(where: { $0.mib == mib }) { return e }
        if mib.count == 2, mib[0] == 6, mib[1] >= Self.optionalMIBBase, mib[1] < Self.optionalMIBBase + 0x4000 {
            return Entry(name: "hw.optional.(\(mib[1]))", mib: mib, value: .integer(0, size: 4))
        }
        return nil
    }
}
