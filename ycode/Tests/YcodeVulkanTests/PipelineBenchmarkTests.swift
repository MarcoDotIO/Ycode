// Pipeline creation times for QuartzCore's uber-shaders (the pipelines
// backboardd creates first), with and without graphics pipeline libraries,
// cold and warm. The runtime's QuartzCore metallib is read at run time
// (YCODE_TEST_QC_METALLIB; never copied into the repository); YCODE_AIRC
// translates. Run with __GL_SHADER_DISK_CACHE=0 so that "cold" is cold.

import Foundation
import Testing
@testable import YcodeMetalHost
@testable import YcodeVulkan

enum QCBench {
    static let env = ProcessInfo.processInfo.environment
    static let configured: Bool = {
        guard let a = env["YCODE_AIRC"], let m = env["YCODE_TEST_QC_METALLIB"] else { return false }
        return FileManager.default.isExecutableFile(atPath: a) && FileManager.default.fileExists(atPath: m)
    }()

    /// (vertex, fragment) pairs whose varyings match.
    static let pairs = [("fixed_vert_lph_spc", "fixed_frag_lph_cph"), ("fixed_vert_lph_gen", "fixed_frag_lph_cpf"),
                        ("fixed_vert_lpf_gen", "fixed_frag_lpf_cpf")]

    static func vertexFormat(_ type: String?) -> UInt32 {
        switch type ?? "" {
        case "float": return 28
        case "float2": return 29
        case "float3": return 30
        case "half": return 53
        case "half2": return 25
        case "half3": return 26
        case "half4": return 27
        case "int": return 32
        case "uint": return 36
        case "uchar4": return 3
        default: return 31
        }
    }
}

@Suite(.serialized, .enabled(if: QCBench.configured && VK.available, "needs YCODE_AIRC, YCODE_TEST_QC_METALLIB and a GPU"))
struct PipelineBenchmarkTests {
    @Test func quartzCoreUberShaders() throws {
        let lib = [UInt8](try Data(contentsOf: URL(fileURLWithPath: QCBench.env["YCODE_TEST_QC_METALLIB"]!)))
        let airc = AircProcessTranslator(executable: URL(fileURLWithPath: QCBench.env["YCODE_AIRC"]!))
        let translator = ProbeLibraryTranslator(airc: airc, library: lib)
        // Vertex inputs from the vertex functions' reflection.
        var inputs: [String: [ShaderReflection.VertexInput]] = [:]
        let t0 = Date()
        for (v, f) in QCBench.pairs {
            let vs = try translator.translate(TranslationRequest(metallib: Array("probe:\(v)".utf8)))
            inputs[v] = vs.reflection.vertexInputs ?? []
            // Translate the fragment function now (airc caches it), so the timings below are Vulkan's.
            let fs = try translator.translate(TranslationRequest(metallib: Array("probe:\(f)".utf8), linkVertexHash: vs.reflection.hash))
            print("translated \(v) + \(f): \(fs.spirv.count) SPIR-V words")
        }
        print(String(format: "translation of 3 pairs: %.2f s", Date().timeIntervalSince(t0)))
        let cacheDir = NSTemporaryDirectory() + "ycode-qcbench-\(getpid())"
        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cacheDir) }

        var report: [String] = []
        for useLibraries in [true, false] {
            if useLibraries { unsetenv("YCODE_VULKAN_NO_PIPELINE_LIBRARY") } else { setenv("YCODE_VULKAN_NO_PIPELINE_LIBRARY", "1", 1) }
            let cachePath = cacheDir + "/\(useLibraries ? "gpl" : "full").bin"
            for round in ["cold", "warm"] {
                var o = VulkanMetalBackend.Options()
                o.asynchronousPipelines = false  // time each creation
                o.pipelineCachePath = cachePath
                let b = VulkanMetalBackend(translator: translator, options: o)
                #expect(b.usesPipelineLibraries == useLibraries || !useLibraries)
                var times: [Double] = []
                var h: UInt64 = 1
                func next() -> MetalHandle { h += 1; return MetalHandle(h) }
                for (v, f) in QCBench.pairs {
                    let vf = next(), ff = next()
                    try b.createFunction(vf, metallib: Array("probe:\(v)".utf8))
                    try b.createFunction(ff, metallib: Array("probe:\(f)".utf8))
                    var vd = MetalVertexDescriptor()
                    for (i, input) in (inputs[v] ?? []).enumerated() {
                        var a = MetalVertexDescriptor.Attribute(index: input.location)
                        a.format = QCBench.vertexFormat(input.type)
                        a.bufferIndex = 20 + i
                        var l = MetalVertexDescriptor.Layout(bufferIndex: 20 + i)
                        l.stride = 16
                        vd.attributes.append(a)
                        vd.layouts.append(l)
                    }
                    for (format, blend) in [(MetalPixelFormat.bgra8Unorm, true), (MetalPixelFormat.rgba16Float, true),
                                            (MetalPixelFormat.bgra8Unorm, false)] {
                        var desc = MetalRenderPipelineDescriptor()
                        desc.label = "\(f) \(format) \(blend ? "over" : "copy")"
                        desc.vertexFunction = vf
                        desc.fragmentFunction = ff
                        desc.vertexDescriptor = vd.attributes.isEmpty ? nil : vd
                        var c = MetalColorAttachmentDescriptor(index: 0)
                        c.pixelFormat = format
                        c.blendingEnabled = blend
                        c.destinationRGBBlendFactor = 5
                        c.destinationAlphaBlendFactor = 5
                        desc.colorAttachments = [c]
                        let start = Date()
                        try b.createRenderPipeline(next(), desc)
                        times.append(Date().timeIntervalSince(start))
                    }
                }
                let line = String(format: "%@ %@: 9 pipelines %.2f s total, first %.2f s, max %.2f s, per pipeline %@",
                                  useLibraries ? "libraries" : "full pipelines", round, times.reduce(0, +), times[0],
                                  times.max() ?? 0, times.map { String(format: "%.0f", $0 * 1000) }.joined(separator: "/") + " ms")
                print(line)
                report.append(line)
                if useLibraries { print("  \(b.pipelineLibraryStatistics.summary)") }
                b.shutdown()
            }
        }
        unsetenv("YCODE_VULKAN_NO_PIPELINE_LIBRARY")
        #expect(report.count == 4)
    }
}
