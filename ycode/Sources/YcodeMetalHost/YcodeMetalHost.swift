// YcodeMetalHost: the simulator Metal host service (stage8-contract.md §5;
// owner MT). Written from specs/simulator/metal-sim-protocol.md ("the
// spec") and the contract only.
//
// API summary (for VK and I3; names are stable, changes go through the
// orchestrator):
//
//   MetalHandle            host-global object identity (UInt64, never reused).
//                          Guest refs are per process and per kind and are
//                          reused; the service maps them to handles, so a
//                          backend sees only handles.
//   MetalProcessID         the service's id of a client process (= processRef)
//
//   protocol MetalBackend  (VK implements; called from several service
//                          threads at once: implementations must be thread-safe)
//     isAvailable, limits()                                   device op 37
//     createBuffer(h, length:, storage:, guestMemory:)        messageType 1, ops 24
//     createTexture(h, desc, iosurface:)                      mt 8 op 1, mt 13 op 47, op 21
//     createTextureView(h, parent:, desc)                     ops 7, 8, 27
//     createSampler(h, desc) / createDepthStencilState(h, desc)
//     createFunction(h, metallib:)                            mt 15 (single-function metallib)
//     createRenderPipeline(h, desc)                           op 14 (keyed descriptor, decoded)
//     createComputePipeline(h, function:) -> MetalComputePipelineInfo   op 11
//     replaceRegion(texture:, region, level:, slice:, bytes:, bytesPerRow:, bytesPerImage:)
//     getBytes(texture:, region, level:, slice:, into:, bytesPerRow:, bytesPerImage:)
//                                                             must observe all work submitted earlier
//     release(h)                                              may arrive while submitted work still
//                                                             uses h: defer destruction until it completes
//     submit(cb, scheduled:, completed:)                      `scheduled` only when the frame's writes to
//                                                             IOSurface-backed textures are in surface
//                                                             memory (spec §9); `completed(status)` 4 or 5.
//                                                             Command buffers of one queue run in order.
//     defaults (protocol extension, optional): createEvent, createFence,
//       signalEvent(h, value:) (CPU op 30), eventValue(h) (op 41),
//       gpuAddress(ofBuffer:) (op 38), gpuResourceID(ofSampler:) (op 39)
//
//   protocol IOSurfaceResolver     (I3)  backing(forSurfacePort:plane:) -> IOSurfaceBacking?
//   protocol MetalGuestMemoryResolver (I3)  region(forMemoryEntry:) -> GuestSharedRegion?
//   GuestSharedRegion      pointer, length, objectID, offset, objectPointer,
//                          objectLength, owner (keeps the memory alive)
//   IOSurfaceBacking       surfaceID, region, width, height, bytesPerRow,
//                          bytesPerElement, pixelFormat (FourCC), plane, planeOffset
//   MetalLimits            maxThreadsPerThreadgroup (x, y, z), maxThreadgroupMemoryLength
//
//   Descriptors (MetalDescriptors.swift): MetalTextureDescriptor,
//     MetalTextureViewDescriptor, MetalSamplerDescriptor,
//     MetalDepthStencilDescriptor (+ MetalStencilDescriptor),
//     MetalRenderPipelineDescriptor (+ MetalColorAttachmentDescriptor,
//     MetalVertexDescriptor), MetalRegion, MetalStorageMode, MetalPixelFormat
//     (raw values = public MTLPixelFormat), Metal* enum-value namespaces.
//   Command model (MetalCommands.swift): MetalCommandBuffer { process,
//     queue, commandBufferRef, passes: [MetalPass], unknownRecordCount }
//     MetalPass .render(MetalRenderPass) .compute([MetalComputeCommand])
//               .blit([MetalBlitCommand]) .event([MetalEventCommand])
//     MetalRenderPass { descriptor: MetalRenderPassDescriptor?, commands: [MetalRenderCommand] }
//     every command enum has .unknown(op:body:) for records the decoder
//     does not know (logged, never fatal).
//
//   MetalHostService(host:backend:memory:surfaces:registryID:log:) (MetalHostService.swift)
//     servicePort (receive + send right in the host task; register the
//     names of serviceNames to it — the first alone is enough), start(),
//     stop(), statistics (MetalHostStatistics).
//   MetalCommandDecoder.decode(segments:process:queue:commandBufferRef:resolve:)
//     the segment decoder on its own (for backend tests).
//   NullBackend: records calls, completes at once, isAvailable == false.

