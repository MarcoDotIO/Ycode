import Foundation
@testable import USDCore

enum Fixture {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)!
    }

    static func bytes(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: url(name)))
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try bytes(name), as: UTF8.self)
    }

    static func layer(_ name: String) throws -> Layer {
        try LayerIO.read(try bytes(name), identifier: name)
    }
}

/// Field-by-field differences between two layers (empty when equal).
func differences(_ a: Layer, _ b: Layer) -> [String] {
    var out: [String] = []
    for p in Set(a.specs.keys).union(b.specs.keys).sorted() {
        let x = a.spec(at: p)
        let y = b.spec(at: p)
        guard x != y else { continue }
        guard let x, let y else {
            out.append("\(p): only in \(x == nil ? "second" : "first")")
            continue
        }
        if x.type != y.type { out.append("\(p): type \(x.type) vs \(y.type)") }
        for k in Set(x.fields.keys).union(y.fields.keys).sorted() where x.fields[k] != y.fields[k] {
            out.append("\(p).\(k): \(String(describing: x.fields[k])) vs \(String(describing: y.fields[k]))")
        }
    }
    return out
}
