// Decrypting and unpacking an asset archive (`runtime-downloads.md` §4.3
// step 3, owner decision O2): with the key Apple's asset service returned to
// this user. On macOS: the system's public Apple Archive API. On Linux:
// python-aea (MIT, kinnay/AEA), an open-source Apple Encrypted Archive
// implementation, run as a separate program in a Python environment of
// Ycode's own; it decrypts to a pipe and Ycode's `AppleArchiveReader`
// unpacks the stream. The key reaches the decryptor on its standard input
// only (never a command line, the environment or a file) and is scrubbed
// from everything it prints.

import Foundation
#if canImport(AppleArchive)
import AppleArchive
import CryptoKit
import System
#endif

public protocol RuntimeArchiveExpander: Sendable {
    /// A line for the confirmation: what decrypts.
    var title: String { get }
    /// Decrypts `archive` with `key` and unpacks it into `folder`;
    /// `progress` gets the bytes written so far.
    @discardableResult
    func expand(_ archive: String, key: RuntimeArchiveKey?, into folder: String, cancel: RuntimeCancellation,
                progress: @escaping @Sendable (Int64) -> Void) async throws -> AppleArchiveReader.Stats
}

/// python-aea in a virtual environment (Linux; any host with Python 3.11+).
public struct PythonAEAExpander: RuntimeArchiveExpander {
    public static let package = "python-aea"
    public static let version = "1.1.0"
    /// The environment's Python.
    public var python: String

    public init(python: String) { self.python = python }

    /// `$YCODE_AEA_PYTHON`, else the environment in Ycode's runtime folder.
    public static func defaultPython(folder: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = environment["YCODE_AEA_PYTHON"], !p.isEmpty { return p }
        return environmentFolder(folder) + "/bin/python3"
    }

    public static func environmentFolder(_ folder: String) -> String { folder + "/.tools/python-aea" }

    /// The commands that make the environment (no root; the user's own folder).
    public static func installCommand(folder: String, python3: String = "python3") -> String {
        let env = environmentFolder(folder)
        return "\(python3) -m venv \(env.shellQuoted) && \((env + "/bin/pip").shellQuoted) install --disable-pip-version-check -q \(package)==\(version)"
    }

    /// Checks the module loads; prints its version line on success.
    public static func checkCommand(python: String) -> String {
        "\(python.shellQuoted) -I -c 'import aea, importlib.metadata as m; print(\"python-aea\", m.version(\"python-aea\"))'"
    }

    public var title: String { "python-aea \(Self.version) (MIT), run as a separate program" }

    /// Ycode's own few lines around python-aea: the key (hex) arrives on
    /// standard input, the plain archive leaves on standard output, one
    /// line of error on standard error.
    static let helper = """
    import sys
    try:
        import aea
        key = bytes.fromhex(sys.stdin.readline().strip())
        class Out:
            def __init__(self, f): self.f, self.n = f, 0
            def write(self, b): self.f.write(b); self.n += len(b)
            def tell(self): return self.n
        with open(sys.argv[1], "rb", buffering=1 << 20) as f:
            aea.decode_stream(f, Out(sys.stdout.buffer), symmetric_key=key)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        sys.exit(3)
    except Exception as e:
        sys.stderr.write(type(e).__name__ + ": " + str(e) + "\\n")
        sys.exit(2)
    """

    @discardableResult
    public func expand(_ archive: String, key: RuntimeArchiveKey?, into folder: String, cancel: RuntimeCancellation,
                       progress: @escaping @Sendable (Int64) -> Void) async throws -> AppleArchiveReader.Stats {
        guard let key else {
            throw RuntimeDownloadError.decryptor("This archive is not encrypted; Ycode expects an encrypted asset archive.")
        }
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw RuntimeDownloadError.decryptor("The decryptor (python-aea) is not set up. Set it up in the wizard, or run: \(Self.installCommand(folder: "<Ycode's runtime folder>"))")
        }
        let python = python
        return try await Task.detached { try Self.decryptAndUnpack(python: python, archive: archive, key: key, folder: folder, cancel: cancel, progress: progress) }.value
    }

