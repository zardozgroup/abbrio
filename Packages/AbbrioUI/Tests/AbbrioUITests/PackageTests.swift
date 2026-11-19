import XCTest
import CryptoKit
import ConfigStore
import EspansoCLI
import SnippetModel
@testable import AbbrioUI

/// Stands in for `espanso`: answers `--version` and `path`, records package commands and changes the
/// package folder the way Espanso would. Everything else is run for real, which here is only `ditto`.
private final class FakeEngine: CommandRunner, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var commands: [[String]] { lock.withLock { recorded } }

    init(root: URL) {
        self.root = root
    }

    func run(
        _ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> CommandResult {
        guard executable.lastPathComponent == "espanso" else {
            return try await ProcessRunner().run(executable, arguments: arguments, environment: environment, timeout: timeout)
        }
        switch arguments.first {
        case "--version": return CommandResult(exitCode: 0, standardOutput: "espanso 2.4.1\n")
        case "path": return CommandResult(exitCode: 0, standardOutput: "Config: \(root.path)\n")
        case "status": return CommandResult(exitCode: 1)
        default: break
        }
        lock.withLock { recorded.append(arguments) }
        let packages = root.appendingPathComponent("match/packages")
        if arguments.first == "install", arguments.count > 1 {
            if arguments[1] == "broken" { return CommandResult(exitCode: 1, standardOutput: "unable to find package: broken\n") }
            let folder = packages.appendingPathComponent(arguments[1])
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "matches:\n  - trigger: \":d6\"\n    replace: six\n".write(to: folder.appendingPathComponent("package.yml"), atomically: true, encoding: .utf8)
            try "name: \(arguments[1])\nversion: 0.1.0\n".write(to: folder.appendingPathComponent("_manifest.yml"), atomically: true, encoding: .utf8)
        } else if arguments.first == "uninstall", arguments.count > 1 {
            try FileManager.default.removeItem(at: packages.appendingPathComponent(arguments[1]))
        }
        return CommandResult(exitCode: 0, standardOutput: "done\n")
    }
}

/// Serves files from a table instead of the network.
private final class FakeHub: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var requested: [String] = []
    var requests: [String] { lock.withLock { requested } }

    func set(_ url: String, _ data: Data?) { lock.withLock { files[url] = data } }

    func fetch(_ url: URL) async throws -> Data {
        try lock.withLock {
            requested.append(url.absoluteString)
            guard let data = files[url.absoluteString] else { throw HubError.message("offline") }
            return data
        }
    }
}

