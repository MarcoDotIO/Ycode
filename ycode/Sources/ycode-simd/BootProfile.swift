// ycode-simd: the boot profile (diagnostics, off by default;
// specs/simulator/performance-contract.md §2.5).
//
// `YCODE_BOOT_PROFILE=<path>` turns it on:
//   - <path>.samples: every `YCODE_BOOT_PROFILE_INTERVAL_MS` (default 500)
//     one line: host CPU of the whole process in the interval (guest mode,
//     host kernel, VMM user code; in cores), host threads runnable (R) and
//     in uninterruptible sleep (D), guest threads by state (in guest code,
//     in a trap handler, blocked in a kernel wait), kernel-lock busy share,
//     live images, and the images that used the most CPU in the interval.
//   - <path> (at the end of the run): one row per process image (launch,
//     build, first guest instruction, libSystem milestone, end, teardown;
//     its vCPU threads' CPU split, KVM exits, faults, run-queue wait, thread
//     start latency, kernel-lock time), and the same summed by program.
// The run must end by itself (`--timeout-ms`) for the table to be written.

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import YcodeDarwinKernel
import YcodeHypervisor
import YcodeDarwinABI

final class BootProfile: @unchecked Sendable {
    static let shared: BootProfile? = {
        guard let raw = getenv("YCODE_BOOT_PROFILE"), raw.pointee != 0 else { return nil }
        return BootProfile(path: String(cString: raw))
    }()

    static let intervalMilliseconds: UInt32 = getenv("YCODE_BOOT_PROFILE_INTERVAL_MS")
        .flatMap { UInt32(String(cString: $0)) }.map { max(50, $0) } ?? 500

    let path: String
    let startNs = monotonicNanoseconds()

    init(path: String) { self.path = path }

    /// The launcher (for the prebuilt-VM counters in the report).
    weak var launcherForReport: VMMLauncher?

    /// Turns on the counters the profile reads. Call before the first image.
    func enable() {
        VCPUPool.profiling = true
        KernelLock.profileProcesses = true
    }

    private func seconds(_ ns: UInt64) -> String {
        ns == 0 ? "-" : String(format: "%.3f", Double(ns &- startNs) / 1e9)
    }

    // MARK: Guest PC samples

    /// `YCODE_BOOT_PROFILE_PC_HZ=<n>` (default 0 = off): guest PC samples
    /// per second of every vCPU in guest code, by image (<path>.pcs).
    static let pcHz: UInt32 = getenv("YCODE_BOOT_PROFILE_PC_HZ").flatMap { UInt32(String(cString: $0)) } ?? 0
    private let pcLock = HostMutex(name: "boot profile PCs")
    /// "program|image" -> samples; "program|image+0xNNN000" (4 KiB buckets).
    private var pcImages: [String: UInt64] = [:]
    private var pcBuckets: [String: UInt64] = [:]
    private var pcTotal: UInt64 = 0
    /// "pc-offset lr-offset" -> samples, for the loader (`dyld_sim`).
    private var loaderSamples: [String: UInt64] = [:]

    /// `YCODE_BOOT_PROFILE_PC_RAW=<program>` (with `…_PC_HZ`): instead of
    /// the by-image table, the samples of that program go to <path>.pcraw as one line, "host-ns pid
    /// pc lr ra0 ra1 …" (hex guest addresses, the frame-pointer chain as
    /// read at the sample), for a timeline of what one process ran
    /// (visionos.md §10.7; symbolized offline in the guest).
    static let rawProgram: String? = getenv("YCODE_BOOT_PROFILE_PC_RAW").map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    private lazy var rawFile: FileHandle? = {
        FileManager.default.createFile(atPath: path + ".pcraw", contents: nil)
        return FileHandle(forWritingAtPath: path + ".pcraw")
    }()

