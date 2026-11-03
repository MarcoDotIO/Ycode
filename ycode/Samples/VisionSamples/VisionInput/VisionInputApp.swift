// Ycode's visionOS sample 4 (visionos.md "Ycode implementation", round R9):
// one target per input path of §5.5.5, each logging what it received through
// os.Logger (subsystem org.ycode.samples, category input, lines starting
// "ycode-input:"), so a guest log stream shows what the gaze, the hands, the
// Digital Crown and the keyboard delivered. A mixed immersive space opened at
// launch adds a RealityKit sphere that takes a tap, and logs ARKit's
// DeviceAnchor whenever it moves (the camera pose through vhmdd's set_pose).
import ARKit
import os
import RealityKit
import SwiftUI

let log = Logger(subsystem: "org.ycode.samples", category: "input")

func f(_ v: Double) -> String { String(format: "%.3f", v) }
func f(_ v: Float) -> String { String(format: "%.3f", v) }

@main
struct VisionInputApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup(id: "probe") {
            ProbeView()
        }
        .defaultSize(width: 1200, height: 760)
        ImmersiveSpace(id: "space") {
            SpaceView()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

/// A labelled tile of the grid.
struct Tile<Content: View>: View {
    let title: String
    let color: Color
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24).fill(color.opacity(0.85))
            VStack(spacing: 8) {
                Text(title).font(.title).bold()
                content()
            }
        }
        .frame(width: 340, height: 200)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 24))
        .hoverEffect()
    }
}

struct ProbeView: View {
    @Environment(\.openImmersiveSpace) private var openSpace
    @State private var last = "nothing yet"
    @State private var buttonTaps = 0
    @State private var drag = CGSize.zero
    @State private var scale = 1.0
    @State private var angle = Angle.zero
    @State private var text = ""

    func note(_ s: String) {
        last = s
        log.notice("ycode-input: \(s, privacy: .public)")
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Ycode input probe — last: \(last)").font(.title2).lineLimit(1)
            HStack(spacing: 20) {
                Button {
                    buttonTaps += 1
                    note("button action \(buttonTaps)")
                } label: {
                    Text("Button \(buttonTaps)").font(.title).frame(width: 300, height: 170)
                }
                .frame(width: 340, height: 200)
                Tile(title: "onTapGesture", color: .blue) { Text("tap") }
                    .onTapGesture { note("onTapGesture") }
                Tile(title: "SpatialTap", color: .green) { Text("tap with location") }
                    .gesture(SpatialTapGesture().onEnded { v in
                        note("spatialTap location \(f(v.location.x)) \(f(v.location.y)) location3D z \(f(v.location3D.z))")
                    })
            }
            HStack(spacing: 20) {
                Tile(title: "Drag", color: .orange) { Text("\(Int(drag.width)) × \(Int(drag.height))") }
                    .gesture(DragGesture()
                        .onChanged { v in
                            drag = v.translation
                            log.notice("ycode-input: drag changed \(f(v.translation.width), privacy: .public) \(f(v.translation.height), privacy: .public)")
                        }
                        .onEnded { v in
                            note("drag ended translation \(f(v.translation.width)) \(f(v.translation.height)) predicted \(f(v.predictedEndTranslation.width)) \(f(v.predictedEndTranslation.height))")
                        })
                Tile(title: "Magnify", color: .purple) { Text(String(format: "%.2f", scale)) }
                    .gesture(MagnifyGesture()
                        .onChanged { v in scale = v.magnification }
                        .onEnded { v in note("magnify ended \(f(v.magnification))") })
                Tile(title: "Rotate", color: .red) { Text(String(format: "%.1f°", angle.degrees)) }
                    .gesture(RotateGesture()
                        .onChanged { v in angle = v.rotation }
                        .onEnded { v in note("rotate ended \(f(v.rotation.degrees)) degrees") })
            }
            HStack(spacing: 20) {
                TextField("Type here", text: $text)
                    .font(.title)
                    .frame(width: 520)
                    .onChange(of: text) { _, new in note("text \"\(new)\"") }
                    .onSubmit { note("text submitted \"\(text)\"") }
                RealityView { content in
                    let box = ModelEntity(mesh: .generateBox(size: 0.12), materials: [SimpleMaterial(color: .cyan, isMetallic: false)])
                    box.name = "window-box"
                    box.components.set(InputTargetComponent())
                    box.generateCollisionShapes(recursive: false)
                    content.add(box)
                }
                .frame(width: 200, height: 160)
                .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { v in
                    note("entity tap \(v.entity.name) at \(f(v.location3D.x)) \(f(v.location3D.y)) \(f(v.location3D.z))")
                })
            }
        }
        .padding(30)
        .onAppear {
            log.notice("ycode-input: probe appeared")
            Task {
                let r = await openSpace(id: "space")
                log.notice("ycode-input: immersive space \(String(describing: r), privacy: .public)")
            }
        }
    }
}

struct SpaceView: View {
    @State private var session = ARKitSession()
    @State private var tracking = WorldTrackingProvider()

    var body: some View {
        RealityView { content in
            let sphere = ModelEntity(mesh: .generateSphere(radius: 0.2), materials: [SimpleMaterial(color: .yellow, isMetallic: false)])
            sphere.name = "space-sphere"
            sphere.position = [-1.0, 1.0, -1.6]
            sphere.components.set(InputTargetComponent())
            sphere.generateCollisionShapes(recursive: false)
            content.add(sphere)
            log.notice("ycode-input: immersive content made")
        }
        .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { v in
            log.notice("ycode-input: entity tap \(v.entity.name, privacy: .public) at \(f(v.location3D.x), privacy: .public) \(f(v.location3D.y), privacy: .public) \(f(v.location3D.z), privacy: .public)")
        })
        .task {
            do {
                try await session.run([tracking])
                log.notice("ycode-input: world tracking \(String(describing: tracking.state), privacy: .public)")
            } catch {
                log.error("ycode-input: world tracking failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            var lastP = SIMD3<Float>(repeating: .nan), n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let a = tracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { continue }
                let m = a.originFromAnchorTransform
                let p = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                let fwd = -SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
                n += 1
                if !(simd_distance(p, lastP) < 0.001) || n % 20 == 0 {
                    lastP = p
                    log.notice("ycode-input: device anchor position \(f(p.x), privacy: .public) \(f(p.y), privacy: .public) \(f(p.z), privacy: .public) forward \(f(fwd.x), privacy: .public) \(f(fwd.y), privacy: .public) \(f(fwd.z), privacy: .public) tracked \(a.isTracked, privacy: .public)")
                }
            }
        }
    }
}
