// EKParticipant (read-only for apps, interface.md §4) and the virtual
// conference descriptor classes (names and simple values; level 1 only).

import Foundation

public class EKParticipant: EKObject, NSCopying {
    public let url: URL
    public let name: String?
    public let participantStatus: EKParticipantStatus
    public let participantRole: EKParticipantRole
    public let participantType: EKParticipantType
    public let isCurrentUser: Bool

    init(url: URL, name: String?, status: EKParticipantStatus = .unknown, role: EKParticipantRole = .unknown,
         type: EKParticipantType = .unknown, isCurrentUser: Bool = false) {
        self.url = url
        self.name = name
        self.participantStatus = status
        self.participantRole = role
        self.participantType = type
        self.isCurrentUser = isCurrentUser
    }

    public func copy(with zone: NSZone? = nil) -> Any { self }
}

public class EKVirtualConferenceRoomTypeDescriptor: NSObject {
    public let title: String
    public let identifier: String
    public init(title: String, identifier: String) {
        self.title = title
        self.identifier = identifier
    }
}

public class EKVirtualConferenceURLDescriptor: NSObject {
    public let title: String?
    public let url: URL
    public init(title: String?, url: URL) {
        self.title = title
        self.url = url
    }
}

public class EKVirtualConferenceDescriptor: NSObject {
    public let title: String?
    public let urlDescriptors: [EKVirtualConferenceURLDescriptor]
    public let conferenceDetails: String?
    public init(title: String?, urlDescriptors: [EKVirtualConferenceURLDescriptor], conferenceDetails: String?) {
        self.title = title
        self.urlDescriptors = urlDescriptors
        self.conferenceDetails = conferenceDetails
    }
}

/// Base class for conferencing extensions; subclasses override both methods.
open class EKVirtualConferenceProvider: NSObject {
    public override init() { super.init() }
    open func fetchAvailableRoomTypes() async throws -> [EKVirtualConferenceRoomTypeDescriptor] { [] }
    open func fetchVirtualConference(identifier: String) async throws -> EKVirtualConferenceDescriptor {
        throw EKError(.osNotSupported)
    }
}
