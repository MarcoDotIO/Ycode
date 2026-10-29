// The guest-facing camera endpoint `dev.ycode.camera` (camera.md §7.2 B and
// "Ycode implementation"; wire format in CameraGuestProtocol.swift). It is
// registered into the guest only when the device's camera is turned on
// (CameraOptIn). It announces the host camera as one capture device, starts
// and stops streams for guest processes, and sends each frame of the host
// camera layer (CameraHostService, camera-host.md) to the streaming process
// as a message naming a host-made IOSurface, with its presentation time in
// guest mach ticks. Flow control: a delivered frame's surface stays held
// until the guest releases it (request 4), so the ring never overwrites a
// frame the guest still reads; with no free surface the host drops the new
// frame and the next one carries the count.
//
// One guest process streams at a time (§7.2 C, step 10): a second process
// starting a stream interrupts the first, which gets the camera back when
// the second stops or ends.

import CYcodeCamera
import Foundation
import YcodeDarwinABI
import YcodeDarwinKernel

public final class CameraGuestService: @unchecked Sendable {
    public static let serviceName = CameraGuestProtocol.serviceName
    /// `YCODE_DEBUG_CAMERA=1`: one line per request.
    static let debug = getenv("YCODE_DEBUG_CAMERA").map { String(cString: $0) == "1" } ?? false

    public let servicePort: UInt32
    let portSet: UInt32
    let notifyPort: UInt32
    let host: MachHostTask
    let camera: CameraHostService
    /// The host camera selection (`CameraHostService.resolve`).
    public let selection: String
    public let presentation: CameraGuestPresentation
    let log: (String) -> Void
    let lock = NSLock()
    private var stopping = false
    /// Frames each stream may hold before the host drops (the ring).
    public var ringSize = 8

    /// Guest mach time now and its frequency (set by the VMM; the default is
    /// the host's 24 MHz timebase on the monotonic clock, as for audio).
    private var guestClock: @Sendable () -> (ticks: UInt64, frequency: UInt64) = { (MachTimebase.now(), MachTimebase.frequency) }
    public func setGuestClock(_ clock: @escaping @Sendable () -> (ticks: UInt64, frequency: UInt64)) {
        lock.withLock { guestClock = clock }
    }

    struct Client {
        /// The host-task name of the send right to the client's frame port.
        var port: UInt32
        var pid: Int32
        var streamID: UInt32
        var configuration: CameraConfiguration
    }

    /// Streaming clients by frame-port name.
    private var clients: [UInt32: Client] = [:]
    /// The client the camera streams to, and the interrupted ones (latest last).
    private var active: UInt32?
    private var waiting: [UInt32] = []
    private var nextStreamID: UInt32 = 1
    /// Increases at each camera start; frames of an older start are not sent.
    private var generation: UInt64 = 0
    /// Frames the guest holds, by sequence (the active stream).
    private var outstanding: [UInt64: CameraFrame] = [:]
    /// Frames the guest could not take (its queue was full) since the last sent one.
    private var unsent = 0
    private var device: CameraDevice?

    /// Statistics.
    public private(set) var requests = 0
    public private(set) var framesSent = 0
    public private(set) var framesNotSent = 0
    public private(set) var framesReleased = 0
    public private(set) var streamsStarted = 0

    public init(host: MachHostTask, surfaces: IOSurfaceHostService, selection: String,
                presentation: CameraGuestPresentation, log: @escaping (String) -> Void) throws {
        self.host = host
        self.selection = selection
        self.presentation = presentation
        self.log = log
        camera = CameraHostService(surfaces: surfaces, log: log)
        servicePort = try host.makePort(sendRight: true, qlimit: 64)
        portSet = try host.makePortSet()
        notifyPort = try host.makePort()
        try host.addMember(servicePort, to: portSet)
        try host.addMember(notifyPort, to: portSet)
    }

    public func start() {
        let t = Thread { [self] in run() }
        t.name = "ycode-camera-guest"
        t.qualityOfService = .userInteractive
        t.start()
    }

    /// Ends the service: the stream stops and the camera is released.
    public func stop() {
        lock.withLock { stopping = true }
        camera.stop()
    }

    public var isStreaming: Bool { camera.isRunning }
    public var activeStreamID: UInt32? { lock.withLock { active.flatMap { clients[$0]?.streamID } } }
    public var heldFrames: Int { lock.withLock { outstanding.count } }

    // MARK: The service thread

