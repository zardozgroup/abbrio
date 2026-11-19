import Foundation

/// Something in a pattern that Espanso's regular expression engine refuses. A rule with such a pattern
/// is skipped when Espanso loads the file.
public enum RegexIssue: Hashable, Sendable {
    case lookAhead
    case lookBehind
    case backReference
    case atomicGroup
    case possessiveQuantifier
    /// `(?<name>…)` instead of `(?P<name>…)`.
    case plainNamedGroup
    case duplicateGroupName(String)
    case unbalancedParentheses

    public var message: String {
        switch self {
        case .lookAhead:
            return "Look-ahead, written (?=…) or (?!…), is not supported by Espanso's regular expressions."
        case .lookBehind:
            return "Look-behind, written (?<=…) or (?<!…), is not supported by Espanso's regular expressions."
        case .backReference:
            return "Back-references such as \\1 are not supported by Espanso's regular expressions."
        case .atomicGroup:
            return "Atomic groups, written (?>…), are not supported by Espanso's regular expressions."
        case .possessiveQuantifier:
            return "Possessive quantifiers such as *+ are not supported by Espanso's regular expressions."
        case .plainNamedGroup:
            return "Espanso does not accept (?<name>…). Write named groups as (?P<name>…)."
        case .duplicateGroupName(let name):
            return "Two groups are named \(name)."
        case .unbalancedParentheses:
            return "The parentheses in the pattern don't pair up."
        }
    }
}

/// A capturing group of a pattern.
public struct RegexGroup: Hashable, Sendable {
    /// Counted from 1 by opening parenthesis, named groups included.
    public var number: Int
    public var name: String?
    /// The position of the group's opening parenthesis among the pattern's characters.
    public var offset: Int
    /// True when the name is written `(?<name>` rather than `(?P<name>`.
    public var usesPlainName: Bool
}

/// What can be told about a pattern by reading it: its groups, what Espanso won't accept, and how long a
/// match can be.
public struct RegexAnalysis: Hashable, Sendable {
    public var groups: [RegexGroup] = []
    public var issues: [RegexIssue] = []
    /// The fewest characters a match can have.
    public var minimumLength = 0
    /// The most characters a match can have. Nil when there is no upper bound.
    public var maximumLength: Int? = 0

    /// The names of the named groups, in the order they are written.
    public var groupNames: [String] { groups.compactMap(\.name) }

    public init(pattern: String) {
        var reader = Reader(characters: Array(pattern))
        let length = reader.alternation()
        if reader.position < reader.characters.count || reader.isUnbalanced {
            reader.note(.unbalancedParentheses)
        }
        groups = reader.groups
        issues = reader.issues
        minimumLength = length.minimum
        maximumLength = length.maximum
        var seen = Set<String>()
        for name in groupNames where !seen.insert(name).inserted {
            if !issues.contains(.duplicateGroupName(name)) { issues.append(.duplicateGroupName(name)) }
        }
    }

    /// A remark about the length of a match against the number of characters Espanso keeps, or nil.
    ///
    /// - Returns: The text, and whether the rule can never expand.
    public func lengthRemark(limit: Int) -> (text: String, isBlocking: Bool)? {
        if minimumLength > limit {
            return (
                "A match needs at least \(minimumLength) characters, but Espanso looks only at the last \(limit) typed, so this rule never expands.",
                true
            )
        }
        if maximumLength.map({ $0 > limit }) ?? true {
            return ("Espanso looks only at the last \(limit) characters typed. A longer match does not expand.", false)
        }
        return nil
    }

    private struct Length {
        var minimum: Int
        var maximum: Int?

        static let zero = Length(minimum: 0, maximum: 0)
        static let one = Length(minimum: 1, maximum: 1)
        static let unknown = Length(minimum: 0, maximum: nil)

        static func + (first: Length, second: Length) -> Length {
            Length(
                minimum: first.minimum + second.minimum,
                maximum: first.maximum.flatMap { a in second.maximum.map { a + $0 } }
            )
        }