import Foundation

/// A host-global identity of one Metal object (buffer, texture, function,
/// pipeline, sampler, depth-stencil state, event, fence, queue, heap). Never
/// reused while the service lives.
public struct MetalHandle: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
    public static func < (a: MetalHandle, b: MetalHandle) -> Bool { a.raw < b.raw }
    public var description: String { "#\(raw)" }
}

/// The service's id of a client process (the hand-shake `processRef`).
public typealias MetalProcessID = UInt64

/// Guest memory that the host can read and write in place: the pages of a
/// guest process (a buffer's `sharedMem`, a read-back region) or of an
/// IOSurface. The memory stays valid while `owner` is retained.
public struct GuestSharedRegion: @unchecked Sendable {
    /// The first byte of the region.
    public let pointer: UnsafeMutableRawPointer
    public let length: Int
    /// A stable identity of the backing allocation (same for every region
    /// over it), for importing an allocation once (VK_EXT_external_memory_host).
    public let objectID: UInt64
    /// The region's offset in the backing allocation.
    public let offset: Int
    /// The whole backing allocation (page aligned).
    public let objectPointer: UnsafeMutableRawPointer
    public let objectLength: Int
    /// Keeps the memory alive (e.g. the kernel's shared memory object).
    public let owner: AnyObject?

    public init(pointer: UnsafeMutableRawPointer, length: Int, objectID: UInt64, offset: Int = 0,
                objectPointer: UnsafeMutableRawPointer? = nil, objectLength: Int? = nil, owner: AnyObject?) {
        self.pointer = pointer
        self.length = length
        self.objectID = objectID
        self.offset = offset
        self.objectPointer = objectPointer ?? pointer - offset
        self.objectLength = objectLength ?? offset + length
        self.owner = owner
    }

    /// The bytes [at, at+count) of the region (clamped).
    public func slice(at: Int, count: Int) -> GuestSharedRegion {
        let start = min(max(at, 0), length)
        let n = min(max(count, 0), length - start)
        return GuestSharedRegion(pointer: pointer + start, length: n, objectID: objectID, offset: offset + start,
                                 objectPointer: objectPointer, objectLength: objectLength, owner: owner)
    }

    /// A copy of the first `count` bytes (clamped to the region).
    public func bytes(count: Int? = nil) -> [UInt8] {
        let n = min(count ?? length, length)
        return n <= 0 ? [] : [UInt8](UnsafeRawBufferPointer(start: pointer, count: n))
    }
}

/// An IOSurface that a texture renders into or samples from (spec §5.4):
/// the surface's memory and layout as Ycode's IOSurface service knows it.
public struct IOSurfaceBacking: @unchecked Sendable {
    public var surfaceID: UInt32
    /// The surface's whole allocation (guest-shared memory).
    public var region: GuestSharedRegion
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    public var bytesPerElement: Int
    /// The IOSurface pixel format (a FourCC such as 'BGRA').
    public var pixelFormat: UInt32
    /// The plane the texture uses, and its byte offset in `region`.
    public var plane: Int
    public var planeOffset: Int
    /// The surface's seed (raised by every lock for writing) and whether a
    /// lock is held now; nil when unknown. Lets the GPU back end skip
    /// copying in a surface nothing wrote since (diagnostics-free; optional).
    public var syncState: (@Sendable () -> (seed: UInt32, locked: Bool)?)?

    public init(surfaceID: UInt32, region: GuestSharedRegion, width: Int, height: Int, bytesPerRow: Int,
                bytesPerElement: Int, pixelFormat: UInt32, plane: Int = 0, planeOffset: Int = 0) {
        self.surfaceID = surfaceID
        self.region = region
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bytesPerElement = bytesPerElement
        self.pixelFormat = pixelFormat
        self.plane = plane
        self.planeOffset = planeOffset
    }
}

