// StereoProbe: our own black-box probe of how many views the visionOS simulator gives a
// CompositorServices layer (Ycode dirty-room observation, OBS-VISION-STEREO 2026-11-01).
// Opens a full immersive space with a CompositorLayer and logs (stdout + os_log, prefix "SP:"):
// the layer capabilities (layouts, foveation, formats), the configuration it got, the
// properties (view count, texture topologies), and per frame for the first frames and
// then every 120th: drawable count, views (transform, tangents, texture map), texture
// sizes/array lengths, depth range, projection per view, device anchor.
// Each view is cleared to its own colour (view 0 red, view 1 green, others blue), and a
// small white square is drawn at a world point 2 m in front so a stereo pair would show
// parallax. Launch args: -layout dedicated|shared|layered (default layered), -fov (foveation when supported),
// -fovforce (ask for foveation even when unsupported; logs each drawable's rate maps; OBS-VISION-RRM).
import ARKit
import CompositorServices
import Metal
import QuartzCore
import SwiftUI
import os

let log = Logger(subsystem: "dev.ycode.stereoprobe", category: "probe")
func say(_ s: String) { print("SP: " + s); fflush(stdout); log.notice("SP: \(s, privacy: .public)") }
func m4(_ m: simd_float4x4) -> String {
    let c = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
    return "[" + c.map { String(format: "(%.4f %.4f %.4f %.4f)", $0.x, $0.y, $0.z, $0.w) }.joined(separator: " ") + "]"
}
func arg(_ k: String) -> String? {
    let a = CommandLine.arguments; if let i = a.firstIndex(of: k), i + 1 < a.count { return a[i + 1] }; return nil
}

struct Cfg: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        say("caps supportsFoveation=\(capabilities.supportsFoveation)")
        say("caps layouts(none)=\(capabilities.supportedLayouts(options: []).map { $0.rawValue }) layouts(foveation)=\(capabilities.supportedLayouts(options: .foveationEnabled).map { $0.rawValue })")
        say("caps colorFormats=\(capabilities.supportedColorFormats.map { $0.rawValue }) depthFormats=\(capabilities.supportedDepthFormats.map { $0.rawValue })")
        say("caps objc=\(String(describing: capabilities))")
        say("config initial layout=\(configuration.layout.rawValue) color=\(configuration.colorFormat.rawValue) depth=\(configuration.depthFormat.rawValue) foveation=\(configuration.isFoveationEnabled)")
        switch arg("-layout") {
        case "dedicated": configuration.layout = .dedicated
        case "shared": configuration.layout = .shared
        default: configuration.layout = .layered
        }
        // -fovforce (OBS-VISION-RRM): ask for foveation even when the capabilities say it is unsupported
        configuration.isFoveationEnabled = (CommandLine.arguments.contains("-fov") && capabilities.supportsFoveation) || CommandLine.arguments.contains("-fovforce")
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
        say("config chosen layout=\(configuration.layout.rawValue) foveation=\(configuration.isFoveationEnabled)")
        do {
            let p = try LayerRenderer.Properties(configuration: configuration)
            say("props(config) viewCount=\(p.viewCount) topologies=\(p.textureTopologies.map { "array \($0.arrayLength) type \($0.textureType.rawValue)" })")
        } catch { say("props(config) failed: \(error)") }
    }
}

