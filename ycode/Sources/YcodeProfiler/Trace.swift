import Foundation

/// A Gauge trace: one recording of a target (`specs/ide/profiler.md` §4.1).
/// Times are nanoseconds since the recording began.
public struct GaugeTrace: Sendable, Equatable {
    public static let format = "ycode-gauge-trace"
    public static let version = 1

    public struct Recording: Sendable, Equatable {
        /// `ycode-simulator`, `linux` or `macos`.
        public var target: String
        public var recorder: String
        public var host: String
        public var command: String
        public var device: String
        public var startDate: Date
        public var durationNs: UInt64
        public var sampleIntervalNs: UInt64
        public var hangThresholdNs: UInt64
        /// `guest-counter` or `monotonic`.
        public var clock: String
        public var notes: [String]

        public init(target: String, recorder: String = "", host: String = "", command: String = "", device: String = "",
                    startDate: Date = Date(timeIntervalSince1970: 0), durationNs: UInt64 = 0, sampleIntervalNs: UInt64 = 1_000_000,
                    hangThresholdNs: UInt64 = 250_000_000, clock: String = "monotonic", notes: [String] = []) {
            self.target = target
            self.recorder = recorder
            self.host = host
            self.command = command
            self.device = device
            self.startDate = startDate
            self.durationNs = durationNs
            self.sampleIntervalNs = sampleIntervalNs
            self.hangThresholdNs = hangThresholdNs
            self.clock = clock
            self.notes = notes
        }
    }

    public struct Process: Sendable, Equatable {
        public var pid: Int
        public var name: String
        public var path: String
        public var isTarget: Bool
        public init(pid: Int, name: String, path: String = "", isTarget: Bool = true) {
            self.pid = pid
            self.name = name
            self.path = path
            self.isTarget = isTarget
        }
    }

    public struct Thread: Sendable, Equatable {
        public var id: UInt64
        public var pid: Int
        public var name: String
        public var isMain: Bool
        /// `main`, `pthread`, `workqueue` or `thread`.
        public var kind: String
        public init(id: UInt64, pid: Int, name: String = "", isMain: Bool = false, kind: String = "thread") {
            self.id = id
            self.pid = pid
            self.name = name
            self.isMain = isMain
            self.kind = kind
        }
    }

    public enum ImageKind: String, Sendable, CaseIterable {
        case app, system, runtime, ycode, kernel, unknown

        /// Hidden by "Hide System Libraries".
        public var isSystem: Bool { self != .app && self != .unknown }
    }

    /// A function: offsets from the image's base, `end` exclusive.
    public struct Symbol: Sendable, Equatable {
        public var start: UInt64
        public var end: UInt64
        public var name: String
        public init(start: UInt64, end: UInt64, name: String) {
            self.start = start
            self.end = end
            self.name = name
        }
    }

    public struct LineEntry: Sendable, Equatable {
        public var offset: UInt64
        public var file: Int
        public var line: Int
        public init(offset: UInt64, file: Int, line: Int) {
            self.offset = offset
            self.file = file
            self.line = line
        }
    }

    public struct Image: Sendable, Equatable {
        public var id: Int
        public var name: String
        public var path: String
        public var uuid: String?
        public var kind: ImageKind
        public var base: UInt64
        public var size: UInt64
        /// Sorted by start.
        public var symbols: [Symbol]
        public var files: [String]
        /// Sorted by offset: the line of each frame offset (exact entries,
        /// written by symbolication for the offsets the trace uses).
        public var lines: [LineEntry]

        public init(id: Int, name: String, path: String = "", uuid: String? = nil, kind: ImageKind = .unknown,
                    base: UInt64 = 0, size: UInt64 = 0, symbols: [Symbol] = [], files: [String] = [], lines: [LineEntry] = []) {
            self.id = id
            self.name = name
            self.path = path
            self.uuid = uuid
            self.kind = kind
            self.base = base
            self.size = size
            self.symbols = symbols
            self.files = files
            self.lines = lines
        }

        /// The symbol with `start ≤ offset < end`.
        public func symbolIndex(at offset: UInt64) -> Int? {
            var low = 0, high = symbols.count
            while low < high {
                let mid = (low + high) / 2
                if symbols[mid].start <= offset { low = mid + 1 } else { high = mid }
            }
            guard low > 0, offset < symbols[low - 1].end else { return nil }
            return low - 1
        }

