// SUIProbe modes: persistence, environment and colours, accessibility,
// localization, images and symbols, gestures, and miscellaneous services.
import SwiftUI
import UIKit

// MARK: persistence

struct PersistProbe: View {
    @AppStorage("launchCount") var launches = 0
    @AppStorage("name") var name = "default"
    @SceneStorage("scenePick") var pick = 0
    @SceneStorage("sceneText") var stext = ""
    var body: some View {
        VStack {
            Text("launch \(launches) pick \(pick) '\(stext)' name \(name)")
        }
        .onChange(of: name) { o, n in logt("persist.appStorage.name", "\(o)->\(n)") }
        .onAppear {
            logt("persist.read", "launches=\(launches) scenePick=\(pick) sceneText='\(stext)' name=\(name)")
            log("persist.home", NSHomeDirectory().components(separatedBy: "/data/").last ?? "?")
            launches += 1
            pick = launches * 10
            stext = "written at launch \(launches)"
            logt("persist.wrote", "launches=\(launches) scenePick=\(pick)")
            log("persist.userDefaults.launchCount", UserDefaults.standard.integer(forKey: "launchCount"))
            after(1.0) {
                logt("persist.externalWrite", "UserDefaults name=external\(launches)")
                UserDefaults.standard.set("external\(launches)", forKey: "name")
            }
            after(2.0) { logt("persist.after", "name=\(name)"); finish() }
        }
    }
}

// MARK: environment, colours, live setting changes

func colorRow(_ c: Color, _ e: EnvironmentValues) -> String {
    let r = c.resolve(in: e)
    return "\(r.description) srgb=\(f4(Double(r.red))),\(f4(Double(r.green))),\(f4(Double(r.blue))),\(f4(Double(r.opacity))) linear=\(f4(Double(r.linearRed))),\(f4(Double(r.linearGreen))),\(f4(Double(r.linearBlue)))"
}

let probeColors: [(String, Color)] = [("primary", .primary), ("secondary", .secondary), ("accentColor", .accentColor),
    ("red", .red), ("orange", .orange), ("yellow", .yellow), ("green", .green), ("mint", .mint), ("teal", .teal),
    ("cyan", .cyan), ("blue", .blue), ("indigo", .indigo), ("purple", .purple), ("pink", .pink), ("brown", .brown),
    ("white", .white), ("gray", .gray), ("black", .black), ("clear", .clear),
    ("ui.label", Color(uiColor: .label)), ("ui.secondaryLabel", Color(uiColor: .secondaryLabel)),
    ("ui.tertiaryLabel", Color(uiColor: .tertiaryLabel)), ("ui.systemBackground", Color(uiColor: .systemBackground)),
    ("ui.secondarySystemBackground", Color(uiColor: .secondarySystemBackground)),
    ("ui.systemGroupedBackground", Color(uiColor: .systemGroupedBackground)),
    ("ui.secondarySystemGroupedBackground", Color(uiColor: .secondarySystemGroupedBackground)),
    ("ui.separator", Color(uiColor: .separator)), ("ui.link", Color(uiColor: .link)), ("ui.tint", Color(uiColor: .tintColor)),
    ("ui.systemFill", Color(uiColor: .systemFill)), ("ui.placeholderText", Color(uiColor: .placeholderText)),
    ("asset.ProbeColor", Color("ProbeColor"))]

func envSummary(_ e: EnvironmentValues) -> String {
    [
        "colorScheme=\(e.colorScheme)", "contrast=\(e.colorSchemeContrast)", "dynamicType=\(e.dynamicTypeSize)",
        "legibility=\(String(describing: e.legibilityWeight))", "layoutDirection=\(e.layoutDirection)",
        "locale=\(e.locale.identifier)", "calendar=\(e.calendar.identifier)", "timeZone=\(e.timeZone.identifier)",
        "displayScale=\(e.displayScale)", "pixelLength=\(e.pixelLength)",
        "hsc=\(String(describing: e.horizontalSizeClass))", "vsc=\(String(describing: e.verticalSizeClass))",
        "reduceMotion=\(e.accessibilityReduceMotion)", "reduceTransparency=\(e.accessibilityReduceTransparency)",
        "differentiateWithoutColor=\(e.accessibilityDifferentiateWithoutColor)", "invertColors=\(e.accessibilityInvertColors)",
        "showButtonShapes=\(e.accessibilityShowButtonShapes)", "voiceOver=\(e.accessibilityVoiceOverEnabled)",
        "switchControl=\(e.accessibilitySwitchControlEnabled)", "accessibilityEnabled=\(e.accessibilityEnabled)",
        "isEnabled=\(e.isEnabled)", "lineLimit=\(String(describing: e.lineLimit))", "multilineTextAlignment=\(e.multilineTextAlignment)",
        "truncationMode=\(e.truncationMode)", "minRowHeight=\(e.defaultMinListRowHeight)", "minHeaderHeight=\(String(describing: e.defaultMinListHeaderHeight))",
        "controlSize=\(e.controlSize)", "imageScale=\(e.imageScale)", "redaction=\(e.redactionReasons.rawValue)",
        "isLuminanceReduced=\(e.isLuminanceReduced)", "supportsMultipleWindows=\(e.supportsMultipleWindows)",
        "isSceneCaptured=\(e.isSceneCaptured)", "font=\(String(describing: e.font))",
    ].joined(separator: " ")
}

