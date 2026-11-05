import Foundation
import YcodeDebug

/// Debug ▸ Debug Workflow ▸ View Memory (`specs/ide/debug.md` §The Linux
/// IDE): the debugged process's bytes through lldb-dap's `readMemory`.
extension WorkspaceSession {
    /// Whether the adapter reads memory (`supportsReadMemoryRequest`).
    public var canReadMemory: Bool { debugClient?.capabilities["supportsReadMemoryRequest"]?.bool == true }

    /// `count` bytes at an address ("0x…" or decimal) or a memory
    /// reference; nil while not paused or when the adapter refuses.
    public func readMemory(_ reference: String, offset: Int = 0, count: Int) async -> MemoryBlock? {
        guard let client = debugClient, stoppedThread != nil else { return nil }
        return try? await client.readMemory(memoryReference: reference, offset: offset, count: count)
    }

    /// Where an expression's value is in memory: the adapter's memory
    /// reference, else the value itself when it reads as an address.
    public func memoryReference(of expression: String) async -> String? {
        if MemoryBlock.address(expression) != nil { return expression.trimmingCharacters(in: .whitespaces) }
        guard let client = debugClient, stoppedThread != nil,
              let r = try? await client.evaluateFull(expression, frameID: selectedFrameID, context: "watch") else { return nil }
        if let m = r.memoryReference { return m }
        let first = r.result.split(separator: " ").first.map(String.init) ?? r.result
        return MemoryBlock.address(first) != nil ? first : nil
    }
}
