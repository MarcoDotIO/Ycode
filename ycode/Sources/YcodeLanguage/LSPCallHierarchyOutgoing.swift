import Foundation

extension LSPClient {
    /// `callHierarchy/outgoingCalls`: the functions an item calls.
    public func outgoingCalls(_ item: CallHierarchyItem) async throws -> [CallHierarchyItem] {
        let r = try await request("callHierarchy/outgoingCalls", ["item": item.raw])
        return (r.array ?? []).compactMap { $0["to"].flatMap(CallHierarchyItem.init) }
    }
}