struct EnvProbe: View {
    @Environment(\.self) var env
    var body: some View {
        let s = envSummary(env)
        Text("Ag").font(.body).gframe("env.bodyText")
            .onChange(of: s, initial: true) { _, n in
                logt("env.values", n)
                logt("env.live.colors", ["primary", "accentColor", "blue", "ui.systemBackground", "ui.label", "asset.ProbeColor"].compactMap { k in
                    probeColors.first { $0.0 == k }.map { "\(k)=\(colorRow($0.1, env))" } }.joined(separator: " | "))
                logWindowFacts("env")
            }
            .onAppear {
                for scheme in [ColorScheme.light, .dark] {
                    var e = EnvironmentValues(); e.colorScheme = scheme
                    for (n, c) in probeColors { log("color.\(scheme).\(n)", colorRow(c, e)) }
                }
                // UIKit high-contrast variants for comparison
                for (n, c) in [("label", UIColor.label), ("systemBlue", UIColor.systemBlue), ("systemBackground", UIColor.systemBackground), ("systemRed", UIColor.systemRed)] {
                    for (sn, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
                        let tc = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: style), UITraitCollection(accessibilityContrast: .high)])
                        let r = c.resolvedColor(with: tc)
                        var red: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        r.getRed(&red, green: &g, blue: &b, alpha: &a)
                        log("color.ui.highContrast.\(sn).\(n)", "\(f4(Double(red))),\(f4(Double(g))),\(f4(Double(b))),\(f4(Double(a)))")
                    }
                }
                // the driver changes appearance (t≈3), content size (t≈6), contrast (t≈9), then reverts (t≈12)
                after(15) { finish() }
            }
    }
}

// MARK: accessibility

@MainActor func dumpAccessibility(_ label: String) {
    guard let ws = UIApplication.shared.connectedScenes.first as? UIWindowScene, let w = ws.windows.first(where: { $0.isKeyWindow }) ?? ws.windows.first else { return }
    var n = 0
    func visit(_ o: NSObject, depth: Int) {
        guard n < 80, depth < 40 else { return }
        if o.isAccessibilityElement {
            n += 1
            let f = o.accessibilityFrame
            log("ax.\(label).element", "label='\(o.accessibilityLabel ?? "")' value='\(o.accessibilityValue ?? "")' hint='\(o.accessibilityHint ?? "")' traits=0x\(String(o.accessibilityTraits.rawValue, radix: 16)) frame=\(rc(f)) id='\((o as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? "")' class=\(String(describing: type(of: o)).prefix(40))")
            return
        }
        if let els = o.accessibilityElements as? [NSObject], !els.isEmpty {
            for e in els { visit(e, depth: depth + 1) }
            return
        }
        let c = o.accessibilityElementCount()
        if c != NSNotFound && c > 0 {
            for i in 0..<c { if let e = o.accessibilityElement(at: i) as? NSObject { visit(e, depth: depth + 1) } }
            return
        }
        if let v = o as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
    }
    visit(w, depth: 0)
    log("ax.\(label).count", n)
}

