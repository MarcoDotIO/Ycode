// The arm64 register file the stub offers (`specs/simulator/debug-stub.md`
// §4): the user registers of a Darwin arm64 thread as `thread_get_state`
// names them (x0–x28, fp, lr, sp, pc, cpsr), then, when the target can read
// them, the FP/SIMD registers v0–v31, fpsr and fpcr. Numbers, names, sizes,
// DWARF numbers (the "DWARF for the Arm 64-bit Architecture" ABI document:
// x0–x30 = 0–30, sp = 31, pc = 32, v0–v31 = 64–95) and LLDB's generic roles
// come from public documents (level 1). The register numbers are Ycode's own
// order; LLDB learns them from `qRegisterInfo`.

/// One register of the layout.
public struct GDBRemoteRegister: Equatable, Sendable {
    public enum Format: String, Sendable { case hex, vector }
    public var number: Int
    public var name: String
    public var altName: String?
    /// Bytes.
    public var size: Int
    /// Byte offset in the `g` packet's register block.
    public var offset: Int
    public var set: String
    public var dwarf: Int?
    /// LLDB's generic role: pc, sp, fp, ra, flags, arg1…arg8.
    public var generic: String?
    public var format: Format { size == 16 ? .vector : .hex }

    /// The `qRegisterInfo` reply (LLDB's key-value form).
    public var infoReply: String {
        var s = "name:\(name);"
        if let altName { s += "alt-name:\(altName);" }
        s += "bitsize:\(size * 8);offset:\(offset);"
        s += size == 16 ? "encoding:vector;format:vector-uint8;" : "encoding:uint;format:hex;"
        s += "set:\(set);"
        if let dwarf { s += "ehframe:\(dwarf);dwarf:\(dwarf);" }
        if let generic { s += "generic:\(generic);" }
        return s
    }
}

/// The register layout and the conversion between a thread's registers and
/// the protocol's byte blocks.
public struct GDBRemoteARM64Layout: Equatable, Sendable {
    public let registers: [GDBRemoteRegister]
    /// The layout includes v0–v31, fpsr and fpcr.
    public let includesFloatingPoint: Bool

    public static let pc = 32, sp = 31, fp = 29, lr = 30, cpsr = 33
    public static let firstVector = 34, fpsr = 66, fpcr = 67

    public init(floatingPoint: Bool) {
        includesFloatingPoint = floatingPoint
        var regs: [GDBRemoteRegister] = []
        var offset = 0
        func add(_ name: String, _ size: Int, set: String, dwarf: Int?, generic: String? = nil, alt: String? = nil) {
            regs.append(GDBRemoteRegister(number: regs.count, name: name, altName: alt, size: size, offset: offset,
                                          set: set, dwarf: dwarf, generic: generic))
            offset += size
        }
        let gpr = "General Purpose Registers"
        for n in 0...28 { add("x\(n)", 8, set: gpr, dwarf: n, generic: n < 8 ? "arg\(n + 1)" : nil) }
        add("fp", 8, set: gpr, dwarf: 29, generic: "fp", alt: "x29")
        add("lr", 8, set: gpr, dwarf: 30, generic: "ra", alt: "x30")
        add("sp", 8, set: gpr, dwarf: 31, generic: "sp", alt: "x31")
        add("pc", 8, set: gpr, dwarf: 32, generic: "pc")
        add("cpsr", 4, set: gpr, dwarf: nil, generic: "flags")
        if floatingPoint {
            let fpu = "Floating Point Registers"
            for n in 0...31 { add("v\(n)", 16, set: fpu, dwarf: 64 + n) }
            add("fpsr", 4, set: fpu, dwarf: nil)
            add("fpcr", 4, set: fpu, dwarf: nil)
        }
        registers = regs
    }

    /// The `g` block's size in bytes.
    public var blockSize: Int { registers.last.map { $0.offset + $0.size } ?? 0 }

