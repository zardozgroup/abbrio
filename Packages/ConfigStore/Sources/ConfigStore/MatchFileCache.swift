import Foundation
import os

/// Parsed match files, kept between loads so that a file whose bytes haven't changed isn't parsed again.
///
/// Parsing is most of the cost of a load: a file of 75,000 matches takes over a second. With the cache, a reload
/// after the app changed one small file parses only that file. Files that fail to parse are not kept, so their
/// problem is reported again on the next load. Entries for files a load didn't read are dropped when it ends.
public final class MatchFileCache: Sendable {
    private struct Entry: Sendable {
        var data: Data
        var parsed: ParsedMatchFile
    }

    private struct State: Sendable {
        var entries: [String: Entry] = [:]
        /// Keys read since the last load ended.
        var used: Set<String> = []
        /// How many times a file had to be parsed. Tests read it.
        var parses = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// The number of files parsed and kept since the cache was made.
    public var parseCount: Int { state.withLock { $0.parses } }

    func parsed(for key: String, data: Data) -> ParsedMatchFile? {
        state.withLock { state in
            state.used.insert(key)
            guard let entry = state.entries[key], entry.data == data else { return nil }
            return entry.parsed
        }
    }

    func store(_ parsed: ParsedMatchFile, for key: String, data: Data) {
        state.withLock { state in
            state.entries[key] = Entry(data: data, parsed: parsed)
            state.used.insert(key)
            state.parses += 1
        }
    }

    /// Drops the files the load that just ended didn't read: they were removed or renamed.
    func endLoad() {
        state.withLock { state in
            state.entries = state.entries.filter { state.used.contains($0.key) }
            state.used = []
        }
    }
}
