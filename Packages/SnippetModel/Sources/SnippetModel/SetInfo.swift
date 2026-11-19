import Foundation

/// How the case of what is typed relates to an abbreviation.
public enum CaseMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// The abbreviation must be typed exactly as written.
    case mustMatch
    /// Lowercase, Capitalized and UPPERCASE forms all expand to the same text.
    case insensitive
    /// The expansion follows the case of what was typed.
    case affectsExpansion
}

/// When an abbreviation expands.
public enum ExpandMode: String, Codable, Hashable, Sendable, CaseIterable {
    case onMatch
    case wordBreak
}

/// How a set's expansions are grouped in the statistics.
public enum CountAs: String, Codable, Hashable, Sendable, CaseIterable {
    case expansions
    case corrections
}

/// What the app remembers about a set beyond its file. None of it is in Espanso's YAML.
public struct SetInfo: Codable, Hashable, Sendable {
    /// The name shown in the sidebar. Nil when the name comes from the file name.
    public var name: String?
    /// The set's place in its sidebar section. Sets without one follow, by name.
    public var order: Int?
    /// Text in front of every trigger in the file.
    public var prefix: String
    /// Text after every trigger in the file.
    public var suffix: String
    public var defaultCase: CaseMode
    public var defaultExpand: ExpandMode
    public var countAs: CountAs
    public var searchAbbreviations: Bool
    public var searchExpansions: Bool
    public var notes: String
    /// True for a set made to hold regular expressions. It matters only while the file is empty; after
    /// that the file's own matches say what the set is.
    public var holdsRegularExpressions: Bool?

    public init(
        name: String? = nil,
        order: Int? = nil,
        prefix: String = "",
        suffix: String = "",
        defaultCase: CaseMode = .mustMatch,
        defaultExpand: ExpandMode = .onMatch,
        countAs: CountAs = .expansions,
        searchAbbreviations: Bool = true,
        searchExpansions: Bool = true,
        notes: String = ""
    ) {
        self.name = name
        self.order = order
        self.prefix = prefix
        self.suffix = suffix
        self.defaultCase = defaultCase
        self.defaultExpand = defaultExpand
        self.countAs = countAs
        self.searchAbbreviations = searchAbbreviations
        self.searchExpansions = searchExpansions
        self.notes = notes
    }

    // A file written by another version may lack fields; each one falls back to its default.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        name = try? values.decodeIfPresent(String.self, forKey: .name)
        order = try? values.decodeIfPresent(Int.self, forKey: .order)
        prefix = (try? values.decodeIfPresent(String.self, forKey: .prefix)) ?? ""
        suffix = (try? values.decodeIfPresent(String.self, forKey: .suffix)) ?? ""
        defaultCase = (try? values.decodeIfPresent(CaseMode.self, forKey: .defaultCase)) ?? .mustMatch
        defaultExpand = (try? values.decodeIfPresent(ExpandMode.self, forKey: .defaultExpand)) ?? .onMatch
        countAs = (try? values.decodeIfPresent(CountAs.self, forKey: .countAs)) ?? .expansions
        searchAbbreviations = (try? values.decodeIfPresent(Bool.self, forKey: .searchAbbreviations)) ?? true
        searchExpansions = (try? values.decodeIfPresent(Bool.self, forKey: .searchExpansions)) ?? true
        notes = (try? values.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        holdsRegularExpressions = try? values.decodeIfPresent(Bool.self, forKey: .holdsRegularExpressions)
    }

    /// True when nothing differs from a set the app knows nothing about.
    public var isEmpty: Bool { self == SetInfo() }
}

/// A variable from a file's `global_vars:` list, for display.
public struct GlobalVariable: Hashable, Sendable {
    public var name: String
    public var type: String
    /// The parameter that says most about the variable, such as a date format or a command.
    public var value: String

    public init(name: String, type: String, value: String) {
        self.name = name
        self.type = type
        self.value = value
    }
}
