// Draws the disk image's background (packaging/macos/dmg-background.tiff holds
// the result at 1x and 2x; run this only to change it):
//   swiftc packaging/macos/make-dmg-background.swift -o <tmp>/bg && <tmp>/bg <font.ttf> <out-prefix>
//   tiffutil -cathidpicheck <out-prefix>.png <out-prefix>@2x.png -out packaging/macos/dmg-background.tiff
// Colours follow the icon (plum, cream, coral). Text: Inter (SIL OFL).
import AppKit
import CoreText

let fontURL = URL(fileURLWithPath: CommandLine.arguments[1])
let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as! [CTFontDescriptor]
let size = CGSize(width: 660, height: 420)

func render(scale: CGFloat, to path: String) {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cream = NSColor(srgbRed: 1.0, green: 0.953, blue: 0.863, alpha: 1)
    let paper = NSColor(srgbRed: 1.0, green: 0.984, blue: 0.957, alpha: 1)
    NSGradient(starting: paper, ending: cream)!.draw(in: NSRect(origin: .zero, size: size), angle: -90)
    // The arrow from the app to Applications.
    let coral = NSColor(srgbRed: 1.0, green: 0.478, blue: 0.349, alpha: 1)
    coral.setStroke()
    let y = size.height - 190
    let shaft = NSBezierPath()
    shaft.lineWidth = 7
    shaft.lineCapStyle = .round
    shaft.lineJoinStyle = .round
    shaft.move(to: NSPoint(x: 268, y: y))
    shaft.line(to: NSPoint(x: 388, y: y))
    shaft.move(to: NSPoint(x: 364, y: y + 24))
    shaft.line(to: NSPoint(x: 390, y: y))
    shaft.line(to: NSPoint(x: 364, y: y - 24))
    shaft.stroke()
    // The instruction.
    let plum = NSColor(srgbRed: 0.227, green: 0.129, blue: 0.341, alpha: 1)
    let font = CTFontCreateWithFontDescriptor(descriptors[0], 19, nil) as NSFont
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let text = NSAttributedString(string: "Drag Ycode to Applications", attributes: [.font: font, .foregroundColor: plum, .paragraphStyle: style])
    text.draw(in: NSRect(x: 0, y: size.height - 92, width: size.width, height: 34))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let prefix = CommandLine.arguments[2]
render(scale: 1, to: prefix + ".png")
render(scale: 2, to: prefix + "@2x.png")
