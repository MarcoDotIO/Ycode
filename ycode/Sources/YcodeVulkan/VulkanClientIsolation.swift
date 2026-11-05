// Client isolation of VulkanMetalBackend (metal-sim-protocol.md §8.8).
//
// Every Metal client process shares one Vulkan device and one queue, and
// the completion thread completes submissions in order. A submission that
// never ends therefore holds up every client: nothing behind it runs, and
// no completion handler behind it is called. Separate queues do not help on
// the Thor: work on a second queue of the same device does not run while a
// submission on the first never ends (`scripts/gpu-probes/queuekick.c`); a
// second device does, but only after the driver has killed the stuck
// context (about 4.3 s, a context-switch timeout). Work that does not end
// can only be ended by losing the device (VulkanDeviceReset.swift).
//
// So the stuck client is isolated by time and by blame:
//
// 1. The blocking watchdog: a submission still running after
//    `blockingWatchdogSeconds` (2 s) while command buffers of other client
//    processes wait behind it is ended at once, as the plain watchdog ends
//    any submission after `watchdogSeconds` (10 s). One hang line names the
//    stuck client, its command buffer and the clients it held up.
// 2. The reset fails the stuck command buffer **and every other command
//    buffer of the same process** still queued, held or refused meanwhile;
//    the other clients' work is recorded again and completes normally.
// 3. A process whose work had to be ended `revokeAfterHangs` times (2)
//    loses GPU access: its later command buffers fail at once without
//    running (Metal's `MTLCommandBufferErrorAccessRevoked`, "the process was
//    denied access to the GPU"), so it cannot stall the others again.

import CVulkan
import Foundation
import YcodeMetalHost

extension VulkanMetalBackend {
    /// What the completion thread waits for and who waits behind it. Under the lock.
    struct BlockedClients {
        /// The process of the submission being waited for (nil: Ycode's own
        /// work, such as a setup submission).
        var stuck: MetalProcessID?
        /// Command buffers of other processes queued, held or refused behind it.
        var others: [MetalProcessID: Int] = [:]
        var label = ""
    }

    /// The client of the submission with serial `serial` and the other
    /// clients whose command buffers wait. Under the lock.
    func blockedClients(behind serial: UInt64) -> BlockedClients {
        let first = pending.first { $0.serial >= serial && $0.commandBuffer != nil }
        var b = BlockedClients(stuck: first?.commandBuffer?.process, label: first?.label ?? pending.first?.label ?? "")
        func note(_ p: MetalProcessID?) {
            guard let p, p != b.stuck else { return }
            b.others[p, default: 0] += 1
        }
        for e in pending where e.serial > serial || (e.serial == serial && e.commandBuffer?.process != b.stuck) {
            note(e.commandBuffer?.process)
        }
        for item in parked { note(item.commandBuffer?.process) }
        return b
    }

    /// Whether the watchdog ends the submission `serial` after `ran`
    /// seconds, and why (nil: not yet). The blocking rule is checked only
    /// once `ran` passed its limit, so the scan costs nothing before that.
    /// Takes the lock.
    func watchdogReason(serial: UInt64, ran: Double) -> (reason: String, blocked: BlockedClients)? {
        let plain = options.watchdogSeconds > 0 && ran >= options.watchdogSeconds
        let blocking = options.blockingWatchdogSeconds > 0 && ran >= options.blockingWatchdogSeconds
        guard plain || blocking else { return nil }
        cond.lock()
        let b = blockedClients(behind: serial)
        cond.unlock()
        if !b.others.isEmpty && blocking {
            let n = b.others.values.reduce(0, +)
            return ("\(n) command buffer\(n == 1 ? "" : "s") of \(b.others.count) other client\(b.others.count == 1 ? "" : "s") "
                    + "waited behind it (\(b.others.keys.sorted().map(describeClient).joined(separator: ", ")))", b)
        }
        return plain ? ("the watchdog's limit is \(Self.seconds(options.watchdogSeconds))", b) : nil
    }

    /// "process 7 (WeatherPoster, guest pid 312)". Not under the lock: the
    /// describer may take the Metal service's lock.
    func describeClient(_ p: MetalProcessID?) -> String {
        guard let p else { return "Ycode's own work" }
        cond.lock()
        var name = clientNames[p]
        cond.unlock()
        if name == nil, let d = options.describeProcess?(p) {
            name = d
            cond.lock(); clientNames[p] = d; cond.unlock()
        }
        return "process \(p)" + (name.map { " (\($0))" } ?? "")
    }

