import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// The host side of the scheduling policy (`specs/simulator/scheduling-
// policy.md` §4.7): each guest thread's host thread runs with a host
// priority that follows its scheduling class. `YCODE_HOST_SCHED` picks the
// backend:
//
// - `nice`: per-thread nice values (needs RLIMIT_NICE ≥ 20 or CAP_SYS_NICE,
//   because a thread must be able to return to nice 0);
// - `cgroup`: four threaded cgroup v2 children of the process's own
//   delegated cgroup with CPU weights (an unprivileged process gets one
//   from `systemd-run --user --scope -p Delegate=yes`; `prepareProcess`
//   re-executes the VMM in such a scope when needed);
// - anything else, or a backend that cannot be set up: none.
//
// A host thread changes only its own priority, right after a trap, outside
// the kernel lock (`DarwinKernel.handle`).

public enum HostSched {
    public enum Backend: String, Sendable { case none, nice, cgroup }

    nonisolated(unsafe) public private(set) static var backend: Backend = .none
    /// Nice values by class (background … interactive).
    static let niceByClass: [Int32] = [19, 8, 3, 0]
    /// cgroup CPU weights by class; class 0 uses `cpu.idle` when the kernel has it.
    static let weightByClass = [1, 25, 100, 400]
    nonisolated(unsafe) static var threadFiles: [Int32] = []
    nonisolated(unsafe) static var key = pthread_key_t()
    static let moveCount = Atomic<Int>(0)
    static let failureCount = Atomic<Int>(0)
    public static var report: String {
        "host scheduling \(status); \(moveCount.load(ordering: .relaxed)) moves, \(failureCount.load(ordering: .relaxed)) failures"
    }
    /// The calling host thread's Linux thread id (the VMM sets it: `gettid`).
    nonisolated(unsafe) public static var threadID: (() -> Int)?
    /// The setup result, for the log.
    nonisolated(unsafe) public private(set) static var status = "off"

    /// The requested backend (`YCODE_HOST_SCHED`).
    static var requested: Backend {
        Backend(rawValue: getenv("YCODE_HOST_SCHED").map { String(cString: $0) } ?? "none") ?? .none
    }

    /// Call first thing in the VMM's `main` (no other threads yet). With
    /// the cgroup backend and a cgroup the process cannot write, replaces
    /// the process with itself inside a delegated user scope (the pid stays
    /// the same: `systemd-run --scope` executes in place). Returns only
    /// when no re-execution happened.
    public static func prepareProcess() {
        #if os(Linux)
        guard SchedPolicy.qosEnabled, requested == .cgroup else { return }
        guard let cg = ownCgroup(), access(cg + "/cgroup.subtree_control", W_OK) != 0 else { return }
        guard getenv("YCODE_HOST_SCHED_SCOPE") == nil else { return }
        setenv("YCODE_HOST_SCHED_SCOPE", "1", 1)
        var exe = [CChar](repeating: 0, count: 4096)
        let n = readlink("/proc/self/exe", &exe, exe.count - 1)
        guard n > 0 else { return }
        let args = ["systemd-run", "--user", "--scope", "--quiet", "-p", "Delegate=yes", "--", String(cString: exe)]
            + CommandLine.arguments.dropFirst()
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        execvp("systemd-run", &cargs)
        // execvp failed: continue without the cgroup backend.
        unsetenv("YCODE_HOST_SCHED_SCOPE")
        #endif
    }

    /// Sets the backend up (once, before guest threads run). Returns a
    /// line for the log.
    @discardableResult
    public static func configure() -> String {
        #if os(Linux)
        guard SchedPolicy.qosEnabled else { return status }
        pthread_key_create(&key, nil)
        switch requested {
        case .nice:
            var limit = rlimit()
            getrlimit(__rlimit_resource_t(13), &limit)  // RLIMIT_NICE (Linux)
            if limit.rlim_cur >= 20 || geteuid() == 0 {
                backend = .nice
                status = "nice (RLIMIT_NICE \(limit.rlim_cur))"
            } else {
                status = "none: nice needs RLIMIT_NICE >= 20 to raise a thread again (it is \(limit.rlim_cur))"
            }
        case .cgroup:
            status = setUpCgroups()
        case .none:
            status = "none"
        }
        #else
        status = "none (not Linux)"
        #endif
        return status
    }

    /// Gives the calling host thread the host priority of `cls` if it does
    /// not have it yet. Cheap when nothing changes.
    @inline(__always)
    public static func apply(_ cls: Int) {
        guard backend != .none else { return }
        #if os(Linux)
        let current = Int(bitPattern: pthread_getspecific(key)) - 1
        guard current != cls else { return }
        guard let threadID else { return }
        let tid = Int32(threadID())
        var ok = false
        switch backend {
        case .nice:
            ok = setpriority(__priority_which_t(PRIO_PROCESS.rawValue), id_t(tid), niceByClass[cls]) == 0
        case .cgroup:
            let text = Array(String(tid).utf8)
            ok = text.withUnsafeBufferPointer { pwrite(threadFiles[cls], $0.baseAddress, $0.count, 0) } == text.count
        case .none:
            break
        }
        if ok { moveCount.wrappingAdd(1, ordering: .relaxed) } else { failureCount.wrappingAdd(1, ordering: .relaxed) }
        // A failure is not retried at every trap either.
        pthread_setspecific(key, UnsafeRawPointer(bitPattern: cls + 1))
        #endif
    }

    #if os(Linux)
    static func ownCgroup() -> String? {
        guard let text = try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("0::") {
            return "/sys/fs/cgroup" + line.dropFirst(3)
        }
        return nil
    }

    static func write(_ path: String, _ value: String) -> Bool {
        let fd = open(path, O_WRONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = Array(value.utf8)
        return bytes.withUnsafeBufferPointer { Glibc.write(fd, $0.baseAddress, $0.count) } == bytes.count
    }

    static func setUpCgroups() -> String {
        guard let cg = ownCgroup() else { return "none: no cgroup v2 path" }
        guard access(cg + "/cgroup.subtree_control", W_OK) == 0 else { return "none: \(cg) is not delegated" }
        var files: [Int32] = []
        for c in 0..<SchedClass.count {
            let dir = cg + "/ycode-class\(c)"
            if mkdir(dir, 0o755) != 0 && errno != EEXIST { return "none: mkdir \(dir) failed (errno \(errno))" }
            guard write(dir + "/cgroup.type", "threaded") else { return "none: \(dir) cannot be threaded" }
        }
        guard write(cg + "/cgroup.subtree_control", "+cpu") else { return "none: cannot enable cpu in \(cg)" }
        for c in 0..<SchedClass.count {
            let dir = cg + "/ycode-class\(c)"
            if c == 0, write(dir + "/cpu.idle", "1") {
            } else {
                _ = write(dir + "/cpu.weight", String(weightByClass[c]))
            }
            let fd = open(dir + "/cgroup.threads", O_WRONLY)
            guard fd >= 0 else { return "none: cannot open \(dir)/cgroup.threads" }
            files.append(fd)
        }
        threadFiles = files
        backend = .cgroup
        return "cgroup \(cg) (weights \(weightByClass.dropFirst().map(String.init).joined(separator: "/")), class 0 idle)"
    }
    #endif
}
