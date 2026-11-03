// CrownProbe: our own black-box probe for the Digital Crown on the visionOS simulator (Ycode,
// dirty-room observation; see research/notes/obs-vision-crown-2026-11-01.md).
//
// Logs (stdout and os_log subsystem dev.ycode.crownprobe, prefix "CP:") what an app sees of
// the crown: onImmersionChange (amount) in progressive, full and mixed immersive spaces,
// onWorldRecenter (phases) in the window and the space, scene phases, and the ARKit
// DeviceAnchor every 0.5 s (recentering moves the world origin on a device).
// The immersive content is an unlit inside-out sphere of radius 20 m (magenta) with a
// red cube at (0, 1.5, -2), so the progressive portal's size is visible in screenshots.
//
// Launch arguments: -prog (progressive, system range), -progR (progressive 0.2...0.8,
// initial 0.5), -full, -mixed open that space at launch.

import ARKit
import QuartzCore
import RealityKit
import SwiftUI
import os

let log = Logger(subsystem: "dev.ycode.crownprobe", category: "probe")
func say(_ s: String) { print("CP: " + s); fflush(stdout); log.notice("CP: \(s, privacy: .public)") }
func f4(_ v: SIMD4<Float>) -> String { String(format: "(%.3f, %.3f, %.3f)", v.x, v.y, v.z) }
func amt(_ c: ImmersionChangeContext) -> String { c.amount.map { String(format: "%.4f", $0) } ?? "nil" }

struct MainView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack(spacing: 16) {
            Text("CrownProbe").font(.title)
            HStack(spacing: 16) {
                ForEach(["prog", "progR", "full", "mixed"], id: \.self) { id in
                    Button(id) { Task { let r = await openImmersiveSpace(id: id); say("open \(id) -> \(r)") } }
                }
                Button("dismiss") { Task { await dismissImmersiveSpace(); say("dismissed") } }
            }
        }
        .padding(30)
        .onWorldRecenter { (p: WorldRecenterPhase) in say("window worldRecenter \(p)") }
        .onChange(of: phase) { o, n in say("window scenePhase \(o) -> \(n)") }
        .task {
            say("launched args=\(CommandLine.arguments)")
            for id in ["prog", "progR", "full", "mixed"] where CommandLine.arguments.contains("-" + id) {
                let r = await openImmersiveSpace(id: id); say("open \(id) -> \(r)")
            }
        }
    }
}

@MainActor final class Tracker: ObservableObject {
    let session = ARKitSession(); let world = WorldTrackingProvider(); var started = false
    func run() async {
        guard !started else { return }; started = true
        do { try await session.run([world]); say("ARKit run ok") } catch { say("ARKit run error \(error)"); return }
        var last = ""
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard let a = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { continue }
            let m = a.originFromAnchorTransform
            let s = "anchor pos=\(f4(m.columns.3)) fwd=\(f4(-m.columns.2))"
            if s != last { say(s); last = s }
        }
    }
}

struct SpaceView: View {
    let name: String
    @StateObject var t = Tracker()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        RealityView { content in
            let sky = ModelEntity(mesh: .generateSphere(radius: 20), materials: [UnlitMaterial(color: .magenta)])
            sky.scale = [-1, 1, 1]; sky.position = [0, 1.5, 0]
            content.add(sky)
            let cube = ModelEntity(mesh: .generateBox(size: 0.3), materials: [UnlitMaterial(color: .red)])
            cube.position = [0, 1.5, -2]; content.add(cube)
            say("\(name) make ok")
        }
        .onImmersionChange { o, n in say("\(name) immersion \(amt(o)) -> \(amt(n))") }
        .onWorldRecenter { (p: WorldRecenterPhase) in say("\(name) worldRecenter \(p)") }
        .onChange(of: phase) { o, n in say("\(name) scenePhase \(o) -> \(n)") }
        .onDisappear { say("\(name) disappeared") }
        .task { await t.run() }
    }
}

@main
struct CrownProbeApp: App {
    @State var prog: any ImmersionStyle = .progressive
    @State var progR: any ImmersionStyle = .progressive(0.2...0.8, initialAmount: 0.5)
    @State var full: any ImmersionStyle = .full
    @State var mixed: any ImmersionStyle = .mixed
    var body: some SwiftUI.Scene {
        WindowGroup(id: "main") { MainView() }
        ImmersiveSpace(id: "prog") { SpaceView(name: "prog") }
            .immersionStyle(selection: $prog, in: .progressive)
        ImmersiveSpace(id: "progR") { SpaceView(name: "progR") }
            .immersionStyle(selection: $progR, in: .progressive(0.2...0.8, initialAmount: 0.5))
        ImmersiveSpace(id: "full") { SpaceView(name: "full") }
            .immersionStyle(selection: $full, in: .full)
        ImmersiveSpace(id: "mixed") { SpaceView(name: "mixed") }
            .immersionStyle(selection: $mixed, in: .mixed)
    }
}