    /// The timeline sampler (`YCODE_BOOT_PROFILE_PC_RAW`): kicks only that
    /// program's vCPUs, waits for each sample (they land within
    /// microseconds) and writes it at once, so the samples are as dense as
    /// `…_PC_HZ` allows. It replaces the by-image sampler.
    private func startRawSampler(launcher: VMMLauncher, program: String) {
        let thread = Thread { [self] in
            let interval = UInt32(1_000_000 / max(1, Self.pcHz))
            var targets: [GuestImageInstance] = []
            var refreshAt: UInt64 = 0
            var out = ""
            while true {
                let now = monotonicNanoseconds()
                if now >= refreshAt {
                    targets = launcher.snapshotLiveImages.filter { ($0.record.executable as NSString).lastPathComponent == program }
                    refreshAt = now + 20_000_000
                    if !out.isEmpty { rawFile?.write(Data(out.utf8)); out = "" }
                }
                var pending: [(GuestImageInstance, VCPUPool.Worker, UInt64)] = []
                for image in targets {
                    for w in image.pool.kickForPCSamples() { pending.append((image, w, w.sampleCount.load(ordering: .relaxed))) }
                }
                let deadline = monotonicNanoseconds() + 300_000
                while !pending.isEmpty && monotonicNanoseconds() < deadline {
                    pending.removeAll { (image, w, count) in
                        guard w.sampleCount.load(ordering: .acquiring) != count else { return false }
                        out += "\(monotonicNanoseconds()) \(image.record.pid) "
                            + String(format: "%llx %llx", w.samplePC.load(ordering: .relaxed), w.sampleLR.load(ordering: .relaxed))
                        for ra in w.sampleStack { out += String(format: " %llx", ra) }
                        out += "\n"
                        return true
                    }
                }
                if out.utf8.count > 1 << 16 { rawFile?.write(Data(out.utf8)); out = "" }
                usleep(interval)
            }
        }
        thread.name = "ycode boot profile PC timeline"
        thread.start()
    }

    func startPCSampler(launcher: VMMLauncher) {
        guard Self.pcHz > 0 else { return }
        if let program = Self.rawProgram {
            startRawSampler(launcher: launcher, program: program)
            return
        }
        let thread = Thread { [self] in
            let interval = 1_000_000 / max(1, Self.pcHz)
            var pending: [(image: GuestImageInstance, worker: VCPUPool.Worker, count: UInt64)] = []
            while true {
                usleep(interval)
                // Collect the samples asked for last time (the kick lands within microseconds).
                for p in pending where p.worker.sampleCount.load(ordering: .acquiring) != p.count {
                    let pc = p.worker.samplePC.load(ordering: .relaxed)
                    let program = (p.image.record.executable as NSString).lastPathComponent
                    let (image, offset) = p.image.attributeForProfile(pc)
                    // Loader samples in detail: PC and return address offsets
                    // (<path>.loader; symbolized offline from the symbol table).
                    var loaderKey: String?
                    if image == "dyld_sim" {
                        let (lrImage, lrOffset) = p.image.attributeForProfile(p.worker.sampleLR.load(ordering: .relaxed))
                        loaderKey = String(format: "0x%llx ", offset) + (lrImage == "dyld_sim" ? String(format: "0x%llx", lrOffset) : lrImage)
                        // Up to six more callers through the frame-pointer
                        // chain (read now; the thread may have moved on, so
                        // this is approximate).
                        for ra in p.worker.sampleStack {
                            let (raImage, raOffset) = p.image.attributeForProfile(ra)
                            loaderKey! += " " + (raImage == "dyld_sim" ? String(format: "0x%llx", raOffset) : raImage)
                        }
                    }
                    pcLock.withLock {
                        pcTotal &+= 1
                        pcImages[program + "|" + image, default: 0] &+= 1
                        pcBuckets[program + "|" + image + String(format: "+0x%llx", offset & ~0xFFF), default: 0] &+= 1
                        if let loaderKey { loaderSamples[loaderKey, default: 0] &+= 1 }
                    }
                }
                pending.removeAll(keepingCapacity: true)
                for image in launcher.snapshotLiveImages {
                    for w in image.pool.kickForPCSamples() {
                        pending.append((image, w, w.sampleCount.load(ordering: .relaxed)))
                    }
                }
            }
        }
        thread.name = "ycode boot profile PCs"
        thread.start()
    }

