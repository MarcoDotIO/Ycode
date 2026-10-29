import Foundation
import YcodeDarwinABI

// The process layer of stage 4b (`specs/simulator/stage4b-contract.md` §4):
// posix_spawn, execve, exit, wait4/waitid, kill, process groups, proc_info.
// Semantics: `specs/simulator/processes.md` §1, §2. Owner: agent P.
//
// A kernel that is not the current image of a process in its system's table
// (the stage-4a one-process machine: `DarwinKernel(fileSystem:)` without a
// system) keeps its stage-4a behavior: `processCall` returns nil for every
// call except `kqueue` and the fileport calls.

extension DarwinKernel {
    /// Signal numbers and `sa_flags` bits (`processes.md` conventions,
    /// `threads-and-events.md` §5.1).
    public enum Signal {
        public static let sighup: Int32 = 1, sigint: Int32 = 2, sigquit: Int32 = 3, sigill: Int32 = 4,
                          sigtrap: Int32 = 5, sigabrt: Int32 = 6, sigfpe: Int32 = 8, sigkill: Int32 = 9, sigbus: Int32 = 10,
                          sigsegv: Int32 = 11, sigpipe: Int32 = 13, sigalrm: Int32 = 14, sigterm: Int32 = 15,
                          sigurg: Int32 = 16, sigstop: Int32 = 17, sigtstp: Int32 = 18, sigcont: Int32 = 19,
                          sigchld: Int32 = 20, sigttin: Int32 = 21, sigttou: Int32 = 22, sigio: Int32 = 23,
                          sigwinch: Int32 = 28, siginfo: Int32 = 29, sigusr1: Int32 = 30, sigusr2: Int32 = 31
        /// `SA_NOCLDSTOP`: no SIGCHLD when a child stops (`processes.md` §2.9).
        public static let saNoCldStop: Int32 = 0x8
        /// `SA_NOCLDWAIT`: exiting children are reaped at once, with no zombie (§2.4).
        public static let saNoCldWait: Int32 = 0x20
        /// Signals whose default action is to ignore them.
        static let ignoredByDefault: Set<Int32> = [sigurg, sigcont, sigchld, sigio, sigwinch, siginfo]
        /// Signals whose default action is to stop the process.
        static let stopping: Set<Int32> = [sigstop, sigtstp, sigttin, sigttou]

        static let names: [Int32: String] = [
            1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT", 8: "SIGFPE",
            9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS", 13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM",
            16: "SIGURG", 17: "SIGSTOP", 18: "SIGTSTP", 19: "SIGCONT", 20: "SIGCHLD", 21: "SIGTTIN", 22: "SIGTTOU",
            23: "SIGIO", 24: "SIGXCPU", 25: "SIGXFSZ", 26: "SIGVTALRM", 27: "SIGPROF", 28: "SIGWINCH", 29: "SIGINFO",
            30: "SIGUSR1", 31: "SIGUSR2",
        ]

        /// The `SIG*` name of `s` for trace lines, or `signal N` when the table lacks it.
        public static func name(_ s: Int32) -> String { names[s] ?? "signal \(s)" }
    }

    /// BSD numbers of the process layer: the low 16 bits of `x16` for the
    /// Darwin call each name spells.
    public enum ProcBSD {
        public static let exit = 1, wait4 = 7, kill = 37, getppid = 39, sigpending = 52, execve = 59, getpgrp = 81,
                          setpgid = 82, setsid = 147, getpgid = 151, waitid = 173, posixSpawn = 244, getsid = 310,
                          pthreadKill = 328, procInfo = 336, kqueue = 362, macExecve = 380,
                          fileportMakeport = 430, fileportMakefd = 431, terminateWithPayload = 520,
                          procInfoExtendedID = 545
    }

