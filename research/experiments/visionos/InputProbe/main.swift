// InputProbe: our own black-box probe for input on the visionOS simulator (Ycode,
// dirty-room observation; see research/notes/obs-vision-input-2026-10-31.md).
//
// Logs (stdout and os_log subsystem dev.ycode.inputprobe, prefix "IP:") every input
// callback a SwiftUI/UIKit/RealityKit app gets: Button, onTapGesture, SpatialTapGesture
// (2D location), DragGesture, MagnifyGesture, RotateGesture, onContinuousHover, UIKit
// touches (type, phase, location) and hover, keyboard text and key presses; in a volume
// and an immersive space: entity-targeted tap (3D location), drag, magnify, rotate3D; and
// the ARKit DeviceAnchor every 0.5 s. The volume also holds a mirror-metal and a rough
// metal sphere (reflection reference).
//
// Launch arguments: -volume opens the volume, -immersive opens the immersive space.

import ARKit
import QuartzCore
import RealityKit
import SwiftUI
import UIKit
import os

let log = Logger(subsystem: "dev.ycode.inputprobe", category: "probe")
func say(_ s: String) { print("IP: " + s); fflush(stdout); log.notice("IP: \(s, privacy: .public)") }
func f3(_ v: SIMD3<Float>) -> String { String(format: "(%.3f, %.3f, %.3f)", v.x, v.y, v.z) }
func f4(_ v: SIMD4<Float>) -> String { String(format: "(%.3f, %.3f, %.3f)", v.x, v.y, v.z) }
func p2(_ p: CGPoint) -> String { String(format: "(%.1f, %.1f)", p.x, p.y) }

// UIKit view that logs raw touches and hover.
final class TouchLogView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemTeal.withAlphaComponent(0.6)
        let h = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:)))
        addGestureRecognizer(h)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func hover(_ g: UIHoverGestureRecognizer) { say("uikit hover state=\(g.state.rawValue) loc=\(p2(g.location(in: self)))") }
    func dump(_ phase: String, _ t: Set<UITouch>, _ e: UIEvent?) {
        for x in t { say("uikit touch \(phase) type=\(x.type.rawValue) phase=\(x.phase.rawValue) loc=\(p2(x.location(in: self))) taps=\(x.tapCount) force=\(x.force) event.type=\(e?.type.rawValue ?? -1)") }
    }
    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) { dump("began", t, e) }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) { dump("moved", t, e) }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { dump("ended", t, e) }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { dump("cancelled", t, e) }
    override func pressesBegan(_ p: Set<UIPress>, with e: UIPressesEvent?) { for x in p { say("uikit press began key=\(x.key?.keyCode.rawValue ?? -1) chars=\(x.key?.characters ?? "")") }; super.pressesBegan(p, with: e) }
    override var canBecomeFirstResponder: Bool { true }
}
struct TouchLog: UIViewRepresentable {
    func makeUIView(context: Context) -> TouchLogView { TouchLogView() }
    func updateUIView(_ v: TouchLogView, context: Context) {}
}

struct MainView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var text = ""
    @State private var count = 0
    var body: some View {
        VStack(spacing: 16) {
            Text("InputProbe \(count)").font(.title)
            HStack(spacing: 16) {
                Button("Button A") { count += 1; say("button A action") }
                Button("Volume") { openWindow(id: "volume"); say("open volume") }
                Button("Immersive") { Task { let r = await openImmersiveSpace(id: "imm"); say("openImmersiveSpace \(r)") } }
            }
            HStack(spacing: 16) {
                Rectangle().fill(.orange).frame(width: 200, height: 140).overlay(Text("tap"))
                    .onTapGesture { say("onTapGesture") }
                    .hoverEffect()
                Rectangle().fill(.green).frame(width: 200, height: 140).overlay(Text("spatial"))
                    .gesture(SpatialTapGesture().onEnded { v in say("spatialTap loc=\(p2(v.location)) loc3D=\(v.location3D)") })
                Rectangle().fill(.purple).frame(width: 200, height: 140).overlay(Text("drag"))
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in say("drag changed start=\(p2(v.startLocation)) loc=\(p2(v.location)) tr=\(v.translation) tr3D=\(v.translation3D)") }
                        .onEnded { v in say("drag ended loc=\(p2(v.location)) tr=\(v.translation) predicted=\(v.predictedEndTranslation)") })
            }
            HStack(spacing: 16) {
                Rectangle().fill(.blue).frame(width: 200, height: 140).overlay(Text("magnify"))
                    .gesture(MagnifyGesture().onChanged { v in say("magnify changed \(v.magnification)") }.onEnded { v in say("magnify ended \(v.magnification)") })
                Rectangle().fill(.red).frame(width: 200, height: 140).overlay(Text("rotate"))
                    .gesture(RotateGesture().onChanged { v in say("rotate changed \(v.rotation.degrees)") }.onEnded { v in say("rotate ended \(v.rotation.degrees)") })
                Rectangle().fill(.yellow).frame(width: 200, height: 140).overlay(Text("hover"))
                    .onContinuousHover { ph in say("continuousHover \(ph)") }
                    .hoverEffect(.highlight)
            }
            HStack(spacing: 16) {
                TouchLog().frame(width: 300, height: 140)
                TextField("type here", text: $text).frame(width: 300)
                    .onChange(of: text) { _, n in say("text=\(n)") }
                    .onKeyPress { k in say("keyPress \(k.key.character) phase=\(k.phase)"); return .ignored }
            }
        }
        .padding(30)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { say("main frame global \($0)") }
        .task {
            say("launched args=\(CommandLine.arguments)")
            if CommandLine.arguments.contains("-volume") { openWindow(id: "volume"); say("open volume") }
            if CommandLine.arguments.contains("-immersive") { let r = await openImmersiveSpace(id: "imm"); say("openImmersiveSpace \(r)") }
        }
    }
}

