import Foundation

/// Reads the result bundles ycodebuild writes (`XCResultStore`): the
/// object store, the object encoding, and the test results in them.
/// Objects are Zstandard frames; this reader takes frames of raw and RLE
/// blocks (what ycodebuild writes) and reports compressed blocks as
/// unsupported. See `specs/xcodebuild/result-bundle.md` §2–§4 and its
/// "Ycode implementation".
public struct XCResultReader {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notABundle(String), missingObject(String), compressed(String), malformed(String)
        public var description: String {
            switch self {
            case .notABundle(let p): "\(p) is not a result bundle (no Info.plist with a root object)."
            case .missingObject(let id): "The result bundle has no object \(id)."
            case .compressed(let id): "The object \(id) uses compressed Zstandard blocks, which this reader does not decode."
            case .malformed(let why): "The result bundle is malformed: \(why)"
            }
        }
    }

    public let bundle: URL
    public let rootID: String

    public init(_ bundle: URL) throws {
        self.bundle = bundle
        guard let data = FileManager.default.contents(atPath: bundle.appendingPathComponent("Info.plist").path),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let root = (info["rootId"] as? [String: Any])?["hash"] as? String else {
            throw Failure.notABundle(bundle.path)
        }
        rootID = root
    }

    /// The bytes of a stored object (its frame decoded).
    public func bytes(_ id: String) throws -> [UInt8] {
        guard let d = FileManager.default.contents(atPath: bundle.appendingPathComponent("Data/data." + id).path) else {
            throw Failure.missingObject(id)
        }
        return try Self.unframe([UInt8](d), id: id)
    }

    public func object(_ id: String) throws -> XCRValue { try XCRValue.decode(bytes(id)) }
    public func root() throws -> XCRValue { try object(rootID) }

    /// A Zstandard frame of raw or RLE blocks (RFC 8878 §3.1).
    static func unframe(_ b: [UInt8], id: String) throws -> [UInt8] {
        guard b.count >= 6, b[0] == 0x28, b[1] == 0xB5, b[2] == 0x2F, b[3] == 0xFD else { return b }
        let fhd = b[4]
        let single = fhd & 0x20 != 0
        let fcsFlag = Int(fhd >> 6)
        let dictFlag = Int(fhd & 0x03)
        let checksum = fhd & 0x04 != 0
        var i = 5
        if !single { i += 1 }
        i += [0, 1, 2, 4][dictFlag]
        i += [single ? 1 : 0, 2, 4, 8][fcsFlag]
        var out: [UInt8] = []
        while true {
            guard i + 3 <= b.count else { throw Failure.malformed("a block header of \(id) is cut off") }
            let header = Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16
            i += 3
            let last = header & 1 != 0
            let type = (header >> 1) & 3
            let size = header >> 3
            switch type {
            case 0:
                guard i + size <= b.count else { throw Failure.malformed("a block of \(id) is cut off") }
                out += b[i..<(i + size)]
                i += size
            case 1:
                guard i < b.count else { throw Failure.malformed("an RLE block of \(id) is cut off") }
                out += [UInt8](repeating: b[i], count: size)
                i += 1
            default:
                throw Failure.compressed(id)
            }
            if last { break }
        }
        if checksum { i += 4 }
        return out
    }

    // MARK: Test results

    /// One test as a result bundle records it.
    public struct Test: Equatable, Sendable {
        public struct Failure: Equatable, Sendable {
            public var message: String
            public var file: String?
            public var line: Int?
        }
        /// The test plan run's name ("Test Scheme Action", or a configuration's).
        public var run: String
        public var target: String
        /// `Class/method()`, `Suite/function()`.
        public var identifier: String
        public var name: String
        /// "Success", "Failure", "Skipped", "Expected Failure".
        public var status: String
        public var duration: Double
        public var failures: [Failure] = []
        public var skipMessage: String?
        public var arguments: [String] = []
    }

    /// Every test of every test action, in the bundle's order.
    public func tests() throws -> [Test] {
        var out: [Test] = []
        let r = try root()
        for action in r["actions"]?.items ?? [] {
            guard let ref = action["actionResult"]?["testsRef"]?["id"]?.text else { continue }
            let plan = try object(ref)
            for summary in plan["summaries"]?.items ?? [] {
                let run = summary["name"]?.text ?? ""
                for testable in summary["testableSummaries"]?.items ?? [] {
                    let target = testable["targetName"]?.text ?? testable["name"]?.text ?? ""
                    func walk(_ node: XCRValue) throws {
                        if node.typeName == "ActionTestMetadata" {
                            var t = Test(run: run, target: target, identifier: node["identifier"]?.text ?? "", name: node["name"]?.text ?? "",
                                         status: node["testStatus"]?.text ?? "", duration: Double(node["duration"]?.text ?? "") ?? 0)
                            if let id = node["summaryRef"]?["id"]?.text {
                                let s = try object(id)
                                t.failures = (s["failureSummaries"]?.items ?? []).map { f in
                                    Test.Failure(message: f["message"]?.text ?? "", file: f["fileName"]?.text.flatMap { $0.isEmpty ? nil : $0 },
                                                 line: f["lineNumber"]?.text.flatMap(Int.init))
                                }
                                t.skipMessage = s["skipNoticeSummary"]?["message"]?.text
                                t.arguments = (s["arguments"]?.items ?? []).compactMap { $0["value"]?["description"]?.text }
                            }
                            out.append(t)
                            return
                        }
                        for child in node["subtests"]?.items ?? [] { try walk(child) }
                    }
                    for node in testable["tests"]?.items ?? [] { try walk(node) }
                }
            }
        }
        return out
    }

    /// The invocation's counts (`ResultMetrics`): tests, failed, skipped,
    /// errors, warnings.
    public func metrics() throws -> [String: Int] {
        var out: [String: Int] = [:]
        guard case .object(_, let fields)? = try root()["metrics"] else { return out }
        for (k, v) in fields { if let n = v.text.flatMap(Int.init) { out[k] = n } }
        return out
    }
}