    /// The PC table: by image (all programs), by program and image, and the
    /// hottest 4 KiB buckets.
    private func pcReport() -> String {
        let (images, buckets, total) = pcLock.withLock { (pcImages, pcBuckets, pcTotal) }
        guard total > 0 else { return "" }
        func pct(_ n: UInt64) -> String { String(format: "%.1f", 100 * Double(n) / Double(total)) }
        var byImage: [String: UInt64] = [:]
        for (k, v) in images { byImage[String(k.split(separator: "|", maxSplits: 1).last ?? ""), default: 0] += v }
        var out = "# guest PC samples: \(total)\n# by image\n"
        for (k, v) in byImage.sorted(by: { $0.value > $1.value }).prefix(40) { out += "\(pct(v)) % \(k)\n" }
        out += "# by program and image\n"
        for (k, v) in images.sorted(by: { $0.value > $1.value }).prefix(60) { out += "\(pct(v)) % \(k)\n" }
        out += "# hottest 4 KiB buckets\n"
        for (k, v) in buckets.sorted(by: { $0.value > $1.value }).prefix(60) { out += "\(pct(v)) % \(k)\n" }
        return out
    }

    // MARK: Trap costs (`YCODE_BOOT_PROFILE_TRAPS=1`)

    /// Per trap number, before and after the image's libSystem milestone:
    /// count, wall time in `handleTrap` (lock waits included), and the
    /// handling thread's user and system CPU (getrusage, µs) and minor
    /// faults. Task-local traps included. Two getrusage calls per trap.
    static let trapCosts = shared != nil
        && (getenv("YCODE_BOOT_PROFILE_TRAPS").map { String(cString: $0) == "1" } ?? false)
    struct TrapCost { var count: UInt64 = 0; var wallNs: UInt64 = 0; var userUs: UInt64 = 0; var sysUs: UInt64 = 0; var faults: UInt64 = 0 }
    private let costLock = HostMutex(name: "boot profile trap costs")
    /// Key: trap number (faults -1000) * 2 + (1 before the milestone).
    private var costs: [Int64: TrapCost] = [:]

    func recordTrapCost(number: Int64, preMilestone: Bool, wallNs: UInt64,
                        start: (userMicros: UInt64, systemMicros: UInt64, minorFaults: UInt64)) {
        let end = hostThreadTimes()
        let key = number * 2 + (preMilestone ? 1 : 0)
        costLock.withLock {
            var c = costs[key] ?? TrapCost()
            c.count &+= 1
            c.wallNs &+= wallNs
            c.userUs &+= end.userMicros &- start.userMicros
            c.sysUs &+= end.systemMicros &- start.systemMicros
            c.faults &+= end.minorFaults &- start.minorFaults
            costs[key] = c
        }
    }

    /// Arguments of chosen traps (`YCODE_BOOT_PROFILE_TRAPS=1`; guest-cpu.md
    /// §6): how often each distinct key (a sysctl name, a proc_info flavor,
    /// an madvise advice) was asked for.
    private var argCounts: [String: UInt64] = [:]
    func recordTrapArgs(_ key: String) {
        costLock.withLock { argCounts[key, default: 0] &+= 1 }
    }

    private func trapArgReport() -> String {
        let all = costLock.withLock { argCounts }
        guard !all.isEmpty else { return "" }
        var out = "# trap arguments: count,key\n"
        for (k, v) in all.sorted(by: { $0.value > $1.value }).prefix(200) { out += "# arg \(v),\(k)\n" }
        return out
    }

