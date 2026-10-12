import Foundation

// XPC object serialization and bootstrap pipe-routine messages
// (`specs/simulator/bootstrap-wire.md` §2–§4). Owner: agent X (stage 4c-ii).

/// An XPC value as it travels in a pipe-routine message. Port-bearing values
/// carry the port name in the receiving space; descriptors are matched to
/// them in depth-first order.
public indirect enum XPCObject: Equatable, Sendable {
    case null
}
