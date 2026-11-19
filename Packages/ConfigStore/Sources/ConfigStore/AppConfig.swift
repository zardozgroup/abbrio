public import Foundation
public import SnippetModel

/// Whether a config file's filters apply to an application.
public enum FilterMatch: Equatable, Sendable {
    case no
    case yes
    /// It can't be told: the file filters on the window title, or uses a pattern the app can't evaluate.
    case maybe
}

/// The filters Espanso uses to pick the config file for the frontmost application.
public enum AppFilter {
    private static let metaCharacters: Set<Character> = ["\\", ".", "+", "*", "?", "(", ")", "|", "[", "]", "{", "}", "^", "$"]

    /// A `filter_class` pattern that matches exactly one bundle identifier: `^com\.apple\.mail$`.
    public static func classPattern(forBundleID bundleID: String) -> String {
        var pattern = "^"
        for character in bundleID {
            if metaCharacters.contains(character) { pattern.append("\\") }
            pattern.append(character)
        }
        return pattern + "$"
    }

    /// The bundle identifier a pattern stands for, when the pattern matches exactly one.
    public static func bundleID(fromClassPattern pattern: String) -> String? {
        guard pattern.hasPrefix("^"), pattern.hasSuffix("$"), pattern.count > 2 else { return nil }
        var result = ""
        var isEscaped = false
        for character in pattern.dropFirst().dropLast() {
            if isEscaped {
                guard metaCharacters.contains(character) else { return nil }
                result.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if metaCharacters.contains(character) {
                return nil
            } else {
                result.append(character)
            }
        }
        return isEscaped || result.isEmpty ? nil : result
    }

    /// Tests a config file's filters against an application.
    ///
    /// - Parameter path: The path of the app bundle, when known.
    public static func match(_ file: ConfigFile, bundleID: String, path: String?) -> FilterMatch {
        guard file.hasFilter else { return .no }
        var result = FilterMatch.yes
        if let pattern = file.filterClass {
            switch search(pattern, in: bundleID) {
            case .no: return .no
            case .maybe: result = .maybe
            case .yes: break
            }
        }
        if let pattern = file.filterExec {
            guard let path else { return .maybe }
            switch search(pattern, in: path) {
            case .no: return .no
            case .maybe: result = .maybe
            case .yes: break
            }
        }
        // The window title changes with every document, so a title filter can't be decided here.
        if file.filterTitle != nil { result = .maybe }
        return result
    }

    private static func search(_ pattern: String, in text: String) -> FilterMatch {
        // Espanso uses another regex engine. The two agree on ordinary patterns; one this engine refuses
        // may still be valid there.
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return .maybe }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil ? .yes : .no
    }
}

/// Works out which match files Espanso loads for a config file.
public struct ConfigEvaluator: Sendable {
    /// `config/default.yml`, which every other config file extends.
    public var base: ConfigFile?

    public init(base: ConfigFile?) {
        self.base = base
    }

    public init(configFiles: [ConfigFile]) {
        base = configFiles.first(where: \.isDefault)
    }

    /// The pattern Espanso loads by default: every file under `match/` whose name has no leading underscore.
    static let standardIncludes = ["../match/**/[!_]*.yml"]

    /// True when the match file at `path` (relative to the config folder, such as `match/work.yml`) is
    /// loaded for windows that `file` applies to. Pass nil for all other applications.
    public func isLoaded(_ path: String, in file: ConfigFile?) -> Bool {
        isLoaded(
            path, in: file,
            extraIncludes: extraIncludes(for: file), extraExcludes: extraExcludes(for: file)
        )
    }

    /// The `extra_includes` list in force for a file. Each list key is taken from the application's file
    /// when the file has it, and from `default.yml` otherwise: a list in an application's file replaces
    /// the same list in `default.yml`, it does not add to it.
    public func extraIncludes(for file: ConfigFile?) -> [String] {
        if let file, file.keys.contains("extra_includes") { return file.extraIncludes }
        return base?.extraIncludes ?? []
    }

    /// The `extra_excludes` list in force for a file. See `extraIncludes(for:)`.
    public func extraExcludes(for file: ConfigFile?) -> [String] {
        if let file, file.keys.contains("extra_excludes") { return file.extraExcludes }
        return base?.extraExcludes ?? []
    }