@MainActor
final class PackageTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var cache: URL!
    private var hub: FakeHub!
    private var engine: FakeEngine!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    private let indexJSON = """
    {"last_update": 1700000000, "packages": [
      {"name": "demo", "author": "Ann", "description": "Faces", "title": "Demo", "version": "0.3.0", "tags": ["fun"],
       "archive_url": "https://github.com/espanso/hub/releases/latest/download/demo-0.3.0.zip", "archive_sha256_url": "https://github.com/espanso/hub/releases/latest/download/demo-0.3.0-sha256.txt"},
      {"name": "dice", "author": "Bo", "description": "Rolls dice", "title": "Dice", "version": "0.1.0", "tags": ["fun", "utility"],
       "archive_url": "https://github.com/espanso/hub/releases/latest/download/dice-0.1.0.zip", "archive_sha256_url": "https://github.com/espanso/hub/releases/latest/download/dice-0.1.0-sha256.txt"}
    ]}
    """

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("abbrio-packages-" + UUID().uuidString)
        root = base.appendingPathComponent("config-folder")
        cache = base.appendingPathComponent("cache")
        for folder in ["match/packages/demo", "config"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try write("config/default.yml", "toggle_key: OFF\n")
        try write("match/work.yml", "matches:\n  - trigger: \";sig\"\n    replace: Regards\n")
        try write("match/packages/demo/package.yml", "matches:\n  - trigger: \":smile\"\n    replace: \"🙂\"\n  - trigger: \":wave\"\n    replace: \"👋\"\n")
        try write("match/packages/demo/_manifest.yml", "name: demo\ntitle: Demo\nversion: 0.2.0\nauthor: Ann\n")
        try write("match/packages/demo/_pkgsource.yml", "hub\n")
        hub = FakeHub()
        engine = FakeEngine(root: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func makeModel() async -> AppModel {
        let hub = hub!
        let clock = now
        let model = AppModel(
            environment: AppEnvironment(configFolderOverride: root, fallbackConfigFolders: []),
            runner: engine,
            locator: EspansoLocator(override: URL(fileURLWithPath: "/nonexistent/espanso"), searchPath: "", isExecutable: { _ in true }),
            hub: HubService(fetch: { try await hub.fetch($0) }, cacheFolder: cache, now: { clock })
        )
        model.autosaveDelay = .seconds(3600)
        await model.load()
        return model
    }

    // MARK: Catalog

    func testTheCatalogIsFetchedCachedAndReusedForADay() async throws {
        hub.set(HubService.indexURL.absoluteString, Data(indexJSON.utf8))
        hub.set(FeaturedPackages.source.absoluteString, Data("export const featuredPackages: string[] = [\"dice\"];".utf8))
        let model = await makeModel()
        await model.loadCatalog()
        XCTAssertEqual(model.packageCenter.index.packages.map(\.name), ["demo", "dice"])
        XCTAssertEqual(model.packageCenter.featured, ["dice"])
        XCTAssertEqual(model.packageCenter.catalogDate, now)
        XCTAssertNil(model.packageCenter.catalogError)
        XCTAssertEqual(hub.requests.count, 2)

        // A second model reads the copy on disk and does not ask again within a day.
        let second = await makeModel()
        await second.loadCatalog()
        XCTAssertEqual(second.packageCenter.index.packages.count, 2)
        XCTAssertEqual(second.packageCenter.featured, ["dice"])
        XCTAssertEqual(hub.requests.count, 2)

        // Asking for a refresh while offline keeps the copy and says why.
        hub.set(HubService.indexURL.absoluteString, nil)
        await second.loadCatalog(force: true)
        XCTAssertEqual(second.packageCenter.index.packages.count, 2)
        XCTAssertNotNil(second.packageCenter.catalogError)
    }

    func testACatalogOfAnotherShapeIsNotUsedAndTheShippedFeaturedListStays() async {
        hub.set(HubService.indexURL.absoluteString, Data("{\"packages\": \"none\"}".utf8))
        let model = await makeModel()
        await model.loadCatalog()
        XCTAssertTrue(model.packageCenter.index.entries.isEmpty)
        XCTAssertNotNil(model.packageCenter.catalogError)
        XCTAssertEqual(model.packageCenter.featured, Set(FeaturedPackages.shipped))

        hub.set(HubService.indexURL.absoluteString, Data(indexJSON.utf8))
        hub.set(FeaturedPackages.source.absoluteString, Data("export const featuredPackages = compute();".utf8))
        await model.loadCatalog(force: true)
        XCTAssertEqual(model.packageCenter.index.packages.count, 2)
        XCTAssertEqual(model.packageCenter.featured, Set(FeaturedPackages.shipped))
    }

    // MARK: Installed packages and commands

    func testInstalledPackagesShowTheirManifestAndWhetherTheHubHasANewerVersion() async throws {
        hub.set(HubService.indexURL.absoluteString, Data(indexJSON.utf8))
        let model = await makeModel()
        let demo = try XCTUnwrap(model.installedPackage(named: "demo"))
        XCTAssertEqual(demo.packageInfo?.title, "Demo")
        XCTAssertEqual(demo.packageInfo?.source, .hub)
        XCTAssertEqual(model.standing(ofPackageNamed: "demo"), .installed(version: "0.2.0"))
        await model.loadCatalog()
        XCTAssertEqual(model.standing(ofPackageNamed: "demo"), .updateAvailable(installed: "0.2.0", latest: "0.3.0"))
        XCTAssertTrue(model.hasUpdate(demo))
        XCTAssertEqual(model.standing(ofPackageNamed: "dice"), .notInstalled)
    }

    func testInstallUpdateAndUninstallRunEspansoAndRefreshTheList() async {
        let model = await makeModel()
        await model.installPackage("dice")
        XCTAssertNotNil(model.installedPackage(named: "dice"))
        XCTAssertNil(model.packageCenter.failures["dice"])
        XCTAssertTrue(model.packageCenter.activity.isEmpty)
        await model.installPackage("dice", version: "0.1.0")
        let installed = await model.installPackage("mine", fromGit: "https://example.invalid/me/mine")
        XCTAssertTrue(installed)
        await model.updatePackage("demo")
        await model.uninstallPackage("dice")
        XCTAssertNil(model.installedPackage(named: "dice"))
        XCTAssertEqual(engine.commands, [
            ["install", "dice"],
            ["install", "dice", "--version", "0.1.0"],
            ["install", "mine", "--git", "https://example.invalid/me/mine", "--external"],
            ["package", "update", "demo"],
            ["uninstall", "dice"],
        ])
    }

    func testAFailedCommandKeepsWhatEspansoPrintedAndABadNameIsNeverRun() async {
        let model = await makeModel()
        await model.installPackage("broken")
        XCTAssertEqual(model.packageCenter.failures["broken"], "unable to find package: broken")
        let installed = await model.installPackage("--force", fromGit: "https://example.invalid/x")
        XCTAssertFalse(installed)
        XCTAssertNotNil(model.packageCenter.failures["--force"])
        XCTAssertEqual(engine.commands, [["install", "broken"]])
    }

    // MARK: Preview

    private func makeArchive() throws -> Data {
        let folder = base.appendingPathComponent("archive/dice-0.1.0")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Dice\n\nRolls dice.\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "matches:\n  - trigger: \":d6\"\n    replace: six\n  - trigger: \";sig\"\n    replace: clash\n".write(to: folder.appendingPathComponent("package.yml"), atomically: true, encoding: .utf8)
        let zip = base.appendingPathComponent("dice.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", folder.deletingLastPathComponent().path, zip.path]
        try process.run()
        process.waitUntilExit()
        return try Data(contentsOf: zip)
    }

    /// Zips a folder with `/usr/bin/zip`, keeping links as links.
    private func zip(_ folder: URL, name: String) throws -> Data {
        let zip = base.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = folder
        process.arguments = ["-q", "-r", "-y", zip.path, "."]
        try process.run()
        process.waitUntilExit()
        return try Data(contentsOf: zip)
    }

    func testHostileArchivesAreRefusedWithoutUnpacking() async throws {
        let bombFolder = base.appendingPathComponent("bomb")
        try FileManager.default.createDirectory(at: bombFolder, withIntermediateDirectories: true)
        // Forty megabytes of zeros squeeze into a few kilobytes.
        FileManager.default.createFile(atPath: bombFolder.appendingPathComponent("package.yml").path, contents: nil)
        let handle = try FileHandle(forWritingTo: bombFolder.appendingPathComponent("package.yml"))
        try handle.truncate(atOffset: 40 * 1024 * 1024)
        try handle.close()
        let bomb = try zip(bombFolder, name: "bomb.zip")
        XCTAssertLessThan(bomb.count, 1024 * 1024)
        do {
            _ = try await AppModel.readArchive(bomb, runner: ProcessRunner())
            XCTFail("expected the archive to be refused")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The archive would unpack to more than 32 MB.")
        }

        let linkFolder = base.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linkFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkFolder.appendingPathComponent("package.yml"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        do {
            _ = try await AppModel.readArchive(try zip(linkFolder, name: "linked.zip"), runner: ProcessRunner())
            XCTFail("expected the archive to be refused")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The archive holds links.")
        }

        do {
            _ = try await AppModel.readArchive(Data("not a zip".utf8), runner: ProcessRunner())
            XCTFail("expected the archive to be refused")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The archive is damaged or not a zip file.")
        }
    }

    func testAnArchiveIsCheckedUnpackedAndReadForTheSheet() async throws {
        let archive = try makeArchive()
        let sum = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        hub.set(HubService.indexURL.absoluteString, Data(indexJSON.utf8))
        hub.set("https://github.com/espanso/hub/releases/latest/download/dice-0.1.0.zip", archive)
        hub.set("https://github.com/espanso/hub/releases/latest/download/dice-0.1.0-sha256.txt", Data((sum + "\n").utf8))
        let model = await makeModel()
        await model.loadCatalog()
        let dice = try XCTUnwrap(model.packageCenter.index.latest("dice"))
        await model.loadPreview(of: dice)
        guard case .loaded(let contents) = model.packageCenter.previews[dice.id] else {
            return XCTFail("expected the archive's contents, got \(String(describing: model.packageCenter.previews[dice.id]))")
        }
        XCTAssertEqual(contents.readme, "# Dice\n\nRolls dice.\n")
        XCTAssertEqual(contents.snippets.flatMap(\.triggers), [":d6", ";sig"])
        XCTAssertEqual(
            model.conflicts(ofTriggers: contents.snippets.flatMap(\.triggers), inPackageNamed: "dice"),
            [PackageConflict(trigger: ";sig", setName: "Work")]
        )
    }

    func testAnArchiveThatDoesNotMatchItsChecksumIsNotOpened() async throws {
        hub.set(HubService.indexURL.absoluteString, Data(indexJSON.utf8))
        hub.set("https://github.com/espanso/hub/releases/latest/download/dice-0.1.0.zip", try makeArchive())
        hub.set("https://github.com/espanso/hub/releases/latest/download/dice-0.1.0-sha256.txt", Data(String(repeating: "0", count: 64).utf8))
        let model = await makeModel()
        await model.loadCatalog()
        let dice = try XCTUnwrap(model.packageCenter.index.latest("dice"))
        await model.loadPreview(of: dice)
        XCTAssertEqual(model.packageCenter.previews[dice.id], .failed("The download does not match its checksum."))
    }

    func testAnArchiveOnAnotherHostIsNotFetched() async throws {
        let index = indexJSON.replacingOccurrences(
            of: "https://github.com/espanso/hub/releases/latest/download/dice-0.1.0.zip",
            with: "https://example.invalid/dice-0.1.0.zip"
        )
        hub.set(HubService.indexURL.absoluteString, Data(index.utf8))
        let model = await makeModel()
        await model.loadCatalog()
        let dice = try XCTUnwrap(model.packageCenter.index.latest("dice"))
        await model.loadPreview(of: dice)
        XCTAssertEqual(
            model.packageCenter.previews[dice.id],
            .failed("The catalog points this package at an address Abbrio doesn't fetch from.")
        )
        XCTAssertFalse(hub.requests.contains { $0.contains("example.invalid") })
    }

    // MARK: Downloads

    func testOnlyGitHubIsFetchedAndOnlyOverHTTPS() {
        XCTAssertTrue(HubService.isAllowed(HubService.indexURL))
        XCTAssertTrue(HubService.isAllowed(URL(string: "https://release-assets.githubusercontent.com/x/y.zip")))
        XCTAssertTrue(HubService.isAllowed(FeaturedPackages.source))
        XCTAssertFalse(HubService.isAllowed(URL(string: "http://github.com/espanso/hub")))
        XCTAssertFalse(HubService.isAllowed(URL(string: "https://github.com.example.invalid/x")))
        XCTAssertFalse(HubService.isAllowed(URL(string: "https://user:pass@github.com/x")))
        XCTAssertFalse(HubService.isAllowed(URL(string: "file:///etc/hosts")))
        XCTAssertFalse(HubService.isAllowed(nil))
    }

    func testADownloadStopsAtTheLimitWhateverItDeclares() async throws {
        func chunks(_ count: Int) -> AsyncStream<UInt8> {
            AsyncStream { continuation in
                for _ in 0..<count { continuation.yield(7) }
                continuation.finish()
            }
        }
        let small = try await HubService.collect(chunks(10), declaredLength: -1, limit: 10)
        XCTAssertEqual(small.count, 10)
        // No declared length, more bytes than allowed: stopped while receiving.
        do {
            _ = try await HubService.collect(chunks(11), declaredLength: -1, limit: 10)
            XCTFail("expected the download to be refused")
        } catch {}
        // A declared length that understates what arrives is not trusted.
        do {
            _ = try await HubService.collect(chunks(50), declaredLength: 5, limit: 10)
            XCTFail("expected the download to be refused")
        } catch {}
        // A declared length over the limit is refused before reading.
        do {
            _ = try await HubService.collect(chunks(0), declaredLength: 11, limit: 10)
            XCTFail("expected the download to be refused")
        } catch {}
    }

    // MARK: Copy to My Sets

    func testPackageItemsAreCopiedIntoASetAndThePackageStaysAsItIs() async throws {
        let model = await makeModel()
        let demo = try XCTUnwrap(model.installedPackage(named: "demo"))
        let before = try String(contentsOf: root.appendingPathComponent("match/packages/demo/package.yml"), encoding: .utf8)
        XCTAssertEqual(model.copyTargets.map(\.id), ["work.yml"])
        XCTAssertTrue(model.copyToMySets([demo.snippets[1].id], toSet: "work.yml"))
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("match/work.yml"), encoding: .utf8),
            "matches:\n  - trigger: \";sig\"\n    replace: Regards\n  - trigger: \":wave\"\n    replace: \"👋\"\n"
        )
        XCTAssertTrue(model.copyToMySets(demo.snippets.map(\.id), toNewSetNamed: "Faces"))
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("match/faces.yml"), encoding: .utf8),
            "matches:\n  - trigger: \":smile\"\n    replace: \"🙂\"\n  - trigger: \":wave\"\n    replace: \"👋\"\n"
        )
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("match/packages/demo/package.yml"), encoding: .utf8), before)
    }
}
