// SUIProbe modes: lifecycle, navigation, lists, controls, keyboard, modals.
import SwiftUI
import UIKit

/// Logs a view's global frame (and safe area) under `key` whenever it changes.
struct GlobalFrame: ViewModifier {
    let key: String
    var asTarget = false
    var fx: CGFloat = 0.5      // target point: fraction of width plus dx points
    var dx: CGFloat = 0
    func pt(_ r: CGRect) -> CGRect { CGRect(x: r.minX + r.width * fx + dx, y: r.midY, width: 0, height: 0) }
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            let r = g.frame(in: .global)
            let s = g.safeAreaInsets
            Color.clear
                .onAppear { logt("\(key).frame", "\(rc(r)) safe=\(ins(s))"); if asTarget { target(key, pt(r)) } }
                .onChange(of: r) { _, n in logt("\(key).frame", "\(rc(n)) safe=\(ins(s))"); if asTarget { target(key, pt(n)) } }
                .onChange(of: s) { _, n in logt("\(key).safe", ins(n)) }
        })
    }
}
extension View {
    func gframe(_ key: String, target: Bool = false, fx: CGFloat = 0.5, dx: CGFloat = 0) -> some View { modifier(GlobalFrame(key: key, asTarget: target, fx: fx, dx: dx)) }
    func lifecycle(_ key: String) -> some View {
        self.onAppear { logt("\(key).onAppear") }
            .onDisappear { logt("\(key).onDisappear") }
            .task { logt("\(key).task.start"); do { try await Task.sleep(for: .seconds(3600)) } catch { logt("\(key).task.cancelled") } }
    }
}

// MARK: lifecycle

struct LifecycleProbe: View {
    @Environment(\.scenePhase) var phase
    var body: some View {
        Text("lifecycle")
            .lifecycle("lc.text")
            .onOpenURL { u in logt("lc.onOpenURL", u.absoluteString) }
            .onContinueUserActivity("dev.ycode.activity") { _ in logt("lc.userActivity") }
            .onAppear {
                logWindowFacts("lc")
                after(2.0) { logImages("lc") }
            }
    }
}

// MARK: navigation stack

struct NavPage: View {
    let n: Int
    init(n: Int) { self.n = n; logt("nav.page\(n).init") }
    var body: some View {
        let _ = logt("nav.page\(n).body")
        Text("Page \(n)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gframe("nav.page\(n)")
            .lifecycle("nav.page\(n)")
            .navigationTitle("Page \(n)")
            .navigationBarTitleDisplayMode(n % 2 == 0 ? .large : .inline)
    }
}

struct NavProbe: View {
    @State var path: [Int] = []
    var body: some View {
        NavigationStack(path: $path) {
            List(0..<5, id: \.self) { i in NavigationLink("Row \(i)", value: i + 10).gframe("nav.row\(i)", target: i == 0) }
                .gframe("nav.root")
                .lifecycle("nav.root")
                .navigationTitle("Root")
                .navigationDestination(for: Int.self) { n in NavPage(n: n) }
        }
        .onChange(of: path) { o, n in logt("nav.path", "\(o)->\(n)") }
        .onAppear {
            let steps: [(Double, [Int])] = [(1.5, [1]), (3.0, [1, 2]), (4.5, [1, 2, 3]), (6.0, [1, 2]), (7.5, []), (9.0, [4, 5])]
            for (t, p) in steps { after(t) { logt("nav.set", p); path = p } }
            after(10.5) { logt("nav.set", "[] (pop all)"); path = [] }
            // 12.0: the driver taps row 0 (value 10); 14.0: it swipes back from the left edge.
            after(17.0) { finish() }
        }
    }
}

// MARK: split view (compact width on iPhone)

struct SplitProbe: View {
    @State var selection: Int?
    @State var visibility: NavigationSplitViewVisibility = .automatic
    @Environment(\.horizontalSizeClass) var hsc
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(0..<3, id: \.self, selection: $selection) { i in Text("Item \(i)") }
                .gframe("split.sidebar")
                .lifecycle("split.sidebar")
                .navigationTitle("Sidebar")
        } detail: {
            Group {
                if let s = selection { Text("Detail \(s)").lifecycle("split.detail\(s)") }
                else { Text("No selection").lifecycle("split.detailEmpty") }
            }
            .gframe("split.detail")
        }
        .onChange(of: selection) { o, n in logt("split.selection", "\(String(describing: o))->\(String(describing: n))") }
        .onChange(of: visibility, initial: true) { o, n in logt("split.visibility", "\(o)->\(n)") }
        .onAppear {
            logt("split.hsc", String(describing: hsc))
            after(2) { selection = 1 }
            after(4) { selection = nil }
            after(6) { selection = 2 }
            after(8) { finish() }
        }
    }
}

