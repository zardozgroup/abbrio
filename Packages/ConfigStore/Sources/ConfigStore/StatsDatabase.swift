public import Foundation
public import SnippetModel
import SQLite3

/// Why Espanso's statistics could not be read from its database.
public enum StatsDatabaseError: Error, Equatable, Sendable {
    /// There is no `stats.db`. Espanso creates it only once statistics are switched on.
    case missing
    /// The tables or columns are not the ones this reader knows, so nothing was read.
    case unknownLayout
    case unreadable(String)
}

/// Reads `$CONFIG/stats.db`, the database Espanso keeps its usage counts in.
///
/// The file is opened where it is and read-only: it runs in write-ahead mode, so a copy would miss recent
/// rows. Nothing is ever written. The layout is not documented, so it is checked before each read.
public struct StatsDatabase: Sendable {
    public var url: URL

    public init(configFolder: URL) {
        url = configFolder.appendingPathComponent("stats.db")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// How often each piece of typed text was expanded since a moment, or in all with nil.
    public func counts(since start: Date?) throws(StatsDatabaseError) -> [UsageCount] {
        var sql = "SELECT t.name, COUNT(*) FROM expansions e JOIN triggers t ON t.id = e.trigger_id"
        if start != nil { sql += " WHERE e.timestamp >= ?1" }
        sql += " GROUP BY t.name ORDER BY COUNT(*) DESC, t.name"
        return try query(sql, bind: start.map(Self.timestamp)) { statement in
            guard let name = sqlite3_column_text(statement, 0) else { return nil }
            return UsageCount(typed: String(cString: name), count: Int(sqlite3_column_int64(statement, 1)))
        }
    }

    /// The last expansion of each piece of typed text, newest first.
    public func recents(limit: Int = 100) throws(StatsDatabaseError) -> [UsageMoment] {
        let sql = """
        SELECT t.name, MAX(e.timestamp) FROM expansions e JOIN triggers t ON t.id = e.trigger_id \
        GROUP BY t.name ORDER BY MAX(e.timestamp) DESC LIMIT \(max(1, limit))
        """
        return try query(sql, bind: nil) { statement in
            guard let name = sqlite3_column_text(statement, 0), let stamp = sqlite3_column_text(statement, 1),
                  let date = Self.date(String(cString: stamp))
            else { return nil }
            return UsageMoment(typed: String(cString: name), date: date)
        }
    }

    /// Espanso writes its timestamps as text in UTC, which sorts in time order.
    static func timestamp(_ date: Date) -> String { formatter.string(from: date) }

    static func date(_ timestamp: String) -> Date? { formatter.date(from: String(timestamp.prefix(19))) }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func query<Row>(
        _ sql: String, bind: String?, row: (OpaquePointer) -> Row?
    ) throws(StatsDatabaseError) -> [Row] {
        guard exists else { throw .missing }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(location, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "The file could not be opened."
            sqlite3_close(handle)
            throw .unreadable(message)
        }
        defer { sqlite3_close(handle) }
        // Espanso may be writing at the same moment.
        sqlite3_busy_timeout(handle, 500)

        guard try columns(of: "triggers", in: handle).isSuperset(of: ["id", "name"]),
              try columns(of: "expansions", in: handle).isSuperset(of: ["trigger_id", "timestamp"])
        else { throw .unknownLayout }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw .unreadable(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        if let bind {
            // The text must outlive the call, so SQLite is told to copy it.
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, bind, -1, transient)
        }
        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                if let value = row(statement) { rows.append(value) }
            } else if step == SQLITE_DONE {
                return rows
            } else {
                throw .unreadable(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    /// How SQLite is told to open the file.
    ///
    /// Espanso closes the database after its last write and removes the write-ahead files. A database in
    /// that mode can't then be opened read-only in the usual way, because SQLite would have to create those
    /// files. With no write-ahead file, everything is in the main file, so it is read as a file that does
    /// not change, which needs no other files and takes no locks.
    private var location: String {
        let hasWriteAheadFile = FileManager.default.fileExists(atPath: url.path + "-wal")
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? url.path
        return "file:" + path + (hasWriteAheadFile ? "?mode=ro" : "?immutable=1")
    }

    private func columns(of table: String, in handle: OpaquePointer) throws(StatsDatabaseError) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw .unreadable(String(cString: sqlite3_errmsg(handle))) }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
        }
        return names
    }
}