        func repeated(_ low: Int, _ high: Int?) -> Length {
            Length(minimum: minimum * low, maximum: high.flatMap { h in maximum.map { $0 * h } } ?? (maximum == 0 ? 0 : nil))
        }
    }

    /// Reads a pattern from left to right. It knows only as much syntax as it needs to find groups and
    /// measure lengths; it does not decide whether the pattern is valid.
    private struct Reader {
        var characters: [Character]
        var position = 0
        var groups: [RegexGroup] = []
        var issues: [RegexIssue] = []
        var isUnbalanced = false

        var current: Character? { position < characters.count ? characters[position] : nil }

        func peek(_ offset: Int) -> Character? {
            position + offset < characters.count ? characters[position + offset] : nil
        }

        func follows(_ text: String) -> Bool {
            let wanted = Array(text)
            guard position + wanted.count <= characters.count else { return false }
            return Array(characters[position..<position + wanted.count]) == wanted
        }

        mutating func note(_ issue: RegexIssue) {
            if !issues.contains(issue) { issues.append(issue) }
        }

        mutating func alternation() -> Length {
            var result = sequence()
            while current == "|" {
                position += 1
                let other = sequence()
                result = Length(
                    minimum: min(result.minimum, other.minimum),
                    maximum: result.maximum.flatMap { a in other.maximum.map { max(a, $0) } }
                )
            }
            return result
        }

        mutating func sequence() -> Length {
            var result = Length.zero
            while let character = current, character != "|", character != ")" {
                result = result + quantified(atom())
            }
            return result
        }

        mutating func atom() -> Length {
            guard let character = current else { return .zero }
            position += 1
            switch character {
            case "(": return group()
            case "[": return characterClass()
            case "\\": return escape()
            case "^", "$": return .zero
            default: return .one
            }
        }

        /// Called after the opening parenthesis.
        mutating func group() -> Length {
            let offset = position - 1
            var isZeroWidth = false
            if current == "?" {
                if follows("?P<") || (follows("?<") && peek(2) != "=" && peek(2) != "!") {
                    let isPlain = !follows("?P<")
                    position += isPlain ? 2 : 3
                    var name = ""
                    while let character = current, character != ">", character != ")" {
                        name.append(character)
                        position += 1
                    }
                    if current == ">" { position += 1 }
                    if isPlain { note(.plainNamedGroup) }
                    groups.append(RegexGroup(number: groups.count + 1, name: name, offset: offset, usesPlainName: isPlain))
                } else if follows("?=") || follows("?!") {
                    note(.lookAhead)
                    position += 2
                    isZeroWidth = true
                } else if follows("?<=") || follows("?<!") {
                    note(.lookBehind)
                    position += 3
                    isZeroWidth = true
                } else if follows("?>") {
                    note(.atomicGroup)
                    position += 2
                } else {
                    // Flags, as in (?i) or (?i:…).
                    position += 1
                    while let character = current, character != ":", character != ")" { position += 1 }
                    if current == ":" { position += 1 }
                }
            } else {
                groups.append(RegexGroup(number: groups.count + 1, name: nil, offset: offset, usesPlainName: false))
            }
            let inner = alternation()
            if current == ")" {
                position += 1
            } else {
                isUnbalanced = true
            }
            return isZeroWidth ? .zero : inner
        }

        /// Called after the opening bracket. Skips to the bracket that closes the class.
        mutating func characterClass() -> Length {
            var depth = 1
            if current == "^" { position += 1 }
            if current == "]" { position += 1 }
            while let character = current, depth > 0 {
                position += 1
                switch character {
                case "\\": if current != nil { position += 1 }
                case "[": depth += 1
                case "]": depth -= 1
                default: break
                }
            }
            return .one
        }

