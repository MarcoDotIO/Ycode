import YcodeDarwinABI

// The fine steps of the port lock split (`specs/simulator/mach-ipc-locking.md`
// §4.12, `PortLockSplit.swift`). Each one checks, reading only, that the
// locked path's own code would touch nothing but state owned by the spaces
// it names, then runs that code under those spaces' locks and G shared.
//
// | Step | Spaces | Declines when (among others) |
// |---|---|---|
// | send of a fast `mach_msg`/`mach_msg2`, send only, simple message | sender, the destination's receiver, the reply port's receiver | a receive in the same trap; complex; a kernel-object, dead or host-held destination; a full queue; a waiting receiver; a reply or sync push; importance that would leave the receiver's process |
// | receive of a fast `mach_msg`/`mach_msg2`, receive only, and the kevent EVFILT_MACHPORT receive | receiver, the reply right's port's receiver | no message queued and the receive would wait; complex; a pushed or held message; blocked senders; a no-senders notification due |
// | `mach_port_deallocate` | caller, the port's receiver | a send-once right, a port set, a dead-name request on the name, a no-senders notification due, a kernel object |
// | readiness queries (`messageQueued`, `receiveTarget`), the end of a servicing episode | caller | a dead port under the name; a push or demand start to end |

extension MachIPC {
    /// The process `p` belongs to the space `space` (its importance count is
    /// that space's state among fine steps).
    @inline(__always) func fineOwns(_ proc: DarwinProcess?, _ space: MachIPC?) -> Bool {
        guard let proc, let space, let k = proc.kernel else { return false }
        return (k.machIPC as? MachIPC) === space
    }

    /// The header fields a fine send checks, from the registers (`mach_msg2`)
    /// or the prefetched send bytes (`mach_msg`). Nil when not available.
    private func fineHeader(_ n: Int, _ frame: TrapFrame) -> (options: UInt64, bits: UInt32, remote: UInt32, local: UInt32,
                                                             voucher: UInt32, descriptors: UInt32)? {
        if n == Trap.machMsg2 {
            let x = frame.x
            return (x[1], UInt32(truncatingIfNeeded: x[2]) & MachMsgBits.user, UInt32(truncatingIfNeeded: x[3]),
                    UInt32(truncatingIfNeeded: x[3] >> 32), UInt32(truncatingIfNeeded: x[4]), UInt32(truncatingIfNeeded: x[5]))
        }
        let options = UInt64(UInt32(truncatingIfNeeded: frame.x[1]))
        guard options & MachMsgOption.sendMsg != 0 else {
            return (options, 0, 0, 0, 0, 0)
        }
        guard let p = KernelThreadLocks.current.prefetchedSend, p.va == frame.x[0], p.bytes.count >= 24 else { return nil }
        let b = p.bytes
        let bits = b.readLE(UInt32.self, at: 0) & MachMsgBits.user
        let descriptors = bits & MachMsgBits.complex != 0 && b.count >= 28 ? b.readLE(UInt32.self, at: 24) : 0
        return (options, bits, b.readLE(UInt32.self, at: 8), b.readLE(UInt32.self, at: 12), b.readLE(UInt32.self, at: 16),
                descriptors)
    }

    /// A fast `mach_msg`/`mach_msg2` as a fine step, or nil (nothing changed)
    /// when it must run under G exclusive. Only a send alone or a receive
    /// alone; the trap's own handler runs under the fine locks.
    func fineMachMsg(_ n: Int, _ frame: inout TrapFrame, context: ThreadContext,
                     memory: any GuestVirtualMemory) -> TrapOutcome? {
        guard let h = fineHeader(n, frame) else {
            PortLockSplit.decline(.header)
            return nil
        }
        let send = h.options & MachMsgOption.sendMsg != 0
        let receives = h.options & MachMsgOption.rcvMsg != 0
        if send && receives {
            PortLockSplit.decline(.combined)
            return nil
        }
        if send {
            let f = frame
            let out = fineStep({ held in fineSendCheck(h.options, msg2: n == Trap.machMsg2, bits: h.bits, remote: h.remote,
                                                       local: h.local, voucher: h.voucher, descriptors: h.descriptors,
                                                       held: held) }, {
                handleTrapLocked(x16: Int64(n), frame: &frame, context: context, memory: memory)
            })
            if out == nil { frame = f } else { PortLockSplit.serve(.send) }
            return out.flatMap { $0 }
        }
        if receives {
            guard let r = fineReceiveRequest(n, frame, memory: memory) else {
                PortLockSplit.decline(.header)
                return nil
            }
            // The receive the trap would run, with the request checked (its
            // vectors are not read again under the locks).
            let out = fineStep({ _ in fineReceiveCheck(r, context: context) }, { () -> TrapOutcome in
                frame.x[0] = UInt64(receive(r, context: context, memory: memory).code)
                return .resume
            })
            if out != nil { PortLockSplit.serve(.receive) }
            return out
        }
        return nil
    }

