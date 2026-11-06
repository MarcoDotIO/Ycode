#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// The object icons of the Library and the Document Outline
/// (`interface-builder.md` §Outline icons): drawn by Ycode from the word
/// descriptions in the spec, as shapes in a 16 × 16 box (origin top-left).
/// Both IDEs draw the same shapes: the macOS editor with AppKit paths, the
/// Linux IDE with a canvas. No artwork files.
public struct IBIcon: Equatable, Sendable {
    /// A fixed colour (icons look the same in light and dark).
    public struct Paint: Equatable, Sendable {
        public var r, g, b, a: Double
        public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

        public static let white = Paint(1, 1, 1)
        public static let black = Paint(0.13, 0.13, 0.14)
        public static let dark = Paint(0.24, 0.25, 0.27)
        public static let gray = Paint(0.62, 0.63, 0.66)
        public static let lightGray = Paint(0.86, 0.87, 0.89)
        public static let border = Paint(0.53, 0.6, 0.7)
        public static let paleBlue = Paint(0.8, 0.88, 0.97)
        public static let blue = Paint(0.04, 0.48, 1)
        public static let tint = Paint(0.78, 0.87, 1)
        public static let yellow = Paint(0.97, 0.76, 0.16)
        public static let yellowLight = Paint(1, 0.89, 0.55)
        public static let orange = Paint(0.99, 0.57, 0.1)
        public static let green = Paint(0.2, 0.78, 0.35)
        public static let red = Paint(0.9, 0.27, 0.23)
        public static let violet = Paint(0.58, 0.36, 0.85)
        public static let teal = Paint(0.15, 0.66, 0.72)
        public static let frosted = Paint(0.76, 0.81, 0.88)
        public static let indigo = Paint(0.33, 0.36, 0.84)
    }

    public enum Shape: Equatable, Sendable {
        /// A rounded rectangle, filled and/or stroked (dashed when asked).
        case rect(CGRect, radius: CGFloat, fill: Paint?, stroke: Paint?, width: CGFloat, dashed: Bool)
        case oval(CGRect, fill: Paint?, stroke: Paint?, width: CGFloat)
        /// Connected lines (closed: a polygon outline).
        case lines([CGPoint], stroke: Paint, width: CGFloat, closed: Bool)
        case polygon([CGPoint], fill: Paint)
        /// An arc of a circle, angles in degrees, clockwise from 3 o'clock (y down).
        case arc(center: CGPoint, radius: CGFloat, from: CGFloat, to: CGFloat, stroke: Paint, width: CGFloat)
        /// Text centered on a point.
        case text(String, center: CGPoint, size: CGFloat, bold: Bool, color: Paint)
    }

    public var shapes: [Shape]
    public init(_ shapes: [Shape]) { self.shapes = shapes }

    // MARK: Building blocks

