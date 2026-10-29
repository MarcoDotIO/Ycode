// The host's power-management server `com.apple.PowerManagement.control`
// (visionos.md §10.10.3, §10.11; launchd-sim.md §6.3 lists it among the
// host-side names), reduced to what the simulated system needs: power
// assertions are granted, user and system activity declarations accepted,
// and nothing ever sleeps. Wire protocol: the MIG subsystem
// `powermanagement` (base 73000) of Apple's open-source IOKitUser
// (`pwr_mgt.subproj/powermanagement.defs`, level 1); the routines' message
// ids are 73000 + their position in that file. The server takes the
// caller's audit token from the trailer (ServerAuditToken), so requests
// carry only the arguments. Written from the .defs file; no Apple code.
//
// Ycode's choices: assertion ids count up from 0x10001 and are never
// tracked (a release always succeeds); the capability bits say CPU,
// video, audio and network are on; every value read is 0; anything else
// is answered MIG_BAD_ID.

import Foundation
import YcodeDarwinKernel

public final class PowerManagementHostService: @unchecked Sendable {
    public static let serviceName = "com.apple.PowerManagement.control"
    /// `YCODE_DEBUG_NO_POWERMANAGEMENT=1`: no service (diagnostics; the
    /// guest's assertion requests then fail with kIOReturnInternalError).
    public static let disabled = getenv("YCODE_DEBUG_NO_POWERMANAGEMENT").map { String(cString: $0) == "1" } ?? false

    /// MIG message ids (`powermanagement.defs`, base 73000).
    enum ID {
        static let getValueInt: Int32 = 73000, setValueInt: Int32 = 73001, forceActiveSettings: Int32 = 73002
        static let schedulePowerEvent: Int32 = 73003, scheduleRepeatEvent: Int32 = 73004, cancelRepeatEvents: Int32 = 73005
        static let assertionCreate: Int32 = 73007, assertionSetProperties: Int32 = 73008
        static let assertionRetainRelease: Int32 = 73009, assertionCopyDetails: Int32 = 73010
        static let declareSystemActive: Int32 = 73011, declareUserActive: Int32 = 73012
        static let declareNetworkClientActive: Int32 = 73013
        static let connectionCreate: Int32 = 73015, connectionScheduleNotification: Int32 = 73016
        static let connectionRelease: Int32 = 73017, connectionAcknowledgeEvent: Int32 = 73018
        static let hidEventReportActivity: Int32 = 73023, setDebugFlags: Int32 = 73025
        static let getCapabilityBits: Int32 = 73030, ctlAssertionType: Int32 = 73031, assertionNotify: Int32 = 73032
        static let setExceptionLimits: Int32 = 73035
    }

