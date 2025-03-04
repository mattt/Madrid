import Foundation
import TypedStream
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class Database {
    var db: OpaquePointer?

    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: Int32

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

    public enum Error: Swift.Error {
        case databaseNotFound
        case failedToOpen(String)
        case queryError(String)
    }

    private init(
        _ filename: String,
        flags: Flags = .default
    ) throws {
        if sqlite3_open_v2(filename, &db, flags.rawValue, nil) != SQLITE_OK {
            throw Error.failedToOpen(String(cString: sqlite3_errmsg(db)))
        }
    }

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
        print("Query: ", query)
        print("Parameters: ", parameters)

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

    public func fetchChats(
        with participantHandles: Set<Account.Handle>? = nil,
        in dateRange: Range<Date>? = nil,
        limit: Int = 100
    ) throws -> [Chat] {
        try withTransaction {
            var conditions: [String] = []
            var parameters: [any Bindable] = []

            // Add date range if specified
            if let dateRange = dateRange {
                if let upperBound = dateRange.upperBound.nanosecondsSinceReferenceDate {
                    conditions.append("m.date < ?")
                    parameters.append(Int64(upperBound))
                }
                if let lowerBound = dateRange.lowerBound.nanosecondsSinceReferenceDate {
                    conditions.append("m.date >= ?")
                    parameters.append(Int64(lowerBound))
                }
            }

            // Add participants filter if specified
            if let handles = participantHandles, !handles.isEmpty {
                conditions.append(
                    """
                        c.ROWID IN (
                            SELECT chat_id 
                            FROM chat_handle_join chj
                            JOIN handle h ON chj.handle_id = h.ROWID
                            WHERE h.id IN (\(String(repeating: "?,", count: handles.count).dropLast()))
                            GROUP BY chat_id
                            HAVING COUNT(DISTINCT handle_id) = ?
                        )
                    """)

                // Add each participant as a value
                handles.forEach { handle in
                    parameters.append(handle.rawValue)
                }
                // Add the count of participants
                parameters.append(Int32(handles.count))
            }

            let query = """
                    SELECT 
                        c.guid,
                        c.display_name,
                        c.service_name,
                        MAX(m.date) as last_message_date
                    FROM chat c
                    LEFT JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
                    LEFT JOIN message m ON cmj.message_id = m.ROWID
                    \(conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))")
                    GROUP BY c.ROWID
                    ORDER BY last_message_date DESC
                    LIMIT ?
                """

            parameters.append(Int32(limit))

            return try execute(query, parameters: parameters) { statement in
                // Safely handle potentially null columns
                guard let guidText = sqlite3_column_text(statement, 0) else { return nil }
                let chatId = Chat.ID(rawValue: String(cString: guidText))

                let displayName = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let lastMessageDate = Date(
                    nanosecondsSinceReferenceDate: sqlite3_column_int64(statement, 3))

                // Fetch participants for this chat
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

    public func fetchMessages(
        for chatId: Chat.ID? = nil,
        with participantHandles: Set<Account.Handle>? = nil,
        in dateRange: Range<Date>? = nil,
        limit: Int = 100
    ) throws -> [Message] {
        try withTransaction {
            var conditions: [String] = []
            var parameters: [any Bindable] = []

            // Add chat filter if specified
            if let chatId = chatId {
                conditions.append("c.guid = ?")
                parameters.append(chatId.rawValue)
            }

            // Add participants filter if specified
            if let handles = participantHandles, !handles.isEmpty {
                conditions.append(
                    """
                        m.ROWID IN (
                            SELECT m.ROWID
                            FROM message m
                            JOIN handle h ON m.handle_id = h.ROWID
                            WHERE h.id IN (\(String(repeating: "?,", count: handles.count).dropLast()))
                        )
                    """)

                // Add each participant as a value
                handles.forEach { handle in
                    parameters.append(handle.rawValue)
                }
            }

            // Add date range if specified
            if let dateRange = dateRange {
                if let upperBound = dateRange.upperBound.nanosecondsSinceReferenceDate {
                    conditions.append("m.date < ?")
                    parameters.append(upperBound)
                }
                if let lowerBound = dateRange.lowerBound.nanosecondsSinceReferenceDate {
                    conditions.append("m.date >= ?")
                    parameters.append(lowerBound)
                }
            }

            let query = """
                    SELECT 
                        m.guid,
                        m.text,
                        HEX(m.attributedBody),
                        m.date,
                        m.is_from_me,
                        h.id,
                        m.service
                    FROM message m
                    \(chatId != nil ? "JOIN chat_message_join cmj ON m.ROWID = cmj.message_id" : "")
                    \(chatId != nil ? "JOIN chat c ON cmj.chat_id = c.ROWID" : "")
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    \(conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))")
                    ORDER BY m.date DESC
                    LIMIT ?
                """

            parameters.append(Int32(limit))

            return try execute(query, parameters: parameters) { statement in
                let messageID: Message.ID
                if let messageIdText = sqlite3_column_text(statement, 0) {
                    messageID = Message.ID(rawValue: String(cString: messageIdText))
                } else {
                    messageID = "N/A"
                    // FIXME
                }

                // Handle text
                let text: String
                if let rawText = sqlite3_column_text(statement, 1) {
                    text = String(cString: rawText)
                } else if let hexData = sqlite3_column_text(statement, 2).map({
                    String(cString: $0)
                }),
                    let data = Data(hexString: hexData),
                          let plainText = try? TypedStreamDecoder.decode(data).compactMap({ $0.stringValue }).joined(separator: "\n")
                {
                    text = plainText
                } else {
                    text = ""
                }

                let date = Date(
                    nanosecondsSinceReferenceDate: sqlite3_column_int64(statement, 3))
                let isFromMe = sqlite3_column_int(statement, 4) != 0

                let senderText = sqlite3_column_text(statement, 5)
                let sender = senderText.map { Account.Handle(rawValue: String(cString: $0)) }

                return Message(
                    id: messageID,
                    text: text,
                    date: date,
                    isFromMe: isFromMe,
                    sender: sender
                )
            }
        }
    }

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

fileprivate protocol Bindable {
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
