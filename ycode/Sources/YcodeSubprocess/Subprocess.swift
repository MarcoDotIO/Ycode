import Foundation

/// Runs a command to completion and captures its output. The caller waits,
/// so in debug builds the run is checked against the main thread
/// (`MainThreadGuard`); call it from a background task.
public enum Subprocess {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
        public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// Runs `executable` with `arguments`. Standard input is the null
    /// device; standard output and error are read concurrently, so a full
    /// pipe never blocks the child. Throws only when it cannot start.
    /// `environment` nil inherits this process's environment.
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           currentDirectory: URL? = nil, captureStderr: Bool = true,
                           fileID: StaticString = #fileID, line: UInt = #line) throws -> Output {
        MainThreadGuard.blockingCall("\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.prefix(3).joined(separator: " "))",
                                     fileID: fileID, line: line)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = captureStderr ? err : FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        // stderr on its own thread: reading the two pipes one after the
        // other deadlocks when the child fills the second one first.
        final class Box: @unchecked Sendable { var data = Data() }
        let errBox = Box()
        let group = DispatchGroup()
        if captureStderr {
            let h = err.fileHandleForReading
            DispatchQueue.global().async(group: group) { errBox.data = h.readDataToEndOfFile() }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return Output(status: p.terminationStatus, stdout: data, stderr: errBox.data)
    }
}
