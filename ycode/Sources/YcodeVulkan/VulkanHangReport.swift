// GPU hang and device-loss reports (diagnostics; stage8-contract.md §15).
//
// A submission that runs longer than `Options.hangReportSeconds` is logged
// once with a description of its Metal command buffer: every pass with its
// attachments and every draw, dispatch and blit with its pipeline, counts
// and bound resources. On device loss the back end logs the same for the
// submissions still pending and, when the device has
// VK_NV_device_diagnostic_checkpoints (`YCODE_GPU_CHECKPOINTS=0` turns it
// off), the last checkpoint markers the queue passed at the top and bottom
// of the pipe: which command of which command buffer was running.
//
// Markers: (recording id << 32) | (pass << 20) | command. Pass 4095 is the
// prologue (IOSurface copy-ins, command 0) and epilogue (copy-outs, command
// 1); command 0xFFFFF is the pass's begin.

import CVulkan
import Foundation
import YcodeMetalHost

/// A recorded command buffer the checkpoint markers can name.
struct CheckpointRecord {
    var id: UInt32
    var process: MetalProcessID
    var commandBufferRef: UInt64
    var commandBuffer: MetalCommandBuffer?
}

extension VulkanMetalBackend {
    static let checkpointPrologue = 4095
    static let checkpointPassBegin = 0xFFFFF

    var checkpointsOn: Bool { ctx.pointee.features.diagnosticCheckpoints != 0 }

    /// A checkpoint marker in `rec` (nothing without the extension).
    func checkpoint(_ rec: Recording, pass: Int, command: Int) {
        guard checkpointsOn else { return }
        let marker = UInt64(rec.checkpointID) << 32 | UInt64(min(pass, 4095)) << 20 | UInt64(min(command, 0xFFFFF))
        yvk_cmd_checkpoint(rec.cb, marker)
    }

    /// Notes which command buffer a recording's markers belong to. Under the lock.
    func registerCheckpoints(_ rec: Recording, _ mcb: MetalCommandBuffer) {
        guard checkpointsOn else { return }
        checkpointRecords.append(CheckpointRecord(id: rec.checkpointID, process: mcb.process,
                                                  commandBufferRef: mcb.commandBufferRef, commandBuffer: mcb))
        if checkpointRecords.count > 128 { checkpointRecords.removeFirst(checkpointRecords.count - 128) }
    }

    /// What a marker points at. Under the lock.
    func describeMarker(_ marker: UInt64) -> String {
        let id = UInt32(truncatingIfNeeded: marker >> 32)
        let pass = Int((marker >> 20) & 0xFFF), command = Int(marker & 0xFFFFF)
        let where_: String
        if pass == Self.checkpointPrologue {
            where_ = command == 0 ? "IOSurface copy-ins" : "IOSurface copy-outs"
        } else if command == Self.checkpointPassBegin {
            where_ = "pass \(pass) begin"
        } else {
            where_ = "pass \(pass) command \(command)"
        }
        guard let r = checkpointRecords.last(where: { $0.id == id }) else { return "recording \(id) (unknown): \(where_)" }
        var text = "process \(r.process) command buffer \(r.commandBufferRef) (recording \(id)): \(where_)"
        if pass != Self.checkpointPrologue, command != Self.checkpointPassBegin, let mcb = r.commandBuffer,
           pass < mcb.passes.count {
            text += " = " + describeCommand(mcb.passes[pass], command)
        }
        return text
    }

    /// One command of a pass, for a marker.
    func describeCommand(_ pass: MetalPass, _ index: Int) -> String {
        switch pass {
        case .render(let p): return index < p.commands.count ? "\(p.commands[index])" : "?"
        case .compute(let c): return index < c.count ? "\(c[index])" : "?"
        case .blit(let c): return index < c.count ? "\(c[index])" : "?"
        default: return "?"
        }
    }

    // MARK: Command-buffer descriptions

    func describeTexture(_ h: MetalHandle?) -> String {
        guard let h else { return "nil" }
        guard let t = textures[h] else { return "t\(h.raw)?" }
        let (w, hh, d) = t.levelSize(0)
        var s = "t\(h.raw) \(w)x\(hh)" + (d > 1 ? "x\(d)" : "") + " fmt \(t.metalFormat)"
        if t.image.samples > 1 { s += " ×\(t.image.samples)" }
        if t.levelCount > 1 { s += " mips \(t.levelCount)" }
        if let surface = t.image.surface { s += " surface \(surface.surfaceID)" }
        return s
    }

