import Foundation
public import SnippetModel
import Yams

/// The contents of one match file.
public struct ParsedMatchFile: Sendable {
    public var snippets: [Snippet] = []
    /// Lines of comments directly above each match, keyed by the match's position in the file.
    public var leadingComments: [Int: LineRange] = [:]
    /// Paths listed under `imports:`.
    public var imports: [String] = []
    /// Names of the variables under `global_vars:`.
    public var globalVariableNames: [String] = []
    /// The variables under `global_vars:`, for display.
    public var globalVariables: [GlobalVariable] = []
    /// The variables under `global_vars:`, in full.
    public var globalVariableList: [SnippetVariable] = []
    /// False when `global_vars:` holds something that isn't a variable, so the list can't be rewritten.
    public var globalVariablesAreComplete = true
    /// Parts of the file that were skipped.
    public var problems: [SetProblem] = []

    /// Where each item under `matches:` sits, keyed by its position in the list.
    var itemRanges: [Int: LineRange] = [:]
    /// How each match is laid out, for the ones written as a plain block mapping.
    var layouts: [Int: MatchLayout] = [:]
    /// The line of the `matches:` key.
    var matchesKeyLine: Int?
    /// The number of items under `matches:`, matches or not.
    var itemCount = 0
}

/// One key of a match and where it starts.
struct KeyLayout: Sendable {
    var name: String
    var line: Int
    /// How a scalar value is quoted. Nil for a list or a mapping.
    var style: ScalarStyle?
}

/// The lines of a match that is written as a block mapping with one key per line.
struct MatchLayout: Sendable {
    var range: LineRange
    /// Number of spaces before the dash.
    var indent: Int
    var keys: [KeyLayout]
}

enum ScalarStyle: Sendable {
    case plain, singleQuoted, doubleQuoted, block
}

/// A file that can't be parsed at all.
public struct MatchFileError: Error, Equatable, Sendable {
    public var line: Int?
    public var message: String
}

public enum MatchFileParser {
    /// Parses the text of a match file.
    ///
    /// - Parameters:
    ///   - text: The file's contents.
    ///   - path: The file's path relative to the config folder. It becomes part of each match's identity.
    /// - Throws: `MatchFileError` when the text is not valid YAML or does not have the shape of a match file.
    public static func parse(_ text: String, path: String) throws -> ParsedMatchFile {
        let root: Node?
        do {
            root = try Yams.compose(yaml: text)
        } catch let error as YamlError {
            throw MatchFileError(yamlError: error)
        } catch {
            throw MatchFileError(line: nil, message: error.localizedDescription)
        }

        var result = ParsedMatchFile()
        guard let root else { return result }
        // Aliases make a short text stand for a huge tree, and everything below walks the tree. A file that
        // expands past the budget is refused before anything else looks at it.
        var budget = nodeBudget
        guard fitsBudget(root, &budget) else {
            throw MatchFileError(line: nil, message: "The file uses YAML aliases that expand to more than Abbrio reads.")
        }
        if case .scalar(let scalar) = root, scalar.string.isEmpty || scalar.string == "~" || scalar.string == "null" {
            return result
        }
        guard case .mapping(let top) = root else {
            throw MatchFileError(line: root.mark?.line, message: "The file must start with keys such as \"matches:\".")
        }

        let lines = SourceLines(text)
        var topLevelKeyLines: [Int] = []
        var matchesNode: Node?

        for (key, value) in top {
            if let line = key.mark?.line { topLevelKeyLines.append(line) }
            switch key.string {
            case "matches":
                matchesNode = value
                result.matchesKeyLine = key.mark?.line
            case "imports":
                result.imports = value.sequence?.compactMap(\.string) ?? []
            case "global_vars":
                result.globalVariableNames = value.sequence?.compactMap { $0.mapping?["name"]?.string } ?? []
                result.globalVariables = value.sequence?.compactMap(globalVariable) ?? []
                let items = value.sequence.map(Array.init) ?? []
                result.globalVariableList = items.compactMap(makeVariable)
                result.globalVariablesAreComplete = value.sequence != nil && result.globalVariableList.count == items.count
            default:
                break
            }
        }

        guard let matchesNode else { return result }
        guard case .sequence(let items) = matchesNode else {
            if case .scalar(let scalar) = matchesNode, scalar.string.isEmpty || scalar.string == "~" {
                return result
            }
            throw MatchFileError(line: matchesNode.mark?.line, message: "\"matches:\" must be a list.")
        }

        // Where each item's dash is. Aliases point back at their anchor, so the lines are trusted only when they
        // increase from one item to the next.
        let itemNodes = Array(items)
        result.itemCount = itemNodes.count
        var dashLines: [Int?] = itemNodes.map { node in
            guard let mark = node.mark else { return nil }
            return lines.dashLine(forNodeAtLine: mark.line, column: mark.column - 1)
        }
        var previous = 0
        var rangesAreReliable = true
        for line in dashLines {
            guard let line, line > previous else {
                rangesAreReliable = false
                break
            }
            previous = line
        }
        if !rangesAreReliable {
            dashLines = dashLines.map { _ in nil }
        }

        let lastDash = dashLines.last.flatMap { $0 } ?? 0
        let nextTopLevelKey = topLevelKeyLines.filter { $0 > lastDash }.min()
        let sequenceEnd = (nextTopLevelKey ?? (lines.count + 1)) - 1

        for (index, node) in itemNodes.enumerated() {
            var range: LineRange?
            if let dash = dashLines[index] {
                let nextDash = index + 1 < dashLines.count ? dashLines[index + 1] : nil
                var rawEnd = (nextDash ?? (sequenceEnd + 1)) - 1
                if let nextDash, let comment = lines.leadingCommentStart(aboveDashLine: nextDash) {
                    rawEnd = comment - 1
                }
                let end = lines.trimmingTrailingBlanksAndComments(first: dash, last: max(dash, rawEnd))
                range = LineRange(first: dash, last: end)
                result.itemRanges[index] = range
                if let commentStart = lines.leadingCommentStart(aboveDashLine: dash) {
                    result.leadingComments[index] = LineRange(first: commentStart, last: dash - 1)
                }
            }

            guard case .mapping(let mapping) = node else {
                result.problems.append(SetProblem(
                    severity: .skipped,
                    file: path,
                    line: dashLines[index] ?? node.mark?.line,
                    message: "Item \(index + 1) under \"matches:\" is not a match and was skipped."
                ))
                continue
            }

            var snippet = makeSnippet(from: mapping, id: Snippet.ID(file: path, index: index))
            snippet.sourceRange = range
            if let range {
                snippet.source = lines.text(in: range)
                let dashContent = lines.line(range.first).drop { $0 == " " }.dropFirst().drop { $0 == " " }
                if dashContent.first == "{" || dashContent.first == "&" || dashContent.first == "*" {
                    snippet.needsAdvancedYAML = true
                }
                // A value that lives outside the item's own lines came through an alias.
                for (_, value) in mapping {
                    if let line = value.mark?.line, line < range.first || line > range.last {
                        snippet.needsAdvancedYAML = true
                    }
                }
                if let layout = layout(of: mapping, in: range, lines: lines) {
                    result.layouts[index] = layout
                } else {
                    snippet.needsAdvancedYAML = true
                }
            } else {
                snippet.needsAdvancedYAML = true
            }
            result.snippets.append(snippet)
        }
        return result
    }

