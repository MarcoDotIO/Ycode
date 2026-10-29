import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Guest virtual memory as seen through the stage-1 tables. Implemented by
/// the hypervisor; `TranslatingGuestMemory` is a ready-made implementation.
public protocol GuestMemoryAccess {
    /// Reads `count` bytes at `va`; throws `GuestMemoryError` when a page is
    /// unmapped or not readable from EL0.
    func read(va: UInt64, count: Int) throws -> [UInt8]
    /// Writes `bytes` at `va`; throws `GuestMemoryError` when a page is
    /// unmapped or not writable from EL0.
    func write(va: UInt64, bytes: [UInt8]) throws
}

/// Why a guest virtual memory access failed.
public enum GuestMemoryError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No valid translation for `va`.
    case unmapped(va: UInt64)
    /// The page at `va` is mapped but EL0 may not access it this way.
    case accessDenied(va: UInt64)
    /// The range wraps around the address space or has a negative length.
    case badRange(va: UInt64, count: Int)

    public var description: String {
        switch self {
        case let .unmapped(va): "guest va \(hex(va)) is not mapped"
        case let .accessDenied(va): "guest va \(hex(va)) is not accessible from EL0"
        case let .badRange(va, count): "bad guest range \(hex(va)) + \(count)"
        }
    }
}

/// Guest memory reached by translating each VA through a `PageTableBuilder`
/// and then accessing guest physical memory with the supplied closures. A
/// range may cross pages; each page is translated separately.
public struct TranslatingGuestMemory: GuestMemoryAccess {
    public var pageTables: PageTableBuilder
    /// When true (the default), reads need an EL0-readable page and writes an
    /// EL0-writable one, as a kernel checks user buffers.
    public var requireEL0Access: Bool
    public var readPhysical: (_ pa: UInt64, _ count: Int) throws -> [UInt8]
    public var writePhysical: (_ pa: UInt64, _ bytes: ArraySlice<UInt8>) throws -> Void

    public init(
        pageTables: PageTableBuilder,
        requireEL0Access: Bool = true,
        readPhysical: @escaping (_ pa: UInt64, _ count: Int) throws -> [UInt8],
        writePhysical: @escaping (_ pa: UInt64, _ bytes: ArraySlice<UInt8>) throws -> Void
    ) {
        self.pageTables = pageTables
        self.requireEL0Access = requireEL0Access
        self.readPhysical = readPhysical
        self.writePhysical = writePhysical
    }

    /// Splits [va, va+count) into physically contiguous pieces, one per page.
    public func physicalPieces(va: UInt64, count: Int, write: Bool) throws -> [(pa: UInt64, count: Int)] {
        guard count >= 0, UInt64(count) <= UInt64.max - va else { throw GuestMemoryError.badRange(va: va, count: count) }
        var pieces: [(pa: UInt64, count: Int)] = []
        // TCR_EL1.TBI0: the top byte of a guest data address is ignored.
        var cursor = va & VMLayout.addressWithoutTag
        var remaining = UInt64(count)
        while remaining > 0 {
            guard let (pa, attributes) = pageTables.translate(cursor) else { throw GuestMemoryError.unmapped(va: cursor) }
            if requireEL0Access {
                let ok = write ? attributes.access.isEL0Writable : attributes.access.isEL0Readable
                guard ok else { throw GuestMemoryError.accessDenied(va: cursor) }
            }
            let inPage = VMLayout.pageSize - (cursor & (VMLayout.pageSize - 1))
            let n = min(inPage, remaining)
            pieces.append((pa, Int(n)))
            cursor += n
            remaining -= n
        }
        return pieces
    }

    public func read(va: UInt64, count: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(max(0, count))
        for piece in try physicalPieces(va: va, count: count, write: false) {
            out += try readPhysical(piece.pa, piece.count)
        }
        return out
    }

    public func write(va: UInt64, bytes: [UInt8]) throws {
        var offset = 0
        for piece in try physicalPieces(va: va, count: bytes.count, write: true) {
            try writePhysical(piece.pa, bytes[offset..<(offset + piece.count)])
            offset += piece.count
        }
    }
}

