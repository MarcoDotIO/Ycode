import Foundation

// Switches of the log path's hand-off work (`boot-profile.md` §12).
extension MachIPC {
    /// `YCODE_KEVENT_WRITE_AFTER_PORT_LOCK` (default on; `=0` off): an
    /// EVFILT_MACHPORT receive (`receiveForKevent`) writes the message into
    /// the guest's buffer after the port lock, as the fast `mach_msg` path
    /// does.
    nonisolated(unsafe) static var keventWriteAfterPortLock =
        getenv("YCODE_KEVENT_WRITE_AFTER_PORT_LOCK").map { String(cString: $0) != "0" } ?? true
}
