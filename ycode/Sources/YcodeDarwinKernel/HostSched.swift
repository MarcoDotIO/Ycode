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

/// Host priorities for guest threads by scheduling class
/// (`specs/simulator/scheduling-policy.md` §4.7). The backend is chosen once
/// from `YCODE_HOST_SCHED`.
public enum HostSched {
    /// How host priorities are applied: not at all, per-thread nice values, or
    /// threaded cgroup v2 children with CPU weights.
    public enum Backend: String, Sendable { case none, nice, cgroup }

    /// The backend in use; `.none` until one is set up (or when setup failed).
    nonisolated(unsafe) public private(set) static var backend: Backend = .none
    /// Nice values by class (background … interactive).
    static let niceByClass: [Int32] = [19, 8, 3, 0]
    /// cgroup CPU weights by class. Class 0 has weight
    /// `YCODE_HOST_SCHED_BG_WEIGHT` (default 5); `YCODE_HOST_SCHED_BG_WEIGHT=idle`
    /// makes it `cpu.idle` instead (the behaviour before 2026-10-27, which
    /// starved a class-0 holder of the kernel lock, scheduling-policy.md §7.4).
    static let weightByClass = [bgWeight ?? 1, 25, 100, 400]
    /// Class 0's weight, nil for `cpu.idle`.
    static let bgWeight: Int? = {
        guard let v = getenv("YCODE_HOST_SCHED_BG_WEIGHT").map({ String(cString: $0) }) else { return 5 }
        if v == "idle" { return nil }
        return Int(v).map { max(1, min(10_000, $0)) } ?? 5
    }()
    nonisolated(unsafe) static var threadFiles: [Int32] = []
    nonisolated(unsafe) static var key = pthread_key_t()
    static let moveCount = Atomic<Int>(0)
    static let failureCount = Atomic<Int>(0)
    /// Time spent in the moves themselves (one cgroup or nice write each).
    static let moveNanoseconds = Atomic<UInt64>(0)
    /// Lock holders raised to a waiter's class (`KernelLock`, §4.7 "holders"),
    /// and the restores that followed.
    static let promotions = Atomic<Int>(0)
    static let promotionRestores = Atomic<Int>(0)
    /// Contended acquisitions that waited out the promotion delay.
    static let promotionWaits = Atomic<Int>(0)
    /// Demotions put off (the class went down and came back up within the
    /// delay) and done.
    static let demotionsSkipped = Atomic<Int>(0)
    /// `YCODE_HOST_SCHED_DEMOTE_MS` (default 50): a thread whose class went
    /// down keeps its host priority this long before it is moved down
    /// (checked at its trap ends); a rise is applied at once. Classes flip
    /// with every serviced request (sync-IPC pushes), and a move costs
    /// about half a millisecond on the Thor (§7.5). 0: at once.
    nonisolated(unsafe) static var demoteDelayNanoseconds: UInt64 =
        UInt64(getenv("YCODE_HOST_SCHED_DEMOTE_MS").flatMap { Double(String(cString: $0)) } ?? 50) * 1_000_000
    /// The time (host monotonic ns) the calling thread's class went below
    /// its applied one, 0 when it has not (pthread key).
    nonisolated(unsafe) static var demoteKey = pthread_key_t()
    /// A one-line summary for the end-of-run report: the backend's status, move
    /// and failure counts, and the time spent moving threads.
    public static var report: String {
        "host scheduling \(status); \(moveCount.load(ordering: .relaxed)) moves, \(failureCount.load(ordering: .relaxed)) failures, "
            + "\(moveNanoseconds.load(ordering: .relaxed) / 1_000_000) ms moving (\(otherMoveCount.load(ordering: .relaxed)) moves of another thread, "
            + "\(otherMoveNanoseconds.load(ordering: .relaxed) / 1_000_000) ms), \(demotionsSkipped.load(ordering: .relaxed)) demotions put off; "
            + "lock holders promoted \(promotions.load(ordering: .relaxed)) "
            + "(\(promotionWaits.load(ordering: .relaxed)) waits past the delay, \(promotionRestores.load(ordering: .relaxed)) let go raised; "
            + "\(groupWrites.load(ordering: .relaxed)) class weight writes, \(groupWriteNanoseconds.load(ordering: .relaxed) / 1_000_000) ms)"
    }
    /// `YCODE_LOCK_HOLDER_PROMOTION` (default on with a backend; `=0` off):
    /// a thread that finds a kernel lock taken raises the holder's host
    /// thread to its own class while the holder holds it (§4.7).
    nonisolated(unsafe) public static var promoteHolders = getenv("YCODE_LOCK_HOLDER_PROMOTION").map { String(cString: $0) != "0" } ?? true
    /// How a holder is raised: `group` (default with the cgroup backend and a
    /// weighted class 0): the weight of the holder's class cgroup is raised
    /// to the waiter's class weight until the holder lets go (one `cpu.weight`
    /// write, microseconds, no global cgroup lock); `thread`
    /// (`YCODE_LOCK_HOLDER_PROMOTION=thread`, and the `nice` backend): the
    /// holder's thread is moved (a move by thread id takes the global
    /// threadgroup lock: 9 ms on average during a boot, §7.5).
    nonisolated(unsafe) static var promoteByGroup = getenv("YCODE_LOCK_HOLDER_PROMOTION").map { String(cString: $0) != "thread" } ?? true
    /// The `cpu.weight` files of the class cgroups (−1 for an idle class 0).
    nonisolated(unsafe) static var weightFiles: [Int32] = []
    /// Per class cgroup: holders raised now, and the class weight it has.
    static let groupRaises = Mutex<[(count: Int, level: Int)]>([(0, 0), (0, 1), (0, 2), (0, 3)])
    /// True when the holder of class `cls` is raised through its cgroup.
    @inline(__always) static func raisesGroup(_ cls: Int) -> Bool {
        promoteByGroup && moveHook == nil && backend == .cgroup && cls >= 0 && cls < weightFiles.count && weightFiles[cls] >= 0
    }
    /// Tests: called for each group weight change (class, weight class).
    nonisolated(unsafe) static var groupHook: ((Int, Int) -> Void)?

