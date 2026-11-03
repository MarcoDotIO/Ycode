// ycode-simd: the debug stub (specs/simulator/debug-stub.md). `--debug-server
// unix:<path>|<port>` serves LLDB's gdb-remote protocol for one guest process
// at a time: a new connection is attached to the app `--launch` started
// (when there is one), or attaches with `vAttach`/`vAttachName`/`vAttachWait`.
// The protocol is YcodeDebug's GDBRemoteServer; this file is the simulator
// side: threads, registers and memory of a guest image, and the kernel's
// debug hooks (YcodeDarwinKernel/DebugHooks.swift).

import Foundation
import YcodeDebug

/// `--debug-server` and its companions.
struct DebugServerOptions {
    /// `unix:<path>`, `<host>:<port>` or `<port>`.
    var address: String
    /// `--debug-server-log`: every packet to stderr.
    var log = false
    /// `--debug-launch-stopped`: the `--launch` app is held at its first
    /// instruction until a debugger attaches (debug-stub.md §7).
    var launchStopped = false
}

#if os(Linux) && arch(arm64)
import CKVM
import Glibc
import YcodeDarwinABI
import YcodeDarwinKernel
import YcodeHypervisor

final class SimDebugServer: GDBRemoteHost, @unchecked Sendable {
    nonisolated(unsafe) static var shared: SimDebugServer?

    let options: DebugServerOptions
    /// The pid `--launch` reported, once it did.
    var launchedPID: () -> Int32? = { nil }
    /// The OS type for `qHostInfo` and `qProcessInfo` (ios, watchos, xros;
    /// debug-stub.md §4.3).
    var osType = "ios"
    /// The runtime's ProductVersion and ProductBuildVersion (`qHostInfo`
    /// `os_version`, `os_build`; debug-stub.md §4.3).
    var osVersion = ""
    var osBuild = ""
    /// The `--launch` app's executable name (CFBundleExecutable), for
    /// `--debug-launch-stopped`.
    var launchExecutable: String?
    private var launcher: VMMLauncher?
    private var listener: GDBRemoteListener?

    /// A wait for the next spawn of an executable: the image is held at its
    /// first instruction for the debugger (debug-stub.md §7). Guarded by `waitLock`.
    final class SpawnWait {
        let name: String
        var process: SimDebugProcess?
        init(name: String) { self.name = name }
    }
    private let waitLock = NSLock()
    private var spawnWaits: [SpawnWait] = []
    /// The `--debug-launch-stopped` wait for the launched app.
    private var launchWait: SpawnWait?

    init(options: DebugServerOptions) { self.options = options }

    func start(launcher: VMMLauncher) {
        self.launcher = launcher
        if options.launchStopped, let name = launchExecutable {
            let w = SpawnWait(name: name)
            waitLock.withLock { spawnWaits.append(w) }
            launchWait = w
            stderrLine("ycode-simd: debug: \(name) is held at its first instruction when it starts, until a debugger attaches")
        }
        do {
            if options.address.hasPrefix("unix:") {
                let dir = (String(options.address.dropFirst(5)) as NSString).deletingLastPathComponent
                if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
            }
            let l = try GDBRemoteListener(address: options.address)
            listener = l
            stderrLine("ycode-simd: debug: gdb-remote stub listening on \(l.description)")
            let t = Thread { [self] in acceptLoop(l) }
            t.name = "ycode debug stub"
            t.start()
        } catch {
            stderrLine("ycode-simd: debug: cannot listen on \(options.address): \(error)")
        }
    }

    func stop() {
        listener?.close()
        listener = nil
    }

    private func acceptLoop(_ l: GDBRemoteListener) {
        while let c = l.accept() {
            stderrLine("ycode-simd: debug: client connected")
            let server = GDBRemoteServer(host: self, connection: c)
            if options.log { server.log = { stderrLine("ycode-simd: debug: " + $0) } }
            server.serve()
            stderrLine("ycode-simd: debug: client disconnected")
        }
    }

    // MARK: GDBRemoteHost

