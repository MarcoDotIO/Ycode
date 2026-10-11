/// A minimal XML element tree that keeps attribute order, for the XML
/// documents Xcode writes (`.xcscheme`, `contents.xcworkspacedata`).
/// See `specs/formats/xcode-xml.md`.
public struct XMLNode: Equatable, Sendable {
    public var name: String
    public var attributes: [(name: String, value: String)]
    public var children: [XMLNode]
    /// Character data, if any; whitespace-only text is dropped.
    public var text: String?

    public init(_ name: String, attributes: [(String, String)] = [], children: [XMLNode] = [], text: String? = nil) {
        self.name = name
        self.attributes = attributes.map { (name: $0.0, value: $0.1) }
        self.children = children
        self.text = text
    }

    public subscript(attribute: String) -> String? {
        get { attributes.first { $0.name == attribute }?.value }
        set {
            if let i = attributes.firstIndex(where: { $0.name == attribute }) {
                if let newValue { attributes[i].value = newValue } else { attributes.remove(at: i) }
            } else if let newValue {
                attributes.append((attribute, newValue))
            }
        }
    }

    public func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    public func children(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }

    /// All descendants (depth-first, pre-order) with the given name.
    public func descendants(_ name: String) -> [XMLNode] {
        var out: [XMLNode] = []
        for c in children {
            if c.name == name { out.append(c) }
            out += c.descendants(name)
        }
        return out
    }

    public static func == (a: XMLNode, b: XMLNode) -> Bool {
        a.name == b.name && a.text == b.text && a.children == b.children
            && a.attributes.count == b.attributes.count
            && zip(a.attributes, b.attributes).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }
}

// MARK: - Reading

public struct XMLReadError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public var offset: Int
    public var description: String { "XML error at byte \(offset): \(message)" }
}

public enum XcodeXML {
    /// Parses a document and returns its root element. Handles the XML
    /// declaration, comments, CDATA, and the predefined/numeric entities.
    /// DTDs and namespaces are not interpreted.
    public static func parse(_ text: String) throws(XMLReadError) -> XMLNode {
        var r = Reader(Array(text.utf8))
        return try r.document()
    }

    private struct Reader {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        mutating func document() throws(XMLReadError) -> XMLNode {
            if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
            try misc()
            guard peek("<") else { throw fail("expected root element") }
            let root = try element()
            try misc()
            if i < b.count { throw fail("content after root element") }
            return root
        }

        /// Skips whitespace, comments, processing instructions, and doctype.
        mutating func misc() throws(XMLReadError) {
            while true {
                skipSpace()
                if starts("<?") { try skip(past: "?>") }
                else if starts("<!--") { try skip(past: "-->") }
                else if starts("<!DOCTYPE") { try skip(past: ">") }
                else { return }
            }
        }

        mutating func element() throws(XMLReadError) -> XMLNode {
            i += 1  // <
            let name = try nameToken()
            var node = XMLNode(name)
            while true {
                skipSpace()
                if starts("/>") { i += 2; return node }
                if peek(">") { i += 1; break }
                let attr = try nameToken()
                skipSpace()
                guard peek("=") else { throw fail("expected '=' after attribute \(attr)") }
                i += 1
                skipSpace()
                guard i < b.count, b[i] == UInt8(ascii: "\"") || b[i] == UInt8(ascii: "'") else {
                    throw fail("expected quoted attribute value")
                }
                let q = b[i]
                i += 1
                let start = i
                while i < b.count, b[i] != q { i += 1 }
                guard i < b.count else { throw fail("unterminated attribute value") }
                let raw = String(decoding: b[start..<i], as: UTF8.self)
                i += 1
                node.attributes.append((attr, try decodeEntities(raw)))
            }
            var text = ""
            while true {
                guard i < b.count else { throw fail("unterminated element <\(name)>") }
                if starts("</") {
                    i += 2
                    let close = try nameToken()
                    guard close == name else { throw fail("mismatched </\(close)>, expected </\(name)>") }
                    skipSpace()
                    guard peek(">") else { throw fail("expected '>'") }
                    i += 1
                    break
                } else if starts("<!--") {
                    try skip(past: "-->")
                } else if starts("<![CDATA[") {
                    i += 9
                    let start = i
                    try skip(past: "]]>")
                    text += String(decoding: b[start..<(i - 3)], as: UTF8.self)
                } else if peek("<") {
                    node.children.append(try element())
                } else {
                    let start = i
                    while i < b.count, b[i] != UInt8(ascii: "<") { i += 1 }
                    text += try decodeEntities(String(decoding: b[start..<i], as: UTF8.self))
                }
            }
            if !text.allSatisfy(\.isWhitespace) { node.text = text }
            return node
        }

