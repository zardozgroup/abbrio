public import Foundation
public import SnippetModel

/// The folders Espanso reports with `espanso path`.
public struct EnginePaths: Hashable, Sendable {
    public var config: URL
    public var packages: URL?
    public var runtime: URL?

    public init(config: URL, packages: URL? = nil, runtime: URL? = nil) {
        self.config = config
        self.packages = packages
        self.runtime = runtime
    }

    /// Reads the `Config:`, `Packages:` and `Runtime:` lines.
    public init?(parsing output: String) {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { values[key] = value }
        }
        guard let config = values["config"] else { return nil }
        self.init(
            config: URL(fileURLWithPath: config, isDirectory: true),
            packages: values["packages"].map { URL(fileURLWithPath: $0, isDirectory: true) },
            runtime: values["runtime"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }
}

/// Runs `espanso` commands. Every call is a separate process with a timeout.
public struct EspansoClient: Sendable {
    public var executable: URL
    public var runner: any CommandRunner
    /// The environment for each command. Nil passes on the app's own.
    public var environment: [String: String]?
    public var timeout: TimeInterval

    public init(
        executable: URL,
        runner: any CommandRunner = ProcessRunner(),
        environment: [String: String]? = nil,
        timeout: TimeInterval = 5
    ) {
        self.executable = executable
        self.runner = runner
        self.environment = environment
        self.timeout = timeout
    }

    /// `espanso --version`
    public func version() async throws -> EngineVersion {
        let result = try await checked(["--version"])
        guard let version = EngineVersion(parsing: result.standardOutput) else {
            throw CommandError.unexpectedOutput(result.standardOutput)
        }
        return version
    }

    /// `espanso path`
    public func paths() async throws -> EnginePaths {
        let result = try await checked(["path"])
        guard let paths = EnginePaths(parsing: result.standardOutput) else {
            throw CommandError.unexpectedOutput(result.standardOutput)
        }
        return paths
    }

    /// `espanso status`. The command exits with 0 only while the service is running.
    public func isRunning() async -> Bool {
        let result = try? await runner.run(
            executable, arguments: ["status"], environment: environment, timeout: timeout
        )
        return result?.succeeded ?? false
    }

    /// `espanso match list --json`: every trigger Espanso reads from the config folder. The command parses
    /// the files itself, so it works without the service and fails when a file is not valid.
    public func loadedTriggers() async throws -> Set<String> {
        let result = try await checked(["match", "list", "--json"])
        struct Entry: Decodable {
            var triggers: [String]?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: Data(result.standardOutput.utf8)) else {
            throw CommandError.unexpectedOutput(String(result.standardOutput.prefix(200)))
        }
        return Set(entries.flatMap { $0.triggers ?? [] })
    }

    /// `espanso cmd disable`: stops expansions until they are resumed or the worker restarts.
    public func pause() async throws {
        _ = try await checked(["cmd", "disable"])
    }

    /// `espanso cmd enable`
    public func resume() async throws {
        _ = try await checked(["cmd", "enable"])
    }

    /// `espanso restart`
    public func restart() async throws {
        _ = try await checked(["restart"], timeout: max(timeout, 15))
    }

    /// `espanso service start`
    public func start() async throws {
        _ = try await checked(["service", "start"], timeout: max(timeout, 15))
    }

    /// `espanso stats --json`: how often each piece of typed text was expanded in a period.
    ///
    /// This is the fallback for when the statistics database can't be read. Espanso's `today` starts at
    /// midnight UTC, not local midnight.
    public func stats(period: StatisticsPeriod) async throws -> [UsageCount] {
        let result = try await checked(["stats", "--json", "--period", period.engineName, "--count", "100000"])
        return try Self.parseStats(result.standardOutput)
    }

    static func parseStats(_ output: String) throws -> [UsageCount] {
        struct Report: Decodable {
            struct Entry: Decodable {
                var trigger: String
                var count: Int
            }
            var top: [Entry]
        }
        guard let start = output.firstIndex(of: "{") else {
            throw CommandError.failed(exitCode: 0, message: "espanso stats printed no JSON.")
        }
        let report = try JSONDecoder().decode(Report.self, from: Data(output[start...].utf8))
        return report.top.map { UsageCount(typed: $0.trigger, count: $0.count) }
    }

    /// `espanso stats clear`: empties the statistics database.
    public func clearStats() async throws {
        _ = try await checked(["stats", "clear"])
    }

    /// `espanso stats prune --days <n>`: deletes records older than that many days.
    public func pruneStats(olderThanDays days: Int) async throws {
        _ = try await checked(["stats", "prune", "--days", String(days)])
    }

    /// `espanso match exec -t <trigger>`: expands the trigger in the frontmost app.
    ///
    /// Espanso first deletes as many characters before the cursor as the trigger is long, so the caller
    /// must have put the trigger there. The command returns before the text is inserted.
    public func expand(trigger: String) async throws {
        _ = try await checked(["match", "exec", "-t", trigger])
    }

    // MARK: Packages

    /// How long a package command may take: it downloads from the network.
    public static let packageTimeout: TimeInterval = 120

    /// True when a name can be passed to a package command: letters, digits, dots, hyphens and underscores,
    /// not starting with a hyphen, so it can't be read as an option.
    public static func isPackageName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first != "-", first != "." else { return false }
        return name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    /// True when text can be passed as a repository address: one word that is not an option.
    public static func isRepositoryURL(_ url: String) -> Bool {
        !url.isEmpty && !url.hasPrefix("-") && !url.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 0x20 }
    }

    /// The arguments of an install command. Nil when the name, version or address can't be passed safely.
    public static func installArguments(name: String, version: String? = nil, gitURL: String? = nil) -> [String]? {
        guard isPackageName(name) else { return nil }
        var arguments = ["install", name]
        if let version {
            guard isPackageName(version) else { return nil }
            arguments += ["--version", version]
        }
        if let gitURL {
            guard isRepositoryURL(gitURL) else { return nil }
            arguments += ["--git", gitURL, "--external"]
        }
        return arguments
    }

    /// `espanso install <name>`, with `--version <v>` for a given version, or `--git <url> --external` for a
    /// package from a git repository. Returns what Espanso printed.
    @discardableResult
    public func installPackage(_ name: String, version: String? = nil, gitURL: String? = nil) async throws -> String {
        guard let arguments = Self.installArguments(name: name, version: version, gitURL: gitURL) else {
            throw CommandError.failed(exitCode: 0, message: "That package name or address can't be used.")
        }
        return try await checked(arguments, timeout: Self.packageTimeout).standardOutput
    }

    /// `espanso package update <name>`
    @discardableResult
    public func updatePackage(_ name: String) async throws -> String {
        guard Self.isPackageName(name) else {
            throw CommandError.failed(exitCode: 0, message: "That package name can't be used.")
        }
        return try await checked(["package", "update", name], timeout: Self.packageTimeout).standardOutput
    }

    /// `espanso uninstall <name>`
    @discardableResult
    public func uninstallPackage(_ name: String) async throws -> String {
        guard Self.isPackageName(name) else {
            throw CommandError.failed(exitCode: 0, message: "That package name can't be used.")
        }
        return try await checked(["uninstall", name], timeout: max(timeout, 30)).standardOutput
    }

    private func checked(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> CommandResult {
        let result = try await runner.run(
            executable, arguments: arguments, environment: environment, timeout: timeout ?? self.timeout
        )
        guard result.succeeded else {
            let message = result.standardError.isEmpty ? result.standardOutput : result.standardError
            throw CommandError.failed(
                exitCode: result.exitCode,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }
}