    var hostInfo: [(String, String)] {
        // With an OS version LLDB uses its newer image loader, which asks
        // the stub for the images (jGetLoadedDynamicLibrariesInfos) and
        // puts its breakpoint on the image list's notification function
        // (debug-stub.md §4.3, §4.4).
        var pairs = [("cputype", "16777228"), ("cpusubtype", "0"), ("ostype", osType), ("vendor", "apple"), ("endian", "little"),
                     ("ptrsize", "8"), ("vm-page-size", "16384")]
        if !osVersion.isEmpty { pairs.append(("os_version", osVersion)) }
        if !osBuild.isEmpty { pairs.append(("os_build", GDBRemoteHex.encode(text: osBuild))) }
        pairs += [("watchpoint_exceptions_received", "before"), ("hostname", GDBRemoteHex.encode(text: "ycode-simulator")),
                  ("default_packet_timeout", "20")]
        return pairs
    }

    /// The runtime root's SystemVersion.plist: (ProductVersion, ProductBuildVersion).
    static func runtimeVersion(root: String) -> (String, String) {
        let path = root + "/System/Library/CoreServices/SystemVersion.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return ("", "")
        }
        return (plist["ProductVersion"] as? String ?? "", plist["ProductBuildVersion"] as? String ?? "")
    }

    // MARK: Spawn holds (debug-stub.md §7)

    /// The launcher calls this for every new image before its main thread
    /// starts (kernel lock held). An image a debugger waits for is attached
    /// here, so its main thread parks before its first instruction.
    func imageWillStart(_ image: GuestImageInstance) {
        let wait: SpawnWait? = waitLock.withLock {
            spawnWaits.first { $0.process == nil && Self.matches(image, $0.name) }
        }
        guard let wait, let p = SimDebugProcess.hold(image, server: self) else { return }
        waitLock.withLock { wait.process = p }
        stderrLine("ycode-simd: debug: pid \(image.pid) (\(Self.name(image))) held at its first instruction for the debugger")
    }

    static func matches(_ i: GuestImageInstance, _ name: String) -> Bool {
        Self.name(i) == name || i.record.executable == name
    }

    /// Waits for `wait` to get its process (polled every millisecond).
    private func process(of wait: SpawnWait, seconds: Double) -> SimDebugProcess? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let p = waitLock.withLock({ wait.process }) { return p }
            usleep(1000)
        }
        return nil
    }

    private func removeWait(_ wait: SpawnWait) {
        waitLock.withLock { spawnWaits.removeAll { $0 === wait } }
    }

    private var images: [GuestImageInstance] { launcher?.snapshotLiveImages.filter { !$0.kernel.isTerminating } ?? [] }

    static func name(_ image: GuestImageInstance) -> String { (image.record.executable as NSString).lastPathComponent }

    func processes() -> [(pid: Int, name: String)] {
        images.map { (Int($0.pid), Self.name($0)) }.sorted { $0.pid < $1.pid }
    }

    func initialProcess() -> GDBRemoteProcess? {
        // --debug-launch-stopped: the launched app, held at its first instruction.
        if let w = launchWait, let held = waitLock.withLock({ w.process }) {
            removeWait(w)
            launchWait = nil
            if case let .success(p) = held.finishAttach() { return p }
        }
        guard let pid = launchedPID(), case let .success(p) = attach(pid: Int(pid)) else { return nil }
        return p
    }

    func attach(pid: Int) -> Result<GDBRemoteProcess, GDBRemoteError> {
        guard let image = images.first(where: { Int($0.pid) == pid }) else { return .failure(GDBRemoteError(0x01, "no process \(pid)")) }
        switch SimDebugProcess.attach(image, server: self) {
        case let .success(p): return .success(p)
        case let .failure(e): return .failure(e)
        }
    }

    func attach(name: String, wait: Bool, includeExisting: Bool) -> Result<GDBRemoteProcess, GDBRemoteError> {
        if !wait || includeExisting, let image = images.first(where: { Self.matches($0, name) }) { return attach(pid: Int(image.pid)) }
        guard wait else { return .failure(GDBRemoteError(0x01, "no process named \(name)")) }
        // The next process of that name, for 10 minutes: the launcher holds
        // it at its first instruction (imageWillStart), so the debugger
        // attaches before any of its code runs.
        let w = SpawnWait(name: name)
        waitLock.withLock { spawnWaits.append(w) }
        defer { removeWait(w) }
        guard let held = process(of: w, seconds: 600) else { return .failure(GDBRemoteError(0x01, "no process named \(name) started")) }
        switch held.finishAttach() {
        case let .success(p): return .success(p)
        case let .failure(e): return .failure(e)
        }
    }
}

