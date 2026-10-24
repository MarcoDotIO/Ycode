// Event waits (`encodeWaitForEvent:value:` on an MTLEvent or MTLSharedEvent,
// metal-sim-protocol.md record 400) are kept on the host.
//
// Every Metal queue of every guest process shares one Vulkan queue. A
// Vulkan semaphore wait there holds up every later submission: other
// processes' frames and, worse, the very command buffer that is to signal
// the event when it comes from another Metal queue. That deadlock ends in
// device loss (seen on the Thor: iconservicesagent's icon rendering waited
// on an event signaled by a later command buffer; every client's Metal
// stopped). Metal itself only orders the command buffers of one queue
// (Metal documentation, MTLCommandQueue and MTLEvent; level 1).
//
// So the work after an unsatisfied wait is recorded at once but held on the
// host, per (process, Metal queue), and submitted in order once the event's
// value is reached. Command buffers of the same Metal queue that arrive
// meanwhile are held behind it; other queues go on. A wait whose value is
// already reached costs nothing. Objects released while work is held are
// destroyed only after the held work has been submitted and completed.

import CVulkan
import Foundation
import YcodeMetalHost

/// Where the command buffers of one Metal queue are held.
struct HeldKey: Hashable {
    var process: MetalProcessID
    var queue: MetalHandle?
}

/// One step of held work, in order.
enum HeldItem {
    /// Wait until the timeline semaphore reaches the value.
    case wait(VkSemaphore, UInt64)
    case submit(Recording, VulkanMetalBackend.PendingSubmission?)
    /// Signal the timeline semaphore to the value (after the earlier steps were submitted).
    case signal(VkSemaphore, UInt64)
}

/// Where one Metal command buffer's recordings go: straight to the queue,
/// or (once it, or an earlier command buffer of its Metal queue, waits for
/// an event) into the held list.
final class SubmitSink {
    let key: HeldKey
    var holding: Bool
    var items: [HeldItem] = []
    /// Frame-trace details (diagnostics).
    var surfacesIn: [UInt32] = [], surfacesOut: [UInt32] = []
    var earlierDraws = 0
    /// The frame trace's timestamp slot and segment labels (`YCODE_METAL_TRACE_SEGMENTS=1`).
    var traceSlot = -1
    var segments: [String] = []
    init(key: HeldKey, holding: Bool) {
        self.key = key
        self.holding = holding
    }
}

extension VulkanMetalBackend {
    /// Submits `rec`, or holds it. Under the lock.
    func sinkSubmit(_ sink: SubmitSink, _ rec: Recording, entry: PendingSubmission?) throws {
        if sink.holding {
            rec.deferred = true
            _ = fn.vkEndCommandBuffer!(rec.cb)
            sink.items.append(.submit(rec, entry))
        } else {
            try submitRecording(rec, entry: entry)
        }
    }

    /// An event wait: true when the rest of the command buffer must go into
    /// a new recording (the wait is not yet satisfied, or work is held
    /// already and the wait must be checked in order). Under the lock.
    func sinkWait(_ sink: SubmitSink, _ sem: VkSemaphore, value: UInt64) -> Bool {
        if !sink.holding && yvk_timeline_value(ctx, sem) >= value { return false }
        sink.holding = true
        sink.items.append(.wait(sem, value))
        return true
    }

    /// An event signal after the work recorded so far. Under the lock.
    func sinkSignal(_ sink: SubmitSink, _ sem: VkSemaphore, value: UInt64) {
        if sink.holding {
            sink.items.append(.signal(sem, value))
        } else {
            _ = yvk_submit(ctx, nil, sem, value, nil, 0)
        }
    }

    /// Queues the items a command buffer left held. Under the lock.
    func hold(_ sink: SubmitSink) {
        guard !sink.items.isEmpty else { return }
        if held[sink.key] == nil { heldSince[sink.key] = DispatchTime.now().uptimeNanoseconds }
        held[sink.key, default: []].append(contentsOf: sink.items)
        sink.items.removeAll()
        if heldThread == nil {
            let thread = Thread { [unowned self] in self.heldLoop() }
            thread.name = "ycode-vulkan-held"
            heldThread = thread
            thread.start()
        }
        cond.broadcast()
    }

    /// Releases held work whose waits are satisfied, every millisecond while
    /// any is held.
    func heldLoop() {
        cond.lock()
        while running {
            if held.isEmpty {
                cond.wait(until: Date(timeIntervalSinceNow: 0.05))
                continue
            }
            releaseHeldLocked()
            if !held.isEmpty { cond.wait(until: Date(timeIntervalSinceNow: 0.001)) }
        }
        // Shutting down: drop what is still held.
        for items in held.values {
            for case let .submit(rec, entry) in items {
                if let cb = rec.cb { freeCommandBuffers.append(cb) }
                for c in rec.chunks { recycle(c) }
                if let entry {
                    enqueueCompletion(status: MetalCommandBufferStatus.error, scheduled: entry.scheduled,
                                      completed: entry.completed)
                }
            }
        }
        held.removeAll()
        releaseHeldGraveyardLocked()
        heldThread = nil
        cond.broadcast()  // the completion thread ends only after this thread
        cond.unlock()
    }

    /// Under the lock.
    func releaseHeldLocked() {
        let now = DispatchTime.now().uptimeNanoseconds
        for key in Array(held.keys) {
            var items = held[key] ?? []
            steps: while let first = items.first {
                switch first {
                case .wait(let sem, let value):
                    let current = yvk_timeline_value(ctx, sem)
                    guard current >= value || deviceLost else {
                        let since = heldSince[key] ?? now
                        let seconds = (now &- since) / 1_000_000_000
                        if seconds >= 10, (heldReported[key] ?? 0) < seconds / 10 {
                            heldReported[key] = seconds / 10
                            log("process \(key.process) queue \(key.queue.map { "\($0)" } ?? "-"): held \(seconds) s "
                                + "waiting for an event to reach \(value) (now \(current)); \(items.count) steps held")
                        }
                        break steps
                    }
                    items.removeFirst()
                    heldSince[key] = now
                    heldReported[key] = nil
                case .submit(let rec, let entry):
                    items.removeFirst()
                    do {
                        try submitPreparedRecording(rec, entry: entry)
                    } catch {
                        log("held command buffer of process \(key.process): \(error)")
                        if let cb = rec.cb { freeCommandBuffers.append(cb) }
                        for c in rec.chunks { recycle(c) }
                        if let entry {
                            enqueueCompletion(status: MetalCommandBufferStatus.error, scheduled: entry.scheduled,
                                              completed: entry.completed)
                        }
                    }
                case .signal(let sem, let value):
                    items.removeFirst()
                    if value > yvk_timeline_value(ctx, sem) { _ = yvk_submit(ctx, nil, sem, value, nil, 0) }
                }
            }
            if items.isEmpty {
                held[key] = nil
                heldSince[key] = nil
                heldReported[key] = nil
            } else {
                held[key] = items
            }
        }
        if held.isEmpty { releaseHeldGraveyardLocked() }
    }

    /// Objects released while work was held: destroyed after everything
    /// submitted so far. Under the lock.
    func releaseHeldGraveyardLocked() {
        guard !heldGraveyard.isEmpty else { return }
        let actions = heldGraveyard
        heldGraveyard.removeAll()
        for a in actions { deferDestroy(a) }
    }
}
