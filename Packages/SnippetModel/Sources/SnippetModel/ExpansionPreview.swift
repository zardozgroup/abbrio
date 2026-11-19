public import Foundation
import xlocale

/// Builds the one-line summary of an expansion for the list, with each variable shown as `{Name}`.
public struct ExpansionPreview: Sendable {
    /// The moment date variables are rendered for.
    public var now: Date
    public var timeZone: TimeZone

    public init(now: Date = Date(), timeZone: TimeZone = .current) {
        self.now = now
        self.timeZone = timeZone
    }

    public func text(for snippet: Snippet) -> String {
        switch snippet.expansion {
        case .missing:
            return ""
        case .image(let path):
            return (path as NSString).lastPathComponent
        case .form(let text):
            return firstLine(of: replaceFormFields(in: text))
        case .text(let text), .markdown(let text), .html(let text):
            return firstLine(of: replaceVariables(in: text, snippet: snippet))
        }
    }

    private func firstLine(of text: String) -> String {
        let trimmed = text.drop { $0.isNewline }
        let line = trimmed.prefix { !$0.isNewline }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private func replaceVariables(in text: String, snippet: Snippet) -> String {
        Self.replacingReferences(in: text, open: "{{", close: "}}", allowingDots: true) { name in
            "{" + self.title(forReference: name, in: snippet) + "}"
        }
    }

    private func replaceFormFields(in text: String) -> String {
        Self.replacingReferences(in: text, open: "[[", close: "]]", allowingDots: false) { name in
            "{" + Self.humanized(name) + "}"
        }
    }

    /// Replaces each `open name close` (spaces allowed inside the brackets) with `transform(name)`.
    ///
    /// Scanned by hand rather than with a regex: the list builds this for every row, and a regex
    /// literal is parsed and compiled again each time it runs.
    static func replacingReferences(
        in text: String, open: String, close: String, allowingDots: Bool,
        _ transform: (String) -> String
    ) -> String {
        guard text.contains(open) else { return text }
        func isNameCharacter(_ c: Character) -> Bool {
            (c.isASCII && (c.isLetter || c.isNumber)) || c == "_" || (allowingDots && c == ".")
        }
        var result = ""
        var rest = text[...]
        while let opening = rest.range(of: open) {
            result += rest[..<opening.lowerBound]
            var cursor = rest[opening.upperBound...].drop(while: \.isWhitespace)
            let name = cursor.prefix(while: isNameCharacter)
            cursor = cursor[name.endIndex...].drop(while: \.isWhitespace)
            if !name.isEmpty, cursor.hasPrefix(close) {
                result += transform(String(name))
                rest = cursor.dropFirst(close.count)
            } else {
                // Not a reference: keep the first bracket and look again after it.
                result += rest[opening.lowerBound..<rest.index(after: opening.lowerBound)]
                rest = rest[rest.index(after: opening.lowerBound)...]
            }
        }
        result += rest
        return result
    }

    private func title(forReference reference: String, in snippet: Snippet) -> String {
        let parts = reference.split(separator: ".", maxSplits: 1).map(String.init)
        let name = parts[0]
        guard let variable = snippet.variables.first(where: { $0.name == name }) else {
            return reference
        }
        if parts.count == 2 {
            // A form field, written as {{form.field}}.
            return Self.humanized(parts[1])
        }
        switch variable.type {
        case "date":
            return "Date: " + renderedDate(for: variable)
        case "clipboard":
            return "Clipboard"
        case "shell":
            if let command = variable.parameters["cmd"] { return "Shell: " + command }
            return "Shell"
        case "script":
            return "Script"
        case "match":
            if let trigger = variable.parameters["trigger"] { return "Abbreviation: " + trigger }
            return "Abbreviation"
        case "random":
            return "Random"
        case "choice":
            return "Choice"
        case "echo":
            return variable.parameters["echo"] ?? "Echo"
        case "form":
            return "Form"
        default:
            return Self.humanized(name)
        }
    }

    private func renderedDate(for variable: SnippetVariable) -> String {
        Self.renderedDate(
            format: variable.parameters["format"] ?? "%Y-%m-%d",
            offset: TimeInterval(variable.parameters["offset"] ?? "") ?? 0,
            locale: variable.parameters["locale"],
            timeZone: variable.parameters["tz"].flatMap(TimeZone.init(identifier:)) ?? timeZone,
            now: now
        )
    }

    /// Renders a date the way a `date` variable would, as closely as the system's own formatter allows.
    ///
    /// - Parameters:
    ///   - format: A strftime format.
    ///   - offset: Seconds added to `now`.
    ///   - locale: A BCP 47 tag such as `en-US`. Nil uses the C locale's English names.
    public static func renderedDate(
        format: String, offset: TimeInterval, locale: String?, timeZone: TimeZone, now: Date
    ) -> String {
        let moment = now.addingTimeInterval(offset)
        var seconds = time_t(moment.timeIntervalSince1970) + time_t(timeZone.secondsFromGMT(for: moment))
        var parts = tm()
        gmtime_r(&seconds, &parts)
        var buffer = [CChar](repeating: 0, count: 512)
        var written = 0
        if let locale, let named = newlocale(LC_TIME_MASK, locale.replacingOccurrences(of: "-", with: "_") + ".UTF-8", nil) {
            // The locale is switched for this thread only, and switched back straight away.
            let previous = uselocale(named)
            written = strftime(&buffer, buffer.count, format, &parts)
            uselocale(previous)
            freelocale(named)
        } else {
            written = strftime(&buffer, buffer.count, format, &parts)
        }
        guard written > 0 else { return format }
        return String(decoding: buffer.prefix(written).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `first_name` becomes "First name".
    public static func humanized(_ name: String) -> String {
        let words = name.split(separator: "_").joined(separator: " ")
        guard let first = words.first else { return name }
        return first.uppercased() + words.dropFirst()
    }
}