    private func run() {
        log("camera: serving \(Self.serviceName) (camera \(selection), shown as \(presentation.placement.rawValue))")
        while !lock.withLock({ stopping }) {
            do {
                let m = try host.receive(on: portSet, timeout: 200_000_000, tracked: true)
                handle(m)
                host.finishedMessage()
            } catch let e as MachHostError where e == .timedOut || e == .interrupted || e == .portChanged {
                continue
            } catch let e as MachHostError where e == MachHostError(MachMsgReturn.rcvInvalidName) {
                break
            } catch {
                if !lock.withLock({ stopping }) { log("camera: receive failed: \(error); stopping") }
                break
            }
        }
        camera.stop()
    }

    func handle(_ m: MachHostReceivedMessage) {
        lock.withLock { requests += 1 }
        if m.localPort == notifyPort {
            deadName(m)
            return
        }
        let n = m.id &- CameraGuestProtocol.base
        let pid = m.sender?.pid ?? -1
        if Self.debug { log("camera: request \(n) from pid \(pid), \(CameraGuestProtocol.words(m.body)) words") }
        switch n {
        case CameraGuestProtocol.Request.devices:
            let data = (try? PropertyListSerialization.data(fromPropertyList: devicesPlist(), format: .binary, options: 0)) ?? Data()
            reply(m, descriptors: [.ool(data: [UInt8](data))], words: [UInt32(data.count)])
            dropRights(m, keeping: [])
        case CameraGuestProtocol.Request.start:
            let port = m.descriptors.compactMap { d -> UInt32? in
                if case let .port(name, _) = d { return name }
                return nil
            }.first
            let w = { CameraGuestProtocol.word(m.body, $0) }
            let result = startStream(port: port, pid: pid, deviceIndex: w(0), width: Int(w(1)), height: Int(w(2)),
                                     fpsMilli: w(3), pixelFormat: w(4))
            dropRights(m, keeping: result.keptPort.map { [$0] } ?? [])
            reply(m, words: result.words)
        case CameraGuestProtocol.Request.stop:
            let status = stopStream(id: CameraGuestProtocol.word(m.body, 0), reason: "stopped by pid \(pid)")
            dropRights(m, keeping: [])
            reply(m, words: [status])
        case CameraGuestProtocol.Request.release:
            let w = { CameraGuestProtocol.word(m.body, $0) }
            release(stream: w(0), sequence: CameraGuestProtocol.join(w(2), w(3)))
            dropRights(m, keeping: [])
        default:
            log("camera: unknown request \(m.id) from pid \(pid)")
            host.discard(m)
        }
    }

    private func reply(_ m: MachHostReceivedMessage, descriptors: [MachHostDescriptor] = [], words: [UInt32]) {
        guard MachPortName.isValid(m.replyPort) else { return }
        do {
            try host.reply(to: m, descriptors: descriptors, body: CameraGuestProtocol.body(words))
        } catch {
            log("camera: reply to \(m.id) failed: \(error)")
        }
    }

    private func dropRights(_ m: MachHostReceivedMessage, keeping: Set<UInt32>) {
        for d in m.descriptors {
            switch d {
            case let .port(name, _), let .guardedPort(name, _, _):
                if !keeping.contains(name), MachPortName.isValid(name) { try? host.deallocate(name) }
            case let .oolPorts(names, _): for n in names where MachPortName.isValid(n) { try? host.deallocate(n) }
            case .ool: break
            }
        }
    }

    // MARK: Devices

    /// The device list (request 1). No device when the selection names none.
    func devicesPlist() -> [String: Any] {
        let found: CameraDevice? = isStreaming ? lock.withLock({ device }) : (try? CameraHostService.resolve(selection))
        lock.withLock { if let found { device = found } }
        guard let found else { return ["version": Int(CameraGuestProtocol.version), "devices": [Any]()] }
        return CameraGuestFormats.plist(device: found, presentation: presentation)
    }

    // MARK: Streams

    struct StartResult {
        var words: [UInt32]
        var keptPort: UInt32?
    }

