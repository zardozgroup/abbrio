import Foundation
public import SnippetModel
import Yams

/// Writes the values of a match as YAML text.
///
/// Every piece of text it produces is parsed back before it is returned, so a string can't come out as a
/// number, a boolean or a different string.
enum YAMLEmitter {
    /// The lines of `key: value` for a string. The first line has no indentation; a block's following lines
    /// are indented for a key that starts at column `indent`.
    ///
    /// - Parameter onOneLine: Writes text with line breaks as a quoted string with `\n` instead of a block.
    static func lines(
        key: String, string: String, indent: Int, prefer: ScalarStyle? = nil, onOneLine: Bool = false
    ) throws(EditError) -> [String] {
        if let inline = inline(string, prefer: prefer, inFlow: false) {
            return ["\(key): \(inline)"]
        }
        if !onOneLine, let block = literalBlock(key: key, string: string, indent: indent) {
            return block
        }
        let quoted = doubleQuoted(string)
        guard parsesBack("k: \(quoted)", to: string) else {
            throw .verificationFailed("The text of \"\(key)\" can't be written as YAML.")
        }
        return ["\(key): \(quoted)"]
    }

    static func lines(key: String, bool: Bool) -> [String] {
        ["\(key): \(bool ? "true" : "false")"]
    }

    /// The lines of `key: [a, b]`, or a block list when an item doesn't fit on a line.
    static func lines(key: String, strings: [String], indent: Int) throws(EditError) -> [String] {
        let items = strings.map { inline($0, prefer: nil, inFlow: true) }
        if !items.contains(nil) {
            let line = "\(key): [" + items.compactMap { $0 }.joined(separator: ", ") + "]"
            if line.count + indent <= 100 { return [line] }
        }
        var lines = ["\(key):"]
        let padding = String(repeating: " ", count: indent + 2)
        for string in strings {
            let text = inline(string, prefer: nil, inFlow: false) ?? doubleQuoted(string)
            guard parsesBack("k: \(text)", to: string) else {
                throw .verificationFailed("An item of \"\(key)\" can't be written as YAML.")
            }
            lines.append(padding + "- " + text)
        }
        return lines
    }

    // MARK: Variables

    /// The lines of `key: value` for any value. The first line has no indentation; the others are whole
    /// lines for a key that starts at column `indent`.
    static func lines(key: String, value: ParamValue, indent: Int) throws(EditError) -> [String] {
        switch value {
        case .string(let string):
            // A form's layout reads better on one line, with its line breaks spelled out.
            return try lines(key: key, string: string, indent: indent, onOneLine: key == "layout")
        case .int(let number):
            return ["\(key): \(number)"]
        case .bool(let flag):
            return lines(key: key, bool: flag)
        case .other(let raw):
            return [raw.isEmpty ? "\(key):" : "\(key): \(raw)"]
        case .list(let items):
            guard !items.isEmpty else { return ["\(key): []"] }
            var result = ["\(key):"]
            for item in items {
                result += try itemLines(item, indent: indent + 2)
            }
            return result
        case .map(let entries):
            guard !entries.isEmpty else { return ["\(key): {}"] }
            return ["\(key):"] + (try entryLines(entries, indent: indent + 2))
        }
    }

    /// Whole lines for the entries of a mapping whose keys start at column `indent`.
    static func entryLines(_ entries: [ParamEntry], indent: Int) throws(EditError) -> [String] {
        let padding = String(repeating: " ", count: indent)
        var result: [String] = []
        for entry in entries {
            guard let key = inline(entry.key, prefer: nil, inFlow: false) else {
                throw .verificationFailed("The name \"\(entry.key)\" can't be written as YAML.")
            }
            let lines = try lines(key: key, value: entry.value, indent: indent)
            result.append(padding + lines[0])
            result += lines.dropFirst()
        }
        return result
    }

    /// Whole lines for one item of a list whose dash is at column `indent`.
    static func itemLines(_ item: ParamValue, indent: Int) throws(EditError) -> [String] {
        let padding = String(repeating: " ", count: indent)
        switch item {
        case .map(let entries) where !entries.isEmpty:
            var lines = try entryLines(entries, indent: indent + 2)
            lines[0] = padding + "- " + lines[0].dropFirst(indent + 2)
            return lines
        case .list(let items) where !items.isEmpty:
            var lines: [String] = []
            for inner in items {
                lines += try itemLines(inner, indent: indent + 2)
            }
            lines[0] = padding + "- " + lines[0].dropFirst(indent + 2)
            return lines
        default:
            var lines = try lines(key: "k", value: item, indent: indent)
            lines[0] = padding + "- " + lines[0].dropFirst(3)
            return lines
        }
    }

    /// Whole lines for one entry of `vars:` or `global_vars:`, with its dash at column `indent`.
    static func variableLines(_ variable: SnippetVariable, indent: Int) throws(EditError) -> [String] {
        var entries = [ParamEntry("name", .string(variable.name)), ParamEntry("type", .string(variable.type))]
        if !variable.params.isEmpty {
            entries.append(ParamEntry("params", .map(variable.params)))
        }
        entries += variable.extras
        return try itemLines(.map(entries), indent: indent)
    }

    /// The lines of a `vars:` or `global_vars:` key. An entry that is the same as before keeps its lines.
    ///
    /// - Parameters:
    ///   - old: The variables the key holds now, and the key's lines as `chunks(of:)` gives them.
    ///   - indent: The column of the key.
    static func variableListLines(
        key: String, variables: [SnippetVariable], old: (variables: [SnippetVariable], lines: [String])?, indent: Int
    ) throws(EditError) -> [String] {
        var preamble: [String] = []
        var segments: [[String]] = []
        var dashIndent = indent + 2
        if let old, let split = split(listLines: old.lines), split.items.count == old.variables.count {
            preamble = split.preamble
            segments = split.items
            dashIndent = split.dashIndent
        }
        var available = Array(segments.indices)
        var result = ["\(key):"] + preamble
        for variable in variables {
            if let old, let position = available.first(where: { old.variables[$0] == variable }) {
                available.removeAll { $0 == position }
                result += segments[position]
            } else {
                result += try variableLines(variable, indent: dashIndent)
            }
        }
        return result
    }