/// One attached guest image.
final class SimDebugProcess: GDBRemoteProcess, KernelDebugger, @unchecked Sendable {
    let image: GuestImageInstance
    let kernel: DarwinKernel
    lazy var breakpoints = GDBRemoteBreakpoints(read: { [unowned self] a, n in rawRead(a, n) },
                                                write: { [unowned self] a, b in rawWrite(a, b) })
    private let osType: String
    private let osVersion: String

    // Events (the kernel hook signals; `waitForEvent` waits).
    private let condition = NSCondition()
    private var pendingThread: UInt64?
    private var interruptRequested = false
    /// The thread an interrupt or the attach reports (SIGSTOP).
    private var signalThread: UInt64?
    /// Memory was written since the last resume (TLB flush on resume).
    private var codeChanged = false
    /// The threads as of the last stop. The kernel may make a workqueue
    /// thread while the process is stopped (it starts held); the client
    /// sees it at the next stop, so the thread list does not change under
    /// a stopped process (debug-stub.md §6).
    private var stopThreads: [UInt64] = []

    private init(image: GuestImageInstance, osType: String, osVersion: String) {
        self.image = image
        kernel = image.kernel
        self.osType = osType
        self.osVersion = osVersion
    }

    static func attach(_ image: GuestImageInstance, server: SimDebugServer) -> Result<SimDebugProcess, GDBRemoteError> {
        let p = SimDebugProcess(image: image, osType: server.osType, osVersion: server.osVersion)
        guard p.kernel.debugAttach(p) else { return .failure(GDBRemoteError(0x01, "process \(image.pid) is ending or already debugged")) }
        return p.finishAttach()
    }

    /// Attaches to an image whose main thread has not started (the
    /// launcher's spawn hold): every thread is held, so the main thread
    /// parks before its first instruction. Kernel lock held; does not wait.
    static func hold(_ image: GuestImageInstance, server: SimDebugServer) -> SimDebugProcess? {
        let p = SimDebugProcess(image: image, osType: server.osType, osVersion: server.osVersion)
        guard p.kernel.debugAttach(p) else { return nil }
        p.heldAtStart = true
        return p
    }

    /// An image held at its start: its main thread has not parked yet.
    private var heldAtStart = false

    /// Waits until every thread is stopped (an image held at its start:
    /// until its main thread parked before its first instruction), then
    /// reports the attach stop.
    func finishAttach() -> Result<SimDebugProcess, GDBRemoteError> {
        var stopped = waitUntilStopped(seconds: 10)
        if stopped, heldAtStart {
            let deadline = Date().addingTimeInterval(10)
            while !kernel.debugIsParked(kernel.mainThread) && !kernel.isTerminating {
                if Date() > deadline { stopped = false; break }
                usleep(250)
            }
        }
        guard stopped else {
            kernel.debugDetach()
            return .failure(GDBRemoteError(0x01, "process \(image.pid) did not stop"))
        }
        signalThread = kernel.debugThreads.first?.threadID
        stopThreads = kernel.debugThreads.map(\.threadID)
        let pc = signalThread.flatMap { registers($0)?.pc }.map { " at pc 0x" + String($0, radix: 16) } ?? ""
        stderrLine("ycode-simd: debug: attached to pid \(image.pid) (\(SimDebugServer.name(image))), \(kernel.debugThreads.count) threads\(pc)")
        return .success(self)
    }

    /// Waits until every held thread is stopped, kicking vCPUs that still
    /// run guest code every millisecond.
    private func waitUntilStopped(seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var rounds = 0
        while !kernel.debugAllStopped() {
            if Date() > deadline { return false }
            if rounds % 4 == 3 { kernel.debugKickRunning() }
            rounds += 1
            usleep(250)
        }
        return true
    }