extension XCRValue {
    /// The type's name.
    public var typeName: String {
        switch self {
        case .object(let t, _), .scalar(let t, _): return t.name
        case .array: return "Array"
        }
    }

    /// An object's field.
    public subscript(_ key: String) -> XCRValue? {
        guard case .object(_, let fields) = self else { return nil }
        return fields.first { $0.0 == key }?.1
    }

    /// A scalar's text.
    public var text: String? {
        if case .scalar(_, let s) = self { return s }
        return nil
    }

    /// An array's items.
    public var items: [XCRValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Decodes the store's text encoding (the inverse of `encode`).
    public static func decode(_ bytes: [UInt8]) throws -> XCRValue {
        var p = Parser(b: bytes)
        let v = try p.value()
        return v
    }

    struct Parser {
        let b: [UInt8]
        var i = 0
        var types: [String: [String]] = [:]

        init(b: [UInt8]) { self.b = b }

        func fail(_ why: String) -> XCResultReader.Failure { .malformed("\(why) at byte \(i)") }

        var peek: UInt8? { i < b.count ? b[i] : nil }

        mutating func expect(_ s: String) throws {
            let u = Array(s.utf8)
            guard i + u.count <= b.count, Array(b[i..<(i + u.count)]) == u else { throw fail("expected \(s)") }
            i += u.count
        }

        /// `<n>:` and n bytes of UTF-8.
        mutating func counted() throws -> String {
            var n = 0
            var digits = 0
            while let c = peek, c >= 0x30, c <= 0x39 {
                n = n * 10 + Int(c - 0x30)
                i += 1
                digits += 1
            }
            guard digits > 0 else { throw fail("expected a length") }
            try expect(":")
            guard i + n <= b.count else { throw fail("a string runs past the end") }
            defer { i += n }
            return String(decoding: b[i..<(i + n)], as: UTF8.self)
        }

        mutating func typedef() throws -> [String] {
            try expect("[K2:_nV")
            var chain = [try counted()]
            if peek == UInt8(ascii: "K") {
                try expect("K2:_s")
                chain += try typedef()
            }
            try expect("]")
            return chain
        }

        mutating func typeRef() throws -> XCRType {
            if peek == UInt8(ascii: "T") {
                i += 1
                let chain = try typedef()
                types[chain[0]] = chain
                var t = XCRType("")
                t.chain = chain
                return t
            }
            try expect("S")
            let name = try counted()
            var t = XCRType("")
            t.chain = types[name] ?? [name]
            return t
        }

        mutating func value() throws -> XCRValue {
            try expect("[")
            let type = try typeRef()
            if type.name == "Array" {
                var items: [XCRValue] = []
                while peek == UInt8(ascii: "[") { items.append(try value()) }
                try expect("]")
                return .array(items)
            }
            var fields: [(String, XCRValue)] = []
            while peek == UInt8(ascii: "K") {
                i += 1
                let key = try counted()
                if key == "_v", peek == UInt8(ascii: "V") {
                    i += 1
                    let text = try counted()
                    try expect("]")
                    return .scalar(type, text)
                }
                fields.append((key, try value()))
            }
            try expect("]")
            return .object(type, fields)
        }
    }
}