    func describeBuffer(_ h: MetalHandle?, _ offset: Int) -> String {
        guard let h else { return "nil" }
        guard let b = buffers[h] else { return "b\(h.raw)?" }
        return "b\(h.raw) \(b.length) B" + (offset != 0 ? " @\(offset)" : "") + (b.storage == .private ? " private" : "")
    }

    func describePipeline(_ h: MetalHandle?) -> String {
        guard let h else { return "no pipeline" }
        guard let p = renderPipelines[h] else { return "pipeline \(h.raw)?" }
        var s = "\(shaderName(p.vertex))+\(shaderName(p.fragment))"
        if p.broken { s += " (broken)" }
        if !p.isBuilt { s += " (not built)" }
        return s
    }

    /// A description of a command buffer for a hang report (at most
    /// `limit` commands with work). Under the lock.
    func describeCommandBuffer(_ mcb: MetalCommandBuffer, limit: Int = 48) -> String {
        var lines: [String] = []
        var budget = limit
        for (pi, pass) in mcb.passes.enumerated() {
            switch pass {
            case .render(let p):
                var head = "pass \(pi) render"
                if let d = p.descriptor {
                    for c in d.colorAttachments {
                        head += " c\(c.index)[\(describeTexture(c.texture)) load \(c.attachment.loadAction) store \(c.attachment.storeAction)"
                            + (c.resolveTexture != nil ? " resolve \(describeTexture(c.resolveTexture))" : "") + "]"
                    }
                    if let a = d.depth { head += " depth[\(describeTexture(a.texture)) load \(a.loadAction)]" }
                    if let a = d.stencil { head += " stencil[\(describeTexture(a.texture)) load \(a.loadAction)]" }
                    head += " target \(d.renderTargetWidth)x\(d.renderTargetHeight)"
                } else {
                    head += " (no descriptor)"
                }
                lines.append(head)
                var pipeline: MetalHandle?
                var vb: [Int: (MetalHandle?, Int)] = [:], fb: [Int: (MetalHandle?, Int)] = [:]
                var vt: [Int: MetalHandle?] = [:], ft: [Int: MetalHandle?] = [:]
                var viewport = "", scissor = ""
                func bindings() -> String {
                    let b = vb.sorted { $0.key < $1.key }.map { "v\($0.key)=\(describeBuffer($0.value.0, $0.value.1))" }
                        + fb.sorted { $0.key < $1.key }.map { "f\($0.key)=\(describeBuffer($0.value.0, $0.value.1))" }
                        + vt.sorted { $0.key < $1.key }.map { "vt\($0.key)=\(describeTexture($0.value))" }
                        + ft.sorted { $0.key < $1.key }.map { "ft\($0.key)=\(describeTexture($0.value))" }
                    return b.joined(separator: ", ")
                }
                for (ci, c) in p.commands.enumerated() {
                    switch c {
                    case .setRenderPipelineState(let h): pipeline = h
                    case .setBuffer(let s, let i, let b, let o): if s == .vertex { vb[i] = (b, o) } else { fb[i] = (b, o) }
                    case .setBufferOffset(let s, let i, let o):
                        if s == .vertex { vb[i] = (vb[i]?.0, o) } else { fb[i] = (fb[i]?.0, o) }
                    case .setTexture(let s, let i, let t): if s == .vertex { vt[i] = t } else { ft[i] = t }
                    case .setViewport(let v): viewport = String(format: " vp %.0f,%.0f %.0fx%.0f", v.x, v.y, v.width, v.height)
                    case .setScissorRect(let r): scissor = " sc \(r.x),\(r.y) \(r.width)x\(r.height)"
                    case .draw(let d):
                        guard budget > 0 else { continue }
                        budget -= 1
                        lines.append("  \(ci): draw \(describePipeline(pipeline)) prim \(d.primitiveType) start \(d.vertexStart) count \(d.vertexCount) "
                                     + "instances \(d.instanceCount) base \(d.baseInstance)\(viewport)\(scissor) [\(bindings())]")
                    case .drawIndexed(let d):
                        guard budget > 0 else { continue }
                        budget -= 1
                        lines.append("  \(ci): drawIndexed \(describePipeline(pipeline)) prim \(d.primitiveType) indices \(d.indexCount) "
                                     + "type \(d.indexType) ib \(describeBuffer(d.indexBuffer, d.indexBufferOffset)) instances \(d.instanceCount) "
                                     + "baseVertex \(d.baseVertex)\(viewport)\(scissor) [\(bindings())]")
                    case .drawIndirect(let prim, let ib, let off):
                        guard budget > 0 else { continue }
                        budget -= 1
                        lines.append("  \(ci): drawIndirect \(describePipeline(pipeline)) prim \(prim) args \(describeBuffer(ib, off))"
                                     + "\(indirectArguments(ib, off, words: 4))\(viewport)\(scissor) [\(bindings())]")
                    case .drawIndexedIndirect(let prim, let type, let ixb, let ixo, let ib, let off):
                        guard budget > 0 else { continue }
                        budget -= 1
                        lines.append("  \(ci): drawIndexedIndirect \(describePipeline(pipeline)) prim \(prim) type \(type) ib "
                                     + "\(describeBuffer(ixb, ixo)) args \(describeBuffer(ib, off))\(indirectArguments(ib, off, words: 5))"
                                     + "\(viewport)\(scissor) [\(bindings())]")
                    default: break
                    }
                }
            case .compute(let cmds):
                lines.append("pass \(pi) compute")
                var pipeline: MetalHandle?
                var b: [Int: (MetalHandle?, Int)] = [:]
                var t: [Int: MetalHandle?] = [:]
                for (ci, c) in cmds.enumerated() {
                    switch c {
                    case .setComputePipelineState(let h): pipeline = h
                    case .setBuffer(let i, let h, let o): b[i] = (h, o)
                    case .setBufferOffset(let i, let o): b[i] = (b[i]?.0, o)
                    case .setTexture(let i, let h): t[i] = h
                    case .dispatchThreadgroups, .dispatchThreads, .dispatchThreadgroupsIndirect:
                        guard budget > 0 else { continue }
                        budget -= 1
                        let name = pipeline.flatMap { computePipelines[$0] }.map { shaderName($0.shader) } ?? "no pipeline"
                        let res = b.sorted { $0.key < $1.key }.map { "b\($0.key)=\(describeBuffer($0.value.0, $0.value.1))" }
                            + t.sorted { $0.key < $1.key }.map { "t\($0.key)=\(describeTexture($0.value))" }
                        lines.append("  \(ci): \(c) \(name) [\(res.joined(separator: ", "))]")
                    default: break
                    }
                }
            case .blit(let cmds):
                lines.append("pass \(pi) blit")
                for (ci, c) in cmds.enumerated() where budget > 0 {
                    budget -= 1
                    switch c {
                    case .copyBufferToTexture(let s, let so, let bpr, _, let size, let d, let slice, let level, let origin, _):
                        lines.append("  \(ci): buffer \(describeBuffer(s, so)) row \(bpr) → \(describeTexture(d)) level \(level) slice \(slice) "
                                     + "at \(origin.width),\(origin.height) size \(size.width)x\(size.height)x\(size.depth)")
                    default:
                        lines.append("  \(ci): \(c)")
                    }
                }
            case .event(let cmds):
                lines.append("pass \(pi) events \(cmds)")
            case .unknown(let kind, let records):
                lines.append("pass \(pi) unknown kind \(kind), \(records.count) records")
            }
        }
        if budget <= 0 { lines.append("(more commands not listed)") }
        return lines.joined(separator: "\n    ")
    }

