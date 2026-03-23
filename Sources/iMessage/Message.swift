import Foundation

/// Represents a single message from the Messages database.
public struct Message: Identifiable, Hashable, Codable, Sendable {
    /// The stable message identifier.
    public let id: GUID

    /// The message body text.
    public let text: String

    /// The date when the message was sent or received.
    public let date: Date

    /// A Boolean value that indicates whether this message is from the current user.
    public let isFromMe: Bool

    /// The date when this message was read, if available.
    public let readAt: Date?

    /// The sender handle for inbound messages.
    public let sender: Account.Handle?

    /// A Boolean value that indicates whether this message has been read.
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
