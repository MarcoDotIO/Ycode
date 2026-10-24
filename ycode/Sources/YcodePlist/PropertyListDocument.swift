import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A typed property-list value with ordered dictionaries, for XML (and
/// binary) property lists such as Info.plist. See `specs/ide/plist-editor.md`.
public indirect enum PropertyListItem: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case real(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case array([PropertyListItem])
    case dictionary([PropertyListEntry])

    public var typeName: String {
        switch self {
        case .string: "String"
        case .integer, .real: "Number"
        case .bool: "Boolean"
        case .date: "Date"
        case .data: "Data"
        case .array: "Array"
        case .dictionary: "Dictionary"
        }
    }

    /// One-line text for an editor's Value column.
    public var summary: String {
        switch self {
        case .string(let s): s
        case .integer(let i): String(i)
        case .real(let r): PropertyListDocument.realText(r)
        case .bool(let b): b ? "YES" : "NO"
        case .date(let d): PropertyListDocument.dateFormatter.string(from: d)
        case .data(let d): "<\(d.count) bytes>"
        case .array(let a): "(\(a.count) item\(a.count == 1 ? "" : "s"))"
        case .dictionary(let d): "(\(d.count) item\(d.count == 1 ? "" : "s"))"
        }
    }
}

public struct PropertyListEntry: Equatable, Sendable {
    public var key: String
    public var value: PropertyListItem
    public init(key: String, value: PropertyListItem) {
        self.key = key
        self.value = value
    }
}

public struct PropertyListDocument: Equatable, Sendable {
    public enum Format: Sendable { case xml, binary }
    public var root: PropertyListItem
    public var format: Format

    public struct ParseError: Error, CustomStringConvertible {
        public var description: String
    }

    public init(root: PropertyListItem, format: Format = .xml) {
        self.root = root
        self.format = format
    }

    /// Reads XML or binary property lists, keeping dictionary key order
    /// in both (reference-ui-5.md §11.2).
    public init(data: Data) throws {
        if data.starts(with: Array("bplist".utf8)) {
            root = try BinaryPropertyList.read(data)
            format = .binary
            return
        }
        let reader = XMLPlistReader()
        root = try reader.parse(data)
        format = .xml
    }

    // MARK: Writing

    /// XML in the conventional layout: tab indentation, `<key>` lines,
    /// empty containers as `<dict/>` / `<array/>`.
    public func xml() -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">

        """
        Self.write(root, depth: 0, into: &out)
        out += "</plist>\n"
        return out
    }

    public func data() throws -> Data {
        switch format {
        case .xml: return Data(xml().utf8)
        case .binary: return BinaryPropertyList.write(root)
        }
    }

    static func write(_ v: PropertyListItem, depth: Int, into out: inout String) {
        let pad = String(repeating: "\t", count: depth)
        switch v {
        case .string(let s): out += pad + "<string>" + escape(s) + "</string>\n"
        case .integer(let i): out += pad + "<integer>\(i)</integer>\n"
        case .real(let r): out += pad + "<real>" + realText(r) + "</real>\n"
        case .bool(let b): out += pad + (b ? "<true/>" : "<false/>") + "\n"
        case .date(let d): out += pad + "<date>" + dateFormatter.string(from: d) + "</date>\n"
        case .data(let d):
            out += pad + "<data>\n"
            let b64 = d.base64EncodedString()
            var i = b64.startIndex
            while i < b64.endIndex {
                let j = b64.index(i, offsetBy: 68, limitedBy: b64.endIndex) ?? b64.endIndex
                out += pad + b64[i..<j] + "\n"
                i = j
            }
            out += pad + "</data>\n"
        case .array(let a):
            if a.isEmpty { out += pad + "<array/>\n"; return }
            out += pad + "<array>\n"
            for x in a { write(x, depth: depth + 1, into: &out) }
            out += pad + "</array>\n"
        case .dictionary(let d):
            if d.isEmpty { out += pad + "<dict/>\n"; return }
            out += pad + "<dict>\n"
            for e in d {
                out += pad + "\t<key>" + escape(e.key) + "</key>\n"
                write(e.value, depth: depth + 1, into: &out)
            }
            out += pad + "</dict>\n"
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func realText(_ r: Double) -> String {
        r == r.rounded() && abs(r) < 1e15 ? String(Int(r)) : String(r)
    }

    nonisolated(unsafe) public static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: Foundation bridging (binary plists)

    static func item(fromFoundation o: Any) throws -> PropertyListItem {
        switch o {
        case let s as String: return .string(s)
        case let n as NSNumber:
            // objCType: "c" for booleans, "d"/"f" for floating point.
            switch String(cString: n.objCType) {
            case "c", "B": return .bool(n.boolValue)
            case "d", "f": return .real(n.doubleValue)
            default: return .integer(n.intValue)
            }
        case let d as Date: return .date(d)
        case let d as Data: return .data(d)
        case let a as [Any]: return .array(try a.map(item(fromFoundation:)))
        case let d as [String: Any]:
            return .dictionary(try d.keys.sorted().map { PropertyListEntry(key: $0, value: try item(fromFoundation: d[$0]!)) })
        default: throw ParseError(description: "unsupported value \(type(of: o))")
        }
    }

    static func foundation(_ v: PropertyListItem) -> Any {
        switch v {
        case .string(let s): s
        case .integer(let i): i
        case .real(let r): r
        case .bool(let b): b
        case .date(let d): d
        case .data(let d): d
        case .array(let a): a.map(foundation)
        case .dictionary(let d): Dictionary(d.map { ($0.key, foundation($0.value)) }, uniquingKeysWith: { _, b in b })
        }
    }
}

/// An XMLParser-based reader that keeps dictionary key order.
final class XMLPlistReader: NSObject, XMLParserDelegate {
    private enum Frame {
        case array([PropertyListItem])
        case dict([PropertyListEntry], pendingKey: String?)
    }
    private var stack: [Frame] = []
    private var text = ""
    private var result: PropertyListItem?
    private var error: String?

    func parse(_ data: Data) throws -> PropertyListItem {
        let p = XMLParser(data: data)
        p.delegate = self
        guard p.parse(), error == nil, let result else {
            throw PropertyListDocument.ParseError(description: error ?? p.parserError.map { "\($0)" } ?? "not a property list")
        }
        return result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "array": stack.append(.array([]))
        case "dict": stack.append(.dict([], pendingKey: nil))
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text
        text = ""
        switch name {
        case "plist": return
        case "key":
            if case .dict(let entries, _) = stack.last { stack[stack.count - 1] = .dict(entries, pendingKey: t) }
            return
        case "string": add(.string(t))
        case "integer": add(.integer(Int(t.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0))
        case "real": add(.real(Double(t.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0))
        case "true": add(.bool(true))
        case "false": add(.bool(false))
        case "date": add(.date(PropertyListDocument.dateFormatter.date(from: t.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Date(timeIntervalSince1970: 0)))
        case "data": add(.data(Data(base64Encoded: t.filter { !$0.isWhitespace }) ?? Data()))
        case "array":
            guard case .array(let items)? = stack.popLast() else { error = "unbalanced array"; return }
            add(.array(items))
        case "dict":
            guard case .dict(let entries, _)? = stack.popLast() else { error = "unbalanced dict"; return }
            add(.dictionary(entries))
        default:
            error = "unknown element <\(name)>"
        }
    }

    private func add(_ v: PropertyListItem) {
        guard let top = stack.last else { result = v; return }
        switch top {
        case .array(var items):
            items.append(v)
            stack[stack.count - 1] = .array(items)
        case .dict(var entries, let key):
            guard let key else { error = "value without key"; return }
            entries.append(PropertyListEntry(key: key, value: v))
            stack[stack.count - 1] = .dict(entries, pendingKey: nil)
        }
    }
}
