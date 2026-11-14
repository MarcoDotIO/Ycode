import Foundation
#if os(Linux)
import Glibc

// YCODE_IDE_SAMPLE=<file>: a sampling profiler for the main thread, for
// measuring the Linux IDE where `perf` is not available to the user. Every
// `interval` a helper thread signals the main thread, whose handler records
// its return addresses; at exit the samples and the process's memory map
// are written to <file> (one sample per line, hexadecimal addresses), for
// `llvm-symbolizer` offline. Off unless the variable is set.
enum MainThreadSampler {
    static let depth = 48
    static let capacity = 200_000
    nonisolated(unsafe) static var buffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    nonisolated(unsafe) static var counts: UnsafeMutablePointer<Int32>?
    nonisolated(unsafe) static var next = 0
    nonisolated(unsafe) static var mainThread = pthread_self()
    nonisolated(unsafe) static var running = false
    nonisolated(unsafe) static var path = ""
    typealias Backtrace = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, Int32) -> Int32
    /// glibc's `backtrace` (execinfo.h is not in the Glibc module).
    nonisolated(unsafe) static var backtrace: Backtrace?

    /// Starts sampling when the variable is set.
    static func startIfAsked() {
        guard let p = ProcessInfo.processInfo.environment["YCODE_IDE_SAMPLE"], !running else { return }
        path = p
        guard let sym = dlsym(nil, "backtrace") else { return }
        backtrace = unsafeBitCast(sym, to: Backtrace.self)
        buffer = .allocate(capacity: depth * capacity)
        counts = .allocate(capacity: capacity)
        mainThread = pthread_self()
        running = true
        // Warm up backtrace (its first call loads libgcc).
        var warm = [UnsafeMutableRawPointer?](repeating: nil, count: 4)
        _ = backtrace?(&warm, 4)
        signal(SIGPROF) { _ in
            let i = MainThreadSampler.next
            guard i < MainThreadSampler.capacity, let b = MainThreadSampler.buffer, let c = MainThreadSampler.counts,
                  let trace = MainThreadSampler.backtrace else { return }
            c[i] = trace(b + i * MainThreadSampler.depth, Int32(MainThreadSampler.depth))
            MainThreadSampler.next = i + 1
        }
        let interval = Double(ProcessInfo.processInfo.environment["YCODE_IDE_SAMPLE_MS"] ?? "") ?? 2
        Thread.detachNewThread {
            while MainThreadSampler.running {
                usleep(useconds_t(interval * 1000))
                pthread_kill(MainThreadSampler.mainThread, SIGPROF)
            }
        }
        atexit { MainThreadSampler.write() }
    }

    /// Stops sampling and writes the samples.
    static func stop() {
        running = false
        usleep(10_000)
        write()
    }

    /// Writes the samples and the memory map.
    static func write() {
        running = false
        guard let b = buffer, let c = counts else { return }
        var out = "maps\n" + ((try? String(contentsOfFile: "/proc/self/maps", encoding: .utf8)) ?? "") + "samples \(next)\n"
        for i in 0..<next {
            var line: [String] = []
            for k in 0..<Int(c[i]) { line.append(String(UInt(bitPattern: b[i * depth + k]), radix: 16)) }
            out += line.joined(separator: " ") + "\n"
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