    // MARK: Send

    /// The checks of a fine send (`MachIPC.send`, `copyinHeader`, `deliver`,
    /// `enqueue`, `annotateForScheduling`), reading only. Space lock of this
    /// space held.
    func fineSendCheck(_ options: UInt64, msg2: Bool, bits: UInt32, remote: UInt32, local: UInt32, voucher: UInt32,
                       descriptors: UInt32, held: (MachIPC) -> Bool) -> FineCheck {
        if bits & MachMsgBits.complex != 0 || descriptors != 0 { return .decline(.complex) }
        let dd = MachMsgBits.remote(bits), rd = MachMsgBits.local(bits)
        guard MachMsgBits.voucher(bits) == 0,
              (MachMsgType.moveSend...MachMsgType.makeSendOnce).contains(dd),
              rd == 0 || (MachMsgType.moveSend...MachMsgType.makeSendOnce).contains(rd),
              rd != 0 || local == 0 else { return .decline(.header) }
        guard !(MachPortName.isValid(local) && rd != 0 && local == remote) else { return .decline(.header) }
        // The destination.
        guard MachPortName.isValid(remote), let i = slot(of: remote), let p = entries[i].port else {
            return .decline(.destination)
        }
        guard p.active else { return .decline(.deadPort) }
        guard !p.isKernelObject, p !== bootstrapPort else { return .decline(.kernelObject) }
        guard let receiver = p.receiver, receiver.kernel?.eventLock != nil else { return .decline(.hostSpace) }
        // The spaces first, from what changes only under G exclusive: the
        // ports' receivers. Their own state is read once their locks are held.
        var spaces = [self, receiver]
        var reply: (q: IPCPort, entry: IPCEntry)?
        if rd != 0, MachPortName.isValid(local) {
            guard let j = slot(of: local), let q = entries[j].port else { return .decline(.reply) }
            guard q.active else { return .decline(.deadPort) }
            guard let qr = q.receiver, !q.isKernelObject else { return .decline(.reply) }
            spaces.append(qr)
            reply = (q, entries[j])
        }
        guard spaces.allSatisfy(held) else { return .go(spaces) }
        let e = entries[i]
        switch dd {
        case MachMsgType.moveSend, MachMsgType.copySend:
            guard e.bits & T.send != 0 else { return .decline(.disposition) }
            if dd == MachMsgType.moveSend, e.urefs == 1, e.bits & T.receive == 0, p.dnRequests[dn(remote)] != nil {
                return .decline(.nameRequest)
            }
        case MachMsgType.moveSendOnce:
            guard e.bits & T.sendOnce != 0 else { return .decline(.disposition) }
            guard p.replyBoosts.isEmpty, p.replyPushes.isEmpty else { return .decline(.replyPush) }
            guard p.dnRequests[dn(remote)] == nil else { return .decline(.nameRequest) }
        default:
            // MAKE_SEND / MAKE_SEND_ONCE: the receive right is this space's.
            guard e.bits & T.receive != 0 else { return .decline(.disposition) }
        }
        if p.isSpecialReply, e.bits & T.portRights != 0, dd != MachMsgType.moveSendOnce, dd != MachMsgType.makeSendOnce {
            return .decline(.disposition)
        }
        // The reply right.
        var replySendOnce = false
        var replySpecial = false
        if let (q, f) = reply {
            switch rd {
            case MachMsgType.moveSend, MachMsgType.copySend:
                guard f.bits & T.send != 0 else { return .decline(.disposition) }
                if rd == MachMsgType.moveSend, f.urefs == 1, f.bits & T.receive == 0, q.dnRequests[dn(local)] != nil {
                    return .decline(.nameRequest)
                }
            case MachMsgType.moveSendOnce:
                guard f.bits & T.sendOnce != 0 else { return .decline(.disposition) }
                guard q.replyBoosts.isEmpty, q.replyPushes.isEmpty else { return .decline(.replyPush) }
                guard q.dnRequests[dn(local)] == nil else { return .decline(.nameRequest) }
                replySendOnce = true
            default:
                guard f.bits & T.receive != 0 else { return .decline(.disposition) }
                replySendOnce = rd == MachMsgType.makeSendOnce
            }
            if q.isSpecialReply, f.bits & T.portRights != 0, rd != MachMsgType.moveSendOnce, rd != MachMsgType.makeSendOnce {
                return .decline(.disposition)
            }
            replySpecial = q.isSpecialReply
        }
        // Scheduling (`annotateForScheduling`): no push records; importance
        // only within the receiver's process.
        if movedReplyPush != nil { return .decline(.replyPush) }
        if SchedPolicy.replyPushActive, replySendOnce, replySpecial { return .decline(.replyPush) }
        if !SchedPolicy.importanceTraced.isEmpty { return .decline(.importance) }
        if SchedPolicy.importanceEnabled, options & MachMsgOption.sendNoImportance == 0, p.importanceDonation,
           let proc = kernel?.schedProcess, proc.isImportanceDonor {
            guard p.watchProcess == nil else { return .decline(.importance) }
            if let c = p.creditedProcess, !fineOwns(c, receiver) { return .decline(.importance) }
            if let t = importanceTarget(p), !fineOwns(t, receiver) { return .decline(.importance) }
        }
        if LookupHold.enabled { return .decline(.lookupHold) }
        if MachTrafficStats.enabled { return .decline(.stats) }
        // Delivery (`deliver`): no error that pseudo-receives, no wait.
        if msg2, options & MachMsgOption.sendAny == 0, options & MachMsgOption.sendMQCall == 0 { return .decline(.msg2Options) }
        if p.messages.count >= MachIPCLimits.qlimitKernel { return .decline(.queueLimit) }
        let sendOnceDestination = dd == MachMsgType.moveSendOnce || dd == MachMsgType.makeSendOnce
        if !sendOnceDestination, p.occupiedSlots >= p.qlimit { return .decline(.queueLimit) }
        // `enqueue` wakes no one.
        guard p.receiveWaiters.isEmpty, p.sets.allSatisfy({ $0.waiters.isEmpty }) else { return .decline(.waiters) }
        return .go(spaces)
    }

