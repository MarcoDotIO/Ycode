#if os(Linux) && arch(arm64)
import CKVM
import Foundation
import Glibc
import YcodeDarwinKernel

/// Diagnostics (`YCODE_TRAP_PROFILE_STACKS=<us>`, with `YCODE_TRAP_PROFILE`):
/// every `<us>` microseconds the kernel-lock holder's host thread is asked
/// for its call stack (SIGPROF, `ckvm_stack_sample`), and the stack is
/// counted under the holder's trap. A sample whose hold ended while it was
/// taken is dropped. The table goes to `<profile path>.stacks` with the
/// trap profile's periodic dump: one line per distinct stack, "count TAB
/// trap TAB module+offset;…" (innermost first), for `llvm-symbolizer`.
final class LockStackSampler: @unchecked Sendable {
    static func startIfRequested(lock: KernelLock, profilePath: String, portLock: KernelLock? = nil) {
        guard let raw = getenv("YCODE_TRAP_PROFILE_STACKS"), let us = UInt32(String(cString: raw)), us > 0 else { return }
        guard ckvm_stack_sampler_install() == 0 else { return }
        // One sampling thread for all (the signal slot is shared).
        var samplers = [LockStackSampler(lock: lock, path: profilePath + ".stacks")]
        if let portLock {
            portLock.tracksHolder = true
            samplers.append(LockStackSampler(lock: portLock, path: profilePath + ".port-stacks"))
        }
        let all = samplers
        let thread = Thread {
            while true {
                usleep(us)
                for s in all { s.sampleOnce() }
            }
        }
        thread.name = "ycode lock stack sampler"
        thread.start()
        let dumper = Thread {
            while true {
                Thread.sleep(forTimeInterval: TrapProfile.dumpInterval)
                for s in all { s.dump() }
            }
        }
        dumper.name = "ycode lock stack dump"
        dumper.start()
    }

    private let lock: KernelLock
    private let path: String
    private let mutex = NSLock()
    private var stacks: [[UInt]: (trap: Int64, count: UInt64)] = [:]
    private var taken: UInt64 = 0
    private var dropped: UInt64 = 0

    private init(lock: KernelLock, path: String) {
        self.lock = lock
        self.path = path
    }

    private var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)

    fileprivate func sampleOnce() {
        do {
            let sequence = lock.holdSequence
            let tid = lock.holderThreadID
            let trap = lock.holderTrapKey
            guard tid != 0 else { return }
            let n = frames.withUnsafeMutableBufferPointer { ckvm_stack_sample(tid, $0.baseAddress, 64, 2000) }
            guard n > 0, lock.holdSequence == sequence else {
                mutex.lock(); dropped &+= 1; mutex.unlock()
                return
            }
            // Frames 0–1 are the handler and the signal trampoline.
            let key = frames[0..<Int(n)].dropFirst(2).map { UInt(bitPattern: $0) }
            mutex.lock()
            taken &+= 1
            let old = stacks[key]
            stacks[key] = (trap, (old?.count ?? 0) &+ 1)
            mutex.unlock()
        }
    }

    fileprivate func dump() {
        mutex.lock()
        let copy = stacks
        let counts = (taken, dropped)
        mutex.unlock()
        let maps = Self.mappings()
        var out = "# lock holder stacks: \(counts.0) samples, \(counts.1) dropped\n"
        for (frames, v) in copy.sorted(by: { $0.value.count > $1.value.count }) {
            let names = frames.map { Self.region($0, maps) }.joined(separator: ";")
            out += "\(v.count)\t\(TrapProfile.name(v.trap))\t\(names)\n"
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
        try? Self.procMaps().write(toFile: path + ".maps", atomically: true, encoding: .utf8)
    }

    private static func mappings() -> [(start: UInt, end: UInt, offset: UInt, path: String)] {
        let text = procMaps()
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 6, f[5].hasPrefix("/") else { return nil }
            let range = f[0].split(separator: "-")
            guard range.count == 2, let a = UInt(range[0], radix: 16), let b = UInt(range[1], radix: 16) else { return nil }
            return (a, b, UInt(f[2], radix: 16) ?? 0, String(f[5]))
        }
    }

    /// /proc/self/maps in full (a single `String(contentsOfFile:)` read
    /// stops after the first page of this generated file).
    private static func procMaps() -> String {
        guard let handle = FileHandle(forReadingAtPath: "/proc/self/maps") else { return "" }
        defer { try? handle.close() }
        return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func region(_ address: UInt, _ maps: [(start: UInt, end: UInt, offset: UInt, path: String)]) -> String {
        guard let m = maps.first(where: { $0.start <= address && address < $0.end }) else { return String(format: "0x%lx", address) }
        // Return addresses point after the call; minus 1 lands in the call.
        return m.path + String(format: "+0x%lx", address - m.start + m.offset - 1)
    }
}
#endif
