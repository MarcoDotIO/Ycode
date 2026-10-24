// An opaque archive value: keeps non-public archive content whose format the
// spec does not fix (codable.md marks these), so it is decoded and written
// back unchanged by the same coder.
import Foundation

struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// A JSON-shaped value read from any decoder.
indirect enum ArchiveValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ArchiveValue])
    case object([String: ArchiveValue])

    init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if single.decodeNil() {
                self = .null
                return
            }
            if let value = try? single.decode(Bool.self) {
                self = .bool(value)
                return
            }
            if let value = try? single.decode(Double.self) {
                self = .number(value)
                return
            }
            if let value = try? single.decode(String.self) {
                self = .string(value)
                return
            }
        }
        if let keyed = try? decoder.container(keyedBy: AnyCodingKey.self) {
            var object: [String: ArchiveValue] = [:]
            for key in keyed.allKeys {
                object[key.stringValue] = try keyed.decode(ArchiveValue.self, forKey: key)
            }
            self = .object(object)
            return
        }
        var unkeyed = try decoder.unkeyedContainer()
        var array: [ArchiveValue] = []
        while !unkeyed.isAtEnd {
            array.append(try unkeyed.decode(ArchiveValue.self))
        }
        self = .array(array)
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case .object(let object):
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                try container.encode(value, forKey: AnyCodingKey(key))
            }
        }
    }
}