    /// As `isLoaded(_:in:)`, with the two extra lists given instead of read from the files.
    func isLoaded(_ path: String, in file: ConfigFile?, extraIncludes: [String], extraExcludes: [String]) -> Bool {
        let includes = file?.includes ?? base?.includes ?? Self.standardIncludes
        let excludes = file?.excludes ?? base?.excludes ?? []
        let target = Self.normalized("../" + path)
        func matches(_ patterns: [String]) -> Bool {
            patterns.contains { Self.glob($0, matches: target) }
        }
        return (matches(includes) || matches(extraIncludes)) && !(matches(excludes) || matches(extraExcludes))
    }

    /// True when expansion is switched off for the file's windows.
    public func isDisabled(in file: ConfigFile?) -> Bool {
        (file?.enable ?? base?.enable) == false
    }

    /// Resolves `.` and `..` in a path written relative to `config/`. The result starts at the config
    /// folder, so `../match/a.yml` becomes `match/a.yml`.
    static func normalized(_ entry: String) -> String {
        var parts = ["config"]
        for part in entry.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return parts.joined(separator: "/")
    }

    /// Glob matching with `*`, `?`, `**` and character classes, as used in include and exclude lists.
    static func glob(_ pattern: String, matches target: String) -> Bool {
        let normalizedPattern = normalized(pattern)
        var regex = "^"
        var index = normalizedPattern.startIndex
        let end = normalizedPattern.endIndex
        while index < end {
            let character = normalizedPattern[index]
            let next = normalizedPattern.index(after: index)
            switch character {
            case "*":
                if next < end, normalizedPattern[next] == "*" {
                    let afterStars = normalizedPattern.index(after: next)
                    if afterStars < end, normalizedPattern[afterStars] == "/" {
                        regex += "(?:.*/)?"
                        index = normalizedPattern.index(after: afterStars)
                    } else {
                        regex += ".*"
                        index = afterStars
                    }
                    continue
                }
                regex += "[^/]*"
            case "?":
                regex += "[^/]"
            case "[":
                guard let close = normalizedPattern[next...].firstIndex(of: "]") else {
                    regex += "\\["
                    break
                }
                var body = String(normalizedPattern[next..<close])
                if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                regex += "[" + body.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                index = normalizedPattern.index(after: close)
                continue
            default:
                regex += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = next
        }
        regex += "$"
        guard let expression = try? NSRegularExpression(pattern: regex) else { return false }
        return expression.firstMatch(in: target, range: NSRange(target.startIndex..., in: target)) != nil
    }
}

/// Something that can be switched on or off for one application.
public enum AppSwitch: Hashable, Sendable {
    /// A set, by its path relative to `match/`.
    case set(String)
    /// An installed package, by its folder name.
    case package(String)

    /// The entry written to `extra_includes` or `extra_excludes`.
    var entry: String {
        switch self {
        case .set(let id): return "../match/" + id
        case .package(let name): return "../match/packages/\(name)/*"
        }
    }

    /// A file that stands for the whole thing when asking whether it is loaded.
    var samplePath: String {
        switch self {
        case .set(let id): return "match/" + id
        case .package(let name): return "match/packages/\(name)/package.yml"
        }
    }
}

/// Writes the config files that switch sets on and off per application.
public struct AppConfigEditor: Sendable {
    public var writer: ConfigWriter
    public var discard: @Sendable (URL) throws -> Void

    public init(
        writer: ConfigWriter,
        discard: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.writer = writer
        self.discard = discard
    }

    /// Creates `config/<bundle id>.yml` holding only the filter. Returns its path relative to the config
    /// folder.
    ///
    /// - Parameter allOff: Also switches expansion off in the application (`enable: false`).
    public func addApp(bundleID: String, allOff: Bool = false) throws(EditError) -> String {
        let safe = String(bundleID.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "-" })
        var path = "config/\(safe).yml"
        var number = 2
        while FileManager.default.fileExists(atPath: writer.url(for: path).path) {
            path = "config/\(safe)-\(number).yml"
            number += 1
        }
        let text = "# \(path), written by Abbrio\n"
            + "filter_class: " + ConfigFileEditor.quoted(AppFilter.classPattern(forBundleID: bundleID)) + "\n"
            + (allOff ? "enable: false\n" : "")
        do {
            try FileManager.default.createDirectory(
                at: writer.url(for: "config"), withIntermediateDirectories: true
            )
        } catch {
            throw .fileSystem("The config folder could not be created: \(error.localizedDescription)")
        }
        try writer.write(Data(text.utf8), to: path, replacing: nil)
        return path
    }

    /// Moves an application's config file to the Trash.
    public func removeApp(configPath path: String) throws(EditError) {
        do {
            try discard(writer.url(for: path))
        } catch {
            throw .fileSystem("\(path) could not be moved to the Trash: \(error.localizedDescription)")
        }
    }

