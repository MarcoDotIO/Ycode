// SUIProbe layout mode: golden layout values. Each case is shown alone inside
// a `Measure` container, which asks its child for sizes at a fixed set of
// proposals, records alignment-guide values, places the child at the case's
// placement proposal, and lets probed descendants record their frames in the
// container's coordinate space.
import SwiftUI
import UIKit

func ps(_ p: ProposedViewSize) -> String {
    func one(_ v: CGFloat?) -> String {
        guard let v else { return "nil" }
        return v == .infinity ? "inf" : f2(v)
    }
    return "\(one(p.width))x\(one(p.height))"
}

let standardProposals: [ProposedViewSize] = [
    .unspecified, .zero, .infinity,
    ProposedViewSize(width: 100, height: nil), ProposedViewSize(width: nil, height: 100),
    ProposedViewSize(width: 100, height: 100), ProposedViewSize(width: 300, height: 500),
]

struct CaseNameKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var caseName: String {
        get { self[CaseNameKey.self] }
        set { self[CaseNameKey.self] = newValue }
    }
}

struct ProbeFrame: ViewModifier {
    let id: String
    @Environment(\.caseName) var caseName
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            let r = g.frame(in: .named("m"))
            let k = "layout.\(caseName).frame.\(id)"
            Color.clear
                .onAppear { Rec.set(k, rc(r)) }
                .onChange(of: r) { _, n in Rec.set(k, rc(n)) }
        })
    }
}
extension View {
    func probe(_ id: String) -> some View { modifier(ProbeFrame(id: id)) }
}

struct Measure: Layout {
    let name: String
    let proposals: [ProposedViewSize]
    let place: ProposedViewSize
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        return s.sizeThatFits(place)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let s = subviews.first else { return }
        let p = "layout.\(name)."
        for q in proposals { Rec.set(p + "fit[\(ps(q))]", sz(s.sizeThatFits(q))) }
        let d = s.dimensions(in: place)
        Rec.set(p + "dims[\(ps(place))]",
                "\(f2(d.width))x\(f2(d.height)) firstBaseline=\(f2(d[VerticalAlignment.firstTextBaseline])) lastBaseline=\(f2(d[VerticalAlignment.lastTextBaseline])) centerY=\(f2(d[VerticalAlignment.center])) leading=\(f2(d[HorizontalAlignment.leading])) trailing=\(f2(d[HorizontalAlignment.trailing]))")
        Rec.set(p + "priority", f2(s.priority))
        s.place(at: bounds.origin, anchor: .topLeading, proposal: place)
    }
}

/// Lays children out in a column (for display only) and records the default
/// spacing every pair of children prefers, along both axes.
struct SpacingProbe: Layout {
    let name: String
    let labels: [String]
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: 300, height: CGFloat(subviews.count) * 50)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for i in subviews.indices {
            for j in subviews.indices {
                let h = subviews[i].spacing.distance(to: subviews[j].spacing, along: .horizontal)
                let v = subviews[i].spacing.distance(to: subviews[j].spacing, along: .vertical)
                Rec.set("layout.\(name).spacing.\(labels[i])->\(labels[j])", "h=\(f2(h)) v=\(f2(v))")
            }
            subviews[i].place(at: CGPoint(x: bounds.minX, y: bounds.minY + CGFloat(i) * 50), proposal: .unspecified)
        }
    }
}

struct LCase {
    let name: String
    var proposals: [ProposedViewSize] = standardProposals
    var place: ProposedViewSize = ProposedViewSize(width: 300, height: 500)
    let view: AnyView
}

let longText = "The quick brown fox jumps over the lazy dog"