// MARK: tabs

struct TabsProbe: View {
    @State var sel = 0
    var body: some View {
        TabView(selection: $sel) {
            ForEach(0..<3, id: \.self) { i in
                Tab("Tab \(i)", systemImage: "star", value: i) {
                    Text("Tab \(i)").frame(maxWidth: .infinity, maxHeight: .infinity).gframe("tabs.tab\(i)").lifecycle("tabs.tab\(i)")
                }
            }
        }
        .onChange(of: sel) { o, n in logt("tabs.selection", "\(o)->\(n)") }
        .onAppear {
            after(2) { sel = 1 }
            after(4) { sel = 2 }
            after(6) { sel = 0 }
            after(8) { finish() }
        }
    }
}

// MARK: list and scrolling

@Observable final class AppearCounter {
    var appeared = Set<Int>()
    var total = 0
    var disappeared = 0
}

struct ListProbe: View {
    @State var stage: Int = {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-stage"), i + 1 < a.count { return Int(a[i + 1]) ?? 0 }
        return 0
    }()
    @State var counter = AppearCounter()
    var body: some View {
        Group {
            if stage == 0 { listStage }
            else if stage == 1 { lazyStage }
            else { eagerStage }
        }
        .onAppear { schedule() }
    }

    var listStage: some View {
        ScrollViewReader { proxy in
            List(0..<1000, id: \.self) { i in
                Text("Row \(i)")
                    .gframe(i < 3 ? "list.row\(i)" : "list.rowX")
                    .onAppear { counter.appeared.insert(i); counter.total += 1 }
                    .onDisappear { counter.appeared.remove(i); counter.disappeared += 1 }
            }
            .gframe("list.list", target: true)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, n in Rec.set("scroll.list.\(String(format: "%.3f", elapsed()))", f2(n)) }
            .onAppear {
                after(1.0) { report("list.initial") }
                after(1.5) { proxy.scrollTo(500, anchor: .top) }
                after(2.5) { report("list.afterScrollTo500") }
            }
        }
        .environment(\.defaultMinListRowHeight, 44)
    }

    var lazyStage: some View {
        ScrollView {
            LazyVStack {
                ForEach(0..<1000, id: \.self) { i in
                    Text("Row \(i)").frame(height: 40)
                        .onAppear { counter.appeared.insert(i); counter.total += 1 }
                        .onDisappear { counter.appeared.remove(i); counter.disappeared += 1 }
                }
            }
        }
        .gframe("list.lazy", target: true)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, g in
            Rec.set(String(format: "scroll.lazy.%.3f", elapsed()), "offset=\(f2(g.contentOffset.y)) content=\(sz(g.contentSize)) container=\(sz(g.containerSize)) insets=\(g.contentInsets)")
        }
        .onAppear { after(1.0) { report("lazy.initial") } }
    }

    var eagerStage: some View {
        ScrollView {
            VStack {
                ForEach(0..<300, id: \.self) { i in
                    Text("Row \(i)").frame(height: 40)
                        .onAppear { counter.appeared.insert(i); counter.total += 1 }
                }
            }
        }
        .onAppear { after(1.0) { report("eager.initial") } }
    }

    func report(_ k: String) {
        let a = counter.appeared
        logt(k, "visible=\(a.count) min=\(a.min() ?? -1) max=\(a.max() ?? -1) onAppearTotal=\(counter.total) onDisappearTotal=\(counter.disappeared)")
    }

    func schedule() {
        // One stage per launch (-stage 0 list, 1 lazy stack, 2 eager stack).
        // The driver flings at t≈4 (drag up); report at 9.
        after(9.0) {
            report(stage == 0 ? "list.afterFling" : stage == 1 ? "lazy.afterFling" : "eager.afterFling")
            Rec.flush(prefix: "scroll.")
            finish()
        }
    }
}

