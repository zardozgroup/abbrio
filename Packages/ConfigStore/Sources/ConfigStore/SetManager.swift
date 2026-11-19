public import Foundation
public import SnippetModel
import Yams

/// Creates, renames, switches and removes the files behind abbreviation sets, and keeps `config/*.yml`
/// pointing at them.
public struct SetManager: Sendable {
    public var writer: ConfigWriter
    /// Removes a file in a way the user can undo. The app moves it to the Trash.
    public var discard: @Sendable (URL) throws -> Void

    public init(
        writer: ConfigWriter,
        discard: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.writer = writer
        self.discard = discard
    }

    /// What a change to a set did.
    public struct Outcome: Equatable, Sendable {
        /// The set's identifier afterwards: its path relative to `match/`. Nil when it was deleted.
        public var id: String?
        /// Config files that still mention the old file because the line could not be changed safely.
        public var remainingReferences: [String] = []
    }

    private var matchDirectory: URL { writer.root.appendingPathComponent("match", isDirectory: true) }
    private var configDirectory: URL { writer.root.appendingPathComponent("config", isDirectory: true) }

    // MARK: Operations

    /// Creates `match/<slug>.yml` with an empty list of matches.
    public func createSet(named name: String) throws(EditError) -> Outcome {
        try createSet(named: name, contents: Data(MatchFileEditor.emptyFileText.utf8))
    }

    /// Creates `match/<slug>.yml` holding the given items, as when a list is imported.
    public func createSet(named name: String, holding drafts: [MatchDraft]) throws(EditError) -> Outcome {
        try createSet(named: name, contents: try MatchFileEditor.newFile(with: drafts, path: Self.slug(for: name) + ".yml"))
    }

    private func createSet(named name: String, contents: Data) throws(EditError) -> Outcome {
        let slug = Self.slug(for: name)
        var fileName = slug + ".yml"
        var suffix = 2
        while nameIsTaken(fileName, in: matchDirectory, ignoring: nil) {
            fileName = "\(slug)-\(suffix).yml"
            suffix += 1
        }
        do {
            try FileManager.default.createDirectory(at: matchDirectory, withIntermediateDirectories: true)
        } catch {
            throw .fileSystem("The match folder could not be created: \(error.localizedDescription)")
        }
        try writer.write(contents, to: "match/" + fileName, replacing: nil)
        return Outcome(id: fileName)
    }

    /// Copies the set's file next to it as `<name>-copy.yml`, keeping its on/off state.
    public func duplicateSet(_ id: String) throws(EditError) -> Outcome {
        let old = matchDirectory.appendingPathComponent(id)
        let data = try writer.read("match/" + id)
        let folder = (id as NSString).deletingLastPathComponent
        let prefix = old.lastPathComponent.hasPrefix("_") ? "_" : ""
        var stem = old.deletingPathExtension().lastPathComponent
        while stem.hasPrefix("_") { stem.removeFirst() }
        let fileExtension = old.pathExtension.isEmpty ? "yml" : old.pathExtension
        var fileName = "\(prefix)\(stem)-copy.\(fileExtension)"
        var number = 2
        while nameIsTaken(fileName, in: old.deletingLastPathComponent(), ignoring: nil) {
            fileName = "\(prefix)\(stem)-copy-\(number).\(fileExtension)"
            number += 1
        }
        let newID = folder.isEmpty ? fileName : folder + "/" + fileName
        try writer.write(data, to: "match/" + newID, replacing: nil)
        return Outcome(id: newID)
    }

    /// Renames the set's file to match a new name, keeping its folder, extension and on/off state.
    public func renameSet(_ id: String, to name: String) throws(EditError) -> Outcome {
        let old = matchDirectory.appendingPathComponent(id)
        let prefix = old.lastPathComponent.hasPrefix("_") ? "_" : ""
        let fileExtension = old.pathExtension.isEmpty ? "yml" : old.pathExtension
        return try move(id, toFileName: prefix + Self.slug(for: name) + "." + fileExtension)
    }

    /// Switches a set on or off by removing or adding the underscore in front of its file name.
    public func setEnabled(_ enabled: Bool, for id: String) throws(EditError) -> Outcome {
        var fileName = (id as NSString).lastPathComponent
        while fileName.hasPrefix("_") { fileName.removeFirst() }
        return try move(id, toFileName: enabled ? fileName : "_" + fileName)
    }

    /// Moves the set's file to the Trash and removes it from the lists in `config/*.yml`.
    public func deleteSet(_ id: String) throws(EditError) -> Outcome {
        let url = matchDirectory.appendingPathComponent(id)
        do {
            try discard(url)
        } catch {
            throw .fileSystem("\(id) could not be moved to the Trash: \(error.localizedDescription)")
        }
        return Outcome(id: nil, remainingReferences: try updateReferences(from: url, to: nil))
    }