    /// `MIG_BAD_ID`; `kIOReturnNotFound`.
    static let migBadID: Int32 = -303
    static let notFound = Int32(bitPattern: 0xE000_02F0)
    /// The NDR record (little-endian integers, IEEE floats, ASCII).
    static let ndr: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 0]
    /// kIOPMCapabilityCPU | Video | Audio | Network.
    static let capabilities: Int32 = 0xF

    public let servicePort: UInt32
    private let host: MachHostTask
    private let log: (String) -> Void
    private let lock = NSLock()
    private var stopping = false
    private var nextID: Int32 = 0x10001
    private var nextConnection: Int32 = 1
    private var logged: [Int32: Int] = [:]
    /// Statistics.
    public private(set) var requestCount = 0

    public init(host: MachHostTask, log: @escaping (String) -> Void) throws {
        self.host = host
        self.log = log
        servicePort = try host.makePort(sendRight: true, qlimit: 64)
    }

    public func start() {
        let t = Thread { [self] in run() }
        t.name = "ycode-powermanagement"
        t.start()
    }

    public func stop() { lock.withLock { stopping = true } }

    private func run() {
        while !lock.withLock({ stopping }) {
            let m: MachHostReceivedMessage
            do {
                m = try host.receive(on: servicePort, timeout: 200_000_000, tracked: true)
            } catch let e as MachHostError where e == .timedOut || e == .interrupted || e == .portChanged {
                continue
            } catch let e as MachHostError where e == MachHostError(MachMsgReturn.rcvInvalidName) {
                return  // the host task ended (the VMM is stopping)
            } catch {
                if !lock.withLock({ stopping }) { log("powermanagement: receive failed: \(error); stopping") }
                return
            }
            handle(m)
            host.finishedMessage()
        }
    }

    // MARK: Requests

    /// The reply body (after the header) and descriptors for one request,
    /// or nil for a message that gets no reply.
    func answer(_ m: MachHostReceivedMessage) -> (descriptors: [MachHostDescriptor], body: [UInt8])? {
        func ints(_ v: [Int32]) -> [UInt8] { Self.ndr + v.flatMap(Self.le) }
        // Scalar arguments after the NDR record.
        func arg(_ i: Int) -> Int32 {
            let at = 8 + 4 * i
            guard m.body.count >= at + 4 else { return 0 }
            return Int32(bitPattern: UInt32(m.body[at]) | UInt32(m.body[at + 1]) << 8 | UInt32(m.body[at + 2]) << 16
                         | UInt32(m.body[at + 3]) << 24)
        }
        switch m.id {
        case ID.getValueInt:
            return ([], ints([0, 0]))                                // RetCode, value
        case ID.setValueInt, ID.forceActiveSettings, ID.schedulePowerEvent, ID.scheduleRepeatEvent,
             ID.cancelRepeatEvents, ID.connectionAcknowledgeEvent:
            return ([], ints([0, 0]))                                // RetCode, return_val
        case ID.assertionCreate:
            let id = lock.withLock { () -> Int32 in
                defer { nextID &+= 1 }
                return nextID
            }
            return ([], ints([0, id, 0, 0, 0]))                      // RetCode, assertion_id, disableAppSleep, enTrIntensity, return_code
        case ID.assertionSetProperties:
            return ([], ints([0, 0, 0, 0, 0]))                       // RetCode, disableAppSleep, enableAppSleep, enTrIntensity, return_code
        case ID.assertionRetainRelease:
            return ([], ints([0, arg(1) == 1 ? 1 : 0, 0, 0, 0]))     // RetCode, retainCnt, disableAppSleep, enableAppSleep, return_code
        case ID.assertionCopyDetails:
            // A complex reply (no RetCode): an empty OOL region, NDR,
            // assertionsCnt 0, return_val kIOReturnNotFound.
            return ([.ool(data: [])], Self.ndr + Self.le(0) + Self.le(Self.notFound))
        case ID.declareSystemActive:
            // state (inout), assertion_id (inout): body NDR, state, propsCnt, assertion_id.
            let id = lock.withLock { () -> Int32 in
                defer { nextID &+= 1 }
                return nextID
            }
            return ([], ints([0, arg(0), id, 0]))                    // RetCode, state, assertion_id, return_code
        case ID.declareUserActive:
            let id = lock.withLock { () -> Int32 in
                defer { nextID &+= 1 }
                return nextID
            }
            return ([], ints([0, id, 0, 0]))                         // RetCode, assertion_id, disableAppSleep, return_code
        case ID.declareNetworkClientActive:
            let id = lock.withLock { () -> Int32 in
                defer { nextID &+= 1 }
                return nextID
            }
            return ([], ints([0, id, 0, 0]))                         // RetCode, assertion_id, disableAppSleep, return_code
        case ID.connectionCreate:
            let c = lock.withLock { () -> Int32 in
                defer { nextConnection &+= 1 }
                return nextConnection
            }
            return ([], ints([0, c, 0]))                             // RetCode, connection_id, return_code
        case ID.connectionScheduleNotification, ID.connectionRelease, ID.ctlAssertionType, ID.assertionNotify,
             ID.setExceptionLimits:
            return ([], ints([0, 0]))                                // RetCode, return_code
        case ID.hidEventReportActivity:
            return ([], ints([0, 1]))                                // RetCode, allow
        case ID.setDebugFlags:
            return ([], ints([0, 0, 0]))                             // RetCode, oldFlags, return_val
        case ID.getCapabilityBits:
            return ([], ints([0, Self.capabilities, 0]))             // RetCode, capBits, return_val
        default:
            return ([], ints([Self.migBadID]))
        }
    }

    func handle(_ m: MachHostReceivedMessage) {
        let first: Bool = lock.withLock {
            requestCount += 1
            logged[m.id, default: 0] += 1
            return logged[m.id] == 1
        }
        if first {
            let pid = m.sender.map { " from pid \($0.pid)" } ?? ""
            log("powermanagement: first request id \(m.id)\(pid), \(m.body.count) body bytes, \(m.descriptors.count) descriptors")
        }
        // Rights the request brought (a notification port) are dropped: no
        // notification is ever sent.
        for d in m.descriptors {
            switch d {
            case let .port(name, _), let .guardedPort(name, _, _): try? host.deallocate(name)
            case let .oolPorts(names, _): for n in names { try? host.deallocate(n) }
            case .ool: break
            }
        }
        guard MachPortName.isValid(m.replyPort), let (descriptors, body) = answer(m) else {
            host.discard(m)
            return
        }
        do {
            try host.reply(to: m, descriptors: descriptors, body: body)
        } catch {
            log("powermanagement: reply to id \(m.id) failed: \(error)")
        }
    }

    static func le(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v)
        return [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8(u >> 24)]
    }
}