    private func startStream(port: UInt32?, pid: Int32, deviceIndex: UInt32, width: Int, height: Int, fpsMilli: UInt32,
                             pixelFormat: UInt32) -> StartResult {
        let bad = StartResult(words: [CameraGuestProtocol.Status.badRequest, 0, 0, 0, 0, 0], keptPort: nil)
        guard let port, MachPortName.isValid(port), deviceIndex == 0, width > 0, height > 0, width <= 8192, height <= 8192,
              let format = CameraPixelFormat(rawValue: pixelFormat) else { return bad }
        let fps = fpsMilli == 0 ? 30 : Double(fpsMilli) / 1000
        let config = CameraConfiguration(width: width, height: height, framesPerSecond: fps, output: format, ringSize: ringSize,
                                         holdFramesUntilReleased: true, syntheticWhileAbsent: false)
        // Who had the camera, and the client record for this port.
        let (isNew, previous, streamID) = lock.withLock { () -> (Bool, UInt32?, UInt32) in
            let isNew = clients[port] == nil
            var c = clients[port] ?? Client(port: port, pid: pid, streamID: nextStreamID, configuration: config)
            if isNew { nextStreamID &+= 1 }
            c.configuration = config
            clients[port] = c
            let previous = active
            waiting.removeAll { $0 == port }
            return (isNew, previous, c.streamID)
        }
        if isNew {
            // Its death tells that the client process ended.
            _ = try? host.requestNotification(port, id: MachNotify.deadName, notifyPort: notifyPort)
        } else {
            // The request brought another reference to a right we keep.
            try? host.deallocate(port)
        }
        if let previous, previous != port {
            lock.withLock { waiting.append(previous) }
            sendEvent(to: previous, CameraGuestProtocol.EventKind.interrupted)
            log("camera: stream \(streamID) of pid \(pid) interrupts stream \(lock.withLock { clients[previous]?.streamID ?? 0 })")
        }
        do {
            let f = try open(port: port, config)
            log("camera: stream \(streamID) for pid \(pid): \(f.width)x\(f.height) \(f.output) at \(f.interval)")
            return StartResult(words: [CameraGuestProtocol.Status.ok, streamID, UInt32(f.width), UInt32(f.height),
                                       UInt32((f.interval.framesPerSecond * 1000).rounded()), f.output.rawValue],
                               keptPort: isNew ? port : nil)
        } catch {
            log("camera: stream \(streamID) for pid \(pid) failed: \(error)")
            let status: UInt32 = switch (error as? CameraError)?.code {
            case .noDevice?, .gone?: CameraGuestProtocol.Status.noDevice
            case .busy?, .permission?: CameraGuestProtocol.Status.busy
            default: CameraGuestProtocol.Status.failed
            }
            // The client is not kept; whoever was interrupted gets it back.
            removeClient(port, reason: nil, resume: false)
            if !isStreaming { resumeNext() }
            return StartResult(words: [status, 0, 0, 0, 0, 0], keptPort: isNew ? port : nil)
        }
    }

    /// (Re)starts the camera for `port`'s client.
    private func open(port: UInt32, _ config: CameraConfiguration) throws -> CameraStreamFormat {
        camera.stop()
        let gen = lock.withLock { () -> UInt64 in
            generation &+= 1
            outstanding = [:]
            unsent = 0
            active = port
            return generation
        }
        do {
            let f = try camera.start(selection: selection, configuration: config,
                                     onFrame: { [weak self] in self?.deliver($0, generation: gen) },
                                     onEvent: { [weak self] in self?.event($0, generation: gen) })
            lock.withLock {
                device = camera.currentDevice
                streamsStarted += 1
            }
            return f
        } catch {
            lock.withLock { if generation == gen { active = nil } }
            throw error
        }
    }

    /// Request 3 or the client's end: the stream goes; an interrupted
    /// client gets the camera back.
    private func stopStream(id: UInt32, reason: String) -> UInt32 {
        guard let port = lock.withLock({ clients.first { $0.value.streamID == id }?.key }) else {
            return CameraGuestProtocol.Status.badRequest
        }
        removeClient(port, reason: reason, resume: true)
        return CameraGuestProtocol.Status.ok
    }

    private func removeClient(_ port: UInt32, reason: String?, resume: Bool) {
        let (wasActive, client) = lock.withLock { () -> (Bool, Client?) in
            let c = clients.removeValue(forKey: port)
            waiting.removeAll { $0 == port }
            let wasActive = active == port
            if wasActive {
                active = nil
                generation &+= 1
            }
            return (wasActive, c)
        }
        if let client, let reason {
            log("camera: stream \(client.streamID) of pid \(client.pid) ended (\(reason)); \(framesSent) frames sent, "
                + "\(framesNotSent) not taken, \(framesReleased) released")
        }
        // Our send right; the dead-name request is cancelled (its send-once
        // right comes back and is dropped).
        if client != nil {
            if let previous = try? host.requestNotification(port, id: MachNotify.deadName, notifyPort: 0),
               MachPortName.isValid(previous) { try? host.deallocate(previous) }
            try? host.deallocate(port)
        }
        guard wasActive else { return }
        camera.stop()
        lock.withLock { outstanding = [:] }
        if resume { resumeNext() }
    }

