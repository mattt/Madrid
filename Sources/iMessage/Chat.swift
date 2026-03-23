import Foundation

/// Represents a chat conversation in the Messages database.
public struct Chat: Identifiable, Hashable, Codable, Sendable {
    /// The stable chat identifier.
    public var id: GUID

    /// The user-visible chat name, when available.
    public let displayName: String?

    /// The participant handles associated with the chat.
    public let participants: [Account.Handle]

    /// The date of the most recent message in the chat.
    public let lastMessageDate: Date?
}

// MARK: - Comparable

extension Chat: Comparable {
    public static func < (lhs: Chat, rhs: Chat) -> Bool {
        return lhs.lastMessageDate ?? .distantPast < rhs.lastMessageDate ?? .distantPast
    }
}