    static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    static func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
    /// The rounded square most icons stand on.
    static func tile(_ fill: Paint, border: Paint? = nil) -> Shape {
        // Black and dark tiles get a faint light rim so they read on dark backgrounds.
        let rim = border ?? (fill == .black || fill == .dark ? Paint(1, 1, 1, 0.22) : nil)
        return .rect(r(1, 1, 14, 14), radius: 3, fill: fill, stroke: rim, width: 0.75, dashed: false)
    }
    static func line(_ pts: [CGPoint], _ c: Paint, _ w: CGFloat = 1.25) -> Shape { .lines(pts, stroke: c, width: w, closed: false) }
    static func dot(_ x: CGFloat, _ y: CGFloat, _ d: CGFloat, _ c: Paint) -> Shape { .oval(r(x - d / 2, y - d / 2, d, d), fill: c, stroke: nil, width: 0) }
    static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: Paint, radius: CGFloat = 0.5) -> Shape {
        .rect(r(x, y, w, h), radius: radius, fill: c, stroke: nil, width: 0, dashed: false)
    }
    static func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: Paint, width: CGFloat = 1, radius: CGFloat = 1) -> Shape {
        .rect(r(x, y, w, h), radius: radius, fill: nil, stroke: c, width: width, dashed: false)
    }
    static func letter(_ s: String, _ c: Paint, size: CGFloat = 10) -> Shape { .text(s, center: p(8, 8), size: size, bold: true, color: c) }
    /// A white cube outline (SceneKit, objects).
    static func cube(_ c: Paint, _ w: CGFloat = 1) -> [Shape] {
        [.lines([p(8, 3.5), p(12, 5.5), p(12, 10.5), p(8, 12.5), p(4, 10.5), p(4, 5.5)], stroke: c, width: w, closed: true),
         line([p(4, 5.5), p(8, 7.5), p(12, 5.5)], c, w), line([p(8, 7.5), p(8, 12.5)], c, w)]
    }
    /// Corner brackets: the AR mark.
    static func arMark(_ c: Paint) -> [Shape] {
        [line([p(3, 5), p(3, 3), p(5, 3)], c, 1), line([p(11, 3), p(13, 3), p(13, 5)], c, 1),
         line([p(3, 11), p(3, 13), p(5, 13)], c, 1), line([p(11, 13), p(13, 13), p(13, 11)], c, 1)]
    }
    /// A dark bar across the middle (navigation bar, toolbar, tab bar).
    static func bar(_ marks: [Shape]) -> IBIcon { IBIcon([box(1, 4, 14, 8, .dark, radius: 2)] + marks) }
    /// A blue gesture glyph on no tile.
    static func gesture(_ marks: [Shape]) -> IBIcon { IBIcon(marks) }

    // MARK: Icons

    /// Generic views: a white rounded square with a thin blue-grey border.
    public static let view = IBIcon([tile(.white, border: .border)])
    /// Safe Area and other layout guides: a grey dashed square.
    public static let layoutGuide = IBIcon([.rect(r(2, 2, 12, 12), radius: 1.5, fill: nil, stroke: .gray, width: 1, dashed: true)])
    /// Objects: a blue-grey cube.
    public static let object = IBIcon([.polygon([p(8, 2), p(13.5, 4.8), p(13.5, 11.2), p(8, 14), p(2.5, 11.2), p(2.5, 4.8)], fill: .border)] + cube(.white, 0.9).map {
        if case .lines(let pts, _, let w, let closed) = $0, closed { return .lines(pts.map { p(8 + ($0.x - 8) * 1.3, 8 + ($0.y - 8) * 1.3) }, stroke: .white, width: w, closed: true) }
        return $0
    })
    /// The controller row: a yellow circle with a white mark.
    public static let controller = IBIcon([.oval(r(1, 1, 14, 14), fill: .yellow, stroke: nil, width: 0), frame(5, 5, 6, 6, .white, width: 1.25, radius: 1)])
    /// First Responder: an orange square with a white "1".
    public static let firstResponder = IBIcon([tile(.orange), letter("1", .white)])
    /// Exit: an orange square with an arrow leaving a box.
    public static let exit = IBIcon([tile(.orange), line([p(9, 4.5), p(5, 4.5), p(5, 11.5), p(9, 11.5)], .white, 1.25),
                                     line([p(7.5, 8), p(12.5, 8)], .white, 1.25), line([p(10.5, 6), p(12.5, 8), p(10.5, 10)], .white, 1.25)])
    /// Storyboard Entry Point: a pale blue circle with a right-pointing arrow.
    public static let entryPoint = IBIcon([.oval(r(1, 1, 14, 14), fill: .paleBlue, stroke: nil, width: 0),
                                           line([p(4.5, 8), p(11, 8)], .blue, 1.5), line([p(8.5, 5.5), p(11, 8), p(8.5, 10.5)], .blue, 1.5)])
    /// Constraint rows: an I-beam.
    public static let constraint = IBIcon([line([p(8, 3), p(8, 13)], .blue, 1.25), line([p(5.5, 3), p(10.5, 3)], .blue, 1.25), line([p(5.5, 13), p(10.5, 13)], .blue, 1.25)])

    /// A scene: a yellow rounded square with a lighter top strip carrying
    /// three small marks, and a white glyph naming the controller kind.
    public static func scene(_ controllerElement: String?) -> IBIcon {
        var s: [Shape] = [tile(.yellow), .rect(r(1, 1, 14, 4), radius: 2, fill: .yellowLight, stroke: nil, width: 0, dashed: false),
                          dot(4, 3, 1.3, .yellow), dot(6.5, 3, 1.3, .yellow), dot(9, 3, 1.3, .yellow)]
        let w = Paint.white
        switch controllerElement ?? "" {
        case "navigationController": s.append(line([p(9.5, 7), p(6.5, 10), p(9.5, 13)], w, 1.5))
        case "tableViewController": s += [7.5, 10, 12.5].map { line([p(4, $0), p(12, $0)], w, 1.25) }
        case "collectionViewController": s += [4.5, 7.5, 10.5].map { box($0, 7, 2, 6, w) }
        case "splitViewController": s += [frame(3.5, 6.5, 3.5, 7, w), frame(8, 6.5, 4.5, 7, w)]
        case "pageViewController": s.append(.lines([p(5, 6.5), p(9.5, 6.5), p(11.5, 8.5), p(11.5, 13.5), p(5, 13.5)], stroke: w, width: 1, closed: true))
        case "glkViewController": s += [.oval(r(4.5, 6.5, 7, 7), fill: nil, stroke: w, width: 1), line([p(8, 6.5), p(8, 13.5)], w, 1), line([p(4.5, 10), p(11.5, 10)], w, 1)]
        case "avPlayerViewController": s.append(.polygon([p(6, 6.5), p(11.5, 10), p(6, 13.5)], fill: w))
        default: s.append(frame(4, 6.5, 8, 7, w, width: 1.25))
        }
        return IBIcon(s)
    }

    /// The icon for a Library kind.
    public static func of(_ kind: IBDocument.NewObject) -> IBIcon {
        switch kind {
        case .label: return of(element: "label")
        case .button, .pullDownButton, .popUpButton: return button(.dark, .blue)
        case .grayButton: return button(.lightGray, .blue)
        case .tintedButton: return button(.tint, .blue)
        case .filledButton: return button(.blue, .white)
        case .horizontalStackView: return stack(vertical: false)
        case .verticalStackView: return stack(vertical: true)
        case .fixedSpace: return space(flexible: false)
        case .flexibleSpace: return space(flexible: true)
        case .subMenu, .mainMenu, .inlineMenu: return of(element: "menu")
        case .blurView, .vibrancyView: return of(element: "visualEffectView")
        case .externalObject: return object
        case .viewController, .storyboardReference, .navigationController, .tableViewController, .collectionViewController, .tabBarController,
             .splitViewController, .pageViewController, .hostingController, .glkViewController, .playerViewController, .lookAroundViewController:
            return scene(kind.element == "viewControllerPlaceholder" ? nil : kind.element)
        default: return of(element: kind.element)
        }
    }

    static func button(_ fill: Paint, _ letterColor: Paint) -> IBIcon { IBIcon([tile(fill), letter("B", letterColor)]) }
    static func stack(vertical: Bool) -> IBIcon {
        IBIcon([tile(.paleBlue, border: .border), vertical ? line([p(3, 8), p(13, 8)], .border, 1.25) : line([p(8, 3), p(8, 13)], .border, 1.25)])
    }
    static func space(flexible: Bool) -> IBIcon {
        var s: [Shape] = [line([p(2.5, 5), p(2.5, 11)], .blue, 1.25), line([p(13.5, 5), p(13.5, 11)], .blue, 1.25)]
        if flexible {
            s += [line([p(4, 8), p(12, 8)], .blue, 1), line([p(6, 6.5), p(4, 8), p(6, 9.5)], .blue, 1), line([p(10, 6.5), p(12, 8), p(10, 9.5)], .blue, 1)]
        } else {
            s.append(.rect(r(4.5, 6.5, 7, 3), radius: 0.5, fill: .tint, stroke: .blue, width: 0.75, dashed: false))
        }
        return IBIcon(s)
    }

    /// The icon for an element (the outline's objects).
    public static func of(element e: String, key: String? = nil, object o: IBDocument.Object? = nil) -> IBIcon {
        let w = Paint.white, b = Paint.blue
        switch e {
        case "label": return IBIcon([tile(.black), letter("L", w)])
        case "textField": return IBIcon([tile(.black), frame(3, 4.5, 10, 7, w, width: 1, radius: 1.5), .text("T", center: p(8, 8), size: 7, bold: true, color: w)])
        case "textView": return IBIcon([tile(.paleBlue, border: .border)] + [4.5, 7, 9.5, 12].map { line([p(4, $0), p(12, $0)], .border, 1) })
        case "button":
            switch o?.node.child("buttonConfiguration")?["style"] {
            case "gray": return button(.lightGray, b)
            case "tinted": return button(.tint, b)
            case "filled": return button(b, w)
            default: return button(.dark, b)
            }
        case "segmentedControl":
            return IBIcon([tile(.black), frame(2.5, 5, 11, 6, w, width: 0.9, radius: 1.5), line([p(8, 5), p(8, 11)], w, 0.9),
                           .text("1", center: p(5.25, 8), size: 4.5, bold: true, color: w), .text("2", center: p(10.75, 8), size: 4.5, bold: true, color: w)])
        case "slider": return IBIcon([line([p(2, 8), p(14, 8)], b, 2), .oval(r(7, 4.5, 7, 7), fill: w, stroke: .gray, width: 0.75)])
        case "switch": return IBIcon([.rect(r(1, 4, 14, 8), radius: 4, fill: .green, stroke: nil, width: 0, dashed: false), dot(11, 8, 6.4, w)])
        case "activityIndicatorView":
            return IBIcon((0..<8).map { i -> Shape in
                let a = CGFloat(i) * .pi / 4
                return line([p(8 + 3 * cos(a), 8 + 3 * sin(a)), p(8 + 6 * cos(a), 8 + 6 * sin(a))], Paint(0.45, 0.46, 0.5, 0.35 + Double(i) * 0.08), 1.5)
            })
        case "progressView": return IBIcon([box(1.5, 7, 13, 2.5, .lightGray, radius: 1.25), box(1.5, 7, 8, 2.5, b, radius: 1.25)])
        case "pageControl": return IBIcon([tile(.paleBlue, border: .border)] + [4.5, 8, 11.5].enumerated().map { dot($0.element, 8, 2.2, $0.offset == 0 ? .dark : .gray) })
        case "stepper":
            return IBIcon([frame(1, 4.5, 6.5, 7, .gray, width: 0.9, radius: 1.5), frame(8.5, 4.5, 6.5, 7, .gray, width: 0.9, radius: 1.5),
                           line([p(2.75, 8), p(5.75, 8)], .dark, 1.25), line([p(10.25, 8), p(13.25, 8)], .dark, 1.25), line([p(11.75, 6.5), p(11.75, 9.5)], .dark, 1.25)])
        case "colorWell":
            let colors: [Paint] = [.red, .orange, .yellow, .green, .teal, b, .violet, Paint(0.9, 0.3, 0.6)]
            return IBIcon(colors.enumerated().map { .arc(center: p(8, 8), radius: 5, from: CGFloat($0.offset) * 45, to: CGFloat($0.offset + 1) * 45, stroke: $0.element, width: 2.5) })
        case "pasteControl": return IBIcon([tile(.dark), frame(4.5, 4, 7, 9, w, width: 1, radius: 1), box(6, 3, 4, 2, w, radius: 0.5)])
        case "stackView": return stack(vertical: o?.attribute("axis") == "vertical")
        case "tableView": return IBIcon([tile(.paleBlue, border: .border)] + [5, 8, 11].map { line([p(3, $0), p(13, $0)], .border, 1) })
        case "tableViewCell": return IBIcon([tile(.white, border: .border), line([p(3.5, 8), p(10, 8)], .border, 1.25), line([p(11, 6.5), p(12.5, 8), p(11, 9.5)], .border, 1)])
        case "imageView":
            return IBIcon([tile(.paleBlue, border: .border), .polygon([p(3, 12), p(6.5, 7.5), p(9, 10), p(10.5, 8.5), p(13, 12)], fill: b), dot(10.5, 5, 2.4, .orange)])
        case "collectionView": return IBIcon([tile(.paleBlue, border: .border)] + [(3.5, 3.5), (8.5, 3.5), (3.5, 8.5), (8.5, 8.5)].map { box($0.0, $0.1, 4, 4, .border) })
        case "collectionViewCell": return IBIcon([tile(.white, border: .border), box(5, 5, 6, 6, .border)])
        case "collectionReusableView": return IBIcon([tile(.white, border: .border), box(3, 3, 10, 3, .border)])
        case "collectionViewFlowLayout": return IBIcon([3.5, 8.5].flatMap { x in [3.5, 8.5].map { frame(x, $0, 4, 4, .gray, width: 1) } })
        case "scrollView": return IBIcon([tile(.paleBlue, border: .border), box(11.5, 3.5, 1.5, 5, .dark, radius: 0.75)])
        case "visualEffectView": return IBIcon([tile(.frosted, border: .border), .oval(r(3, 3, 6, 6), fill: Paint(1, 1, 1, 0.55), stroke: nil, width: 0)])
        case "datePicker", "pickerView":
            return IBIcon([tile(.black)] + [(4.5, 0.45), (6.5, 0.7), (8, 1), (9.5, 0.7), (11.5, 0.45)].map { line([p(4, $0.0), p(12, $0.0)], Paint(1, 1, 1, $0.1), 0.9) })
        case "mapView":
            return IBIcon([tile(b), .lines([p(3, 4.5), p(6.5, 3.5), p(9.5, 4.5), p(13, 3.5), p(13, 11.5), p(9.5, 12.5), p(6.5, 11.5), p(3, 12.5)], stroke: w, width: 1, closed: true),
                           line([p(5, 10), p(7.5, 7), p(9.5, 9), p(11.5, 6)], w, 1.25)])
        case "mtkView": return IBIcon([tile(.teal), .lines([p(8, 4), p(12.5, 12), p(3.5, 12)], stroke: w, width: 1.25, closed: true)])
        case "glkView": return IBIcon([tile(b), .oval(r(3.5, 3.5, 9, 9), fill: nil, stroke: w, width: 1.25), line([p(8, 3.5), p(8, 12.5)], w, 1.25), line([p(3.5, 8), p(12.5, 8)], w, 1.25)])
        case "sceneKitView": return IBIcon([tile(.red)] + cube(w))
        case "skView": return IBIcon([tile(.violet), .polygon([p(8, 3.5), p(9.5, 6.5), p(12.5, 8), p(9.5, 9.5), p(8, 12.5), p(6.5, 9.5), p(3.5, 8), p(6.5, 6.5)], fill: w)])
        case "arscnView": return IBIcon([tile(.red)] + cube(w, 0.9).map(Self.shrink) + arMark(w))
        case "arskView": return IBIcon([tile(.violet), .polygon([p(8, 5), p(9, 7), p(11, 8), p(9, 9), p(8, 11), p(7, 9), p(5, 8), p(7, 7)], fill: w)] + arMark(w))
        case "webView", "wkWebView":
            return IBIcon([tile(b), .oval(r(3, 3, 10, 10), fill: nil, stroke: w, width: 1), .polygon([p(10.5, 5.5), p(8.8, 8.8), p(5.5, 10.5), p(7.2, 7.2)], fill: w)])
        case "arView": return IBIcon([tile(.indigo)] + cube(w, 0.9).map(Self.shrink) + arMark(w))
        case "roomCaptureView":
            return IBIcon([tile(.dark), .lines([p(4, 5), p(8, 3.5), p(12, 5), p(12, 11), p(8, 12.5), p(4, 11)], stroke: w, width: 1, closed: true), line([p(8, 3.5), p(8, 12.5)], w, 1)])
        case "clLocationButton": return IBIcon([tile(b), .polygon([p(12, 4), p(8.5, 12), p(7.5, 8.5), p(4, 7.5)], fill: w)])
        case "navigationBar": return bar([line([p(5.5, 6), p(3.5, 8), p(5.5, 10)], b, 1.5), box(8, 7.25, 4, 1.5, .gray)])
        case "toolbar": return bar([3.5, 6.5, 9.5, 12.5].map { dot($0, 8, 1.8, b) })
        case "tabBar": return bar([3, 7, 11].map { box($0, 6, 2.5, 2.5, b) } + [3, 7, 11].map { box($0, 9.5, 2.5, 0.8, b) })
        case "searchBar": return IBIcon([.oval(r(2.5, 2.5, 8, 8), fill: nil, stroke: .dark, width: 1.5), line([p(9.5, 9.5), p(13.5, 13.5)], .dark, 2)])
        case "navigationItem": return IBIcon([tile(.white, border: .border), line([p(5, 5.5), p(3.5, 7), p(5, 8.5)], b, 1.1), box(6.5, 6.25, 5.5, 1.5, .dark)])
        case "barButtonItem":
            if let s = o?.attribute("systemItem"), s == "fixedSpace" || s == "flexibleSpace" { return space(flexible: s == "flexibleSpace") }
            return IBIcon([.rect(r(1.5, 4.5, 13, 7), radius: 3.5, fill: .tint, stroke: b, width: 0.9, dashed: false), box(5, 7.25, 6, 1.5, b)])
        case "barButtonItemGroup":
            return IBIcon([.rect(r(1, 5, 6.5, 6), radius: 3, fill: .tint, stroke: b, width: 0.9, dashed: false),
                           .rect(r(8.5, 5, 6.5, 6), radius: 3, fill: .tint, stroke: b, width: 0.9, dashed: false)])
        case "tabBarItem": return IBIcon([frame(3.5, 2.5, 9, 8, b, width: 1.1, radius: 2), box(5, 12, 6, 1.5, b)])
        case "menu": return IBIcon([tile(.white, border: .border)] + [5, 8, 11].map { line([p(4, $0), p(12, $0)], .dark, 1) })
        case "command": return IBIcon([dot(4, 8, 2.2, b), line([p(6.5, 8), p(13, 8)], .dark, 1.25)])
        case "tapGestureRecognizer": return gesture([dot(8, 8, 4, b), .oval(r(2.5, 2.5, 11, 11), fill: nil, stroke: b, width: 1)])
        case "pinchGestureRecognizer": return gesture([dot(4.5, 11.5, 4, b), dot(11.5, 4.5, 4, b), line([p(6.5, 9.5), p(9.5, 6.5)], b, 0.9)])
        case "rotationGestureRecognizer":
            return gesture([.arc(center: p(8, 8), radius: 5, from: 200, to: 320, stroke: b, width: 1.5), .arc(center: p(8, 8), radius: 5, from: 20, to: 140, stroke: b, width: 1.5),
                            .polygon([p(12.2, 3.5), p(13.6, 6.6), p(10.4, 6.2)], fill: b), .polygon([p(3.8, 12.5), p(2.4, 9.4), p(5.6, 9.8)], fill: b)])
        case "swipeGestureRecognizer": return gesture([dot(11, 8, 4, b), line([p(2, 6), p(7, 6)], b, 1), line([p(2, 8), p(8, 8)], b, 1), line([p(2, 10), p(7, 10)], b, 1)])
        case "panGestureRecognizer": return gesture([dot(11, 5, 4, b), line([p(3, 13), p(5.5, 9.5), p(8, 8), p(9.5, 6.5)], Paint(0.04, 0.48, 1, 0.55), 1.5)])
        case "screenEdgePanGestureRecognizer": return gesture([line([p(2, 2), p(2, 14)], b, 1.5), dot(9, 8, 4, b), line([p(3.5, 8), p(6.5, 8)], Paint(0.04, 0.48, 1, 0.55), 1.25)])
        case "pongPressGestureRecognizer": return gesture([dot(8, 8, 4, b), .oval(r(3, 3, 10, 10), fill: nil, stroke: b, width: 2.25)])
        case "gestureRecognizer": return gesture([dot(8, 8, 4, b), .oval(r(2.5, 2.5, 11, 11), fill: nil, stroke: b, width: 1)].map {
            if case .oval(let rr, nil, let s?, let wd) = $0 { return .rect(rr, radius: 5.5, fill: nil, stroke: s, width: wd, dashed: true) }
            return $0
        })
        case "viewLayoutGuide": return layoutGuide
        case "customObject", "placeholder": return object
        case "exit": return exit
        default:
            if let o, o.isView { return view }
            return object
        }
    }

    static func shrink(_ s: Shape) -> Shape {
        func m(_ q: CGPoint) -> CGPoint { p(8 + (q.x - 8) * 0.7, 8 + (q.y - 8) * 0.7) }
        if case .lines(let pts, let c, let w, let closed) = s { return .lines(pts.map(m), stroke: c, width: w, closed: closed) }
        return s
    }

    /// The outline icon for an object.
    public static func of(object o: IBDocument.Object, in d: IBDocument) -> IBIcon {
        if o.element == "scene" { return scene(o.children.first { d.isController($0) }?.element) }
        if o.element == "placeholder", o.attribute("placeholderIdentifier") == "IBFirstResponder" || o.attribute("sceneMemberID") == "firstResponder" { return firstResponder }
        if o.element == "exit" || o.attribute("sceneMemberID") == "exit" { return exit }
        if d.isController(o) { return controller }
        return of(element: o.element, key: o.key, object: o)
    }

    /// The outline icon for a row.
    public static func of(row: IBOutlineRow, in d: IBDocument) -> IBIcon {
        switch row.kind {
        case .constraints, .constraint: return constraint
        case .entryPoint: return entryPoint
        default: return row.objectID.flatMap { d.byID[$0] }.map { of(object: $0, in: d) } ?? object
        }
    }
}