struct A11yProbe: View {
    @State var value = 0.3
    @State var count = 2
    var body: some View {
        VStack(spacing: 12) {
            Text("Heading").font(.title).accessibilityAddTraits(.isHeader)
            Button("Save") {}.accessibilityHint("Saves the document")
            Image(systemName: "star.fill")
            Image(systemName: "trash").accessibilityLabel("Delete")
            Image(decorative: "ProbeImage")
            Toggle("Wi-Fi", isOn: .constant(true))
            Slider(value: $value)
            Stepper("Count \(count)", value: $count)
            HStack { Text("Combined"); Text("children") }.accessibilityElement(children: .combine)
            Text("Hidden text").accessibilityHidden(true)
            Text("Identified").accessibilityIdentifier("probe.id")
            Link("Link", destination: URL(string: "https://example.com")!)
            TextField("Field", text: .constant("typed"))
            ProgressView(value: 0.4)
        }
        .onAppear {
            log("ax.flags", "voiceOver=\(UIAccessibility.isVoiceOverRunning) switch=\(UIAccessibility.isSwitchControlRunning) reduceMotion=\(UIAccessibility.isReduceMotionEnabled) boldText=\(UIAccessibility.isBoldTextEnabled) darkerColors=\(UIAccessibility.isDarkerSystemColorsEnabled) buttonShapes=\(UIAccessibility.buttonShapesEnabled)")
            after(1.5) { dumpAccessibility("tree") }
            after(2.0) { AccessibilityNotification.Announcement("probe announcement").post(); logt("ax.announcementPosted") }
            after(3.0) { finish() }
        }
    }
}

// MARK: localization

struct L10nProbe: View {
    @Environment(\.locale) var locale
    @Environment(\.layoutDirection) var dir
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("greeting").gframe("l10n.greeting")
            Text(verbatim: "greeting").gframe("l10n.verbatim")
            Text("items \(3)").gframe("l10n.items3")
            HStack { Text("L").gframe("l10n.first"); Text("R").gframe("l10n.second") }
            Image(systemName: "arrow.forward").gframe("l10n.arrow")
            Text(Date(timeIntervalSince1970: 1_000_000_000), format: .dateTime.year().month().day())
            Text(1234567.891, format: .number)
        }
        .padding()
        .onAppear {
            log("l10n.env", "locale=\(locale.identifier) layoutDirection=\(dir)")
            log("l10n.preferredLanguages", Locale.preferredLanguages.joined(separator: ","))
            log("l10n.bundlePreferred", Bundle.main.preferredLocalizations.joined(separator: ","))
            log("l10n.String(localized:)", String(localized: "greeting"))
            log("l10n.items3", String(localized: "items \(3)"))
            log("l10n.date", Date(timeIntervalSince1970: 1_000_000_000).formatted(.dateTime.year().month().day().locale(locale)))
            log("l10n.number", 1234567.891.formatted(.number.locale(locale)))
            after(1.5) { finish() }
        }
    }
}

// MARK: images and symbols

struct ImagesProbe: View {
    @State var bounce = 0
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "cloud.sun.rain.fill").symbolRenderingMode(.multicolor)
                Image(systemName: "cloud.sun.rain.fill").symbolRenderingMode(.hierarchical).foregroundStyle(.blue)
                Image(systemName: "cloud.sun.rain.fill").symbolRenderingMode(.palette).foregroundStyle(.red, .green, .blue)
                Image(systemName: "wifi", variableValue: 0.5)
                Image(systemName: "star.fill").symbolEffect(.bounce, value: bounce)
            }.font(.largeTitle)
            HStack {
                ForEach([Font.Weight.ultraLight, .regular, .black], id: \.self) { w in Image(systemName: "star").fontWeight(w).gframe("img.weight.\(w)") }
            }.font(.title)
            Image("ProbeImage").gframe("img.asset")
            Image("ProbeImage").resizable().frame(width: 40, height: 40).gframe("img.asset.resized")
            Image(systemName: "doesnotexist.symbol").gframe("img.missing")
            Image(uiImage: UIImage(systemName: "heart")!).gframe("img.fromUIImage")
        }
        .onAppear {
            let names = ["star", "star.fill", "heart", "trash", "gear", "person.crop.circle", "square.and.arrow.up",
                         "apple.logo", "applelogo", "swift", "xcode", "iphone", "cloud.sun.rain.fill", "doesnotexist.symbol"]
            for n in names {
                if let i = UIImage(systemName: n) { log("img.symbol.\(n)", "size=\(sz(i.size)) scale=\(f2(i.scale)) baseline=\(f2(i.baselineOffsetFromBottom ?? -1)) isSymbol=\(i.isSymbolImage)") }
                else { log("img.symbol.\(n)", "nil") }
            }
            let cfg = UIImage.SymbolConfiguration(textStyle: .body)
            if let i = UIImage(systemName: "star", withConfiguration: cfg) { log("img.symbol.star.body", sz(i.size)) }
            if let i = UIImage(named: "ProbeImage") { log("img.asset.ProbeImage", "size=\(sz(i.size)) scale=\(f2(i.scale))") } else { log("img.asset.ProbeImage", "nil") }
            after(1.0) { bounce += 1 }
            after(2.5) { finish() }
        }
    }
}