// MARK: controls

struct ControlsProbe: View {
    @State var on = false
    @State var value = 0.5
    @State var count = 1
    @State var choice = 0
    @State var date = Date(timeIntervalSince1970: 0)
    @State var text = ""
    @State var color = Color.red
    @State var expanded = false
    var body: some View {
        Form {
            Section("Basics") {
                Toggle("Toggle", isOn: $on).gframe("ctl.toggle", target: true, fx: 1, dx: -25)
                Slider(value: $value).gframe("ctl.slider", target: true, fx: 0.8)
                Stepper("Stepper \(count)", value: $count).gframe("ctl.stepper", target: true, fx: 1, dx: -23)
                Picker("Picker", selection: $choice) { Text("One").tag(0); Text("Two").tag(1) }.gframe("ctl.picker")
                DatePicker("Date", selection: $date, displayedComponents: .date).gframe("ctl.date")
            }
            Section("More") {
                TextField("Text", text: $text).gframe("ctl.textField")
                ColorPicker("Color", selection: $color).gframe("ctl.color")
                LabeledContent("Labeled", value: "Value").gframe("ctl.labeled")
                DisclosureGroup("Disclosure", isExpanded: $expanded) { Text("Inside") }.gframe("ctl.disclosure")
                Button("Button") { logt("ctl.button.action") }.gframe("ctl.button", target: true)
                Menu("Menu") { Button("A") {} }.gframe("ctl.menu")
                ProgressView(value: 0.3).gframe("ctl.progress")
            }
        }
        .onChange(of: on) { _, n in logt("ctl.toggle.value", n) }
        .onChange(of: value) { _, n in logt("ctl.slider.value", f4(n)) }
        .onChange(of: count) { _, n in logt("ctl.stepper.value", n) }
        .onAppear {
            logt("ctl.pickerDefaultStyleHint", "see screenshot")
            after(1.0) { logt("ctl.programmatic", "toggle on"); on = true }
            after(1.5) { on = false }
            // the driver taps toggle (t≈3), button (t≈4), slider right end (t≈5), stepper plus (t≈6)
            after(14.0) { finish() }
        }
    }
}

// MARK: keyboard and text input

