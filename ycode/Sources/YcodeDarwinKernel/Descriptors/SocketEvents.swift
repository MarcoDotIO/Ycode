import Foundation
import YcodeDarwinABI

// EVFILT_SOCK (`specs/simulator/networking-ycode.md` §2.5; xnu
// `uipc_socket.c` `filt_sockev_common`, `sys/event_private.h`): socket
// state events. Network.framework registers it on every TCP socket it
// connects and waits for NOTE_CONNECTED before it uses the connection.
//
// The events come from the socket's state: NOTE_CONNECTED while connected,
// NOTE_DISCONNECTED once the connection is gone, NOTE_READCLOSED and
// NOTE_WRITECLOSED when a direction is shut, NOTE_CONNRESET for a reset.
// The first four are level events (and NOTE_SUSPEND/NOTE_RESUME, never
// raised here): delivered once until the knote's interest in them changes
// (`kn_hook32` = `Knote.sockDelivered`). The event's data is the pending
// socket error (with EV_EOF), else the state bits SOCKEV_CONNECTED (1) and
// SOCKEV_DISCONNECTED (2); EV_EOF also marks a closed direction.

enum SocketEvents {
    static let connReset: UInt32 = 0x1, readClosed: UInt32 = 0x2, writeClosed: UInt32 = 0x4, timeout: UInt32 = 0x8,
               suspend: UInt32 = 0x40, resume: UInt32 = 0x80, connected: UInt32 = 0x800, disconnected: UInt32 = 0x1000
    /// `EVFILT_SOCK_LEVEL_TRIGGER_MASK`.
    static let levelMask: UInt32 = readClosed | writeClosed | suspend | resume | connected | disconnected
    static let stateConnected: Int64 = 1, stateDisconnected: Int64 = 2
}

/// A descriptor object EVFILT_SOCK can watch.
protocol SocketEventSource: AnyObject {
    /// The events raised now, the pending error (0 = none; not cleared).
    /// Kernel lock held.
    func socketEvents() -> (events: UInt32, error: Int32)
}

extension InetSocket: SocketEventSource {
    func socketEvents() -> (events: UInt32, error: Int32) {
        var events: UInt32 = 0
        if isReset {
            return (SocketEvents.disconnected | SocketEvents.readClosed | SocketEvents.writeClosed
                        | (pendingError == DarwinErrnoCode.ECONNRESET ? SocketEvents.connReset : 0), pendingError)
        }
        refreshConnecting()
        guard hostFD >= 0 else { return (SocketEvents.disconnected, pendingError) }
        let r = HostSocketCalls.revents(hostFD)
        // A host error (a reset, a failed connect) becomes the pending error.
        if r & Int16(POLLERR) != 0, pendingError == 0,
           let e = HostSocketCalls.intOption(hostFD, level: HostNet.solSocket, name: Int32(SO_ERROR)), e != 0 {
            pendingError = SocketErrno.fromHost(e)
        }
        let connected = isStream ? state == .connected : datagramConnected
        if connected { events |= SocketEvents.connected }
        if isStream, state == .connected {
            if shutRead || r & HostSocketCalls.rdHup != 0 || (r & Int16(POLLIN) != 0 && HostSocketCalls.bytesReadable(hostFD) == 0) {
                events |= SocketEvents.readClosed
            }
            if shutWrite || r & Int16(POLLHUP) != 0 { events |= SocketEvents.writeClosed }
            if r & Int16(POLLHUP) != 0 { events |= SocketEvents.disconnected }
        }
        if pendingError == DarwinErrnoCode.ECONNRESET { events |= SocketEvents.connReset }
        if pendingError != 0, isStream, state != .connecting { events |= SocketEvents.disconnected }
        return (events, pendingError)
    }
}

extension UnixSocket: SocketEventSource {
    func socketEvents() -> (events: UInt32, error: Int32) {
        var events: UInt32 = 0
        if isConnected { events |= SocketEvents.connected }
        if cantReceiveMore { events |= SocketEvents.readClosed }
        if cantSendMore { events |= SocketEvents.writeClosed }
        if cantReceiveMore && cantSendMore && !isConnected && peer == nil && !isListening { events |= SocketEvents.disconnected }
        return (events, error)
    }
}

extension DarwinKernel {
    /// An EVFILT_SOCK knote's state now: the events within its interest
    /// (`kn.fflags`), whether any would be reported, the event's data and
    /// EV_EOF.
    func socketEventState(_ kn: Knote) -> (fired: UInt32, pending: Bool, data: Int64, eof: Bool) {
        guard let source = kn.object as? SocketEventSource else { return (0, false, 0, false) }
        let s = source.socketEvents()
        let fired = s.events & kn.fflags
        let unreported = fired & ~(SocketEvents.levelMask & kn.sockDelivered)
        var data: Int64 = 0
        if s.error != 0 {
            data = Int64(s.error)
        } else {
            if s.events & SocketEvents.connected != 0 { data |= SocketEvents.stateConnected }
            if s.events & SocketEvents.disconnected != 0 { data |= SocketEvents.stateDisconnected }
        }
        let eof = s.error != 0 || fired & (SocketEvents.readClosed | SocketEvents.writeClosed) != 0
        // A pending error fires until it is read (SO_ERROR), as in xnu.
        return (fired, unreported != 0 || s.error != 0, data, eof)
    }
}
