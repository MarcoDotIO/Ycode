// ycode-simd: Gauge's recorder for apps on the simulator
// (specs/ide/profiler.md §3.1). `--profile <path>` turns it on.
//
// One host thread samples every thread of the target process `rate` times
// a second: a vCPU running guest code is kicked out of KVM_RUN and records
// PC, LR, FP, PSTATE and its frame-pointer chain on its own host thread
// (VCPUPool's diagnostic kick); a thread inside a trap handler is not
// stopped: the user registers saved at the trap's entry give its stack.
// Addresses are placed in images at once (the image may end before the
// trace is written); symbols come from the images' Mach-O symbol tables at
// the end. Signposts come from the in-app agent (libYcodeGauge.dylib, a
// file in the device's /tmp), presents from the frame record, GPU command
// buffers from the Metal trace.

import Foundation
import YcodeMachO
import YcodeProfiler

/// `--profile` and its companions.
struct GaugeOptions {
    var path: String
    var rate = 1000
    var hangMilliseconds = 250
    var seconds: Double?
    var processes: [String] = []
    var signposts = true
}

/// The signpost file (guest path; DEV/data/tmp on the host).
enum GaugeAgentFiles {
    static let signpostsGuestPath = "/tmp/ycode-gauge-signposts.bin"
    static let libraryName = "libYcodeGauge.dylib"
}

#if os(Linux) && arch(arm64)
import Glibc
import Synchronization
import YcodeDarwinABI
import YcodeDarwinKernel
import YcodeHypervisor

/// A stop signal that nothing else in ycode-simd handles (no stop
/// snapshot, no display server): Gauge writes the trace, then the process
/// ends as the signal would have ended it.
enum GaugeStopSignal {
    static let received = Atomic<Int32>(0)
}
private func gaugeStopSignalHandler(_ sig: Int32) { GaugeStopSignal.received.store(sig, ordering: .relaxed) }

final class GaugeRecorder: @unchecked Sendable {
    nonisolated(unsafe) static var shared: GaugeRecorder?
    static var active: Bool { shared != nil }

    let options: GaugeOptions
    /// The app's executable name (CFBundleExecutable of `--install-app`).
    var appExecutable: String?
    var deviceDescription = ""
    var command = ""
    /// The launched app's pid once the launch reported it.
    var launchedPID: () -> Int32? = { nil }
    /// Host paths: the frame record, the signpost file, the Metal trace.
    var frameRecordPath: String?
    var signpostsHostPath: String?
    var metalTracePath: String?

    private let finished = Atomic<Bool>(false)
    /// Stop signals Gauge took over (their default action was to end the process).
    private var ownSignals: [Int32] = []
    private let lock = HostMutex(name: "gauge recorder")
    private var thread: Thread?

    init(options: GaugeOptions) { self.options = options }

    // MARK: State (sampler thread only, then `finish` under `lock`)

    struct ImageInfo {
        var name: String
        var guestPath: String
        var hostPath: String?
        var kind: GaugeTrace.ImageKind
        var base: UInt64
        var low: UInt64
        var high: UInt64
        /// The install name of a shared-cache image.
        var cacheImage: String?
    }

    struct RawSample {
        var time: UInt64
        var tid: UInt64
        var pid: Int32
        var state: GaugeTrace.SampleState
        /// Frames outermost first (resolved) — the leaf is last.
        var frames: [GaugeTrace.Frame]
        /// LR of a user sample, kept apart until symbols decide whether it is a caller.
        var lr: GaugeTrace.Frame?
    }

    /// Per target image (process image).
    final class Target {
        let image: GuestImageInstance
        var threads: [UInt64: (kind: ThreadContext.Kind, first: UInt64)] = [:]
        var resolved: [UInt64: GaugeTrace.Frame] = [:]
        init(image: GuestImageInstance) { self.image = image }
    }