    /// The first words of an indirect-arguments buffer when the CPU can read it.
    func indirectArguments(_ h: MetalHandle?, _ offset: Int, words: Int) -> String {
        guard let h, let b = buffers[h], let p = b.hostPointer, offset >= 0, offset + 4 * words <= b.length else { return "" }
        let values = (0..<words).map { p.load(fromByteOffset: offset + 4 * $0, as: UInt32.self) }
        return " (now " + values.map(String.init).joined(separator: " ") + ")"
    }

    // MARK: Reports

    /// Logs the description of the oldest pending submission (a hang). Under the lock.
    func reportRunningSubmission(serial: UInt64, seconds: Double) {
        guard let e = pending.first(where: { $0.serial == serial }) ?? pending.first else { return }
        var text = String(format: "serial %llu has run for %.1f s: ", serial, seconds) + e.label
        if let mcb = e.commandBuffer {
            let description = describeCommandBuffer(mcb)
            text += "\n    " + description
            if let dir = Self.hangCaptureDirectory { text += "\n    capture: " + capture(mcb, description: description, into: dir, serial: serial) }
        }
        log(text)
    }

    /// `YCODE_GPU_HANG_CAPTURE=<dir>`: a hang report also saves the command
    /// buffer's translated shaders (SPIR-V and reflection) and the bytes of
    /// the buffers it binds that the CPU can read, for offline replay.
    static let hangCaptureDirectory = ProcessInfo.processInfo.environment["YCODE_GPU_HANG_CAPTURE"].flatMap { $0.isEmpty ? nil : $0 }

