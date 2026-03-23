import Foundation

public struct Message: Identifiable, Hashable, Codable, Sendable {
    public let id: GUID
    public let text: String
    public let date: Date
    public let isFromMe: Bool
    public let readAt: Date?
    public let sender: Account.Handle?

    public var isRead: Bool {
        readAt != nil
    }
}

// MARK: - Comparable

extension Message: Comparable {
    public static func < (lhs: Message, rhs: Message) -> Bool {
        return (lhs.date, lhs.id) < (rhs.date, rhs.id)
    }
}
