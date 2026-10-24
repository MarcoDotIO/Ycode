// Opt-in probe for a translated compute kernel that may not terminate
// (stage8-contract.md §13.3): runs one kernel many times over random
// inputs with a per-dispatch time limit and reports the first dispatch
// that does not finish. The kernel comes from files ycode-airc wrote
// (its own SPIR-V and reflection, for example a GPU-cache entry), so the
// probe needs no guest library:
//
//   YCODE_TEST_HANG_SPV=k.spv YCODE_TEST_HANG_JSON=k.json swift test --filter KernelHangProbe
//
// Optional: YCODE_TEST_HANG_ROUNDS (default 40), YCODE_TEST_HANG_SEED,
// YCODE_TEST_HANG_TG (threadgroup width,height; default 8,8),
// YCODE_TEST_HANG_GRID (blocks per side, default 64),
// YCODE_TEST_HANG_OUT (directory for the inputs of a dispatch that hung).
// Replay: YCODE_TEST_HANG_REPLAY=DIR (inputs saved by an earlier hang; one
// round) with YCODE_TEST_HANG_FIRST / YCODE_TEST_HANG_COUNT keeping only
// that range of blocks (the others become zero bytes), to bisect for the
// block that does not finish; YCODE_TEST_HANG_PLACE=i,j,... moves the kept
// blocks to those block indices (other threads, warps or threadgroups).
//
// The bindings follow the reflection of the `astc` kernel family: buffer 0
// 16-byte input blocks, buffers 1 and 3 byte tables, buffer 2 a small
// parameter structure, texture 0 the written image. The parameter words
// the kernel reads (byte offsets 8, 36, 40, 44, 48, 52 per its reflection
// and its own SPIR-V) are set to plausible and to random values.

import Foundation
import Testing
@testable import YcodeMetalHost
@testable import YcodeVulkan

enum HangProbe {
    static let env = ProcessInfo.processInfo.environment
    static var configured: Bool {
        guard let s = env["YCODE_TEST_HANG_SPV"], let j = env["YCODE_TEST_HANG_JSON"] else { return false }
        return FileManager.default.fileExists(atPath: s) && FileManager.default.fileExists(atPath: j)
    }
}