        public func symbol(at offset: UInt64) -> Symbol? { symbolIndex(at: offset).map { symbols[$0] } }

        /// The line entry for exactly this offset, else the nearest one at a
        /// lower offset inside the same symbol.
        public func line(at offset: UInt64) -> (file: String, line: Int)? {
            var low = 0, high = lines.count
            while low < high {
                let mid = (low + high) / 2
                if lines[mid].offset <= offset { low = mid + 1 } else { high = mid }
            }
            guard low > 0 else { return nil }
            let e = lines[low - 1]
            if e.offset != offset, let s = symbol(at: offset), e.offset < s.start { return nil }
            guard files.indices.contains(e.file) else { return nil }
            return (files[e.file], e.line)
        }
    }

    /// An address: an image and an offset from its base; image −1 holds an
    /// absolute address.
    public struct Frame: Sendable, Hashable {
        public var image: Int
        public var offset: UInt64
        public init(image: Int, offset: UInt64) {
            self.image = image
            self.offset = offset
        }
    }

    /// A call chain: `prefix` (−1: none) plus one more (inner) frame.
    public struct Stack: Sendable, Hashable {
        public var prefix: Int
        public var frame: Int
        public init(prefix: Int, frame: Int) {
            self.prefix = prefix
            self.frame = frame
        }
    }

    public enum SampleState: String, Sendable, CaseIterable {
        case user, kernel, blocked, idle
        public var isCPU: Bool { self == .user || self == .kernel }
    }

    /// Columnar samples (§4.1).
    public struct Samples: Sendable, Equatable {
        public var time: [UInt64] = []
        public var thread: [UInt64] = []
        public var stack: [Int] = []
        public var state: [SampleState] = []
        public init() {}
        public var count: Int { time.count }
        public mutating func append(time t: UInt64, thread: UInt64, stack: Int, state: SampleState) {
            time.append(t)
            self.thread.append(thread)
            self.stack.append(stack)
            self.state.append(state)
        }
    }

    public struct Signpost: Sendable, Equatable {
        public enum Kind: String, Sendable { case interval, event }
        public var name: String
        public var subsystem: String
        public var category: String
        public var id: UInt64
        public var thread: UInt64
        public var begin: UInt64
        public var end: UInt64?
        public var kind: Kind
        public var message: String
        /// `open` (no end before the recording ended), `unmatched` (an end without a begin).
        public var flags: [String]

        public init(name: String, subsystem: String = "", category: String = "", id: UInt64 = 0, thread: UInt64 = 0,
                    begin: UInt64, end: UInt64? = nil, kind: Kind = .interval, message: String = "", flags: [String] = []) {
            self.name = name
            self.subsystem = subsystem
            self.category = category
            self.id = id
            self.thread = thread
            self.begin = begin
            self.end = end
            self.kind = kind
            self.message = message
            self.flags = flags
        }

        public var duration: UInt64 { end.map { $0 &- begin } ?? 0 }
    }

    public struct Hang: Sendable, Equatable {
        public var thread: UInt64
        public var begin: UInt64
        public var end: UInt64
        public init(thread: UInt64, begin: UInt64, end: UInt64) {
            self.thread = thread
            self.begin = begin
            self.end = end
        }
        public var duration: UInt64 { end &- begin }
    }

    public struct GPUWork: Sendable, Equatable {
        public var pid: Int
        public var process: String
        public var submit: UInt64
        public var end: UInt64
        public var gpuNs: UInt64
        public init(pid: Int, process: String, submit: UInt64, end: UInt64, gpuNs: UInt64) {
            self.pid = pid
            self.process = process
            self.submit = submit
            self.end = end
            self.gpuNs = gpuNs
        }
    }

    public var recording: Recording
    public var processes: [Process] = []
    public var threads: [Thread] = []
    public var images: [Image] = []
    public var frames: [Frame] = []
    public var stacks: [Stack] = []
    public var samples = Samples()
    public var signposts: [Signpost] = []
    public var hangs: [Hang] = []
    public var presents: [UInt64] = []
    public var gpu: [GPUWork] = []

    public init(recording: Recording) { self.recording = recording }

    // MARK: Lookups

    public func image(_ id: Int) -> Image? { images.indices.contains(id) && images[id].id == id ? images[id] : images.first { $0.id == id } }

