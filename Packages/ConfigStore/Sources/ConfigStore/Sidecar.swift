public import Foundation
public import SnippetModel

/// What the app notes about one match.
public struct MatchNote: Codable, Hashable, Sendable {
    public var caseMode: CaseMode

    public init(caseMode: CaseMode) {
        self.caseMode = caseMode
    }
}

/// The app's own notes about a config folder, kept in `.abbrio/metadata.json`.
///
/// Espanso never reads the file. Entries for files or abbreviations that no longer exist are left alone and
/// ignored, so a folder that is synced or edited by hand never breaks the app.
public struct Sidecar: Codable, Equatable, Sendable {
    public var version = 1
    /// Per set, keyed by the file's path relative to `match/`.
    public var sets: [String: SetInfo] = [:]
    /// Per match, keyed by the set and then by the abbreviation without prefix and suffix.
    public var matches: [String: [String: MatchNote]] = [:]

    public init() {}

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? values.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        sets = (try? values.decodeIfPresent([String: SetInfo].self, forKey: .sets)) ?? [:]
        matches = (try? values.decodeIfPresent([String: [String: MatchNote]].self, forKey: .matches)) ?? [:]
    }

    public func info(for setID: String) -> SetInfo {
        sets[setID] ?? SetInfo()
    }

    public mutating func setInfo(_ info: SetInfo, for setID: String) {
        sets[setID] = info.isEmpty ? nil : info
    }

    public func isCaseInsensitive(_ abbreviation: String, in setID: String) -> Bool {
        matches[setID]?[abbreviation]?.caseMode == .insensitive
    }

    public mutating func setCaseInsensitive(_ isInsensitive: Bool, for abbreviation: String, in setID: String) {
        if isInsensitive {
            matches[setID, default: [:]][abbreviation] = MatchNote(caseMode: .insensitive)
        } else {
            matches[setID]?[abbreviation] = nil
            if matches[setID]?.isEmpty == true { matches[setID] = nil }
        }
    }

    /// Carries a set's notes along when its file gets another name.
    public mutating func moveSet(from old: String, to new: String) {
        guard old != new else { return }
        if let info = sets.removeValue(forKey: old) { sets[new] = info }
        if let notes = matches.removeValue(forKey: old) { matches[new] = notes }
    }

    public mutating func removeSet(_ id: String) {
        sets[id] = nil
        matches[id] = nil
    }
}

/// Reads and writes the sidecar file.
public struct SidecarStore: Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var url: URL {
        root.appendingPathComponent(".abbrio/metadata.json")
    }

    /// The file's bytes, or nil when there is no file.
    public func data() -> Data? {
        try? Data(contentsOf: url)
    }

    /// The notes on disk. A missing or unreadable file gives empty notes.
    public func load() -> Sidecar {
        guard let data = data(), let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) else {
            return Sidecar()
        }
        return sidecar
    }

    public static func encode(_ sidecar: Sidecar) -> Data {
        let encoder = JSONEncoder()
        // Stable output, so a synced folder doesn't see changes where there are none.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(sidecar)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    public func save(_ sidecar: Sidecar) throws(EditError) {
        try write(Self.encode(sidecar))
    }

    /// Writes the file's bytes, or removes the file for nil. Used to save and to undo.
    ///
    /// Espanso restarts for new folders and for names without an extension, so the folder is made only once
    /// and the temporary file ends in `.tmp`.
    public func write(_ data: Data?) throws(EditError) {
        let manager = FileManager.default
        do {
            guard let data else {
                if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
                return
            }
            guard data != self.data() else { return }
            let folder = url.deletingLastPathComponent()
            if !manager.fileExists(atPath: folder.path) {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            if let existing = self.data(), (try? JSONDecoder().decode(Sidecar.self, from: existing)) == nil {
                // Something the app can't read is in the way. Keep a copy before replacing it.
                try existing.write(to: folder.appendingPathComponent("metadata.unreadable.bak"))
            }
            let temporary = folder.appendingPathComponent(".metadata.json.tmp")
            try data.write(to: temporary)
            guard rename(temporary.path, url.path) == 0 else {
                try? manager.removeItem(at: temporary)
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            throw .fileSystem("The app's notes (.abbrio/metadata.json) could not be saved: \(error.localizedDescription)")
        }
    }
}
