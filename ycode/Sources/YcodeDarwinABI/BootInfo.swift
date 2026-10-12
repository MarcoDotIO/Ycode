/// Errors decoding the fixed-layout blocks shared with the guest.
public enum DarwinABIError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The buffer is shorter than the block.
    case truncated(what: String, expected: Int, actual: Int)
    /// The boot info magic does not match.
    case badMagic(UInt64)

    public var description: String {
        switch self {
        case let .truncated(what, expected, actual): "\(what) needs \(expected) bytes, got \(actual)"
        case let .badMagic(m): "bad boot info magic \(hex(m))"
        }
    }
}

/// The boot info block the VMM writes at `VMLayout.bootInfoGPA` and passes to
/// the shim in `x0`. All fields are little-endian u64.
/// See `specs/simulator/vm-shim-protocol.md` §4.
public struct BootInfo: Equatable, Sendable {
    /// ASCII "YCDBOOT1" read as a little-endian u64.
    public static let magic: UInt64 = 0x3154_4F4F_4244_4359
    /// The encoded size: 20 u64 fields.
    public static let byteCount = 160

    /// Byte offsets of the fields.
    public enum Offset {
        public static let magic = 0
        public static let ttbr0EL1 = 8
        public static let tcrEL1 = 16
        public static let mairEL1 = 24
        public static let sctlrEL1 = 32
        public static let el0EntryPC = 40
        public static let el0InitialSP = 48
        public static let trapFrameAddress = 56
        public static let doorbellAddress = 64
        public static let tpidrroEL0 = 72
        public static let tpidrEL0 = 80
        /// `x0`…`x7`, 8 × u64 (bytes 88–151).
        public static let el0Registers = 88
        public static let el1StackTop = 152
    }

    public var ttbr0EL1: UInt64
    public var tcrEL1: UInt64
    public var mairEL1: UInt64
    public var sctlrEL1: UInt64
    public var el0EntryPC: UInt64
    public var el0InitialSP: UInt64
    public var trapFrameAddress: UInt64
    public var doorbellAddress: UInt64
    public var tpidrroEL0: UInt64
    public var tpidrEL0: UInt64
    /// Initial EL0 `x0`…`x7`. Missing entries encode as 0; entries past the
    /// eighth are ignored.
    public var el0Registers: [UInt64]
    public var el1StackTop: UInt64

    public init(
        ttbr0EL1: UInt64,
        tcrEL1: UInt64 = VMLayout.tcrEL1,
        mairEL1: UInt64 = VMLayout.mairEL1,
        sctlrEL1: UInt64 = VMLayout.sctlrEL1,
        el0EntryPC: UInt64,
        el0InitialSP: UInt64 = VMLayout.el0StackTop,
        trapFrameAddress: UInt64 = VMLayout.trapFrameGPA,
        doorbellAddress: UInt64 = VMLayout.doorbellGPA,
        tpidrroEL0: UInt64 = 0,
        tpidrEL0: UInt64 = 0,
        el0Registers: [UInt64] = [],
        el1StackTop: UInt64 = VMLayout.el1StackTop
    ) {
        self.ttbr0EL1 = ttbr0EL1
        self.tcrEL1 = tcrEL1
        self.mairEL1 = mairEL1
        self.sctlrEL1 = sctlrEL1
        self.el0EntryPC = el0EntryPC
        self.el0InitialSP = el0InitialSP
        self.trapFrameAddress = trapFrameAddress
        self.doorbellAddress = doorbellAddress
        self.tpidrroEL0 = tpidrroEL0
        self.tpidrEL0 = tpidrEL0
        self.el0Registers = el0Registers
        self.el1StackTop = el1StackTop
    }

    /// Decodes a block, checking its size and magic.
    public init(decoding bytes: [UInt8]) throws {
        guard bytes.count >= Self.byteCount else {
            throw DarwinABIError.truncated(what: "boot info", expected: Self.byteCount, actual: bytes.count)
        }
        let magic = readLE(bytes, at: Offset.magic)
        guard magic == Self.magic else { throw DarwinABIError.badMagic(magic) }
        ttbr0EL1 = readLE(bytes, at: Offset.ttbr0EL1)
        tcrEL1 = readLE(bytes, at: Offset.tcrEL1)
        mairEL1 = readLE(bytes, at: Offset.mairEL1)
        sctlrEL1 = readLE(bytes, at: Offset.sctlrEL1)
        el0EntryPC = readLE(bytes, at: Offset.el0EntryPC)
        el0InitialSP = readLE(bytes, at: Offset.el0InitialSP)
        trapFrameAddress = readLE(bytes, at: Offset.trapFrameAddress)
        doorbellAddress = readLE(bytes, at: Offset.doorbellAddress)
        tpidrroEL0 = readLE(bytes, at: Offset.tpidrroEL0)
        tpidrEL0 = readLE(bytes, at: Offset.tpidrEL0)
        el0Registers = (0..<8).map { readLE(bytes, at: Offset.el0Registers + 8 * $0) }
        el1StackTop = readLE(bytes, at: Offset.el1StackTop)
    }

    /// The 160-byte little-endian block.
    public func encoded() -> [UInt8] {
        var b: [UInt8] = []
        b.reserveCapacity(Self.byteCount)
        for v in [Self.magic, ttbr0EL1, tcrEL1, mairEL1, sctlrEL1, el0EntryPC, el0InitialSP,
                  trapFrameAddress, doorbellAddress, tpidrroEL0, tpidrEL0] {
            appendLE(v, to: &b)
        }
        for i in 0..<8 { appendLE(i < el0Registers.count ? el0Registers[i] : 0, to: &b) }
        appendLE(el1StackTop, to: &b)
        return b
    }
}

// MARK: Little-endian helpers shared by the module

@inline(__always)
func appendLE(_ v: UInt64, to bytes: inout [UInt8]) {
    for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
}

/// Reads a little-endian u64. The caller has checked the bounds.
@inline(__always)
func readLE(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
    return v
}

/// `0x` followed by lowercase hex digits.
func hex<T: BinaryInteger>(_ v: T) -> String { "0x" + String(v, radix: 16) }