    private var images: [ImageInfo] = []
    private var imageIndex: [String: Int] = [:]
    private var samples: [RawSample] = []
    private var targets: [ObjectIdentifier: Target] = [:]
    private var processes: [Int32: (name: String, path: String, target: Bool)] = [:]
    private var threadInfo: [UInt64: (pid: Int32, kind: ThreadContext.Kind)] = [:]
    private var presents: [UInt64] = []
    private var counter0: UInt64 = 0
    private var frequency: UInt64 = 1
    private var host0: UInt64 = 0
    private var started = false
    private var startDate = Date()
    private var lastTime: UInt64 = 0
    private var kernelImage = -1
    private var unresolved = 0
    /// Sampler cost: total ns spent per tick and ticks with samples.
    private var tickNs: UInt64 = 0
    private var ticks: UInt64 = 0
    private var sampleCount: UInt64 = 0
    /// Samples taken by kicking a vCPU, and the vCPU threads' time for them.
    private var kickedSamples: UInt64 = 0
    private var vcpuSampleNs: UInt64 = 0
    private weak var cacheSource: SharedCacheIndex?

    // MARK: Start and stop

    func start(launcher: VMMLauncher) {
        signal(SIGPIPE, SIG_IGN)
        if let s = signpostsHostPath { try? FileManager.default.removeItem(atPath: s) }
        // A plain stop signal (no stop snapshot; a display server, started
        // later, replaces this with its own handling) still writes the trace.
        if SnapshotSupport.shared?.handlesStopSignals != true {
            for sig in [SIGINT, SIGTERM, SIGHUP] {
                let previous = signal(sig, gaugeStopSignalHandler)
                if unsafeBitCast(previous, to: Int.self) != unsafeBitCast(SIG_DFL, to: Int.self) { signal(sig, previous) } else { ownSignals.append(sig) }
            }
        }
        let t = Thread { [self] in run(launcher: launcher) }
        t.name = "ycode gauge sampler"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        stderrLine("ycode-simd: gauge: recording \(appExecutable ?? "the launched app") at \(options.rate) Hz to \(options.path)")
    }

    private func isTarget(_ image: GuestImageInstance) -> Bool {
        let name = (image.record.executable as NSString).lastPathComponent
        if options.processes.contains(name) { return true }
        if let pid = launchedPID(), image.pid == pid { return true }
        if let exe = appExecutable, name == exe, image.record.executable.contains(".app/") { return true }
        return false
    }

    private func run(launcher: VMMLauncher) {
        let interval = UInt64(1_000_000_000 / max(10, min(10_000, options.rate)))
        var next = monotonicNanoseconds()
        var refreshAt: UInt64 = 0
        var live: [Target] = []
        var everSeen = false
        var firstTargetAt: UInt64 = 0
        let frames = frameRecordPath.map { FrameRecordReader(path: $0) }
        var lastFrame = frames?.read()
        while !finished.load(ordering: .acquiring) {
            let now = monotonicNanoseconds()
            let sig = GaugeStopSignal.received.load(ordering: .relaxed)
            if sig != 0 {
                finish(reason: "signal \(sig)")
                return
            }
            if now >= refreshAt {
                refreshAt = now + 20_000_000
                let list = launcher.snapshotLiveImages.filter(isTarget)
                live = list.map { img in
                    let id = ObjectIdentifier(img)
                    if let t = targets[id] { return t }
                    let t = Target(image: img)
                    targets[id] = t
                    processes[img.pid] = ((img.record.executable as NSString).lastPathComponent, img.record.executable, true)
                    return t
                }
                if !live.isEmpty && !everSeen {
                    everSeen = true
                    firstTargetAt = now
                    beginClock(live[0].image)
                    stderrLine("ycode-simd: gauge: target pid \(live[0].image.pid) (\((live[0].image.record.executable as NSString).lastPathComponent)) started")
                }
                if everSeen && live.isEmpty {
                    finish(reason: "the target ended")
                    return
                }
            }
            if let s = options.seconds, everSeen, Double(now &- firstTargetAt) / 1e9 >= s {
                finish(reason: "--profile-seconds")
                return
            }
            if !live.isEmpty {
                let began = monotonicNanoseconds()
                for t in live { sample(t) }
                if let r = frames?.read(), r != lastFrame {
                    lastFrame = r
                    presents.append(monotonicNanoseconds() &- host0)
                }
                tickNs &+= monotonicNanoseconds() &- began
                ticks &+= 1
            }
            next &+= interval
            let after = monotonicNanoseconds()
            if next > after {
                let wait = next - after
                var ts = timespec(tv_sec: Int(wait / 1_000_000_000), tv_nsec: Int(wait % 1_000_000_000))
                nanosleep(&ts, nil)
            } else if after - next > 50 * interval {
                next = after // fell far behind (host load): do not burst
            }
        }
    }