    private func thread(_ tid: UInt64) -> ThreadContext? { kernel.debugThreads.first { $0.threadID == tid } }

    // MARK: KernelDebugger (kernel lock held)

    func kernelDebugException(_ kernel: DarwinKernel, thread: ThreadContext, stop: KernelDebugStop) -> KernelDebugDecision {
        if case .breakpoint = stop.kind, !breakpoints.contains(stop.pc) {
            // A breakpoint removed while the thread was on its way into its
            // trap: no `brk` is there any more, so it runs the instruction.
            let now = rawRead(stop.pc, 4)
            if now.count == 4, GDBRemoteHex.littleEndianValue(now) & 0xFFE0_001F != 0xD420_0000 { return .retry }
        }
        condition.lock()
        if pendingThread == nil { pendingThread = thread.threadID }
        condition.broadcast()
        condition.unlock()
        return .stop
    }

    // MARK: GDBRemoteProcess

    var pid: Int { Int(image.pid) }

    var processInfo: [(String, String)] {
        [("parent-pid", String(kernel.debugParentPID, radix: 16)), ("real-uid", "1f5"), ("real-gid", "14"),
         ("effective-uid", "1f5"), ("effective-gid", "14"), ("cputype", "100000c"), ("cpusubtype", "0"),
         ("ostype", osType), ("vendor", "apple"), ("endian", "little"), ("ptrsize", "8")]
            + (osVersion.isEmpty ? [] : [("os_version", osVersion)])
    }

    // MARK: Images (debug-stub.md §4.3)

    /// dyld's list: `infoArrayCount` × `dyld_image_info` at `infoArray`
    /// (the struct `dyld_sim` keeps in the host page), plus `dyld_sim`
    /// itself (`dyldImageLoadAddress`) when the list lacks it.
    func loadedImages() -> [(address: UInt64, path: String)]? {
        let infos = kernel.allImageInfosAddress
        let head = rawRead(infos, 40)
        guard head.count == 40 else { return nil }
        let count = Int(min(GDBRemoteMachO.u32(head, DyldAllImageInfos.Offset.infoArrayCount), 1 << 14))
        let array = GDBRemoteMachO.u64(head, DyldAllImageInfos.Offset.infoArray)
        let dyld = GDBRemoteMachO.u64(head, DyldAllImageInfos.Offset.dyldImageLoadAddress)
        var out: [(address: UInt64, path: String)] = []
        // NULL while dyld_sim updates it: the dyld entry alone.
        if array != 0, count > 0 {
            let bytes = rawRead(array, 24 * count)
            for o in stride(from: 0, to: bytes.count / 24 * 24, by: 24) {
                let a = GDBRemoteMachO.u64(bytes, o)
                guard a != 0 else { continue }
                out.append((a, GDBRemoteServer.cString(at: GDBRemoteMachO.u64(bytes, o + 8)) { [self] in rawRead($0, $1) }))
            }
        }
        if dyld != 0, !out.contains(where: { $0.address == dyld }) {
            out.append((dyld, memoryRegion(at: dyld)?.name ?? "/usr/lib/dyld_sim"))
        }
        return out
    }

    /// From the image list's `libSystemInitialized` and the kernel's record
    /// of `dyld_sim`'s "main called" notification.
    var dyldState: GDBRemoteDyldState? {
        if kernel.debugDyldMainCalled { return .programRunning }
        let infos = kernel.allImageInfosAddress
        let head = rawRead(infos, 32)
        guard head.count == 32 else { return nil }
        if head[DyldAllImageInfos.Offset.libSystemInitialized] != 0 { return .libSystemInitialized }
        // The host's list holds only the main executable until dyld_sim adds images.
        return GDBRemoteMachO.u32(head, DyldAllImageInfos.Offset.infoArrayCount) > 1 ? .dyldInitialized : .notStarted
    }

    // MARK: Hardware watchpoints (debug-stub.md §6.2)

    struct Watch: Equatable {
        var address: UInt64
        var size: Int
        var kind: GDBRemoteWatchKind
        var registers: VCPUPool.HardwareWatchpoint
    }
    /// In register order.
    private var watches: [Watch] = []
    /// The threads the last resume stepped.
    private var steppedThreads: Set<UInt64> = []
    private var stepStarts: [UInt64: UInt64] = [:]