        /// Called after the backslash.
        mutating func escape() -> Length {
            guard let character = current else { return .one }
            position += 1
            switch character {
            case "1"..."9":
                note(.backReference)
                return .unknown
            case "k" where current == "<" || current == "{":
                note(.backReference)
                return .unknown
            case "b", "B", "A", "z", "Z", "G":
                return .zero
            case "p", "P", "x", "u", "U":
                if current == "{" {
                    while let next = current, next != "}" { position += 1 }
                    if current == "}" { position += 1 }
                } else if character == "p" || character == "P" {
                    if current != nil { position += 1 }
                } else {
                    let digits = character == "x" ? 2 : (character == "u" ? 4 : 8)
                    var taken = 0
                    while taken < digits, let next = current, next.isHexDigit {
                        position += 1
                        taken += 1
                    }
                }
                return .one
            default:
                return .one
            }
        }

        mutating func quantified(_ length: Length) -> Length {
            var result = length
            switch current {
            case "*":
                position += 1
                result = length.repeated(0, nil)
            case "+":
                position += 1
                result = length.repeated(1, nil)
            case "?":
                position += 1
                result = length.repeated(0, 1)
            case "{":
                guard let bounds = braces() else { return length }
                result = length.repeated(bounds.low, bounds.high)
            default:
                return length
            }
            if current == "?" {
                position += 1
            } else if current == "+" {
                note(.possessiveQuantifier)
                position += 1
            }
            return result
        }

        /// Reads `{n}`, `{n,}` or `{n,m}`. Leaves the position alone when the braces hold something else.
        mutating func braces() -> (low: Int, high: Int?)? {
            var index = position + 1
            var text = ""
            while index < characters.count, characters[index] != "}" {
                text.append(characters[index])
                index += 1
            }
            guard index < characters.count else { return nil }
            let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let low = parts.first.flatMap({ Int($0) }), parts.count <= 2 else { return nil }
            var high: Int? = low
            if parts.count == 2 {
                if parts[1].isEmpty {
                    high = nil
                } else if let value = Int(parts[1]) {
                    high = value
                } else {
                    return nil
                }
            }
            position = index + 1
            return (low, high)
        }
    }
}

/// Trying a rule on sample text.
///
/// The system's regular expression engine stands in for Espanso's, so the result is a close approximation.
public enum RegexTest {
    public struct Match: Hashable, Sendable {
        /// The text the rule replaces.
        public var matched: String
        /// The sample up to the point where the rule fires, without the matched text.
        public var before: String
        /// What would be typed after the rule has fired.
        public var after: String
        /// Named groups and what they caught, in the order they are written.
        public var groups: [Capture]
        /// The expansion with the groups filled in. Nil for an expansion that has no text.
        public var output: String?
    }

    public struct Capture: Hashable, Sendable {
        public var name: String
        public var value: String
    }

    public enum Outcome: Hashable, Sendable {
        /// Nothing to test yet.
        case idle
        /// The system's engine can't read the pattern.
        case unreadable(String)
        case noMatch
        case match(Match)
    }

    /// The longest sample that is tried.
    public static let sampleLimit = 2_000

