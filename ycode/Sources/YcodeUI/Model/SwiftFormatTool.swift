import Foundation
import YcodeSubprocess

/// Editor ▸ Structure ▸ Format Selection / Format File
/// (`specs/ide/reference-ui-5.md` §6.4): runs the toolchain's open-source
/// `swift-format` (swiftlang/swift-format, Apache 2.0) as a separate tool;
/// Ycode links none of its code.
public enum SwiftFormatTool {
    /// `swift-format` on the PATH, else the active toolchain's (`xcrun --find`).
    public static func locate() -> URL? {
        if let override = ProcessInfo.processInfo.environment["YCODE_SWIFT_FORMAT"], !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = URL(fileURLWithPath: String(dir)).appendingPathComponent("swift-format")
            if FileManager.default.isExecutableFile(atPath: p.path) { return p }
        }
        guard let out = run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["--find", "swift-format"], input: nil), out.status == 0 else { return nil }
        let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    static func run(_ tool: URL, _ args: [String], input: String?) -> (status: Int32, stdout: String, stderr: String)? {
        MainThreadGuard.blockingCall("swift-format")
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input == nil ? FileHandle.nullDevice : inp
        guard (try? p.run()) != nil else { return nil }
        if let input {
            // Write from another thread so a large output cannot block us.
            let data = Data(input.utf8)
            let w = inp.fileHandleForWriting
            DispatchQueue.global().async { w.write(data); try? w.close() }
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case toolNotFound
        case failed(String)
        public var description: String {
            switch self {
            case .toolNotFound: "swift-format was not found in the toolchain."
            case .failed(let s): s
            }
        }
    }

    /// Formats `text` (a Swift file named `fileName`, for configuration
    /// lookup); `lines` limits it to a 1-based line range.
    public static func format(_ text: String, fileName: String, lines: ClosedRange<Int>? = nil, tool: URL? = locate()) -> Result<String, Failure> {
        guard let tool else { return .failure(.toolNotFound) }
        var args = ["format", "--assume-filename", fileName]
        if let lines { args += ["--lines", "\(lines.lowerBound):\(lines.upperBound)"] }
        guard let r = run(tool, args, input: text) else { return .failure(.toolNotFound) }
        guard r.status == 0 else { return .failure(.failed(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))) }
        return .success(r.stdout)
    }
}
