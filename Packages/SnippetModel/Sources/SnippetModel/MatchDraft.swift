import Foundation

/// The editable fields of a match, as the details pane holds them while the user types.
public struct MatchDraft: Hashable, Sendable {
    /// The abbreviation followed by its aliases.
    public var triggers: [String]
    /// The pattern, for a regular-expression rule.
    public var regex: String?
    public var expansion: Expansion
    public var label: String
    public var searchTerms: [String]
    public var options: SnippetOptions
    /// The match's `vars:` list.
    public var variables: [SnippetVariable]
    /// The fields under `form_fields:`, for a match written with the short `form:` key.
    public var formFields: [ParamEntry]

    public init(
        triggers: [String] = [],
        regex: String? = nil,
        expansion: Expansion = .text(""),
        label: String = "",
        searchTerms: [String] = [],
        options: SnippetOptions = SnippetOptions(),
        variables: [SnippetVariable] = [],
        formFields: [ParamEntry] = []
    ) {
        self.triggers = triggers
        self.regex = regex
        self.expansion = expansion
        self.label = label
        self.searchTerms = searchTerms
        self.options = options
        self.variables = variables
        self.formFields = formFields
    }

    public init(_ snippet: Snippet) {
        self.init(
            triggers: snippet.triggers,
            regex: snippet.regex,
            expansion: snippet.expansion,
            label: snippet.label ?? "",
            searchTerms: snippet.searchTerms,
            options: snippet.options,
            variables: snippet.variables,
            formFields: snippet.formFields
        )
    }

    public var isRegex: Bool { regex != nil }

    /// The abbreviation, or the pattern of a regular-expression rule.
    public var abbreviation: String {
        get { regex ?? triggers.first ?? "" }
        set {
            if regex != nil {
                regex = newValue
            } else if triggers.isEmpty {
                triggers = [newValue]
            } else {
                triggers[0] = newValue
            }
        }
    }

    /// Triggers after the first one.
    public var aliases: [String] {
        get { Array(triggers.dropFirst()) }
        set { triggers = [triggers.first ?? ""] + newValue }
    }

    /// The expansion's text, keeping its type.
    public var body: String {
        get { expansion.body }
        set {
            switch expansion {
            case .text, .missing: expansion = .text(newValue)
            case .markdown: expansion = .markdown(newValue)
            case .html: expansion = .html(newValue)
            case .form: expansion = .form(newValue)
            case .image: expansion = .image(path: newValue)
            }
        }
    }

    /// Why the draft can't be saved yet, in words for the user. Nil when it can.
    public var blockingProblem: String? {
        if abbreviation.isEmpty {
            return isRegex ? "Enter a pattern." : "Enter an abbreviation."
        }
        if aliases.contains(where: \.isEmpty) {
            return "An alias can't be empty."
        }
        if case .image(let path) = expansion, path.isEmpty {
            return "Choose a picture."
        }
        var seen = Set<String>()
        for variable in variables {
            guard Self.isValidName(variable.name) else {
                return "A variable name may contain only letters, numbers and underscores."
            }
            guard seen.insert(variable.name).inserted else {
                return "Two variables are named \(variable.name)."
            }
        }
        return nil
    }

    /// Things worth pointing out that don't stop a save.
    public var warnings: [String] {
        var warnings: [String] = []
        if body.components(separatedBy: "$|$").count > 2 {
            warnings.append("Espanso uses only the first cursor position.")
        }
        if Set(triggers).count != triggers.count {
            warnings.append("The same trigger is listed twice.")
        }
        return warnings
    }

    /// Espanso accepts only letters, numbers and underscores in a variable name.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
        }
    }
}
