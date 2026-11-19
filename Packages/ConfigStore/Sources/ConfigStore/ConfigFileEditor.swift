public import Foundation
import Yams

/// A value for a top-level key of a config file.
public enum ConfigValue: Equatable, Sendable {
    case bool(Bool)
    case integer(Int)
    case string(String)
    /// A fixed word that needs no quotes, such as `auto` or `OFF`.
    case word(String)

    var yaml: String {
        switch self {
        case .word(let value):
            let isPlain = !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" }
            return isPlain ? value : ConfigFileEditor.quoted(value)
        case .bool(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .string(let value): return ConfigFileEditor.quoted(value)
        }
    }
}

/// Changes single top-level keys of a file in `config/`, leaving every other line as it was.
public enum ConfigFileEditor {
    /// Sets a key to a list of strings, written one item per line. Nil removes the key; an empty list is
    /// written as `key: []`, which is not the same thing when the key would otherwise be inherited.
    public static func setList(_ key: String, _ items: [String]?, in data: Data) throws(EditError) -> Data {
        guard let items else { return try set(key, lines: nil, in: data) }
        let lines = items.isEmpty ? ["\(key): []"] : ["\(key):"] + items.map { "  - " + quoted($0) }
        return try set(key, lines: lines, in: data)
    }

    /// Sets a key to a single value. Nil removes the key.
    public static func setValue(_ key: String, _ value: ConfigValue?, in data: Data) throws(EditError) -> Data {
        try set(key, lines: value.map { ["\(key): \($0.yaml)"] }, in: data)
    }

    /// Switches Espanso's statistics on or off by setting `enabled:` under `stats:`. Nil removes the line,
    /// and the `stats:` key with it when nothing else is left under it.
    public static func setStatsEnabled(_ isEnabled: Bool?, in data: Data) throws(EditError) -> Data {
        let wanted = isEnabled.map { "enabled: \($0 ? "true" : "false")" }
        guard let block = try lines(ofKey: "stats", in: data) else {
            return try set("stats", lines: wanted.map { ["stats:", "  " + $0] }, in: data)
        }
        func content(_ line: String) -> Substring { line.drop { $0 == " " || $0 == "\t" } }
        func isNoise(_ line: String) -> Bool { content(line).isEmpty || content(line).first == "#" }

        let header = content(block[0])
        let afterKey = header.dropFirst("stats:".count).drop { $0 == " " }
        guard header.hasPrefix("stats:"), afterKey.isEmpty || afterKey.first == "#" else {
            // Written on one line, as in `stats: {enabled: true}`. Only a line that holds nothing else is replaced.
            let text = String(decoding: data, as: UTF8.self)
            let file = ConfigFileParser.parse(text, path: "", url: URL(fileURLWithPath: "/"))
            guard let node = try? Yams.compose(yaml: text), case .mapping(let stats)? = node["stats"],
                  stats.count <= 1, file.statsEnabled != nil || stats.isEmpty
            else {
                throw .notEditable("The stats setting is written in a way the app can't change safely. Edit the file by hand.")
            }
            return try set("stats", lines: wanted.map { ["stats:", "  " + $0] }, in: data)
        }

        var lines = block
        if let index = lines.indices.dropFirst().first(where: { content(lines[$0]).hasPrefix("enabled:") }) {
            let indent = lines[index].prefix { $0 == " " || $0 == "\t" }
            if let wanted { lines[index] = indent + wanted } else { lines.remove(at: index) }
        } else if let wanted {
            let indent = lines.dropFirst().first { !isNoise($0) }.map { String($0.prefix { $0 == " " || $0 == "\t" }) } ?? "  "
            lines.insert(indent + wanted, at: 1)
        }
        let isEmpty = lines.dropFirst().allSatisfy(isNoise)
        return try set("stats", lines: isEmpty && wanted == nil ? nil : lines, in: data)
    }

    /// A double-quoted YAML string.
    static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case "\u{A0}": result += "\\xa0"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                // Other control characters are written by number, so the line stays readable.
                result += "\\x" + (scalar.value < 0x10 ? "0" : "") + String(scalar.value, radix: 16)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private struct TopLevelKey {
        var name: String
        var first: Int
        var last: Int
    }

