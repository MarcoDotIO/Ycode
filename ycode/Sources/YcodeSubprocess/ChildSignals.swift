import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension Process {
    /// `run()`, with no signal blocked in the child.
    ///
    /// A child starts with the signal mask of the thread that spawns it, and
    /// `Process` does not reset it. Dispatch's worker threads (and so Swift
    /// concurrency's on Linux) block nearly every signal, SIGINT and SIGTERM
    /// included, so a child spawned there can be stopped only with SIGKILL:
    /// `interrupt()` and `terminate()` stay pending in it for ever, and a
    /// tool that waits for input then never ends. The mask of this thread is
    /// cleared for the length of the spawn and restored after it.
    public func runWithSignalsUnblocked() throws {
        var none = sigset_t(), saved = sigset_t()
        sigemptyset(&none)
        pthread_sigmask(SIG_SETMASK, &none, &saved)
        defer { pthread_sigmask(SIG_SETMASK, &saved, nil) }
        try run()
    }
}

/// Signals for a child and the processes it started.
public enum ChildSignals {
    /// Sends `signal` to the child's process group when the child leads one
    /// of its own (`Process` starts every child in a new group), as a
    /// terminal's Control-C does, so a shell's foreground command or a tool's
    /// helpers get it too; otherwise to the child alone. Never to this
    /// process's own group.
    public static func send(_ signal: Int32, to pid: pid_t) {
        guard pid > 0 else { return }
        let group = getpgid(pid)
        if group == pid && group != getpgrp() {
            kill(-group, signal)
        } else {
            kill(pid, signal)
        }
    }
}