    /// Types the sample one character at a time, as Espanso sees it, and stops at the first match.
    ///
    /// - Parameter limit: How many of the last characters typed Espanso keeps.
    public static func run(pattern: String, expansion: Expansion, sample: String, limit: Int) -> Outcome {
        guard !pattern.isEmpty, !sample.isEmpty else { return .idle }
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: RegexSyntax.systemPattern(for: pattern))
        } catch {
            return .unreadable(error.localizedDescription)
        }
        let names = RegexAnalysis(pattern: pattern).groupNames
        let typed = Array(sample.prefix(sampleLimit))
        for end in 1...typed.count {
            let start = max(0, end - max(1, limit))
            let buffer = String(typed[start..<end])
            let whole = NSRange(buffer.startIndex..., in: buffer)
            guard let result = expression.firstMatch(in: buffer, range: whole), result.range.length > 0,
                  let range = Range(result.range, in: buffer)
            else { continue }
            var captures: [Capture] = []
            var seen = Set<String>()
            for name in names where seen.insert(name).inserted {
                let value = Range(result.range(withName: name), in: buffer).map { String(buffer[$0]) } ?? ""
                captures.append(Capture(name: name, value: value))
            }
            let matched = String(buffer[range])
            return .match(Match(
                matched: matched,
                before: String(typed[0..<start]) + buffer[..<range.lowerBound],
                after: String(typed[end...]),
                groups: captures,
                output: output(of: expansion, captures: captures)
            ))
        }
        return .noMatch
    }

    /// The expansion's text with each `{{group}}` replaced by what the group caught.
    static func output(of expansion: Expansion, captures: [Capture]) -> String? {
        switch expansion {
        case .text(let body), .markdown(let body), .html(let body):
            let values = Dictionary(captures.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
            return ExpansionPiece.pieces(of: body, isShortForm: false).map { piece in
                switch piece.kind {
                case .cursor: return ""
                case .variable(let name, nil): return values[name] ?? piece.source
                default: return piece.source
                }
            }.joined()
        case .form, .image, .missing:
            return nil
        }
    }
}

/// Rewrites a rule written the way other text expanders have it: numbered groups referred to as `$1`.
public enum RegexConversion {
    public struct Result: Hashable, Sendable {
        public var pattern: String
        public var body: String
    }

    /// Names the numbered groups the expansion refers to, respells `(?<name>` as `(?P<name>`, and turns
    /// `$1`, `${1}` and `${name}` in the expansion into `{{…}}`. Nil when there is nothing to change.
    public static func convert(pattern: String, body: String) -> Result? {
        let analysis = RegexAnalysis(pattern: pattern)
        guard !analysis.issues.contains(.unbalancedParentheses) else { return nil }
        var taken = Set(analysis.groupNames)
        var names: [Int: String] = [:]
        for group in analysis.groups {
            if let name = group.name { names[group.number] = name }
        }

        // The expansion first, to learn which numbered groups are used.
        var newBody = ""
        var used = Set<Int>()
        var rest = body[...]
        while let dollar = rest.firstIndex(of: "$") {
            newBody += rest[..<dollar]
            let tail = rest[rest.index(after: dollar)...]
            var reference = ""
            var end = tail.startIndex
            if tail.first == "{", let close = tail.firstIndex(of: "}") {
                reference = String(tail[tail.index(after: tail.startIndex)..<close])
                end = tail.index(after: close)
            } else {
                // One digit, so that "$10" after one group stays "$1" followed by a zero.
                if let digit = tail.first, digit.isASCII, digit.isNumber {
                    reference = String(digit)
                    end = tail.index(after: tail.startIndex)
                }
            }
            if let number = Int(reference), let group = analysis.groups.first(where: { $0.number == number }) {
                var name = names[number]
                if name == nil {
                    var candidate = "group\(number)"
                    while taken.contains(candidate) { candidate += "_" }
                    taken.insert(candidate)
                    names[number] = candidate
                    name = candidate
                }
                if group.name == nil { used.insert(number) }
                newBody += "{{\(name ?? "")}}"
                rest = tail[end...]
            } else if !reference.isEmpty, analysis.groupNames.contains(reference) {
                newBody += "{{\(reference)}}"
                rest = tail[end...]
            } else {
                newBody += "$"
                rest = tail
            }
        }
        newBody += rest

        var characters = Array(pattern)
        for group in analysis.groups.reversed() {
            if group.name == nil, used.contains(group.number), let name = names[group.number] {
                characters.insert(contentsOf: Array("?P<\(name)>"), at: group.offset + 1)
            } else if group.usesPlainName {
                characters.insert("P", at: group.offset + 2)
            }
        }
        let result = Result(pattern: String(characters), body: newBody)
        return result.pattern == pattern && result.body == body ? nil : result
    }
}
