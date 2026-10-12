// Shader translation for the Vulkan back end: what the back end needs from
// a translated Metal function (SPIR-V plus reflection), and the client of
// SH's `ycode-airc serve` (stage8-contract.md §5.2).
//
// The binding ABI is the one ycode-airc emits (ycode/Translator/src/abi.h,
// "Ycode Metal ABI 1", metal-shaders.md §4.4); the numbers are repeated in
// YcodeMetalABI below:
//
//   Push constants (32 bytes, all stages):
//     offset  0  u64  address of the vertex (or kernel) stage's argument table
//     offset  8  u64  address of the fragment stage's argument table
//     offset 16  u32 × 3  threads per grid (kernels: the exact Metal grid)
//   Argument table: 192 u64 entries (1536 bytes), one per stage and draw/dispatch:
//     0…30     buffer slot k: device address (buffer address + bound offset); 0 = nil
//     31       device address of the function's constant data
//     32…159   texture slot k: heap index
//     160…175  sampler slot k: heap index
//     176…191  constexpr sampler i: heap index
//   Set 0 (the bindless heap): binding 0 sampled images, 1 storage images,
//     2 samplers (runtime arrays). Heap index 0 is the null texture / sampler.
//   Specialization constants: 0, 1, 2 threads per threadgroup; 3 total
//     threadgroup memory bytes; 100 + n byte offset of [[threadgroup(n)]].
//   Vertex input: Location n = Metal attribute n; the Vulkan vertex binding
//     of a Metal vertex buffer index is that index.
//   Clip space: the back end flips y with a negative viewport height.

import Foundation

public enum YcodeMetalABI {
    public static let version = 1
    public static let tableEntries = 192
    public static let tableSize = 192 * 8
    public static let bufferEntry0 = 0
    public static let bufferSlots = 31
    public static let constantDataEntry = 31
    public static let textureEntry0 = 32
    public static let textureSlots = 128
    public static let samplerEntry0 = 160
    public static let samplerSlots = 16
    public static let constexprSamplerEntry0 = 176
    public static let constexprSamplerSlots = 16
    public static let pushVertexTable = 0
    public static let pushFragmentTable = 8
    public static let pushGrid = 16
    public static let pushConstantBytes = 32
    public static let specWorkgroup: [UInt32] = [0, 1, 2]
    public static let specThreadgroupBytes: UInt32 = 3
    public static let specThreadgroupSlot0: UInt32 = 100
}

/// The stage of a translated function.
public enum ShaderStage: String, Codable, Sendable {
    case vertex
    case fragment
    case kernel
}

/// The reflection document `ycode-airc` returns with each function (the
/// fields this back end uses; others are ignored). Keys are snake_case in
/// JSON.
public struct ShaderReflection: Codable, Sendable, Equatable {
    public var stage: ShaderStage
    /// The SPIR-V entry point (the Metal function name).
    public var entryPoint: String?
    /// The function's HASH (fragment translations link to a vertex function by it).
    public var hash: String?
    public var abi: ABIInfo?
    public var buffers: [Binding]?
    public var textures: [Binding]?
    public var samplers: [Binding]?
    public var constexprSamplers: [ConstexprSampler]?
    public var constantData: ConstantData?
    public var compute: Compute?
    public var vertexInputs: [VertexInput]?

    public struct ABIInfo: Codable, Sendable, Equatable {
        public var version: Int?
        public var pushConstantSize: Int?
        public var tablePushOffset: Int?
        public var tableEntries: Int?
    }

    public struct Binding: Codable, Sendable, Equatable {
        public var index: Int
        public var tableEntry: Int?
        public var used: Bool?
        public init(index: Int) { self.index = index }
    }

    public struct ConstexprSampler: Codable, Sendable, Equatable {
        public var tableEntry: Int
        public var sAddress: String?, tAddress: String?, rAddress: String?
        public var magFilter: String?, minFilter: String?, mipFilter: String?
        public var normalizedCoordinates: Bool?
        public var compareFunction: String?
        public var maxAnisotropy: Int?
        public var lodMin: Double?, lodMax: Double?
        public var borderColor: String?
        public init(tableEntry: Int) { self.tableEntry = tableEntry }
    }

    public struct ConstantData: Codable, Sendable, Equatable {
        public var tableEntry: Int?
        public var size: Int?
        public var base64: String
        public var bytes: [UInt8] { Data(base64Encoded: base64).map { [UInt8]($0) } ?? [] }
    }