/// The answer to device op 37 (spec §4.2). The driver keeps, for each
/// value, the smaller of this and its own cap (512, 512, 512, 16 384).
public struct MetalLimits: Equatable, Sendable {
    public var maxThreadsPerThreadgroup: (x: UInt64, y: UInt64, z: UInt64)
    public var maxThreadgroupMemoryLength: UInt64

    public init(maxThreadsPerThreadgroup: (x: UInt64, y: UInt64, z: UInt64) = (1024, 1024, 1024),
                maxThreadgroupMemoryLength: UInt64 = 32768) {
        self.maxThreadsPerThreadgroup = maxThreadsPerThreadgroup
        self.maxThreadgroupMemoryLength = maxThreadgroupMemoryLength
    }

    /// The values the macOS host answered.
    public static let macOSHost = MetalLimits()

    public static func == (a: MetalLimits, b: MetalLimits) -> Bool {
        a.maxThreadsPerThreadgroup == b.maxThreadsPerThreadgroup && a.maxThreadgroupMemoryLength == b.maxThreadgroupMemoryLength
    }
}

/// What a compute pipeline reports back (op 11 reply).
public struct MetalComputePipelineInfo: Equatable, Sendable {
    public var maxTotalThreadsPerThreadgroup: UInt16
    public var threadExecutionWidth: UInt16
    public init(maxTotalThreadsPerThreadgroup: UInt16 = 1024, threadExecutionWidth: UInt16 = 32) {
        self.maxTotalThreadsPerThreadgroup = maxTotalThreadsPerThreadgroup
        self.threadExecutionWidth = threadExecutionWidth
    }
}

/// `MTLCommandBufferStatus` values that completion events carry (spec §8.5).
public enum MetalCommandBufferStatus {
    public static let scheduled = 3
    public static let completed = 4
    public static let error = 5
}

/// The GPU side of the service. VK implements it on Vulkan; `NullBackend`
/// is the test double. Every method may be called from several service
/// threads at once. Object creation failures are logged by the service and
/// never reported to the guest (the spec knows no error path, §13 item 5):
/// the guest still gets its ref, and work that names a handle the backend
/// does not know must be skipped, not fatal.
public protocol MetalBackend: AnyObject {
    /// False on hosts without a usable GPU.
    var isAvailable: Bool { get }
    /// Device op 37.
    func limits() -> MetalLimits

    /// A buffer. `guestMemory` is set for shared (and managed) storage: the
    /// guest's pages, to be used in place (the guest reads results there
    /// after event 101). Private buffers have none: the backend allocates.
    func createBuffer(_ handle: MetalHandle, length: Int, storage: MetalStorageMode, guestMemory: GuestSharedRegion?) throws
    /// A texture; host-owned memory for every storage mode, unless
    /// `iosurface` is set (then rendering must land in the surface memory).
    func createTexture(_ handle: MetalHandle, _ desc: MetalTextureDescriptor, iosurface: IOSurfaceBacking?) throws
    /// A view of `parent` (ops 7, 8, 27).
    func createTextureView(_ handle: MetalHandle, parent: MetalHandle, _ desc: MetalTextureViewDescriptor) throws
    func createSampler(_ handle: MetalHandle, _ desc: MetalSamplerDescriptor) throws
    func createDepthStencilState(_ handle: MetalHandle, _ desc: MetalDepthStencilDescriptor) throws
    /// A function: a metallib container with one function (AIR). Translation
    /// may be lazy (at pipeline creation).
    func createFunction(_ handle: MetalHandle, metallib: [UInt8]) throws
    func createRenderPipeline(_ handle: MetalHandle, _ desc: MetalRenderPipelineDescriptor) throws
    func createComputePipeline(_ handle: MetalHandle, function: MetalHandle) throws -> MetalComputePipelineInfo