    // MARK: Receive

    /// The receive request of a fast `mach_msg`/`mach_msg2` receive, built as
    /// the trap builds it. Nil when its vectors cannot be read.
    private func fineReceiveRequest(_ n: Int, _ frame: TrapFrame, memory: any GuestVirtualMemory) -> MachReceiveRequest? {
        let a = frame.x
        if n == Trap.machMsg2 {
            let options = a[1]
            let data = a[0]
            var r = MachReceiveRequest(name: UInt32(truncatingIfNeeded: a[5] >> 32), options: options, buffer: data,
                                       size: UInt64(UInt32(truncatingIfNeeded: a[6])), timeout: UInt32(truncatingIfNeeded: a[7]))
            r.syncDestination = UInt32(truncatingIfNeeded: a[3])
            if options & MachMsgOption.msgVector != 0 {
                let count = Int(UInt32(truncatingIfNeeded: a[6]))
                guard count == 1 || count == 2, let raw = try? memory.read(va: data, count: 24 * count) else { return nil }
                let rcvAddr = raw.readLE(UInt64.self, at: 8)
                r.buffer = rcvAddr != 0 ? rcvAddr : raw.readLE(UInt64.self, at: 0)
                r.size = UInt64(raw.readLE(UInt32.self, at: 20))
                if count == 2 {
                    let auxAddr = raw.readLE(UInt64.self, at: 32)
                    r.auxBuffer = auxAddr != 0 ? auxAddr : raw.readLE(UInt64.self, at: 24)
                    r.auxSize = UInt64(raw.readLE(UInt32.self, at: 44))
                }
            }
            return r
        }
        let options = UInt64(UInt32(truncatingIfNeeded: a[1]))
        let buffer = n == Trap.machMsgOverwrite && a[7] != 0 ? a[7] : a[0]
        return MachReceiveRequest(name: UInt32(truncatingIfNeeded: a[4]), options: options, buffer: buffer,
                                  size: UInt64(UInt32(truncatingIfNeeded: a[3])), timeout: UInt32(truncatingIfNeeded: a[5]),
                                  syncDestination: UInt32(truncatingIfNeeded: a[6]))
    }

