import Foundation

/// A search as typed into the search field.
///
/// Words separated by spaces must all appear, in any order. Text inside double quotes must appear exactly as
/// written, spaces included. Letter case and accents are ignored.
public struct SearchQuery: Hashable, Sendable {
    public private(set) var terms: [String]

    public init(_ text: String) {
        var terms: [String] = []
        var current = ""
        var inQuotes = false

        func flush() {
            let term = inQuotes ? current : current.trimmingCharacters(in: .whitespaces)
            if !term.isEmpty {
                terms.append(Self.fold(term))
            }
            current = ""
        }

        for character in text {
            if character == "\"" {
                flush()
                inQuotes.toggle()
            } else if character.isWhitespace && !inQuotes {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        self.terms = terms
    }

    public var isEmpty: Bool { terms.isEmpty }

    public func matches(_ snippet: Snippet) -> Bool {
        matches(searchText: Self.searchText(for: snippet))
    }

    /// True when every term appears somewhere in the given texts.
    public func matches(_ fields: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        return matches(searchText: Self.searchText(of: fields))
    }

    /// True when every term appears in text made by `searchText(for:)` or `searchText(of:)`.
    ///
    /// Folding the text is most of the cost of a match, so a caller that searches the same items again and
    /// again can make their search text once and keep it.
    public func matches(searchText: String) -> Bool {
        terms.allSatisfy { searchText.contains($0) }
    }

    /// The text of an item that a search looks through, folded the way the terms are.
    public static func searchText(for snippet: Snippet) -> String {
        var fields = snippet.triggers
        if let regex = snippet.regex { fields.append(regex) }
        fields.append(snippet.expansion.body)
        if let label = snippet.label { fields.append(label) }
        fields.append(contentsOf: snippet.searchTerms)
        return searchText(of: fields)
    }

    /// Several texts joined and folded the way the terms are.
    public static func searchText(of fields: [String]) -> String {
        fold(fields.joined(separator: "\n"))
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