    /// `wait4`/`waitid` options.
    enum WaitOption {
        static let noHang: Int32 = 0x1
        static let untraced: Int32 = 0x2
        static let exited: Int32 = 0x4
        static let stopped: Int32 = 0x8
        static let continued: Int32 = 0x10
        static let noWait: Int32 = 0x20
    }

    static let ECHILD: Int32 = 10

    /// This image's process record (nil for the stage-4a one-process machine
    /// and for an image that was replaced or ended).
    var processRecord: DarwinProcess? { system.record(of: self) }

    /// BSD calls the process layer owns. nil = not mine.
    func processCall(_ n: Int, _ a: [UInt64], _ call: inout CallText, _ fallback: inout Int32,
                     _ mem: any KernelGuestMemory) throws -> BSDResult? {
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        switch n {
        case ProcBSD.kqueue:
            return .value(try withEvents { try kqueueCall(&call) })
        case ProcBSD.fileportMakeport, ProcBSD.fileportMakefd:
            // Forwarded to the Mach layer (`stage4b-contract.md` §3.7).
            guard let ipc = machIPC as? MachIPC else { return nil }
            call.set(n == ProcBSD.fileportMakeport ? "fileport_makeport(fd=\(int(0)), portnamep=\(hx(a[1])))"
                : "fileport_makefd(port=\(hx(UInt32(truncatingIfNeeded: a[0]))))")
            guard let v = try withPorts({ try ipc.fileportCall(n, a, fileSystem: fileSystem, memory: mem) }) else { return nil }
            return .value(v)
        default:
            break
        }
        guard let me = processRecord else { return nil }
        switch n {
        case ProcBSD.exit:
            call.set("exit(\(int(0)))")
            exitValue = int(0)
            return .exit(int(0) & 0xFF)

        case ProcBSD.wait4:
            return .value(try wait4(me, a, &call, mem))
        case ProcBSD.waitid:
            return .value(try waitid(me, a, &call, mem))

        case ProcBSD.kill:
            return .value(try kill(me, a, &call))
        case ProcBSD.pthreadKill:
            return .value(try pthreadKill(a, &call))
        case ProcBSD.terminateWithPayload:
            return .value(try terminateWithPayload(me, a, &call, mem))
        case ProcBSD.sigpending:
            call.set("sigpending(osv=\(hx(a[0])))")
            if a[0] != 0 { try writeU32(a[0], extended.pendingSignals, mem) }
            return .value(0)

        case ProcBSD.getppid:
            call.set("getppid()")
            return .value(UInt64(UInt32(bitPattern: me.ppid)))
        case ProcBSD.getpgrp:
            call.set("getpgrp()")
            return .value(UInt64(UInt32(bitPattern: me.pgid)))
        case ProcBSD.getpgid, ProcBSD.getsid:
            let isPgid = n == ProcBSD.getpgid
            call.set("\(isPgid ? "getpgid" : "getsid")(\(int(0)))")
            let target = int(0) == 0 ? me : system.processes[int(0)]
            guard let target, target.pid != DarwinSystem.initPID || int(0) == 1 else { throw Failure(errno: Errno.ESRCH) }
            return .value(UInt64(UInt32(bitPattern: isPgid ? target.pgid : target.sid)))
        case ProcBSD.setsid:
            call.set("setsid()")
            try setsid(me)
            return .value(UInt64(UInt32(bitPattern: me.pid)))
        case ProcBSD.setpgid:
            call.set("setpgid(\(int(0)), \(int(1)))")
            try setpgid(caller: me, pid: int(0), pgid: int(1))
            return .value(0)

        case ProcBSD.posixSpawn:
            return try posixSpawn(me, a, &call, mem)
        case ProcBSD.execve, ProcBSD.macExecve:
            return try execve(me, n, a, &call, mem)

        case ProcBSD.procInfo:
            return .value(try procInfo(a, &call, mem))
        case ProcBSD.procInfoExtendedID:
            return .value(try procInfoExtendedID(a, &call, mem))

        default:
            return nil
        }
    }