/// A small, seedable generator (SplitMix64) so that a hang can be replayed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite(.serialized, .enabled(if: HangProbe.configured && VK.available, "needs YCODE_TEST_HANG_SPV, YCODE_TEST_HANG_JSON and a GPU"))
struct KernelHangProbeTests {
    @Test func randomInputsTerminate() throws {
        let spvData = try Data(contentsOf: URL(fileURLWithPath: HangProbe.env["YCODE_TEST_HANG_SPV"]!))
        let reflection = try ShaderReflection.decode(Data(contentsOf: URL(fileURLWithPath: HangProbe.env["YCODE_TEST_HANG_JSON"]!)))
        var words = [UInt32](repeating: 0, count: spvData.count / 4)
        _ = words.withUnsafeMutableBytes { spvData.copyBytes(to: $0) }
        let t = PrebuiltShaderTranslator()
        t.add(Array("probe:kernel".utf8), TranslatedShader(spirv: words, reflection: reflection))
        var o = VulkanMetalBackend.Options()
        o.log = { print($0) }
        let b = VulkanMetalBackend(translator: t, options: o)
        defer { b.shutdown() }

        let rounds = Int(HangProbe.env["YCODE_TEST_HANG_ROUNDS"] ?? "") ?? 40
        let grid = Int(HangProbe.env["YCODE_TEST_HANG_GRID"] ?? "") ?? 64
        var rng = SplitMix64(state: UInt64(HangProbe.env["YCODE_TEST_HANG_SEED"] ?? "") ?? 1)
        let fn = VK.handle(), pipe = VK.handle()
        try b.createFunction(fn, metallib: Array("probe:kernel".utf8))
        _ = try b.createComputePipeline(pipe, function: fn)

        let blockBytes = grid * grid * 16
        let tableBytes = 1 << 20
        let mem = HostPages(roundUp(blockBytes + 2 * tableBytes + 16384, 16384))
        let inOff = 0, tabOff = roundUp(blockBytes, 16384), zeroOff = tabOff + tableBytes, parOff = zeroOff + tableBytes
        let hin = VK.handle(), htab = VK.handle(), hzero = VK.handle(), hpar = VK.handle()
        try b.createBuffer(hin, length: blockBytes, storage: .shared, guestMemory: mem.region(inOff, blockBytes))
        try b.createBuffer(htab, length: tableBytes, storage: .shared, guestMemory: mem.region(tabOff, tableBytes))
        try b.createBuffer(hzero, length: tableBytes, storage: .shared, guestMemory: mem.region(zeroOff, tableBytes))
        try b.createBuffer(hpar, length: 64, storage: .shared, guestMemory: mem.region(parOff, 64))
        let side = grid * 12
        let tex = VK.handle()
        try b.createTexture(tex, MetalTextureDescriptor(pixelFormat: MetalPixelFormat.rgba8Unorm, width: side, height: side, usage: 0x3,
                                                        resourceOptions: 0x20), iosurface: nil)
        let dims: [UInt32] = [4, 5, 6, 8, 10, 12]
        // YCODE_TEST_HANG_TG=w,h: the threadgroup size (default 8,8; the
        // render server's dispatches used 32,16).
        let tgParts = (HangProbe.env["YCODE_TEST_HANG_TG"] ?? "8,8").split(separator: ",").compactMap { Int($0) }
        let tg = (tgParts.count == 2 ? tgParts[0] : 8, tgParts.count == 2 ? tgParts[1] : 8)
        var slowest = 0.0
        var lastStatus = -1
        /// One dispatch over the current inputs; false when it did not finish in 8 s.
        func dispatchOnce() throws -> Bool {
            let done = DispatchSemaphore(value: 0)
            let status = StatusBox()
            let cb = MetalCommandBuffer(process: 1, queue: nil, commandBufferRef: VK.nextID(), passes: [.compute([
                .setComputePipelineState(pipe),
                .setBuffer(index: 0, buffer: hin, offset: 0),
                .setBuffer(index: 1, buffer: htab, offset: 0),
                .setBuffer(index: 2, buffer: hpar, offset: 0),
                .setBuffer(index: 3, buffer: hzero, offset: 0),
                .setTexture(index: 0, texture: tex),
                .dispatchThreads(MetalSize3(grid, grid, 1), threadsPerThreadgroup: MetalSize3(tg.0, tg.1, 1)),
            ])])
            b.submit(cb, scheduled: {}, completed: { s in status.value = s; done.signal() })
            if done.wait(timeout: .now() + 8) == .timedOut { return false }
            lastStatus = status.value
            return true
        }
        for round in 0..<rounds {
            // Tables: valid partition indices (0...3) or anything.
            let tabMask: UInt8 = round % 3 == 2 ? 0xFF : 0x03
            for i in 0..<tableBytes { mem.pointer.storeBytes(of: UInt8(truncatingIfNeeded: rng.next()) & tabMask, toByteOffset: tabOff + i, as: UInt8.self) }
            for i in 0..<tableBytes { mem.pointer.storeBytes(of: round % 4 == 3 ? UInt8(truncatingIfNeeded: rng.next()) & 3 : 0, toByteOffset: zeroOff + i, as: UInt8.self) }
            for i in 0..<(blockBytes / 8) { mem.pointer.storeBytes(of: rng.next(), toByteOffset: inOff + 8 * i, as: UInt64.self) }
            var par = [UInt32](repeating: 0, count: 16)
            if let dir = HangProbe.env["YCODE_TEST_HANG_REPLAY"] {
                func load(_ name: String, _ off: Int, _ n: Int) throws {
                    let d = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(name)"))
                    precondition(d.count == n, "\(name): \(d.count) bytes, expected \(n)")
                    d.withUnsafeBytes { (mem.pointer + off).copyMemory(from: $0.baseAddress!, byteCount: n) }
                }
                try load("blocks.bin", inOff, blockBytes)
                try load("tables.bin", tabOff, tableBytes)
                try load("zero-tables.bin", zeroOff, tableBytes)
                try load("params.bin", parOff, 64)
                let first = Int(HangProbe.env["YCODE_TEST_HANG_FIRST"] ?? "") ?? 0
                let count = Int(HangProbe.env["YCODE_TEST_HANG_COUNT"] ?? "") ?? grid * grid
                for blk in 0..<(grid * grid) where blk < first || blk >= first + count {
                    (mem.pointer + inOff + 16 * blk).initializeMemory(as: UInt8.self, repeating: 0, count: 16)
                }
                if let place = HangProbe.env["YCODE_TEST_HANG_PLACE"] {
                    // Move the kept blocks (in order) to these block indices.
                    let kept = (first..<(first + count)).map { Array(UnsafeRawBufferPointer(start: mem.pointer + inOff + 16 * $0, count: 16)) }
                    (mem.pointer + inOff).initializeMemory(as: UInt8.self, repeating: 0, count: blockBytes)
                    for (k, dst) in place.split(separator: ",").compactMap({ Int($0) }).enumerated() where k < kept.count {
                        kept[k].withUnsafeBytes { (mem.pointer + inOff + 16 * dst).copyMemory(from: $0.baseAddress!, byteCount: 16) }
                    }
                }
                for i in 0..<16 { par[i] = mem.pointer.load(fromByteOffset: parOff + 4 * i, as: UInt32.self) }
                let started = DispatchTime.now().uptimeNanoseconds
                let ok = try dispatchOnce()
                let s = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
                print("hang-probe replay: blocks \(first)..<\(first + count): \(ok ? "finished" : "did not finish") (\(String(format: "%.3f", s)) s)")
                if ok, count == 1 {
                    let bytes = (0..<16).map { String(format: "%02x", mem.pointer.load(fromByteOffset: inOff + 16 * first + $0, as: UInt8.self)) }
                    print("hang-probe replay: block \(first) = \(bytes.joined())")
                }
                if !ok {
                    let bytes = count == 1 ? (0..<16).map { String(format: "%02x", mem.pointer.load(fromByteOffset: inOff + 16 * first + $0, as: UInt8.self)) }.joined() : ""
                    print("hang-probe replay: HANG \(first) \(count) \(bytes)")
                    return
                }
                break
            }
            for i in 0..<14 { par[i] = round % 5 == 4 ? UInt32(truncatingIfNeeded: rng.next()) : 0 }
            let bw = dims[Int(rng.next() % 6)], bh = dims[Int(rng.next() % 6)]
            par[2] = UInt32(grid * 16)           // offset 8: bytes per row of blocks
            par[9] = 0; par[10] = 0              // offsets 36, 40: first block
            par[11] = UInt32(rng.next() % 3)     // offset 44: mode flag (1 or other)
            par[12] = bw; par[13] = bh           // offsets 48, 52: block size
            for (i, v) in par.enumerated() { mem.pointer.storeBytes(of: v, toByteOffset: parOff + 4 * i, as: UInt32.self) }
            let start = DispatchTime.now().uptimeNanoseconds
            if try !dispatchOnce() {
                let parHex = par.map { String($0, radix: 16) }.joined(separator: " ")
                print("hang-probe: round \(round) did not finish in 8 s; block \(bw)x\(bh) params \(parHex)")
                if let dir = HangProbe.env["YCODE_TEST_HANG_OUT"] {
                    try Data(bytes: mem.pointer + inOff, count: blockBytes).write(to: URL(fileURLWithPath: "\(dir)/blocks.bin"))
                    try Data(bytes: mem.pointer + tabOff, count: tableBytes).write(to: URL(fileURLWithPath: "\(dir)/tables.bin"))
                    try Data(bytes: mem.pointer + zeroOff, count: tableBytes).write(to: URL(fileURLWithPath: "\(dir)/zero-tables.bin"))
                    try Data(bytes: mem.pointer + parOff, count: 64).write(to: URL(fileURLWithPath: "\(dir)/params.bin"))
                }
                Issue.record("round \(round): the kernel did not finish in 8 s (block \(bw)x\(bh), params \(parHex))")
                return  // the queue is stuck; nothing more can run
            }
            let s = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            slowest = max(slowest, s)
            #expect(lastStatus == 4, "round \(round): status \(lastStatus)")
        }
        print("hang-probe: \(rounds) rounds of \(grid)x\(grid) blocks finished; slowest dispatch \(String(format: "%.3f", slowest)) s")
        for h in [hin, htab, hzero, hpar, tex, pipe, fn] { b.release(h) }
    }
}

