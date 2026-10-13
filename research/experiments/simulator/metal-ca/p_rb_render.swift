// p_rb_render: Ycode stage-8 test probe (original Ycode code).
//
// Renders a fixed SwiftUI view with the public ImageRenderer API and writes
// a PNG. SwiftUI draws through its own renderer, which uses Metal for
// drawing groups, blurs, shadows, gradients and shader effects; this
// checks those paths through Ycode's Metal host against the Mac.
//
// Usage: p_rb_render [OUT.png [SCALE]]
// Prints one line per step and "rb ok" at the end, or "rb FAIL: ...".

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

func step(_ s: String) {
    print("p_rb_render: \(s)")
    fflush(stdout)
}

struct Cell<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ c: () -> Content) { content = c() }
    var body: some View {
        content
            .frame(width: 150, height: 200)
            .background(Color(red: 0.92, green: 0.92, blue: 0.95))
            .border(Color(red: 0.6, green: 0.6, blue: 0.65), width: 1)
    }
}

struct Grid16: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Cell { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.red).frame(width: 100, height: 100) }
                Cell { Circle().fill(LinearGradient(colors: [.yellow, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 100, height: 100) }
                Cell { Rectangle().fill(RadialGradient(colors: [.white, .purple], center: .center, startRadius: 5, endRadius: 60))
                        .frame(width: 100, height: 100) }
                Cell { Rectangle().fill(AngularGradient(colors: [.red, .green, .blue, .red], center: .center))
                        .frame(width: 100, height: 100).clipShape(Circle()) }
            }
            HStack(spacing: 0) {
                Cell { RoundedRectangle(cornerRadius: 16).fill(Color.blue).frame(width: 80, height: 80)
                        .shadow(color: .black.opacity(0.6), radius: 10, x: 4, y: 8) }
                Cell { HStack(spacing: 4) { ForEach(0..<5) { i in Rectangle().fill(Color(hue: Double(i) / 5, saturation: 1, brightness: 1)) } }
                        .frame(width: 100, height: 100).blur(radius: 6) }
                Cell { Text("Ycode").font(.system(size: 30, weight: .bold)).foregroundStyle(.black) }
                Cell { Image(systemName: "star.fill").font(.system(size: 70)).foregroundStyle(.orange) }
            }
            HStack(spacing: 0) {
                Cell { ZStack { Rectangle().fill(Color.red).frame(width: 70, height: 70).offset(x: -15, y: -15)
                                Rectangle().fill(Color.blue).frame(width: 70, height: 70).offset(x: 15, y: 15) }
                        .compositingGroup().opacity(0.5) }
                Cell { ZStack { Rectangle().fill(Color.yellow).frame(width: 100, height: 100)
                                Circle().fill(Color.pink).frame(width: 70, height: 70).blendMode(.multiply) } }
                Cell { ZStack { Rectangle().fill(Color.green).frame(width: 100, height: 100)
                                Circle().fill(Color.blue).frame(width: 70, height: 70).blendMode(.screen) }.drawingGroup() }
                Cell { Rectangle().fill(LinearGradient(colors: [.orange, .purple], startPoint: .top, endPoint: .bottom))
                        .frame(width: 100, height: 100).rotationEffect(.degrees(30)) }
            }
            HStack(spacing: 0) {
                Cell { Rectangle().fill(Color.teal).frame(width: 100, height: 100)
                        .mask(Text("Y").font(.system(size: 110, weight: .black))) }
                Cell { Capsule().stroke(Color.indigo, lineWidth: 8).frame(width: 110, height: 60) }
                Cell { Rectangle().fill(Color.mint).frame(width: 100, height: 100).saturation(0.2).brightness(0.1) }
                Cell { Rectangle().fill(Color.cyan).frame(width: 100, height: 100).hueRotation(.degrees(90)).contrast(1.4) }
            }
        }
        .background(Color.white)
    }
}

@MainActor
func render(_ out: String, scale: CGFloat) -> Int32 {
    step("start")
    let renderer = ImageRenderer(content: Grid16())
    renderer.scale = scale
    guard let image = renderer.cgImage else {
        print("rb FAIL: no image")
        return 1
    }
    step("rendered \(image.width)x\(image.height)")
    let w = image.width, h = image.height
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { print("rb FAIL: no bitmap context"); return 1 }
    var hash: UInt64 = 1469598103934665603
    for b in rgba { hash = (hash ^ UInt64(b)) &* 1099511628211 }
    print("p_rb_render: \(w)x\(h), fnv1a64 \(String(hash, radix: 16))")
    let url = URL(fileURLWithPath: out) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        print("rb FAIL: cannot write \(out)")
        return 1
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { print("rb FAIL: cannot finalize \(out)"); return 1 }
    print("p_rb_render: wrote \(out)")
    print("rb ok")
    return 0
}

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "/tmp/p_rb_render.png"
let scale = args.count > 2 ? CGFloat(Double(args[2]) ?? 1) : 1
let status = MainActor.assumeIsolated { render(out, scale: scale) }
exit(status)