    var watchpointSlots: Int { min(image.pool.hardwareWatchpointCount, 16) }

    /// DBGWVR/DBGWCR for a range: a byte-select within one doubleword, or
    /// an aligned power of two of 8 bytes or more (MASK). EL0 accesses only
    /// (PAC 0b10); LSC 1 load, 2 store, 3 both (Arm ARM, DBGWCR<n>_EL1).
    static func registers(address: UInt64, size: Int, kind: GDBRemoteWatchKind) -> VCPUPool.HardwareWatchpoint? {
        let lsc: UInt64 = kind == .read ? 1 : kind == .write ? 2 : 3
        let common: UInt64 = 1 | (0b10 << 1) | (lsc << 3)
        let base = address & ~UInt64(7)
        if size <= 8, address + UInt64(size) <= base + 8 {
            let bas = ((UInt64(1) << UInt64(size)) - 1) << (address - base)
            return .init(value: base, control: common | (bas << 5))
        }
        let n = UInt64(size)
        guard n >= 8, n <= 1 << 31, n & (n - 1) == 0, address & (n - 1) == 0 else { return nil }
        return .init(value: address, control: common | (0xFF << 5) | (UInt64(n.trailingZeroBitCount) << 24))
    }

    func insertWatchpoint(address: UInt64, size: Int, kind: GDBRemoteWatchKind) -> Result<Void, GDBRemoteError> {
        if watches.contains(where: { $0.address == address && $0.size == size && $0.kind == kind }) { return .success(()) }
        guard let r = Self.registers(address: address, size: size, kind: kind) else {
            return .failure(GDBRemoteError(0x16, "a watchpoint of \(size) bytes at 0x\(String(address, radix: 16)) cannot be set"))
        }
        guard watches.count < watchpointSlots else { return .failure(GDBRemoteError(0x1C, "no free hardware watchpoint")) }
        watches.append(Watch(address: address, size: size, kind: kind, registers: r))
        image.pool.setHardwareWatchpoints(watches.map(\.registers))
        return .success(())
    }

    func removeWatchpoint(address: UInt64, size: Int, kind: GDBRemoteWatchKind) -> Result<Void, GDBRemoteError> {
        let before = watches.count
        watches.removeAll { $0.address == address && $0.size == size && $0.kind == kind }
        if watches.count != before { image.pool.setHardwareWatchpoints(watches.map(\.registers)) }
        return .success(())
    }

    /// The watchpoint an access at `hit` matched: the one whose range holds
    /// it, else the nearest one whose doublewords overlap the access's
    /// (a wide access reports its first byte, which may lie before the range).
    func watchStop(hit: UInt64) -> GDBRemoteStopReason {
        if let i = watches.firstIndex(where: { hit >= $0.address && hit < $0.address + UInt64($0.size) }) {
            return .watchpoint(address: hit, index: i, hit: hit)
        }
        let candidates = watches.enumerated().filter { _, w in (hit & ~UInt64(7)) < w.address + UInt64(w.size) && hit + 16 > w.address }
        if let (i, w) = candidates.min(by: { abs(Int64(bitPattern: $0.1.address &- hit)) < abs(Int64(bitPattern: $1.1.address &- hit)) }) {
            return .watchpoint(address: w.address, index: i, hit: hit)
        }
        return .watchpoint(address: watches.first?.address ?? hit, index: 0, hit: hit)
    }

    var sharedLibraryInfoAddress: UInt64? { kernel.allImageInfosAddress }

    /// From the image list `dyld_sim` keeps: sharedCacheUUID (160) and
    /// sharedCacheBaseAddress (176) (dyld-sim-handoff.md §4.5).
    var sharedCacheInfo: (base: UInt64, uuid: [UInt8])? {
        let infos = kernel.allImageInfosAddress
        let uuid = rawRead(infos &+ UInt64(DyldAllImageInfos.Offset.sharedCacheUUID), 16)
        let base = GDBRemoteHex.littleEndianValue(rawRead(infos &+ UInt64(DyldAllImageInfos.Offset.sharedCacheBaseAddress), 8))
        guard uuid.count == 16, uuid.contains(where: { $0 != 0 }), base != 0 else { return nil }
        return (base, uuid)
    }
    var hasFloatingPointRegisters: Bool { true }