    private static func globalVariable(_ node: Node) -> GlobalVariable? {
        guard let mapping = node.mapping, let name = mapping["name"]?.string else { return nil }
        let type = mapping["type"]?.string ?? ""
        let parameters = mapping["params"]?.mapping
        // The parameter that tells most about each type comes first; any other scalar is the fallback.
        let preferred = ["echo", "format", "cmd", "trigger", "args"]
        var value = preferred.lazy.compactMap { parameters?[$0]?.string }.first
        if value == nil, let parameters {
            value = parameters.lazy.compactMap { $0.value.string }.first
        }
        return GlobalVariable(name: name, type: type, value: value ?? "")
    }

    /// The layout of a match whose keys each start a line at the same indentation, the first one right after
    /// the dash. Returns nil for anything else, which the form then leaves alone.
    private static func layout(of mapping: Node.Mapping, in range: LineRange, lines: SourceLines) -> MatchLayout? {
        let indent = lines.indentation(ofLine: range.first)
        let padding = String(repeating: " ", count: indent)
        var keys: [KeyLayout] = []
        var previousLine = range.first - 1

        for (key, value) in mapping {
            guard let name = key.string, let mark = key.mark, case .scalar = key else { return nil }
            guard mark.column - 1 == indent + 2, mark.line >= range.first, mark.line <= range.last else { return nil }
            let line = lines.line(mark.line)
            if keys.isEmpty {
                guard mark.line == range.first, line.hasPrefix(padding + "- ") else { return nil }
            } else {
                guard mark.line > previousLine, line.hasPrefix(padding + "  ") else { return nil }
            }
            previousLine = mark.line

            var style: ScalarStyle?
            if case .scalar(let scalar) = value {
                switch scalar.style {
                case .singleQuoted: style = .singleQuoted
                case .doubleQuoted: style = .doubleQuoted
                case .literal, .folded: style = .block
                default: style = .plain
                }
            }
            keys.append(KeyLayout(name: name, line: mark.line, style: style))
        }
        return keys.isEmpty ? nil : MatchLayout(range: range, indent: indent, keys: keys)
    }

    private static let knownKeys: Set<String> = [
        "trigger", "triggers", "regex", "replace", "markdown", "html", "image_path", "form", "label",
        "search_terms", "word", "left_word", "right_word", "propagate_case", "uppercase_style", "force_mode",
        "paragraph", "vars", "form_fields",
    ]

