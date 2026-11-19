import Foundation

/// A run of whole lines in a source file. Line numbers are 1-based and the range is inclusive.
public struct LineRange: Hashable, Sendable {
    public var first: Int
    public var last: Int

    public init(first: Int, last: Int) {
        self.first = first
        self.last = last
    }

    public var count: Int { last - first + 1 }
}

/// What a snippet inserts.
public enum Expansion: Hashable, Sendable {
    case text(String)
    case markdown(String)
    case html(String)
    case image(path: String)
    /// The short `form:` syntax, where the text holds `[[field]]` placeholders.
    case form(String)
    /// The match has no expansion key the app recognizes.
    case missing

    /// The expansion's text, or the image path for a picture.
    public var body: String {
        switch self {
        case .text(let text), .markdown(let text), .html(let text), .form(let text):
            return text
        case .image(let path):
            return path
        case .missing:
            return ""
        }
    }
}

public enum ForceMode: String, Hashable, Sendable {
    case keys
    case clipboard
}

public enum UppercaseStyle: String, Hashable, Sendable {
    case uppercase
    case capitalize
    case capitalizeWords = "capitalize_words"
}

/// One entry of a match's `vars:` list, or of a file's `global_vars:` list.
public struct SnippetVariable: Hashable, Sendable {
    public var name: String
    /// Espanso's variable type, such as `date`, `clipboard`, `shell`, `script`, `form`, `choice`, `random`, `match` or `echo`.
    public var type: String
    /// Everything under `params:`, in file order.
    public var params: [ParamEntry]
    /// Keys beside `name`, `type` and `params`, such as `inject_vars` and `depends_on`.
    public var extras: [ParamEntry]

    public init(name: String, type: String, params: [ParamEntry] = [], extras: [ParamEntry] = []) {
        self.name = name
        self.type = type
        self.params = params
        self.extras = extras
    }

    /// A variable whose parameters are all text.
    public init(name: String, type: String, parameters: [String: String]) {
        self.init(name: name, type: type, params: parameters.keys.sorted().map { ParamEntry($0, .string(parameters[$0] ?? "")) })
    }

    /// The single values under `params:`, as text. Lists and mappings are left out.
    public var parameters: [String: String] {
        var result: [String: String] = [:]
        for entry in params {
            if let text = entry.value.text { result[entry.key] = text }
        }
        return result
    }
}

/// The flags of a match that the editor shows as options.
public struct SnippetOptions: Hashable, Sendable {
    public var word = false
    public var leftWord = false
    public var rightWord = false
    public var propagateCase = false
    public var uppercaseStyle: UppercaseStyle?
    public var forceMode: ForceMode?
    public var paragraph = false

    public init() {}
}

/// One match in a match file.
public struct Snippet: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable {
        /// Path of the file relative to the config folder, such as `match/work.yml`.
        public var file: String
        /// Position of the match in that file's `matches:` list.
        public var index: Int

        public init(file: String, index: Int) {
            self.file = file
            self.index = index
        }
    }

    public var id: ID
    /// Everything from `trigger:` and `triggers:`, in file order.
    public var triggers: [String]
    /// The pattern, for a match that uses `regex:`.
    public var regex: String?
    public var expansion: Expansion
    public var label: String?
    public var searchTerms: [String]
    public var options: SnippetOptions
    public var variables: [SnippetVariable]
    /// The fields under `form_fields:`, for a match written with the short `form:` key.
    public var formFields: [ParamEntry]
    /// Keys the form does not understand. They are kept and shown only in the YAML view.
    public var unknownKeys: [String]
    /// True when the match uses YAML the form can't round-trip: flow style, anchors, aliases, merge keys or unknown keys.
    public var needsAdvancedYAML: Bool
    /// The lines the match occupies, when they could be determined.
    public var sourceRange: LineRange?
    /// The match exactly as written in the file.
    public var source: String

    public init(
        id: ID,
        triggers: [String] = [],
        regex: String? = nil,
        expansion: Expansion = .missing,
        label: String? = nil,
        searchTerms: [String] = [],
        options: SnippetOptions = SnippetOptions(),
        variables: [SnippetVariable] = [],
        formFields: [ParamEntry] = [],
        unknownKeys: [String] = [],
        needsAdvancedYAML: Bool = false,
        sourceRange: LineRange? = nil,
        source: String = ""
    ) {
        self.id = id
        self.triggers = triggers
        self.regex = regex
        self.expansion = expansion
        self.label = label
        self.searchTerms = searchTerms
        self.options = options
        self.variables = variables
        self.formFields = formFields
        self.unknownKeys = unknownKeys
        self.needsAdvancedYAML = needsAdvancedYAML
        self.sourceRange = sourceRange
        self.source = source
    }

    public var isRegex: Bool { regex != nil }

    /// The text shown in the Abbreviation column: the first trigger, or the pattern.
    public var abbreviation: String {
        regex ?? triggers.first ?? ""
    }

    /// Triggers after the first one.
    public var aliases: [String] {
        Array(triggers.dropFirst())
    }

    /// True when the expansion contains the cursor hint.
    public var hasCursorHint: Bool {
        expansion.body.contains("$|$")
    }

    public var hasForm: Bool {
        if case .form = expansion { return true }
        return variables.contains { $0.type == "form" }
    }

    public var hasScript: Bool {
        variables.contains { $0.type == "script" || $0.type == "shell" }
    }

    /// True when the expansion has variables other than a form, or a cursor hint.
    public var hasDynamicContent: Bool {
        hasCursorHint || variables.contains { $0.type != "form" }
    }
}
