import Foundation
import Synchronization
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// Collects console output and log lines.
final class Sink {
    var console: [Int32: [UInt8]] = [:]
    var lines: [String] = []
    func text(_ fd: Int32) -> String { String(decoding: console[fd] ?? [], as: UTF8.self) }
}

/// A kernel over a fake physical backing, with a read-only VFS prefix at a
/// temporary directory and an RW scratch region at `Env.scratch`.
struct Env {
    static let scratch: UInt64 = 0x1_0000_0000
    static let scratchSize: UInt64 = 0x10000

    let kernel: DarwinKernel
    let space: GuestAddressSpace
    let sink: Sink
    let root: String

    /// `device`: the root prefix's guest volume device (nil: the host's);
    /// `rootDevice`: the synthetic "/" device.
    init(counter: @escaping () -> UInt64 = { 0x1234 }, frequency: UInt64 = 24_000_000,
         device: UInt32? = nil, rootDevice: UInt32? = nil) throws {
        let sink = Sink()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let dir = tmp.appendingPathComponent("ycode-kernel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir.path
        let fs = DarwinFileSystem(
            prefixes: [.init(guestPath: root, hostPath: root, writable: false, device: device)],
            console: { fd, bytes in sink.console[fd, default: []] += bytes })
        fs.rootDevice = rootDevice
        kernel = DarwinKernel(fileSystem: fs, pid: 100, log: { sink.lines.append($0) }, counter: counter,
                              counterFrequency: frequency, wallClock: { (1_700_000_000, 250_000_000) })
        space = GuestAddressSpace(backing: FakePhysicalBacking())
        _ = try space.mapAnonymous(at: Self.scratch, size: Self.scratchSize, protection: .readWrite, hint: nil)
        self.sink = sink
    }

    /// Writes a host file under the root and returns its guest path.
    func makeFile(_ name: String, _ bytes: [UInt8]) throws -> String {
        let path = root + "/" + name
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Runs one SVC with `x16` and the given argument registers.
    @discardableResult
    func svc(_ x16: UInt64, _ args: [UInt64] = [], x3: UInt64? = nil, frame: inout TrapFrame) -> DarwinKernel.Outcome {
        frame.kind = TrapFrame.Kind.svc.rawValue
        frame.x[16] = x16
        for (i, v) in args.enumerated() { frame.x[i] = v }
        if let x3 { frame.x[3] = x3 }
        return kernel.handleTrying(&frame, context: kernel.mainThread, memory: space)
    }

    func svc(_ x16: UInt64, _ args: [UInt64] = []) -> (DarwinKernel.Outcome, TrapFrame) {
        var f = TrapFrame()
        let o = svc(x16, args, frame: &f)
        return (o, f)
    }

    func put(_ bytes: [UInt8], at va: UInt64) throws { try space.write(va: va, bytes: bytes) }
    func putString(_ s: String, at va: UInt64) throws { try put(Array(s.utf8) + [0], at: va) }
    func u64(_ va: UInt64) throws -> UInt64 { le(try space.read(va: va, count: 8)) }
    func u32(_ va: UInt64) throws -> UInt32 { UInt32(truncatingIfNeeded: le(try space.read(va: va, count: 4))) }
    func string(_ va: UInt64) throws -> String {
        let b = try space.read(va: va, count: 256)
        return String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
    }
}

let reportedSplit = Atomic<Bool>(false)

extension DarwinKernel {
    /// As the VMM: an IPC fast path first (`YCODE_IPC_LOCKS_TESTS=1` turns
    /// the lock split on in every test system), else the locked path.
    func handleTrying(_ frame: inout TrapFrame, context: ThreadContext, memory: any KernelGuestMemory) -> Outcome {
        if DarwinSystem.splitForTests || DarwinKernel.bsdFastForTests, !reportedSplit.exchange(true, ordering: .relaxed) {
            atexit {
                print("ipc fast traps in tests: \(DarwinKernel.ipcFastServed.load(ordering: .relaxed)) served, "
                    + "\(DarwinKernel.ipcFastDeclined.load(ordering: .relaxed)) declined; "
                    + "bsd fast traps: \(DarwinKernel.bsdFastServed.load(ordering: .relaxed)) served, "
                    + "\(DarwinKernel.bsdFastDeclined.load(ordering: .relaxed)) declined")
            }
        }
        if DarwinSystem.splitForTests, hasIPCFastPaths, let o = handleIPCFast(&frame, context: context, memory: memory) {
            return o
        }
        // BSD traps without L0 (bsd-locking.md), as the VMM tries them.
        if DarwinKernel.bsdFastForTests, context.kernel === self,
           let o = handleBSDFast(&frame, context: context, memory: memory) {
            return o
        }
        return handle(&frame, context: context, memory: memory)
    }
}

func le(_ b: some Collection<UInt8>) -> UInt64 {
    var v: UInt64 = 0
    for (i, byte) in b.prefix(8).enumerated() { v |= UInt64(byte) << (8 * UInt64(i)) }
    return v
}

func u64(_ b: [UInt8], _ o: Int) -> UInt64 { le(b[o..<(o + 8)]) }
func u32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(le(b[o..<(o + 4)])) }
func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(le(b[o..<(o + 2)])) }
func leBytes(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

/// A deterministic RNG for the apple strings.
struct CountingRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x1111_1111_1111_1111
        return state
    }
}