    private func trapCostReport() -> String {
        let all = costLock.withLock { costs }
        guard !all.isEmpty else { return "" }
        var out = "# trap costs (phase pre = before the image's libSystem milestone): phase,trap,count,wall_ms,user_ms,sys_ms,minflt,wall_us_each\n"
        for (key, c) in all.sorted(by: { $0.value.wallNs > $1.value.wallNs }) {
            let pre = key & 1 == 1
            let number = (key - (pre ? 1 : 0)) / 2
            out += "# \(pre ? "pre" : "post"),\(number),\(c.count),\(c.wallNs / 1_000_000),\(c.userUs / 1000),\(c.sysUs / 1000),\(c.faults),"
                // swiftlint:disable:next empty_count - a counter, not a collection
                + "\(c.count == 0 ? 0 : c.wallNs / c.count / 1000)\n"
        }
        return out
    }

    // MARK: The sampler

    /// Starts the sampler thread (writes <path>.samples).
    func startSampler(launcher: VMMLauncher, lock: KernelLock) {
        let thread = Thread { [self] in
            guard let out = fopen(path + ".samples", "w") else { return }
            fputs("# t_s cpu_guest cpu_sys cpu_vmm (cores) R D | guest_threads: in_guest in_handler blocked | lock_busy_% | images | top images by CPU (cores) [| host mappings (every 10th line)]\n", out)
            var sampleNumber = 0
            fflush(out)
            var last = processTimes()
            var lastLock: UInt64 = lock.withLock { lock.totalHeldNanoseconds }
            var lastNs = monotonicNanoseconds()
            var lastThreadCPU: [Int: UInt64] = [:]
            let ticks = Double(hostClockTicks)
            while true {
                usleep(Self.intervalMilliseconds * 1000)
                let now = monotonicNanoseconds()
                let wall = Double(now &- lastNs) / 1e9
                let times = processTimes()
                let held = lock.withLock { lock.totalHeldNanoseconds }
                let (r, d) = hostThreadStates()
                var inGuest = 0, inHandler = 0, blocked = 0
                var perImage: [(name: String, pid: Int32, cores: Double)] = []
                var long: [String] = []
                let nowMs = monotonicMilliseconds()
                var seen: [Int: UInt64] = [:]
                for image in launcher.snapshotLiveImages {
                    for w in image.pool.snapshotWorkers.workers {
                        guard let ctx = w.context as? ThreadContext else { continue }
                        if !w.inHandler.load(ordering: .relaxed) { inGuest += 1 } else if ctx.blockedInKernel { blocked += 1 } else {
                            inHandler += 1
                            // A long busy handler (not a kernel wait): which trap.
                            let age = nowMs &- w.handlerSince.load(ordering: .relaxed)
                            if age >= 200 {
                                long.append("\((image.record.executable as NSString).lastPathComponent):\(image.pid):"
                                    + "x16=\(Int64(bitPattern: w.lastTrapX16.load(ordering: .relaxed))):\(age)ms")
                            }
                        }
                    }
                    var cpu: UInt64 = 0
                    for tid in image.pool.hostThreadIDs {
                        guard let s = hostTaskStats(tid) else { continue }
                        seen[tid] = s[5]
                        cpu &+= s[5] &- (lastThreadCPU[tid] ?? 0)
                    }
                    if cpu > 0 {
                        perImage.append(((image.record.executable as NSString).lastPathComponent, image.pid, Double(cpu) / 1e9 / wall))
                    }
                }
                lastThreadCPU = seen
                let guest = Double(times.guest &- last.guest) / ticks / wall
                let system = Double(times.system &- last.system) / ticks / wall
                let user = Double(times.user &- last.user) / ticks / wall
                let busy = 100 * Double(held &- lastLock) / 1e9 / wall
                perImage.sort { $0.cores > $1.cores }
                let top = perImage.prefix(8).map { "\($0.name):\($0.pid):" + String(format: "%.2f", $0.cores) }.joined(separator: " ")
                sampleNumber += 1
                let mappings = sampleNumber % 10 == 1 ? " | host mappings \(Self.hostMappingCount())" : ""
                let line = String(format: "%.2f %.2f %.2f %.2f %d %d | %d %d %d | %.1f | %d | ", Double(now &- startNs) / 1e9,
                                  guest, system, max(0, user - guest), r, d, inGuest, inHandler, blocked, busy,
                                  launcher.liveCount) + top + (long.isEmpty ? "" : " | long handlers: " + long.joined(separator: " "))
                    + mappings + "\n"
                fputs(line, out)
                fflush(out)
                (last, lastLock, lastNs) = (times, held, now)
            }
        }
        thread.name = "ycode boot profile"
        thread.start()
    }