    /// The checks of a fine receive (`receive`, `awaitMessage`, `take`,
    /// `dequeue`, `copyoutReceived`, `receivedForScheduling`), reading only.
    /// Space lock of this space held.
    func fineReceiveCheck(_ r: MachReceiveRequest, context: ThreadContext) -> FineCheck {
        guard context.kernel === kernel, kernel != nil else { return .decline(.notSelf) }
        guard MachPortName.isValid(r.name), let i = slot(of: r.name) else { return .decline(.header) }
        let set = entries[i].set
        let port: IPCPort? = set == nil && entries[i].bits & T.receive != 0 ? entries[i].port : nil
        guard set != nil || port != nil else { return .decline(.header) }
        if r.options & MachMsgOption.rcvSyncWait != 0, context.replyWait != nil { return .decline(.replyWait) }
        if context.hasServicingState {
            // A push class ends with a class refresh of this thread only
            // (`endServicing`; its waited requests' classes are G's).
            guard context.ipcPushClass < 0 || !context.waitsOnRequest.load(ordering: .acquiring),
                  context.demandServing == nil else { return .decline(.servicing) }
            if let c = context.carriedImportance, !fineOwns(c, self) { return .decline(.servicing) }
        }
        let source = port.flatMap { $0.messages.isEmpty ? nil : $0 } ?? set.flatMap(readyMember)
        guard let source else {
            // `awaitMessage` answers MACH_RCV_TIMED_OUT at once, or waits.
            let immediate = r.options & MachMsgOption.rcvTimeout != 0 && r.timeout == 0
            return r.mayBlock && !immediate ? .decline(.wouldBlock) : .go([self])
        }
        guard source.receiver === self else { return .decline(.portSet) }
        guard let m = source.messages.first, m.destination.port === source else { return .decline(.message) }
        guard !m.complex, m.items.isEmpty else { return .decline(.complex) }
        guard m.syncPush == nil, m.pushClass < 0 else { return .decline(.message) }
        if m.importance {
            if let c = source.creditedProcess, !fineOwns(c, self) { return .decline(.importance) }
            if SchedPolicy.replyImportanceEnabled { return .decline(.importance) }
            if let proc = kernel?.schedProcess, !fineOwns(proc, self) { return .decline(.importance) }
        }
        guard source.demandPush == nil else { return .decline(.demandPush) }
        guard source.sendWaiters.isEmpty else { return .decline(.sendWaiters) }
        guard !source.hasArmedSendPossible else { return .decline(.sendPossible) }
        // `take`: too large is answered under G exclusive.
        let trailer = MachMsgOption.trailerSize(r.options)
        let auxNeeded = r.auxBuffer != nil ? max(8, m.aux?.count ?? 8) : 0
        if r.size < UInt64(m.size + trailer) || (r.auxBuffer != nil && r.auxSize < UInt64(auxNeeded)) {
            return .decline(.tooLarge)
        }
        // The destination right is consumed (`consumeDestination`).
        if case .send = m.destination {
            if source.srights == 1, source.nsRequest != nil { return .decline(.noSenders) }
            if source.fileportFile != nil || source.memoryEntry != nil { return .decline(.kernelObject) }
        }
        var spaces = [self]
        // The reply right is copied out into this space.
        switch m.reply {
        case .null, .dead:
            break
        case let .send(q):
            guard q.active else { return .decline(.deadPort) }
            guard let qr = q.receiver else { return .decline(.reply) }
            if reverse[ObjectIdentifier(q)] == nil, !fineHasFreeName { return .decline(.nameTable) }
            spaces.append(qr)
        case let .sendOnce(q):
            guard q.active else { return .decline(.deadPort) }
            if !fineHasFreeName { return .decline(.nameTable) }
        case .receive:
            return .decline(.reply)
        }
        return .go(spaces)
    }

    /// A new name can be allocated without growing past the table's limit.
    private var fineHasFreeName: Bool { !freeList.isEmpty || nextFresh < MachIPCLimits.maxIndex }

    /// The kevent EVFILT_MACHPORT receive as a fine step (`receiveForKevent`;
    /// the caller holds this image's event lock). Nil: run it under G exclusive.
    func fineKeventReceive(_ r: MachReceiveRequest, context: ThreadContext,
                           memory: any GuestVirtualMemory) -> MachReceiveResult? {
        let out = fineStep({ _ in fineReceiveCheck(r, context: context) }, {
            receive(r, context: context, memory: memory)
        })
        if out != nil { PortLockSplit.serve(.keventReceive) }
        return out
    }

    // MARK: Port routines and queries

