public import Foundation

/// Something the log says about whether Espanso can expand right now.
public enum EngineEvent: Hashable, Sendable {
    /// Expansions were switched off, with the toggle key or `espanso cmd disable`.
    case paused
    case resumed
    /// A new worker started. It always starts with expansions on.
    case workerStarted
    /// An app took Secure Input. The name is Espanso's guess and may be wrong.
    case secureInputAcquired(holder: String?)
    case secureInputReleased

    /// Reads one line of the log. Nil for a line that says nothing about these states.
    public init?(logLine line: some StringProtocol) {
        if line.contains("toggled enabled state, is_enabled = false") {
            self = .paused
        } else if line.contains("toggled enabled state, is_enabled = true") {
            self = .resumed
        } else if line.contains("spawning the worker process") {
            self = .workerStarted
        } else if line.contains("secure input has been acquired") {
            var holder: String?
            if let open = line.range(of: "caused by '"), let close = line[open.upperBound...].firstIndex(of: "'") {
                let name = String(line[open.upperBound..<close])
                if !name.isEmpty { holder = name }
            }
            self = .secureInputAcquired(holder: holder)
        } else if line.contains("secure input has been disabled") {
            self = .secureInputReleased
        } else {
            return nil
        }
    }
}

/// Reads Espanso's log file to see what the service did.
public struct EngineLog: Sendable {
    public var url: URL

    /// The line the service writes when it notices a changed config file.
    static let reloadMarker = "configuration change detected"

    public init(runtimeFolder: URL) {
        url = runtimeFolder.appendingPathComponent("espanso.log")
    }

    /// The size of the log now. Pass it to `hasReloaded(since:)` later.
    public func position() -> UInt64 {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return size?.uint64Value ?? 0
    }

    /// True when the log gained a reload line after `position`.
    public func hasReloaded(since position: UInt64) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // A log that shrank was rotated; read it from the start.
        let start = position <= self.position() ? position : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return false }
        return String(decoding: data, as: UTF8.self).contains(Self.reloadMarker)
    }

    /// Waits for a reload line, checking a few times a second.
    public func waitForReload(since position: UInt64, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if hasReloaded(since: position) { return true }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return false
            }
        }
        return hasReloaded(since: position)
    }

    /// The state changes written to the log after `position`, in order, and the position to continue from.
    ///
    /// A first read passes nil and gets the events from the last part of the log. Only whole lines are read;
    /// a line still being written is left for the next call.
    public func events(since position: UInt64?) -> (events: [EngineEvent], position: UInt64) {
        let size = self.position()
        // A log that shrank was rotated; read it from the start.
        var start = position.map { $0 <= size ? $0 : 0 } ?? (size > Self.firstReadLimit ? size - Self.firstReadLimit : 0)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], start) }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(),
              let lastBreak = data.lastIndex(of: UInt8(ascii: "\n"))
        else { return ([], start) }
        let whole = data[data.startIndex...lastBreak]
        start += UInt64(whole.count)
        let events = String(decoding: whole, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { EngineEvent(logLine: $0) }
        return (events, start)
    }

    /// How much of an existing log is read the first time.
    static let firstReadLimit: UInt64 = 512 * 1024
}
