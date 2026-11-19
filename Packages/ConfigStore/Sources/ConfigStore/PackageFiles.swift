public import Foundation
public import SnippetModel
import Yams

/// What a package archive holds, read before it is installed.
public struct PackageContents: Equatable, Sendable {
    /// The text of `README.md`. Nil when there is none.
    public var readme: String?
    public var snippets: [Snippet]
    /// True when a match file in the archive could not be read.
    public var hasUnreadableFiles: Bool
}

/// Reads the files of a package, installed or unpacked from an archive.
public enum PackageFiles {
    /// Reads `_manifest.yml`. Fields that are missing stay empty; the name falls back to the folder's.
    public static func manifest(at url: URL, folderName: String) -> PackageInfo {
        var info = PackageInfo(name: folderName)
        guard let text = text(at: url), let mapping = (try? Yams.compose(yaml: text))?.mapping else { return info }
        func string(_ key: String) -> String { mapping[key]?.string ?? "" }
        if !string("name").isEmpty { info.name = string("name") }
        info.title = string("title")
        info.description = string("description")
        info.version = string("version")
        info.author = string("author")
        info.homepage = string("homepage")
        info.tags = mapping["tags"]?.sequence?.compactMap(\.string) ?? []
        return info
    }

    /// Reads `_pkgsource.yml`.
    public static func source(at url: URL) -> PackageInfo.Source {
        text(at: url).map(PackageInfo.source(fromFileText:)) ?? .unknown
    }

    /// Builds what the preview shows from the texts read out of an archive: the first README and the items
    /// of every match file. Files are taken in name order, so the result does not depend on the archive's.
    ///
    /// - Parameter unreadable: True when the archive held match files that were not read.
    public static func contents(entries: [(name: String, text: String?)], unreadable: Bool = false) -> PackageContents {
        var contents = PackageContents(readme: nil, snippets: [], hasUnreadableFiles: unreadable)
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            let fileName = (entry.name as NSString).lastPathComponent
            let lowercased = fileName.lowercased()
            var text = entry.text
            if let current = text, current.hasPrefix("\u{FEFF}") { text = String(current.dropFirst()) }
            if lowercased == "readme.md" {
                if contents.readme == nil { contents.readme = text }
            } else if PackageArchive.isMatchFile(fileName) {
                guard let text, let parsed = try? MatchFileParser.parse(text, path: fileName) else {
                    contents.hasUnreadableFiles = true
                    continue
                }
                contents.snippets.append(contentsOf: parsed.snippets)
            }
        }
        return contents
    }

    private static func text(at url: URL) -> String? {
        // A manifest or README is small; anything huge is not one.
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }
}
