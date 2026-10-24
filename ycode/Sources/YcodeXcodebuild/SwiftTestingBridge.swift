import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Lists the swift-testing tests of a test bundle through swift-testing's
/// documented ABI entry point (`swt_abiv0_getEntryPoint`, open source,
/// `Documentation/ABI/JSON.md`). It runs in a child process
/// (`ycodebuild __list-swift-tests <executable>`), because loading a test
/// bundle loads the test frameworks into the process.
/// See `specs/xcodebuild/test-actions.md` §4.
public enum SwiftTestingBridge {
    public struct TestRecord: Equatable, Sendable {
        /// `Module.Suite/function()/File.swift:line:column` for functions,
        /// `Module.Suite` for suites.
        public var id: String
        public var name: String
        public var isSuite: Bool
        public var file: String?
        public var line: Int?

        /// The identifier without the source-location suffix.
        public var specifier: String {
            guard !isSuite, let slash = id.lastIndex(of: "/"), id[id.index(after: slash)...].contains(".swift:") else { return id }
            return String(id[..<slash])
        }
        /// Module name (before the first dot).
        public var module: String { String(specifier.prefix { $0 != "." }) }
        /// `Suite/func()` or `func()` without the module.
        public var path: String { String(specifier.dropFirst(module.count + 1)) }
    }

    typealias EntryPoint = @convention(thin) @Sendable (
        _ configurationJSON: UnsafeRawBufferPointer?,
        _ recordHandler: @escaping @Sendable (_ recordJSON: UnsafeRawBufferPointer) -> Void
    ) async throws -> Bool

    /// In the child: loads the bundle executable and prints one JSON record
    /// per line on stdout. Exit 0 also when the bundle has no swift-testing.
    public static func listMain(executable: String) async -> Int32 {
        guard let handle = dlopen(executable, RTLD_NOW) else {
            FileHandle.standardError.write(Data("ycodebuild: cannot load \(executable): \(String(cString: dlerror()))\n".utf8))
            return 1
        }
        guard let symbol = dlsym(handle, "swt_abiv0_getEntryPoint") else { return 0 }
        typealias Getter = @convention(c) () -> UnsafeRawPointer
        let entry = unsafeBitCast(unsafeBitCast(symbol, to: Getter.self)(), to: EntryPoint.self)
        let config = Array(#"{"listTests":true,"eventStreamVersion":0}"#.utf8)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: config.count, alignment: 1)
        defer { buffer.deallocate() }
        buffer.copyBytes(from: config)
        // The library prints its own listing on stdout; keep only records.
        let out = dup(STDOUT_FILENO)
        let null = open("/dev/null", O_WRONLY)
        dup2(null, STDOUT_FILENO)
        let records = Box()
        do {
            _ = try await entry(UnsafeRawBufferPointer(buffer)) { rec in records.append(Data(rec)) }
        } catch {
            dup2(out, STDOUT_FILENO)
            FileHandle.standardError.write(Data("ycodebuild: swift-testing listing failed: \(error)\n".utf8))
            return 1
        }
        dup2(out, STDOUT_FILENO)
        for r in records.all { FileHandle.standardOutput.write(r + Data([0x0A])) }
        return 0
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Data] = []
        func append(_ d: Data) { lock.withLock { items.append(d) } }
        var all: [Data] { lock.withLock { items } }
    }

    /// Parses the records the child printed.
    public static func parse(_ text: String) -> [TestRecord] {
        text.split(separator: "\n").compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["kind"] as? String == "test", let p = obj["payload"] as? [String: Any],
                  let id = p["id"] as? String, let name = p["name"] as? String else { return nil }
            let loc = p["sourceLocation"] as? [String: Any]
            let file = (loc?["_filePath"] as? String) ?? (loc?["filePath"] as? String)
            return TestRecord(id: id, name: name, isSuite: p["kind"] as? String == "suite", file: file, line: loc?["line"] as? Int)
        }
    }
}