/// The loop guard on the GPU: Translator/tests/ir/control-flow.sh leaves
/// `spin` (a loop that waits for in[0] == 1) translated with
/// --loop-limit 1000; with in[0] = 0 every thread must stop at the guard
/// (and store the guard edge's zero), with in[0] = 1 after one iteration.
///   YCODE_TEST_LOOP_SPV=WORK/spin.spv YCODE_TEST_LOOP_JSON=WORK/spin.json
@Suite(.serialized, .enabled(if: HangProbe.env["YCODE_TEST_LOOP_SPV"] != nil && VK.available, "needs YCODE_TEST_LOOP_SPV, YCODE_TEST_LOOP_JSON and a GPU"))
struct LoopGuardGPUTests {
    @Test func guardEndsRunawayLoop() throws {
        let spvData = try Data(contentsOf: URL(fileURLWithPath: HangProbe.env["YCODE_TEST_LOOP_SPV"]!))
        let reflection = try ShaderReflection.decode(Data(contentsOf: URL(fileURLWithPath: HangProbe.env["YCODE_TEST_LOOP_JSON"]!)))
        var words = [UInt32](repeating: 0, count: spvData.count / 4)
        _ = words.withUnsafeMutableBytes { spvData.copyBytes(to: $0) }
        let t = PrebuiltShaderTranslator()
        t.add(Array("spin".utf8), TranslatedShader(spirv: words, reflection: reflection))
        let b = VulkanMetalBackend(translator: t, options: VulkanMetalBackend.Options())
        defer { b.shutdown() }
        let fn = VK.handle(), pipe = VK.handle(), hout = VK.handle(), hin = VK.handle()
        try b.createFunction(fn, metallib: Array("spin".utf8))
        _ = try b.createComputePipeline(pipe, function: fn)
        let n = 256
        let mem = HostPages(16384)
        try b.createBuffer(hout, length: 4 * n, storage: .shared, guestMemory: mem.region(0, 4 * n))
        try b.createBuffer(hin, length: 4, storage: .shared, guestMemory: mem.region(8192, 4))
        for (flag, want) in [(UInt32(0), UInt32(0)), (1, 1)] {
            mem.pointer.storeBytes(of: flag, toByteOffset: 8192, as: UInt32.self)
            for i in 0..<n { mem.pointer.storeBytes(of: UInt32(0xDEAD), toByteOffset: 4 * i, as: UInt32.self) }
            let done = DispatchSemaphore(value: 0)
            let status = StatusBox()
            let cb = MetalCommandBuffer(process: 1, queue: nil, commandBufferRef: VK.nextID(), passes: [.compute([
                .setComputePipelineState(pipe),
                .setBuffer(index: 0, buffer: hout, offset: 0),
                .setBuffer(index: 1, buffer: hin, offset: 0),
                .dispatchThreads(MetalSize3(n, 1, 1), threadsPerThreadgroup: MetalSize3(64, 1, 1)),
            ])])
            b.submit(cb, scheduled: {}, completed: { s in status.value = s; done.signal() })
            guard done.wait(timeout: .now() + 5) == .success else {
                Issue.record("in[0] = \(flag): the guarded loop did not end in 5 s")
                return
            }
            #expect(status.value == 4)
            let bad = (0..<n).filter { mem.pointer.load(fromByteOffset: 4 * $0, as: UInt32.self) != want }.count
            #expect(bad == 0, "in[0] = \(flag): \(bad) threads did not store \(want)")
        }
        for h in [hout, hin, pipe, fn] { b.release(h) }
    }
}

final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v = -1
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