// MARK: gestures

struct GestureProbe: View {
    @State var dragging = false
    var body: some View {
        VStack(spacing: 16) {
            Color.red.frame(height: 70).onTapGesture { logt("g.tap.action") }.gframe("g.tap", target: true)
            Color.orange.frame(height: 70)
                .onTapGesture(count: 2) { logt("g.double.doubleAction") }
                .onTapGesture { logt("g.double.singleAction") }
                .gframe("g.double", target: true)
            Color.yellow.frame(height: 70)
                .onLongPressGesture(minimumDuration: 0.5) { logt("g.long.action") } onPressingChanged: { p in logt("g.long.pressing", p) }
                .gframe("g.long", target: true)
            Color.green.frame(height: 110)
                .gesture(DragGesture(minimumDistance: 10)
                    .onChanged { v in
                        if !dragging { dragging = true; logt("g.drag.began", "start=\(f2(v.startLocation.x)),\(f2(v.startLocation.y)) translation=\(sz(v.translation))") }
                        Rec.set(String(format: "g.drag.changed.%.3f", elapsed()), "loc=\(f2(v.location.x)),\(f2(v.location.y)) tr=\(sz(v.translation)) vel=\(sz(v.velocity)) predEnd=\(sz(v.predictedEndTranslation))")
                    }
                    .onEnded { v in
                        dragging = false
                        logt("g.drag.ended", "tr=\(sz(v.translation)) vel=\(sz(v.velocity)) predEnd=\(sz(v.predictedEndTranslation))")
                        Rec.flush(prefix: "g.drag.changed.")
                    })
                .gframe("g.drag", target: true)
            Color.blue.frame(height: 70)
                .onTapGesture { logt("g.simul.tap") }
                .simultaneousGesture(DragGesture(minimumDistance: 10).onEnded { v in logt("g.simul.dragEnded", sz(v.translation)) })
                .gframe("g.simul", target: true)
            Button("Button") { logt("g.button.action") }
                .buttonStyle(.borderedProminent)
                .gframe("g.button", target: true)
        }
        .padding()
        .onAppear { after(16) { finish() } }
    }
}

// MARK: services touched by common app code

struct ServicesProbe: View {
    @State var trigger = 0
    var body: some View {
        Text("services")
            .sensoryFeedback(.success, trigger: trigger)
            .onAppear {
                after(0.5) { logt("svc.step", "sensoryFeedback"); trigger += 1 }
                after(1.0) { logt("svc.step", "impact"); let g = UIImpactFeedbackGenerator(style: .medium); g.prepare(); g.impactOccurred() }
                after(1.5) { logt("svc.step", "pasteboard write"); UIPasteboard.general.string = "suiprobe" }
                after(2.0) { logt("svc.step", "pasteboard read"); log("svc.pasteboard.hasStrings", UIPasteboard.general.hasStrings) }
                after(2.5) { logt("svc.step", "orientation"); UIDevice.current.beginGeneratingDeviceOrientationNotifications(); log("svc.orientation", UIDevice.current.orientation.rawValue) }
                after(3.0) { logt("svc.step", "battery"); UIDevice.current.isBatteryMonitoringEnabled = true; log("svc.battery", "\(UIDevice.current.batteryState.rawValue) \(UIDevice.current.batteryLevel)") }
                after(3.5) { logt("svc.step", "thermal/lowPower"); log("svc.thermal", "\(ProcessInfo.processInfo.thermalState.rawValue) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)") }
                after(4.0) { logt("svc.step", "idleTimer"); UIApplication.shared.isIdleTimerDisabled = true }
                after(4.5) { logt("svc.step", "brightness"); log("svc.brightness", f2(UIScreen.main.brightness)) }
                after(5.0) { logt("svc.step", "device"); log("svc.device", "\(UIDevice.current.model) \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) name=\(UIDevice.current.name)") }
                after(6.0) { finish() }
            }
    }
}
