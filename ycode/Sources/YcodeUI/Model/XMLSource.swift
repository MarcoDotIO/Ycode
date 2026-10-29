import Foundation

/// An XML element tree that remembers where each tag and attribute value
/// sits in the source bytes, so edits can splice only what changes. See
/// `specs/ide/interface-builder.md` §Editing.
public final class XMLSourceNode {
    /// One attribute of a start tag, with the position of its raw value.
    public struct Attribute {
        /// The attribute name as written.
        public var name: String
        /// Decoded value.
        public var value: String
        /// Byte range of the raw value (inside the quotes).
        public var valueRange: Range<Int>
    }

    /// The element name.
    public let name: String
    /// The start tag's attributes in source order.
    public internal(set) var attributes: [Attribute] = []
    /// `<` … `>` of the start tag (the whole element when self-closing).
    public internal(set) var startTag: Range<Int> = 0..<0
    /// True for `<name … />`, which has no end tag and no children.
    public internal(set) var selfClosing = false
    /// `</name>` when not self-closing.
    public internal(set) var endTag: Range<Int>?
    /// Child elements in source order (text and comments are not kept).
    public internal(set) var children: [XMLSourceNode] = []
    /// The enclosing element; nil for the root.
    public internal(set) weak var parent: XMLSourceNode?

    init(name: String) { self.name = name }

    /// The decoded value of attribute `attr`, or nil when absent.
    public subscript(_ attr: String) -> String? { attributes.first { $0.name == attr }?.value }

    /// The whole element, start tag through end tag.
    public var range: Range<Int> { startTag.lowerBound..<(endTag?.upperBound ?? startTag.upperBound) }

    /// The first child element named `name`, and with the given `key`
    /// attribute when `key` is not nil.
    public func child(_ name: String, key: String? = nil) -> XMLSourceNode? {
        children.first { $0.name == name && (key == nil || $0["key"] == key) }
    }

    /// Calls `f` on this element, then on every descendant (pre-order).
    public func walk(_ f: (XMLSourceNode) -> Void) { f(self); children.forEach { $0.walk(f) } }
}

/// A position-keeping XML reader for Interface Builder documents, plus the
/// attribute escaping their edits use.
public enum XMLSource {
    public struct ParseError: Error, CustomStringConvertible {
        public var offset: Int
        public var description: String { "XML syntax error at byte \(offset)" }
    }

