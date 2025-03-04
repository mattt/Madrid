import Foundation
import SQLite3
@testable import iMessage

enum Fixtures {
    static let attributedBody: String = [
        // Header: "streamtyped" (11 bytes)
        "040B",  // Version 4, length 11
        "73747265616D7479706564",  // "streamtyped" in hex
        "81E803",  // System version 1000

        // Start of NSAttributedString object
        "8401",  // Object start marker
        "40",  // Object type
        "848484",  // Object markers

        // Class hierarchy: NSAttributedString -> NSObject
        "124E5341747472696275746564537472696E6700",  // "NSAttributedString" (18 bytes)
        "8484084E534F626A65637400",  // "NSObject" (8 bytes)

        // String content
        "8592",  // String start marker
        "848484",  // String markers
        "084E53537472696E6701",  // "NSString" (8 bytes)
        "948401",  // String content marker
        "2B",  // UTF-8 string type
        "05",  // Length of string (5 bytes)
        "48656C6C6F",  // "Hello" in hex

        // Attributes dictionary
        "868402",  // Dictionary start marker
        "694901",  // Dictionary count (1)
        "0992",  // Dictionary content marker
        "848484",  // Dictionary markers
        "0C4E5344696374696F6E61727900",  // "NSDictionary" (12 bytes)
        "948401",  // Dictionary content marker
        "6901",  // Dictionary count (1)
        "9292",  // Dictionary entry markers
        "965F5F6B494D4261736557726974696E67446972656374696F6E4174747269627574654E616D65",  // "__kIMBaseWritingDirectionAttributeName"
        "8692",  // Attribute value marker
        "848484",  // Value markers
        "084E534E756D62657200",  // "NSNumber" (8 bytes)
        "8484074E5356616C756500",  // "NSValue" (7 bytes)
        "948401",  // Value content marker
        "2A",  // Value type
        "848401",  // Value content marker
        "719DFF",  // Value data
        "8692",  // Next attribute marker
        "849696",  // Attribute markers
        "1D5F5F6B494D4D657373616765506172744174747269627574654E616D65",  // "__kIMMessagePartAttributeName"
        "8692",  // Attribute value marker
        "849B9C9D9D00",  // Attribute value data
        "868686",  // End markers
    ].joined()
    
    static var testDatabase: Database {
        let db = try! Database.inMemory()

        // Create schema
        try! db.execute(
            """
                CREATE TABLE chat (
                    ROWID INTEGER PRIMARY KEY,
                    guid TEXT UNIQUE NOT NULL,
                    display_name TEXT,
                    service_name TEXT
                );
                
                CREATE TABLE handle (
                    ROWID INTEGER PRIMARY KEY,
                    id TEXT NOT NULL,
                    service TEXT
                );
                
                CREATE TABLE message (
                    ROWID INTEGER PRIMARY KEY,
                    guid TEXT UNIQUE NOT NULL,
                    text TEXT,
                    attributedBody BLOB,
                    handle_id INTEGER REFERENCES handle(ROWID),
                    date REAL,
                    is_from_me INTEGER,
                    service TEXT
                );
                
                CREATE TABLE chat_handle_join (
                    chat_id INTEGER REFERENCES chat(ROWID),
                    handle_id INTEGER REFERENCES handle(ROWID)
                );
                
                CREATE TABLE chat_message_join (
                    chat_id INTEGER REFERENCES chat(ROWID),
                    message_id INTEGER REFERENCES message(ROWID)
                );
            """)

        // Insert sample chats
        try! db.execute(
            """
                INSERT INTO chat (ROWID, guid, display_name, service_name)
                VALUES 
                    (1, 'chat-guid-1', 'Sample Group', 'iMessage'),
                    (2, 'chat-guid-2', 'Another Group', 'iMessage');
            """)

        // Insert sample handles (participants)
        try! db.execute(
            """
                INSERT INTO handle (ROWID, id, service)
                VALUES 
                    (1, '+1234567890', 'iMessage'),
                    (2, 'person@example.com', 'iMessage'),
                    (3, 'third@example.com', 'iMessage');
            """)

        // Link handles to chats - chat 2 shares one participant with chat 1
        try! db.execute(
            """
                INSERT INTO chat_handle_join (chat_id, handle_id)
                VALUES 
                    (1, 1), (1, 2),  -- First chat with two participants
                    (2, 1), (2, 3);  -- Second chat with overlapping participant
            """)

        // Insert sample messages with different dates
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        let thirtyMinutesAgo = now.addingTimeInterval(-1800)
        let twoDaysAgo = now.addingTimeInterval(-86400 * 2)
        let twoDaysAndOneHourAgo = twoDaysAgo.addingTimeInterval(3600)

        try! db.execute(
            """
                INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, date, is_from_me, service)
                VALUES 
                    -- Messages for first chat
                    (1, 'msg-guid-1', 'Hello!', NULL, 1, \(oneHourAgo.nanosecondsSinceReferenceDate ?? 0), 0, 'iMessage'),
                    (2, 'msg-guid-2', 'Hi there', NULL, NULL, \(thirtyMinutesAgo.nanosecondsSinceReferenceDate ?? 0), 1, 'iMessage'),
                    (3, 'msg-guid-3', NULL, X'\(Fixtures.attributedBody)', 2, \(now.nanosecondsSinceReferenceDate ?? 0), 0, 'iMessage'),
                    -- Messages for second chat (older)
                    (4, 'msg-guid-4', 'Old message', NULL, 1, \(twoDaysAgo.nanosecondsSinceReferenceDate ?? 0), 0, 'iMessage'),
                    (5, 'msg-guid-5', 'Another old one', NULL, 3, \(twoDaysAndOneHourAgo.nanosecondsSinceReferenceDate ?? 0), 0, 'iMessage');
            """)

        // Link messages to chats
        try! db.execute(
            """
                INSERT INTO chat_message_join (chat_id, message_id)
                VALUES 
                    -- First chat messages (recent)
                    (1, 1), (1, 2), (1, 3),
                    -- Second chat messages (older)
                    (2, 4), (2, 5);
            """)

        return db
    }
}

private func execute(db: OpaquePointer, _ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
        let message = String(cString: error!)
        sqlite3_free(error)
        throw Database.Error.queryError(message)
    }
}