    /// Cuts the lines of a block list into its items. Nil when the list is not written one item per dash.
    private static func split(listLines lines: [String]) -> (preamble: [String], items: [[String]], dashIndent: Int)? {
        guard let first = lines.first, first.split(separator: "#")[0].trimmingCharacters(in: .whitespaces).hasSuffix(":") else {
            return nil
        }
        func isDash(_ line: String, at indent: Int) -> Bool {
            let content = line.dropFirst(indent)
            return line.prefix(indent).allSatisfy { $0 == " " } && line.count > indent
                && (content == "-" || content.hasPrefix("- "))
        }
        let rest = Array(lines.dropFirst())
        guard let firstDash = rest.first(where: { line in
            let content = line.drop { $0 == " " }
            return !content.isEmpty && content.first != "#"
        }) else { return nil }
        let dashIndent = firstDash.prefix { $0 == " " }.count
        guard isDash(firstDash, at: dashIndent) else { return nil }

        var preamble: [String] = []
        var items: [[String]] = []
        for line in rest {
            if isDash(line, at: dashIndent) {
                items.append([line])
            } else if items.isEmpty {
                preamble.append(line)
            } else {
                items[items.count - 1].append(line)
            }
        }
        return (preamble, items, dashIndent)
    }

    // MARK: Scalars

    /// A one-line form of the string, or nil when it needs a block.
    private static func inline(_ string: String, prefer: ScalarStyle?, inFlow: Bool) -> String? {
        guard !string.contains(where: \.isNewline) else {
            return nil
        }
        func check(_ text: String) -> Bool {
            inFlow ? parsesBackInFlow(text, to: string) : parsesBack("k: \(text)", to: string)
        }

        var candidates: [String] = []
        let quoted = doubleQuoted(string)
        switch prefer {
        case .doubleQuoted:
            candidates = [quoted]
        case .singleQuoted:
            candidates = ["'" + string.replacingOccurrences(of: "'", with: "''") + "'", quoted]
        default:
            if looksPlain(string) { candidates.append(string) }
            candidates.append(quoted)
        }
        return candidates.first(where: check)
    }

    /// Unquoted text is used only for words that start with a letter or digit and have no edge spaces. The
    /// parse check then rules out anything YAML would read as another type or cut short.
    private static func looksPlain(_ string: String) -> Bool {
        guard let first = string.first, let last = string.last else { return false }
        guard first.isLetter || first.isNumber, !last.isWhitespace else { return false }
        return !string.unicodeScalars.contains { needsEscape($0) }
    }

    private static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09: return false
        case 0x00...0x1F, 0x7F, 0x85, 0xA0, 0x2028, 0x2029, 0xFEFF: return true
        default: return false
        }
    }

    private static func doubleQuoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if needsEscape(scalar) {
                    result += scalar.value <= 0xFF
                        ? String(format: "\\x%02X", scalar.value)
                        : String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// A `|` block for text with line breaks. Nil when the text has characters a block can't hold.
    private static func literalBlock(key: String, string: String, indent: Int) -> [String]? {
        guard !string.unicodeScalars.contains(where: { $0 != "\n" && needsEscape($0) }),
              !string.contains("\r"), !string.contains("\t")
        else { return nil }

        var body = string.components(separatedBy: "\n")
        var trailingBreaks = 0
        while body.last == "" {
            body.removeLast()
            trailingBreaks += 1
        }
        guard let first = body.first, !body.contains(where: { $0.hasSuffix(" ") }) else { return nil }

        var header = "|"
        // A first line that starts with a space needs the indentation spelled out.
        if first.hasPrefix(" ") { header += "2" }
        switch trailingBreaks {
        case 0: header += "-"
        case 1: break
        default: header += "+"
        }

        let padding = String(repeating: " ", count: indent + 2)
        var lines = ["\(key): \(header)"]
        lines += body.map { $0.isEmpty ? "" : padding + $0 }
        if trailingBreaks > 1 {
            lines += Array(repeating: "", count: trailingBreaks - 1)
        }

        // Check it the way it will sit in the file, followed by another key.
        let sample = (["k: \(header)"] + lines.dropFirst().map { String($0.dropFirst(min(indent, $0.count))) })
            .joined(separator: "\n") + "\nz: 1\n"
        return parsesBack(sample, to: string) ? lines : nil
    }

    // MARK: Checks

    private static func parsesBack(_ yaml: String, to string: String) -> Bool {
        guard let loaded = try? Yams.load(yaml: yaml), let mapping = loaded as? [String: Any] else { return false }
        return mapping["k"] as? String == string
    }

    private static func parsesBackInFlow(_ item: String, to string: String) -> Bool {
        guard let loaded = try? Yams.load(yaml: "k: [\(item), z]"), let mapping = loaded as? [String: Any],
              let list = mapping["k"] as? [Any], list.count == 2
        else { return false }
        return list[0] as? String == string
    }
}

/// The YAML the app writes for a piece of dynamic content, for showing in the editor.
public enum YAMLPreview {
    /// One entry of `vars:`, as it will be written. Empty when it can't be written.
    public static func text(for variable: SnippetVariable) -> String {
        ((try? YAMLEmitter.variableLines(variable, indent: 0)) ?? []).joined(separator: "\n")
    }
}
