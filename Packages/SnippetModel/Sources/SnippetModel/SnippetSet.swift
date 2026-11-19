public import Foundation

/// Something wrong with a file that belongs to a set.
public struct SetProblem: Hashable, Sendable {
    public enum Severity: Hashable, Sendable {
        /// The file could not be read or parsed, so none of its matches are shown.
        case unreadable
        /// The file was read, but part of it was skipped.
        case skipped
    }

    public var severity: Severity
    /// Path relative to the config folder.
    public var file: String
    public var line: Int?
    public var message: String

    public init(severity: Severity, file: String, line: Int? = nil, message: String) {
        self.severity = severity
        self.file = file
        self.line = line
        self.message = message
    }
}

/// A file that makes up a set.
public struct SetFile: Hashable, Sendable {
    /// Path relative to the config folder, such as `match/work.yml`.
    public var path: String
    public var url: URL

    public init(path: String, url: URL) {
        self.path = path
        self.url = url
    }
}

/// One row of the sidebar: a match file, or an installed package.
public struct SnippetSet: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case abbreviations
        case regularExpressions
        case package
    }

    /// Path relative to `match/`: the file for a set, the folder for a package.
    public var id: String
    public var name: String
    public var kind: Kind
    /// False for a file whose name starts with an underscore, which Espanso does not load by itself.
    public var isEnabled: Bool
    public var files: [SetFile]
    public var snippets: [Snippet]
    public var problems: [SetProblem]
    /// The version from a package's manifest.
    public var packageVersion: String?
    /// What a package's manifest says about it.
    public var packageInfo: PackageInfo?
    /// What the app remembers about the set: prefix, defaults, notes and so on.
    public var info = SetInfo()
    /// The file's `global_vars:`.
    public var globalVariables: [GlobalVariable] = []
    /// The file's `global_vars:` list, in full.
    public var globalVariableList: [SnippetVariable] = []
    /// False when the app can't rewrite `global_vars:` safely.
    public var globalVariablesAreEditable = true

    public init(
        id: String,
        name: String,
        kind: Kind,
        isEnabled: Bool,
        files: [SetFile],
        snippets: [Snippet] = [],
        problems: [SetProblem] = [],
        packageVersion: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isEnabled = isEnabled
        self.files = files
        self.snippets = snippets
        self.problems = problems
        self.packageVersion = packageVersion
    }

    /// Packages are read-only.
    public var isLocked: Bool { kind == .package }

    /// True when a file of the set could not be parsed.
    public var isBroken: Bool {
        problems.contains { $0.severity == .unreadable }
    }

    /// A display name derived from a file or folder name: `_email-signatures.yml` becomes "Email signatures".
    public static func displayName(forFileName fileName: String) -> String {
        var base = fileName
        for suffix in [".yml", ".yaml"] where base.lowercased().hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            break
        }
        while base.hasPrefix("_") {
            base.removeFirst()
        }
        let words = base
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .joined(separator: " ")
        guard let first = words.first else { return fileName }
        return first.uppercased() + words.dropFirst()
    }
}