    /// `proc_info_extended_id` (callnum, pid, flavor, flags, ext_id, arg,
    /// buffer, buffersize): flag 0x1 compares the pid version, 0x2 the
    /// unique id; a mismatch is ESRCH (`processes.md` §2.11). Also on the
    /// BSD fast path for the read calls (`bsd-locking.md` §13).
    func procInfoExtendedID(_ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> UInt64 {
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        let target = int(1), flags = UInt32(truncatingIfNeeded: a[3]), ext = a[4]
        call.set("proc_info_extended_id(callnum=\(int(0)), pid=\(target), flavor=\(int(2)), flags=\(hx(flags)), "
            + "ext_id=\(hx(ext)))")
        if flags & 0x3 != 0 {
            guard let p = system.processRecord(target) else { throw Failure(errno: Errno.ESRCH) }
            if flags & 0x1 != 0, UInt64(p.pidVersion) != ext & 0xFFFF_FFFF { throw Failure(errno: Errno.ESRCH) }
            if flags & 0x2 != 0, p.uniqueID != ext { throw Failure(errno: Errno.ESRCH) }
        }
        var inner = CallText(call.enabled)
        let r = try procInfo([a[0], a[1], a[2], a[5], a[6], a[7]], &inner, mem)
        call += " " + inner.description
        return r
    }

    // MARK: Signals

    /// Contract-pinned (§3.6): posts `signal` to this process (to `thread`
    /// when given, as for SIGPIPE). Lock held.
    ///
    /// There is no handler delivery (`stage4b-contract.md` §2 item 5): the
    /// default action is taken (terminate, ignore; stop is not modeled and
    /// ignored; SIGCONT resumes a start-suspended process), and a signal
    /// with a guest handler is recorded as pending. EVFILT_SIGNAL counts
    /// every process-directed posting, even an ignored one.
    public func postSignal(_ signal: Int32, thread: ThreadContext? = nil) {
        postSignal(signal, thread: thread, sender: nil)
    }

    func postSignal(_ signal: Int32, thread: ThreadContext?, sender: Int32?) {
        guard (1...31).contains(signal), !isTerminating else { return }
        if thread == nil { countSignalForKEvent(signal) }
        if let p = processRecord { system.postProcessEvent(p, NoteProc.signal) }
        let action = extended.signalActions[signal]
        let handler = action?.handler ?? 0
        let name = Signal.name(signal)
        if signal == Signal.sigcont { continueProcess(sender: sender) }
        if signal == Signal.sigkill {
            terminateBySignal(signal)
            return
        }
        if handler == 1 {
            trace("note: \(name) posted to pid \(pid): ignored")
            return
        }
        if handler == 0 {
            if Signal.ignoredByDefault.contains(signal) { return }
            if Signal.stopping.contains(signal) {
                trace("note: \(name) posted to pid \(pid): stopping a process is not modeled; ignored")
                return
            }
            terminateBySignal(signal)
            return
        }
        // A guest handler: no delivery yet; the signal stays pending.
        extended.pendingSignals |= 1 << UInt32(signal - 1)
        trace("note: \(name) posted to pid \(pid): handler at \(hx(handler)) not run (no signal delivery); pending")
        signalWaiters.wakeAll()
    }

    /// Ends the process as killed by `signal` (`processes.md` §2.3).
    func terminateBySignal(_ signal: Int32, message: String? = nil, status: Int32? = nil) {
        guard !isTerminating else { return }
        deathSignal = signal
        let text = message ?? "guest terminated by \(Signal.name(signal)) (default action)"
        let outcome = Outcome.fatal(status: status ?? 128 + signal, message: text)
        if let p = processRecord {
            system.exitProcess(p, waitStatus: signal, outcome: outcome)
        } else {
            endImage(outcome)
        }
    }

    /// SIGCONT: a stopped (start-suspended) process runs: its task is
    /// resumed once (xnu resumes the task of a stopped process), so a
    /// process that was also `task_suspend`ed stays suspended
    /// (threads-and-events.md §1.6).
    private func continueProcess(sender: Int32?) {
        guard let p = processRecord, p.state == .stopped else { return }
        p.state = .running
        p.continuedPending = true
        p.continuedBy = sender ?? pid
        if mainStartPending {
            taskResumed()
        } else {
            p.image?.resume()
        }
        system.processes[p.ppid]?.childWaiters.wakeAll()
    }

    /// `cansignal` (`processes.md` §2.9): one uid for every guest process,
    /// so anything but pid 1 may be signalled.
    func canSignal(_ target: DarwinProcess) -> Bool {
        target.pid == pid || target.pid != DarwinSystem.initPID
    }

    /// `kill` (37).
    private func kill(_ me: DarwinProcess, _ a: [UInt64], _ call: inout CallText) throws -> UInt64 {
        let target = Int32(truncatingIfNeeded: a[0]), sig = Int32(truncatingIfNeeded: a[1])
        let posix = Int32(truncatingIfNeeded: a[2])
        call.set("kill(pid=\(target), sig=\(sig), posix=\(posix))")
        guard (0...31).contains(sig) else { throw Failure(errno: Errno.EINVAL) }
        if target > 0 {
            guard let p = system.processes[target] else { throw Failure(errno: Errno.ESRCH) }
            if p.state == .zombie { return 0 }
            guard canSignal(p) else { throw Failure(errno: Errno.EPERM) }
            if sig != 0 { p.kernel?.postSignal(sig, thread: nil, sender: pid) }
            if sig != 0 { call += " [\(Signal.name(sig)) to \(p.pid)]" }
            return 0
        }
        // A group or a broadcast.
        let members: [DarwinProcess]
        switch target {
        case 0:
            members = system.processes.values.filter { $0.pgid == me.pgid && $0.pid > 1 && $0.state != .zombie }
        case -1:
            members = system.processes.values.filter { $0.pid > 1 && (posix != 0 || $0.pid != pid) }
        default:
            guard target != Int32.min else { throw Failure(errno: Errno.ESRCH) }
            members = system.processes.values.filter { $0.pgid == -target && $0.pid > 1 && $0.state != .zombie }
            guard !members.isEmpty else { throw Failure(errno: Errno.ESRCH) }
        }
        var permitted = false
        var selfToo = false
        for p in members.sorted(by: { $0.pid < $1.pid }) {
            guard canSignal(p) else { continue }
            permitted = true
            if p.state == .zombie || sig == 0 { continue }
            if p.pid == pid {
                selfToo = true
                continue
            }
            p.kernel?.postSignal(sig, thread: nil, sender: pid)
        }
        if selfToo { postSignal(sig, thread: nil, sender: pid) }
        guard permitted else { throw Failure(errno: posix != 0 && !members.isEmpty ? Errno.EPERM : Errno.ESRCH) }
        call += " [\(members.count) targets]"
        return 0
    }

    /// `__pthread_kill` (328): a thread-directed signal of this process.
    private func pthreadKill(_ a: [UInt64], _ call: inout CallText) throws -> UInt64 {
        let port = UInt32(truncatingIfNeeded: a[0]), sig = Int32(truncatingIfNeeded: a[1])
        call.set("__pthread_kill(thread=\(hx(port)), sig=\(sig))")
        guard let thread = threadsByPort[port] else { throw Failure(errno: Errno.ESRCH) }
        guard (0...31).contains(sig) else { throw Failure(errno: Errno.EINVAL) }
        if sig == 0 { return 0 }
        call += " [\(Signal.name(sig))]"
        postSignal(sig, thread: thread, sender: pid)
        return 0
    }

    /// `terminate_with_payload` (520): SIGKILL with an exit reason.
    private func terminateWithPayload(_ me: DarwinProcess, _ a: [UInt64], _ call: inout CallText,
                                      _ mem: any KernelGuestMemory) throws -> UInt64 {
        let target = Int32(truncatingIfNeeded: a[0])
        let reason = a[5] == 0 ? "" : ((try? readString(a[5], length: 4096, mem)) ?? "<unreadable>")
        call.set("terminate_with_payload(pid=\(target), namespace=\(Int32(truncatingIfNeeded: a[1])), code=\(hx(a[2])))")
        guard target > 0 else { throw Failure(errno: Errno.EINVAL) }
        guard let p = system.processes[target], p.state != .zombie, let k = p.kernel else { throw Failure(errno: Errno.ESRCH) }
        guard canSignal(p) else { throw Failure(errno: Errno.EPERM) }
        let message = "terminate_with_payload: namespace \(Int32(truncatingIfNeeded: a[1])) code \(hx(a[2])): \(reason)"
        p.exitReason = message
        // The caller itself ends with the stage-3 status (134); its wait
        // status is SIGKILL.
        k.terminateBySignal(Signal.sigkill, message: message, status: k === self ? Self.abortExitStatus : nil)
        return 0
    }

    // MARK: wait4 / waitid

    /// Children of `me` that `match` accepts, in creation order.
    private func matchingChildren(_ me: DarwinProcess, _ match: (DarwinProcess) -> Bool) -> [DarwinProcess] {
        me.children.compactMap { system.processes[$0] }.filter(match)
    }

    /// `wait4` (7, 400): `processes.md` §2.6.
    private func wait4(_ me: DarwinProcess, _ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> UInt64 {
        var selector = Int32(truncatingIfNeeded: a[0])
        let options = Int32(truncatingIfNeeded: a[2])
        call.set("wait4(pid=\(selector), status=\(hx(a[1])), options=\(hx(UInt32(bitPattern: options))), rusage=\(hx(a[3])))")
        guard selector != Int32.min else { throw Failure(errno: Errno.EINVAL) }
        if selector == 0 { selector = -me.pgid }
        let wanted = selector
        let match: (DarwinProcess) -> Bool = { c in
            wanted == -1 ? true : wanted < -1 ? c.pgid == -wanted : c.pid == wanted
        }
        while true {
            let children = matchingChildren(me, match)
            guard !children.isEmpty else { throw Failure(errno: Self.ECHILD) }
            for c in children {
                if c.state == .zombie {
                    if a[1] != 0 { try writeU32(a[1], UInt32(bitPattern: c.status & 0xFFFF), mem) }
                    if a[3] != 0 { try mem.write(va: a[3], bytes: [UInt8](repeating: 0, count: 144)) }
                    system.reap(c)
                    call += " [pid \(c.pid) status \(hx(UInt32(bitPattern: c.status & 0xFFFF)))]"
                    return UInt64(UInt32(bitPattern: c.pid))
                }
                if options & WaitOption.continued != 0, c.continuedPending {
                    if a[1] != 0 { try writeU32(a[1], 0x137F, mem) }
                    if a[3] != 0 { try mem.write(va: a[3], bytes: [UInt8](repeating: 0, count: 144)) }
                    c.continuedPending = false
                    call += " [pid \(c.pid) continued]"
                    return UInt64(UInt32(bitPattern: c.pid))
                }
            }
            if options & WaitOption.noHang != 0 { return 0 }
            if me.childWaiters.wait(on: lock, deadline: nil) == .interrupted { throw Failure(errno: Self.EINTR) }
            guard system.record(of: self) === me else { throw Failure(errno: Self.EINTR) }
        }
    }

    /// `waitid` (173, 416): `processes.md` §2.7.
    private func waitid(_ me: DarwinProcess, _ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let idtype = Int32(truncatingIfNeeded: a[0]), id = Int32(truncatingIfNeeded: a[1])
        let infop = a[2], options = Int32(truncatingIfNeeded: a[3])
        call.set("waitid(idtype=\(idtype), id=\(id), infop=\(hx(infop)), options=\(hx(UInt32(bitPattern: options))))")
        let valid = WaitOption.noHang | WaitOption.exited | WaitOption.stopped | WaitOption.continued | WaitOption.noWait
        guard options != 0, options & ~valid == 0 else { throw Failure(errno: Errno.EINVAL) }
        let match: (DarwinProcess) -> Bool
        switch idtype {
        case 0: match = { _ in true }
        case 1:
            guard id >= 0 else { throw Failure(errno: Errno.EINVAL) }
            match = { $0.pid == id }
        case 2:
            guard id >= 0 else { throw Failure(errno: Errno.EINVAL) }
            match = { $0.pgid == id }
        default:
            throw Failure(errno: Errno.EINVAL)
        }
        func siginfo(code: Int32, pid: Int32, status: Int32) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 104)
            b.putLE(Signal.sigchld, at: 0)
            b.putLE(code, at: 8)
            b.putLE(pid, at: 12)
            b.putLE(DarwinFileSystem.guestUID, at: 16)
            b.putLE(status, at: 20)
            return b
        }
        while true {
            let children = matchingChildren(me, match)
            guard !children.isEmpty else { throw Failure(errno: Self.ECHILD) }
            for c in children {
                if c.state == .zombie, options & WaitOption.exited != 0 {
                    let low = c.status & 0x7F
                    let info = low == 0
                        ? siginfo(code: 1, pid: c.pid, status: ((c.status >> 8) & 0xFF) | (c.exitHighBits << 24))
                        : siginfo(code: 2, pid: c.pid, status: low)
                    if infop != 0 { try mem.write(va: infop, bytes: info) }
                    if options & WaitOption.noWait == 0 { system.reap(c) }
                    call += " [pid \(c.pid)]"
                    return 0
                }
                if c.continuedPending, options & WaitOption.continued != 0 {
                    if infop != 0 { try mem.write(va: infop, bytes: siginfo(code: 6, pid: c.continuedBy, status: Signal.sigcont)) }
                    if options & WaitOption.noWait == 0 { c.continuedPending = false }
                    call += " [pid \(c.pid) continued]"
                    return 0
                }
            }
            if options & WaitOption.noHang != 0 { return 0 }
            if me.childWaiters.wait(on: lock, deadline: nil) == .interrupted { throw Failure(errno: Self.EINTR) }
            guard system.record(of: self) === me else { throw Failure(errno: Self.EINTR) }
        }
    }

