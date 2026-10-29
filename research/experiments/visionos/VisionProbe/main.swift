// VisionProbe: our own black-box probe for the visionOS simulator (Ycode,
// dirty-room observation; see research/notes/visionos-observations.md).
//
// On launch it prints (stdout and os_log, prefix "VP:"):
//   - device identity (UIDevice, a few SIMULATOR_* variables),
//   - what the guest's Metal device reports (families, limits, the features a
//     visionOS renderer relies on: vertex amplification, rasterization-rate maps),
//   - ARKit provider support and authorization state,
// then opens a window, a volume and an immersive space with RealityKit
// entities, runs an ARKitSession with world tracking inside the immersive
// space and prints the device (head) pose once a second.
//
// Launch argument "-noImmersive" skips the volume and the immersive space.

import ARKit
import Metal
import QuartzCore
import RealityKit
import SwiftUI
import UIKit
import os

let log = Logger(subsystem: "dev.ycode.visionprobe", category: "probe")

func say(_ s: String) {
    print("VP: " + s)
    fflush(stdout)
    log.notice("VP: \(s, privacy: .public)")
}

func f3(_ v: SIMD4<Float>) -> String { String(format: "(%.3f, %.3f, %.3f)", v.x, v.y, v.z) }

func reportDevice() {
    let d = UIDevice.current
    say("UIDevice model=\(d.model) systemName=\(d.systemName) systemVersion=\(d.systemVersion) idiom=\(d.userInterfaceIdiom.rawValue)")
    let env = ProcessInfo.processInfo.environment
    for k in ["SIMULATOR_MODEL_IDENTIFIER", "SIMULATOR_MAINSCREEN_WIDTH", "SIMULATOR_MAINSCREEN_HEIGHT", "SIMULATOR_MAINSCREEN_SCALE", "SIMULATOR_RUNTIME_BUILD_VERSION"] {
        say("env \(k)=\(env[k] ?? "-")")
    }
}

func reportMetal() {
    guard let dev = MTLCreateSystemDefaultDevice() else { say("Metal: no device"); return }
    say("Metal name=\(dev.name) unified=\(dev.hasUnifiedMemory)")
    var fam: [String] = []
    let families: [(String, MTLGPUFamily)] = [
        ("apple1", .apple1), ("apple2", .apple2), ("apple3", .apple3), ("apple4", .apple4),
        ("apple5", .apple5), ("apple6", .apple6), ("apple7", .apple7), ("apple8", .apple8),
        ("apple9", .apple9), ("apple10", .apple10), ("common1", .common1), ("common2", .common2),
        ("common3", .common3), ("mac2", .mac2), ("metal3", .metal3),
    ]
    for (n, f) in families where dev.supportsFamily(f) { fam.append(n) }
    say("Metal families=\(fam.joined(separator: ","))")
    let t = dev.maxThreadsPerThreadgroup
    say("Metal maxThreadsPerThreadgroup=\(t.width)x\(t.height)x\(t.depth) maxBuffer=\(dev.maxBufferLength) workingSet=\(dev.recommendedMaxWorkingSetSize) maxTGMem=\(dev.maxThreadgroupMemoryLength) argBufTier=\(dev.argumentBuffersSupport.rawValue) rwTexTier=\(dev.readWriteTextureSupport.rawValue)")
    say("Metal raytracing=\(dev.supportsRaytracing) dynamicLibs=\(dev.supportsDynamicLibraries) functionPointers=\(dev.supportsFunctionPointers) bc=\(dev.supportsBCTextureCompression) float32Filter=\(dev.supports32BitFloatFiltering) shaderBarycentric=\(dev.supportsShaderBarycentricCoordinates) pullModel=\(dev.supportsPullModelInterpolation)")
    say("Metal vertexAmplification1=\(dev.supportsVertexAmplificationCount(1)) 2=\(dev.supportsVertexAmplificationCount(2)) rasterRateMap1=\(dev.supportsRasterizationRateMap(layerCount: 1)) rasterRateMap2=\(dev.supportsRasterizationRateMap(layerCount: 2)) sampleCount4=\(dev.supportsTextureSampleCount(4)) maxViewports=?")
}