    /// `mach_port_deallocate` as a fine step, or nil.
    func fineDeallocate(_ frame: inout TrapFrame, context: ThreadContext, memory: any GuestVirtualMemory) -> TrapOutcome? {
        let target = UInt32(truncatingIfNeeded: frame.x[0])
        let name = UInt32(truncatingIfNeeded: frame.x[1])
        let out = fineStep({ held -> FineCheck in
            guard let t = slot(of: target), entries[t].bits & T.send != 0, entries[t].port === taskPort, taskPort.active else {
                return .decline(.header)
            }
            guard MachPortName.isValid(name), let i = slot(of: name) else { return .go([self]) }
            let e = entries[i]
            if e.set != nil { return .decline(.portSet) }
            if let p = e.port, !p.active, e.bits & (T.send | T.sendOnce) != 0 { return .decline(.deadPort) }
            if e.bits & T.deadName != 0 { return .go([self]) }
            if e.bits & T.sendOnce != 0 { return .decline(.sendOnce) }
            guard e.bits & T.send != 0, let p = e.port else { return .go([self]) }
            if e.urefs == MachPortName.urefsMax || e.urefs > 1 { return .go([self]) }
            guard let q = p.receiver, !p.isKernelObject, p.fileportFile == nil, p.memoryEntry == nil else {
                return .decline(.kernelObject)
            }
            // The port's counters are its receiver's state.
            guard held(q) else { return .go([self, q]) }
            if e.bits & T.receive == 0, p.dnRequests[dn(name)] != nil { return .decline(.nameRequest) }
            if p.srights == 1, p.nsRequest != nil { return .decline(.noSenders) }
            return .go([self, q])
        }, {
            handleTrapLocked(x16: Int64(Trap.portDeallocate), frame: &frame, context: context, memory: memory)
        })
        if out != nil { PortLockSplit.serve(.deallocate) }
        return out.flatMap { $0 }
    }

    /// Ycode's `thread_get_state` as a fine step (the caller holds its
    /// image's event lock, which guards the thread table): it reads this
    /// space's names of the task's threads. Nil: under G exclusive.
    func fineThreadGetState(_ frame: inout TrapFrame, context: ThreadContext, memory: any GuestVirtualMemory) -> TrapOutcome? {
        guard let k = kernel, context.kernel === k, k.eventLock?.isHeldByCurrentThread == true else { return nil }
        let name = UInt32(truncatingIfNeeded: frame.x[0])
        let out = fineStep({ _ -> FineCheck in
            // No lazy dead-name conversion: every name it looks up is alive.
            func live(_ n: UInt32) -> Bool {
                guard let i = slot(of: n), let p = entries[i].port else { return true }
                return p.active || entries[i].bits & (T.send | T.sendOnce) == 0
            }
            guard live(name), k.threadsByPort.values.allSatisfy({ live($0.portName) }) else { return .decline(.deadPort) }
            return .go([self])
        }, {
            handleTrapLocked(x16: Int64(Int32(bitPattern: Routine.threadGetState)), frame: &frame, context: context, memory: memory)
        })
        if out != nil { PortLockSplit.serve(.threadState) }
        return out.flatMap { $0 }
    }

    /// The readiness of `name` for kevent (`messageQueued`, `receiveTarget`)
    /// as a fine step: this space's lock. Nil: under G exclusive.
    func fineQuery<Value>(_ name: UInt32, _ body: () -> Value) -> Value? {
        let out = fineStep({ _ -> FineCheck in
            if let i = slot(of: name), let p = entries[i].port, !p.active,
               entries[i].bits & (T.send | T.sendOnce) != 0 { return .decline(.deadPort) }
            return .go([self])
        }, body)
        if out != nil { PortLockSplit.serve(.query) }
        return out
    }

    /// The end of a servicing episode (`DarwinKernel.endServicing`) as a fine
    /// step: the carried importance of this space's process. False: not done.
    func fineEndServicing(_ ctx: ThreadContext) -> Bool {
        guard let k = kernel, ctx.kernel === k else { return false }
        let done = fineStep({ _ -> FineCheck in
            guard ctx.ipcPushClass < 0 || !ctx.waitsOnRequest.load(ordering: .acquiring),
                  ctx.demandServing == nil else { return .decline(.servicing) }
            if let c = ctx.carriedImportance, !fineOwns(c, self) { return .decline(.servicing) }
            return .go([self])
        }, { k.endServicing(ctx) }) != nil
        if done { PortLockSplit.serve(.servicing) }
        return done
    }
}