func entityGestures<V: View>(_ v: V, _ name: String) -> some View {
    v.gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { e in
        say("\(name) entityTap \(e.entity.name) loc3D=\(e.location3D) inScene=\(e.convert(e.location3D, from: .local, to: .scene))") })
     .simultaneousGesture(DragGesture().targetedToAnyEntity()
        .onChanged { e in say("\(name) entityDrag \(e.entity.name) loc3D=\(e.location3D) tr3D=\(e.translation3D)") }
        .onEnded { e in say("\(name) entityDrag ended \(e.entity.name) tr3D=\(e.translation3D)") })
     .simultaneousGesture(MagnifyGesture().targetedToAnyEntity().onChanged { e in say("\(name) entityMagnify \(e.magnification)") })
     .simultaneousGesture(RotateGesture3D().targetedToAnyEntity().onChanged { e in say("\(name) entityRotate3D \(e.rotation)") })
}

func target(_ m: ModelEntity, _ name: String) -> ModelEntity {
    m.name = name; m.components.set(InputTargetComponent()); m.components.set(HoverEffectComponent())
    m.generateCollisionShapes(recursive: false); return m
}

struct VolumeView: View {
    var body: some View {
        entityGestures(RealityView { content in
            let mirror = target(ModelEntity(mesh: .generateSphere(radius: 0.09), materials: [SimpleMaterial(color: .white, roughness: 0.0, isMetallic: true)]), "mirrorSphere")
            mirror.position = [-0.1, 0, 0]
            let rough = target(ModelEntity(mesh: .generateSphere(radius: 0.09), materials: [SimpleMaterial(color: .white, roughness: 0.5, isMetallic: true)]), "roughSphere")
            rough.position = [0.1, 0, 0]
            content.add(mirror); content.add(rough)
            say("volume make ok")
        }, "volume")
    }
}

@MainActor final class Tracker: ObservableObject {
    let session = ARKitSession(); let world = WorldTrackingProvider(); var started = false
    func run() async {
        guard !started else { return }; started = true
        do { try await session.run([world]); say("ARKit run ok") } catch { say("ARKit run error \(error)"); return }
        var last = ""
        while true {
            try? await Task.sleep(for: .milliseconds(500))
            guard let a = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { say("anchor nil"); continue }
            let m = a.originFromAnchorTransform
            let s = "anchor pos=\(f4(m.columns.3)) fwd=\(f4(-m.columns.2)) up=\(f4(m.columns.1)) tracked=\(a.isTracked)"
            if s != last { say(s); last = s }
        }
    }
}

struct ImmersiveView: View {
    @StateObject var t = Tracker()
    var body: some View {
        entityGestures(RealityView { content in
            let s = target(ModelEntity(mesh: .generateSphere(radius: 0.2), materials: [SimpleMaterial(color: .systemBlue, isMetallic: false)]), "immSphere")
            s.position = [0, 1.5, -2]
            content.add(s)
            let marker = ModelEntity(mesh: .generateBox(size: 0.1), materials: [UnlitMaterial(color: .red)])
            marker.position = [1, 1.5, -2]; content.add(marker)
            say("immersive make ok")
        }, "imm")
        .task { await t.run() }
    }
}

@main
struct InputProbeApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup(id: "main") { MainView() }
        WindowGroup(id: "volume") { VolumeView() }
            .windowStyle(.volumetric)
            .defaultSize(width: 0.4, height: 0.3, depth: 0.3, in: .meters)
        ImmersiveSpace(id: "imm") { ImmersiveView() }
    }
}