@MainActor func layoutCases() -> [LCase] {
    var c: [LCase] = []
    func add(_ n: String, place: ProposedViewSize = ProposedViewSize(width: 300, height: 500),
             proposals: [ProposedViewSize] = standardProposals, @ViewBuilder _ v: () -> some View) {
        c.append(LCase(name: n, proposals: proposals, place: place, view: AnyView(v())))
    }
    let w300 = ProposedViewSize(width: 300, height: 500)
    // Text
    add("text.hello") { Text("Hello") }
    add("text.long") { Text(longText) }
    add("text.long.w100", place: ProposedViewSize(width: 100, height: 500)) { Text(longText) }
    add("text.long.lineLimit1", place: ProposedViewSize(width: 100, height: 500)) { Text(longText).lineLimit(1) }
    add("text.long.lineLimit2", place: ProposedViewSize(width: 100, height: 500)) { Text(longText).lineLimit(2) }
    add("text.empty") { Text("") }
    add("text.system17") { Text("Hello").font(.system(size: 17)) }
    add("text.bold") { Text("Hello").bold() }
    add("text.twoLines") { Text("Hello\nWorld") }
    let styles: [(String, Font)] = [("largeTitle", .largeTitle), ("title", .title), ("title2", .title2), ("title3", .title3),
        ("headline", .headline), ("subheadline", .subheadline), ("body", .body), ("callout", .callout),
        ("footnote", .footnote), ("caption", .caption), ("caption2", .caption2)]
    for (n, f) in styles {
        add("font.\(n)", proposals: [.unspecified]) { Text("Ag").font(f) }
    }
    let dyn: [(String, DynamicTypeSize)] = [("xSmall", .xSmall), ("small", .small), ("medium", .medium), ("large", .large),
        ("xLarge", .xLarge), ("xxLarge", .xxLarge), ("xxxLarge", .xxxLarge), ("ax1", .accessibility1),
        ("ax2", .accessibility2), ("ax3", .accessibility3), ("ax4", .accessibility4), ("ax5", .accessibility5)]
    for (dn, d) in dyn {
        add("dyn.\(dn)", proposals: [.unspecified]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(styles.indices, id: \.self) { i in
                    Text("Ag").font(styles[i].1).probe(styles[i].0)
                }
            }.environment(\.dynamicTypeSize, d)
        }
    }
    // Primitive views
    add("color") { Color.red }
    add("rectangle") { Rectangle() }
    add("circle", place: ProposedViewSize(width: 300, height: 100)) { Circle() }
    add("capsule", place: ProposedViewSize(width: 300, height: 100)) { Capsule() }
    add("rect.frame") { Rectangle().frame(width: 50, height: 30) }
    add("spacer") { Spacer() }
    add("spacer.min20") { Spacer(minLength: 20) }
    add("divider") { Divider() }
    add("hstack.divider") { HStack { Text("A"); Divider(); Text("B") } }
    add("image.symbol") { Image(systemName: "star.fill") }
    add("image.symbol.largeTitle") { Image(systemName: "star.fill").font(.largeTitle) }
    add("image.symbol.scaleSmall") { Image(systemName: "star.fill").imageScale(.small) }
    add("image.symbol.scaleLarge") { Image(systemName: "star.fill").imageScale(.large) }
    add("image.symbol.wide") { Image(systemName: "rectangle.portrait.and.arrow.right") }
    add("image.symbol.resizable") { Image(systemName: "star.fill").resizable() }
    add("image.symbol.resizableFit") { Image(systemName: "star.fill").resizable().scaledToFit() }
    add("label") { Label("Title", systemImage: "star") }
    // Stacks
    add("hstack.texts") { HStack { Text("A").probe("a"); Text("B").probe("b") } }
    add("hstack.colors") { HStack { Color.red.frame(width: 10, height: 10).probe("a"); Color.blue.frame(width: 10, height: 10).probe("b") } }
    add("hstack.textImage") { HStack { Text("A").probe("a"); Image(systemName: "star").probe("b") } }
    add("vstack.texts") { VStack { Text("A").probe("a"); Text("B").probe("b") } }
    add("vstack.colors") { VStack { Color.red.frame(width: 10, height: 10).probe("a"); Color.blue.frame(width: 10, height: 10).probe("b") } }
    add("hstack.spacer") { HStack { Text("Left").probe("l"); Spacer().probe("s"); Text("Right").probe("r") } }
    add("hstack.flex") { HStack { Color.red.probe("a"); Color.blue.frame(maxWidth: 50).probe("b"); Text("Hello").probe("c") } }
    add("hstack.twoColors") { HStack { Color.red.probe("a"); Color.blue.probe("b") } }
    add("hstack.threeColors.spacing0") { HStack(spacing: 0) { Color.red.probe("a"); Color.blue.frame(minWidth: 150).probe("b"); Color.green.probe("c") } }
    add("hstack.equalTexts") { HStack { Text(longText).probe("a"); Text("short words here").probe("b") } }
    add("hstack.priority") { HStack { Text(longText).probe("a"); Text(longText).layoutPriority(1).probe("b") } }
    add("hstack.baseline") { HStack(alignment: .firstTextBaseline) { Text("Big").font(.largeTitle).probe("a"); Text("small").font(.caption).probe("b") } }
    add("hstack.center") { HStack { Text("Big").font(.largeTitle).probe("a"); Text("small").font(.caption).probe("b") } }
    add("hstack.top") { HStack(alignment: .top) { Color.red.frame(width: 50, height: 80).probe("a"); Color.blue.frame(width: 30, height: 20).probe("b") } }
    add("vstack.leading") { VStack(alignment: .leading) { Text("Short").probe("a"); Text("Longer text").probe("b") } }
    add("vstack.center") { VStack { Text("Short").probe("a"); Text("Longer text").probe("b") } }
    add("vstack.spacer") { VStack { Text("Top").probe("a"); Spacer().probe("s"); Text("Bottom").probe("b") } }
    add("zstack") { ZStack { Color.red.frame(width: 100, height: 50).probe("a"); Text("Hi").probe("b") } }
    add("zstack.bottomTrailing") { ZStack(alignment: .bottomTrailing) { Color.red.frame(width: 100, height: 50).probe("a"); Text("Hi").probe("b") } }
    add("zstack.flex") { ZStack { Color.red.probe("a"); Text("Hi").probe("b") } }
    // Frames and modifiers
    add("frame.fixed") { Text("Hello").probe("t").frame(width: 100, height: 100) }
    add("frame.topLeading") { Text("Hello").probe("t").frame(width: 100, height: 100, alignment: .topLeading) }
    add("frame.widthOnly") { Text("Hello").probe("t").frame(width: 100) }
    add("frame.maxInf") { Text("Hello").probe("t").frame(maxWidth: .infinity) }
    add("frame.maxInfBoth") { Text("Hello").probe("t").frame(maxWidth: .infinity, maxHeight: .infinity) }
    add("frame.minmax") { Color.red.probe("c").frame(minWidth: 50, maxWidth: 150, minHeight: 20, maxHeight: 40) }
    add("frame.minOnText") { Text("Hello").probe("t").frame(minWidth: 200) }
    add("frame.ideal") { Color.red.frame(idealWidth: 120, idealHeight: 30) }
    add("frame.ideal.fixedSize") { Color.red.frame(idealWidth: 120, idealHeight: 30).fixedSize() }
    add("frame.tooSmall") { Text(longText).probe("t").frame(width: 50, height: 20) }
    add("fixedSize", place: ProposedViewSize(width: 100, height: 500)) { Text(longText).fixedSize() }
    add("fixedSize.vertical", place: ProposedViewSize(width: 100, height: 500)) { Text(longText).fixedSize(horizontal: false, vertical: true) }
    add("padding.default") { Text("Hello").probe("t").padding() }
    add("padding.10") { Text("Hello").probe("t").padding(10) }
    add("padding.horizontal") { Text("Hello").probe("t").padding(.horizontal) }
    add("padding.color") { Color.red.probe("c").padding() }
    add("padding.negative") { Text("Hello").probe("t").padding(-5) }
    add("aspect.fit") { Color.red.aspectRatio(2, contentMode: .fit) }
    add("aspect.fill") { Color.red.aspectRatio(2, contentMode: .fill) }
    add("aspect.fit.symbol") { Image(systemName: "star.fill").resizable().aspectRatio(contentMode: .fit) }
    add("offset") { Text("Hello").probe("t").offset(x: 20, y: 10) }
    add("position") { Text("Hello").probe("t").position(x: 50, y: 50) }
    add("overlay") { Text("Hello").overlay(Color.red.frame(width: 200).probe("o")) }
    add("background") { Text("Hello").background(Color.red.probe("b")) }
    add("background.padded") { Text("Hello").padding().background(Color.red.probe("b")) }
    add("background.ignoresSafeArea") { Text("Hello").background(Color.red.ignoresSafeArea().probe("b")) }
    add("geometryReader") { GeometryReader { _ in Text("Hi").probe("t") } }
    add("alignmentGuide") { VStack(alignment: .leading) { Text("One").probe("a"); Text("Two").alignmentGuide(.leading) { d in d.width / 2 }.probe("b") } }
    add("alignmentGuide.explicitLeading") { HStack { Text("One").alignmentGuide(VerticalAlignment.center) { _ in 0 }.probe("a"); Color.red.frame(width: 10, height: 40).probe("b") } }
    add("layoutPriority.vstack") { VStack { Color.red.probe("a"); Color.blue.layoutPriority(1).probe("b") } }
    add("clipped") { Color.red.frame(width: 400, height: 50).probe("c").frame(width: 100).clipped() }
    add("scaleEffect") { Text("Hello").probe("t").scaleEffect(2) }
    add("rotationEffect") { Text("Hello").probe("t").rotationEffect(.degrees(90)) }
    // Grids
    add("grid") {
        Grid {
            GridRow { Text("A").probe("a"); Text("Longer").probe("b") }
            GridRow { Text("Wide cell").probe("c"); Color.red.frame(width: 10, height: 10).probe("d") }
        }
    }
    add("grid.spacing0") {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow { Text("A").probe("a"); Text("Longer").probe("b") }
            GridRow { Text("Wide cell").probe("c"); Color.red.frame(width: 10, height: 10).probe("d") }
        }
    }
    add("grid.flex") {
        Grid {
            GridRow { Color.red.probe("a"); Text("Fixed").probe("b") }
            GridRow { Text("X").gridCellColumns(2).probe("c") }
        }
    }
    add("lazyvgrid.flexible2") {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
            ForEach(0..<4, id: \.self) { i in Color.red.frame(height: 20).probe("c\(i)") }
        }
    }
    add("lazyvgrid.adaptive80") {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))]) {
            ForEach(0..<6, id: \.self) { i in Color.red.frame(height: 20).probe("c\(i)") }
        }
    }
    add("lazyvgrid.fixed") {
        LazyVGrid(columns: [GridItem(.fixed(50)), GridItem(.fixed(70))]) {
            ForEach(0..<4, id: \.self) { i in Color.red.frame(height: 20).probe("c\(i)") }
        }
    }
    add("viewThatFits") { ViewThatFits { Text(longText).fixedSize().probe("a"); Text("short").probe("b") } }
    add("viewThatFits.w400", place: ProposedViewSize(width: 400, height: 500)) { ViewThatFits { Text(longText).fixedSize().probe("a"); Text("short").probe("b") } }
    // Controls
    add("button.default") { Button("Tap") {} }
    add("button.bordered") { Button("Tap") {}.buttonStyle(.bordered) }
    add("button.borderedProminent") { Button("Tap") {}.buttonStyle(.borderedProminent) }
    add("button.glass") { Button("Tap") {}.buttonStyle(.glass) }
    add("button.borderless") { Button("Tap") {}.buttonStyle(.borderless) }
    add("button.plain") { Button("Tap") {}.buttonStyle(.plain) }
    add("button.large") { Button("Tap") {}.buttonStyle(.borderedProminent).controlSize(.large) }
    add("toggle") { Toggle("On", isOn: .constant(true)) }
    add("toggle.labelsHidden") { Toggle("On", isOn: .constant(true)).labelsHidden() }
    add("slider") { Slider(value: .constant(0.5)) }
    add("stepper") { Stepper("S", value: .constant(1)) }
    add("progress.spinner") { ProgressView() }
    add("progress.linear") { ProgressView(value: 0.5) }
    add("picker.segmented") { Picker("P", selection: .constant(0)) { Text("A").tag(0); Text("Bee").tag(1) }.pickerStyle(.segmented) }
    add("textfield.plain") { TextField("Placeholder", text: .constant("")) }
    add("textfield.rounded") { TextField("Placeholder", text: .constant("")).textFieldStyle(.roundedBorder) }
    add("secureField") { SecureField("Password", text: .constant("")) }
    add("datePicker.compact") { DatePicker("D", selection: .constant(Date(timeIntervalSince1970: 0)), displayedComponents: .date) }
    add("gauge") { Gauge(value: 0.5) { Text("G") } }
    add("link") { Link("Ycode", destination: URL(string: "https://example.com")!) }
    // Containers
    add("scrollView") { ScrollView { VStack { Text("A").probe("a"); Color.red.frame(height: 1000).probe("c") } } }
    add("scrollView.horizontal") { ScrollView(.horizontal) { HStack { Text("A").probe("a"); Color.red.frame(width: 1000).probe("c") } } }
    add("list.two", proposals: [.unspecified, w300]) { List { Text("A").probe("a"); Text("B").probe("b") } }
    add("list.plain", proposals: [w300]) { List { Text("A").probe("a"); Text("B").probe("b") }.listStyle(.plain) }
    add("form.toggle", proposals: [w300]) { Form { Toggle("On", isOn: .constant(true)).probe("t") } }
    add("navigationStack", proposals: [w300]) { NavigationStack { Text("Hi").probe("t").navigationTitle("T") } }
    add("navigationStack.inline", proposals: [w300]) { NavigationStack { Text("Hi").probe("t").navigationTitle("T").navigationBarTitleDisplayMode(.inline) } }
    add("tabView", proposals: [w300]) { TabView { Text("Hi").probe("t").tabItem { Label("A", systemImage: "star") } } }
    // Spacing preferences between kinds of views
    c.append(LCase(name: "spacingMatrix", proposals: [], place: .unspecified, view: AnyView(
        SpacingProbe(name: "spacingMatrix", labels: ["text", "textCaption", "image", "color", "button", "toggle", "textField", "padded"]) {
            Text("A"); Text("A").font(.caption); Image(systemName: "star"); Color.red.frame(width: 10, height: 10)
            Button("B") {}; Toggle("T", isOn: .constant(true)).labelsHidden(); TextField("F", text: .constant("")).frame(width: 50)
            Text("P").padding()
        })))
    return c
}