    /// Switches a set or package on or off for the windows a config file applies to.
    ///
    /// The file gains an `extra_includes` or `extra_excludes` entry only when the choice differs from all
    /// other applications; an entry that is no longer needed is removed.
    ///
    /// A list in an application's file replaces the same list in `default.yml`. So a list that is written
    /// here for the first time starts from the entries of `default.yml`, and the other sets stay as they
    /// were in this application.
    public func setLoaded(_ isOn: Bool, _ item: AppSwitch, in path: String, base: ConfigFile?) throws(EditError) {
        let current = try writer.read(path)
        let file = parse(current, path: path)
        let evaluator = ConfigEvaluator(base: base)
        let target = ConfigEvaluator.normalized(item.entry)
        func without(_ entries: [String]) -> [String] {
            entries.filter { ConfigEvaluator.normalized($0) != target }
        }
        func isLoaded(_ includes: [String], _ excludes: [String]) -> Bool {
            evaluator.isLoaded(item.samplePath, in: file, extraIncludes: includes, extraExcludes: excludes)
        }

        let oldIncludes = evaluator.extraIncludes(for: file)
        let oldExcludes = evaluator.extraExcludes(for: file)
        var includes = without(oldIncludes)
        var excludes = without(oldExcludes)
        if isLoaded(includes, excludes) != isOn {
            if isOn {
                includes.append(item.entry)
            } else {
                excludes.append(item.entry)
            }
        }
        guard isLoaded(includes, excludes) == isOn else {
            throw .notEditable("Another line in \(path) or in config/default.yml decides this. Edit the file by hand.")
        }

        // A list equal to the one in default.yml needs no key here; any other list is written out, an
        // empty one included.
        var updated = current
        if includes != oldIncludes {
            let inherited = includes == (base?.extraIncludes ?? [])
            updated = try ConfigFileEditor.setList("extra_includes", inherited ? nil : includes, in: updated)
        }
        if excludes != oldExcludes {
            let inherited = excludes == (base?.extraExcludes ?? [])
            updated = try ConfigFileEditor.setList("extra_excludes", inherited ? nil : excludes, in: updated)
        }
        let result = parse(updated, path: path)
        guard result.problem == nil, evaluator.isLoaded(item.samplePath, in: result) == isOn,
              evaluator.extraIncludes(for: result) == includes, evaluator.extraExcludes(for: result) == excludes
        else {
            throw .verificationFailed("The change could not be written safely. The file was left as it is.")
        }
        try writer.write(updated, to: path, replacing: current)
    }

    /// Switches expansion off (`enable: false`) or back on for the windows a config file applies to. The
    /// per-set choices in the file stay as they are.
    public func setAllOff(_ isOff: Bool, in path: String) throws(EditError) {
        try setOption("enable", isOff ? .bool(false) : nil, in: path)
    }

    /// Sets or, with nil, removes one option, so that the value from `default.yml` applies again.
    public func setOption(_ key: String, _ value: ConfigValue?, in path: String) throws(EditError) {
        let current = try writer.read(path)
        let updated = try ConfigFileEditor.setValue(key, value, in: current)
        guard parse(updated, path: path).problem == nil else {
            throw .verificationFailed("The change could not be written safely. The file was left as it is.")
        }
        try writer.write(updated, to: path, replacing: current)
    }

    /// Sets one option to a list or, with nil, removes it.
    public func setList(_ key: String, _ items: [String]?, in path: String) throws(EditError) {
        try change(path) { data throws(EditError) in try ConfigFileEditor.setList(key, items, in: data) }
    }

    /// Switches statistics on or off, or with nil removes the setting.
    public func setStatsEnabled(_ isEnabled: Bool?, in path: String) throws(EditError) {
        try change(path) { data throws(EditError) in try ConfigFileEditor.setStatsEnabled(isEnabled, in: data) }
    }

    private func change(_ path: String, _ edit: (Data) throws(EditError) -> Data) throws(EditError) {
        let current = try writer.read(path)
        let updated = try edit(current)
        guard updated != current else { return }
        guard parse(updated, path: path).problem == nil else {
            throw .verificationFailed("The change could not be written safely. The file was left as it is.")
        }
        try writer.write(updated, to: path, replacing: current)
    }

    private func parse(_ data: Data, path: String) -> ConfigFile {
        var text = String(decoding: data, as: UTF8.self)
        if text.unicodeScalars.first == "\u{FEFF}" { text = String(text.dropFirst()) }
        return ConfigFileParser.parse(text, path: path, url: writer.url(for: path))
    }
}
