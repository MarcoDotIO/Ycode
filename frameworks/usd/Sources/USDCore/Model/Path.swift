/// A USD scene path: `/World/Robot{look=red}Arm.xformOp:translate`.
///
/// Paths name prims, variant selections and properties. Absolute paths start
/// at the pseudo-root `/`; relative paths (used inside reference targets and
/// relationship values) may start with `..` elements. The textual grammar is
/// the one of the OpenUSD documentation ("Path syntax").
public struct Path: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// One step of a path.
    public enum Element: Hashable, Sendable {
        /// `..` (relative paths only).
        case parent
        /// A prim name.
        case prim(String)
        /// `{set=variant}`; an empty variant names the variant set itself.
        case variantSelection(set: String, variant: String)
        /// `.name` (a namespaced property name).
        case property(String)
        /// `[path]`: a relationship target or attribute connection spec.
        case target(Path)
    }

    public enum Kind: Hashable, Sendable {
        case empty, absolute, relative
    }

    public let kind: Kind
    public let elements: [Element]

    public init(kind: Kind, elements: [Element]) {
        self.kind = kind
        self.elements = kind == .empty ? [] : elements
    }

    /// The empty path (no path at all).
    public static let empty = Path(kind: .empty, elements: [])
    /// The pseudo-root, `/`.
    public static let root = Path(kind: .absolute, elements: [])
    /// The relative path to the anchor itself, `.`.
    public static let reflexive = Path(kind: .relative, elements: [])

    /// Parses a path string (same as `init?(_:)`; use this spelling with a
    /// string literal, where `Path("…")` means the literal conversion).
    public init?(parsing text: String) {
        self.init(text)
    }

    /// Parses a path string. Returns `nil` when the text is not a path.
    public init?(_ text: String) {
        if text.isEmpty {
            self = .empty
            return
        }
        var parser = PathParser(Array(text.unicodeScalars))
        guard let path = parser.parse(), parser.atEnd else { return nil }
        self = path
    }

    // MARK: Queries

    public var isEmpty: Bool { kind == .empty }
    public var isAbsolute: Bool { kind == .absolute }
    public var isRoot: Bool { kind == .absolute && elements.isEmpty }

    /// The last element, if any.
    public var last: Element? { elements.last }

    /// True for a prim path (`/A/B`) or a prim in a variant (`/A{v=x}B`).
    public var isPrimPath: Bool {
        if case .prim = elements.last { return true }
        return false
    }

    /// True for `/A{set=variant}`.
    public var isVariantSelectionPath: Bool {
        if case .variantSelection = elements.last { return true }
        return false
    }

    /// True when the last element is a property.
    public var isPropertyPath: Bool {
        if case .property = elements.last { return true }
        return false
    }

    /// True for a property directly on a prim (or variant selection), the
    /// kind of path the crate format stores with a negative element token.
    public var isPrimPropertyPath: Bool {
        guard isPropertyPath else { return false }
        if elements.count == 1 { return true }
        switch elements[elements.count - 2] {
        case .prim, .variantSelection: return true
        default: return false
        }
    }

    public var isTargetPath: Bool {
        if case .target = elements.last { return true }
        return false
    }

    /// True if any element is a variant selection.
    public var containsVariantSelection: Bool {
        elements.contains { if case .variantSelection = $0 { return true }; return false }
    }

    /// The name of the last element: the prim or property name, the variant
    /// name of a selection, `..` for a parent step, and "" for the root.
    public var name: String {
        switch elements.last {
        case .prim(let n), .property(let n): return n
        case .variantSelection(_, let v): return v
        case .parent: return ".."
        case .target(let p): return p.description
        case nil: return ""
        }
    }

    /// The text of the last element as it appears in the path string
    /// (`Arm`, `{look=red}`, `xformOp:translate`, `[/T]`).
    public var elementString: String {
        guard let last = elements.last else { return "" }
        return Path.text(of: last)
    }

    /// The parent: the owning prim for a property, the prim for a variant
    /// selection, the parent prim for a prim, and the root for a top-level
    /// prim. The root and the empty path have no parent (returns `.empty`).
    public var parent: Path {
        guard !elements.isEmpty else {
            return kind == .relative ? Path(kind: .relative, elements: [.parent]) : .empty
        }
        return Path(kind: kind, elements: Array(elements.dropLast()))
    }

    /// The nearest prim (or root) path: strips properties and targets.
    public var primPath: Path {
        var elems = elements
        while let last = elems.last {
            switch last {
            case .property, .target: elems.removeLast()
            default: return Path(kind: kind, elements: elems)
            }
        }
        return Path(kind: kind, elements: elems)
    }

    /// The path with every variant selection removed (the namespace path).
    public var strippingVariantSelections: Path {
        Path(kind: kind, elements: elements.filter {
            if case .variantSelection = $0 { return false }
            return true
        })
    }

    /// Prim names along the path (variant selections skipped).
    public var primNames: [String] {
        elements.compactMap { if case .prim(let n) = $0 { return n }; return nil }
    }

    public func hasPrefix(_ prefix: Path) -> Bool {
        guard kind == prefix.kind, prefix.elements.count <= elements.count else { return false }
        return Array(elements.prefix(prefix.elements.count)) == prefix.elements
    }

    /// Replaces `prefix` with `replacement` when this path has that prefix.
    public func replacingPrefix(_ prefix: Path, with replacement: Path) -> Path {
        guard hasPrefix(prefix) else { return self }
        return Path(kind: replacement.kind, elements: replacement.elements + elements.dropFirst(prefix.elements.count))
    }

    // MARK: Construction

    public func appending(_ element: Element) -> Path {
        Path(kind: kind == .empty ? .relative : kind, elements: elements + [element])
    }

    public func appendingChild(_ name: String) -> Path { appending(.prim(name)) }
    public func appendingProperty(_ name: String) -> Path { appending(.property(name)) }
    public func appendingVariantSelection(set: String, variant: String) -> Path {
        appending(.variantSelection(set: set, variant: variant))
    }
    public func appendingTarget(_ target: Path) -> Path { appending(.target(target)) }

    /// Appends a path element given as text, as the crate format stores it:
    /// a prim name, `{set=variant}`, `[target]` or (with `isProperty`) a
    /// property name.
    public func appendingElementText(_ text: String, isProperty: Bool) -> Path {
        if isProperty { return appendingProperty(text) }
        if text.hasPrefix("{"), text.hasSuffix("}"), let eq = text.firstIndex(of: "=") {
            let set = String(text[text.index(after: text.startIndex)..<eq])
            let variant = String(text[text.index(after: eq)..<text.index(before: text.endIndex)])
            return appendingVariantSelection(set: set, variant: variant)
        }
        if text.hasPrefix("["), text.hasSuffix("]"), let target = Path(String(text.dropFirst().dropLast())) {
            return appendingTarget(target)
        }
        if text == ".." { return appending(.parent) }
        return appendingChild(text)
    }

    /// Resolves a relative path against an absolute anchor.
    public func makingAbsolute(anchor: Path) -> Path {
        guard kind == .relative else { return self }
        var result = anchor.elements
        for element in elements {
            if element == .parent {
                if !result.isEmpty { result.removeLast() }
            } else {
                result.append(element)
            }
        }
        return Path(kind: .absolute, elements: result)
    }

    /// Expresses an absolute path relative to an absolute anchor.
    public func makingRelative(anchor: Path) -> Path {
        guard kind == .absolute, anchor.kind == .absolute else { return self }
        var common = 0
        while common < elements.count, common < anchor.elements.count, elements[common] == anchor.elements[common] {
            common += 1
        }
        let ups = Array(repeating: Element.parent, count: anchor.elements.count - common)
        return Path(kind: .relative, elements: ups + elements[common...])
    }

    // MARK: Text

    public var description: String {
        switch kind {
        case .empty: return ""
        case .absolute where elements.isEmpty: return "/"
        case .relative where elements.isEmpty: return "."
        default: break
        }
        var out = kind == .absolute ? "/" : ""
        var previous: Element?
        for element in elements {
            switch element {
            case .prim(let n):
                if let previous {
                    if case .variantSelection = previous {} else { out += "/" }
                }
                out += n
            case .parent:
                if previous != nil { out += "/" }
                out += ".."
            case .variantSelection, .property, .target:
                out += Path.text(of: element)
            }
            previous = element
        }
        return out
    }

    static func text(of element: Element) -> String {
        switch element {
        case .parent: return ".."
        case .prim(let n): return n
        case .variantSelection(let s, let v): return "{\(s)=\(v)}"
        case .property(let n): return "." + n
        case .target(let p): return "[\(p.description)]"
        }
    }

    public static func < (lhs: Path, rhs: Path) -> Bool {
        lhs.description.unicodeScalars.lexicographicallyPrecedes(rhs.description.unicodeScalars)
    }
}

