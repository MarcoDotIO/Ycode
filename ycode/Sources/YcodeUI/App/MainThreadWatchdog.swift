import Darwin
import Foundation

/// A debug-build watchdog for main-thread stalls. A background thread
/// posts a small block to the main queue every few milliseconds; when the
/// main thread has not run it after `threshold`, the watchdog suspends the
/// main thread for a moment, records its stack (frame-pointer walk), and,
/// once the main thread answers, logs how long it was blocked.
///
/// Turned on with `YCODE_MAIN_THREAD_WATCHDOG=<milliseconds>` in debug
/// builds (`startIfRequested()`, called at launch). Release builds never
/// start it. The report goes to standard error, and to the file named by
/// `YCODE_MAIN_THREAD_WATCHDOG_LOG` when set.
public final class MainThreadWatchdog: @unchecked Sendable {
    /// One stall: how long the main thread did not answer, and its stack
    /// when the stall passed the threshold.
    public struct Stall: Sendable, CustomStringConvertible {
        public var milliseconds: Double
        /// The stack when the stall passed the threshold.
        public var stack: [String] { samples.first ?? [] }
        /// One stack per threshold interval while the stall lasted (at
        /// most the watchdog's `maxSamples`).
        public var samples: [[String]]
        public var description: String {
            var text = "Ycode main-thread watchdog: main thread blocked for \(Int(milliseconds.rounded())) ms\n"
            for (i, s) in samples.enumerated() {
                if samples.count > 1 { text += "  sample \(i + 1) of \(samples.count):\n" }
                text += s.map { "    \($0)\n" }.joined()
            }
            return text
        }
    }

    /// Samples kept per stall by default.
    public static let defaultMaxSamples = 8

    public let thresholdMilliseconds: Double
    private let log: @Sendable (Stall) -> Void
    private let lock = NSLock()
    private var answered = 0
    private var running = false
    private var stalls: [Stall] = []
    private var mainThread: thread_act_t = 0
    private var stackLow: UInt = 0, stackHigh: UInt = 0
    /// Frame buffer, allocated up front: nothing may allocate while the
    /// main thread is suspended (it could hold the allocator's lock).
    private let frames = UnsafeMutablePointer<UInt>.allocate(capacity: MainThreadWatchdog.maxFrames)
    private static let maxFrames = 128

    /// The watchdog started at launch, if any.
    @MainActor public private(set) static var shared: MainThreadWatchdog?

    /// Starts the watchdog when `YCODE_MAIN_THREAD_WATCHDOG` holds a
    /// threshold in milliseconds (debug builds only).
    @MainActor @discardableResult
    public static func startIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) -> MainThreadWatchdog? {
        #if DEBUG
        guard shared == nil, let ms = environment["YCODE_MAIN_THREAD_WATCHDOG"].flatMap(Double.init), ms > 0 else { return shared }
        let path = environment["YCODE_MAIN_THREAD_WATCHDOG_LOG"]
        let w = MainThreadWatchdog(thresholdMilliseconds: ms) { stall in
            let data = Data(stall.description.utf8)
            FileHandle.standardError.write(data)
            if let path, let h = FileHandle(forWritingAtPath: path) ?? {
                FileManager.default.createFile(atPath: path, contents: nil)
                return FileHandle(forWritingAtPath: path)
            }() {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            }
        }
        w.start()
        shared = w
        return w
        #else
        return nil
        #endif
    }

    /// Stacks kept per stall (one per threshold interval).
    public let maxSamples: Int

    public init(thresholdMilliseconds: Double, maxSamples: Int = MainThreadWatchdog.defaultMaxSamples, log: @escaping @Sendable (Stall) -> Void) {
        self.thresholdMilliseconds = thresholdMilliseconds
        self.maxSamples = maxSamples
        self.log = log
    }

    deinit { frames.deallocate() }

    /// Stalls seen so far.
    public var recorded: [Stall] {
        lock.lock()
        defer { lock.unlock() }
        return stalls
    }

    /// Starts watching; call on the main thread.
    @MainActor public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        running = true
        mainThread = mach_thread_self()
        let me = pthread_self()
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(me))
        stackLow = stackHigh - UInt(pthread_get_stacksize_np(me))
        let t = Thread { [self] in watch() }
        t.name = "ycode.main-thread-watchdog"
        t.qualityOfService = .userInteractive
        t.start()
    }

    /// Stops watching (the background thread ends after its current ping).
    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private func watch() {
        var ping = 0
        // Pings follow one another closely, so a stall is measured nearly
        // from its start.
        let interval = min(thresholdMilliseconds / 4, 10) / 1000
        while true {
            lock.lock()
            let live = running
            lock.unlock()
            guard live else { return }
            ping += 1
            let n = ping
            let start = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async { [self] in
                lock.lock()
                answered = n
                lock.unlock()
            }
            var samples: [[String]] = []
            while true {
                lock.lock()
                let done = answered >= n
                lock.unlock()
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                if done {
                    if elapsed >= thresholdMilliseconds {
                        let stall = Stall(milliseconds: elapsed, samples: samples)
                        lock.lock()
                        stalls.append(stall)
                        lock.unlock()
                        log(stall)
                    }
                    break
                }
                // A sample when the stall passes the threshold, then one
                // per threshold interval.
                if samples.count < maxSamples, elapsed >= thresholdMilliseconds * Double(samples.count + 1) {
                    samples.append(sampleMainThread())
                }
                Thread.sleep(forTimeInterval: interval)
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// The main thread's return addresses, symbolized.
    func sampleMainThread() -> [String] {
        let count = captureMainThreadFrames()
        return (0..<count).map { Self.symbolize(frames[$0]) }
    }

    /// Suspends the main thread, walks its frame-pointer chain into
    /// `frames`, resumes it. Allocates nothing while it is suspended.
    private func captureMainThreadFrames() -> Int {
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(mainThread) }
        var pc: UInt = 0, fp: UInt = 0, lr: UInt = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__pc); fp = UInt(state.__fp); lr = UInt(state.__lr)
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(mainThread, x86_THREAD_STATE64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__rip); fp = UInt(state.__rbp)
        #endif
        // Pointer-authentication bits are not part of the address.
        let mask: UInt = 0x0000_7FFF_FFFF_FFFF
        var n = 0
        frames[n] = pc & mask; n += 1
        if lr != 0 { frames[n] = lr & mask; n += 1 }
        while n < Self.maxFrames, fp >= stackLow, fp + 16 <= stackHigh, fp % 8 == 0 {
            let p = UnsafePointer<UInt>(bitPattern: fp)!
            let next = p[0], ret = p[1] & mask
            if ret == 0 { break }
            frames[n] = ret; n += 1
            guard next > fp else { break }
            fp = next
        }
        return n
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static let demangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle")
        .map { unsafeBitCast($0, to: Demangle.self) }

    /// "image  symbol + offset" for a return address.
    static func symbolize(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return String(format: "0x%lx", address) }
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
        guard let sname = info.dli_sname else { return String(format: "%@  0x%lx", image, address) }
        var name = String(cString: sname)
        if let demangle, let d = demangle(sname, strlen(sname), nil, nil, 0) {
            name = String(cString: d)
            free(d)
        }
        let offset = address - UInt(bitPattern: info.dli_saddr)
        return "\(image)  \(name) + \(offset)"
    }
}
