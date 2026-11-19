public import Foundation

/// The span of time a statistics view covers.
public enum StatisticsPeriod: String, CaseIterable, Hashable, Sendable {
    case today
    case week
    case month
    case year
    case all

    public var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        case .year: return "365 days"
        case .all: return "All time"
        }
    }

    /// The word `espanso stats --period` takes for this span.
    public var engineName: String { rawValue }

    /// The moment the span starts, or nil for all time. Today starts at local midnight; the others are
    /// rolling windows of 7, 30 and 365 days, as Espanso has them.
    public func start(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .today: return calendar.startOfDay(for: now)
        case .week: return now.addingTimeInterval(-7 * 86_400)
        case .month: return now.addingTimeInterval(-30 * 86_400)
        case .year: return now.addingTimeInterval(-365 * 86_400)
        case .all: return nil
        }
    }
}

/// How often one piece of typed text was expanded. Espanso records what was typed, not which match it was.
public struct UsageCount: Hashable, Sendable {
    public var typed: String
    public var count: Int

    public init(typed: String, count: Int) {
        self.typed = typed
        self.count = count
    }
}

/// The last time one piece of typed text was expanded.
public struct UsageMoment: Hashable, Sendable {
    public var typed: String
    public var date: Date

    public init(typed: String, date: Date) {
        self.typed = typed
        self.date = date
    }
}

/// Finds the snippet behind a piece of typed text.
///
/// An exact trigger wins. Then a trigger that differs only in case, for snippets whose expansion follows the
/// case of what was typed. Then a regular expression that matches the whole text.
public struct UsageAttribution: Sendable {
    public struct Target: Hashable, Sendable {
        public var snippet: Snippet
        public var setName: String
        public var countAs: CountAs
    }

    private var exact: [String: Target] = [:]
    private var folded: [String: Target] = [:]
    private var patterns: [(expression: NSRegularExpression, target: Target)] = []

    /// - Parameter sets: In sidebar order. When several sets have the same trigger, a set that is switched
    ///   on wins over one that is off, and otherwise the first wins.
    public init(sets: [SnippetSet]) {
        let ordered = sets.filter { $0.isEnabled && !$0.isBroken } + sets.filter { !$0.isEnabled && !$0.isBroken }
        for set in ordered {
            for snippet in set.snippets {
                let target = Target(snippet: snippet, setName: set.name, countAs: set.info.countAs)
                if let regex = snippet.regex {
                    if let expression = try? NSRegularExpression(pattern: RegexSyntax.systemPattern(for: regex)) {
                        patterns.append((expression, target))
                    }
                    continue
                }
                for trigger in snippet.triggers where exact[trigger] == nil {
                    exact[trigger] = target
                }
                if snippet.options.propagateCase {
                    for trigger in snippet.triggers where folded[trigger.lowercased()] == nil {
                        folded[trigger.lowercased()] = target
                    }
                }
            }
        }
    }

    public func target(for typed: String) -> Target? {
        if let target = exact[typed] { return target }
        if let target = folded[typed.lowercased()] { return target }
        let whole = NSRange(typed.startIndex..., in: typed)
        for (expression, target) in patterns {
            if let match = expression.firstMatch(in: typed, range: whole), match.range == whole { return target }
        }
        return nil
    }
}

/// The small part of regular expression syntax that differs between Espanso's engine and the system's and
/// can be rewritten safely.
public enum RegexSyntax {
    /// Rewrites `(?P<name>…)` as `(?<name>…)`, the only spelling the system engine knows.
    public static func systemPattern(for pattern: String) -> String {
        pattern.replacingOccurrences(of: "(?P<", with: "(?<")
    }
}

/// One line of the statistics table.
public struct UsageRow: Identifiable, Hashable, Sendable {
    /// What the row is about: a snippet's abbreviation, or typed text nothing in the sets explains.
    public var trigger: String
    public var snippetID: Snippet.ID?
    public var setName: String?
    /// Nil when the text belongs to no set.
    public var countAs: CountAs?
    public var count: Int
    /// Characters saved by these expansions.
    public var charactersSaved: Int

    public var id: String { (snippetID.map { "\($0.file)#\($0.index)" } ?? "?") + "|" + trigger }
}