    func threadIDs() -> [UInt64] {
        let alive = Set(kernel.debugThreads.map(\.threadID))
        return stopThreads.filter { alive.contains($0) }
    }

    func threadName(_ tid: UInt64) -> String? { nil }

    func dispatchQueueAddress(_ tid: UInt64) -> UInt64? {
        // The libdispatch queue slot of the thread's TSD (as
        // THREAD_IDENTIFIER_INFO reports it, ThreadInfo.swift).
        guard let t = thread(tid), t.pthreadAddress != 0 else { return nil }
        return t.pthreadAddress + 224 + 20 * 8
    }

    func stopInfo(_ tid: UInt64) -> GDBRemoteThreadStop {
        guard let t = thread(tid) else { return .quiet }
        guard let stop = kernel.debugStopOf(t) else {
            return tid == signalThread ? GDBRemoteThreadStop(signal: 17, reason: .signal) : .quiet
        }
        switch stop.kind {
        case let .breakpoint(immediate):
            // A thread the client stepped that stops at one of its
            // breakpoints has not executed that instruction: the step
            // ended there (LLDB's step-over-breakpoint plans expect `trace`).
            if steppedThreads.contains(tid), breakpoints.contains(stop.pc) {
                if let from = stepStarts[tid], stop.pc != from &+ 4 {
                    stderrLine("ycode-simd: debug: thread \(tid) stepped from 0x\(String(from, radix: 16)) to the breakpoint at 0x\(String(stop.pc, radix: 16))")
                    stepStarts[tid] = nil
                }
                return GDBRemoteThreadStop(signal: 5, reason: .trace)
            }
            if breakpoints.contains(stop.pc) { return GDBRemoteThreadStop(signal: 5, reason: .breakpoint) }
            return GDBRemoteThreadStop(signal: 5, reason: .exception("EXC_BREAKPOINT (brk #\(String(immediate, radix: 16)))"))
        case .step:
            return GDBRemoteThreadStop(signal: 5, reason: .trace)
        case let .fault(signal, description):
            return GDBRemoteThreadStop(signal: Int(signal), reason: .exception(description))
        case let .watchpoint(address, _):
            return GDBRemoteThreadStop(signal: 5, reason: watchStop(hit: address))
        }
    }

    /// The vCPU that runs `t` (it is stopped: parked at its gate or in a
    /// kernel call, never in KVM_RUN), for its FP/SIMD registers.
    private func vcpu(of t: ThreadContext) -> VCPU? {
        image.pool.activeWorkers().first { $0.context === t }?.vcpu
    }

    func registers(_ tid: UInt64) -> GDBRemoteThreadRegisters? {
        guard let t = thread(tid), let f = kernel.debugRegisters(t) else { return nil }
        // PSTATE as thread_get_state reports it: NZCV, EL0t (the step bit off).
        var r = GDBRemoteThreadRegisters(x: Array(f.x.prefix(31)), sp: f.spEL0, pc: f.elr,
                                         cpsr: UInt32(truncatingIfNeeded: f.spsr) & 0xF000_0000)
        // FP/SIMD live in the vCPU (the shim saves none of them): v0–v31,
        // fpsr, fpcr, as the snapshot reads them (SnapshotSupport.swift).
        if let v = vcpu(of: t) {
            var fp = [UInt8](repeating: 0, count: 520)
            if fp.withUnsafeMutableBufferPointer({ ckvm_get_fp_state(v.fd, $0.baseAddress) }) >= 0 {
                r.vector = Array(fp[0..<512])
                r.fpsr = UInt32(GDBRemoteHex.littleEndianValue(fp[512..<516]))
                r.fpcr = UInt32(GDBRemoteHex.littleEndianValue(fp[516..<520]))
            }
        }
        return r
    }

