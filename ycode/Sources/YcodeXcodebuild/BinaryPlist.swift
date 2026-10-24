import Foundation

/// A property-list value for `BinaryPlist`, including the keyed-archive
/// `uid` type that `PropertyListSerialization` cannot create portably.
enum BPlist: Equatable {
    case string(String)
    case int(Int)
    case data([UInt8])
    case uid(Int)
    case array([BPlist])
    /// Keys are written in sorted (byte) order.
    case dict([(String, BPlist)])

    static func == (a: BPlist, b: BPlist) -> Bool {
        switch (a, b) {
        case let (.string(x), .string(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.data(x), .data(y)): return x == y
        case let (.uid(x), .uid(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.dict(x), .dict(y)): return x.map(\.0) == y.map(\.0) && x.map(\.1) == y.map(\.1)
        default: return false
        }
    }
}

/// A writer for the `bplist00` binary property-list format (as documented
/// in CoreFoundation's open-source `CFBinaryPList.c` header comment): the
/// same value gives the same bytes on every platform.
enum BinaryPlist {
    private enum Node {
        case leaf(BPlist)
        case array([Int])
        case dict(keys: [Int], values: [Int])
    }

    static func encode(_ root: BPlist) -> [UInt8] {
        var nodes: [Node] = []
        @discardableResult
        func flatten(_ v: BPlist) -> Int {
            let i = nodes.count
            switch v {
            case .array(let items):
                nodes.append(.array([]))
                let refs = items.map { flatten($0) }
                nodes[i] = .array(refs)
            case .dict(let pairs):
                nodes.append(.dict(keys: [], values: []))
                let sorted = pairs.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
                let keys = sorted.map { flatten(.string($0.0)) }
                let values = sorted.map { flatten($0.1) }
                nodes[i] = .dict(keys: keys, values: values)
            default:
                nodes.append(.leaf(v))
            }
            return i
        }
        flatten(root)
        let refSize = byteCount(nodes.count - 1)
        var out = Array("bplist00".utf8)
        var offsets: [Int] = []
        func ref(_ r: Int) -> [UInt8] { bigEndian(r, size: refSize) }
        for node in nodes {
            offsets.append(out.count)
            switch node {
            case .array(let refs):
                out += marker(0xA, refs.count) + refs.flatMap(ref)
            case .dict(let keys, let values):
                out += marker(0xD, keys.count) + keys.flatMap(ref) + values.flatMap(ref)
            case .leaf(let v):
                switch v {
                case .string(let s):
                    if s.unicodeScalars.allSatisfy({ $0.value < 0x80 }) {
                        out += marker(0x5, s.utf8.count) + Array(s.utf8)
                    } else {
                        let units = Array(s.utf16)
                        out += marker(0x6, units.count) + units.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
                    }
                case .int(let n): out += integer(n)
                case .data(let d): out += marker(0x4, d.count) + d
                case .uid(let n):
                    let size = byteCount(n)
                    out += [0x80 | UInt8(size - 1)] + bigEndian(n, size: size)
                case .array, .dict: break
                }
            }
        }
        let tableOffset = out.count
        let offsetSize = byteCount(tableOffset)
        for o in offsets { out += bigEndian(o, size: offsetSize) }
        out += [0, 0, 0, 0, 0, 0, UInt8(offsetSize), UInt8(refSize)]
        out += bigEndian(nodes.count, size: 8) + bigEndian(0, size: 8) + bigEndian(tableOffset, size: 8)
        return out
    }

    /// 1, 2, 4 or 8: the bytes an unsigned value needs.
    static func byteCount(_ n: Int) -> Int {
        n <= 0xFF ? 1 : n <= 0xFFFF ? 2 : n <= 0xFFFF_FFFF ? 4 : 8
    }

    static func bigEndian(_ n: Int, size: Int) -> [UInt8] {
        (0..<size).reversed().map { UInt8(truncatingIfNeeded: UInt64(bitPattern: Int64(n)) >> (8 * UInt64($0))) }
    }

    /// Integers: unsigned in 1, 2 or 4 bytes; signed in 8 (negative values).
    static func integer(_ n: Int) -> [UInt8] {
        let size = n < 0 ? 8 : byteCount(n)
        let power: UInt8 = size == 1 ? 0 : size == 2 ? 1 : size == 4 ? 2 : 3
        return [0x10 | power] + bigEndian(n, size: size)
    }

    /// A type marker with its count in the low nibble, or `F` and an integer.
    static func marker(_ type: UInt8, _ count: Int) -> [UInt8] {
        count < 15 ? [type << 4 | UInt8(count)] : [type << 4 | 0xF] + integer(count)
    }
}

/// An `NSKeyedArchiver`-format archive built by hand (`$archiver`,
/// `$version`, `$top`, `$objects` with `$null` first, objects as dictionaries
/// with a `$class` reference, class dictionaries with `$classname` and
/// `$classes`). Strings and class dictionaries are shared by value; an
/// object's class dictionary follows the objects its fields refer to.
struct KeyedArchive {
    private(set) var objects: [BPlist] = [.string("$null")]
    private var strings: [String: Int] = [:]
    private var classes: [String: Int] = [:]

    /// A shared string object.
    mutating func string(_ s: String) -> BPlist {
        if let i = strings[s] { return .uid(i) }
        objects.append(.string(s))
        strings[s] = objects.count - 1
        return .uid(objects.count - 1)
    }

    /// An object of the class `chain[0]` (`chain` up to `NSObject`); `fields`
    /// encodes its values in order.
    mutating func object(_ chain: [String], _ fields: (inout KeyedArchive) -> [(String, BPlist)]) -> BPlist {
        objects.append(.string(""))
        let i = objects.count - 1
        var values = fields(&self)
        values.append(("$class", classReference(chain)))
        objects[i] = .dict(values)
        return .uid(i)
    }

    mutating func classReference(_ chain: [String]) -> BPlist {
        if let i = classes[chain[0]] { return .uid(i) }
        objects.append(.dict([("$classes", .array(chain.map(BPlist.string))), ("$classname", .string(chain[0]))]))
        classes[chain[0]] = objects.count - 1
        return .uid(objects.count - 1)
    }

    mutating func array(mutable: Bool, _ items: (inout KeyedArchive) -> [BPlist]) -> BPlist {
        object(mutable ? ["NSMutableArray", "NSArray", "NSObject"] : ["NSArray", "NSObject"]) { a in
            [("NS.objects", .array(items(&a)))]
        }
    }

    mutating func mutableData(_ bytes: [UInt8]) -> BPlist {
        object(["NSMutableData", "NSData", "NSObject"]) { _ in [("NS.data", .data(bytes))] }
    }

    /// The archive with `root` as its root object, as a binary property list.
    func encoded(root: BPlist) -> [UInt8] {
        BinaryPlist.encode(.dict([
            ("$archiver", .string("NSKeyedArchiver")),
            ("$objects", .array(objects)),
            ("$top", .dict([("root", root)])),
            ("$version", .int(100000)),
        ]))
    }
}
