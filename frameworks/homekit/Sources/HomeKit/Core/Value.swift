// Characteristic values: the Codable wire form and the API form
// (object-model.md §7 "Value representation in the API").

import Foundation

/// A characteristic value as stored and sent across the store boundary.
public enum YcodeHomeValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case data(Data)
    case array([YcodeHomeValue])
    case dictionary([String: YcodeHomeValue])

    /// The value as the API shows it: booleans and numbers as `NSNumber`,
    /// strings as `String`, TLV8 and data as `Data`.
    public var apiValue: Any {
        switch self {
        case .bool(let b): return NSNumber(value: b)
        case .int(let i): return NSNumber(value: i)
        case .uint(let u): return NSNumber(value: u)
        case .float(let d): return NSNumber(value: d)
        case .string(let s): return s
        case .data(let d): return d
        case .array(let a): return a.map(\.apiValue)
        case .dictionary(let d): return d.mapValues(\.apiValue)
        }
    }

    /// Numeric view (bools as 0/1), nil for non-numbers.
    public var doubleValue: Double? {
        switch self {
        case .bool(let b): return b ? 1 : 0
        case .int(let i): return Double(i)
        case .uint(let u): return Double(u)
        case .float(let d): return d
        default: return nil
        }
    }

    /// A loose conversion from an API value without a format: used for values
    /// the app hands over where no metadata applies (event trigger values).
    public init?(any value: Any?) {
        guard let value else { return nil }
        switch value {
        case let v as YcodeHomeValue: self = v
        case let b as Bool where type(of: value) == Bool.self: self = .bool(b)
        case let s as String: self = .string(s)
        case let d as Data: self = .data(d)
        case let n as NSNumber:
            if let i = n as? Int64, Double(i) == n.doubleValue { self = .int(i) } else { self = .float(n.doubleValue) }
        case let a as [Any]:
            var out: [YcodeHomeValue] = []
            for e in a { guard let v = YcodeHomeValue(any: e) else { return nil }; out.append(v) }
            self = .array(out)
        case let d as [String: Any]:
            var out: [String: YcodeHomeValue] = [:]
            for (k, e) in d { guard let v = YcodeHomeValue(any: e) else { return nil }; out[k] = v }
            self = .dictionary(out)
        default:
            if let n = Self.number(value) {
                if let i = Int64(exactly: n) { self = .int(i) } else { self = .float(n) }
            } else {
                return nil
            }
        }
    }

    /// A Swift numeric or NSNumber as Double (exact for the integer types the
    /// formats use); nil for anything else. Swift `Bool` is not a number here.
    static func number(_ value: Any) -> Double? {
        switch value {
        case let v as Int where type(of: value) == Int.self: return Double(v)
        case let v as Int8 where type(of: value) == Int8.self: return Double(v)
        case let v as Int16 where type(of: value) == Int16.self: return Double(v)
        case let v as Int32 where type(of: value) == Int32.self: return Double(v)
        case let v as Int64 where type(of: value) == Int64.self: return Double(v)
        case let v as UInt where type(of: value) == UInt.self: return Double(v)
        case let v as UInt8 where type(of: value) == UInt8.self: return Double(v)
        case let v as UInt16 where type(of: value) == UInt16.self: return Double(v)
        case let v as UInt32 where type(of: value) == UInt32.self: return Double(v)
        case let v as UInt64 where type(of: value) == UInt64.self: return Double(v)
        case let v as Double where type(of: value) == Double.self: return v
        case let v as Float where type(of: value) == Float.self: return Double(v)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    /// Exact integer view of a Swift integer or NSNumber, to keep 64-bit values exact.
    static func integer(_ value: Any) -> (signed: Int64?, unsigned: UInt64?)? {
        switch value {
        case let v as Int where type(of: value) == Int.self: return (Int64(v), v >= 0 ? UInt64(v) : nil)
        case let v as Int64 where type(of: value) == Int64.self: return (v, v >= 0 ? UInt64(v) : nil)
        case let v as UInt64 where type(of: value) == UInt64.self: return (Int64(exactly: v), v)
        case let v as UInt where type(of: value) == UInt.self: return (Int64(exactly: v), UInt64(v))
        case let n as NSNumber:
            let d = n.doubleValue
            guard d.rounded() == d else { return nil }
            if d < 0 { return (n.int64Value, nil) }
            return (Int64(exactly: n.uint64Value), n.uint64Value)
        default:
            if let d = number(value), d.rounded() == d, abs(d) < 9.2e18 {
                let i = Int64(d)
                return (i, i >= 0 ? UInt64(i) : nil)
            }
            return nil
        }
    }
}