    /// The registers a stop reply carries (LLDB's "expedited" registers):
    /// fp, lr, sp, pc, cpsr.
    public static let expedited = [fp, lr, sp, pc, cpsr]

    public func register(_ n: Int) -> GDBRemoteRegister? { registers.indices.contains(n) ? registers[n] : nil }

    /// A register's value bytes from a thread's state.
    public func bytes(of n: Int, in state: GDBRemoteThreadRegisters) -> [UInt8]? {
        guard let r = register(n) else { return nil }
        func le(_ v: UInt64, _ size: Int) -> [UInt8] { (0..<size).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
        switch n {
        case 0...30: return le(state.x[n], 8)
        case Self.sp: return le(state.sp, 8)
        case Self.pc: return le(state.pc, 8)
        case Self.cpsr: return le(UInt64(state.cpsr), 4)
        case Self.firstVector..<(Self.firstVector + 32):
            guard let v = state.vector else { return [UInt8](repeating: 0, count: r.size) }
            return Array(v[(n - Self.firstVector) * 16..<(n - Self.firstVector + 1) * 16])
        case Self.fpsr: return le(UInt64(state.fpsr ?? 0), 4)
        case Self.fpcr: return le(UInt64(state.fpcr ?? 0), 4)
        default: return nil
        }
    }

    /// Stores a register's value bytes into a thread's state; false for an
    /// unknown register or a wrong size.
    public func set(_ n: Int, bytes: [UInt8], in state: inout GDBRemoteThreadRegisters) -> Bool {
        guard let r = register(n), bytes.count == r.size else { return false }
        let v = GDBRemoteHex.littleEndianValue(bytes)
        switch n {
        case 0...30: state.x[n] = v
        case Self.sp: state.sp = v
        case Self.pc: state.pc = v
        case Self.cpsr: state.cpsr = UInt32(truncatingIfNeeded: v)
        case Self.firstVector..<(Self.firstVector + 32):
            var vec = state.vector ?? [UInt8](repeating: 0, count: 512)
            vec.replaceSubrange((n - Self.firstVector) * 16..<(n - Self.firstVector + 1) * 16, with: bytes)
            state.vector = vec
        case Self.fpsr: state.fpsr = UInt32(truncatingIfNeeded: v)
        case Self.fpcr: state.fpcr = UInt32(truncatingIfNeeded: v)
        default: return false
        }
        return true
    }

    /// The `g` reply's block.
    public func block(of state: GDBRemoteThreadRegisters) -> [UInt8] {
        registers.flatMap { bytes(of: $0.number, in: state) ?? [] }
    }

    /// Reads a `G` block into a state; nil when the size is wrong.
    public func state(fromBlock block: [UInt8], base: GDBRemoteThreadRegisters) -> GDBRemoteThreadRegisters? {
        guard block.count == blockSize else { return nil }
        var s = base
        for r in registers { _ = set(r.number, bytes: Array(block[r.offset..<(r.offset + r.size)]), in: &s) }
        return s
    }
}

/// One thread's registers as the target reports them.
public struct GDBRemoteThreadRegisters: Equatable, Sendable {
    /// x0–x30 (x29 = fp, x30 = lr).
    public var x: [UInt64]
    public var sp: UInt64
    public var pc: UInt64
    /// PSTATE's NZCV and mode bits as `thread_get_state` reports them.
    public var cpsr: UInt32
    /// v0–v31, 16 bytes each, little-endian (nil: not available).
    public var vector: [UInt8]?
    public var fpsr: UInt32?
    public var fpcr: UInt32?

    public init(x: [UInt64] = Array(repeating: 0, count: 31), sp: UInt64 = 0, pc: UInt64 = 0, cpsr: UInt32 = 0,
                vector: [UInt8]? = nil, fpsr: UInt32? = nil, fpcr: UInt32? = nil) {
        precondition(x.count == 31)
        self.x = x
        self.sp = sp
        self.pc = pc
        self.cpsr = cpsr
        self.vector = vector
        self.fpsr = fpsr
        self.fpcr = fpcr
    }
}
