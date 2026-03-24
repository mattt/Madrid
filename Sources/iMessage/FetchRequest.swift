import Foundation

/// Sort direction for fetch requests.
public enum SortOrder: String, Sendable, Hashable, CaseIterable {
    /// Sort values from smallest to largest.
    case ascending
    /// Sort values from largest to smallest.
    case descending
}

/// Participant matching mode for participant-based predicates.
public enum ParticipantMatch: String, Sendable, Hashable, CaseIterable {
    /// Match when any provided participant is present.
    case any
    /// Match only when all provided participants are present.
    case all
}

/// Predicate tree used to filter messages.
public indirect enum MessagePredicate: Sendable, Hashable {
    /// Match all messages.
    case all
    /// Match no messages.
    case none
    /// Match messages that belong to the specified chat.
    case chatID(Chat.ID)
    /// Match messages sent by any of the provided handles.
    case participantHandles(Set<Account.Handle>)
    /// Match messages in the half-open date range.
    case dateRange(Range<Date>)
    /// Match messages that satisfy every nested predicate.
    case and([MessagePredicate])
    /// Match messages that satisfy at least one nested predicate.
    case or([MessagePredicate])
    /// Match messages that do not satisfy the nested predicate.
    case not(MessagePredicate)
}

/// Typed message sort descriptor.
public enum MessageSortDescriptor: Sendable, Hashable {
    /// Sort by message date.
    case date(SortOrder)
    /// Sort by stable message identifier.
    case id(SortOrder)
}

/// Predicate tree used to filter chats.
public indirect enum ChatPredicate: Sendable, Hashable {
    /// Match all chats.
    case all
    /// Match no chats.
    case none
    /// Match chats by participant handles using the selected mode.
    case participantHandles(Set<Account.Handle>, match: ParticipantMatch)
    /// Match chats that contain message activity in the half-open date range.
    case dateRange(Range<Date>)
    /// Match chats that satisfy every nested predicate.
    case and([ChatPredicate])
    /// Match chats that satisfy at least one nested predicate.
    case or([ChatPredicate])
    /// Match chats that do not satisfy the nested predicate.
    case not(ChatPredicate)
}

/// Typed chat sort descriptor.
public enum ChatSortDescriptor: Sendable, Hashable {
    /// Sort by each chat's latest message date.
    case lastMessageDate(SortOrder)
    /// Sort by stable chat identifier.
    case id(SortOrder)
}

/// Describes result-specific behavior for ``FetchRequest``.
public protocol FetchRequestResult {
    /// Predicate type accepted for this result type.
    associatedtype Predicate: Sendable
    /// Sort descriptor type accepted for this result type.
    associatedtype SortDescriptor: Sendable

    /// Default predicate when callers do not provide one.
    static var defaultFetchPredicate: Predicate { get }
    /// Default sort descriptors when callers do not provide any.
    static var defaultFetchSortDescriptors: [SortDescriptor] { get }
}

/// A generic typed fetch request for queryable result models.
public struct FetchRequest<Result: FetchRequestResult>: Sendable {
    /// Predicate used to filter rows.
    public var predicate: Result.Predicate
    /// Sort descriptors applied in order.
    public var sortDescriptors: [Result.SortDescriptor]
    /// Maximum number of rows to return.
    public var limit: Int
    /// Number of rows to skip before returning.
    public var offset: Int

    /// Creates a fetch request.
    ///
    /// - Parameters:
    ///   - predicate: The filter predicate to apply.
    ///   - sortDescriptors: The sort descriptors applied in order.
    ///   - limit: The maximum number of rows to return.
    ///   - offset: The number of rows to skip before returning.
    public init(
        predicate: Result.Predicate = Result.defaultFetchPredicate,
        sortDescriptors: [Result.SortDescriptor] = Result.defaultFetchSortDescriptors,
        limit: Int = 100,
        offset: Int = 0
    ) {
        self.predicate = predicate
        self.sortDescriptors = sortDescriptors
        self.limit = limit
        self.offset = offset
    }
}

extension Message: FetchRequestResult {
    public static var defaultFetchPredicate: MessagePredicate { .all }
    public static var defaultFetchSortDescriptors: [MessageSortDescriptor] {
        [.date(.descending), .id(.descending)]
    }
}

extension Chat: FetchRequestResult {
    public static var defaultFetchPredicate: ChatPredicate { .all }
    public static var defaultFetchSortDescriptors: [ChatSortDescriptor] {
        [.lastMessageDate(.descending), .id(.ascending)]
    }
}