    // MARK: Process groups and sessions

    /// `setsid` (`processes.md` §2.10).
    func setsid(_ p: DarwinProcess) throws {
        guard !system.groupExists(p.pid) else { throw Failure(errno: Errno.EPERM) }
        p.sid = p.pid
        p.pgid = p.pid
    }

    /// `setpgid` as `caller` (`processes.md` §2.10).
    func setpgid(caller: DarwinProcess, pid target: Int32, pgid: Int32) throws {
        guard pgid >= 0 else { throw Failure(errno: Errno.EINVAL) }
        let t: DarwinProcess
        if target == 0 || target == caller.pid {
            t = caller
        } else {
            guard let c = system.processes[target], c.ppid == caller.pid, c.state != .zombie else {
                throw Failure(errno: Errno.ESRCH)
            }
            guard c.sid == caller.sid else { throw Failure(errno: Errno.EPERM) }
            guard !c.hasExeced else { throw Failure(errno: Self.EACCES) }
            t = c
        }
        guard t.sid != t.pid else { throw Failure(errno: Errno.EPERM) }
        let newGroup = pgid == 0 ? t.pid : pgid
        if newGroup != t.pid {
            guard system.processes.values.contains(where: { $0.pgid == newGroup && $0.sid == caller.sid && $0.state != .zombie })
            else { throw Failure(errno: Errno.EPERM) }
        }
        t.pgid = newGroup
    }
}
