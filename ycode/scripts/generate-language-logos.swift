// Generates Sources/YcodeIDECore/Navigator/LanguageLogoData.swift from the
// single-colour devicon SVGs in Resources/language-logos (MIT, release
// v2.18.0; the "-plain" variant of each logo, the "-line" one where a logo
// has no plain variant): each
// SVG's path data converted to Ycode's own outline data, absolute
// move / line / cubic / close commands only (quadratic curves raised to
// cubics, arcs split into cubics of at most 90°), translated so the
// outline's ink starts at 0, 0, in the SVG's units. Both IDEs fill these
// outlines in one colour at the navigator's glyph box (council round 9,
// row 208; the owner's rule 1). No colour, raster or SVG reader is used:
// the outlines are tinted per file type at run time. Swift is inverted
// (`invertedLogos`): only the bird its plain variant knocks out of a
// rounded square, filled solid.
//
//   swift scripts/generate-language-logos.swift            (from ycode/)
//   swift scripts/generate-language-logos.swift --preview <dir>
//                     (macOS: also writes PNGs of every outline, for a look)
import Foundation
#if canImport(AppKit)
import AppKit
#endif

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dir = root.appendingPathComponent("Resources/language-logos")
let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".svg") }.sorted()

// MARK: Path data

enum Op { case move(Double, Double), line(Double, Double), cubic(Double, Double, Double, Double, Double, Double), close }

/// The tokens of path data: commands and numbers; an arc's two flags are
/// read one character each (they may be written without separators).
struct Scanner {
    let c: [Character]
    var i = 0
    init(_ s: String) { c = Array(s) }
    mutating func skip() { while i < c.count, " ,\n\t\r".contains(c[i]) { i += 1 } }
    mutating func command() -> Character? {
        skip()
        guard i < c.count, c[i].isLetter, c[i] != "e", c[i] != "E" else { return nil }
        defer { i += 1 }
        return c[i]
    }
    var atNumber: Bool {
        mutating get { skip(); return i < c.count && (c[i].isNumber || c[i] == "-" || c[i] == "+" || c[i] == ".") }
    }
    mutating func flag() -> Double {
        skip()
        defer { i += 1 }
        return c[i] == "1" ? 1 : 0
    }
    mutating func number() -> Double {
        skip()
        var s = ""
        if i < c.count, c[i] == "-" || c[i] == "+" { s.append(c[i]); i += 1 }
        while i < c.count, c[i].isNumber { s.append(c[i]); i += 1 }
        if i < c.count, c[i] == "." { s.append(c[i]); i += 1; while i < c.count, c[i].isNumber { s.append(c[i]); i += 1 } }
        if i < c.count, c[i] == "e" || c[i] == "E" {
            s.append(c[i]); i += 1
            if i < c.count, c[i] == "-" || c[i] == "+" { s.append(c[i]); i += 1 }
            while i < c.count, c[i].isNumber { s.append(c[i]); i += 1 }
        }
        guard let v = Double(s) else { fatalError("bad number at \(i): \(String(c[max(0, i - 20)..<min(c.count, i + 20)]))") }
        return v
    }
}