    /// The most recently interrupted client that still exists gets the camera.
    private func resumeNext() {
        while let next = lock.withLock({ waiting.popLast() }) {
            guard let c = lock.withLock({ clients[next] }) else { continue }
            do {
                _ = try open(port: next, c.configuration)
                sendEvent(to: next, CameraGuestProtocol.EventKind.interruptionEnded)
                log("camera: stream \(c.streamID) of pid \(c.pid) resumes")
                return
            } catch {
                log("camera: stream \(c.streamID) of pid \(c.pid) cannot resume: \(error)")
                sendEvent(to: next, CameraGuestProtocol.EventKind.failed)
            }
        }
    }

    private func release(stream: UInt32, sequence: UInt64) {
        let frame = lock.withLock { () -> CameraFrame? in
            guard let a = active, clients[a]?.streamID == stream else { return nil }
            return outstanding.removeValue(forKey: sequence)
        }
        guard let frame else { return }
        camera.release(frame)
        lock.withLock { framesReleased += 1 }
    }

    private func deadName(_ m: MachHostReceivedMessage) {
        guard m.id == MachNotify.deadName else {
            host.discard(m)
            return
        }
        let name = CameraGuestProtocol.word(m.body, 0)
        // The notification's own reference to the dead name.
        try? host.deallocate(name)
        if lock.withLock({ clients[name] != nil }) {
            removeClient(name, reason: "its process ended", resume: true)
        }
    }

    // MARK: Frames and events (capture thread)

    func deliver(_ frame: CameraFrame, generation gen: UInt64) {
        let clock = lock.withLock { guestClock }
        // The camera's clock (CLOCK_MONOTONIC, camera-host.md §3.4) read
        // around the guest clock.
        let before = UInt64(ycam_monotonic_ns())
        let reading = clock()
        let after = UInt64(ycam_monotonic_ns())
        let time = CameraGuestTime(hostNanoseconds: before / 2 + after / 2, guestTicks: reading.ticks, frequency: reading.frequency)
        let target = lock.withLock { () -> (port: UInt32, stream: UInt32, dropped: Int)? in
            guard gen == generation, let a = active, let c = clients[a] else { return nil }
            return (a, c.streamID, frame.droppedBefore + unsent)
        }
        guard let target else {
            camera.release(frame)
            return
        }
        let words = CameraGuestProtocol.frameWords(stream: target.stream, frame: frame,
                                                   presentationTicks: time.ticks(atHostNanoseconds: frame.presentationTime),
                                                   durationTicks: time.ticks(forNanoseconds: frame.duration), dropped: target.dropped)
        // Recorded before the send: the guest may release it at once.
        lock.withLock { outstanding[frame.sequence] = frame }
        do {
            try host.send(MachHostOutgoingMessage(remotePort: target.port, remoteDisposition: MachMsgType.copySend,
                                                  id: CameraGuestProtocol.base + CameraGuestProtocol.ToClient.frame,
                                                  body: CameraGuestProtocol.body(words)), timeout: 0)
            lock.withLock {
                unsent = 0
                framesSent += 1
            }
        } catch {
            // The guest's queue is full (or its port died): the frame is dropped.
            let held = lock.withLock { () -> Bool in
                unsent += 1
                framesNotSent += 1
                return outstanding.removeValue(forKey: frame.sequence) != nil
            }
            if held { camera.release(frame) }
        }
    }

    func event(_ e: CameraEvent, generation gen: UInt64) {
        guard let port = lock.withLock({ gen == generation ? active : nil }) else { return }
        switch e {
        case .disconnected:
            sendEvent(to: port, CameraGuestProtocol.EventKind.disconnected)
        case let .reconnected(f):
            sendEvent(to: port, CameraGuestProtocol.EventKind.reconnected, width: f.width, height: f.height)
        case .started, .stopped:
            break
        }
    }

    private func sendEvent(to port: UInt32, _ kind: UInt32, width: Int = 0, height: Int = 0) {
        guard let stream = lock.withLock({ clients[port]?.streamID }) else { return }
        _ = try? host.send(MachHostOutgoingMessage(remotePort: port, remoteDisposition: MachMsgType.copySend,
                                                   id: CameraGuestProtocol.base + CameraGuestProtocol.ToClient.event,
                                                   body: CameraGuestProtocol.body([stream, kind, UInt32(width), UInt32(height)])),
                           timeout: 0)
    }
}