extension Path: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        guard let path = Path(value) else { preconditionFailure("invalid USD path literal: \(value)") }
        self = path
    }
}

extension Path: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let path = Path(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid path \(text)"))
        }
        self = path
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Recursive-descent parser for path text.
struct PathParser {
    let s: [Unicode.Scalar]
    var i = 0

    init(_ s: [Unicode.Scalar]) { self.s = s }

    var atEnd: Bool { i >= s.count }

    func peek(_ offset: Int = 0) -> Unicode.Scalar? { i + offset < s.count ? s[i + offset] : nil }

    static func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
        c == "_" || c.properties.isAlphabetic
    }

    static func isIdentifierContinue(_ c: Unicode.Scalar) -> Bool {
        c == "_" || c.properties.isAlphabetic || c.properties.numericType != nil || (c.value >= 0x30 && c.value <= 0x39)
    }

    mutating func identifier() -> String? {
        guard let c = peek(), PathParser.isIdentifierStart(c) else { return nil }
        var out = String.UnicodeScalarView()
        while let c = peek(), PathParser.isIdentifierContinue(c) {
            out.append(c)
            i += 1
        }
        return String(out)
    }

    mutating func namespacedIdentifier() -> String? {
        guard var name = identifier() else { return nil }
        while peek() == ":", let next = peek(1), PathParser.isIdentifierStart(next) {
            i += 1
            guard let part = identifier() else { return nil }
            name += ":" + part
        }
        return name
    }

    /// Variant set and variant names: identifiers that may also use `|`, `-`
    /// and digits anywhere (and a leading `.` for variants).
    mutating func variantName(allowEmpty: Bool) -> String? {
        var out = String.UnicodeScalarView()
        while let c = peek(), c != "=", c != "}" {
            guard PathParser.isIdentifierContinue(c) || c == "|" || c == "-" || c == "." else { return nil }
            out.append(c)
            i += 1
        }
        if out.isEmpty && !allowEmpty { return nil }
        return String(out)
    }

    mutating func parse() -> Path? {
        var kind = Path.Kind.relative
        var elements: [Path.Element] = []
        if peek() == "/" {
            kind = .absolute
            i += 1
            if atEnd { return .root }
        } else if peek() == ".", peek(1) == nil || peek(1) == "/" {
            // "." (reflexive) or "./A".
            i += 1
            if atEnd { return .reflexive }
            i += 1
        }
        // Leading parent steps.
        if kind == .relative {
            while peek() == ".", peek(1) == "." {
                i += 2
                elements.append(.parent)
                if peek() == "/" { i += 1 } else { break }
            }
        }
        var expectPrim = true
        var afterSlash = false
        while !atEnd {
            guard let c = peek() else { break }
            if c == "." {
                i += 1
                guard let name = namespacedIdentifier() else { return nil }
                elements.append(.property(name))
                expectPrim = false
                continue
            }
            if c == "{" {
                i += 1
                guard let set = variantName(allowEmpty: false), peek() == "=" else { return nil }
                i += 1
                guard let variant = variantName(allowEmpty: true), peek() == "}" else { return nil }
                i += 1
                elements.append(.variantSelection(set: set, variant: variant))
                expectPrim = true
                continue
            }
            if c == "[" {
                i += 1
                var depth = 1
                var inner = String.UnicodeScalarView()
                while let d = peek() {
                    if d == "[" { depth += 1 }
                    if d == "]" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    inner.append(d)
                    i += 1
                }
                guard peek() == "]", let target = Path(String(inner)) else { return nil }
                i += 1
                elements.append(.target(target))
                continue
            }
            if c == "/" {
                guard !afterSlash, !elements.isEmpty else { return nil }
                switch elements.last! {
                case .prim, .parent: break
                default: return nil
                }
                i += 1
                expectPrim = true
                afterSlash = true
                continue
            }
            afterSlash = false
            guard expectPrim, let name = identifier() else { return nil }
            elements.append(.prim(name))
            expectPrim = false
        }
        if afterSlash || (elements.isEmpty && kind == .relative) { return nil }
        return Path(kind: kind, elements: elements)
    }
}
