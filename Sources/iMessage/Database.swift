import Foundation
import SQLite3
import TypedStream

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Provides read-focused access to the Messages SQLite database.
public final class Database {
    var db: OpaquePointer?

    /// Defines flags used to open a SQLite database connection.
    public struct Flags: OptionSet, Sendable, Hashable {
        /// The underlying SQLite bitmask value.
        public let rawValue: Int32

        /// Creates a flags value from a raw SQLite bitmask.
        ///
        /// - Parameter rawValue: The SQLite open flags bitmask.
        public init(rawValue: Int32) {
            self.rawValue = rawValue
        }

        /// Opens the database in read-only mode
        public static let readOnly = Flags(rawValue: SQLITE_OPEN_READONLY)

        /// Opens the database in read-write mode
        public static let readWrite = Flags(rawValue: SQLITE_OPEN_READWRITE)

        /// Creates the database if it does not exist
        public static let create = Flags(rawValue: SQLITE_OPEN_CREATE)

        /// Enables URI filename interpretation
        public static let uri = Flags(rawValue: SQLITE_OPEN_URI)

        /// Opens the database in shared cache mode
        public static let sharedCache = Flags(rawValue: SQLITE_OPEN_SHAREDCACHE)

        /// Opens the database in private cache mode
        public static let privateCache = Flags(rawValue: SQLITE_OPEN_PRIVATECACHE)

        /// Opens the database without mutex checking
        public static let noMutex = Flags(rawValue: SQLITE_OPEN_NOMUTEX)

        /// Opens the database with full mutex checking
        public static let fullMutex = Flags(rawValue: SQLITE_OPEN_FULLMUTEX)

        /// Common flag combinations
        public static let `default`: Flags = [.readOnly, .uri]
    }

    /// Describes errors produced while opening or querying the database.
    public enum Error: Swift.Error {
        /// The database file does not exist at the requested path.
        case databaseNotFound
        /// SQLite failed to open the database.
        case failedToOpen(String)
        /// SQLite failed while preparing or executing a query.
        case queryError(String)
    }

    /// Backward-compatible alias for a message fetch request.
    public typealias MessageFetchRequest = FetchRequest<Message>
    /// Backward-compatible alias for a chat fetch request.
    public typealias ChatFetchRequest = FetchRequest<Chat>

