// Graphics pipeline libraries (VK_EXT_graphics_pipeline_library) for
// render pipelines. A render pipeline is linked from four parts, each
// cached by what it depends on:
//
//   vertex input        vertex descriptor + topology class
//   pre-rasterization   the vertex function's SPIR-V
//   fragment shader     the fragment function's SPIR-V + sample count
//   fragment output     attachment formats + blend state + sample count
//
// The fragment-shader part is the expensive one on the Thor (NVIDIA's
// compiler costs ~3 ms per branch; QuartzCore's uber-shaders take seconds),
// and many Metal pipelines share a fragment function with different blend
// state, formats or topology: with libraries it is compiled once per
// fragment function, and every pipeline is a fast link (milliseconds).
// Parts are never destroyed before shutdown (their number is bounded by
// the distinct functions and states). YCODE_VULKAN_NO_PIPELINE_LIBRARY=1
// turns the path off (CVulkan.c); YCODE_VULKAN_LIBRARY_LTO=1 links with
// link-time optimization (slower links, for comparison).

import CVulkan
import Foundation

/// The library parts, with in-flight builds so that concurrent workers do
/// not compile the same part twice.
final class PipelineLibraryCache: @unchecked Sendable {
    let lock = NSLock()
    var parts: [String: VkPipeline] = [:]
    var failed: Set<String> = []
    var building: [String: DispatchGroup] = [:]
    var stats = PipelineLibraryStatistics()

    /// The part for `key`, built by `build` once (outside the lock).
    func part(_ key: String, kind: Int, _ build: () -> VkPipeline?) -> VkPipeline? {
        while true {
            lock.lock()
            if let p = parts[key] { stats.hits[kind] += 1; lock.unlock(); return p }
            if failed.contains(key) { lock.unlock(); return nil }
            if let g = building[key] {
                lock.unlock()
                g.wait()
                continue
            }
            let g = DispatchGroup()
            g.enter()
            building[key] = g
            lock.unlock()
            let start = DispatchTime.now().uptimeNanoseconds
            let p = build()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            lock.lock()
            if let p { parts[key] = p } else { failed.insert(key) }
            building[key] = nil
            stats.builds[kind] += 1
            stats.buildMilliseconds[kind] += ms
            stats.maxBuildMilliseconds[kind] = max(stats.maxBuildMilliseconds[kind], ms)
            lock.unlock()
            g.leave()
            return p
        }
    }

    func all() -> [VkPipeline] {
        lock.lock(); defer { lock.unlock() }
        return Array(parts.values)
    }
}

/// Counters per part kind: 0 vertex input, 1 pre-rasterization, 2 fragment shader, 3 fragment output, 4 link.
public struct PipelineLibraryStatistics: Sendable {
    public static let kinds = ["vertex input", "pre-rasterization", "fragment shader", "fragment output", "link"]
    public var builds = [Int](repeating: 0, count: 5)
    public var hits = [Int](repeating: 0, count: 5)
    public var buildMilliseconds = [Double](repeating: 0, count: 5)
    public var maxBuildMilliseconds = [Double](repeating: 0, count: 5)

    public var summary: String {
        (0..<5).map { k in
            String(format: "%@: %d built (%.1f ms total, max %.1f ms), %d reused", Self.kinds[k], builds[k],
                   buildMilliseconds[k], maxBuildMilliseconds[k], hits[k])
        }.joined(separator: "; ")
    }
}

extension VulkanMetalBackend {
    /// Whether render pipelines are linked from library parts.
    var usesPipelineLibraries: Bool { ctx.pointee.features.graphicsPipelineLibrary != 0 }

    /// A copy of the pipeline-library counters, taken under the libraries' lock.
    public var pipelineLibraryStatistics: PipelineLibraryStatistics {
        libraries.lock.lock(); defer { libraries.lock.unlock() }
        return libraries.stats
    }

