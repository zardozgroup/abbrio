public import Foundation

/// How Quick Search puts a snippet into the frontmost app.
public enum InsertionPlan: Hashable, Sendable {
    /// The app pastes the text itself, then moves the cursor back by this many characters.
    case paste(text: String, cursorBack: Int)
    /// The app pastes the trigger and asks Espanso to expand it, because the snippet needs Espanso: variables,
    /// a form, Markdown, HTML or a picture.
    case engine(trigger: String)
}

extension Snippet {
    /// How the snippet is inserted from Quick Search. Nil for a regular expression, which has no trigger to
    /// run, and for a snippet that needs Espanso but has no trigger.
    public var insertionPlan: InsertionPlan? {
        guard !isRegex else { return nil }
        if case .text(let body) = expansion, variables.isEmpty, formFields.isEmpty {
            let pieces = ExpansionPiece.pieces(of: body, isShortForm: false)
            let needsEngine = pieces.contains { piece in
                if case .variable = piece.kind { return true }
                return false
            }
            if !needsEngine {
                // The first marker is where the cursor goes; the text after it is what the cursor steps back over.
                guard let marker = pieces.firstIndex(where: { $0.kind == .cursor }) else {
                    return .paste(text: body, cursorBack: 0)
                }
                let before = pieces[..<marker].map(\.source).joined()
                let after = pieces[(marker + 1)...].map(\.source).joined()
                return .paste(text: before + after, cursorBack: after.count)
            }
        }
        guard let trigger = triggers.first, !trigger.isEmpty else { return nil }
        return .engine(trigger: trigger)
    }
}

/// One use of a snippet from Quick Search, kept by the app for the list of recent items.
public struct RecentUse: Codable, Hashable, Sendable {
    /// Path of the snippet's file relative to the config folder.
    public var file: String
    /// The snippet's first trigger. The position in the file is no use here, because it changes with edits.
    public var trigger: String
    public var date: Date

    public init(file: String, trigger: String, date: Date) {
        self.file = file
        self.trigger = trigger
        self.date = date
    }

    /// Adds a use to a list, newest first, keeping one entry per snippet.
    public static func adding(_ use: RecentUse, to list: [RecentUse], limit: Int = 50) -> [RecentUse] {
        var result = list.filter { $0.file != use.file || $0.trigger != use.trigger }
        result.insert(use, at: 0)
        return Array(result.prefix(limit))
    }
}

/// One row of the Quick Search results.
public struct QuickSearchItem: Identifiable, Hashable, Sendable {
    public var id: Snippet.ID
    public var abbreviation: String
    /// The snippet's description, when it has one.
    public var title: String?
    /// The expansion on one line.
    public var preview: String
    public var setName: String
    /// Nil for an item that can only be opened, not inserted.
    public var plan: InsertionPlan?

    public init(snippet: Snippet, setName: String, preview: ExpansionPreview) {
        id = snippet.id
        abbreviation = snippet.abbreviation
        title = snippet.label.flatMap { $0.isEmpty ? nil : $0 }
        self.preview = preview.text(for: snippet)
        self.setName = setName
        plan = snippet.insertionPlan
    }
}

/// Finds snippets for the Quick Search panel.
///
/// Only sets that are switched on take part. A set's Quick Search settings decide whether its abbreviations
/// and its expansions are searched; descriptions and search terms are searched whenever the set takes part.
/// A set with both settings off is left out.
public struct QuickSearch: Sendable {
    public var sets: [SnippetSet]
    public var recents: [RecentUse]
    public var preview: ExpansionPreview
    public var limit: Int

    public init(sets: [SnippetSet], recents: [RecentUse] = [], preview: ExpansionPreview = ExpansionPreview(), limit: Int = 50) {
        self.sets = sets
        self.recents = recents
        self.preview = preview
        self.limit = limit
    }

    private var searchableSets: [SnippetSet] {
        sets.filter { $0.isEnabled && !$0.isBroken && ($0.info.searchAbbreviations || $0.info.searchExpansions) }
    }

    /// The results for what is typed. Nothing typed gives nothing; a single `.` gives the recent items.
    public func results(for text: String) -> [QuickSearchItem] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "." { return recentItems }
        let query = SearchQuery(text)
        guard !query.isEmpty else { return [] }
        let needle = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)

        var found: [(rank: Int, item: QuickSearchItem)] = []
        for set in searchableSets {
            for snippet in set.snippets {
                var fields: [String] = []
                if set.info.searchAbbreviations {
                    fields += snippet.triggers
                    if let regex = snippet.regex { fields.append(regex) }
                }
                if set.info.searchExpansions { fields.append(snippet.expansion.body) }
                if let label = snippet.label { fields.append(label) }
                fields += snippet.searchTerms
                guard query.matches(fields) else { continue }

                // Abbreviations that are, or start with, what was typed come first.
                var rank = 3
                if set.info.searchAbbreviations {
                    let triggers = snippet.triggers.map {
                        $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    }
                    if triggers.contains(needle) {
                        rank = 0
                    } else if triggers.contains(where: { $0.hasPrefix(needle) }) {
                        rank = 1
                    } else if triggers.contains(where: { $0.contains(needle) }) {
                        rank = 2
                    }
                }
                found.append((rank, QuickSearchItem(snippet: snippet, setName: set.name, preview: preview)))
            }
        }
        // The sort is stable, so items of equal rank stay in sidebar and file order.
        return found.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .prefix(limit)
            .map(\.element.item)
    }

    /// The recently used snippets that still exist, newest first.
    public var recentItems: [QuickSearchItem] {
        var items: [QuickSearchItem] = []
        let sets = searchableSets
        for use in recents {
            for set in sets {
                guard let snippet = set.snippets.first(where: {
                    $0.id.file == use.file && $0.triggers.first == use.trigger
                }) else { continue }
                items.append(QuickSearchItem(snippet: snippet, setName: set.name, preview: preview))
                break
            }
            if items.count == limit { break }
        }
        return items
    }
}
