import XCTest
import SQLite3
import SnippetModel
@testable import ConfigStore

final class StatsDatabaseTests: XCTestCase {
    private var folder: URL!
    private var root: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("abbrio-stats-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Builds a database with the layout Espanso 2.4.1 uses, in write-ahead mode as Espanso has it.
    private func makeDatabase(_ statements: [String]) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("stats.db").path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        for sql in ["PRAGMA journal_mode=WAL"] + statements {
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, sql)
        }
    }

    private let layout = [
        "CREATE TABLE triggers (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)",
        "CREATE TABLE expansions (id INTEGER PRIMARY KEY, trigger_id INTEGER NOT NULL, timestamp TEXT NOT NULL)",
    ]

    func testCountsAndRecentsAreRead() throws {
        try makeDatabase(layout + [
            "INSERT INTO triggers (id, name) VALUES (1, ';sig'), (2, 'Btw'), (3, 'héllo')",
            "INSERT INTO expansions (trigger_id, timestamp) VALUES (1, '2026-11-10 08:00:00'), (1, '2026-11-14 09:30:00'), (2, '2026-11-14 09:00:00'), (1, '2026-11-14 12:00:00'), (3, '2026-01-01 00:00:00')",
        ])
        let database = StatsDatabase(configFolder: folder)
        XCTAssertTrue(database.exists)
        XCTAssertEqual(try database.counts(since: nil), [
            UsageCount(typed: ";sig", count: 3), UsageCount(typed: "Btw", count: 1), UsageCount(typed: "héllo", count: 1),
        ])
        let start = try XCTUnwrap(StatsDatabase.date("2026-11-14 09:00:00"))
        XCTAssertEqual(try database.counts(since: start), [UsageCount(typed: ";sig", count: 2), UsageCount(typed: "Btw", count: 1)])
        XCTAssertEqual(try database.counts(since: start.addingTimeInterval(1)), [UsageCount(typed: ";sig", count: 2)])

        let recents = try database.recents()
        XCTAssertEqual(recents.map(\.typed), [";sig", "Btw", "héllo"])
        XCTAssertEqual(recents.first?.date, StatsDatabase.date("2026-11-14 12:00:00"))
        XCTAssertEqual(try database.recents(limit: 1).count, 1)
        XCTAssertEqual(StatsDatabase.timestamp(start), "2026-11-14 09:00:00")
    }

    func testReadingLeavesTheFilesUntouched() throws {
        try makeDatabase(layout + ["INSERT INTO triggers (id, name) VALUES (1, 'a')", "INSERT INTO expansions (trigger_id, timestamp) VALUES (1, '2026-11-14 09:30:00')"])
        let file = folder.appendingPathComponent("stats.db")
        let before = try Data(contentsOf: file)
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        _ = try StatsDatabase(configFolder: folder).counts(since: nil)
        _ = try StatsDatabase(configFolder: folder).recents()
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, modified)
    }

    func testADatabaseEspansoHasClosedIsRead() throws {
        // Espanso removes the write-ahead files when it closes the database; the main file stays marked
        // as being in that mode.
        try makeDatabase(layout + [
            "INSERT INTO triggers (id, name) VALUES (1, ';sig')",
            "INSERT INTO expansions (trigger_id, timestamp) VALUES (1, '2026-11-14 09:30:00')",
            "PRAGMA wal_checkpoint(TRUNCATE)",
        ])
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("stats.db" + suffix))
        }
        let database = StatsDatabase(configFolder: folder)
        XCTAssertEqual(try database.counts(since: nil), [UsageCount(typed: ";sig", count: 1)])
        XCTAssertEqual(try database.recents().map(\.typed), [";sig"])
        // Reading created nothing next to the file.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["stats.db"])
    }

    func testAFolderNameWithSpacesAndMarksIsRead() throws {
        let odd = folder.appendingPathComponent("Application Support #1?")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        folder = odd
        try makeDatabase(layout + ["INSERT INTO triggers (id, name) VALUES (1, 'a')", "INSERT INTO expansions (trigger_id, timestamp) VALUES (1, '2026-11-14 09:30:00')"])
        XCTAssertEqual(try StatsDatabase(configFolder: odd).counts(since: nil).count, 1)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(at: odd.appendingPathComponent("stats.db" + suffix)) }
        XCTAssertEqual(try StatsDatabase(configFolder: odd).counts(since: nil).count, 1)
    }

    func testAMissingDatabaseAndAnUnknownLayoutAreReported() throws {
        let database = StatsDatabase(configFolder: folder)
        XCTAssertFalse(database.exists)
        XCTAssertThrowsError(try database.counts(since: nil)) { XCTAssertEqual($0 as? StatsDatabaseError, .missing) }

        try makeDatabase(["CREATE TABLE triggers (id INTEGER PRIMARY KEY, label TEXT)", layout[1]])
        XCTAssertThrowsError(try database.counts(since: nil)) { XCTAssertEqual($0 as? StatsDatabaseError, .unknownLayout) }
        XCTAssertThrowsError(try database.recents()) { XCTAssertEqual($0 as? StatsDatabaseError, .unknownLayout) }
    }

    func testAFileThatIsNotADatabaseIsReported() throws {
        try Data("not a database".utf8).write(to: folder.appendingPathComponent("stats.db"))
        XCTAssertThrowsError(try StatsDatabase(configFolder: folder).counts(since: nil)) { error in
            guard case .unreadable? = error as? StatsDatabaseError else { return XCTFail("\(error)") }
        }
    }
}