    /// The number of host mappings (VMAs) of this process (/proc/self/maps lines).
    static func hostMappingCount() -> Int {
        guard let f = fopen("/proc/self/maps", "r") else { return -1 }
        defer { fclose(f) }
        var n = 0
        var buffer = [CChar](repeating: 0, count: 1 << 16)
        while true {
            let got = fread(&buffer, 1, buffer.count, f)
            if got <= 0 { break }
            for i in 0..<got where buffer[i] == 10 { n += 1 }
        }
        return n
    }

    /// The whole process's CPU times (clock ticks): user (guest included),
    /// system, guest.
    private func processTimes() -> (user: UInt64, system: UInt64, guest: UInt64) {
        guard let text = try? String(contentsOfFile: "/proc/self/stat", encoding: .utf8),
              let close = text.lastIndex(of: ")") else { return (0, 0, 0) }
        let f = text[text.index(close, offsetBy: 2)...].split(separator: " ")
        // After "pid (comm) ": f[0] = state (field 3); utime 14, stime 15, guest_time 43.
        guard f.count > 40 else { return (0, 0, 0) }
        return (UInt64(f[11]) ?? 0, UInt64(f[12]) ?? 0, UInt64(f[40]) ?? 0)
    }

    /// Host threads of this process runnable (R) and in uninterruptible sleep (D).
    private func hostThreadStates() -> (Int, Int) {
        guard let tids = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/task") else { return (0, 0) }
        var r = 0, d = 0
        for tid in tids {
            guard let n = Int(tid), let s = hostTaskStats(n) else { continue }
            if s[7] == UInt64(UInt8(ascii: "R")) { r += 1 } else if s[7] == UInt64(UInt8(ascii: "D")) { d += 1 }
        }
        return (r, d)
    }

    // MARK: The report