    /// `replaceRegion:` (messageType 9). `bytes` holds exactly
    /// (rows − 1) × bytesPerRow + width × bytes per pixel per image.
    func replaceRegion(texture: MetalHandle, _ region: MetalRegion, level: Int, slice: Int, bytes: [UInt8],
                       bytesPerRow: Int, bytesPerImage: Int) throws
    /// `getBytes:` (messageType 10): write the pixels into `into` (guest
    /// memory) before returning. Must see the effects of every command
    /// buffer submitted earlier (connection 0 is ordered).
    func getBytes(texture: MetalHandle, _ region: MetalRegion, level: Int, slice: Int, into: GuestSharedRegion,
                  bytesPerRow: Int, bytesPerImage: Int) throws

    /// The guest released the object (or its process ended).
    func release(_ handle: MetalHandle)

    /// Runs a command buffer. Call `scheduled` once the frame's writes to
    /// IOSurface-backed textures are complete in surface memory (or never:
    /// the service then sends event 100 just before 101), and
    /// `completed(status)` once everything is done and visible in guest
    /// memory (status 4, or 5 for an error). Either may be called on any thread.
    func submit(_ commandBuffer: MetalCommandBuffer, scheduled: @escaping @Sendable () -> Void,
                completed: @escaping @Sendable (_ status: Int) -> Void)

    // Optional (defaults below).
    /// `newEvent` / `newSharedEvent` (op 28).
    func createEvent(_ handle: MetalHandle) throws
    /// A second handle for an existing event (`newSharedEventWithHandle:`,
    /// messageType 18): signals and values through either are one event,
    /// and releasing one handle keeps the event for the other.
    func createEventAlias(_ handle: MetalHandle, of original: MetalHandle) throws
    /// `newFence` (op 13).
    func createFence(_ handle: MetalHandle) throws
    /// CPU `setSignaledValue:` (op 30). Must release GPU waits (record 400) for values ≤ `value`.
    func signalEvent(_ handle: MetalHandle, value: UInt64)
    /// CPU `signaledValue` (op 41); nil: the service answers with the last CPU value.
    func eventValue(_ handle: MetalHandle) -> UInt64?
    /// Buffer `gpuAddress` (op 38); nil: the service chooses one.
    func gpuAddress(ofBuffer handle: MetalHandle) -> UInt64?
    /// Sampler `gpuResourceID` (op 39); nil: the service answers the handle.
    func gpuResourceID(ofSampler handle: MetalHandle) -> UInt64?
    /// The 64-bit value a shader uses for a texture (its heap index in the
    /// Vulkan back end); nil: none.
    func gpuResourceID(ofTexture handle: MetalHandle) -> UInt64?
    /// Writes bytes into a buffer's memory as the guest's CPU sees it
    /// (argument-encoder set calls, `YCODE_METAL_ARGUMENT_ENCODER`); false
    /// when the buffer has no CPU-visible memory.
    func writeBuffer(_ handle: MetalHandle, offset: Int, _ bytes: [UInt8]) -> Bool
    /// Diagnostics: a one-line summary of the backend's state (nil: none).
    func diagnosticSummary() -> String?
    /// Snapshots (snapshot.md §8 option 2): finish every queued GPU
    /// operation (uploads included) and wait until the device is idle.
    func snapshotSettle()
    /// Snapshots: the bytes of a buffer the backend owns (not guest memory),
    /// read once the device is idle; nil when it cannot be read.
    func bufferContents(_ handle: MetalHandle) -> [UInt8]?
    /// Restores: writes a buffer's bytes back (true on success).
    func setBufferContents(_ handle: MetalHandle, _ bytes: [UInt8]) -> Bool
    /// Ends the backend before the host process exits: no thread of the
    /// backend may still be inside the GPU driver when exit() runs the
    /// driver's own teardown (`stage8-contract.md` §12).
    /// Called once no request can arrive any more; idempotent.
    func shutdown()
}