    private func beginClock(_ image: GuestImageInstance) {
        counter0 = image.kernel.counter()
        frequency = max(1, image.kernel.counterFrequency)
        host0 = monotonicNanoseconds()
        startDate = Date()
        started = true
        cacheSource = image.images.cache
    }

    private func now(_ image: GuestImageInstance) -> UInt64 {
        let c = image.kernel.counter()
        guard c > counter0 else { return 0 }
        let d = c - counter0
        return d / frequency * 1_000_000_000 + d % frequency * 1_000_000_000 / frequency
    }

    // MARK: Sampling

    private func sample(_ t: Target) {
        let image = t.image
        let workers = image.pool.activeWorkers()
        var pending: [(VCPUPool.Worker, ThreadContext, UInt64)] = []
        let time = now(image)
        lastTime = max(lastTime, time)
        for w in workers {
            guard let ctx = w.context as? ThreadContext, ctx.isAlive else { continue }
            if t.threads[ctx.threadID] == nil {
                t.threads[ctx.threadID] = (ctx.kind, time)
                threadInfo[ctx.threadID] = (image.pid, ctx.kind)
            }
            if w.inHandler.load(ordering: .relaxed) {
                // In the kernel: the registers saved at the trap's entry.
                let svc = w.lastTrapKind.load(ordering: .relaxed) == TrapFrame.Kind.svc.rawValue
                let trap = Int64(bitPattern: w.lastTrapX16.load(ordering: .relaxed))
                let blocked = ctx.blockedInKernel
                let state: GaugeTrace.SampleState = !blocked ? .kernel : (svc && (trap == -31 || trap == -47) ? .idle : .blocked)
                var frames: [GaugeTrace.Frame] = []
                var lr: GaugeTrace.Frame?
                if !blocked || ctx.kind == .main, let entry = ctx.entryFrame {
                    let chain = readChain(image.space, fp: entry.x[29])
                    frames = chain.reversed().map { resolve(t, $0) }
                    lr = resolve(t, entry.x[30])
                    frames.append(resolve(t, entry.elr))
                }
                frames.append(kernelFrame(svc ? trap : -1000))
                samples.append(RawSample(time: time, tid: ctx.threadID, pid: image.pid, state: state, frames: frames, lr: lr))
                sampleCount &+= 1
            } else {
                image.pool.kickForSample(w)
                pending.append((w, ctx, w.sampleCount.load(ordering: .relaxed)))
            }
        }
        // The kicked vCPUs answer within microseconds (a busy host: longer).
        let deadline = monotonicNanoseconds() + 3_000_000
        while !pending.isEmpty && monotonicNanoseconds() < deadline {
            pending.removeAll { w, ctx, count in
                guard w.sampleCount.load(ordering: .acquiring) != count else { return false }
                let pstate = w.samplePSTATE.load(ordering: .relaxed)
                let el1 = pstate & 0xC != 0
                let pc = el1 ? w.sampleELR1.load(ordering: .relaxed) : w.samplePC.load(ordering: .relaxed)
                var frames = w.sampleStack.reversed().map { resolve(t, $0) }
                frames.append(resolve(t, pc))
                if el1 { frames.append(kernelFrame(-2000)) }
                let lr = el1 ? nil : resolve(t, w.sampleLR.load(ordering: .relaxed))
                samples.append(RawSample(time: time, tid: ctx.threadID, pid: image.pid, state: el1 ? .kernel : .user, frames: frames, lr: lr))
                sampleCount &+= 1
                kickedSamples &+= 1
                vcpuSampleNs &+= w.sampleCostNanoseconds.load(ordering: .relaxed)
                return true
            }
            if !pending.isEmpty { sched_yield() }
        }
        if !pending.isEmpty { unresolved += pending.count }
    }

