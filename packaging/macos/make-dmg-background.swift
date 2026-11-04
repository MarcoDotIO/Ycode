// Draws the disk image's background (packaging/macos/dmg-background.tiff holds
// the result at 1x and 2x; run this only to change it):
//   swiftc packaging/macos/make-dmg-background.swift -o <tmp>/bg
//   <tmp>/bg frameworks/swiftui/Sources/OVText/Resources/Fonts <out-prefix>
//   tiffutil -cathidpicheck <out-prefix>.png <out-prefix>@2x.png -out packaging/macos/dmg-background.tiff
// Colours follow the icon (plum, cream, coral). Text: Inter (SIL OFL).
// The window is 660 × 400 points with 128-point icons centred at (170, 205)
// and (490, 205) from the top left (make-dmg.sh's layout.json). Finder draws
// the icon labels in dark text, so the picture stays light.
import AppKit
import CoreText

let fonts = URL(fileURLWithPath: CommandLine.arguments[1])
let size = CGSize(width: 660, height: 400)
let iconCentres = [CGPoint(x: 170, y: size.height - 205), CGPoint(x: 490, y: size.height - 205)]

func font(_ file: String, _ points: CGFloat) -> NSFont {
    let url = fonts.appendingPathComponent(file)
    let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as! [CTFontDescriptor]
    return CTFontCreateWithFontDescriptor(descriptors[0], points, nil) as NSFont
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let plum = rgb(0x3A2157), coral = rgb(0xFF7A59), lilac = rgb(0xB9A3E3)

/// A soft round glow that fades to nothing at `radius`.
func glow(_ color: NSColor, at centre: CGPoint, radius: CGFloat) {
    NSGradient(colors: [color, color.withAlphaComponent(0)])!
        .draw(fromCenter: centre, radius: 0, toCenter: centre, radius: radius, options: [])
}

func centred(_ string: String, _ font: NSFont, _ color: NSColor, top: CGFloat, kern: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color,
                                                               .paragraphStyle: style, .kern: kern])
    let height = ceil(text.size().height)
    text.draw(in: NSRect(x: 0, y: size.height - top - height, width: size.width, height: height))
}

func drawBackground() {
    let bounds = NSRect(origin: .zero, size: size)
    NSGradient(starting: rgb(0xFFFDF8), ending: rgb(0xFBEEDD))!.draw(in: bounds, angle: -90)
    glow(plum.withAlphaComponent(0.11), at: CGPoint(x: 60, y: size.height + 40), radius: 330)
    glow(lilac.withAlphaComponent(0.20), at: CGPoint(x: 600, y: size.height - 20), radius: 240)
    glow(coral.withAlphaComponent(0.13), at: CGPoint(x: 640, y: -30), radius: 320)

    // A faint dot grid, strongest at the edges.
    for x in stride(from: CGFloat(9), to: size.width, by: 18) {
        for y in stride(from: CGFloat(9), to: size.height, by: 18) {
            let dx = (x - size.width / 2) / (size.width / 2), dy = (y - size.height / 2) / (size.height / 2)
            let edge = min(1, (dx * dx + dy * dy) * 0.7)
            plum.withAlphaComponent(0.075 * edge).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)).fill()
        }
    }
}

/// A frosted card behind an icon and its Finder label.
func drawCard(around centre: CGPoint) {
    let card = NSRect(x: centre.x - 86, y: centre.y - 100, width: 172, height: 186)
    let path = NSBezierPath(roundedRect: card, xRadius: 30, yRadius: 30)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = plum.withAlphaComponent(0.13)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSColor.white.withAlphaComponent(0.62).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.55), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: path, angle: -90)
    plum.withAlphaComponent(0.08).setStroke()
    path.lineWidth = 1
    path.stroke()
}

/// A dotted arc from the app's card to the Applications card, ending in a chevron.
func drawArrow() {
    let y = iconCentres[0].y + 4, lift: CGFloat = 14
    let start = CGPoint(x: 272, y: y), end = CGPoint(x: 382, y: y)
    let control2 = CGPoint(x: 352, y: y + lift)
    let arc = NSBezierPath()
    arc.move(to: start)
    arc.curve(to: end, controlPoint1: CGPoint(x: 302, y: y + lift), controlPoint2: control2)
    arc.lineWidth = 5
    arc.lineCapStyle = .round
    arc.setLineDash([0, 11], count: 2, phase: 0)
    coral.withAlphaComponent(0.9).setStroke()
    arc.stroke()

    // The chevron follows the arc's direction at its end.
    let angle = atan2(end.y - control2.y, end.x - control2.x)
    let tip = CGPoint(x: end.x + 10 * cos(angle), y: end.y + 10 * sin(angle))
    let head = NSBezierPath()
    for side in [CGFloat(1), -1] {
        let a = angle + .pi - side * 0.7
        head.move(to: CGPoint(x: tip.x + 15 * cos(a), y: tip.y + 15 * sin(a)))
        head.line(to: tip)
    }
    head.lineWidth = 5.5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    coral.setStroke()
    head.stroke()
}

func render(scale: CGFloat, to path: String) {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawBackground()
    iconCentres.forEach(drawCard)
    drawArrow()
    centred("Install Ycode", font("Inter-SemiBold.ttf", 24), plum, top: 38, kern: -0.2)
    centred("Drag the app onto the Applications folder.", font("Inter-Regular.ttf", 13.5),
            plum.withAlphaComponent(0.62), top: 72)
    centred("PUBLIC BETA", font("Inter-Medium.ttf", 10.5), plum.withAlphaComponent(0.42), top: 360, kern: 1.6)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let prefix = CommandLine.arguments[2]
render(scale: 1, to: prefix + ".png")
render(scale: 2, to: prefix + "@2x.png")