/// The statistics for one period, with typed text mapped back to the items in the sets.
public struct UsageReport: Hashable, Sendable {
    /// Most used first.
    public var rows: [UsageRow]
    public var total: Int
    public var expansions: Int
    public var corrections: Int
    /// Expansions of text that no item in the sets explains, such as items deleted since.
    public var unattributed: Int
    public var charactersSaved: Int

    public static let empty = UsageReport(counts: [], attribution: UsageAttribution(sets: []))

    public init(counts: [UsageCount], attribution: UsageAttribution) {
        var rows: [String: UsageRow] = [:]
        var order: [String] = []
        for entry in counts where entry.count > 0 {
            var row: UsageRow
            if let target = attribution.target(for: entry.typed) {
                let snippet = target.snippet
                // A regular expression is shown by its pattern; what was typed differs every time.
                row = UsageRow(
                    trigger: snippet.abbreviation, snippetID: snippet.id, setName: target.setName,
                    countAs: target.countAs, count: entry.count,
                    charactersSaved: Self.saved(snippet, typed: entry.typed) * entry.count
                )
            } else {
                row = UsageRow(trigger: entry.typed, snippetID: nil, setName: nil, countAs: nil, count: entry.count, charactersSaved: 0)
            }
            if var existing = rows[row.id] {
                existing.count += row.count
                existing.charactersSaved += row.charactersSaved
                row = existing
            } else {
                order.append(row.id)
            }
            rows[row.id] = row
        }
        self.rows = order.compactMap { rows[$0] }.sorted {
            ($1.count, $0.trigger.lowercased()) < ($0.count, $1.trigger.lowercased())
        }
        total = self.rows.reduce(0) { $0 + $1.count }
        corrections = self.rows.filter { $0.countAs == .corrections }.reduce(0) { $0 + $1.count }
        expansions = self.rows.filter { $0.countAs == .expansions }.reduce(0) { $0 + $1.count }
        unattributed = total - corrections - expansions
        charactersSaved = self.rows.reduce(0) { $0 + $1.charactersSaved }
    }

    /// The share of all expansions a row has, from 0 to 1.
    public func share(of row: UsageRow) -> Double {
        total == 0 ? 0 : Double(row.count) / Double(total)
    }

    /// The rows to show when only `limit` fit, and what the rest add up to.
    public func top(_ limit: Int) -> (rows: [UsageRow], otherTriggers: Int, otherCount: Int) {
        let shown = Array(rows.prefix(limit))
        let rest = rows.dropFirst(limit)
        return (shown, rest.count, rest.reduce(0) { $0 + $1.count })
    }

    /// Minutes saved at a typing speed in words per minute, taking a word as five characters.
    public func minutesSaved(wordsPerMinute: Int) -> Double {
        guard wordsPerMinute > 0 else { return 0 }
        return Double(charactersSaved) / Double(wordsPerMinute * 5)
    }

    /// Characters one expansion saves: the length of what appears, less the length of what was typed.
    /// Never negative. The cursor marker is not counted, and a picture saves nothing that can be counted.
    static func saved(_ snippet: Snippet, typed: String) -> Int {
        guard case .text(let body) = snippet.expansion else {
            if case .image = snippet.expansion { return 0 }
            return max(0, snippet.expansion.body.count - typed.count)
        }
        let length = body.replacingOccurrences(of: "$|$", with: "").count
        return max(0, length - typed.count)
    }
}

extension UsageAttribution {
    /// Turns Espanso's record of recent expansions into the form Quick Search keeps its own history in.
    public func recentUses(from moments: [UsageMoment]) -> [RecentUse] {
        moments.compactMap { moment in
            guard let snippet = target(for: moment.typed)?.snippet, let trigger = snippet.triggers.first else { return nil }
            return RecentUse(file: snippet.id.file, trigger: trigger, date: moment.date)
        }
    }
}

extension RecentUse {
    /// Two histories as one, newest first, with one entry per snippet.
    public static func merged(_ first: [RecentUse], _ second: [RecentUse], limit: Int = 50) -> [RecentUse] {
        var seen = Set<String>()
        var result: [RecentUse] = []
        for use in (first + second).sorted(by: { $0.date > $1.date }) {
            guard seen.insert(use.file + "\u{0}" + use.trigger).inserted else { continue }
            result.append(use)
            if result.count == limit { break }
        }
        return result
    }
}
