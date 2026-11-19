public import Foundation
public import SnippetModel

/// What a package's `_manifest.yml` says about it.
public struct PackageManifest: Equatable, Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var version: String
    public var author: String

    public init(name: String = "", title: String = "", description: String = "", version: String = "0.1.0", author: String = "") {
        self.name = name
        self.title = title
        self.description = description
        self.version = version
        self.author = author
    }

    /// What has to change before the package can be written. Nil when it is fine.
    public var problem: String? {
        if name.isEmpty { return "Give the package a name." }
        let nameIsPlain = name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
        if !nameIsPlain || name.hasPrefix("-") || name.hasSuffix("-") {
            return "The name may hold only lowercase letters, digits and hyphens."
        }
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the package a title." }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count != 3 || !parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) {
            return "Write the version as three numbers, such as 0.1.0."
        }
        return nil
    }

    /// A package name made from a set's name.
    public static func name(forSetNamed name: String) -> String {
        SetManager.slug(for: name)
    }
}

/// Writes a set as a package folder that `espanso install <name> --git <url> --external` accepts once the
/// folder is the root of a git repository.
public enum PackageExporter {
    /// Creates `<parent>/<name>/` with `package.yml`, `_manifest.yml` and `README.md`, and returns the folder.
    ///
    /// - Parameter matchFile: The set's file, copied as it is.
    public static func export(
        matchFile: Data, snippets: [Snippet], manifest: PackageManifest, to parent: URL
    ) throws(EditError) -> URL {
        if let problem = manifest.problem { throw .invalidDraft(problem) }
        let folder = parent.appendingPathComponent(manifest.name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw .fileSystem("There is already an item named \(manifest.name) in that folder.")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try matchFile.write(to: folder.appendingPathComponent("package.yml"))
            try Data(manifestText(manifest).utf8).write(to: folder.appendingPathComponent("_manifest.yml"))
            try Data(readme(manifest, snippets: snippets).utf8).write(to: folder.appendingPathComponent("README.md"))
        } catch {
            throw .fileSystem("The package could not be written: \(error.localizedDescription)")
        }
        return folder
    }

    static func manifestText(_ manifest: PackageManifest) -> String {
        func line(_ key: String, _ value: String) -> String {
            key + ": " + ConfigFileEditor.quoted(value.trimmingCharacters(in: .whitespacesAndNewlines)) + "\n"
        }
        return line("name", manifest.name) + line("title", manifest.title)
            + line("description", manifest.description) + line("version", manifest.version)
            + line("author", manifest.author)
    }

    static func readme(_ manifest: PackageManifest, snippets: [Snippet]) -> String {
        var text = "# \(manifest.title.trimmingCharacters(in: .whitespaces))\n\n"
        let description = manifest.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { text += description + "\n\n" }
        let author = manifest.author.trimmingCharacters(in: .whitespaces)
        text += "Version \(manifest.version)" + (author.isEmpty ? "" : ", by \(author)") + ".\n\n"
        text += "## Install\n\n"
        text += "Put this folder in a git repository of its own, then run:\n\n"
        text += "    espanso install \(manifest.name) --git <repository URL> --external\n\n"
        text += "## Contents\n\n"
        if snippets.isEmpty { text += "This package has no items yet.\n" }
        for snippet in snippets {
            let names = (snippet.regex.map { [$0] } ?? snippet.triggers).map(code).joined(separator: ", ")
            let summary = self.summary(of: snippet)
            text += "- " + names + (summary.isEmpty ? "" : ": " + summary) + "\n"
        }
        return text
    }

    /// Text as inline code, whatever backquotes it holds.
    private static func code(_ text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
        return fence + pad + text + pad + fence
    }

    /// The item's description, or the start of its text.
    private static func summary(of snippet: Snippet) -> String {
        if let label = snippet.label, !label.isEmpty { return escaped(label) }
        switch snippet.expansion {
        case .image: return "a picture"
        case .missing: return ""
        default: break
        }
        let line = snippet.expansion.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let short = line.count > 70 ? String(line.prefix(70)) + "\u{2026}" : line
        return escaped(short.trimmingCharacters(in: .whitespaces))
    }

    /// Keeps Markdown from reading the text as markup.
    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]<>#|".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