func reportARKitSupport() {
    let rows: [(String, Bool, [ARKitSession.AuthorizationType])] = [
        ("WorldTracking", WorldTrackingProvider.isSupported, WorldTrackingProvider.requiredAuthorizations),
        ("HandTracking", HandTrackingProvider.isSupported, HandTrackingProvider.requiredAuthorizations),
        ("PlaneDetection", PlaneDetectionProvider.isSupported, PlaneDetectionProvider.requiredAuthorizations),
        ("SceneReconstruction", SceneReconstructionProvider.isSupported, SceneReconstructionProvider.requiredAuthorizations),
        ("ImageTracking", ImageTrackingProvider.isSupported, ImageTrackingProvider.requiredAuthorizations),
        ("ObjectTracking", ObjectTrackingProvider.isSupported, ObjectTrackingProvider.requiredAuthorizations),
        ("RoomTracking", RoomTrackingProvider.isSupported, RoomTrackingProvider.requiredAuthorizations),
        ("EnvironmentLightEstimation", EnvironmentLightEstimationProvider.isSupported, EnvironmentLightEstimationProvider.requiredAuthorizations),
        ("StereoProperties", StereoPropertiesProvider.isSupported, StereoPropertiesProvider.requiredAuthorizations),
        ("VisualFidelity", VisualFidelityProvider.isSupported, VisualFidelityProvider.requiredAuthorizations),
        ("AccessoryTracking", AccessoryTrackingProvider.isSupported, AccessoryTrackingProvider.requiredAuthorizations),
        ("SharedCoordinateSpace", SharedCoordinateSpaceProvider.isSupported, SharedCoordinateSpaceProvider.requiredAuthorizations),
        ("BarcodeDetection", BarcodeDetectionProvider.isSupported, BarcodeDetectionProvider.requiredAuthorizations),
        ("CameraFrame", CameraFrameProvider.isSupported, CameraFrameProvider.requiredAuthorizations),
        ("CameraRegion", CameraRegionProvider.isSupported, CameraRegionProvider.requiredAuthorizations),
    ]
    for (n, s, a) in rows { say("ARKit \(n) isSupported=\(s) requiredAuthorizations=\(a)") }
}

@MainActor
final class ProbeState: ObservableObject {
    let session = ARKitSession()
    let world = WorldTrackingProvider()
    var started = false

    func runTracking() async {
        guard !started else { return }
        started = true
        let auth = await session.queryAuthorization(for: [.handTracking, .worldSensing])
        say("ARKit queryAuthorization \(auth)")
        var providers: [any DataProvider] = [world]
        let stereo = StereoPropertiesProvider()
        if StereoPropertiesProvider.isSupported { providers.append(stereo) }
        do {
            try await session.run(providers)
            say("ARKit session.run ok providers=\(providers.count)")
        } catch {
            say("ARKit session.run error \(error)")
            return
        }
        Task {
            for await ev in session.events { say("ARKit event \(ev)") }
        }
        for i in 0..<30 {
            try? await Task.sleep(for: .seconds(1))
            let a = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
            if let a {
                let m = a.originFromAnchorTransform
                say("pose[\(i)] tracked=\(a.isTracked) state=\(a.trackingState) pos=\(f3(m.columns.3)) fwd=\(f3(-m.columns.2)) worldState=\(world.state)")
            } else {
                say("pose[\(i)] nil worldState=\(world.state)")
            }
            if i == 2, StereoPropertiesProvider.isSupported {
                say("stereo latestViewpointProperties=\(String(describing: stereo.latestViewpointProperties))")
            }
        }
    }
}

struct MainView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    var body: some View {
        VStack(spacing: 20) {
            Text("VisionProbe").font(.extraLargeTitle)
            Text("Ycode black-box probe").font(.title)
            Button("Tap me") { say("button tapped") }
        }
        .padding(40)
        .task {
            reportDevice()
            reportMetal()
            reportARKitSupport()
            if CommandLine.arguments.contains("-noImmersive") { return }
            try? await Task.sleep(for: .seconds(2))
            openWindow(id: "volume")
            say("opened volume")
            try? await Task.sleep(for: .seconds(3))
            let r = await openImmersiveSpace(id: "immersive")
            say("openImmersiveSpace result=\(r)")
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { say("main window size \($0)") }
    }
}

struct VolumeView: View {
    var body: some View {
        RealityView { content in
            let box = ModelEntity(mesh: .generateBox(size: 0.2, cornerRadius: 0.02),
                                  materials: [SimpleMaterial(color: .systemOrange, isMetallic: true)])
            box.components.set(InputTargetComponent())
            box.generateCollisionShapes(recursive: false)
            content.add(box)
            say("volume RealityView make ok")
        }
        .gesture(TapGesture().targetedToAnyEntity().onEnded { v in say("entity tapped \(v.entity.name)") })
    }
}

struct ImmersiveView: View {
    @StateObject var state = ProbeState()
    var body: some View {
        RealityView { content in
            let s = ModelEntity(mesh: .generateSphere(radius: 0.25),
                                materials: [SimpleMaterial(color: .systemBlue, isMetallic: false)])
            s.position = [0, 1.5, -1.5]
            content.add(s)
            say("immersive RealityView make ok")
        }
        .task { await state.runTracking() }
    }
}

@main
struct VisionProbeApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup(id: "main") { MainView() }
        WindowGroup(id: "volume") { VolumeView() }
            .windowStyle(.volumetric)
            .defaultSize(width: 0.4, height: 0.4, depth: 0.4, in: .meters)
        ImmersiveSpace(id: "immersive") { ImmersiveView() }
    }
}
