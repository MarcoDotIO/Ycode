// A `MetalBackend` that executes nothing: it records every call and
// completes command buffers at once (or when told to, for ordering tests).
// It reports `isAvailable` false, so a VMM never prefers it to a GPU.

import Foundation

public final class NullBackend: MetalBackend, @unchecked Sendable {
    public enum Call: Equatable, Sendable {
        case createBuffer(MetalHandle, length: Int, storage: MetalStorageMode, shared: Bool)
        case createTexture(MetalHandle, MetalTextureDescriptor, iosurface: UInt32?)
        case createTextureView(MetalHandle, parent: MetalHandle, MetalTextureViewDescriptor)
        case createSampler(MetalHandle, MetalSamplerDescriptor)
        case createDepthStencilState(MetalHandle, MetalDepthStencilDescriptor)
        case createFunction(MetalHandle, bytes: Int)
        case createRenderPipeline(MetalHandle, MetalRenderPipelineDescriptor)
        case createComputePipeline(MetalHandle, function: MetalHandle)
        case createEvent(MetalHandle)
        case createFence(MetalHandle)
        case signalEvent(MetalHandle, value: UInt64)
        case replaceRegion(MetalHandle, MetalRegion, level: Int, slice: Int, bytes: Int, bytesPerRow: Int)
        case getBytes(MetalHandle, MetalRegion, level: Int, slice: Int, length: Int, bytesPerRow: Int)
        case release(MetalHandle)
        case submit(commandBufferRef: UInt64, passes: Int)
    }

    public struct Pending: @unchecked Sendable {
        public var commandBuffer: MetalCommandBuffer
        public var scheduled: @Sendable () -> Void
        public var completed: @Sendable (Int) -> Void
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _submitted: [MetalCommandBuffer] = []
    private var _pending: [Pending] = []
    private var events: [MetalHandle: UInt64] = [:]

    /// When true (default), `submit` calls `scheduled` and `completed(4)` before returning.
    public var completesImmediately: Bool
    /// The value `getBytes` fills the guest region with.
    public var readBackFill: UInt8 = 0
    public var limitsValue = MetalLimits.macOSHost
    /// Called by `shutdown()` (ordering tests).
    public var onShutdown: (@Sendable () -> Void)?
    private var _shutdownCount = 0
    /// How many times `shutdown()` was called.
    public var shutdownCount: Int { lock.withLock { _shutdownCount } }

    public func shutdown() {
        lock.withLock { _shutdownCount += 1 }
        onShutdown?()
    }

    public init(completesImmediately: Bool = true) { self.completesImmediately = completesImmediately }

    public var isAvailable: Bool { false }
    public var calls: [Call] { lock.withLock { _calls } }
    public var submitted: [MetalCommandBuffer] { lock.withLock { _submitted } }
    public var pending: [Pending] { lock.withLock { _pending } }

    private func record(_ c: Call) { lock.withLock { _calls.append(c) } }

    public func limits() -> MetalLimits { limitsValue }

    public func createBuffer(_ handle: MetalHandle, length: Int, storage: MetalStorageMode, guestMemory: GuestSharedRegion?) throws {
        record(.createBuffer(handle, length: length, storage: storage, shared: guestMemory != nil))
    }

    public func createTexture(_ handle: MetalHandle, _ desc: MetalTextureDescriptor, iosurface: IOSurfaceBacking?) throws {
        record(.createTexture(handle, desc, iosurface: iosurface?.surfaceID))
    }

    public func createTextureView(_ handle: MetalHandle, parent: MetalHandle, _ desc: MetalTextureViewDescriptor) throws {
        record(.createTextureView(handle, parent: parent, desc))
    }

    public func createSampler(_ handle: MetalHandle, _ desc: MetalSamplerDescriptor) throws { record(.createSampler(handle, desc)) }

    public func createDepthStencilState(_ handle: MetalHandle, _ desc: MetalDepthStencilDescriptor) throws {
        record(.createDepthStencilState(handle, desc))
    }

    public func createFunction(_ handle: MetalHandle, metallib: [UInt8]) throws {
        record(.createFunction(handle, bytes: metallib.count))
    }

    public func createRenderPipeline(_ handle: MetalHandle, _ desc: MetalRenderPipelineDescriptor) throws {
        record(.createRenderPipeline(handle, desc))
    }

    public func createComputePipeline(_ handle: MetalHandle, function: MetalHandle) throws -> MetalComputePipelineInfo {
        record(.createComputePipeline(handle, function: function))
        return MetalComputePipelineInfo()
    }

    public func createEvent(_ handle: MetalHandle) throws { record(.createEvent(handle)) }
    public func createFence(_ handle: MetalHandle) throws { record(.createFence(handle)) }

    public func signalEvent(_ handle: MetalHandle, value: UInt64) {
        lock.withLock {
            _calls.append(.signalEvent(handle, value: value))
            events[handle] = value
        }
    }

    public func eventValue(_ handle: MetalHandle) -> UInt64? { lock.withLock { events[handle] } }

    public func replaceRegion(texture: MetalHandle, _ region: MetalRegion, level: Int, slice: Int, bytes: [UInt8],
                              bytesPerRow: Int, bytesPerImage: Int) throws {
        record(.replaceRegion(texture, region, level: level, slice: slice, bytes: bytes.count, bytesPerRow: bytesPerRow))
    }

    public func getBytes(texture: MetalHandle, _ region: MetalRegion, level: Int, slice: Int, into: GuestSharedRegion,
                         bytesPerRow: Int, bytesPerImage: Int) throws {
        if into.length > 0 { into.pointer.initializeMemory(as: UInt8.self, repeating: readBackFill, count: into.length) }
        record(.getBytes(texture, region, level: level, slice: slice, length: into.length, bytesPerRow: bytesPerRow))
    }

    public func release(_ handle: MetalHandle) { record(.release(handle)) }

    public func submit(_ commandBuffer: MetalCommandBuffer, scheduled: @escaping @Sendable () -> Void,
                       completed: @escaping @Sendable (Int) -> Void) {
        let now = lock.withLock { () -> Bool in
            _calls.append(.submit(commandBufferRef: commandBuffer.commandBufferRef, passes: commandBuffer.passes.count))
            _submitted.append(commandBuffer)
            if !completesImmediately {
                _pending.append(Pending(commandBuffer: commandBuffer, scheduled: scheduled, completed: completed))
            }
            return completesImmediately
        }
        if now {
            scheduled()
            completed(MetalCommandBufferStatus.completed)
        }
    }

    /// Finishes the oldest pending command buffer: `scheduled` first when
    /// asked, then `completed(status)`.
    public func completeNext(status: Int = MetalCommandBufferStatus.completed, reportScheduled: Bool = true) {
        guard let p = lock.withLock({ _pending.isEmpty ? nil : _pending.removeFirst() }) else { return }
        if reportScheduled { p.scheduled() }
        p.completed(status)
    }
}