    private static func makeSnippet(from mapping: Node.Mapping, id: Snippet.ID) -> Snippet {
        var snippet = Snippet(id: id)

        for (key, value) in mapping {
            guard let name = key.string else { continue }
            switch name {
            case "trigger":
                if let trigger = value.string { snippet.triggers.insert(trigger, at: 0) }
            case "triggers":
                snippet.triggers.append(contentsOf: value.sequence?.compactMap(\.string) ?? [])
            case "regex":
                snippet.regex = value.string
            case "replace":
                snippet.expansion = .text(value.string ?? "")
            case "markdown":
                snippet.expansion = .markdown(value.string ?? "")
            case "html":
                snippet.expansion = .html(value.string ?? "")
            case "image_path":
                snippet.expansion = .image(path: value.string ?? "")
            case "form":
                snippet.expansion = .form(value.string ?? "")
            case "label":
                snippet.label = value.string
            case "search_terms":
                snippet.searchTerms = value.sequence?.compactMap(\.string) ?? []
            case "word":
                snippet.options.word = value.bool ?? false
            case "left_word":
                snippet.options.leftWord = value.bool ?? false
            case "right_word":
                snippet.options.rightWord = value.bool ?? false
            case "propagate_case":
                snippet.options.propagateCase = value.bool ?? false
            case "uppercase_style":
                snippet.options.uppercaseStyle = value.string.flatMap(UppercaseStyle.init(rawValue:))
            case "force_mode":
                snippet.options.forceMode = value.string.flatMap(ForceMode.init(rawValue:))
            case "paragraph":
                snippet.options.paragraph = value.bool ?? false
            case "vars":
                let items = value.sequence.map(Array.init) ?? []
                snippet.variables = items.compactMap(makeVariable)
                // Something in the list that isn't a variable would be lost if the form rewrote it.
                if value.sequence == nil || snippet.variables.count != items.count {
                    snippet.needsAdvancedYAML = true
                }
            case "form_fields":
                if case .map(let fields) = paramValue(value) {
                    snippet.formFields = fields
                } else {
                    snippet.needsAdvancedYAML = true
                }
            default:
                break
            }
            if !knownKeys.contains(name) {
                snippet.unknownKeys.append(name)
            }
        }

        if !snippet.unknownKeys.isEmpty {
            snippet.needsAdvancedYAML = true
        }
        return snippet
    }

    private static func makeVariable(from node: Node) -> SnippetVariable? {
        guard let mapping = node.mapping,
              let name = mapping["name"]?.string,
              let type = mapping["type"]?.string
        else { return nil }
        var variable = SnippetVariable(name: name, type: type)
        for (key, value) in mapping {
            guard let key = key.string else { return nil }
            switch key {
            case "name", "type":
                continue
            case "params":
                guard case .map(let params) = paramValue(value) else {
                    // An empty `params:` is as good as none.
                    if case .scalar(let scalar) = value, scalar.string.isEmpty || scalar.string == "~" { continue }
                    return nil
                }
                variable.params = params
            default:
                variable.extras.append(ParamEntry(key, paramValue(value)))
            }
        }
        return variable
    }

    /// How many nodes a file may hold once its aliases are expanded. The largest files on the Espanso Hub hold
    /// a few tens of thousands.
    static let nodeBudget = 2_000_000

    /// Counts the nodes of a tree with its aliases expanded, stopping as soon as the budget runs out, so the
    /// count itself never takes long.
    static func fitsBudget(_ node: Node, _ budget: inout Int) -> Bool {
        budget -= 1
        guard budget >= 0 else { return false }
        switch node {
        case .sequence(let sequence):
            for item in sequence where !fitsBudget(item, &budget) { return false }
        case .mapping(let mapping):
            for (key, value) in mapping where !fitsBudget(key, &budget) || !fitsBudget(value, &budget) { return false }
        default:
            break
        }
        return true
    }

    /// The value of a node, keeping apart text, whole numbers, true and false, and anything else.
    static func paramValue(_ node: Node) -> ParamValue {
        switch node {
        case .scalar(let scalar):
            guard scalar.style == .plain else { return .string(scalar.string) }
            switch node.tag.rawValue {
            case Tag.Name.str.rawValue:
                return .string(scalar.string)
            case Tag.Name.int.rawValue:
                return Int(scalar.string).map(ParamValue.int) ?? .other(scalar.string)
            case Tag.Name.bool.rawValue:
                if scalar.string == "true" { return .bool(true) }
                if scalar.string == "false" { return .bool(false) }
                return .other(scalar.string)
            default:
                return .other(scalar.string)
            }
        case .sequence(let sequence):
            return .list(sequence.map(paramValue))
        case .mapping(let mapping):
            return .map(mapping.map { ParamEntry($0.key.string ?? "", paramValue($0.value)) })
        default:
            return .other("")
        }
    }
}

extension MatchFileError {
    init(yamlError: YamlError) {
        switch yamlError {
        case .scanner(_, let problem, let mark, _),
             .parser(_, let problem, let mark, _),
             .composer(_, let problem, let mark, _):
            self.init(line: mark.line, message: problem)
        case .reader(let problem, _, _, _):
            self.init(line: nil, message: problem)
        default:
            self.init(line: nil, message: String(describing: yamlError))
        }
    }
}
