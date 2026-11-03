import Darwin
import Foundation
import Testing

/// Finds child processes the tests leave behind (debug adapters, language
/// servers, simctl, build services). A leftover child keeps pipes, devices
/// and the test helper's run loop busy, so the run would not end cleanly.
///
/// - After every `.heavyIntegration` suite, children with a long-lived tool
///   name must be gone within a grace period, or the suite records an issue
///   naming them (and they are killed).
/// - At process exit, any child still alive fails the run (exit status 1).
enum ProcessAudit {
    /// Tools that are meant to live for one session and must be closed.
    static let sessionTools = ["lldb-dap", "lldb", "debugserver", "sourcekit-lsp", "clangd", "simctl",
                               "swbuild", "SWBBuildService", "swift-build", "swift-frontend",
                               // Preview hosts: the Mac host and built SwiftPM hosts (specs/ide/previews.md §The macOS host)
                               "YcodePreview"]

    struct Child: CustomStringConvertible {
        var pid: pid_t
        var name: String
        var description: String { "\(name)[\(pid)]" }
    }

    static func children() -> [Child] {
        var pids = [pid_t](repeating: 0, count: 512)
        let n = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        return pids.prefix(Int(n)).filter { $0 > 0 }.compactMap { pid in
            var buf = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
            // A zombie (exited, not reaped yet) holds nothing open.
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
               info.pbi_status == UInt32(SZOMB) { return nil }
            return Child(pid: pid, name: String(cString: buf))
        }
    }

    /// Children still alive after `grace` seconds, among those `filter` keeps.
    static func leftovers(grace: Double, filter: (Child) -> Bool = { _ in true }) -> [Child] {
        let deadline = Date().addingTimeInterval(grace)
        while true {
            let live = children().filter(filter)
            if live.isEmpty || Date() >= deadline { return live }
            usleep(100_000)
        }
    }

    /// The child's arguments (`KERN_PROCARGS2`), to name what left it.
    static func commandLine(_ pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return "" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return "" }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        // argc, the executable path, padding NULs, then argv.
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return "(" + args.joined(separator: " ").prefix(400) + ")"
    }

    static func isSessionTool(_ c: Child) -> Bool { sessionTools.contains { c.name.hasPrefix($0) } }

    static func kill(_ list: [Child]) { for c in list { Darwin.kill(c.pid, SIGKILL) } }

    private static let armed: Void = {
        atexit {
            let left = ProcessAudit.leftovers(grace: 10)
            guard !left.isEmpty else { return }
            let msg = "ProcessAudit: child processes still running at exit: \(left.map { "\($0) \(ProcessAudit.commandLine($0.pid))" }.joined(separator: ", "))\n"
            FileHandle.standardError.write(Data(msg.utf8))
            ProcessAudit.kill(left)
            _exit(1)
        }
    }()

    /// Installs the exit check (once).
    static func arm() { _ = armed }

    /// After a heavy suite: its session tools must be gone.
    static func checkAfterSuite(_ name: String) {
        let left = leftovers(grace: 15, filter: isSessionTool)
        guard !left.isEmpty else { return }
        Issue.record("\(name) left child processes running: \(left.map(\.description).joined(separator: ", "))")
        kill(left)
    }
}