        mutating func nameToken() throws(XMLReadError) -> String {
            let start = i
            while i < b.count {
                let c = b[i]
                let ok = (c >= 0x80) || (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z"))
                    || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
                    || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
                    || c == UInt8(ascii: "_") || c == UInt8(ascii: "-") || c == UInt8(ascii: ".") || c == UInt8(ascii: ":")
                if !ok { break }
                i += 1
            }
            guard i > start else { throw fail("expected a name") }
            return String(decoding: b[start..<i], as: UTF8.self)
        }

        func decodeEntities(_ s: String) throws(XMLReadError) -> String {
            guard s.contains("&") else { return s }
            var out = ""
            var rest = Substring(s)
            while let amp = rest.firstIndex(of: "&") {
                out += rest[..<amp]
                guard let semi = rest[amp...].firstIndex(of: ";") else { throw fail("unterminated entity") }
                let entity = rest[rest.index(after: amp)..<semi]
                switch entity {
                case "amp": out += "&"
                case "lt": out += "<"
                case "gt": out += ">"
                case "quot": out += "\""
                case "apos": out += "'"
                default:
                    var code: UInt32?
                    if entity.hasPrefix("#x") { code = UInt32(entity.dropFirst(2), radix: 16) }
                    else if entity.hasPrefix("#") { code = UInt32(entity.dropFirst(), radix: 10) }
                    guard let code, let scalar = Unicode.Scalar(code) else { throw fail("unknown entity &\(entity);") }
                    out.unicodeScalars.append(scalar)
                }
                rest = rest[rest.index(after: semi)...]
            }
            return out + rest
        }

        mutating func skipSpace() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x09 || b[i] == 0x0D { i += 1 }
        }

        mutating func skip(past marker: String) throws(XMLReadError) {
            let m = Array(marker.utf8)
            while i + m.count <= b.count {
                if b[i..<(i + m.count)].elementsEqual(m) { i += m.count; return }
                i += 1
            }
            throw fail("expected '\(marker)'")
        }

        func peek(_ c: Unicode.Scalar) -> Bool { i < b.count && b[i] == UInt8(ascii: c) }
        func starts(_ s: String) -> Bool {
            let m = Array(s.utf8)
            return i + m.count <= b.count && b[i..<(i + m.count)].elementsEqual(m)
        }
        func fail(_ m: String) -> XMLReadError { XMLReadError(message: m, offset: i) }
    }

    // MARK: - Writing

    /// Serializes in Xcode's layout: 3-space indentation, one attribute per
    /// line as `name = "value"`, and an explicit end tag for every element.
    public static func write(_ root: XMLNode) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        write(root, depth: 0, into: &out)
        return out
    }

    private static func write(_ node: XMLNode, depth: Int, into out: inout String) {
        let pad = String(repeating: " ", count: depth * 3)
        let attrPad = String(repeating: " ", count: (depth + 1) * 3)
        out += pad + "<" + node.name
        for a in node.attributes {
            out += "\n" + attrPad + a.name + " = \"" + escape(a.value) + "\""
        }
        out += ">\n"
        if let text = node.text { out += escapeText(text) + "\n" }
        for c in node.children { write(c, depth: depth + 1, into: &out) }
        out += pad + "</" + node.name + ">\n"
    }

    /// Attribute-value escaping. Line breaks and tabs become character
    /// references so that multi-line values (scripts) survive.
    public static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n": out += "&#10;"
            case "\r": out += "&#13;"
            case "\t": out += "&#9;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    static func escapeText(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
