public import Foundation
public import ConfigStore
public import SnippetModel

/// A comma- or tab-separated file that was opened for import.
public nonisolated struct PendingImport: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// The file's name, for the sheet's title.
    public var fileName: String
    public var text: String
    /// The name offered for the new set.
    public var suggestedName: String

    public static func == (lhs: PendingImport, rhs: PendingImport) -> Bool { lhs.id == rhs.id }
}

/// Importing lists into new sets, and exporting sets as lists or as packages.
extension AppModel {
    // MARK: Import

    /// Reads a file for the import sheet. Text that is not UTF-8 is read as UTF-16 or, failing that, as
    /// Windows Latin 1, which is what spreadsheets on other systems tend to write.
    public func beginImport(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            alertMessage = "\(url.lastPathComponent) could not be read."
            return
        }
        guard let text = Self.text(from: data) else {
            alertMessage = "\(url.lastPathComponent) does not look like a text file."
            return
        }
        let stem = url.deletingPathExtension().lastPathComponent
        pendingImport = PendingImport(
            fileName: url.lastPathComponent, text: text,
            suggestedName: SnippetSet.displayName(forFileName: stem + ".yml")
        )
    }

    nonisolated static func text(from data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        let startsWithMark = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        if startsWithMark, let text = String(data: data, encoding: .utf16) { return text }
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Creates a set from the rows of an import. Returns false, with an alert, when nothing was written.
    @discardableResult
    public func importSet(named name: String, from source: SnippetImport) -> Bool {
        guard !source.rows.isEmpty else {
            alertMessage = "There is nothing to import."
            return false
        }
        guard createSet(named: name, holding: source.drafts) else { return false }
        pendingImport = nil
        return true
    }

    // MARK: Export

    /// True when a set has something a list can hold.
    public func canExport(_ id: String?) -> Bool {
        guard let set = sets.first(where: { $0.id == id }) else { return false }
        return !set.isBroken
    }

    /// True when a set can be written as a package: one of the user's own sets, in one file.
    public func canExportAsPackage(_ id: String?) -> Bool {
        guard let set = sets.first(where: { $0.id == id }) else { return false }
        return !set.isBroken && !set.isLocked && set.files.count == 1
    }

    /// The set's items as comma-separated text.
    public func listExport(of id: String) -> SnippetExport? {
        sets.first { $0.id == id }.map { SnippetExport(snippets: $0.snippets) }
    }

    /// Writes a set's items to a file as comma-separated text. Returns what was written.
    @discardableResult
    public func exportList(of id: String, to url: URL) -> SnippetExport? {
        commitDraft()
        guard let export = listExport(of: id) else { return nil }
        do {
            try Data(export.text.utf8).write(to: url, options: .atomic)
        } catch {
            alertMessage = "The file could not be saved: \(error.localizedDescription)"
            return nil
        }
        if export.skippedCount > 0 {
            let items = export.skippedCount == 1 ? "1 item was" : "\(export.skippedCount) items were"
            alertMessage = "\(items) left out. Pictures, forms and regular expression rules can't be written as a list."
        }
        return export
    }

    /// What the export sheet starts with for a set.
    public func suggestedManifest(for id: String) -> PackageManifest {
        guard let set = sets.first(where: { $0.id == id }) else { return PackageManifest() }
        return PackageManifest(
            name: PackageManifest.name(forSetNamed: set.name), title: set.name,
            description: set.info.notes.split(whereSeparator: \.isNewline).first.map(String.init) ?? "",
            author: NSFullUserName()
        )
    }

    /// True when the set's file points into the config folder, which a package does not carry along.
    public func refersToConfigFolder(_ id: String) -> Bool {
        guard let path = sets.first(where: { $0.id == id })?.files.first?.path,
              let data = try? writer?.read(path)
        else { return false }
        return String(decoding: data, as: UTF8.self).contains("$CONFIG")
    }

    /// Writes a set as a package folder inside `parent`. Returns the folder, or nil with an alert.
    @discardableResult
    public func exportPackage(of id: String, manifest: PackageManifest, to parent: URL) -> URL? {
        commitDraft()
        guard let set = sets.first(where: { $0.id == id }), let path = set.files.first?.path, let writer else {
            return nil
        }
        do {
            let data = try writer.read(path)
            return try PackageExporter.export(matchFile: data, snippets: set.snippets, manifest: manifest, to: parent)
        } catch {
            alertMessage = error.message
            return nil
        }
    }
}