    /// The name already known for a client (under the lock; never calls the describer).
    func knownClient(_ p: MetalProcessID) -> String {
        "process \(p)" + (clientNames[p].map { " (\($0))" } ?? "")
    }

    static func seconds(_ s: Double) -> String { String(format: "%.1f s", s) }

    /// The reset's share (VulkanDeviceReset.swift): every command buffer of
    /// the stuck item's process fails with it, and the process is charged
    /// one hang (and loses GPU access at `revokeAfterHangs`). Returns the
    /// process and whether its access was revoked now. Under the lock.
    func blameStuckClient(_ items: inout [ResubmitItem]) -> (process: MetalProcessID, failed: Int, revoked: Bool)? {
        guard let guilty = items.first(where: \.guilty), let p = guilty.commandBuffer?.process else { return nil }
        var failed = 0
        for i in items.indices where items[i].commandBuffer?.process == p {
            items[i].guilty = true
            failed += 1
        }
        hangsByProcess[p, default: 0] += 1
        statistics.clientHangs += 1
        var revoked = false
        if options.revokeAfterHangs > 0, hangsByProcess[p]! >= options.revokeAfterHangs, !revokedProcesses.contains(p) {
            revokedProcesses.insert(p)
            statistics.revokedClients += 1
            revoked = true
        }
        return (p, failed, revoked)
    }

    /// A command buffer of a process whose GPU access was revoked: it fails
    /// without running (after the process's earlier work, keeping the
    /// order of its completions). Under the lock. True when refused.
    func refuseRevoked(_ mcb: MetalCommandBuffer, scheduled: @escaping @Sendable () -> Void,
                       completed: @escaping @Sendable (Int) -> Void) -> Bool {
        guard revokedProcesses.contains(mcb.process) else { return false }
        refusedByProcess[mcb.process, default: 0] += 1
        statistics.revokedRefusals += 1
        let n = refusedByProcess[mcb.process]!
        if n == 1 || n % 1000 == 0 {
            log("GPU access revoked: command buffer \(mcb.commandBufferRef) of \(knownClient(mcb.process)) fails without running "
                + "(\(n) so far)")
        }
        enqueueCompletion(status: MetalCommandBufferStatus.error, scheduled: scheduled, completed: completed)
        return true
    }

    /// Ends the stuck work by giving the GPU to a second context of ours
    /// (made at the first hang and kept): an empty kernel there makes the
    /// driver end the context that will not yield (a context-switch
    /// timeout, about 4 s on the Thor), and the stuck device's waits then
    /// fail at once. Without the kick only waiting the device idle ends it,
    /// in 4–59 s (`scripts/gpu-probes/queuekick.c`; §8.8). On the completion
    /// thread, outside the lock. Returns what happened, for the log.
    func kickGPU() -> String {
        guard options.kick else { return "off" }
        let start = DispatchTime.now().uptimeNanoseconds
        if kicker == nil {
            let c = UnsafeMutablePointer<yvk_context>.allocate(capacity: 1)
            c.initialize(to: yvk_context())
            var opts = yvk_context_options(maxSampledImages: 16, maxSamplers: 16, maxStorageImages: 16, validation: 0,
                                           queues: 1, second: 1)
            var err = [CChar](repeating: 0, count: 512)
            guard yvk_context_create(c, &opts, &err, err.count) == 0 else {
                c.deallocate()
                return "no second device (\(cString(err)))"
            }
            kicker = c
        }
        let made = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
        let r = yvk_kick(kicker, 15_000_000_000)
        let ran = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
        if r != VK_SUCCESS {
            // A kicker that timed out or was lost is not used again.
            if r == VK_ERROR_DEVICE_LOST, let k = kicker { yvk_context_destroy(k); k.deallocate() }
            kicker = nil
        }
        return String(format: "%@ after %.1f s (second device %@)", r == VK_SUCCESS ? "ran" : "failed (\(r.rawValue))", ran,
                      made > 0.001 ? String(format: "made in %.1f s", made) : "kept")
    }

    /// Shutdown: frees the kick's device (the completion thread has ended).
    func destroyKicker() {
        guard let k = kicker else { return }
        kicker = nil
        yvk_context_destroy(k)
        k.deallocate()
    }

    /// Tests and diagnostics: whether a client process has lost GPU access,
    /// and the last hang line.
    public func gpuAccessRevoked(_ p: MetalProcessID) -> Bool {
        cond.lock(); defer { cond.unlock() }
        return revokedProcesses.contains(p)
    }

    public var lastHangReport: String {
        cond.lock(); defer { cond.unlock() }
        return lastHang
    }
}
