public import ConfigStore
public import EspansoCLI
public import Foundation
public import SnippetModel

/// The two sides of the Packages window.
public nonisolated enum PackagesTab: Hashable, Sendable {
    case installed
    case hub
}

/// How a Hub package stands on this Mac.
public nonisolated enum PackageStanding: Equatable, Sendable {
    case notInstalled
    case installed(version: String)
    /// Installed, and the Hub has a newer version.
    case updateAvailable(installed: String, latest: String)
}

/// A trigger in a package that one of the user's sets already uses.
public nonisolated struct PackageConflict: Identifiable, Equatable, Sendable {
    public var trigger: String
    public var setName: String
    public var id: String { trigger + "\n" + setName }
}

/// Packages: the Hub catalog, and installing, updating and removing through Espanso.
extension AppModel {
    /// Opens the Packages window on one of its tabs.
    public func showPackages(_ tab: PackagesTab, askingForGitURL: Bool = false) {
        packagesTab = tab
        isAskingForGitInstall = askingForGitURL
        openWindow?("packages")
    }

    // MARK: Installed

    public var installedPackages: [SnippetSet] {
        sets(ofKind: .package)
    }

    /// The folder name of an installed package, which is the name Espanso knows it by.
    public nonisolated static func packageName(ofSet id: String) -> String {
        id.hasPrefix("packages/") ? String(id.dropFirst("packages/".count)) : id
    }

    public func installedPackage(named name: String) -> SnippetSet? {
        installedPackages.first { Self.packageName(ofSet: $0.id) == name }
    }

    public func standing(ofPackageNamed name: String) -> PackageStanding {
        guard let installed = installedPackage(named: name) else { return .notInstalled }
        let version = installed.packageVersion ?? ""
        if let latest = packageCenter.index.latest(name)?.version, PackageVersion.isNewer(latest, than: version) {
            return .updateAvailable(installed: version, latest: latest)
        }
        return .installed(version: version)
    }

    /// True when the Hub lists a newer version of an installed package that came from the Hub.
    public func hasUpdate(_ set: SnippetSet) -> Bool {
        if case .git = set.packageInfo?.source { return false }
        if case .updateAvailable = standing(ofPackageNamed: Self.packageName(ofSet: set.id)) { return true }
        return false
    }

    // MARK: Catalog

    /// Shows the cached catalog and fetches a new one when it is missing, older than a day, or asked for.
    public func loadCatalog(force: Bool = false) async {
        packageCenter.loadCache()
        guard force || packageCenter.needsRefresh else { return }
        await packageCenter.refresh()
    }

    // MARK: Commands

    public func installPackage(_ name: String, version: String? = nil) async {
        await runPackageCommand(name, activity: "Installing\u{2026}") { try await $0.installPackage(name, version: version) }
    }

    /// Installs a package from a git repository. Returns true when Espanso reports success.
    @discardableResult
    public func installPackage(_ name: String, fromGit url: String) async -> Bool {
        await runPackageCommand(name, activity: "Installing\u{2026}") { try await $0.installPackage(name, gitURL: url) }
    }

    public func updatePackage(_ name: String) async {
        await runPackageCommand(name, activity: "Updating\u{2026}") { try await $0.updatePackage(name) }
    }

    public func uninstallPackage(_ name: String) async {
        await runPackageCommand(name, activity: "Uninstalling\u{2026}") { try await $0.uninstallPackage(name) }
    }

    @discardableResult
    private func runPackageCommand(
        _ name: String, activity: String, _ command: (EspansoClient) async throws -> String
    ) async -> Bool {
        guard packageCenter.activity[name] == nil else { return false }
        guard let client else {
            packageCenter.failures[name] = "Espanso wasn't found on this Mac."
            return false
        }
        commitDraft()
        packageCenter.failures[name] = nil
        packageCenter.activity[name] = activity
        defer {
            packageCenter.activity[name] = nil
            // The package folder changed, whatever the command said.
            reloadNow()
        }
        do {
            _ = try await command(client)
            return true
        } catch let error as CommandError {
            packageCenter.failures[name] = Self.message(for: error)
        } catch {
            packageCenter.failures[name] = error.localizedDescription
        }
        return false
    }

    private nonisolated static func message(for error: CommandError) -> String {
        switch error {
        case .failed(_, let message): return message.isEmpty ? "Espanso reported an error without saying more." : message
        case .timedOut(let seconds): return "Espanso did not finish within \(Int(seconds)) seconds."
        case .launchFailed(let reason): return "Espanso could not be started: \(reason)"
        case .outputTooLarge: return "Espanso printed more than expected."
        case .unexpectedOutput(let output): return output
        }
    }

