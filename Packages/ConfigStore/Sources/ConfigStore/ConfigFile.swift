public import Foundation
public import SnippetModel
import Yams

/// One file in `config/`: `default.yml`, or the settings for one application.
public struct ConfigFile: Identifiable, Hashable, Sendable {
    /// Path relative to the config folder, such as `config/default.yml`.
    public var path: String
    public var url: URL
    public var filterTitle: String?
    public var filterClass: String?
    public var filterExec: String?
    public var includes: [String]?
    public var excludes: [String]?
    public var extraIncludes: [String] = []
    public var extraExcludes: [String] = []
    /// The value of `enable:`, when the file sets it.
    public var enable: Bool?
    /// Every top-level key in the file, in file order.
    public var keys: [String] = []
    /// The top-level keys that hold a single value, as text.
    public var values: [String: String] = [:]
    /// The top-level keys that hold a list of single values.
    public var lists: [String: [String]] = [:]
    /// The value of `enabled:` under `stats:`, when the file sets it.
    public var statsEnabled: Bool?
    /// Set when the file could not be parsed.
    public var problem: SetProblem?

    public var id: String { path }

    public var isDefault: Bool {
        (path as NSString).lastPathComponent.lowercased().hasPrefix("default.")
    }

    /// True when the file applies only to windows that match a filter.
    public var hasFilter: Bool {
        filterTitle != nil || filterClass != nil || filterExec != nil
    }

    public init(path: String, url: URL) {
        self.path = path
        self.url = url
    }
}

public enum ConfigFileParser {
    public static func parse(_ text: String, path: String, url: URL) -> ConfigFile {
        var file = ConfigFile(path: path, url: url)
        let root: Node?
        do {
            root = try Yams.compose(yaml: text)
        } catch let error as YamlError {
            let failure = MatchFileError(yamlError: error)
            file.problem = SetProblem(severity: .unreadable, file: path, line: failure.line, message: failure.message)
            return file
        } catch {
            file.problem = SetProblem(severity: .unreadable, file: path, message: error.localizedDescription)
            return file
        }

        guard let root else { return file }
        guard case .mapping(let mapping) = root else {
            if case .scalar(let scalar) = root, scalar.string.isEmpty { return file }
            file.problem = SetProblem(
                severity: .unreadable, file: path, line: root.mark?.line,
                message: "The file must contain settings as \"key: value\" lines."
            )
            return file
        }

        for (key, value) in mapping {
            guard let name = key.string else { continue }
            file.keys.append(name)
            if case .scalar(let scalar) = value { file.values[name] = scalar.string }
            if case .sequence(let sequence) = value, sequence.allSatisfy({ $0.scalar != nil }) {
                file.lists[name] = sequence.compactMap(\.string)
            }
            if name == "stats", case .mapping(let stats) = value {
                file.statsEnabled = stats.first { $0.key.string == "enabled" }?.value.bool
            }
            switch name {
            case "filter_title": file.filterTitle = value.string
            case "filter_class": file.filterClass = value.string
            case "filter_exec": file.filterExec = value.string
            case "includes": file.includes = strings(value)
            case "excludes": file.excludes = strings(value)
            case "extra_includes": file.extraIncludes = strings(value)
            case "extra_excludes": file.extraExcludes = strings(value)
            case "enable": file.enable = value.bool
            default: break
            }
        }
        return file
    }

    private static func strings(_ node: Node) -> [String] {
        node.sequence?.compactMap(\.string) ?? []
    }
}