    /// The decryptor's run and the reader, on the calling thread.
    static func decryptAndUnpack(python: String, archive: String, key: RuntimeArchiveKey, folder: String, cancel: RuntimeCancellation,
                                 progress: @escaping @Sendable (Int64) -> Void) throws -> AppleArchiveReader.Stats {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-I", "-c", Self.helper, archive]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        let errText = LockedText()
        try p.run()
        // Standard error, read to its end on its own thread.
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errText.append(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            drained.signal()
        }
        let token = cancel.onCancel { if p.isRunning { p.terminate() } }
        defer { cancel.remove(token) }
        input.fileHandleForWriting.write(Data((key.hexForStandardInput + "\n").utf8))
        try? input.fileHandleForWriting.close()
        let reader = AppleArchiveReader.reading(output.fileHandleForReading, into: folder)
        reader.progress = progress
        reader.cancel = cancel
        var readError: Error?
        do { try reader.extract() } catch { readError = error }
        if readError != nil, p.isRunning { p.terminate() }
        p.waitUntilExit()
        drained.wait()
        try cancel.check()
        let said = RuntimeSecrets.scrub(errText.text, extra: [key]).trimmed
        if p.terminationStatus != 0 {
            throw RuntimeDownloadError.expansion("python-aea stopped (status \(p.terminationStatus))\(said.isEmpty ? "" : ": \(said)")")
        }
        if let readError { throw readError }
        if reader.stats.files == 0 && reader.stats.directories == 0 { throw RuntimeDownloadError.expansion("the archive was empty") }
        return reader.stats
    }
}

final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var t = ""
    func append(_ s: String) { lock.withLock { if t.count < 16_000 { t += s } } }
    var text: String { lock.withLock { t } }
}

#if canImport(AppleArchive)
/// The system's Apple Archive API decrypts (macOS); Ycode's reader unpacks.
public struct SystemAppleArchiveExpander: RuntimeArchiveExpander {
    public init() {}

    public var title: String { "macOS's Apple Archive framework" }

    @discardableResult
    public func expand(_ archive: String, key: RuntimeArchiveKey?, into folder: String, cancel: RuntimeCancellation,
                       progress: @escaping @Sendable (Int64) -> Void) async throws -> AppleArchiveReader.Stats {
        return try await Task.detached {
            guard let file = ArchiveByteStream.fileStream(path: FilePath(archive), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)) else {
                throw RuntimeDownloadError.expansion("cannot open \((archive as NSString).lastPathComponent)")
            }
            defer { try? file.close() }
            var plain: ArchiveByteStream = file
            var decrypt: ArchiveByteStream?
            if let key {
                guard let context = ArchiveEncryptionContext(from: file) else {
                    throw RuntimeDownloadError.expansion("the archive is not an encrypted Apple Archive")
                }
                do { try context.setSymmetricKey(SymmetricKey(data: key.bytes)) } catch {
                    throw RuntimeDownloadError.expansion("the key does not fit the archive")
                }
                guard let d = ArchiveByteStream.decryptionStream(readingFrom: file, encryptionContext: context) else {
                    throw RuntimeDownloadError.expansion("the key does not open the archive")
                }
                decrypt = d
                plain = d
            }
            defer { try? decrypt?.close() }
            let stream = plain
            let reader = AppleArchiveReader(destination: folder) { n in
                var b = [UInt8](repeating: 0, count: n)
                let got: Int
                do {
                    got = try b.withUnsafeMutableBytes { try stream.read(into: $0) }
                } catch {
                    throw RuntimeDownloadError.expansion("decryption failed: \(RuntimeSecrets.scrub(String(describing: error), extra: [key].compactMap { $0 }))")
                }
                if got < n { b.removeLast(n - got) }
                return b
            }
            reader.progress = progress
            reader.cancel = cancel
            let stats = try reader.extract()
            if stats.files == 0 && stats.directories == 0 { throw RuntimeDownloadError.expansion("the archive was empty") }
            return stats
        }.value
    }
}
#endif

public enum RuntimeExpanders {
    /// The platform's expander: the system's on macOS, python-aea elsewhere
    /// (`YCODE_AEA_PYTHON` forces python-aea on a Mac, for tests).
    public static func standard(folder: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> any RuntimeArchiveExpander {
        #if canImport(AppleArchive)
        if environment["YCODE_AEA_PYTHON"] == nil { return SystemAppleArchiveExpander() }
        #endif
        return PythonAEAExpander(python: PythonAEAExpander.defaultPython(folder: folder, environment: environment))
    }
}