extension IBDocument.NewObject {
    /// The kind's Library icon.
    public var icon: IBIcon { IBIcon.of(self) }
}

extension IBIcon {
    /// The glyph of one choice in an icon row (`interface-builder.md`
    /// "icons (…)"): text alignment, content alignment and border style,
    /// drawn by Ycode in the label colour (`ink`).
    public static func choiceGlyph(attribute: String, value: String, ink: Paint = .dark) -> IBIcon? {
        let c = ink
        func bars(_ xs: [(CGFloat, CGFloat)]) -> [Shape] { xs.enumerated().map { line([p($0.element.0, 4 + CGFloat($0.offset) * 2.7), p($0.element.1, 4 + CGFloat($0.offset) * 2.7)], c, 1.1) } }
        switch attribute {
        case "textAlignment":
            switch value {
            case "left": return IBIcon(bars([(3, 13), (3, 10), (3, 13), (3, 8)]))
            case "center": return IBIcon(bars([(3, 13), (4.5, 11.5), (3, 13), (5.5, 10.5)]))
            case "right": return IBIcon(bars([(3, 13), (6, 13), (3, 13), (8, 13)]))
            case "justified": return IBIcon(bars([(3, 13), (3, 13), (3, 13), (3, 13)]))
            case "natural": return IBIcon(bars([(3, 13), (3, 10), (3, 13)]) + [line([p(3, 12.5), p(7, 12.5)], c, 1.1), line([p(5.5, 11), p(7, 12.5), p(5.5, 14)], c, 0.9)])
            default: return nil
            }
        case "contentHorizontalAlignment":
            let box = { (x: CGFloat, w: CGFloat) in Shape.rect(r(x, 5, w, 6), radius: 1, fill: c, stroke: nil, width: 0, dashed: false) }
            switch value {
            case "leading": return IBIcon([line([p(2, 2), p(2, 14)], c, 1), box(3.5, 7), line([p(4, 13), p(9, 13)], c, 0.8)])
            case "left": return IBIcon([line([p(2, 2), p(2, 14)], c, 1), box(3.5, 7)])
            case "center": return IBIcon([line([p(8, 2), p(8, 4)], c, 1), line([p(8, 12), p(8, 14)], c, 1), box(4.5, 7)])
            case "trailing": return IBIcon([line([p(14, 2), p(14, 14)], c, 1), box(5.5, 7), line([p(7, 13), p(12, 13)], c, 0.8)])
            case "right": return IBIcon([line([p(14, 2), p(14, 14)], c, 1), box(5.5, 7)])
            case "fill": return IBIcon([line([p(2, 2), p(2, 14)], c, 1), line([p(14, 2), p(14, 14)], c, 1), box(3.5, 9)])
            default: return nil
            }
        case "contentVerticalAlignment":
            let box = { (y: CGFloat, h: CGFloat) in Shape.rect(r(5, y, 6, h), radius: 1, fill: c, stroke: nil, width: 0, dashed: false) }
            switch value {
            case "top": return IBIcon([line([p(2, 2), p(14, 2)], c, 1), box(3.5, 7)])
            case "center": return IBIcon([line([p(2, 8), p(4, 8)], c, 1), line([p(12, 8), p(14, 8)], c, 1), box(4.5, 7)])
            case "bottom": return IBIcon([line([p(2, 14), p(14, 14)], c, 1), box(5.5, 7)])
            case "fill": return IBIcon([line([p(2, 2), p(14, 2)], c, 1), line([p(2, 14), p(14, 14)], c, 1), box(3.5, 9)])
            default: return nil
            }
        case "borderStyle":
            switch value {
            case "none": return IBIcon([.rect(r(2, 4.5, 12, 7), radius: 0, fill: nil, stroke: c, width: 0.8, dashed: true)])
            case "line": return IBIcon([frame(2, 4.5, 12, 7, c, width: 0.9, radius: 0)])
            case "bezel": return IBIcon([frame(2, 4.5, 12, 7, c, width: 0.8, radius: 0), line([p(2, 11.5), p(2, 4.5), p(14, 4.5)], c, 1.8)])
            case "roundedRect": return IBIcon([frame(2, 4.5, 12, 7, c, width: 0.9, radius: 3)])
            default: return nil
            }
        default: return nil
        }
    }
}