    /// A render pipeline variant linked from cached library parts. Needs no backend lock.
    func linkRenderVariant(_ p: VKRenderPipeline, vertex: TranslatedShader, topologyClass cls: UInt32) -> VkPipeline? {
        var info = p.info
        info.topology = vkTopology(forClass: cls)
        var err = [CChar](repeating: 0, count: 512)
        func fail(_ what: String) -> VkPipeline? {
            log("render pipeline (\(p.desc.label ?? "unlabelled")): \(what): \(cString(err))")
            return nil
        }

        // Vertex input: the raw bytes of the binding and attribute arrays plus counts and topology.
        let viKey = "vi:" + bytesKey(&info.bindings, Int(info.bindingCount) * MemoryLayout<yvk_vertex_binding>.stride) + "/" +
            bytesKey(&info.attributes, Int(info.attributeCount) * MemoryLayout<VkVertexInputAttributeDescription>.stride) +
            "/\(info.bindingCount)/\(info.attributeCount)/\(info.topology.rawValue)"
        guard let vi = libraries.part(viKey, kind: 0, { yvk_library_vertex_input(ctx, &info, &err, err.count) }) else {
            return fail("vertex input")
        }

        let discard = p.fragment == nil
        let vsKey = "vs:\(shaderKey(vertex))/\(discard)"
        let vsEntry = vertex.reflection.entryPoint ?? "main"
        guard let pre = libraries.part(vsKey, kind: 1, {
            vertex.spirv.withUnsafeBufferPointer { words in
                vsEntry.withCString { name in
                    var stage = yvk_shader_stage(code: words.baseAddress, wordCount: words.count, entry: name,
                                                 constants: nil, constantCount: 0, flags: 0)
                    return yvk_library_pre_raster(ctx, &stage, discard ? 1 : 0, &err, err.count)
                }
            }
        }) else { return fail("pre-rasterization") }

        var parts: [VkPipeline?] = [vi, pre]
        if let fragment = p.fragment {
            let fsKey = "fs:\(shaderKey(fragment))/\(info.samples.rawValue)"
            let fsEntry = fragment.reflection.entryPoint ?? "main"
            let samples = info.samples
            guard let fsLib = libraries.part(fsKey, kind: 2, {
                fragment.spirv.withUnsafeBufferPointer { words in
                    fsEntry.withCString { name in
                        var stage = yvk_shader_stage(code: words.baseAddress, wordCount: words.count, entry: name,
                                                     constants: nil, constantCount: 0, flags: 0)
                        return yvk_library_fragment_shader(ctx, &stage, samples, &err, err.count)
                    }
                }
            }) else { return fail("fragment shader") }
            let foKey = "fo:" + bytesKey(&info.colorFormats, MemoryLayout.size(ofValue: info.colorFormats)) + "/" +
                bytesKey(&info.blend, MemoryLayout.size(ofValue: info.blend)) +
                "/\(info.colorCount)/\(info.depthFormat.rawValue)/\(info.stencilFormat.rawValue)/\(info.samples.rawValue)/\(info.alphaToCoverage)"
            guard let fo = libraries.part(foKey, kind: 3, { yvk_library_fragment_output(ctx, &info, &err, err.count) }) else {
                return fail("fragment output")
            }
            parts += [fsLib, fo]
        }
        let optimize = Self.environmentLibraryLTO
        let start = DispatchTime.now().uptimeNanoseconds
        let linked = parts.withUnsafeBufferPointer { yvk_library_link(ctx, $0.baseAddress, UInt32($0.count), optimize ? 1 : 0, &err, err.count) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        libraries.lock.lock()
        libraries.stats.builds[4] += 1
        libraries.stats.buildMilliseconds[4] += ms
        libraries.stats.maxBuildMilliseconds[4] = max(libraries.stats.maxBuildMilliseconds[4], ms)
        libraries.lock.unlock()
        return linked ?? fail("link")
    }

    static let environmentLibraryLTO = ProcessInfo.processInfo.environment["YCODE_VULKAN_LIBRARY_LTO"] != nil

    func shaderKey(_ s: TranslatedShader) -> String {
        // FNV-1a over 32-bit words (4× fewer steps than over bytes).
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for w in s.spirv { h = (h ^ UInt64(w)) &* 0x0000_0100_0000_01B3 }
        return "\(String(h, radix: 16))-\(s.spirv.count)-\(s.reflection.entryPoint ?? "main")"
    }

    func bytesKey<T>(_ value: inout T, _ count: Int) -> String {
        withUnsafeBytes(of: &value) { raw in
            String(fnv1a64([UInt8](raw.prefix(min(count, raw.count)))), radix: 16)
        }
    }
}