struct LayoutProbe: View {
    @State var index = 0
    @State var cases: [LCase] = []
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                if index < cases.count {
                    let cs = cases[index]
                    Measure(name: cs.name, proposals: cs.proposals, place: cs.place) { cs.view }
                        .coordinateSpace(.named("m"))
                        .environment(\.caseName, cs.name)
                        .id(cs.name)
                }
                Color.clear
            }
            .onAppear {
                log("layout.root.size", sz(g.size))
                log("layout.root.safeArea", ins(g.safeAreaInsets))
                logWindowFacts("layout")
                logFonts()
                cases = layoutCases()
                step()
            }
        }
    }
    func step() {
        after(0.25) {
            if index < cases.count { Rec.flush(prefix: "layout.\(cases[index].name).") }
            index += 1
            if index < cases.count { step() } else { log("layout.cases", cases.count); finish() }
        }
    }
}

/// UIKit's preferred fonts per text style and content size category.
func logFonts() {
    let styles: [(String, UIFont.TextStyle)] = [("largeTitle", .largeTitle), ("title1", .title1), ("title2", .title2),
        ("title3", .title3), ("headline", .headline), ("subheadline", .subheadline), ("body", .body),
        ("callout", .callout), ("footnote", .footnote), ("caption1", .caption1), ("caption2", .caption2),
        ("extraLargeTitle", .extraLargeTitle), ("extraLargeTitle2", .extraLargeTitle2)]
    let cats: [UIContentSizeCategory] = [.extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge,
        .extraExtraExtraLarge, .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
        .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge]
    for (n, s) in styles {
        var row: [String] = []
        for c in cats {
            let f = UIFont.preferredFont(forTextStyle: s, compatibleWith: UITraitCollection(preferredContentSizeCategory: c))
            row.append(f2(f.pointSize))
        }
        let f = UIFont.preferredFont(forTextStyle: s, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        log("font.ui.\(n)", "sizes=\(row.joined(separator: ",")) large: name=\(f.fontName) family=\(f.familyName) asc=\(f2(f.ascender)) desc=\(f2(f.descender)) leading=\(f2(f.leading)) lineHeight=\(f2(f.lineHeight)) capHeight=\(f2(f.capHeight)) xHeight=\(f2(f.xHeight))")
    }
    let sys = UIFont.systemFont(ofSize: 17)
    log("font.ui.system17", "name=\(sys.fontName) family=\(sys.familyName) lineHeight=\(f2(sys.lineHeight))")
    log("font.families.count", UIFont.familyNames.count)
    log("font.families", UIFont.familyNames.sorted().joined(separator: "|"))
}