@MainActor func observeKeyboard() {
    let names: [(String, Notification.Name)] = [
        ("willShow", UIResponder.keyboardWillShowNotification), ("didShow", UIResponder.keyboardDidShowNotification),
        ("willHide", UIResponder.keyboardWillHideNotification), ("didHide", UIResponder.keyboardDidHideNotification),
        ("willChangeFrame", UIResponder.keyboardWillChangeFrameNotification)]
    for (label, n) in names {
        NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { note in
            let u = note.userInfo ?? [:]
            let end = (u[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect).map(rc) ?? "-"
            let dur = (u[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double).map(f4) ?? "-"
            let curve = (u[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int).map(String.init) ?? "-"
            let local = (u[UIResponder.keyboardIsLocalUserInfoKey] as? Bool).map { "\($0)" } ?? "-"
            logt("kb.\(label)", "end=\(end) duration=\(dur) curve=\(curve) local=\(local)")
        }
    }
}

struct KeyboardProbe: View {
    @State var text = ""
    @State var number = ""
    @FocusState var focus: Int?
    var body: some View {
        GeometryReader { g in
            VStack(spacing: 20) {
                TextField("Type here", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: 1)
                    .onSubmit { logt("kb.onSubmit", text) }
                    .gframe("kb.field", target: true)
                TextField("Number", text: $number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: 2)
                Spacer()
                Text("bottom").gframe("kb.bottomText")
            }
            .padding()
            .onChange(of: g.safeAreaInsets) { _, n in logt("kb.safeArea", ins(n)) }
            .onAppear { logt("kb.safeArea.initial", ins(g.safeAreaInsets)) }
        }
        .onChange(of: text) { o, n in logt("kb.text", "'\(o)'->'\(n)'") }
        .onChange(of: focus) { o, n in logt("kb.focus", "\(String(describing: o))->\(String(describing: n))") }
        .onAppear {
            let modes = UITextInputMode.activeInputModes.map { $0.primaryLanguage ?? "nil" }
            log("kb.activeInputModes", modes.joined(separator: ","))
            after(1.0) { logt("kb.set", "focus=1"); focus = 1 }
            // driver: keys h, i at t≈3, Return at t≈4.5
            after(7.0) { logt("kb.set", "focus=2"); focus = 2 }
            after(9.0) { logt("kb.set", "focus=nil"); focus = nil }
            after(11.0) { finish() }
        }
    }
}

// MARK: modals

func topPresented() -> String {
    guard let ws = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return "-" }
    var out: [String] = []
    for w in ws.windows {
        var vc = w.rootViewController
        var chain: [String] = []
        while let p = vc?.presentedViewController {
            let n = String(describing: type(of: p)).split(separator: "<").first.map(String.init) ?? "?"
            chain.append("\(n)[\(p.modalPresentationStyle.rawValue)]")
            vc = p
        }
        out.append("w\(rc(w.frame)):" + chain.joined(separator: ">"))
    }
    return out.joined(separator: " ")
}

struct ModalProbe: View {
    @State var sheet = false
    @State var detent: PresentationDetent = .medium
    @State var alert = false
    @State var dialog = false
    @State var popover = false
    @State var popoverCompact = false
    @State var cover = false
    var body: some View {
        VStack(spacing: 40) {
            Text("modal root").lifecycle("modal.root")
            Button("Popover anchor") {}.popover(isPresented: $popover) {
                Text("Popover").padding().gframe("modal.popover").lifecycle("modal.popover")
            }
            Button("Popover compact") {}.popover(isPresented: $popoverCompact) {
                Text("Popover compact").padding().gframe("modal.popoverCompact").lifecycle("modal.popoverCompact")
                    .presentationCompactAdaptation(.popover)
            }
        }
        .sheet(isPresented: $sheet, onDismiss: { logt("modal.sheet.onDismiss") }) {
            Color.yellow.gframe("modal.sheet").lifecycle("modal.sheet")
                .presentationDetents([.medium, .large], selection: $detent)
        }
        .alert("Alert title", isPresented: $alert) { Button("OK") { logt("modal.alert.ok") } } message: { Text("Message") }
        .confirmationDialog("Dialog", isPresented: $dialog, titleVisibility: .visible) { Button("Choice") {} }
        .fullScreenCover(isPresented: $cover, onDismiss: { logt("modal.cover.onDismiss") }) {
            Color.green.gframe("modal.cover").lifecycle("modal.cover")
        }
        .onChange(of: sheet) { _, n in logt("modal.sheet.isPresented", n) }
        .onChange(of: alert) { _, n in logt("modal.alert.isPresented", n) }
        .onChange(of: detent) { _, n in logt("modal.sheet.detent", String(describing: n)) }
        .onAppear {
            var t = 1.0
            func at(_ dt: Double, _ label: String, _ f: @escaping @MainActor () -> Void) {
                t += dt
                after(t) { logt("modal.step", label); f(); after(0.8) { logt("modal.presented", topPresented()) } }
            }
            at(0, "sheet on") { sheet = true }
            at(2, "detent large") { detent = .large }
            at(2, "sheet off") { sheet = false }
            at(2, "alert on") { alert = true }
            at(2, "alert off") { alert = false }
            at(2, "dialog on") { dialog = true }
            at(2, "dialog off") { dialog = false }
            at(2, "popover on") { popover = true }
            at(2, "popover off") { popover = false }
            at(2, "popoverCompact on") { popoverCompact = true }
            at(2, "popoverCompact off") { popoverCompact = false }
            at(2, "cover on") { cover = true }
            at(2, "cover off") { cover = false }
            after(t + 2) { finish() }
        }
    }
}