    /// Writes the capture; returns its directory or why it failed. Under the lock.
    func capture(_ mcb: MetalCommandBuffer, description: String, into root: String, serial: UInt64) -> String {
        let dir = "\(root)/hang-\(getpid())-\(serial)"
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(description.utf8).write(to: URL(fileURLWithPath: dir + "/commands.txt"))
            var shaders: [String: TranslatedShader] = [:]
            var bufferHandles: Set<MetalHandle> = []
            for pass in mcb.passes {
                switch pass {
                case .render(let p):
                    for c in p.commands {
                        switch c {
                        case .setRenderPipelineState(let h?):
                            if let rp = renderPipelines[h] {
                                if let v = rp.vertex { shaders["p\(h.raw)-vertex"] = v }
                                if let f = rp.fragment { shaders["p\(h.raw)-fragment"] = f }
                            }
                        case .setBuffer(_, _, let b?, _): bufferHandles.insert(b)
                        case .drawIndexed(let d): if let b = d.indexBuffer { bufferHandles.insert(b) }
                        case .drawIndirect(_, let b?, _): bufferHandles.insert(b)
                        case .drawIndexedIndirect(_, _, let i, _, let b, _):
                            if let i { bufferHandles.insert(i) }
                            if let b { bufferHandles.insert(b) }
                        default: break
                        }
                    }
                case .compute(let cmds):
                    for c in cmds {
                        switch c {
                        case .setComputePipelineState(let h?): if let s = computePipelines[h]?.shader { shaders["c\(h.raw)-kernel"] = s }
                        case .setBuffer(_, let b?, _): bufferHandles.insert(b)
                        case .dispatchThreadgroupsIndirect(let b?, _, _): bufferHandles.insert(b)
                        default: break
                        }
                    }
                case .blit(let cmds):
                    for case .copyBufferToTexture(let s?, _, _, _, _, _, _, _, _, _) in cmds { bufferHandles.insert(s) }
                default: break
                }
            }
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            for (name, s) in shaders {
                try s.spirv.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: "\(dir)/\(name).spv")) }
                try encoder.encode(s.reflection).write(to: URL(fileURLWithPath: "\(dir)/\(name).json"))
            }
            var budget = 256 << 20
            for h in bufferHandles {
                guard let b = buffers[h], let p = b.hostPointer, b.length > 0, b.length <= budget else { continue }
                budget -= b.length
                try Data(bytes: p, count: b.length).write(to: URL(fileURLWithPath: "\(dir)/b\(h.raw).bin"))
            }
            return dir
        } catch {
            return "failed (\(error))"
        }
    }

    /// Logs what was pending and running when the device was lost (once). Under the lock.
    func reportDeviceLoss(_ context: String) {
        guard !deviceLossReported else { return }
        deviceLossReported = true
        let now = DispatchTime.now().uptimeNanoseconds
        var text = "device lost (\(context)); serials \(completedSerial)/\(lastSubmitted), \(pending.count) pending"
        for e in pending.prefix(4) {
            text += String(format: "\n  serial %llu queued %.2f s ago: ", e.serial, Double(now &- e.queuedAt) / 1e9) + e.label
            if let mcb = e.commandBuffer { text += "\n    " + describeCommandBuffer(mcb, limit: 24) }
        }
        if checkpointsOn {
            var markers = [UInt64](repeating: 0, count: 16), stages = [UInt64](repeating: 0, count: 16)
            let n = Int(yvk_queue_checkpoints(ctx, &markers, &stages, 16))
            if n == 0 { text += "\n  checkpoints: none reported" }
            for i in 0..<n {
                let stage = stages[i] == VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT ? "top of pipe"
                    : stages[i] == VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT ? "bottom of pipe" : "stage 0x\(String(stages[i], radix: 16))"
                text += "\n  checkpoint (\(stage)): " + describeMarker(markers[i])
            }
        }
        log(text)
    }
}