    /// Writes the per-image table and the per-program sums to `path`.
    func writeReport(records: [ImageRecord]) {
        let ticks = Double(hostClockTicks)
        func s(_ t: UInt64) -> String { String(format: "%.3f", Double(t) / ticks) }
        func ms(_ ns: UInt64) -> String { String(format: "%.1f", Double(ns) / 1e6) }
        func span(_ from: UInt64, _ to: UInt64) -> String { from == 0 || to == 0 ? "-" : ms(to &- from) }
        var out = "# ycode boot profile: \(records.count) images, \(String(format: "%.1f", Double(monotonicNanoseconds() &- startNs) / 1e9)) s\n"
        out += "# " + BackingStats.report + "\n"
        // Thread-start and wakeup latency (thread-latency.md §2).
        out += "# latency (YCODE_VCPU_WARM=\(VCPUPool.warmTarget), YCODE_WAKE_AFTER_UNLOCK=\(KernelLock.wakeAfterUnlock ? 1 : 0)): "
            // swiftlint:disable:next empty_count - sample counts, not collections
            + (VCPUPool.startLatency + VCPUPool.creationPhases + [KernelLock.wakeLatency]).filter { $0.count > 0 }.map(\.summary).joined(separator: " | ") + "\n"
        out += "# " + (launcherForReport?.prebuilt.report ?? "") + "; host mappings now \(Self.hostMappingCount())\n"
        if let arena = SharedFileArena.shared {
            out += "# file arena: \(arena.fileCount) files, \(arena.bytesUsed >> 20) MiB; huge-page copies: "
                + arena.promotions.map { "\($0.bytes >> 20) MiB in \($0.milliseconds) ms (\($0.hugeBytes >> 20) MiB in huge pages)" }.joined(separator: ", ")
                + "; hot chunks \(arena.hotChunks.load(ordering: .relaxed)) (\(arena.hotChunkFailures.load(ordering: .relaxed)) failed, "
                + "\(arena.hotNanoseconds.load(ordering: .relaxed) / 1_000_000) ms)\n"
        }
        if let rollup = try? String(contentsOfFile: "/proc/self/smaps_rollup", encoding: .utf8) {
            out += "# " + rollup.split(separator: "\n").filter { $0.hasPrefix("Rss:") || $0.hasPrefix("AnonHugePages:") }
                .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }.joined(separator: "; ") + "\n"
        }
        out += trapCostReport()
        out += trapArgReport()
        out += "serial,pid,ppid,name,launch_s,build_ms,first_run_ms,milestone_ms,end_s,life_s,teardown_ms,threads,vcpus,traps,"
            + "cpu_s,user_s,sys_s,guest_s,runqueue_s,kvm_run_s,handler_s,user_exits,kvm_exits,wfx_exits,minflt,majflt,"
            + "lock_held_ms,lock_wait_ms,lock_acq,starts,start_wait_ms,start_wait_max_ms,"
            + "m_traps,m_lock_wait_ms,m_lock_held_ms,m_cpu_ms,m_guest_s,m_sys_s,m_run_ms,m_handler_ms,m_top_traps,tl_traps,"
            + "req_to_launch_ms,vm_ms,load_ms,vcpu0_ms,activate_ms,prebuilt,m_kvm_exits,m_user_exits,m_wfx_exits,m_minflt,end\n"
        struct Sum { var images = 0; var stats = VCPUPool.HostStats(); var lifeNs: UInt64 = 0; var lockHeld: UInt64 = 0
            var lockWait: UInt64 = 0; var traps = 0; var buildNs: UInt64 = 0; var firstRunNs: UInt64 = 0; var milestoneNs: UInt64 = 0 }
        var sums: [String: Sum] = [:]
        var total = Sum()
        for r in records {
            let st = r.hostStats ?? VCPUPool.HostStats()
            let name = (r.executable as NSString).lastPathComponent
            let endNs = r.endNs != 0 ? r.endNs : r.tornDownNs
            out += "\(r.serial),\(r.pid),\(r.ppid),\(name),\(seconds(r.launchNs)),\(span(r.launchNs, r.builtNs)),"
                + "\(span(r.launchNs, r.firstRunNs)),\(span(r.launchNs, r.milestoneNs)),\(seconds(endNs)),"
                + "\(r.launchNs == 0 || endNs == 0 ? "-" : String(format: "%.3f", Double(endNs &- r.launchNs) / 1e9)),"
                + "\(span(endNs, r.tornDownNs)),\(st.threads),\(r.vcpus),\(r.traps),"
                + "\(String(format: "%.3f", Double(st.cpuNanoseconds) / 1e9)),\(s(st.userTicks)),\(s(st.systemTicks)),\(s(st.guestTicks)),"
                + "\(String(format: "%.3f", Double(st.runQueueNanoseconds) / 1e9)),\(String(format: "%.3f", Double(st.runNanoseconds) / 1e9)),"
                + "\(String(format: "%.3f", Double(st.handlerNanoseconds) / 1e9)),\(st.userExits),\(st.kvmExits),\(st.wfxExits),"
                + "\(st.minorFaults),\(st.majorFaults),\(ms(r.lockHeldNs)),\(ms(r.lockWaitNs)),\(r.lockAcquisitions),"
                + "\(st.starts),\(ms(st.startWaitNanoseconds)),\(ms(st.maxStartWaitNanoseconds)),"
                + "\(r.milestoneTraps),\(ms(r.milestoneLockWaitNs)),\(ms(r.milestoneLockHeldNs)),\(ms(r.milestoneCPUNs)),"
                + "\(s(r.milestoneGuestTicks)),\(s(r.milestoneSystemTicks)),\(ms(r.milestoneRunNs)),\(ms(r.milestoneHandlerNs)),\(r.milestoneTopTraps),\(r.taskLocalTraps),"
                + "\(span(r.requestNs, r.launchNs)),\(span(r.launchNs, r.vmReadyNs)),\(span(r.vmReadyNs, r.loadedNs)),"
                + "\(span(r.loadedNs, r.vcpuReadyNs)),\(span(r.launchNs, r.activatedNs)),\(r.prebuiltVM),"
                + "\(r.milestoneKVMExits),\(r.milestoneUserExits),\(r.milestoneWFxExits),\(r.milestoneMinorFaults),\(r.endDescription.replacingOccurrences(of: ",", with: ";"))\n"
            for key in [name, "(all)"] {
                var m = key == "(all)" ? total : (sums[key] ?? Sum())
                m.images += 1
                m.stats.add(st)
                if r.launchNs != 0, endNs >= r.launchNs { m.lifeNs &+= endNs &- r.launchNs }
                m.lockHeld &+= r.lockHeldNs
                m.lockWait &+= r.lockWaitNs
                m.traps += r.traps
                if r.builtNs != 0 { m.buildNs &+= r.builtNs &- r.launchNs }
                if r.firstRunNs != 0 { m.firstRunNs &+= r.firstRunNs &- r.launchNs }
                if r.milestoneNs != 0 { m.milestoneNs &+= r.milestoneNs &- r.launchNs }
                if key == "(all)" { total = m } else { sums[key] = m }
            }
        }
        out += "\n# by program (sums; *_mean_ms are means per image)\n"
        out += "name,images,life_s,cpu_s,user_s,sys_s,guest_s,vmm_s,runqueue_s,kvm_run_s,handler_s,user_exits,kvm_exits,minflt,"
            + "lock_held_ms,lock_wait_ms,traps,starts,start_wait_ms,build_mean_ms,first_run_mean_ms,milestone_mean_ms\n"
        for (name, m) in [("(all)", total)] + sums.sorted(by: { $0.value.stats.cpuNanoseconds > $1.value.stats.cpuNanoseconds }) {
            let st = m.stats
            let n = Double(max(1, m.images))
            out += "\(name),\(m.images),\(String(format: "%.1f", Double(m.lifeNs) / 1e9)),\(String(format: "%.2f", Double(st.cpuNanoseconds) / 1e9)),"
                + "\(s(st.userTicks)),\(s(st.systemTicks)),\(s(st.guestTicks)),\(s(st.userTicks &- min(st.userTicks, st.guestTicks))),"
                + "\(String(format: "%.2f", Double(st.runQueueNanoseconds) / 1e9)),\(String(format: "%.2f", Double(st.runNanoseconds) / 1e9)),"
                + "\(String(format: "%.2f", Double(st.handlerNanoseconds) / 1e9)),\(st.userExits),\(st.kvmExits),\(st.minorFaults),"
                + "\(ms(m.lockHeld)),\(ms(m.lockWait)),\(m.traps),\(st.starts),\(ms(st.startWaitNanoseconds)),"
                + "\(String(format: "%.1f", Double(m.buildNs) / 1e6 / n)),\(String(format: "%.1f", Double(m.firstRunNs) / 1e6 / n)),"
                + "\(String(format: "%.1f", Double(m.milestoneNs) / 1e6 / n))\n"
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
        let pcs = pcReport()
        if !pcs.isEmpty { try? pcs.write(toFile: path + ".pcs", atomically: true, encoding: .utf8) }
        let loader = pcLock.withLock { loaderSamples }
        if !loader.isEmpty {
            let text = loader.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: "\n") + "\n"
            try? text.write(toFile: path + ".loader", atomically: true, encoding: .utf8)
        }
        stderrLine("ycode-simd: boot profile: \(path) (\(records.count) images)")
    }
}
#endif