    /// Up to 128 return addresses from a frame pointer (AAPCS64 frame records).
    private func readChain(_ space: GuestAddressSpace, fp start: UInt64) -> [UInt64] {
        var out: [UInt64] = []
        var fp = start
        for _ in 0..<128 {
            guard fp != 0, fp & 7 == 0, let raw = try? space.read(va: fp, count: 16, checkingEL0Access: true) else { break }
            func word(_ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(raw[o + $1]) << (8 * UInt64($1)) } }
            let ra = word(8)
            if ra == 0 { break }
            out.append(ra & 0x0000_FFFF_FFFF_FFFF)
            let next = word(0)
            guard next > fp else { break }
            fp = next
        }
        return out
    }

    // MARK: Images

    private func registerImage(_ info: ImageInfo) -> Int {
        let key = info.guestPath + "@" + String(info.base, radix: 16)
        if let i = imageIndex[key] {
            images[i].low = min(images[i].low, info.low)
            images[i].high = max(images[i].high, info.high)
            return i
        }
        images.append(info)
        imageIndex[key] = images.count - 1
        return images.count - 1
    }

    /// The leaf frame of a sample in the kernel: the trap's name.
    private func kernelFrame(_ trap: Int64) -> GaugeTrace.Frame {
        if kernelImage < 0 {
            kernelImage = registerImage(ImageInfo(name: "Ycode kernel", guestPath: "Ycode kernel", kind: .kernel, base: 0, low: 0, high: 0))
        }
        return GaugeTrace.Frame(image: kernelImage, offset: UInt64(bitPattern: trap &+ 0x10000))
    }

    private func kind(guestPath p: String, hostPath: String?) -> GaugeTrace.ImageKind {
        if p.hasSuffix(ImageMap.hostLibrarySuffix) || p.contains("/Library/Ycode/") || (hostPath ?? "").contains("/Library/Ycode/") { return .ycode }
        if p.contains(".app/") { return .app }
        if p.hasSuffix("/dyld_sim") || p.hasSuffix("/dyld") { return .runtime }
        return .system
    }

    /// Places an address in an image (cached per target).
    private func resolve(_ t: Target, _ address: UInt64) -> GaugeTrace.Frame {
        if let f = t.resolved[address] { return f }
        let image = t.image
        let map = image.images
        var result: GaugeTrace.Frame?
        if let g = map.fixed.first(where: { address >= $0.start && address < $0.end }) {
            let host = image.space.file(at: address)?.hostPath ?? (try? image.fileSystem.hostPathForExec(g.name))?.hostPath
            let isYcode = g.name.hasPrefix("ycode ")
            let i = registerImage(ImageInfo(name: (g.name as NSString).lastPathComponent, guestPath: g.name, hostPath: isYcode ? nil : host,
                                            kind: isYcode ? .ycode : kind(guestPath: g.name, hostPath: host), base: g.base, low: g.start, high: g.end))
            result = GaugeTrace.Frame(image: i, offset: address &- g.base)
        } else if address >= VMLayout.sharedRegionBase, address < VMLayout.sharedRegionEnd {
            if let list = map.cache.cacheImagesIfReady() {
                let header = address &- map.cacheDelta
                var low = 0, high = list.count
                while low < high {
                    let mid = (low + high) / 2
                    if list[mid].start <= header { low = mid + 1 } else { high = mid }
                }
                if low > 0, header < list[low - 1].end {
                    let g = list[low - 1]
                    let i = registerImage(ImageInfo(name: (g.name as NSString).lastPathComponent, guestPath: g.name, kind: .system,
                                                    base: g.base, low: g.start, high: g.end, cacheImage: g.name))
                    result = GaugeTrace.Frame(image: i, offset: header &- g.base)
                }
            } else {
                // The cache's image list is still being built: try again next time.
                return GaugeTrace.Frame(image: -1, offset: address)
            }
        } else if let file = image.space.file(at: address), let region = image.space.region(containing: address),
                  case let .file(_, fileOffset, _) = region.backing {
            let base = region.va &- fileOffset
            let guest = file.guestPath
            let i = registerImage(ImageInfo(name: (guest as NSString).lastPathComponent, guestPath: guest, hostPath: file.hostPath,
                                            kind: kind(guestPath: guest, hostPath: file.hostPath), base: base, low: region.va, high: region.end))
            result = GaugeTrace.Frame(image: i, offset: address &- base)
        }
        let f = result ?? GaugeTrace.Frame(image: -1, offset: address)
        t.resolved[address] = f
        return f
    }

    // MARK: The trace

    /// Writes the trace once (any thread; later calls do nothing).
    func finish(reason: String) {
        guard !finished.exchange(true, ordering: .acquiringAndReleasing) else { return }
        if let t = thread, t !== Thread.current {
            // Let the sampler leave its tick.
            usleep(20_000)
        }
        lock.withLock { write(reason: reason) }
        // Signals go back to their default action; one that arrived meanwhile ends the process now.
        for sig in ownSignals {
            signal(sig, SIG_DFL)
            if GaugeStopSignal.received.load(ordering: .relaxed) == sig { _exit(128 + sig) }
        }
    }

    private func write(reason: String) {
        let began = monotonicNanoseconds()
        guard started else {
            stderrLine("ycode-simd: gauge: no trace: the target never ran (\(reason))")
            return
        }
        let intervalNs = UInt64(1_000_000_000 / max(10, min(10_000, options.rate)))
        var notes: [String] = []
        if unresolved > 0 { notes.append("\(unresolved) kicked vCPUs did not answer within 3 ms (samples dropped)") }
        if sampleCount > 0 {
            notes.append(String(format: "recorder cost: %.1f µs of the sampler thread per sample; %.1f µs of the vCPU's thread per sample of a running thread",
                                Double(tickNs) / Double(sampleCount) / 1000, kickedSamples > 0 ? Double(vcpuSampleNs) / Double(kickedSamples) / 1000 : 0))
        }
        let duration = max(lastTime &+ intervalNs, monotonicNanoseconds() &- host0)
        var b = GaugeTraceBuilder(recording: GaugeTrace.Recording(
            target: "ycode-simulator", recorder: "ycode-simd gauge 1", host: "Linux arm64 (KVM)", command: command,
            device: deviceDescription, startDate: startDate, durationNs: duration, sampleIntervalNs: intervalNs,
            hangThresholdNs: UInt64(options.hangMilliseconds) * 1_000_000, clock: "guest-counter", notes: notes))

        // Symbols and UUIDs, image by image.
        var used: [Int: Set<UInt64>] = [:]
        for s in samples {
            for f in s.frames where f.image >= 0 { used[f.image, default: []].insert(f.offset) }
            if let l = s.lr, l.image >= 0 { used[l.image, default: []].insert(l.offset) }
        }
        let cache = cacheSource?.sharedCacheForSymbols()
        var traceImages: [GaugeTrace.Image] = []
        for (i, info) in images.enumerated() {
            var img = GaugeTrace.Image(id: i, name: info.name, path: info.hostPath ?? info.guestPath, kind: info.kind,
                                       base: info.base, size: info.high &- info.low)
            let offsets = used[i] ?? []
            if info.kind == .kernel {
                img.symbols = offsets.sorted().map { o in
                    let n = Int64(bitPattern: o) &- 0x10000
                    let name = n == -1000 ? "page fault" : n == -2000 ? "exception (EL1 shim)"
                        : n < 0 ? TrapNames.mach(Int(n)).name : TrapNames.bsd(Int(n)).name
                    return GaugeTrace.Symbol(start: o, end: o + 1, name: name)
                }
            } else if let table = symbolTable(info, cache: cache, uuid: &img.uuid) {
                var syms: [UInt64: GaugeTrace.Symbol] = [:]
                for o in offsets {
                    for q in [o, o &- 1] {
                        if let fn = table.function(containing: table.textAddress &+ q) {
                            let start = fn.address &- table.textAddress
                            syms[start] = GaugeTrace.Symbol(start: start, end: start &+ fn.size, name: fn.name)
                        }
                    }
                }
                img.symbols = syms.values.sorted { $0.start < $1.start }
            }
            if info.cacheImage != nil { img.path = info.guestPath }
            traceImages.append(img)
        }
        b.update { $0.images = traceImages }

        func functionKey(_ f: GaugeTrace.Frame) -> (Int, UInt64)? {
            guard f.image >= 0, f.image < traceImages.count, let s = traceImages[f.image].symbol(at: f.offset) else { return nil }
            return (f.image, s.start)
        }
        for s in samples.sorted(by: { $0.time < $1.time }) {
            var frames = s.frames
            // LR is a caller unless it repeats the chain's first return
            // address or lies in the function of the PC (the frame was
            // already set up, LR is stale).
            if let lr = s.lr, s.state == .user || s.state == .kernel, let leafIndex = frames.lastIndex(where: { $0.image != kernelImage }) {
                let leaf = frames[leafIndex]
                let callerFromChain = leafIndex > 0 ? frames[leafIndex - 1] : nil
                let sameAsChain = callerFromChain.map { $0 == lr } ?? false
                let sameFunction = functionKey(lr).map { k in functionKey(leaf).map { $0 == k } ?? false } ?? false
                if !sameAsChain && !sameFunction && lr.offset != 0 { frames.insert(lr, at: leafIndex) }
            }
            b.addSample(time: s.time, thread: s.tid, state: s.state, frames: frames)
        }
        let signposts = readSignposts()
        let gpu = readMetalTrace()
        b.update { tr in
            tr.processes = processes.sorted { $0.key < $1.key }.map { GaugeTrace.Process(pid: Int($0.key), name: $0.value.name, path: $0.value.path, isTarget: $0.value.target) }
            tr.threads = threadInfo.sorted { $0.key < $1.key }.map { id, v in
                let (kind, name): (String, String)
                switch v.kind {
                case .main: (kind, name) = ("main", "Main Thread")
                case .pthread: (kind, name) = ("pthread", "Thread 0x" + String(id, radix: 16))
                case .workqueue: (kind, name) = ("workqueue", "Dispatch Worker 0x" + String(id, radix: 16))
                }
                return GaugeTrace.Thread(id: id, pid: Int(v.pid), name: name, isMain: v.kind == .main, kind: kind)
            }
            tr.signposts = signposts
            tr.presents = presents
            tr.gpu = gpu
        }
        var trace = b.finish()
        trace.hangs = GaugeTimeline.hangs(trace)
        do {
            try GaugeTraceCodec.write(trace, to: URL(fileURLWithPath: options.path))
            let perSample = sampleCount > 0 ? Double(tickNs) / Double(sampleCount) / 1000 : 0
            stderrLine(String(format: "ycode-simd: gauge: wrote %@ (%@): %d samples, %d threads, %d signposts, %d presents, %d GPU command buffers; "
                              + "sampler %.1f µs per sample, %.1f µs per tick; vCPU %.1f µs per kicked sample (%d); written in %d ms",
                              options.path, reason, trace.samples.count, trace.threads.count, trace.signposts.count, trace.presents.count,
                              trace.gpu.count, perSample, ticks > 0 ? Double(tickNs) / Double(ticks) / 1000 : 0,
                              kickedSamples > 0 ? Double(vcpuSampleNs) / Double(kickedSamples) / 1000 : 0, Int(kickedSamples),
                              Int((monotonicNanoseconds() &- began) / 1_000_000)))
        } catch {
            stderrLine("ycode-simd: gauge: cannot write \(options.path): \(error)")
        }
    }

    private func symbolTable(_ info: ImageInfo, cache: SharedCache?, uuid: inout String?) -> SymbolTable? {
        if let name = info.cacheImage, let cache, let entry = cache.image(path: name) {
            uuid = (try? cache.machO(for: entry))?.uuid?.uuidString
            return try? SymbolTable(cache: cache, image: entry)
        }
        guard let host = info.hostPath, let reader = try? ByteReader(contentsOf: URL(fileURLWithPath: host)) else { return nil }
        for (offset, image) in GaugeSymbolicator.machOSlices(reader) where image.isArm64 {
            uuid = image.uuid?.uuidString
            return try? SymbolTable(file: reader, at: offset)
        }
        return nil
    }

    /// The agent's records (profiler.md §3.1): "YGS1", u16 length, u8 type,
    /// u8 0, u64 time, u64 id, u64 thread, four NUL-terminated strings.
    private func readSignposts() -> [GaugeTrace.Signpost] {
        guard let path = signpostsHostPath, let data = FileManager.default.contents(atPath: path) else { return [] }
        let b = [UInt8](data)
        var events: [GaugeTimeline.SignpostEvent] = []
        var p = 0
        func u64(_ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) } }
        while p + 32 <= b.count {
            guard b[p] == 0x59, b[p + 1] == 0x47, b[p + 2] == 0x53, b[p + 3] == 0x31 else { break }
            let length = Int(b[p + 4]) | Int(b[p + 5]) << 8
            guard length >= 32, p + length <= b.count, let kind = GaugeTimeline.SignpostEvent.Kind(rawValue: b[p + 6]) else { break }
            let counter = u64(p + 8)
            var strings: [String] = []
            var q = p + 32
            while strings.count < 4, q < p + length {
                let end = b[q..<(p + length)].firstIndex(of: 0) ?? (p + length)
                strings.append(String(decoding: b[q..<end], as: UTF8.self))
                q = end + 1
            }
            while strings.count < 4 { strings.append("") }
            let d = counter > counter0 ? counter - counter0 : 0
            let time = d / frequency * 1_000_000_000 + d % frequency * 1_000_000_000 / frequency
            events.append(.init(time: time, kind: kind, id: u64(p + 16), thread: u64(p + 24), subsystem: strings[0],
                                category: strings[1], name: strings[2], message: strings[3]))
            p += length
        }
        return GaugeTimeline.intervals(events, recordingEnd: lastTime)
    }

    /// Command buffers of the Metal trace (stage8-contract.md §14.1) during the recording.
    private func readMetalTrace() -> [GaugeTrace.GPUWork] {
        guard let path = metalTracePath, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [GaugeTrace.GPUWork] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: " ")
            guard f.count >= 11, let pid = Int(f[0]), let submitted = UInt64(f[6]), let done = UInt64(f[9]), submitted >= host0 else { continue }
            let gpu = (UInt64(f[8]) ?? 0) >= (UInt64(f[7]) ?? 0) ? (UInt64(f[8]) ?? 0) - (UInt64(f[7]) ?? 0) : 0
            out.append(.init(pid: pid, process: "Metal client \(pid)", submit: submitted - host0, end: max(done, submitted) - host0, gpuNs: gpu))
        }
        return out
    }
}
#endif