/// What the VMM does after a trap.
public enum TrapOutcome: Equatable, Sendable {
    /// Re-enter the vCPU (`KVM_RUN`) with the edited frame.
    case resume
    /// Stop the guest; the VMM exits with `status`.
    case exit(status: Int32)
    /// Stop the guest and print the message; the VMM exits with
    /// `VMLayout.fatalExitStatus` (70).
    case fatal(String)
}

/// The Darwin trap number in `x16`, classified as in
/// `specs/simulator/darwin-arm64-abi.md` §1.
public enum DarwinTrapNumber: Equatable, Sendable, CustomStringConvertible {
    /// `0x80000000`: a machine-dependent platform call.
    case platform
    /// A Mach trap −N (including the time fast traps −3 and −4); the payload is negative.
    case mach(Int32)
    /// A BSD system call N (zero or positive).
    case bsd(Int32)

    /// Interprets the low 32 bits of `x16` as a signed trap number.
    public init(x16: UInt64) {
        let n = Int32(truncatingIfNeeded: x16)
        if n == Int32.min {
            self = .platform
        } else if n < 0 {
            self = .mach(n)
        } else {
            self = .bsd(n)
        }
    }

    public var description: String {
        switch self {
        case .platform: "platform 0x80000000"
        case let .mach(n): "mach \(n)"
        case let .bsd(n): "bsd \(n)"
        }
    }
}

/// Darwin errno values used by the stage-2 calls (xnu `bsd/sys/errno.h`;
/// `vm-shim-protocol.md` §6). A failed call returns one in x0 with carry set.
public enum DarwinErrno {
    public static let EFAULT: UInt64 = 14
    public static let EBADF: UInt64 = 9
    public static let EINVAL: UInt64 = 22
    public static let ENOSYS: UInt64 = 78

    static func name(_ e: UInt64) -> String {
        switch e {
        case EBADF: "EBADF"
        case EFAULT: "EFAULT"
        case EINVAL: "EINVAL"
        case ENOSYS: "ENOSYS"
        default: "errno"
        }
    }
}

/// The guest timebase: `mach_absolute_time` counts at 24 MHz, and
/// `mach_timebase_info` reports numer/denom = 125/3 (ticks × 125 / 3 = ns).
public enum MachTimebase {
    public static let frequency: UInt64 = 24_000_000
    public static let numer: UInt32 = 125
    public static let denom: UInt32 = 3

    /// Converts nanoseconds to 24 MHz ticks without intermediate overflow.
    public static func ticks(fromNanoseconds ns: UInt64) -> UInt64 {
        let n = UInt64(numer), d = UInt64(denom)
        return (ns / n) * d + (ns % n) * d / n
    }

    /// Converts 24 MHz ticks to nanoseconds without intermediate overflow.
    public static func nanoseconds(fromTicks t: UInt64) -> UInt64 {
        let n = UInt64(numer), d = UInt64(denom)
        return (t / d) * n + (t % d) * n / d
    }

    /// Nanoseconds from the host's monotonic clock (uptime on macOS,
    /// `CLOCK_MONOTONIC` on Linux).
    public static func hostMonotonicNanoseconds() -> UInt64 {
        #if canImport(Darwin)
        return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        #else
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
        #endif
    }

    /// The current guest `mach_absolute_time`: monotonic, never zero.
    public static func now() -> UInt64 {
        max(1, ticks(fromNanoseconds: hostMonotonicNanoseconds()))
    }
}

/// Handles SVC traps from EL0 the way the Darwin kernel would, for the
/// stage-2 subset of `specs/simulator/vm-shim-protocol.md` §6.
public struct DarwinTrapDispatcher {
    /// What `getpid` returns.
    public var pid: Int32
    /// Bytes written to guest fd 1 and fd 2, decoded as UTF-8.
    public var stdout: (String) -> Void
    /// See `stdout`.
    public var stderr: (String) -> Void
    /// Receives one line (without a newline) per handled trap.
    public var log: (String) -> Void
    /// The source of `mach_absolute_time` / `mach_continuous_time`, in 24 MHz ticks.
    public var machAbsoluteTime: () -> UInt64

