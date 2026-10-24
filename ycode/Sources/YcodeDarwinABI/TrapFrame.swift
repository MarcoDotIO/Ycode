/// The register frame the shim saves on every exception and the VMM reads and
/// edits while the vCPU is stopped. 320 bytes of little-endian u64.
/// See `specs/simulator/vm-shim-protocol.md` §5.
public struct TrapFrame: Equatable, Sendable, CustomStringConvertible {
    public static let byteCount = 320
    public static let registerCount = 31

    /// Byte offsets of the fields.
    public enum Offset {
        /// `x0`…`x30` (bytes 0–247); `xN` is at `8 × N`.
        public static let x0 = 0
        public static let spEL0 = 248
        public static let elr = 256
        public static let spsr = 264
        public static let esr = 272
        public static let far = 280
        public static let tpidrro = 288
        public static let tpidr = 296
        public static let kind = 304
        /// `resumeFlags` (stage 3, `stage3-contract.md` §7). Formerly reserved.
        public static let resumeFlags = 312
        /// The stage-2 name of the word at +312.
        public static let reserved = resumeFlags
    }

    /// Bits of `resumeFlags`.
    public enum ResumeFlag {
        /// Bit 0: the shim runs `tlbi vmalle1; dsb ish; isb` before the
        /// `eret`, then clears the bit.
        public static let flushTLB: UInt64 = 1 << 0
    }

    /// The `kind` field.
    public enum Kind: UInt64, Sendable, CustomStringConvertible {
        /// SVC from EL0 (EC `0x15`).
        case svc = 1
        /// Any other synchronous exception from EL0.
        case el0Synchronous = 2
        /// IRQ, FIQ, or SError.
        case asynchronous = 3
        /// A synchronous exception taken at EL1 (a shim bug).
        case el1Synchronous = 4

        public var description: String {
            switch self {
            case .svc: "SVC from EL0"
            case .el0Synchronous: "synchronous exception from EL0"
            case .asynchronous: "IRQ/FIQ/SError"
            case .el1Synchronous: "synchronous exception at EL1"
            }
        }
    }

    /// `x0`…`x30`: 31 entries.
    public var x: [UInt64]
    public var spEL0: UInt64
    /// For SVC this is already the address after the `svc`.
    public var elr: UInt64
    public var spsr: UInt64
    public var esr: UInt64
    public var far: UInt64
    /// Written back to `TPIDRRO_EL0` on resume.
    public var tpidrro: UInt64
    /// Written back to `TPIDR_EL0` on resume.
    public var tpidr: UInt64
    public var kind: UInt64
    /// Requests from the VMM to the shim for the next resume (+312). The VMM
    /// sets this before writing the frame back. Decoding always yields 0:
    /// the shim clears the word on resume, so a value read from a stopped
    /// vCPU carries no meaning.
    public var resumeFlags: UInt64 = 0

    public init(
        x: [UInt64] = Array(repeating: 0, count: TrapFrame.registerCount),
        spEL0: UInt64 = 0, elr: UInt64 = 0, spsr: UInt64 = 0, esr: UInt64 = 0, far: UInt64 = 0,
        tpidrro: UInt64 = 0, tpidr: UInt64 = 0, kind: UInt64 = 0
    ) {
        self.x = x
        self.spEL0 = spEL0
        self.elr = elr
        self.spsr = spsr
        self.esr = esr
        self.far = far
        self.tpidrro = tpidrro
        self.tpidr = tpidr
        self.kind = kind
    }

    /// Decodes the first 320 bytes of `bytes`. `resumeFlags` is not decoded
    /// (it is 0 in the result).
    public init(decoding bytes: [UInt8]) throws {
        guard bytes.count >= Self.byteCount else {
            throw DarwinABIError.truncated(what: "trap frame", expected: Self.byteCount, actual: bytes.count)
        }
        x = (0..<Self.registerCount).map { readLE(bytes, at: Offset.x0 + 8 * $0) }
        spEL0 = readLE(bytes, at: Offset.spEL0)
        elr = readLE(bytes, at: Offset.elr)
        spsr = readLE(bytes, at: Offset.spsr)
        esr = readLE(bytes, at: Offset.esr)
        far = readLE(bytes, at: Offset.far)
        tpidrro = readLE(bytes, at: Offset.tpidrro)
        tpidr = readLE(bytes, at: Offset.tpidr)
        kind = readLE(bytes, at: Offset.kind)
    }

