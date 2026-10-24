import Foundation
import YcodeSubprocess

/// DAP base-protocol framing: `Content-Length: N\r\n\r\n` then N bytes of
/// JSON. See `specs/ide/debug.md` §Wire format.
public enum DAPFraming {
    public static func frame(_ body: Data) -> Data {
        Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    /// Accumulates bytes and returns whole message bodies.
    public struct Decoder: Sendable {
        private var buffer = Data()
        public init() {}

        public mutating func append(_ data: Data) -> [Data] {
            buffer.append(data)
            var out: [Data] = []
            let separator = Data("\r\n\r\n".utf8)
            while let end = buffer.range(of: separator) {
                let header = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                var length: Int?
                for field in header.components(separatedBy: "\r\n") {
                    let parts = field.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].lowercased() == "content-length" {
                        length = Int(parts[1].trimmingCharacters(in: .whitespaces))
                    }
                }
                guard let length else {
                    // A header without a length cannot be framed; drop it.
                    buffer = Data(buffer[end.upperBound...])
                    continue
                }
                let bodyStart = end.upperBound
                guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
                let bodyEnd = buffer.index(bodyStart, offsetBy: length)
                out.append(Data(buffer[bodyStart..<bodyEnd]))
                buffer = Data(buffer[bodyEnd...])
            }
            return out
        }
    }
}

/// A byte channel to a debug adapter.
public protocol DAPTransport: AnyObject, Sendable {
    /// Called with incoming bytes, and with nil once when the channel closes.
    func start(receiving: @escaping @Sendable (Data?) -> Void) throws
    func send(_ data: Data)
    func close()
}

/// Runs a debug adapter (normally `lldb-dap`) and talks over its stdio.
public final class ProcessTransport: DAPTransport, @unchecked Sendable {
    public let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    public init(executable: String, arguments: [String] = []) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
    }

    public func start(receiving: @escaping @Sendable (Data?) -> Void) throws {
        try process.run()
        let reader = output.fileHandleForReading
        Thread {
            while true {
                let d = reader.availableData
                if d.isEmpty { break }
                receiving(d)
            }
            receiving(nil)
        }.start()
    }

    public func send(_ data: Data) {
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Closes the adapter's input and sends SIGTERM; an adapter still
    /// running two seconds later gets SIGKILL, so none outlives its client.
    public func close() {
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }
}

/// Finds the LLDB debug adapter: `xcrun -f lldb-dap` on macOS, else PATH.
public enum LLDBDAP {
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let explicit = environment["YCODE_LLDB_DAP"] { return explicit }
        #if os(macOS)
        MainThreadGuard.blockingCall("xcrun --find lldb-dap")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["-f", "lldb-dap"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0, !path.isEmpty { return path }
        }
        #endif
        // Older LLVM releases named the tool lldb-vscode.
        for name in ["lldb-dap", "lldb-vscode"] {
            for dir in (environment["PATH"] ?? "/usr/bin").split(separator: ":") {
                let candidate = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }
}
