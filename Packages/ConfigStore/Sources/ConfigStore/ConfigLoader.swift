public import Foundation
public import SnippetModel
import Yams

/// Everything read from a config folder at one moment.
public struct ConfigSnapshot: Sendable {
    public var root: URL
    /// Sets and packages, sorted by kind and then by name.
    public var sets: [SnippetSet]
    public var configFiles: [ConfigFile]
    /// The app's own notes about the folder.
    public var sidecar: Sidecar

    public init(root: URL, sets: [SnippetSet] = [], configFiles: [ConfigFile] = [], sidecar: Sidecar = Sidecar()) {
        self.root = root
        self.sets = sets
        self.configFiles = configFiles
        self.sidecar = sidecar
    }

    public func sets(ofKind kind: SnippetSet.Kind) -> [SnippetSet] {
        sets.filter { $0.kind == kind }
    }
}

/// Reads a config folder. It never writes.
public struct ConfigLoader: Sendable {
    public var root: URL
    /// Parsed match files from earlier loads. Nil parses every file every time.
    public var cache: MatchFileCache?

    public init(root: URL, cache: MatchFileCache? = nil) {
        self.root = root.standardizedFileURL
        self.cache = cache
    }

    public var matchDirectory: URL { root.appendingPathComponent("match", isDirectory: true) }
    public var configDirectory: URL { root.appendingPathComponent("config", isDirectory: true) }

    public func load() -> ConfigSnapshot {
        defer { cache?.endLoad() }
        let sidecar = SidecarStore(root: root).load()
        var sets: [SnippetSet] = []
        var packages: [String: SnippetSet] = [:]

        for relative in yamlFiles(under: matchDirectory, recursive: true) {
            let components = relative.split(separator: "/").map(String.init)
            let fileName = components.last ?? relative
            let url = matchDirectory.appendingPathComponent(relative)
            let path = "match/" + relative

            if components.count >= 3, components[0] == "packages" {
                // match/packages/<name>/…: all of a package's files form one locked row.
                let name = components[1]
                let id = "packages/" + name
                var package = packages[id] ?? SnippetSet(id: id, name: name, kind: .package, isEnabled: true, files: [])
                if fileName.hasPrefix("_") {
                    if fileName.lowercased().hasPrefix("_manifest.") {
                        let source = package.packageInfo?.source
                        package.packageInfo = PackageFiles.manifest(at: url, folderName: name)
                        if let source { package.packageInfo?.source = source }
                        package.packageVersion = package.packageInfo.flatMap { $0.version.isEmpty ? nil : $0.version }
                    } else if fileName.lowercased().hasPrefix("_pkgsource.") {
                        let source = PackageFiles.source(at: url)
                        if package.packageInfo == nil { package.packageInfo = PackageInfo(name: name) }
                        package.packageInfo?.source = source
                    }
                } else {
                    package.files.append(SetFile(path: path, url: url))
                    let parsed = parseMatchFile(at: url, path: path)
                    package.snippets.append(contentsOf: parsed.snippets)
                    package.problems.append(contentsOf: parsed.problems)
                }
                packages[id] = package
                continue
            }

            let parsed = parseMatchFile(at: url, path: path)
            let info = sidecar.info(for: relative)
            // An empty file is what the app's notes say it was made for.
            let isRegexSet = parsed.snippets.isEmpty
                ? info.holdsRegularExpressions == true
                : parsed.snippets.allSatisfy(\.isRegex)
            var set = SnippetSet(
                id: relative,
                name: info.name ?? SnippetSet.displayName(forFileName: fileName),
                kind: isRegexSet ? .regularExpressions : .abbreviations,
                isEnabled: !fileName.hasPrefix("_"),
                files: [SetFile(path: path, url: url)],
                snippets: parsed.snippets,
                problems: parsed.problems
            )
            set.info = info
            set.globalVariables = parsed.globalVariables
            set.globalVariableList = parsed.globalVariableList
            set.globalVariablesAreEditable = parsed.globalVariablesAreComplete
            sets.append(set)
        }

        sets.append(contentsOf: packages.values)
        sets.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return order(of: lhs.kind) < order(of: rhs.kind) }
            // Sets the user arranged come first, in that order; the rest follow by name.
            switch (lhs.info.order, rhs.info.order) {
            case let (left?, right?) where left != right: return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id < rhs.id
        }

        let configFiles = yamlFiles(under: configDirectory, recursive: false).map { relative -> ConfigFile in
            let url = configDirectory.appendingPathComponent(relative)
            let path = "config/" + relative
            do {
                return ConfigFileParser.parse(try readText(at: url), path: path, url: url)
            } catch {
                var file = ConfigFile(path: path, url: url)
                file.problem = SetProblem(severity: .unreadable, file: path, message: error.localizedDescription)
                return file
            }
        }

        return ConfigSnapshot(root: root, sets: sets, configFiles: configFiles, sidecar: sidecar)
    }

    private func order(of kind: SnippetSet.Kind) -> Int {
        switch kind {
        case .abbreviations: return 0
        case .regularExpressions: return 1
        case .package: return 2
        }
    }

    private func parseMatchFile(at url: URL, path: String) -> ParsedMatchFile {
        var failed = ParsedMatchFile()
        do {
            let data = try readData(at: url)
            let key = url.path + "\n" + path
            if let parsed = cache?.parsed(for: key, data: data) { return parsed }
            let parsed = try MatchFileParser.parse(try text(from: data), path: path)
            cache?.store(parsed, for: key, data: data)
            return parsed
        } catch let error as MatchFileError {
            failed.problems = [SetProblem(severity: .unreadable, file: path, line: error.line, message: error.message)]
        } catch {
            failed.problems = [SetProblem(severity: .unreadable, file: path, message: error.localizedDescription)]
        }
        return failed
    }

    /// The largest file read as YAML. Match files are a few hundred kilobytes at most.
    static let fileSizeLimit = 16 * 1024 * 1024

    private func readText(at url: URL) throws -> String {
        try text(from: readData(at: url))
    }

    private func readData(at url: URL) throws -> Data {
        // Only regular files of a sensible size: a pipe would never finish and a huge file would fill memory.
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw MatchFileError(line: nil, message: "This is not a regular file.")
        }
        guard (values.fileSize ?? 0) <= Self.fileSizeLimit else {
            throw MatchFileError(line: nil, message: "The file is larger than 16 MB, so Abbrio does not read it.")
        }
        return try Data(contentsOf: url)
    }

    private func text(from data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        // A byte order mark is not part of the YAML.
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Paths of the `.yml` and `.yaml` files under a folder, relative to it, sorted. Hidden files are skipped.
    private func yamlFiles(under directory: URL, recursive: Bool) -> [String] {
        let manager = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        // The folder may be a symlink into a synced location.
        let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = manager.enumerator(
            at: resolved, includingPropertiesForKeys: [.isRegularFileKey], options: options
        ) else { return [] }

        let base = resolved.path
        var result: [String] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "yml" || ext == "yaml" else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base + "/") else { continue }
            result.append(String(full.dropFirst(base.count + 1)))
        }
        return result.sorted()
    }
}