    private func move(_ id: String, toFileName fileName: String) throws(EditError) -> Outcome {
        let old = matchDirectory.appendingPathComponent(id)
        let new = old.deletingLastPathComponent().appendingPathComponent(fileName)
        let folder = (id as NSString).deletingLastPathComponent
        let newID = folder.isEmpty ? fileName : folder + "/" + fileName
        guard new.lastPathComponent != old.lastPathComponent else { return Outcome(id: id) }
        guard FileManager.default.fileExists(atPath: old.path) else {
            throw .fileSystem("\(id) is no longer there.")
        }
        guard !nameIsTaken(fileName, in: old.deletingLastPathComponent(), ignoring: old.lastPathComponent) else {
            throw .alreadyExists(fileName)
        }
        guard rename(old.path, new.path) == 0 else {
            throw .fileSystem("\(id) could not be renamed: \(String(cString: strerror(errno)))")
        }
        return Outcome(id: newID, remainingReferences: try updateReferences(from: old, to: new))
    }

    /// True when the folder has that file, switched on or off. The file being renamed doesn't count, also
    /// when a disk that ignores letter case finds it under the new spelling.
    private func nameIsTaken(_ fileName: String, in folder: URL, ignoring current: String?) -> Bool {
        var bare = fileName
        while bare.hasPrefix("_") { bare.removeFirst() }
        return [bare, "_" + bare].contains { candidate in
            if let current, candidate.lowercased() == current.lowercased() { return false }
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path)
        }
    }

    /// A file name for a set name: "Email Signatures!" becomes "email-signatures".
    public static func slug(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var slug = ""
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "untitled" : slug
    }

    // MARK: References in config files

    private static let listKeys: Set<String> = ["includes", "excludes", "extra_includes", "extra_excludes"]

    /// Points list entries in `config/*.yml` at the file's new name, or removes them when `new` is nil.
    /// Returns the config files that still mention the old file.
    private func updateReferences(from old: URL, to new: URL?) throws(EditError) -> [String] {
        let manager = FileManager.default
        let names = ((try? manager.contentsOfDirectory(atPath: configDirectory.path)) ?? []).sorted()
        let target = old.standardizedFileURL.resolvingSymlinksInPath().path
        let folder = old.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        var remaining: [String] = []

        for name in names where name.lowercased().hasSuffix(".yml") || name.lowercased().hasSuffix(".yaml") {
            let path = "config/" + name
            guard let data = try? Data(contentsOf: configDirectory.appendingPathComponent(name)),
                  var document = try? SourceDocument(data),
                  let root = try? Yams.compose(yaml: document.text), case .mapping(let mapping) = root
            else { continue }

            // Lines to change, and keys whose whole list goes away.
            var hits: [(line: Int, keyLine: Int?, isOnlyItem: Bool)] = []
            for (key, value) in mapping {
                guard let keyName = key.string, Self.listKeys.contains(keyName), case .sequence(let items) = value else { continue }
                let matching = items.filter { item in
                    guard let text = item.string else { return false }
                    let resolved = URL(fileURLWithPath: text, relativeTo: configDirectory)
                        .standardizedFileURL.resolvingSymlinksInPath()
                    // The file is gone or renamed by now, so compare the folder and the name.
                    return resolved.path == target
                        || (resolved.deletingLastPathComponent().path == folder
                            && resolved.lastPathComponent == old.lastPathComponent)
                }
                for item in matching {
                    guard let line = item.mark?.line else { continue }
                    hits.append((line, key.mark?.line, matching.count == items.count))
                }
            }
            guard !hits.isEmpty else { continue }

            var changedAll = true
            var keyLinesToDrop: Set<Int> = []
            for hit in hits.sorted(by: { $0.line > $1.line }) {
                let line = document.line(hit.line)
                if let new {
                    guard let range = line.range(of: old.lastPathComponent, options: .backwards) else {
                        changedAll = false
                        continue
                    }
                    document.replace(first: hit.line, last: hit.line,
                                     with: [line.replacingCharacters(in: range, with: new.lastPathComponent)])
                } else {
                    let content = line.drop { $0 == " " }
                    guard content.hasPrefix("- "), hit.keyLine != hit.line else {
                        changedAll = false
                        continue
                    }
                    document.replace(first: hit.line, last: hit.line, with: [])
                    if hit.isOnlyItem, let keyLine = hit.keyLine { keyLinesToDrop.insert(keyLine) }
                }
            }
            if changedAll {
                // A key left without items would read as null, so it goes too.
                for keyLine in keyLinesToDrop.sorted(by: >) where document.line(keyLine).hasSuffix(":") {
                    document.replace(first: keyLine, last: keyLine, with: [])
                }
            } else {
                remaining.append(path)
            }
            // An empty file is fine; text that no longer parses is not.
            do {
                _ = try Yams.compose(yaml: document.text)
            } catch {
                remaining.append(path)
                continue
            }
            try writer.write(document.data, to: path, replacing: data)
        }
        return Array(Set(remaining)).sorted()
    }
}
