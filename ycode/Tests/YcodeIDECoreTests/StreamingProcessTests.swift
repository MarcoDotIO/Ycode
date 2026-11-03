import Foundation
import Testing
@testable import YcodeIDECore

/// `StreamingProcess` (the console of simulator runs, remote runs, Device
/// Hub sessions and remote previews): every line the child wrote reaches
/// `onLine` before `onExit`, in order. The exit used to be reported from
/// the termination handler while the pipe still held output; the run's
/// state was released in `onExit`, and the lines read after it (a remote
/// launcher's "stopped by SIGINT") were dropped.
@MainActor
@Suite struct StreamingProcessTests {
    #if os(macOS)
    nonisolated static let reportsExitBeforeThePipeCloses = true
    #else
    nonisolated static let reportsExitBeforeThePipeCloses = false
    #endif

    final class Seen {
        var lines: [String] = []
        var linesAtExit: Int?
        var status: Int32?
    }

    func run(_ script: String, readDelay: TimeInterval = 0, grace: TimeInterval = 1, timeout: TimeInterval = 60) async throws -> Seen {
        let seen = Seen()
        let p = StreamingProcess(executable: "/bin/sh", arguments: ["-c", script])
        p.readDelayForTesting = readDelay
        p.outputGrace = grace
        try p.start(onLine: { seen.lines.append($0) }, onExit: { status in
            seen.linesAtExit = seen.lines.count
            seen.status = status
        })
        let end = Date().addingTimeInterval(timeout)
        while seen.status == nil, Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        // Anything that would still arrive after the exit.
        try await Task.sleep(nanoseconds: 100_000_000)
        return seen
    }

    /// Far more output than a pipe holds, written just before the exit: the
    /// process ends while most of it is still unread.
    @Test func everyLineArrivesBeforeTheExit() async throws {
        // A reader as late as on a loaded machine (each read waits), and one on time.
        for delay in [0.02, 0, 0, 0] {
            let seen = try await run("i=0; while [ $i -lt 20000 ]; do echo \"line $i of the run\"; i=$((i+1)); done; printf 'last'; exit 3",
                                     readDelay: delay, grace: 30)
            #expect(seen.status == 3)
            #expect(seen.lines.count == 20001)
            #expect(seen.linesAtExit == seen.lines.count)
            #expect(seen.lines.first == "line 0 of the run" && seen.lines.last == "last")
            #expect(seen.lines.dropLast().enumerated().allSatisfy { $0.element == "line \($0.offset) of the run" })
        }
    }

    /// A child that outlives the process keeps the pipe open: the exit is
    /// still reported (after a short grace for the output), with the lines
    /// written so far.
    /// (macOS: swift-corelibs-foundation reports the end of the process
    /// only once the pipe has closed, so there the exit waits for the child.)
    @Test(.enabled(if: Self.reportsExitBeforeThePipeCloses))
    func anInheritedPipeDoesNotHoldTheExitBack() async throws {
        let start = Date()
        let seen = try await run("echo before; (sleep 4) & echo after; exit 0", timeout: 10)
        #expect(seen.status == 0)
        #expect(seen.lines == ["before", "after"])
        // Reported before the child ended.
        #expect(Date().timeIntervalSince(start) < 3.9)
    }
}
