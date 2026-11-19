import Foundation
public import SnippetModel

// The rule editor for regular expressions: what the pattern holds, trying it out, and converting it.
extension AppModel {
    /// How many of the last characters typed Espanso matches a pattern against.
    public var regexBufferLimit: Int {
        guard let option = EngineOption.option("max_regex_buffer_size"), option.isAvailable(in: engineVersion),
              case .integer(let value)? = shownValue(of: option), value > 0
        else { return 30 }
        return value
    }

    /// What reading the draft's pattern tells. Nil when the item is not a regular expression.
    public var regexAnalysis: RegexAnalysis? {
        draft?.regex.map { RegexAnalysis(pattern: $0) }
    }

    /// The names the expansion can refer to as `{{name}}`.
    public var regexGroupNames: [String] {
        var seen = Set<String>()
        return (regexAnalysis?.groupNames ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The rule rewritten with named groups, when it is written with numbered ones the expansion refers to
    /// as `$1`, or with `(?<name>…)`.
    public var regexConversion: RegexConversion.Result? {
        guard let draft, let pattern = draft.regex, formLockReason == nil else { return nil }
        switch draft.expansion {
        case .text, .markdown, .html: return RegexConversion.convert(pattern: pattern, body: draft.body)
        case .form, .image, .missing: return nil
        }
    }

    /// Rewrites the pattern and the expansion as `regexConversion` has them.
    public func applyRegexConversion() {
        guard let conversion = regexConversion else { return }
        updateDraft { $0.regex = conversion.pattern }
        setBody(conversion.body)
        commitDraft()
    }

    /// The text last tried against the rule being edited.
    public var regexSample: String {
        get { selectedSnippetID.flatMap { regexSamples[$0] } ?? "" }
        set { if let selectedSnippetID { regexSamples[selectedSnippetID] = newValue } }
    }

    /// Tries the draft on the sample text.
    public var regexTestOutcome: RegexTest.Outcome {
        guard let draft, let pattern = draft.regex else { return .idle }
        return RegexTest.run(pattern: pattern, expansion: draft.expansion, sample: regexSample, limit: regexBufferLimit)
    }

    /// "New Abbreviation", or "New Rule" in a set of regular expressions.
    public var newItemTitle: String {
        selectedSet?.kind == .regularExpressions ? "New Rule" : "New Abbreviation"
    }
}