    // MARK: Preview

    /// Downloads a package's archive, checks and unpacks it, and reads its README and items for the sheet.
    public func loadPreview(of package: HubPackage) async {
        switch packageCenter.previews[package.id] {
        case .loading, .loaded: return
        default: break
        }
        packageCenter.previews[package.id] = .loading
        do {
            let data = try await packageCenter.verifiedArchive(of: package)
            let contents = try await Self.readArchive(data, runner: runner)
            packageCenter.previews[package.id] = .loaded(contents)
        } catch {
            packageCenter.previews[package.id] = .failed(error.localizedDescription)
        }
    }

    /// How long reading one archive may take in all.
    nonisolated static let archiveDeadline: Duration = .seconds(30)

    /// Reads a package archive's README and items without unpacking it: the listing is checked first, then
    /// only the README and the match files are read, one at a time and within size limits.
    @concurrent
    nonisolated static func readArchive(_ data: Data, runner: any CommandRunner) async throws -> PackageContents {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: archiveDeadline)
        func remaining() throws -> TimeInterval {
            let left = clock.now.duration(to: deadline)
            guard left > .zero else { throw HubError.message("Reading the archive took too long.") }
            return Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
        }

        // The archive goes into a folder of its own, created for this read and removed after it.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbrio-package-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("package.zip")
        try ConfigWriter.createExclusively(archive, with: data, permissions: 0o600)

        let listing = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/zipinfo"), arguments: ["-T", "-s", archive.path],
            environment: nil, timeout: min(try remaining(), 30)
        )
        guard listing.succeeded else { throw HubError.message("The archive is damaged or not a zip file.") }
        let entries = try PackageArchive.entries(fromListing: listing.standardOutput)
        let selection = PackageArchive.entriesToRead(entries)

        var texts: [(name: String, text: String?)] = []
        var total = 0
        for entry in selection.read {
            let result = try await runner.run(
                URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", "-q", archive.path, entry.name],
                environment: nil, timeout: min(try remaining(), 30)
            )
            guard result.succeeded else { throw HubError.message("The archive is damaged.") }
            let size = result.standardOutput.utf8.count
            total += size
            // The listing's sizes are only what the archive claims; the bytes actually read are checked too.
            guard size <= PackageArchive.fileLimit, Int64(total) <= PackageArchive.totalLimit else {
                throw HubError.message("The archive holds more than it says.")
            }
            texts.append((entry.name, result.standardOutput))
        }
        return PackageFiles.contents(entries: texts, unreadable: selection.skipped)
    }

    /// Lets the sheet ask for the preview again after a failure.
    public func forgetPreview(of package: HubPackage) {
        if case .failed = packageCenter.previews[package.id] { packageCenter.previews[package.id] = nil }
    }

    /// Triggers of a package that one of the user's own sets, or another package, already uses.
    public func conflicts(ofTriggers triggers: [String], inPackageNamed name: String) -> [PackageConflict] {
        var owners: [String: String] = [:]
        for set in sets where Self.packageName(ofSet: set.id) != name || set.kind != .package {
            for snippet in set.snippets {
                for trigger in snippet.triggers where owners[trigger] == nil {
                    owners[trigger] = set.name
                }
            }
        }
        var seen: Set<String> = []
        return triggers.compactMap { trigger in
            guard let owner = owners[trigger], seen.insert(trigger).inserted else { return nil }
            return PackageConflict(trigger: trigger, setName: owner)
        }
    }

    // MARK: Copy to My Sets

    /// The sets a package's items can be copied into.
    public var copyTargets: [SnippetSet] {
        sets.filter { !$0.isLocked && !$0.isBroken }
    }

    /// Copies package items into one of the user's sets. The package stays as it is.
    @discardableResult
    public func copyToMySets(_ ids: [Snippet.ID], toSet id: String) -> Bool {
        moveItems(ids, toSet: id, copying: true)
    }

    /// Copies package items into a new set of the given name.
    @discardableResult
    public func copyToMySets(_ ids: [Snippet.ID], toNewSetNamed name: String) -> Bool {
        let before = Set(sets.map(\.id))
        guard createSet(named: name), let created = sets.first(where: { !before.contains($0.id) }) else { return false }
        return moveItems(ids, toSet: created.id, copying: true)
    }
}