    /// Decodes the 320 bytes at `p` (guest memory the caller owns for the
    /// call): as `init(decoding:)` without the intermediate byte array.
    public init(decodingFrameAt p: UnsafeRawPointer) {
        @inline(__always) func word(_ offset: Int) -> UInt64 { UInt64(littleEndian: p.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        x = [UInt64](unsafeUninitializedCapacity: Self.registerCount) { buffer, count in
            for i in 0..<Self.registerCount { buffer[i] = word(Offset.x0 + 8 * i) }
            count = Self.registerCount
        }
        spEL0 = word(Offset.spEL0)
        elr = word(Offset.elr)
        spsr = word(Offset.spsr)
        esr = word(Offset.esr)
        far = word(Offset.far)
        tpidrro = word(Offset.tpidrro)
        tpidr = word(Offset.tpidr)
        kind = word(Offset.kind)
    }

    /// Writes the 320-byte frame to `p`: the same bytes as `encoded()`.
    public func encode(into p: UnsafeMutableRawPointer) {
        @inline(__always) func put(_ v: UInt64, _ offset: Int) { p.storeBytes(of: v.littleEndian, toByteOffset: offset, as: UInt64.self) }
        let n = min(x.count, Self.registerCount)
        x.withUnsafeBufferPointer { b in for i in 0..<n { put(b[i], Offset.x0 + 8 * i) } }
        for i in n..<Self.registerCount { put(0, Offset.x0 + 8 * i) }
        put(spEL0, Offset.spEL0)
        put(elr, Offset.elr)
        put(spsr, Offset.spsr)
        put(esr, Offset.esr)
        put(far, Offset.far)
        put(tpidrro, Offset.tpidrro)
        put(tpidr, Offset.tpidr)
        put(kind, Offset.kind)
        put(resumeFlags, Offset.resumeFlags)
    }

    /// The 320-byte frame. Missing `x` entries encode as 0 and extra ones are
    /// ignored. The word at +312 is `resumeFlags` (0 unless the VMM set it).
    public func encoded() -> [UInt8] {
        var b: [UInt8] = []
        b.reserveCapacity(Self.byteCount)
        for i in 0..<Self.registerCount { appendLE(i < x.count ? x[i] : 0, to: &b) }
        for v in [spEL0, elr, spsr, esr, far, tpidrro, tpidr, kind, resumeFlags] { appendLE(v, to: &b) }
        return b
    }

    /// PSTATE.C as saved in `SPSR_EL1` (bit 29). Darwin BSD calls set it on error.
    public var carry: Bool {
        get { spsr & AArch64.SPSR.c != 0 }
        set { spsr = newValue ? spsr | AArch64.SPSR.c : spsr & ~AArch64.SPSR.c }
    }

    /// `resumeFlags` bit 0: flush the TLB before resuming.
    public var flushTLB: Bool {
        get { resumeFlags & ResumeFlag.flushTLB != 0 }
        set { resumeFlags = newValue ? resumeFlags | ResumeFlag.flushTLB : resumeFlags & ~ResumeFlag.flushTLB }
    }

    public var trapKind: Kind? { Kind(rawValue: kind) }
    public var syndrome: ExceptionSyndrome { ExceptionSyndrome(esr) }

    /// One summary line (kind, decoded ESR, FAR, ELR) and a register dump.
    public var description: String {
        let kindText = trapKind.map(\.description) ?? "unknown kind \(kind)"
        var lines = ["\(kindText): \(syndrome) FAR=\(hex16(far)) ELR=\(hex16(elr))"]
        for row in stride(from: 0, to: Self.registerCount, by: 4) {
            lines.append((row..<min(row + 4, Self.registerCount)).map { i in
                let name = i < 10 ? " x\(i)" : "x\(i)"
                return "\(name)=\(hex16(i < x.count ? x[i] : 0))"
            }.joined(separator: " "))
        }
        lines.append(" sp=\(hex16(spEL0)) spsr=\(hex16(spsr)) tpidrro=\(hex16(tpidrro)) tpidr=\(hex16(tpidr))")
        return lines.joined(separator: "\n")
    }
}

/// A 16-digit zero-padded hex value.
func hex16(_ v: UInt64) -> String {
    let s = String(v, radix: 16)
    return "0x" + String(repeating: "0", count: max(0, 16 - s.count)) + s
}

/// Exception classes (ESR_ELx.EC) the micro-VM is likely to meet.
public enum ExceptionClass: UInt8, Sendable, CaseIterable, CustomStringConvertible {
    case unknown = 0x00
    case trappedWFIorWFE = 0x01
    case trappedSIMDorFP = 0x07
    case pointerAuthenticationTrap = 0x09
    case branchTarget = 0x0D
    case illegalExecutionState = 0x0E
    case svc = 0x15
    case hvc = 0x16
    case smc = 0x17
    case trappedSystemRegister = 0x18
    case trappedSVE = 0x19
    case pointerAuthenticationFailure = 0x1C
    case instructionAbortLowerEL = 0x20
    case instructionAbortSameEL = 0x21
    case pcAlignment = 0x22
    case dataAbortLowerEL = 0x24
    case dataAbortSameEL = 0x25
    case spAlignment = 0x26
    case floatingPoint = 0x2C
    case serror = 0x2F
    case breakpointLowerEL = 0x30
    case breakpointSameEL = 0x31
    case softwareStepLowerEL = 0x32
    case softwareStepSameEL = 0x33
    case watchpointLowerEL = 0x34
    case watchpointSameEL = 0x35
    case brk = 0x3C

    public var description: String {
        switch self {
        case .unknown: "unknown reason"
        case .trappedWFIorWFE: "trapped WFI/WFE"
        case .trappedSIMDorFP: "trapped SIMD/FP access"
        case .pointerAuthenticationTrap: "trapped pointer authentication instruction"
        case .branchTarget: "branch target exception"
        case .illegalExecutionState: "illegal execution state"
        case .svc: "SVC (AArch64)"
        case .hvc: "HVC (AArch64)"
        case .smc: "SMC (AArch64)"
        case .trappedSystemRegister: "trapped MSR/MRS/system instruction"
        case .trappedSVE: "trapped SVE access"
        case .pointerAuthenticationFailure: "pointer authentication failure"
        case .instructionAbortLowerEL: "instruction abort from a lower EL"
        case .instructionAbortSameEL: "instruction abort at the same EL"
        case .pcAlignment: "PC alignment fault"
        case .dataAbortLowerEL: "data abort from a lower EL"
        case .dataAbortSameEL: "data abort at the same EL"
        case .spAlignment: "SP alignment fault"
        case .floatingPoint: "floating-point exception (AArch64)"
        case .serror: "SError"
        case .breakpointLowerEL: "breakpoint from a lower EL"
        case .breakpointSameEL: "breakpoint at the same EL"
        case .softwareStepLowerEL: "software step from a lower EL"
        case .softwareStepSameEL: "software step at the same EL"
        case .watchpointLowerEL: "watchpoint from a lower EL"
        case .watchpointSameEL: "watchpoint at the same EL"
        case .brk: "BRK (AArch64)"
        }
    }

    public var isAbort: Bool {
        switch self {
        case .instructionAbortLowerEL, .instructionAbortSameEL, .dataAbortLowerEL, .dataAbortSameEL: true
        default: false
        }
    }

    public var isDataAbort: Bool { self == .dataAbortLowerEL || self == .dataAbortSameEL }
}

/// A decoded `ESR_EL1` value: EC (bits 31:26), IL (bit 25), ISS (bits 24:0).
public struct ExceptionSyndrome: Equatable, Sendable, CustomStringConvertible {
    public var raw: UInt64

    public init(_ raw: UInt64) { self.raw = raw }

    /// Builds a syndrome from its fields.
    public init(ec: UInt8, il: Bool = true, iss: UInt32 = 0) {
        raw = UInt64(ec & 0x3F) << 26 | (il ? 1 << 25 : 0) | UInt64(iss & 0x1FF_FFFF)
    }

    /// Exception class, bits [31:26].
    public var ec: UInt8 { UInt8((raw >> 26) & 0x3F) }
    /// Instruction length, bit [25]: true for a 32-bit instruction.
    public var il: Bool { raw & (1 << 25) != 0 }
    /// Instruction-specific syndrome, bits [24:0].
    public var iss: UInt32 { UInt32(raw & 0x1FF_FFFF) }
    /// ISS2, bits [55:32] (zero before FEAT_LS64 and later extensions).
    public var iss2: UInt32 { UInt32((raw >> 32) & 0xFF_FFFF) }

    public var exceptionClass: ExceptionClass? { ExceptionClass(rawValue: ec) }

    /// The `imm16` of an SVC.
    public var svcImmediate: UInt16? { exceptionClass == .svc ? UInt16(iss & 0xFFFF) : nil }

    /// IFSC/DFSC, ISS bits [5:0], for instruction and data aborts.
    public var faultStatusCode: UInt8? { exceptionClass?.isAbort == true ? UInt8(iss & 0x3F) : nil }

    /// WnR, ISS bit 6, for data aborts: true when the access was a write.
    public var isWrite: Bool? { exceptionClass?.isDataAbort == true ? iss & (1 << 6) != 0 : nil }

    /// A name for an IFSC/DFSC value.
    public static func faultStatusName(_ fsc: UInt8) -> String {
        let level = fsc & 3
        switch fsc {
        case 0x00...0x03: return "address size fault, level \(level)"
        case 0x04...0x07: return "translation fault, level \(level)"
        case 0x08...0x0B: return "access flag fault, level \(level)"
        case 0x0C...0x0F: return "permission fault, level \(level)"
        case 0x10: return "synchronous external abort"
        case 0x21: return "alignment fault"
        case 0x30: return "TLB conflict abort"
        default: return "fault status \(hex(fsc))"
        }
    }

    public var description: String {
        let name = exceptionClass?.description ?? "unrecognized"
        var s = "EC=\(hex(ec)) (\(name)) IL=\(il ? 1 : 0) ISS=\(hex(iss))"
        if let fsc = faultStatusCode {
            s += " [\(Self.faultStatusName(fsc))"
            if let w = isWrite { s += w ? ", write" : ", read" }
            s += "]"
        }
        if let imm = svcImmediate { s += " [svc #\(hex(imm))]" }
        return s
    }
}