    /// A holder of class `holder` blocks a waiter of class `to`: raise the
    /// holder's class cgroup to the waiter's weight (counted).
    static func raiseGroup(_ holder: Int, to cls: Int) {
        groupRaises.withLock { g in
            g[holder].count += 1
            if cls > g[holder].level {
                g[holder].level = cls
                writeWeight(holder, weightByClass[cls])
            }
        }
    }

    /// That holder let go: the cgroup gets its own weight back once no
    /// raised holder of it is left.
    static func lowerGroup(_ holder: Int) {
        groupRaises.withLock { g in
            g[holder].count = max(0, g[holder].count - 1)
            // swiftlint:disable:next empty_count - a counter, not a collection
            if g[holder].count == 0, g[holder].level != holder {
                g[holder].level = holder
                writeWeight(holder, weightByClass[holder])
            }
        }
    }

    private static func writeWeight(_ group: Int, _ weight: Int) {
        if let groupHook { groupHook(group, weight); return }
        #if os(Linux)
        let start = KernelClock.now()
        let text = Array(String(weight).utf8)
        let ok = text.withUnsafeBufferPointer { pwrite(weightFiles[group], $0.baseAddress, $0.count, 0) } == text.count
        groupWrites.wrappingAdd(1, ordering: .relaxed)
        groupWriteNanoseconds.wrappingAdd(KernelClock.now() &- start, ordering: .relaxed)
        if !ok { failureCount.wrappingAdd(1, ordering: .relaxed) }
        #endif
    }
    static let groupWrites = Atomic<Int>(0)
    static let groupWriteNanoseconds = Atomic<UInt64>(0)
    /// True when lock holders are tracked for promotion (a backend is on).
    @inline(__always) static var promoting: Bool { (backend != .none || moveHook != nil) && promoteHolders }
    /// Tests: replaces the host moves (thread id, class) and turns the
    /// bookkeeping on without a backend. Set before threads use it.
    nonisolated(unsafe) static var moveHook: ((Int32, Int) -> Void)? {
        didSet { if moveHook != nil { makeKeys() } }
    }
    private static let keysMade = Atomic<Bool>(false)
    static func makeKeys() {
        guard keysMade.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged else { return }
        pthread_key_create(&key, nil)
        pthread_key_create(&tidKey, nil)
        pthread_key_create(&demoteKey, nil)
    }
    /// The calling host thread's Linux thread id, cached (pthread key).
    nonisolated(unsafe) static var tidKey = pthread_key_t()
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
        // systemd-run needs the user's service manager; without it the scope
        // cannot be made and systemd-run would fail instead of running us.
        let runtime = getenv("XDG_RUNTIME_DIR").map { String(cString: $0) } ?? "/run/user/\(getuid())"
        guard access(runtime + "/systemd/private", F_OK) == 0 else { return }
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
        makeKeys()
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
        guard backend != .none || moveHook != nil else { return }
        let current = Int(bitPattern: pthread_getspecific(key)) - 1
        guard current != cls else {
            if pthread_getspecific(demoteKey) != nil {
                pthread_setspecific(demoteKey, nil)
                demotionsSkipped.wrappingAdd(1, ordering: .relaxed)
            }
            return
        }
        if cls < current, current >= 0, demoteDelayNanoseconds > 0 {
            let now = KernelClock.now()
            let since = UInt64(UInt(bitPattern: pthread_getspecific(demoteKey)))
            if since == 0 {
                pthread_setspecific(demoteKey, UnsafeRawPointer(bitPattern: UInt(now)))
                return
            }
            guard now &- since >= demoteDelayNanoseconds else { return }
        }
        pthread_setspecific(demoteKey, nil)
        guard let tid = currentTID() else { return }
        move(tid, to: cls, isSelf: true)
        // A failure is not retried at every trap either.
        pthread_setspecific(key, UnsafeRawPointer(bitPattern: cls + 1))
    }

    /// Records `cls` as the calling thread's applied class (it was moved
    /// there by another thread).
    @inline(__always)
    static func setAppliedClass(_ cls: Int) {
        pthread_setspecific(key, UnsafeRawPointer(bitPattern: cls + 1))
    }

    /// The class last applied to the calling host thread; −1 when none was
    /// (a host thread with no guest context, or a guest thread before its
    /// first trap returned).
    @inline(__always)
    static func appliedClass() -> Int {
        Int(bitPattern: pthread_getspecific(key)) - 1
    }

    /// Forgets the calling thread's applied class, so the next `apply`
    /// moves it again (after a promotion by a lock waiter).
    @inline(__always)
    static func forgetAppliedClass() {
        pthread_setspecific(key, nil)
    }

    /// The calling host thread's Linux thread id (cached), nil without one.
    @inline(__always)
    static func currentTID() -> Int32? {
        let cached = Int(bitPattern: pthread_getspecific(tidKey))
        if cached != 0 { return Int32(truncatingIfNeeded: cached) }
        guard let threadID else { return nil }
        let tid = threadID()
        guard tid != 0 else { return nil }
        pthread_setspecific(tidKey, UnsafeRawPointer(bitPattern: tid))
        return Int32(truncatingIfNeeded: tid)
    }

    /// Gives host thread `tid` (of this process) the host priority of `cls`.
    /// `isSelf`: `tid` is the calling thread. The cgroup backend then writes
    /// "0" (the writer itself), which Linux moves without the global
    /// threadgroup lock that a move by thread id takes (that one waits for
    /// an RCU grace period and blocks every thread creation in the system
    /// meanwhile: about 2 ms a move during a boot, §7.5).
    static func move(_ tid: Int32, to cls: Int, isSelf: Bool = false) {
        if let moveHook {
            moveHook(tid, cls)
            moveCount.wrappingAdd(1, ordering: .relaxed)
            return
        }
        #if os(Linux)
        let start = KernelClock.now()
        var ok = false
        switch backend {
        case .nice:
            ok = setpriority(__priority_which_t(PRIO_PROCESS.rawValue), id_t(tid), niceByClass[cls]) == 0
        case .cgroup:
            let text = Array((isSelf && selfMoveByZero ? "0" : String(tid)).utf8)
            ok = text.withUnsafeBufferPointer { pwrite(threadFiles[cls], $0.baseAddress, $0.count, 0) } == text.count
        case .none:
            break
        }
        let took = KernelClock.now() &- start
        moveNanoseconds.wrappingAdd(took, ordering: .relaxed)
        if !isSelf {
            otherMoveCount.wrappingAdd(1, ordering: .relaxed)
            otherMoveNanoseconds.wrappingAdd(took, ordering: .relaxed)
        }
        if ok { moveCount.wrappingAdd(1, ordering: .relaxed) } else { failureCount.wrappingAdd(1, ordering: .relaxed) }
        #endif
    }
    /// `YCODE_HOST_SCHED_SELF_ZERO=0`: a thread moves itself by its id too.
    nonisolated(unsafe) static var selfMoveByZero = getenv("YCODE_HOST_SCHED_SELF_ZERO").map { String(cString: $0) != "0" } ?? true
    /// Moves of another thread (promotions) and their time.
    static let otherMoveCount = Atomic<Int>(0)
    static let otherMoveNanoseconds = Atomic<UInt64>(0)

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
        var weights: [Int32] = []
        for c in 0..<SchedClass.count {
            let dir = cg + "/ycode-class\(c)"
            if mkdir(dir, 0o755) != 0 && errno != EEXIST { return "none: mkdir \(dir) failed (errno \(errno))" }
            guard write(dir + "/cgroup.type", "threaded") else { return "none: \(dir) cannot be threaded" }
        }
        guard write(cg + "/cgroup.subtree_control", "+cpu") else { return "none: cannot enable cpu in \(cg)" }
        for c in 0..<SchedClass.count {
            let dir = cg + "/ycode-class\(c)"
            if c == 0, bgWeight == nil, write(dir + "/cpu.idle", "1") {
            } else {
                // A cgroup left idle by an earlier run of this process is made a weighted one again.
                if c == 0 { _ = write(dir + "/cpu.idle", "0") }
                _ = write(dir + "/cpu.weight", String(weightByClass[c]))
            }
            let fd = open(dir + "/cgroup.threads", O_WRONLY)
            guard fd >= 0 else { return "none: cannot open \(dir)/cgroup.threads" }
            files.append(fd)
            weights.append(c == 0 && bgWeight == nil ? -1 : open(dir + "/cpu.weight", O_WRONLY))
        }
        threadFiles = files
        weightFiles = weights
        backend = .cgroup
        let bg = bgWeight.map { "class 0 weight \($0)" } ?? "class 0 idle"
        return "cgroup \(cg) (weights \(weightByClass.dropFirst().map(String.init).joined(separator: "/")), \(bg); "
            + "holder promotion \(promoteHolders ? (promoteByGroup ? "by class weight" : "by thread move") : "off"))"
    }
    #endif
}
