// Snapshot support of the Vulkan back end (specs/simulator/snapshot.md §8
// option 2): settle the device, and read and write the bytes of buffers the
// back end owns. Textures go through `getBytes` and `replaceRegion`.

import CVulkan
import Foundation
import YcodeMetalHost

extension VulkanMetalBackend {
    /// Flushes pending setup work and waits until the Vulkan device is idle
    /// (`vkDeviceWaitIdle`). Does nothing without a GPU.
    public func snapshotSettle() {
        guard isAvailable else { return }
        cond.lock()
        try? flushSetup()
        cond.unlock()
        _ = fn.vkDeviceWaitIdle!(ctx.pointee.device)
    }

    /// The bytes of a buffer in backend-owned, host-mapped memory; nil for
    /// an unknown or empty buffer, one backed by imported (guest) memory, or
    /// one without a host mapping.
    public func bufferContents(_ handle: MetalHandle) -> [UInt8]? {
        cond.lock(); defer { cond.unlock() }
        guard let b = buffers[handle], b.allocation.key == nil, let base = b.allocation.base, b.length > 0 else { return nil }
        return [UInt8](UnsafeRawBufferPointer(start: base + b.offset, count: b.length))
    }

    /// Copies `bytes` (at most the buffer's length) into a backend-owned
    /// buffer; false for an unknown buffer, one backed by imported memory,
    /// or one without a host mapping.
    public func setBufferContents(_ handle: MetalHandle, _ bytes: [UInt8]) -> Bool {
        cond.lock(); defer { cond.unlock() }
        guard let b = buffers[handle], b.allocation.key == nil, let base = b.allocation.base else { return false }
        let n = min(bytes.count, b.length)
        bytes.withUnsafeBytes { (base + b.offset).copyMemory(from: $0.baseAddress!, byteCount: n) }
        return true
    }
}