    public struct Compute: Codable, Sendable, Equatable {
        public var workgroupSizeSpecIds: [UInt32]?
        public var gridPushOffset: Int?
        public var gridGuard: Bool?
        public var threadgroupMemory: ThreadgroupMemory?
        public init() {}
    }

    public struct ThreadgroupMemory: Codable, Sendable, Equatable {
        public var staticBytes: Int?
        public var dynamic: Bool?
        public var sizeSpecId: UInt32?
        public var slotsBase: Int?
        public var slots: [ThreadgroupSlot]?
    }

    public struct ThreadgroupSlot: Codable, Sendable, Equatable {
        public var index: Int
        public var offsetSpecId: UInt32?
        public var used: Bool?
    }

    public struct VertexInput: Codable, Sendable, Equatable {
        public var location: Int
        public var name: String?
        public var type: String?
        public var used: Bool?
    }

    public init(stage: ShaderStage, entryPoint: String? = "main") {
        self.stage = stage
        self.entryPoint = entryPoint
    }

    /// Decodes `ycode-airc`'s JSON.
    public static func decode(_ json: Data) throws -> ShaderReflection {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(ShaderReflection.self, from: json)
    }
}

/// A translated function.
public struct TranslatedShader: Sendable {
    public var spirv: [UInt32]
    public var reflection: ShaderReflection
    public init(spirv: [UInt32], reflection: ShaderReflection) {
        self.spirv = spirv
        self.reflection = reflection
    }
}

/// One translation request: a single-function metallib (as the guest sent
/// it), and for fragment functions the HASH of the vertex function it is
/// linked with (varyings are matched by name, metal-shaders.md §4.5); the
/// vertex function must have been translated before by the same translator.
public struct TranslationRequest: Sendable {
    public var metallib: [UInt8]
    public var linkVertexHash: String?
    /// The function to translate when the metallib has several (tools and tests).
    public var functionName: String?
    /// Requests with the same affinity go to the same translator process
    /// (a fragment function and the vertex function it links to). Default:
    /// the metallib's own hash.
    public var affinity: UInt64?
    public init(metallib: [UInt8], linkVertexHash: String? = nil, functionName: String? = nil, affinity: UInt64? = nil) {
        self.metallib = metallib
        self.linkVertexHash = linkVertexHash
        self.functionName = functionName
        self.affinity = affinity
    }
}

public struct ShaderTranslationError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ d: String) { description = d }
}

/// Turns Metal functions into SPIR-V. Implementations must be thread-safe.
public protocol ShaderTranslator: AnyObject, Sendable {
    func translate(_ request: TranslationRequest) throws -> TranslatedShader
}

