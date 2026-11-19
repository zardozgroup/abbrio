import Foundation

/// Comma- or tab-separated text, as spreadsheets save it.
public enum DelimitedText {
    public enum Delimiter: Sendable, Equatable {
        case comma
        case tab

        var scalar: Unicode.Scalar { self == .comma ? "," : "\t" }
    }

    /// The delimiter a text most likely uses. A tab wins when every one of the first records has one, because
    /// tabs hardly ever occur inside a field while commas often do.
    public static func delimiter(of text: String) -> Delimiter {
        let sample = rows(in: text, delimiter: .tab, limit: 10)
        return !sample.isEmpty && sample.allSatisfy { $0.count >= 2 } ? .tab : .comma
    }

    /// Splits a text into records and fields. Fields may be wrapped in double quotes, inside which a
    /// doubled quote stands for one quote and line breaks are kept. Records with no content are left out.
    public static func rows(in text: String, delimiter: Delimiter, limit: Int? = nil) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var isQuoted = false
        var fieldWasQuoted = false

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            fieldWasQuoted = false
        }
        func endRow() {
            endField()
            if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            row = []
        }

        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        var index = 0
        while index < scalars.count {
            if let limit, rows.count >= limit { return rows }
            let scalar = scalars[index]
            index += 1
            if isQuoted {
                if scalar == "\"" {
                    if index < scalars.count, scalars[index] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        isQuoted = false
                    }
                } else if scalar == "\r" {
                    // Line breaks inside a field are kept as plain newlines.
                    if index < scalars.count, scalars[index] == "\n" { index += 1 }
                    field.append("\n")
                } else {
                    field.append(scalar)
                }
            } else if scalar == "\"", field.isEmpty, !fieldWasQuoted {
                isQuoted = true
                fieldWasQuoted = true
            } else if scalar == delimiter.scalar {
                endField()
            } else if scalar == "\n" || scalar == "\r" {
                if scalar == "\r", index < scalars.count, scalars[index] == "\n" { index += 1 }
                endRow()
            } else {
                field.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty || fieldWasQuoted { endRow() }
        return rows
    }

    /// Writes records as text. A field is quoted when it holds the delimiter, a quote, a line break, or
    /// space at either end.
    public static func text(for rows: [[String]], delimiter: Delimiter) -> String {
        var text = ""
        for row in rows {
            text += row.map { field(for: $0, delimiter: delimiter) }.joined(separator: String(delimiter.scalar))
            text += "\r\n"
        }
        return text
    }

    private static func field(for value: String, delimiter: Delimiter) -> String {
        let needsQuotes = value.unicodeScalars.contains {
            $0 == delimiter.scalar || $0 == "\"" || $0 == "\n" || $0 == "\r"
        } || value.first?.isWhitespace == true || value.last?.isWhitespace == true
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Abbreviations read from a comma- or tab-separated file: abbreviation, expansion and an optional
/// description, in that order.
public struct SnippetImport: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var abbreviation: String
        public var expansion: String
        public var description: String
    }

    public var delimiter: DelimitedText.Delimiter
    /// True when the first record holds column names and is not imported.
    public var hasHeader: Bool
    public var rows: [Row]
    /// Records left out because they have no abbreviation or no expansion.
    public var skippedCount: Int

    private static let abbreviationNames: Set<String> = ["abbreviation", "abbr", "trigger", "shortcut", "keyword", "snippet"]
    private static let expansionNames: Set<String> = ["expansion", "replace", "replacement", "text", "phrase", "content"]

    /// - Parameter hasHeader: Whether the first record is a header. Nil decides from its wording.
    public init(text: String, hasHeader: Bool? = nil) {
        delimiter = DelimitedText.delimiter(of: text)
        var records = DelimitedText.rows(in: text, delimiter: delimiter)
        let header = hasHeader ?? Self.looksLikeHeader(records.first)
        self.hasHeader = header && !records.isEmpty
        if self.hasHeader { records.removeFirst() }

        rows = []
        skippedCount = 0
        for record in records {
            let abbreviation = record[0]
            let expansion = record.count > 1 ? record[1] : ""
            guard !abbreviation.trimmingCharacters(in: .whitespaces).isEmpty, !expansion.isEmpty else {
                skippedCount += 1
                continue
            }
            rows.append(Row(
                abbreviation: abbreviation, expansion: expansion,
                description: record.count > 2 ? record[2].trimmingCharacters(in: .whitespaces) : ""
            ))
        }
    }

    /// True when a record's first two fields read like column names.
    public static func looksLikeHeader(_ record: [String]?) -> Bool {
        guard let record, record.count >= 2 else { return false }
        func name(_ field: String) -> String { field.trimmingCharacters(in: .whitespaces).lowercased() }
        return abbreviationNames.contains(name(record[0])) && expansionNames.contains(name(record[1]))
    }

    /// One new item per row, as plain text.
    public var drafts: [MatchDraft] {
        rows.map { MatchDraft(triggers: [$0.abbreviation], expansion: .text($0.expansion), label: $0.description) }
    }
}

/// A set's items written as comma-separated text that `SnippetImport` reads back.
public struct SnippetExport: Equatable, Sendable {
    public var text: String
    /// Rows written: one per abbreviation, so an item with aliases takes several.
    public var rowCount: Int
    /// Items left out: pictures, forms and regular-expression rules have no plain abbreviation and text.
    public var skippedCount: Int

    public init(snippets: [Snippet]) {
        var rows = [["abbreviation", "expansion", "description"]]
        var skipped = 0
        for snippet in snippets {
            let body: String
            switch snippet.expansion {
            case .text(let text), .markdown(let text), .html(let text): body = text
            case .image, .form, .missing:
                skipped += 1
                continue
            }
            guard snippet.regex == nil, !snippet.triggers.isEmpty else {
                skipped += 1
                continue
            }
            for trigger in snippet.triggers {
                rows.append([trigger, body, snippet.label ?? ""])
            }
        }
        text = DelimitedText.text(for: rows, delimiter: .comma)
        rowCount = rows.count - 1
        skippedCount = skipped
    }
}