    /// A dispatcher whose output goes to the host's stdout and stderr by default.
    public init(
        pid: Int32 = VMLayout.guestPID,
        stdout: @escaping (String) -> Void = DarwinTrapDispatcher.writeHostStdout,
        stderr: @escaping (String) -> Void = DarwinTrapDispatcher.writeHostStderr,
        log: @escaping (String) -> Void = { DarwinTrapDispatcher.writeHostStderr($0 + "\n") },
        machAbsoluteTime: @escaping () -> UInt64 = MachTimebase.now
    ) {
        self.pid = pid
        self.stdout = stdout
        self.stderr = stderr
        self.log = log
        self.machAbsoluteTime = machAbsoluteTime
    }

    /// Writes `s` to the host process's standard output.
    public static func writeHostStdout(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }
    /// Writes `s` to the host process's standard error.
    public static func writeHostStderr(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }

    /// BSD call numbers handled in stage 2 (`vm-shim-protocol.md` §6; xnu
    /// `bsd/kern/syscalls.master`).
    public enum BSD {
        public static let exit: Int32 = 1
        public static let write: Int32 = 4
        public static let getpid: Int32 = 20
    }

    /// Mach fast traps handled in stage 2 (`vm-shim-protocol.md` §6): the
    /// negative x16 trap numbers.
    public enum Mach {
        public static let machAbsoluteTime: Int32 = -3
        public static let machContinuousTime: Int32 = -4
    }

    /// Handles one trap. For SVC the frame is edited in place (x0 and carry)
    /// and `ELR` is left alone, since it already points after the `svc`.
    public mutating func handle(_ frame: inout TrapFrame, memory: any GuestMemoryAccess) -> TrapOutcome {
        guard frame.trapKind == .svc else {
            log("trap \(frame.trapKind.map { "kind \($0.rawValue)" } ?? "kind \(frame.kind)") fatal")
            return .fatal(frame.description)
        }
        guard frame.x.count == TrapFrame.registerCount else {
            return .fatal("malformed trap frame: \(frame.x.count) general registers")
        }

        let number = DarwinTrapNumber(x16: frame.x[16])
        switch number {
        case let .bsd(n):
            return handleBSD(n, &frame, memory: memory)
        case let .mach(n) where n == Mach.machAbsoluteTime || n == Mach.machContinuousTime:
            let t = machAbsoluteTime()
            frame.x[0] = t
            log("trap mach \(n) \(n == Mach.machAbsoluteTime ? "mach_absolute_time" : "mach_continuous_time") -> \(t)")
            return .resume
        case let .mach(n):
            frame.x[0] = 0x1
            log("trap mach \(n) unimplemented -> 0x1")
            return .resume
        case .platform:
            frame.x[0] = 0x1
            log("trap platform 0x80000000 unimplemented -> 0x1")
            return .resume
        }
    }

    private func handleBSD(_ n: Int32, _ frame: inout TrapFrame, memory: any GuestMemoryAccess) -> TrapOutcome {
        func succeed(_ name: String, _ value: UInt64) -> TrapOutcome {
            frame.x[0] = value
            frame.carry = false
            log("trap bsd \(n) \(name) -> \(value)")
            return .resume
        }
        func fail(_ name: String, _ errno: UInt64) -> TrapOutcome {
            frame.x[0] = errno
            frame.carry = true
            log("trap bsd \(n) \(name) -> error \(errno) (\(DarwinErrno.name(errno)))")
            return .resume
        }

        switch n {
        case BSD.exit:
            let status = Int32(frame.x[0] & 0xFF)
            log("trap bsd \(n) exit -> exit \(status)")
            return .exit(status: status)

        case BSD.write:
            let fd = Int32(truncatingIfNeeded: frame.x[0])
            let buf = frame.x[1]
            let len = frame.x[2]
            guard fd == 1 || fd == 2 else { return fail("write", DarwinErrno.EBADF) }
            guard len <= UInt64(Int32.max) else { return fail("write", DarwinErrno.EINVAL) }
            guard len > 0 else { return succeed("write", 0) }
            let bytes: [UInt8]
            do {
                bytes = try memory.read(va: buf, count: Int(len))
            } catch {
                return fail("write", DarwinErrno.EFAULT)
            }
            let text = String(decoding: bytes, as: UTF8.self)
            if fd == 1 { stdout(text) } else { stderr(text) }
            return succeed("write", len)

        case BSD.getpid:
            return succeed("getpid", UInt64(UInt32(bitPattern: pid)))

        default:
            return fail("unimplemented", DarwinErrno.ENOSYS)
        }
    }
}
