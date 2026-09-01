import Foundation
import SQLite3
import Testing

@testable import iMessage

/// A WAL-mode database with one row checkpointed into the main file and a second row
/// still in the write-ahead log. The writer stays open so nothing checkpoints it.
private final class WALFixture {
    let path: String
    private var writer: OpaquePointer?

    init() throws {
        path =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("madrid-\(UUID().uuidString).db").path
        guard
            sqlite3_open_v2(path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK
        else {
            throw Database.Error.failedToOpen(String(cString: sqlite3_errmsg(writer)))
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE t(x INTEGER)")
        try execute("INSERT INTO t VALUES (1)")
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("INSERT INTO t VALUES (2)")
    }

    deinit {
        sqlite3_close(writer)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(writer, sql, nil, nil, &error) != SQLITE_OK {
            let message = String(cString: error!)
            sqlite3_free(error)
            throw Database.Error.queryError(message)
        }
    }
}

private func rowCount(_ db: Database) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db.db, "SELECT count(*) FROM t", -1, &statement, nil) == SQLITE_OK,
        sqlite3_step(statement) == SQLITE_ROW
    else {
        throw Database.Error.queryError(String(cString: sqlite3_errmsg(db.db)))
    }
    defer { sqlite3_finalize(statement) }
    return Int(sqlite3_column_int64(statement, 0))
}

@Suite(.serialized)
struct AccessModeTests {
    @Test
    func liveReadsTheWriteAheadLog() throws {
        let fixture = try WALFixture()
        let db = try Database(path: fixture.path, mode: .live)
        #expect(db.accessMode == .live)
        #expect(try rowCount(db) == 2)
    }

    @Test
    func immutableStopsAtTheLastCheckpoint() throws {
        let fixture = try WALFixture()
        let db = try Database(path: fixture.path, mode: .immutable)
        #expect(db.accessMode == .immutable)
        #expect(try rowCount(db) == 1)
    }

    @Test
    func liveReadsThroughReadOnlyCompanions() throws {
        // A sandboxed reader gets the Messages folder read-only: SQLite must cope with a
        // `-shm` it cannot write to.
        let fixture = try WALFixture()
        let attributes = [FileAttributeKey.posixPermissions: 0o444]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: fixture.path + "-wal")
        try FileManager.default.setAttributes(attributes, ofItemAtPath: fixture.path + "-shm")
        defer {
            let restore = [FileAttributeKey.posixPermissions: 0o644]
            try? FileManager.default.setAttributes(restore, ofItemAtPath: fixture.path + "-wal")
            try? FileManager.default.setAttributes(restore, ofItemAtPath: fixture.path + "-shm")
        }
        let db = try Database(path: fixture.path, mode: .live)
        #expect(db.accessMode == .live)
        #expect(try rowCount(db) == 2)
    }

    @Test
    func automaticPrefersLiveWhenTheLogIsReadable() throws {
        let fixture = try WALFixture()
        let db = try Database(path: fixture.path)
        #expect(db.accessMode == .live)
        #expect(try rowCount(db) == 2)
    }

    @Test
    func automaticFallsBackWhenTheLogIsUnreadable() throws {
        let fixture = try WALFixture()
        // Take the companions away from the reader the way a single-file grant does.
        let attributes = [FileAttributeKey.posixPermissions: 0]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: fixture.path + "-wal")
        try FileManager.default.setAttributes(attributes, ofItemAtPath: fixture.path + "-shm")
        defer {
            let restore = [FileAttributeKey.posixPermissions: 0o644]
            try? FileManager.default.setAttributes(restore, ofItemAtPath: fixture.path + "-wal")
            try? FileManager.default.setAttributes(restore, ofItemAtPath: fixture.path + "-shm")
        }
        let db = try Database(path: fixture.path)
        #expect(db.accessMode == .immutable)
        #expect(try rowCount(db) == 1)
    }
}