public extension MetalBackend {
    func createEvent(_ handle: MetalHandle) throws {}
    func createEventAlias(_ handle: MetalHandle, of original: MetalHandle) throws { try createEvent(handle) }
    func createFence(_ handle: MetalHandle) throws {}
    func signalEvent(_ handle: MetalHandle, value: UInt64) {}
    func eventValue(_ handle: MetalHandle) -> UInt64? { nil }
    func gpuAddress(ofBuffer handle: MetalHandle) -> UInt64? { nil }
    func gpuResourceID(ofSampler handle: MetalHandle) -> UInt64? { nil }
    func gpuResourceID(ofTexture handle: MetalHandle) -> UInt64? { nil }
    func writeBuffer(_ handle: MetalHandle, offset: Int, _ bytes: [UInt8]) -> Bool { false }
    /// Diagnostics: a one-line summary of the backend's state (nil: none).
    func diagnosticSummary() -> String? { nil }
    func snapshotSettle() {}
    func bufferContents(_ handle: MetalHandle) -> [UInt8]? { nil }
    func setBufferContents(_ handle: MetalHandle, _ bytes: [UInt8]) -> Bool { false }
    func shutdown() {}
}

// CONTRACT-REQUEST (I3): IOSurfaceHostService keeps its Method-14 ports
// private (`surfacePorts`). Please add a public look-up from such a port
// name to the surface (ID, SharedMemoryObject, width, height, bytes per row,
// bytes per element, pixel format, plane offsets) and implement
// `IOSurfaceResolver` with it. The service keeps the received send right
// until the texture is released, then drops one send reference.
/// Resolves the `iosurface` right of messageType 13 (an IOSurface.Remote
/// surface port from Method 14, named in the host task) to the surface.
/// I3 implements it with the IOSurface service.
public protocol IOSurfaceResolver: AnyObject {
    func backing(forSurfacePort port: UInt32, plane: Int) -> IOSurfaceBacking?
    /// A new surface made by the host for a shared texture (messageType 19,
    /// metal-sim-protocol.md §5.10): width, height, bytes per row and pixel
    /// format 0, bytes per element 1, `allocationSize` bytes, the name, and
    /// these creation properties (numbers; `IOSurfaceName` is added as a
    /// string). Every process that looks the surface up sees them. Returns
    /// its port (a host-task receive right; the reply carries a send right
    /// made from it), or nil.
    func makeSharedTextureSurface(allocationSize: Int, name: String, properties: [(key: String, value: UInt64)]) -> UInt32?
    /// The surface behind a port the guest sent (messageType 20): its ID and
    /// its numeric creation properties, or nil when the port is unknown.
    func surfaceDescription(forSurfacePort port: UInt32) -> MetalSurfaceDescription?
}

public extension IOSurfaceResolver {
    func makeSharedTextureSurface(allocationSize: Int, name: String, properties: [(key: String, value: UInt64)]) -> UInt32? { nil }
    func surfaceDescription(forSurfacePort port: UInt32) -> MetalSurfaceDescription? { nil }
}

/// A surface as messageType 20 needs it: its ID (the same in every process)
/// and its creation properties that are numbers (`kMetal…` keys among them).
public struct MetalSurfaceDescription: Equatable, Sendable {
    public var id: UInt32
    public var numbers: [String: UInt64]
    public init(id: UInt32, numbers: [String: UInt64]) {
        self.id = id
        self.numbers = numbers
    }
}

// CONTRACT-REQUEST (I3): MachHostTask has no public way to find what a
// memory-entry name stands for (`MachIPC.memoryEntry(named:)` is internal).
// Please add one, e.g. `memoryEntry(_ name: UInt32) -> (object:
// SharedMemoryObject, offset: UInt64, size: UInt64)?`, and implement
// `MetalGuestMemoryResolver` with it: pointer = object.host + offset,
// objectID = object.serial, owner = object. Used for buffers' `sharedMem`
// (kept for the buffer's life), read-back regions, and XPC data sent by
// memory entry (command-buffer segments, large uploads; copied at once).
/// Resolves a memory-entry send right named in the host task (an XPC
/// shared-memory object, or XPC data sent by memory entry) to host memory.
/// I3 implements it with the kernel's memory entries.
public protocol MetalGuestMemoryResolver: AnyObject {
    func region(forMemoryEntry name: UInt32) -> GuestSharedRegion?
}