/// An elliptical arc as cubics (SVG 1.1 implementation notes F.6).
func arc(from p0: (Double, Double), rx rx0: Double, ry ry0: Double, angle: Double, large: Bool, sweep: Bool, to p: (Double, Double)) -> [Op] {
    if p0 == p { return [] }
    var rx = abs(rx0), ry = abs(ry0)
    if rx == 0 || ry == 0 { return [.line(p.0, p.1)] }
    let phi = angle * .pi / 180, cp = cos(phi), sp = sin(phi)
    let dx = (p0.0 - p.0) / 2, dy = (p0.1 - p.1) / 2
    let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
    let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
    if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
    let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var k = (max(0, num) / den).squareRoot()
    if large == sweep { k = -k }
    let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
    let cx = cp * cx1 - sp * cy1 + (p0.0 + p.0) / 2, cy = sp * cx1 + cp * cy1 + (p0.1 + p.1) / 2
    func ang(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a
    }
    let t1 = ang(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    var dt = ang((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if !sweep, dt > 0 { dt -= 2 * .pi }
    if sweep, dt < 0 { dt += 2 * .pi }
    let n = max(1, Int((abs(dt) / (.pi / 2)).rounded(.up)))
    let step = dt / Double(n)
    let alpha = 4.0 / 3.0 * tan(step / 4)
    var ops: [Op] = []
    func point(_ t: Double) -> (Double, Double) {
        let x = rx * cos(t), y = ry * sin(t)
        return (cp * x - sp * y + cx, sp * x + cp * y + cy)
    }
    func deriv(_ t: Double) -> (Double, Double) {
        let x = -rx * sin(t), y = ry * cos(t)
        return (cp * x - sp * y, sp * x + cp * y)
    }
    var t = t1
    for s in 0..<n {
        let a = point(t), da = deriv(t), b = s == n - 1 ? p : point(t + step), db = deriv(t + step)
        ops.append(.cubic(a.0 + alpha * da.0, a.1 + alpha * da.1, b.0 - alpha * db.0, b.1 - alpha * db.1, b.0, b.1))
        t += step
    }
    return ops
}

/// Path data as absolute moves, lines, cubics and closes.
func parse(_ d: String) -> [Op] {
    var s = Scanner(d), ops: [Op] = []
    var cur = (0.0, 0.0), start = (0.0, 0.0), lastCtrl: (Double, Double)?, lastQuad: (Double, Double)?
    var cmd: Character = "M"
    while true {
        if let c = s.command() { cmd = c } else if !s.atNumber { break }
        let rel = cmd.isLowercase
        func pt() -> (Double, Double) {
            let x = s.number(), y = s.number()
            return rel ? (cur.0 + x, cur.1 + y) : (x, y)
        }
        var ctrl: (Double, Double)?, quad: (Double, Double)?
        switch cmd.uppercased() {
        case "M":
            cur = pt(); start = cur
            ops.append(.move(cur.0, cur.1))
            cmd = rel ? "l" : "L"   // further pairs are lines
        case "L":
            cur = pt(); ops.append(.line(cur.0, cur.1))
        case "H":
            let x = s.number(); cur.0 = rel ? cur.0 + x : x; ops.append(.line(cur.0, cur.1))
        case "V":
            let y = s.number(); cur.1 = rel ? cur.1 + y : y; ops.append(.line(cur.0, cur.1))
        case "C":
            let a = pt(), b = pt(), p = pt()
            ops.append(.cubic(a.0, a.1, b.0, b.1, p.0, p.1)); cur = p; ctrl = b
        case "S":
            let a = lastCtrl.map { (2 * cur.0 - $0.0, 2 * cur.1 - $0.1) } ?? cur
            let b = pt(), p = pt()
            ops.append(.cubic(a.0, a.1, b.0, b.1, p.0, p.1)); cur = p; ctrl = b
        case "Q", "T":
            let q = cmd.uppercased() == "Q" ? pt() : (lastQuad.map { (2 * cur.0 - $0.0, 2 * cur.1 - $0.1) } ?? cur)
            let p = pt()
            ops.append(.cubic(cur.0 + 2 / 3 * (q.0 - cur.0), cur.1 + 2 / 3 * (q.1 - cur.1),
                              p.0 + 2 / 3 * (q.0 - p.0), p.1 + 2 / 3 * (q.1 - p.1), p.0, p.1))
            cur = p; quad = q
        case "A":
            let rx = s.number(), ry = s.number(), angle = s.number(), large = s.flag(), sweep = s.flag()
            let p = pt()
            ops += arc(from: cur, rx: rx, ry: ry, angle: angle, large: large == 1, sweep: sweep == 1, to: p)
            cur = p
        case "Z":
            ops.append(.close); cur = start
        default:
            fatalError("unknown command \(cmd)")
        }
        lastCtrl = ctrl
        lastQuad = quad
    }
    return ops
}

/// The ink box of the outlines (curves sampled).
func inkBox(_ ops: [Op]) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
    var b = (minX: Double.infinity, minY: Double.infinity, maxX: -Double.infinity, maxY: -Double.infinity)
    func add(_ x: Double, _ y: Double) { b.minX = min(b.minX, x); b.minY = min(b.minY, y); b.maxX = max(b.maxX, x); b.maxY = max(b.maxY, y) }
    var cur = (0.0, 0.0)
    for op in ops {
        switch op {
        case let .move(x, y), let .line(x, y): add(x, y); cur = (x, y)
        case let .cubic(x1, y1, x2, y2, x, y):
            for k in 0...24 {
                let t = Double(k) / 24, u = 1 - t
                add(u * u * u * cur.0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x,
                    u * u * u * cur.1 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y)
            }
            cur = (x, y)
        case .close: break
        }
    }
    return b
}

func fmt(_ v: Double) -> String {
    var s = String(format: "%.2f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s == "-0" ? "0" : s
}

/// The outline as compact text: "M x y", "L x y", "C x1 y1 x2 y2 x y", "Z".
func text(_ ops: [Op], dx: Double, dy: Double) -> String {
    ops.map { op -> String in
        switch op {
        case let .move(x, y): "M\(fmt(x - dx)) \(fmt(y - dy))"
        case let .line(x, y): "L\(fmt(x - dx)) \(fmt(y - dy))"
        case let .cubic(a, b, c, d, x, y): "C\(fmt(a - dx)) \(fmt(b - dy)) \(fmt(c - dx)) \(fmt(d - dy)) \(fmt(x - dx)) \(fmt(y - dy))"
        case .close: "Z"
        }
    }.joined()
}

/// Every `d="…"` in an SVG, with whether its fill rule is even-odd.
func paths(_ svg: String) -> [(d: String, evenOdd: Bool)] {
    var out: [(String, Bool)] = [], rest = Substring(svg)
    while let tag = rest.range(of: "<path") {
        rest = rest[tag.upperBound...]
        guard let end = rest.firstIndex(of: ">") else { break }
        let element = rest[..<end]
        rest = rest[end...]
        guard let r = element.range(of: " d=\"") else { continue }
        let d = element[r.upperBound...].prefix { $0 != "\"" }
        out.append((String(d), element.contains("fill-rule=\"evenodd\"") || element.contains("fill-rule:evenodd")))
    }
    return out
}

// MARK: Inversion

/// Logos drawn inverted (the owner's decision of 2026-11-13): devicon's
/// Swift plain variant is a filled rounded square with the bird knocked
/// out; Ycode keeps only the knocked-out shape, the bird, filled solid (the
/// reference's Swift glyph is a filled bird).
let invertedLogos: Set<String> = ["swift"]

/// A path's subpaths (each from a move).
func subpaths(_ ops: [Op]) -> [[Op]] {
    var out: [[Op]] = []
    for op in ops {
        if case .move = op { out.append([]) }
        if out.isEmpty { out.append([]) }
        out[out.count - 1].append(op)
    }
    return out
}

/// The shape knocked out of a logo: every subpath but the outermost (the
/// one with the largest ink box), filled even-odd so it comes out solid.
func knockedOut(_ ops: [Op]) -> [Op] {
    let parts = subpaths(ops)
    guard parts.count > 1 else { return ops }
    func area(_ p: [Op]) -> Double { let b = inkBox(p); return (b.maxX - b.minX) * (b.maxY - b.minY) }
    let outer = parts.indices.max { area(parts[$0]) < area(parts[$1]) }!
    return parts.enumerated().filter { $0.offset != outer }.flatMap(\.element)
}

// MARK: Output

struct Glyph { let key: String, file: String, width: Double, height: Double, subpaths: [(String, Bool)], ops: [Op] }
var glyphs: [Glyph] = []
for file in files {
    let svg = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
    let key = String(file.split(separator: "-").first!)
    let inverted = invertedLogos.contains(key)
    let parsed = paths(svg).map { inverted ? (knockedOut(parse($0.d)), true) : (parse($0.d), $0.evenOdd) }
    let all = parsed.flatMap(\.0)
    let box = inkBox(all)
    glyphs.append(Glyph(key: key, file: file, width: box.maxX - box.minX, height: box.maxY - box.minY,
                        subpaths: parsed.map { (text($0.0, dx: box.minX, dy: box.minY), $0.1) }, ops: all))
}

var out = """
// Generated by scripts/generate-language-logos.swift from Resources/language-logos
// (devicon v2.18.0, MIT, single-colour variants; see THIRD_PARTY_NOTICES.md). Do not edit.

extension LanguageLogos {
    /// Each logo's outline: its ink box in the SVG's units and its paths
    /// (absolute M, L, C and Z commands from the ink box's top left, y
    /// down), each with whether it fills even-odd.
    static let outlineData: [String: (source: String, width: Double, height: Double, paths: [(d: String, evenOdd: Bool)])] = [

"""
for g in glyphs {
    out += "        \"\(g.key)\": (source: \"\(g.file)\", width: \(fmt(g.width)), height: \(fmt(g.height)), paths: [\n"
    for (d, eo) in g.subpaths { out += "            (d: \"\(d)\", evenOdd: \(eo)),\n" }
    out += "        ]),\n"
}
out += "    ]\n}\n"
try out.write(to: root.appendingPathComponent("Sources/YcodeIDECore/Navigator/LanguageLogoData.swift"), atomically: true, encoding: .utf8)
print("wrote \(glyphs.count) outlines")

// MARK: Preview (macOS)

#if canImport(AppKit)
if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
    let pdir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    try FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
    for g in glyphs {
        for (px, label) in [(256, "big"), (29, "2x")] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: px, height: px).fill()
            let k = Double(px) / max(g.width, g.height)
            let ox = (Double(px) - g.width * k) / 2, oy = (Double(px) - g.height * k) / 2
            let box = inkBox(g.ops)
            let p = NSBezierPath()
            func q(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: ox + (x - box.minX) * k, y: Double(px) - (oy + (y - box.minY) * k)) }
            for op in g.ops {
                switch op {
                case let .move(x, y): p.move(to: q(x, y))
                case let .line(x, y): p.line(to: q(x, y))
                case let .cubic(a, b, c, d, x, y): p.curve(to: q(x, y), controlPoint1: q(a, b), controlPoint2: q(c, d))
                case .close: p.close()
                }
            }
            NSColor(srgbRed: 0.97, green: 0.46, blue: 0.25, alpha: 1).setFill()
            p.fill()
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using: .png, properties: [:])!.write(to: pdir.appendingPathComponent("\(g.key)-\(label).png"))
        }
    }
    print("previews in \(pdir.path)")
}
#endif