    /// Parses elements (skipping the declaration, comments, CDATA, DOCTYPE
    /// and text). Returns the root element.
    public static func parse(_ b: [UInt8]) throws -> XMLSourceNode {
        var i = 0
        var stack: [XMLSourceNode] = []
        var root: XMLSourceNode?
        func starts(_ s: String, at j: Int) -> Bool {
            let u = Array(s.utf8)
            return j + u.count <= b.count && Array(b[j..<j + u.count]) == u
        }
        func skip(to s: String, from j: Int) throws -> Int {
            let u = Array(s.utf8)
            var k = j
            while k + u.count <= b.count { if Array(b[k..<k + u.count]) == u { return k + u.count }; k += 1 }
            throw ParseError(offset: j)
        }
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 }
        func isNameChar(_ c: UInt8) -> Bool { !isSpace(c) && c != UInt8(ascii: "=") && c != UInt8(ascii: ">") && c != UInt8(ascii: "/") }
        while i < b.count {
            guard b[i] == UInt8(ascii: "<") else { i += 1; continue }
            if starts("<?", at: i) { i = try skip(to: "?>", from: i); continue }
            if starts("<!--", at: i) { i = try skip(to: "-->", from: i); continue }
            if starts("<![CDATA[", at: i) { i = try skip(to: "]]>", from: i); continue }
            if starts("<!", at: i) { i = try skip(to: ">", from: i); continue }
            let tagStart = i
            if starts("</", at: i) {
                let end = try skip(to: ">", from: i)
                guard let open = stack.popLast() else { throw ParseError(offset: i) }
                open.endTag = tagStart..<end
                i = end
                continue
            }
            i += 1
            var j = i
            while j < b.count, isNameChar(b[j]) { j += 1 }
            let node = XMLSourceNode(name: String(decoding: b[i..<j], as: UTF8.self))
            i = j
            while true {
                while i < b.count, isSpace(b[i]) { i += 1 }
                guard i < b.count else { throw ParseError(offset: i) }
                if b[i] == UInt8(ascii: "/"), i + 1 < b.count, b[i + 1] == UInt8(ascii: ">") { node.selfClosing = true; i += 2; break }
                if b[i] == UInt8(ascii: ">") { i += 1; break }
                var k = i
                while k < b.count, isNameChar(b[k]) { k += 1 }
                let attrName = String(decoding: b[i..<k], as: UTF8.self)
                while k < b.count, isSpace(b[k]) { k += 1 }
                guard k < b.count, b[k] == UInt8(ascii: "=") else { throw ParseError(offset: k) }
                k += 1
                while k < b.count, isSpace(b[k]) { k += 1 }
                guard k < b.count, b[k] == UInt8(ascii: "\"") || b[k] == UInt8(ascii: "'") else { throw ParseError(offset: k) }
                let quote = b[k]
                let vStart = k + 1
                var vEnd = vStart
                while vEnd < b.count, b[vEnd] != quote { vEnd += 1 }
                guard vEnd < b.count else { throw ParseError(offset: vStart) }
                node.attributes.append(.init(name: attrName, value: decode(String(decoding: b[vStart..<vEnd], as: UTF8.self)), valueRange: vStart..<vEnd))
                i = vEnd + 1
            }
            node.startTag = tagStart..<i
            node.parent = stack.last
            if let p = stack.last { p.children.append(node) } else if root == nil { root = node }
            if !node.selfClosing { stack.append(node) }
        }
        guard stack.isEmpty, let root else { throw ParseError(offset: b.count) }
        return root
    }

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            guard let semi = rest[amp...].firstIndex(of: ";") else { out += rest[amp...]; return out }
            let ent = rest[rest.index(after: amp)..<semi]
            switch ent {
            case "amp": out += "&"
            case "lt": out += "<"
            case "gt": out += ">"
            case "quot": out += "\""
            case "apos": out += "'"
            default:
                if ent.hasPrefix("#x"), let v = UInt32(ent.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                else if ent.hasPrefix("#"), let v = UInt32(ent.dropFirst()), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                else { out += "&" + ent + ";" }
            }
            rest = rest[rest.index(after: semi)...]
        }
        return out + rest
    }

    /// Escapes an attribute value for double quotes.
    public static func encode(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n": out += "&#10;"
            default: out.append(c)
            }
        }
        return out
    }
}

/// Byte splices on a source buffer, applied from the end so earlier
/// ranges stay valid.
public struct XMLEdit {
    /// Byte range of the source to replace.
    public var range: Range<Int>
    /// Replacement text, written as UTF-8.
    public var text: String
    /// Replaces `range` with `text`.
    public init(_ range: Range<Int>, _ text: String) { self.range = range; self.text = text }

    /// Applies `edits` to `bytes`, last range first. Ranges must not overlap.
    public static func apply(_ edits: [XMLEdit], to bytes: [UInt8]) -> [UInt8] {
        var b = bytes
        for e in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            b.replaceSubrange(e.range, with: Array(e.text.utf8))
        }
        return b
    }

    /// Sets (or, with nil, removes) an attribute: replaces the value in
    /// place, appends ` name="value"` before the tag's closing, or removes
    /// ` name="value"`.
    public static func setAttribute(_ name: String, _ value: String?, on node: XMLSourceNode, in bytes: [UInt8]) -> XMLEdit? {
        if let a = node.attributes.first(where: { $0.name == name }) {
            if let value {
                return a.value == value ? nil : XMLEdit(a.valueRange, XMLSource.encode(value))
            }
            // Remove the attribute and the whitespace before it.
            var start = a.valueRange.lowerBound - 2 - name.utf8.count
            while start > node.startTag.lowerBound, [0x20, 0x09, 0x0A].contains(bytes[start - 1]) { start -= 1 }
            return XMLEdit(start..<(a.valueRange.upperBound + 1), "")
        }
        guard let value else { return nil }
        let close = node.startTag.upperBound - (node.selfClosing ? 2 : 1)
        return XMLEdit(close..<close, " \(name)=\"\(XMLSource.encode(value))\"")
    }

    /// The whitespace before a node's start tag on its line.
    public static func indentation(of node: XMLSourceNode, in bytes: [UInt8]) -> String {
        var k = node.startTag.lowerBound
        while k > 0, bytes[k - 1] == 0x20 || bytes[k - 1] == 0x09 { k -= 1 }
        return String(decoding: bytes[k..<node.startTag.lowerBound], as: UTF8.self)
    }
}