/// 64-bit FNV-1a, for cache keys of shader bytes.
func fnv1a64(_ bytes: [UInt8], seed: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 {
    var h = seed
    for b in bytes {
        h ^= UInt64(b)
        h = h &* 0x0000_0100_0000_01B3
    }
    return h
}

/// A translator for tests and tools: functions given directly as SPIR-V,
/// keyed by the metallib bytes that stand for them.
public final class PrebuiltShaderTranslator: ShaderTranslator, @unchecked Sendable {
    private let lock = NSLock()
    private var shaders: [[UInt8]: TranslatedShader] = [:]

    public init() {}

    /// Registers `shader` as the translation of `metallib` (any bytes that identify it).
    public func add(_ metallib: [UInt8], _ shader: TranslatedShader) {
        lock.lock(); defer { lock.unlock() }
        shaders[metallib] = shader
    }

    public func translate(_ request: TranslationRequest) throws -> TranslatedShader {
        lock.lock(); defer { lock.unlock() }
        guard let s = shaders[request.metallib] else {
            throw ShaderTranslationError("no prebuilt shader for this function (\(request.metallib.count) bytes)")
        }
        return s
    }
}

/// The client of `ycode-airc serve`: one long-lived child process, binary
/// frames over stdin/stdout (ycode/Translator/src/main.cpp):
///   frame    u32 length L, then u32 header length H, H bytes of JSON, L − 4 − H payload bytes
///   request  {"id", "op": "translate", "link_vertex": HASH?}; payload = the metallib
///   response {"id", "status": "ok", "reflection": {...}}; payload = SPIR-V words,
///            or {"status": "error", "error": {"code", "detail"}}
/// A translator that died is restarted at the next request.
public final class AircProcessTranslator: ShaderTranslator, @unchecked Sendable {
    public let executable: URL
    public let arguments: [String]
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var nextID = 1

    /// `serve`, plus `--cache $YCODE_AIRC_CACHE` when that is set (ycode-airc's on-disk translation cache).
    public static var defaultArguments: [String] {
        if let dir = ProcessInfo.processInfo.environment["YCODE_AIRC_CACHE"], !dir.isEmpty { return ["serve", "--cache", dir] }
        return ["serve"]
    }

    public init(executable: URL, arguments: [String] = AircProcessTranslator.defaultArguments) {
        self.executable = executable
        self.arguments = arguments
    }

    /// Finds `ycode-airc`: $YCODE_AIRC, next to the running executable, or on $PATH.
    public static func locate() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["YCODE_AIRC"], FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        let own = URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
        let sibling = own.appendingPathComponent("ycode-airc")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let p = URL(fileURLWithPath: String(dir)).appendingPathComponent("ycode-airc")
            if FileManager.default.isExecutableFile(atPath: p.path) { return p }
        }
        return nil
    }

    deinit {
        process?.terminate()
    }

    private func start() throws {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.standardError
        try p.run()
        process = p
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
    }

    private func stop() {
        process?.terminate()
        process = nil
        input = nil
        output = nil
    }

    private func readExactly(_ n: Int) throws -> [UInt8] {
        guard let out = output else { throw ShaderTranslationError("ycode-airc is not running") }
        var data = [UInt8]()
        data.reserveCapacity(n)
        while data.count < n {
            let chunk = out.readData(ofLength: n - data.count)
            if chunk.isEmpty { throw ShaderTranslationError("ycode-airc closed its output") }
            data.append(contentsOf: chunk)
        }
        return data
    }

    public func translate(_ request: TranslationRequest) throws -> TranslatedShader {
        lock.lock(); defer { lock.unlock() }
        if process == nil || process?.isRunning == false { try start() }
        let id = nextID
        nextID += 1
        var header: [String: Any] = ["id": id, "op": "translate"]
        if let h = request.linkVertexHash { header["link_vertex"] = h }
        if let f = request.functionName { header["function"] = f }
        let headerBytes = [UInt8](try JSONSerialization.data(withJSONObject: header))
        var frame = [UInt8]()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { frame.append(contentsOf: $0) } }
        u32(UInt32(4 + headerBytes.count + request.metallib.count))
        u32(UInt32(headerBytes.count))
        frame.append(contentsOf: headerBytes)
        frame.append(contentsOf: request.metallib)
        let reply: (json: [UInt8], payload: [UInt8])
        do {
            try input?.write(contentsOf: Data(frame))
            let lengths = try readExactly(8)
            let total = lengths.withUnsafeBytes { Int($0.load(as: UInt32.self).littleEndian) }
            let hl = lengths.withUnsafeBytes { Int($0.load(fromByteOffset: 4, as: UInt32.self).littleEndian) }
            guard total >= 4 + hl else { throw ShaderTranslationError("ycode-airc: bad reply frame") }
            let json = try readExactly(hl)
            let payload = try readExactly(total - 4 - hl)
            reply = (json, payload)
        } catch {
            stop()
            throw error as? ShaderTranslationError ?? ShaderTranslationError("ycode-airc: \(error)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: Data(reply.json)) as? [String: Any] else {
            throw ShaderTranslationError("ycode-airc: reply header is not an object")
        }
        guard obj["status"] as? String == "ok", let refl = obj["reflection"] else {
            let e = obj["error"] as? [String: Any]
            throw ShaderTranslationError("ycode-airc: \(e?["code"] ?? "error"): \(e?["detail"] ?? "")")
        }
        let reflection = try ShaderReflection.decode(try JSONSerialization.data(withJSONObject: refl))
        let spirv = reply.payload.withUnsafeBytes { raw in
            (0..<(reply.payload.count / 4)).map { raw.load(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian }
        }
        return TranslatedShader(spirv: spirv, reflection: reflection)
    }
}

/// Several `ycode-airc serve` processes, so pipelines translate in
/// parallel. A request goes to the process its affinity selects (a fragment
/// function and its vertex function meet in the same process, whose
/// in-memory hash index links them).
public final class AircTranslatorPool: ShaderTranslator, @unchecked Sendable {
    public let processes: [AircProcessTranslator]

    public init(executable: URL, count: Int, arguments: [String] = AircProcessTranslator.defaultArguments) {
        processes = (0..<max(count, 1)).map { _ in AircProcessTranslator(executable: executable, arguments: arguments) }
    }

    public func translate(_ request: TranslationRequest) throws -> TranslatedShader {
        let key = request.affinity ?? fnv1a64(request.metallib)
        return try processes[Int(key % UInt64(processes.count))].translate(request)
    }
}