    private static func compose(_ document: SourceDocument) throws(EditError) -> Node.Mapping? {
        let root: Node?
        do {
            root = try Yams.compose(yaml: document.text)
        } catch let error as YamlError {
            let failure = MatchFileError(yamlError: error)
            throw .invalidYAML(line: failure.line, message: failure.message)
        } catch {
            throw .invalidYAML(line: nil, message: error.localizedDescription)
        }
        guard let root else { return nil }
        if case .scalar(let scalar) = root, scalar.string.isEmpty || scalar.string == "~" || scalar.string == "null" {
            return nil
        }
        guard case .mapping(let mapping) = root else {
            throw .notEditable("The file doesn't hold settings as \"key: value\" lines.")
        }
        return mapping
    }

    private static func keys(of mapping: Node.Mapping?, in document: SourceDocument) throws(EditError) -> [TopLevelKey] {
        guard let mapping else { return [] }
        var starts: [(name: String, line: Int)] = []
        for (key, _) in mapping {
            guard let name = key.string, let mark = key.mark, mark.column == 1,
                  document.line(mark.line).hasPrefix(name) || document.line(mark.line).first == "\"" || document.line(mark.line).first == "'"
            else {
                throw .notEditable("The file is written in a way the app can't change safely. Edit it by hand.")
            }
            starts.append((name, mark.line))
        }
        starts.sort { $0.line < $1.line }
        var keys: [TopLevelKey] = []
        for (position, start) in starts.enumerated() {
            var last = position + 1 < starts.count ? starts[position + 1].line - 1 : document.count
            // Blank lines and comments after a value sit between keys and stay where they are.
            while last > start.line {
                let content = document.line(last).drop { $0 == " " || $0 == "\t" }
                if content.isEmpty || content.first == "#" { last -= 1 } else { break }
            }
            keys.append(TopLevelKey(name: start.name, first: start.line, last: last))
        }
        return keys
    }

    /// The lines a top-level key occupies, or nil when the file doesn't have the key.
    static func lines(ofKey key: String, in data: Data) throws(EditError) -> [String]? {
        let document = try SourceDocument(data)
        guard let existing = try keys(of: try compose(document), in: document).first(where: { $0.name == key }) else {
            return nil
        }
        return (existing.first...existing.last).map { document.line($0) }
    }

    /// Replaces the lines of a top-level key, adds the key, or with nil removes it.
    ///
    /// - Parameter other: A new key goes in front of this key, above the comment lines directly over it.
    ///   Without it, or when the file doesn't have that key, a new key goes at the end.
    static func set(_ key: String, lines: [String]?, in data: Data, before other: String? = nil) throws(EditError) -> Data {
        var document = try SourceDocument(data)
        let before = try compose(document)
        let keys = try keys(of: before, in: document)

        if let existing = keys.first(where: { $0.name == key }) {
            document.replace(first: existing.first, last: existing.last, with: lines ?? [])
        } else if let lines {
            if let next = keys.first(where: { $0.name == other }) {
                var line = next.first
                while line > 1, document.line(line - 1).drop(while: { $0 == " " }).first == "#" {
                    line -= 1
                }
                // Comments that run up to the top of the file are the file's heading, not the key's.
                if line == 1 { line = next.first }
                document.replace(first: line, last: line - 1, with: lines + [""])
            } else {
                document.replace(first: document.count + 1, last: document.count, with: lines)
            }
        } else {
            return data
        }

        // Every other key must hold exactly what it held before.
        let after = try compose(document)
        func others(_ mapping: Node.Mapping?) -> [String: Node] {
            var result: [String: Node] = [:]
            for (name, value) in mapping ?? [:] {
                if let name = name.string, name != key { result[name] = value }
            }
            return result
        }
        guard others(before) == others(after) else {
            throw .verificationFailed("The change would have altered other settings. The file was left as it is.")
        }
        return document.data
    }
}