    func setRegisters(_ tid: UInt64, _ r: GDBRemoteThreadRegisters) -> Bool {
        guard let t = thread(tid), var f = kernel.debugRegisters(t) else { return false }
        let old = registers(tid)
        for i in 0..<31 { f.x[i] = r.x[i] }
        f.spEL0 = r.sp
        f.elr = r.pc
        f.spsr = (f.spsr & ~UInt64(0xF000_0000)) | UInt64(r.cpsr & 0xF000_0000)
        guard kernel.debugSetRegisters(t, f) else { return false }
        if let vec = r.vector, vec.count == 512, vec != old?.vector || r.fpsr != old?.fpsr || r.fpcr != old?.fpcr {
            guard let v = vcpu(of: t) else { return false }
            var fp = vec
            for word in [r.fpsr ?? 0, r.fpcr ?? 0] { for i in 0..<4 { fp.append(UInt8(truncatingIfNeeded: word >> (8 * UInt32(i)))) } }
            guard fp.withUnsafeBufferPointer({ ckvm_set_fp_state(v.fd, $0.baseAddress) }) >= 0 else { return false }
        }
        return true
    }

    /// Memory without the breakpoint table: page by page, as far as it is readable.
    func rawRead(_ address: UInt64, _ count: Int) -> [UInt8] {
        var out: [UInt8] = []
        var cursor = address
        var remaining = count
        while remaining > 0 {
            let inPage = Int(VMLayout.pageSize - (cursor & (VMLayout.pageSize - 1)))
            let n = min(inPage, remaining)
            guard let bytes = try? image.space.read(va: cursor, count: n, checkingEL0Access: false) else { break }
            out += bytes
            cursor &+= UInt64(n)
            remaining -= n
        }
        return out
    }

    func rawWrite(_ address: UInt64, _ bytes: [UInt8]) -> Bool {
        do {
            // Read-only code moves to a private copy of its page first
            // (GuestAddressSpace.write without EL0 checks).
            try image.space.write(va: address, bytes: bytes, checkingEL0Access: false)
            codeChanged = true
            return true
        } catch {
            return false
        }
    }

    /// Reads for the client. One field is shown as dyld fills it in: the
    /// image list's own address (`dyldAllImageInfosAddress`, offset 104),
    /// which Ycode leaves 0 (stage3-contract.md §6) and LLDB compares with
    /// the address `qShlibInfoAddr` gave to detect a slid dyld
    /// (debug-stub.md §4.3). Guest memory is not changed.
    func readMemory(_ address: UInt64, count: Int) -> [UInt8] {
        var bytes = rawRead(address, count)
        let field = kernel.allImageInfosAddress &+ UInt64(DyldAllImageInfos.Offset.dyldAllImageInfosAddress)
        let end = address &+ UInt64(bytes.count)
        // Only a field the guest left 0 is filled in.
        if field < end, field &+ 8 > address, rawRead(field, 8) == [UInt8](repeating: 0, count: 8) {
            let own = kernel.allImageInfosAddress
            for i in 0..<8 {
                let a = field &+ UInt64(i)
                if a >= address, a < end { bytes[Int(a - address)] = UInt8(truncatingIfNeeded: own >> (8 * UInt64(i))) }
            }
        }
        return bytes
    }
    func writeMemory(_ address: UInt64, bytes: [UInt8]) -> Bool { rawWrite(address, bytes) }

    /// Memory the debugger allocated (`_M`), by address: its size.
    private var allocations: [UInt64: UInt64] = [:]

    func allocateMemory(size: UInt64, permissions: String) -> UInt64? {
        var protection: VMProtection = []
        if permissions.contains("r") { protection.insert(.read) }
        if permissions.contains("w") { protection.insert(.write) }
        if permissions.contains("x") { protection.insert(.execute) }
        let rounded = (size + VMLayout.pageSize - 1) & ~(VMLayout.pageSize - 1)
        guard let a = try? kernel.debugLocked({ try image.space.mapAnonymous(at: nil, size: rounded, protection: protection, hint: nil) }) else {
            return nil
        }
        allocations[a] = rounded
        return a
    }

    func deallocateMemory(_ address: UInt64) -> Bool {
        guard let size = allocations.removeValue(forKey: address) else { return false }
        _ = try? kernel.debugLocked { try image.space.unmap(va: address, size: size) }
        codeChanged = true   // an unmap leaves stale translations
        return true
    }