    public func thread(_ id: UInt64) -> Thread? { threads.first { $0.id == id } }

    /// The main thread of the target process (the first thread marked main).
    public var mainThread: Thread? {
        let targets = Set(processes.filter(\.isTarget).map(\.pid))
        return threads.first { $0.isMain && (targets.isEmpty || targets.contains($0.pid)) } ?? threads.first { $0.isMain }
    }

    /// Frame ids of a stack, outermost first.
    public func frameIDs(ofStack stack: Int) -> [Int] {
        var out: [Int] = []
        var s = stack
        var guardCount = 0
        while s >= 0, s < stacks.count, guardCount < 100_000 {
            out.append(stacks[s].frame)
            s = stacks[s].prefix
            guardCount += 1
        }
        return out.reversed()
    }

    /// A display name for a thread: its name, else "Main Thread" or
    /// "Thread <id>", with the process name when the trace has several.
    public func threadTitle(_ id: UInt64) -> String {
        guard let t = thread(id) else { return "Thread \(id)" }
        var title = t.name.isEmpty ? (t.isMain ? "Main Thread" : "Thread \(t.id)") : t.name
        if t.isMain && !t.name.isEmpty && !t.name.lowercased().contains("main") { title = "Main Thread (\(t.name))" }
        if processes.count > 1, let p = processes.first(where: { $0.pid == t.pid }) { title += " — \(p.name) [\(p.pid)]" }
        return title + "  0x\(String(t.id, radix: 16))"
    }
}

/// Builds a trace: interns frames and stacks.
public struct GaugeTraceBuilder: Sendable {
    public private(set) var trace: GaugeTrace
    private var frameIndex: [GaugeTrace.Frame: Int] = [:]
    private var stackIndex: [GaugeTrace.Stack: Int] = [:]

    public init(recording: GaugeTrace.Recording) { trace = GaugeTrace(recording: recording) }

    public mutating func frameID(_ f: GaugeTrace.Frame) -> Int {
        if let i = frameIndex[f] { return i }
        let i = trace.frames.count
        trace.frames.append(f)
        frameIndex[f] = i
        return i
    }

    /// The stack id of a chain of frame ids, outermost first (−1: empty).
    public mutating func stackID(frameIDs: [Int]) -> Int {
        var s = -1
        for f in frameIDs {
            let key = GaugeTrace.Stack(prefix: s, frame: f)
            if let i = stackIndex[key] { s = i; continue }
            let i = trace.stacks.count
            trace.stacks.append(key)
            stackIndex[key] = i
            s = i
        }
        return s
    }

    /// The stack id of frames given outermost first.
    public mutating func stackID(frames: [GaugeTrace.Frame]) -> Int {
        stackID(frameIDs: frames.map { frameID($0) })
    }

    public mutating func addSample(time: UInt64, thread: UInt64, state: GaugeTrace.SampleState, stack: Int) {
        trace.samples.append(time: time, thread: thread, stack: stack, state: state)
    }

    public mutating func addSample(time: UInt64, thread: UInt64, state: GaugeTrace.SampleState, frames: [GaugeTrace.Frame]) {
        let s = stackID(frames: frames)
        trace.samples.append(time: time, thread: thread, stack: s, state: state)
    }

    /// Adds an image and returns its id.
    @discardableResult
    public mutating func addImage(_ image: GaugeTrace.Image) -> Int {
        var i = image
        i.id = trace.images.count
        i.symbols.sort { $0.start < $1.start }
        i.lines.sort { $0.offset < $1.offset }
        trace.images.append(i)
        return i.id
    }

    public mutating func update(_ body: (inout GaugeTrace) -> Void) { body(&trace) }

    /// Rewrites absolute frames (image −1) through `resolve`; frames it
    /// cannot place stay absolute. Distinct frames stay distinct as long as
    /// `resolve` maps distinct addresses to distinct (image, offset) pairs.
    public mutating func resolveAbsoluteFrames(_ resolve: (UInt64) -> GaugeTrace.Frame?) {
        for i in trace.frames.indices where trace.frames[i].image < 0 {
            if let f = resolve(trace.frames[i].offset) { trace.frames[i] = f }
        }
        frameIndex = Dictionary(trace.frames.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func finish() -> GaugeTrace { trace }
}