    private init(
        _ filename: String,
        flags: Flags = .default
    ) throws {
        if sqlite3_open_v2(filename, &db, flags.rawValue, nil) != SQLITE_OK {
            throw Error.failedToOpen(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Opens the Messages database at a path.
    ///
    /// When `path` is `nil`, this initializer uses the default
    /// `~/Library/Messages/chat.db` location.
    ///
    /// - Parameter path: An optional absolute database path.
    /// - Throws: ``Error/databaseNotFound`` when the file does not exist,
    ///   or ``Error/failedToOpen(_:)`` when SQLite fails to open it.
    public convenience init(path: String? = nil) throws {
        let resolvedPath: String
        if let path = path {
            resolvedPath = path
        } else {
            resolvedPath = "/Users/\(NSUserName())/Library/Messages/chat.db"
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw Error.databaseNotFound
        }

        let dbURI = "file:\(resolvedPath)?immutable=1&mode=ro"
        try self.init(dbURI, flags: [.readOnly, .uri])
    }

    /// Creates an in-memory database handle for tests and temporary data.
    ///
    /// - Returns: A database opened at SQLite's `:memory:` location.
    /// - Throws: ``Error/failedToOpen(_:)`` when SQLite cannot create the database.
    public static func inMemory() throws -> Database {
        return try Database(":memory:", flags: [.readWrite, .create])
    }

    deinit {
        sqlite3_close(db)
    }

    // Remove transaction from execute
    private func execute<T>(
        _ query: String,
        parameters: [any Bindable] = [],
        transform: (OpaquePointer) throws -> T?
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK,
            let statement = statement
        else {
            throw Error.queryError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        // Bind all parameters
        for (index, value) in parameters.enumerated() {
            value.bind(to: statement, at: Int32(index + 1))
        }

        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let result = try transform(statement) {
                results.append(result)
            }
        }

        return results
    }

    /// Fetches chats using a predicate-style request.
    ///
    /// - Parameter request: The typed chat fetch request.
    /// - Returns: Chats matching the predicate and sort descriptors.
    /// - Throws: ``Error/queryError(_:)`` when SQL preparation or execution fails.
    public func fetch(_ request: ChatFetchRequest) throws -> [Chat] {
        try validatePagination(limit: request.limit, offset: request.offset)

        return try withTransaction {
            let compiledPredicate = try compileChatPredicate(request.predicate)
            let orderByClause = chatOrderByClause(request.sortDescriptors)

            var parameters = compiledPredicate.parameters
            parameters.append(try bindableInt32(request.limit, name: "limit"))
            parameters.append(try bindableInt32(request.offset, name: "offset"))

            let query = """
                    SELECT
                        c.guid,
                        c.display_name,
                        c.service_name,
                        MAX(m.date) as last_message_date
                    FROM chat c
                    LEFT JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
                    LEFT JOIN message m ON cmj.message_id = m.ROWID
                    \(compiledPredicate.whereClause.map { "WHERE \($0)" } ?? "")
                    GROUP BY c.ROWID
                    ORDER BY \(orderByClause)
                    LIMIT ?
                    OFFSET ?
                """

            return try execute(query, parameters: parameters) { statement in
                guard let guidText = sqlite3_column_text(statement, 0) else { return nil }
                let chatId = Chat.ID(rawValue: String(cString: guidText))

                let displayName = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let rawLastMessageDate = sqlite3_column_int64(statement, 3)
                let lastMessageDate =
                    sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : Date(nanosecondsSinceReferenceDate: rawLastMessageDate)

                let participants = try fetchParticipants(for: chatId)

                return Chat(
                    id: chatId,
                    displayName: displayName,
                    participants: participants,
                    lastMessageDate: lastMessageDate
                )
            }
        }
    }

    @available(*, deprecated, message: "Use fetch(_:) with a ChatFetchRequest.")
    public func fetchChats(_ request: ChatFetchRequest) throws -> [Chat] {
        try fetch(request)
    }

    /// Fetches chats, optionally filtered by participants and date range.
    ///
    /// - Parameters:
    ///   - participantHandles: An optional set of handles that must be present in the chat.
    ///   - dateRange: An optional date range used to filter chat activity.
    ///   - limit: The maximum number of chats to return.
    /// - Returns: Chats ordered by most recent message date, descending.
    /// - Throws: ``Error/queryError(_:)`` when SQL preparation or execution fails.
    @available(
        *,
        deprecated,
        message: "Use fetch(_:) with a ChatFetchRequest predicate instead."
    )
    public func fetchChats(
        with participantHandles: Set<Account.Handle>? = nil,
        in dateRange: Range<Date>? = nil,
        limit: Int = 100
    ) throws -> [Chat] {
        var predicates: [ChatPredicate] = []
        if let participantHandles = participantHandles, !participantHandles.isEmpty {
            predicates.append(.participantHandles(participantHandles, match: .all))
        }
        if let dateRange = dateRange {
            predicates.append(.dateRange(dateRange))
        }

        return try fetch(
            ChatFetchRequest(
                predicate: .and(predicates),
                limit: limit
            )
        )
    }

    /// Fetches messages using a predicate-style request.
    ///
    /// - Parameter request: The typed message fetch request.
    /// - Returns: Messages matching the predicate and sort descriptors.
    /// - Throws: ``Error/queryError(_:)`` when SQL preparation or execution fails.
    public func fetch(_ request: MessageFetchRequest) throws -> [Message] {
        try validatePagination(limit: request.limit, offset: request.offset)

        return try withTransaction {
            let compiledPredicate = try compileMessagePredicate(request.predicate)
            let orderByClause = messageOrderByClause(request.sortDescriptors)

            var parameters = compiledPredicate.parameters
            parameters.append(try bindableInt32(request.limit, name: "limit"))
            parameters.append(try bindableInt32(request.offset, name: "offset"))

            let query = """
                    SELECT
                        m.guid,
                        m.text,
                        HEX(m.attributedBody),
                        m.date,
                        m.is_from_me,
                        h.id,
                        m.service,
                        m.date_read
                    FROM message m
                    \(compiledPredicate.requiresChatJoin ? "JOIN chat_message_join cmj ON m.ROWID = cmj.message_id" : "")
                    \(compiledPredicate.requiresChatJoin ? "JOIN chat c ON cmj.chat_id = c.ROWID" : "")
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    \(compiledPredicate.whereClause.map { "WHERE \($0)" } ?? "")
                    ORDER BY \(orderByClause)
                    LIMIT ?
                    OFFSET ?
                """

            return try execute(query, parameters: parameters) { statement in
                let messageID: Message.ID
                if let messageIdText = sqlite3_column_text(statement, 0) {
                    messageID = Message.ID(rawValue: String(cString: messageIdText))
                } else {
                    messageID = "N/A"
                }

                let text: String
                if let rawText = sqlite3_column_text(statement, 1) {
                    text = String(cString: rawText)
                } else if let hexData = sqlite3_column_text(statement, 2).map({
                    String(cString: $0)
                }),
                    let data = Data(hexString: hexData),
                    let plainText = try? TypedStreamDecoder.decode(data).compactMap({
                        $0.stringValue
                    }).joined(separator: "\n")
                {
                    text = plainText
                } else {
                    text = ""
                }

                let date = Date(
                    nanosecondsSinceReferenceDate: sqlite3_column_int64(statement, 3)
                )
                let isFromMe = sqlite3_column_int(statement, 4) != 0
                let rawReadAt = sqlite3_column_int64(statement, 7)
                let readAt =
                    rawReadAt == 0
                    ? nil
                    : Date(nanosecondsSinceReferenceDate: rawReadAt)

                let senderText = sqlite3_column_text(statement, 5)
                let sender = senderText.map { Account.Handle(rawValue: String(cString: $0)) }

                return Message(
                    id: messageID,
                    text: text,
                    date: date,
                    isFromMe: isFromMe,
                    readAt: readAt,
                    sender: sender
                )
            }
        }
    }

    @available(*, deprecated, message: "Use fetch(_:) with a MessageFetchRequest.")
    public func fetchMessages(_ request: MessageFetchRequest) throws -> [Message] {
        try fetch(request)
    }

    /// Fetches messages, optionally filtered by chat, participants, and date range.
    ///
    /// - Parameters:
    ///   - chatId: An optional chat identifier to scope the query.
    ///   - participantHandles: An optional set of sender handles to include.
    ///   - dateRange: An optional date range used to filter message dates.
    ///   - limit: The maximum number of messages to return.
    /// - Returns: Messages ordered by message date, descending.
    /// - Throws: ``Error/queryError(_:)`` when SQL preparation or execution fails.
    @available(
        *,
        deprecated,
        message: "Use fetch(_:) with a MessageFetchRequest predicate instead."
    )
    public func fetchMessages(
        for chatId: Chat.ID? = nil,
        with participantHandles: Set<Account.Handle>? = nil,
        in dateRange: Range<Date>? = nil,
        limit: Int = 100
    ) throws -> [Message] {
        var predicates: [MessagePredicate] = []
        if let chatId = chatId {
            predicates.append(.chatID(chatId))
        }
        if let participantHandles = participantHandles, !participantHandles.isEmpty {
            predicates.append(.participantHandles(participantHandles))
        }
        if let dateRange = dateRange {
            predicates.append(.dateRange(dateRange))
        }

        return try fetch(
            MessageFetchRequest(
                predicate: .and(predicates),
                limit: limit
            )
        )
    }

    private struct CompiledPredicate {
        let whereClause: String?
        let parameters: [any Bindable]
        let requiresChatJoin: Bool
    }

    private func compileMessagePredicate(
        _ predicate: MessagePredicate
    ) throws -> CompiledPredicate {
        switch predicate {
        case .all:
            return CompiledPredicate(whereClause: nil, parameters: [], requiresChatJoin: false)
        case .none:
            return CompiledPredicate(whereClause: "1 = 0", parameters: [], requiresChatJoin: false)
        case .chatID(let chatID):
            return CompiledPredicate(
                whereClause: "c.guid = ?",
                parameters: [chatID.rawValue],
                requiresChatJoin: true
            )
        case .participantHandles(let handles):
            if handles.isEmpty {
                return CompiledPredicate(
                    whereClause: "1 = 0",
                    parameters: [],
                    requiresChatJoin: false
                )
            }
            let handleValues = orderedHandleValues(handles)
            let placeholders = placeholders(handles.count)
            let condition = """
                m.ROWID IN (
                    SELECT m2.ROWID
                    FROM message m2
                    JOIN handle h ON m2.handle_id = h.ROWID
                    WHERE h.id IN (\(placeholders))
                )
                """
            return CompiledPredicate(
                whereClause: condition,
                parameters: toBindableStrings(handleValues),
                requiresChatJoin: false
            )
        case .dateRange(let dateRange):
            let upperBound = try requireNanoseconds(dateRange.upperBound, label: "upperBound")
            let lowerBound = try requireNanoseconds(dateRange.lowerBound, label: "lowerBound")
            return CompiledPredicate(
                whereClause: "m.date < ? AND m.date >= ?",
                parameters: [upperBound, lowerBound],
                requiresChatJoin: false
            )
        case .and(let predicates):
            if predicates.isEmpty {
                return CompiledPredicate(whereClause: nil, parameters: [], requiresChatJoin: false)
            }
            return try combineMessagePredicates(predicates, joiner: "AND")
        case .or(let predicates):
            if predicates.isEmpty {
                return CompiledPredicate(whereClause: "1 = 0", parameters: [], requiresChatJoin: false)
            }
            return try combineMessagePredicates(predicates, joiner: "OR")
        case .not(let predicate):
            let compiled = try compileMessagePredicate(predicate)
            let whereClause = compiled.whereClause ?? "1 = 1"
            return CompiledPredicate(
                whereClause: "NOT (\(whereClause))",
                parameters: compiled.parameters,
                requiresChatJoin: compiled.requiresChatJoin
            )
        }
    }

    private func combineMessagePredicates(
        _ predicates: [MessagePredicate],
        joiner: String
    ) throws -> CompiledPredicate {
        let isOR = joiner == "OR"
        var whereParts: [String] = []
        var parameters: [any Bindable] = []
        var requiresChatJoin = false

        for predicate in predicates {
            let compiled = try compileMessagePredicate(predicate)
            if let whereClause = compiled.whereClause {
                whereParts.append("(\(whereClause))")
                parameters.append(contentsOf: compiled.parameters)
            } else if isOR {
                // OR with a match-all branch is itself match-all.
                return CompiledPredicate(whereClause: nil, parameters: [], requiresChatJoin: false)
            }
            requiresChatJoin = requiresChatJoin || compiled.requiresChatJoin
        }

        let joinedWhereClause = whereParts.isEmpty ? nil : whereParts.joined(separator: " \(joiner) ")
        return CompiledPredicate(
            whereClause: joinedWhereClause,
            parameters: parameters,
            requiresChatJoin: requiresChatJoin
        )
    }

    private func compileChatPredicate(
        _ predicate: ChatPredicate
    ) throws -> CompiledPredicate {
        switch predicate {
        case .all:
            return CompiledPredicate(whereClause: nil, parameters: [], requiresChatJoin: false)
        case .none:
            return CompiledPredicate(whereClause: "1 = 0", parameters: [], requiresChatJoin: false)
        case .participantHandles(let handles, let match):
            if handles.isEmpty {
                let whereClause = match == .all ? nil : "1 = 0"
                return CompiledPredicate(
                    whereClause: whereClause,
                    parameters: [],
                    requiresChatJoin: false
                )
            }

            let handleValues = orderedHandleValues(handles)
            let placeholders = placeholders(handles.count)
            switch match {
            case .any:
                let condition = """
                    c.ROWID IN (
                        SELECT chat_id
                        FROM chat_handle_join chj
                        JOIN handle h ON chj.handle_id = h.ROWID
                        WHERE h.id IN (\(placeholders))
                    )
                    """
                return CompiledPredicate(
                    whereClause: condition,
                    parameters: toBindableStrings(handleValues),
                    requiresChatJoin: false
                )
            case .all:
                let condition = """
                    c.ROWID IN (
                        SELECT chat_id
                        FROM chat_handle_join chj
                        JOIN handle h ON chj.handle_id = h.ROWID
                        WHERE h.id IN (\(placeholders))
                        GROUP BY chat_id
                        HAVING COUNT(DISTINCT handle_id) = ?
                    )
                    """
                var parameters = toBindableStrings(handleValues)
                parameters.append(try bindableInt32(handles.count, name: "participant count"))
                return CompiledPredicate(
                    whereClause: condition,
                    parameters: parameters,
                    requiresChatJoin: false
                )
            }
        case .dateRange(let dateRange):
            let upperBound = try requireNanoseconds(dateRange.upperBound, label: "upperBound")
            let lowerBound = try requireNanoseconds(dateRange.lowerBound, label: "lowerBound")
            return CompiledPredicate(
                whereClause: "m.date < ? AND m.date >= ?",
                parameters: [upperBound, lowerBound],
                requiresChatJoin: false
            )
        case .and(let predicates):
            if predicates.isEmpty {
                return CompiledPredicate(whereClause: nil, parameters: [], requiresChatJoin: false)
            }
            return try combineChatPredicates(predicates, joiner: "AND")
        case .or(let predicates):
            if predicates.isEmpty {
                return CompiledPredicate(whereClause: "1 = 0", parameters: [], requiresChatJoin: false)
            }
            return try combineChatPredicates(predicates, joiner: "OR")
        case .not(let predicate):
            let compiled = try compileChatPredicate(predicate)
            let whereClause = compiled.whereClause ?? "1 = 1"
            return CompiledPredicate(
                whereClause: "NOT (\(whereClause))",
                parameters: compiled.parameters,
                requiresChatJoin: false
            )
        }
    }

    private func combineChatPredicates(
        _ predicates: [ChatPredicate],
        joiner: String
    ) throws -> CompiledPredicate {
        let isOR = joiner == "OR"
        var whereParts: [String] = []
        var parameters: [any Bindable] = []

        for predicate in predicates {
            let compiled = try compileChatPredicate(predicate)
            if let whereClause = compiled.whereClause {
                whereParts.append("(\(whereClause))")
                parameters.append(contentsOf: compiled.parameters)
            } else if isOR {
                // OR with a match-all branch is itself match-all.
                return CompiledPredicate(whereClause: nil, parameters: [], requiresChatJoin: false)
            }
        }

        return CompiledPredicate(
            whereClause: whereParts.isEmpty ? nil : whereParts.joined(separator: " \(joiner) "),
            parameters: parameters,
            requiresChatJoin: false
        )
    }

    private func messageOrderByClause(_ descriptors: [MessageSortDescriptor]) -> String {
        let descriptors = descriptors.isEmpty ? [.date(.descending), .id(.descending)] : descriptors
        return descriptors.map { descriptor in
            switch descriptor {
            case .date(let order):
                return "m.date \(order.sqlKeyword)"
            case .id(let order):
                return "m.guid \(order.sqlKeyword)"
            }
        }.joined(separator: ", ")
    }

    private func chatOrderByClause(_ descriptors: [ChatSortDescriptor]) -> String {
        let descriptors = descriptors.isEmpty ? [.lastMessageDate(.descending), .id(.ascending)] : descriptors
        return descriptors.map { descriptor in
            switch descriptor {
            case .lastMessageDate(let order):
                return "last_message_date \(order.sqlKeyword)"
            case .id(let order):
                return "c.guid \(order.sqlKeyword)"
            }
        }.joined(separator: ", ")
    }

    private func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private func orderedHandleValues(_ handles: Set<Account.Handle>) -> [String] {
        handles.map(\.rawValue).sorted()
    }

    private func toBindableStrings(_ values: [String]) -> [any Bindable] {
        values.map { $0 as any Bindable }
    }

    private func requireNanoseconds(_ date: Date, label: String) throws -> Int64 {
        guard let value = date.nanosecondsSinceReferenceDate else {
            throw Error.queryError("Could not represent \(label) as Int64 nanoseconds.")
        }
        return value
    }

    private func validatePagination(limit: Int, offset: Int) throws {
        guard limit >= 0 else {
            throw Error.queryError("limit must be >= 0")
        }
        guard offset >= 0 else {
            throw Error.queryError("offset must be >= 0")
        }
    }

    private func bindableInt32(_ value: Int, name: String) throws -> Int32 {
        guard value <= Int(Int32.max), value >= Int(Int32.min) else {
            throw Error.queryError("\(name) is out of Int32 range.")
        }
        return Int32(value)
    }

    /// Fetches participants for a chat.
    ///
    /// - Parameters:
    ///   - chatId: The chat identifier to query.
    ///   - limit: The maximum number of participants to return.
    /// - Returns: Participant handles associated with the chat.
    /// - Throws: ``Error/queryError(_:)`` when SQL preparation or execution fails.
    public func fetchParticipants(
        for chatId: Chat.ID,
        limit: Int = 100
    ) throws -> [Account.Handle] {
        let query = """
                SELECT h.id
                FROM chat c
                JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                JOIN handle h ON chj.handle_id = h.ROWID
                WHERE c.guid = ?
                LIMIT ?
            """
        let parameters: [any Bindable] = [
            chatId.rawValue,
            Int32(limit),
        ]

        return try execute(query, parameters: parameters) { statement in
            guard let idText = sqlite3_column_text(statement, 0) else { return nil }
            return Account.Handle(rawValue: String(cString: idText))
        }
    }

    @available(iOS 16.0, *)
    @available(macOS 13.0, *)
    /// Fetches participants whose aliases match the provided inputs.
    ///
    /// The matcher handles exact IDs, uncanonicalized IDs,
    /// and suffix matches for normalized phone numbers.
    ///
    /// - Parameters:
    ///   - aliases: Candidate phone numbers or email addresses to match.
    ///   - limit: The maximum number of handles to return.
    /// - Returns: Matching participant handles.
    /// - Throws: ``Error/queryError(_:)`` when SQL preparation or execution fails.
    public func fetchParticipant(
        matching aliases: [String],
        limit: Int = 100
    ) throws -> [Account.Handle] {
        guard !aliases.isEmpty else { return [] }

        // Normalize the input phone numbers/emails
        let normalized = aliases.map { alias in
            if alias.contains("@") {
                // Email: just lowercase
                return alias.lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // Phone: remove formatting characters
                return alias.replacing(/[\s\(\)\-]/, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Create the placeholder strings for IN clauses
        let placeholders = Array(repeating: "?", count: normalized.count).joined(separator: ",")

        let query = """
                SELECT DISTINCT h.id
                FROM handle h
                WHERE h.id IN (\(placeholders))
                   OR h.uncanonicalized_id IN (\(placeholders))
                   OR (\(normalized.map { _ in "h.id LIKE '%' || ?" }.joined(separator: " OR ")))
                LIMIT ?
            """

        var parameters: [any Bindable] = []
        // Exact matches with id
        parameters.append(contentsOf: normalized)
        // Match original inputs with uncanonicalized_id
        parameters.append(contentsOf: aliases)
        // Match as suffix of handle id (handles varying country code prefixes)
        parameters.append(contentsOf: normalized)
        // Add limit
        parameters.append(Int32(limit))

        return try execute(query, parameters: parameters) { statement in
            guard let idText = sqlite3_column_text(statement, 0) else { return nil }
            return Account.Handle(rawValue: String(cString: idText))
        }
    }

    private func withTransaction<T>(_ block: () throws -> T) throws -> T {
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw Error.queryError(String(cString: sqlite3_errmsg(db)))
        }

        do {
            let result = try block()
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw Error.queryError(String(cString: sqlite3_errmsg(db)))
            }
            return result
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }
}

// MARK: -

private extension SortOrder {
    var sqlKeyword: String {
        switch self {
        case .ascending: "ASC"
        case .descending: "DESC"
        }
    }
}

private protocol Bindable {
    func bind(to statement: OpaquePointer, at index: Int32)
}

extension String: Bindable {
    func bind(to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, self, -1, SQLITE_TRANSIENT)
    }
}

extension Double: Bindable {
    fileprivate func bind(to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_double(statement, index, self)
    }
}

extension Int32: Bindable {
    fileprivate func bind(to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_int(statement, index, self)
    }
}

extension Int64: Bindable {
    fileprivate func bind(to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_int64(statement, index, self)
    }
}
