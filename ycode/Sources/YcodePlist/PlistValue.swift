/// A property-list value in the OpenStep (NeXTSTEP) data model.
///
/// OpenStep plists have no number, boolean, or date types: every scalar is a
/// string. Dictionaries keep their insertion order so that documents can be
/// edited without reshuffling keys.
public enum PlistValue: Equatable, Hashable, Sendable {
    case string(String)
    case array([PlistValue])
    case dictionary(PlistDictionary)
    case data([UInt8])

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var array: [PlistValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var dictionary: PlistDictionary? {
        if case .dictionary(let d) = self { return d }
        return nil
    }
}

extension PlistValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension PlistValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: PlistValue...) { self = .array(elements) }
}

extension PlistValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, PlistValue)...) {
        self = .dictionary(PlistDictionary(elements))
    }
}

/// An insertion-ordered string-keyed dictionary.
public struct PlistDictionary: Equatable, Hashable, Sendable, Sequence {
    public private(set) var keys: [String] = []
    private var storage: [String: PlistValue] = [:]

    public init() {}

    public init<S: Sequence>(_ pairs: S) where S.Element == (String, PlistValue) {
        for (k, v) in pairs { self[k] = v }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public subscript(key: String) -> PlistValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public func makeIterator() -> AnyIterator<(key: String, value: PlistValue)> {
        var i = keys.makeIterator()
        return AnyIterator {
            guard let k = i.next() else { return nil }
            return (k, storage[k]!)
        }
    }

    public static func == (a: PlistDictionary, b: PlistDictionary) -> Bool {
        a.keys == b.keys && a.storage == b.storage
    }

    public func hash(into h: inout Hasher) {
        h.combine(keys)
        for k in keys { h.combine(storage[k]) }
    }
}

extension PlistValue {
    /// The same value with every dictionary's keys sorted. Two values with
    /// equal canonical forms differ only in key order.
    public var canonicalized: PlistValue {
        switch self {
        case .string, .data: self
        case .array(let a): .array(a.map(\.canonicalized))
        case .dictionary(let d): .dictionary(d.canonicalized)
        }
    }
}

extension PlistDictionary {
    /// The same dictionary with its keys sorted, recursively. Two
    /// dictionaries with equal canonical forms differ only in key order.
    public var canonicalized: PlistDictionary {
        PlistDictionary(keys.sorted().map { ($0, self[$0]!.canonicalized) })
    }
}