    func memoryRegion(at address: UInt64) -> GDBRemoteMemoryRegion? {
        let a = address & VMLayout.addressWithoutTag
        let regions = image.space.regions
        if let r = regions.first(where: { $0.va <= a && a < $0.end }) {
            var perms = ""
            if r.protection.contains(.read) { perms += "r" }
            if r.protection.contains(.write) { perms += "w" }
            if r.protection.contains(.execute) { perms += "x" }
            var name: String?
            if case let .file(path, _, _) = r.backing { name = path }
            return GDBRemoteMemoryRegion(start: r.va, size: r.size, permissions: perms, name: name)
        }
        // Unmapped: up to the next mapping.
        let next = regions.first(where: { $0.va > a })?.va ?? (UInt64(1) << 47)
        let start = regions.last(where: { $0.end <= a })?.end ?? 0
        return GDBRemoteMemoryRegion(start: start, size: next > start ? next - start : 0, permissions: nil)
    }

    func resume(_ actions: [UInt64: GDBRemoteResume], others: GDBRemoteResume) -> Result<Void, GDBRemoteError> {
        func map(_ r: GDBRemoteResume, _ tid: UInt64?) -> DarwinKernel.DebugResume {
            switch r {
            case .stop: return .stay
            case let .continue(signal):
                // A fault's own signal passed back: the fault takes its course.
                guard let signal, let tid, case .exception = stopInfo(tid).reason, stopInfo(tid).signal == signal else { return .run(deliverSignal: false) }
                return .run(deliverSignal: true)
            case .step: return .step
            }
        }
        var mapped: [UInt64: DarwinKernel.DebugResume] = [:]
        for (tid, a) in actions { mapped[tid] = map(a, tid) }
        steppedThreads = Set(mapped.filter { $0.value == .step }.keys)
        stepStarts = [:]
        for tid in steppedThreads { stepStarts[tid] = registers(tid)?.pc }
        // `others` with a signal: only the named threads get signals.
        let rest = map(others, nil)
        condition.lock()
        pendingThread = nil
        interruptRequested = false
        signalThread = nil
        condition.unlock()
        if codeChanged {
            codeChanged = false
            kernel.debugRequestFlush()
        }
        kernel.debugResume(mapped, others: rest)
        return .success(())
    }

    func interrupt() {
        kernel.debugStopAll()
        condition.lock()
        interruptRequested = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForEvent() -> GDBRemoteEvent {
        while true {
            if let status = kernel.debugTerminationStatus ?? (kernel.isTerminating ? Int32(DarwinKernel.Signal.sigkill) : nil) {
                breakpoints.forgetAll()
                return status & 0x7F == 0 ? .exited(status: Int((status >> 8) & 0xFF)) : .terminated(signal: Int(status & 0x7F))
            }
            condition.lock()
            if pendingThread == nil && !interruptRequested { _ = condition.wait(until: Date().addingTimeInterval(0.05)) }
            let hit = pendingThread
            let interrupted = interruptRequested
            condition.unlock()
            guard hit != nil || interrupted else { continue }
            if !waitUntilStopped(seconds: 5) {
                if kernel.isTerminating { continue }
                stderrLine("ycode-simd: debug: some threads of pid \(pid) did not stop within 5 s; reporting the stop anyway")
            }
            stopThreads = kernel.debugThreads.map(\.threadID)
            if let hit { return .stopped(thread: hit) }
            let main = kernel.debugThreads.first?.threadID ?? 0
            condition.lock()
            signalThread = main
            condition.unlock()
            return .stopped(thread: main)
        }
    }

    func detach() {
        if !watches.isEmpty {
            watches = []
            image.pool.setHardwareWatchpoints([])
        }
        if codeChanged {
            codeChanged = false
            kernel.debugRequestFlush()
        }
        kernel.debugDetach()
        stderrLine("ycode-simd: debug: detached from pid \(pid)")
    }

    func kill() {
        if !watches.isEmpty {
            watches = []
            image.pool.setHardwareWatchpoints([])
        }
        kernel.debugDetach()
        kernel.debugKill()
        stderrLine("ycode-simd: debug: killed pid \(pid)")
    }
}
#endif
