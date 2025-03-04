import SQLite3
@testable import iMessage

extension Database {
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(self.db, sql, nil, nil, &error) != SQLITE_OK {
            let message = String(cString: error!)
            sqlite3_free(error)
            throw Database.Error.queryError(message)
        }
    }
}