final class Renderer {
    let lr: LayerRenderer; let dev: MTLDevice; let q: MTLCommandQueue
    let session = ARKitSession(); let world = WorldTrackingProvider()
    var pso: MTLRenderPipelineState?
    init(_ lr: LayerRenderer) {
        self.lr = lr; dev = lr.device; q = dev.makeCommandQueue()!
        say("device \(dev.name) ampl2=\(dev.supportsVertexAmplificationCount(2))")
        let p = lr.properties
        say("props(layer) viewCount=\(p.viewCount) topologies=\(p.textureTopologies.map { "array \($0.arrayLength) type \($0.textureType.rawValue)" }) layout=\(lr.configuration.layout.rawValue)")
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p [[position]]; };
        vertex V vs(uint vid [[vertex_id]], constant float4x4 &mvp [[buffer(0)]]) {
          float2 c[6] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,-1),float2(1,1),float2(-1,1)};
          V o; o.p = mvp * float4(c[vid] * 0.1, 0, 1); return o; }
        fragment half4 fs(V i [[stage_in]]) { return half4(1,1,1,1); }
        """
        do {
            let lib = try dev.makeLibrary(source: src, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vs"); d.fragmentFunction = lib.makeFunction(name: "fs")
            d.colorAttachments[0].pixelFormat = lr.configuration.colorFormat
            d.depthAttachmentPixelFormat = lr.configuration.depthFormat
            pso = try dev.makeRenderPipelineState(descriptor: d)
        } catch { say("pso error \(error)") }
    }
    func run() {
        Task { do { try await session.run([world]); say("ARKit run ok") } catch { say("ARKit error \(error)") } }
        var n = 0
        while true {
            switch lr.state {
            case .paused: say("state paused"); lr.waitUntilRunning(); continue
            case .running: break
            case .invalidated: say("state invalidated"); return
            @unknown default: return
            }
            autoreleasepool {
                guard let frame = lr.queryNextFrame() else { return }
                frame.startUpdate(); frame.endUpdate()
                guard let timing = frame.predictTiming() else { return }
                LayerRenderer.Clock().wait(until: timing.optimalInputTime)
                frame.startSubmission()
                let ds = frame.queryDrawables()
                let verbose = n < 4 || n % 120 == 0
                if verbose { say("frame \(n) index \(frame.frameIndex) drawables \(ds.count)") }
                for (di, d) in ds.enumerated() {
                    let dd = LayerRenderer.Clock.Instant.epoch.duration(to: d.frameTiming.presentationTime); let t = Double(dd.components.seconds) + Double(dd.components.attoseconds) * 1e-18
                    d.deviceAnchor = world.queryDeviceAnchor(atTimestamp: t)
                    if verbose {
                        say(" drawable \(di) target \(d.target) views \(d.views.count) targetViewCount \(frame.drawableTargetViewCount(target: d.target)) depthRange \(d.depthRange) colorTextures \(d.colorTextures.map { "\($0.width)x\($0.height) array \($0.arrayLength) type \($0.textureType.rawValue) fmt \($0.pixelFormat.rawValue)" }) depthTextures \(d.depthTextures.map { "\($0.width)x\($0.height) array \($0.arrayLength)" }) rrm \(d.rasterizationRateMaps.count)")
                        for (mi, m) in d.rasterizationRateMaps.enumerated() {
                            say("  rrm \(mi) screen \(m.screenSize.width)x\(m.screenSize.height) layers \(m.layerCount) granularity \(m.physicalGranularity.width)x\(m.physicalGranularity.height) physical0 \(m.physicalSize(layer: 0).width)x\(m.physicalSize(layer: 0).height)")
                        }
                        if let a = d.deviceAnchor { say("  anchor \(m4(a.originFromAnchorTransform))") } else { say("  anchor nil") }
                        for (vi, v) in d.views.enumerated() {
                            let tm = v.textureMap
                            say("  view \(vi) transform \(m4(v.transform)) tangents \(v.tangents) tex \(tm.textureIndex) slice \(tm.sliceIndex) viewport (\(tm.viewport.originX), \(tm.viewport.originY), \(tm.viewport.width), \(tm.viewport.height))")
                            say("  view \(vi) projection \(m4(d.computeProjection(viewIndex: vi)))")
                        }
                    }
                    guard let cb = q.makeCommandBuffer() else { continue }
                    let device = d.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
                    for (vi, v) in d.views.enumerated() {
                        let tm = v.textureMap
                        let rp = MTLRenderPassDescriptor()
                        rp.colorAttachments[0].texture = d.colorTextures[tm.textureIndex]
                        rp.colorAttachments[0].slice = tm.sliceIndex
                        rp.colorAttachments[0].loadAction = (lr.configuration.layout == .shared && vi > 0) ? .load : .clear
                        rp.colorAttachments[0].clearColor = vi == 0 ? MTLClearColor(red: 0.6, green: 0, blue: 0, alpha: 1) : vi == 1 ? MTLClearColor(red: 0, green: 0.6, blue: 0, alpha: 1) : MTLClearColor(red: 0, green: 0, blue: 0.6, alpha: 1)
                        rp.colorAttachments[0].storeAction = .store
                        rp.depthAttachment.texture = d.depthTextures[tm.textureIndex]
                        rp.depthAttachment.slice = tm.sliceIndex
                        rp.depthAttachment.loadAction = rp.colorAttachments[0].loadAction
                        rp.depthAttachment.clearDepth = 0; rp.depthAttachment.storeAction = .store
                        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { continue }
                        enc.setViewport(tm.viewport)
                        if let pso = pso {
                            // world point (0, 1.5, -2): model at that point, view = (device * view.transform)^-1
                            var model = matrix_identity_float4x4; model.columns.3 = SIMD4<Float>(0, 1.5, -2, 1)
                            var mvp = d.computeProjection(viewIndex: vi) * (device * v.transform).inverse * model
                            enc.setRenderPipelineState(pso)
                            enc.setVertexBytes(&mvp, length: 64, index: 0)
                            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                        }
                        enc.endEncoding()
                    }
                    d.encodePresent(commandBuffer: cb)
                    cb.commit()
                }
                frame.endSubmission()
                n += 1
            }
        }
    }
}

struct MainView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    var body: some View {
        Text("StereoProbe").font(.title).padding(30)
            .task {
                say("launched args=\(CommandLine.arguments)")
                let r = await openImmersiveSpace(id: "cl"); say("open cl -> \(r)")
            }
    }
}

@main struct StereoProbeApp: App {
    var body: some Scene {
        WindowGroup { MainView() }
        ImmersiveSpace(id: "cl") {
            CompositorLayer(configuration: Cfg()) { lr in
                say("layer renderer created")
                let t = Thread { Renderer(lr).run() }
                t.name = "SP render"; t.start()
            }
        }.immersionStyle(selection: .constant(.full), in: .full)
    }
}
