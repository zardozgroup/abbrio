import XCTest
import SnippetModel
@testable import ConfigStore

/// A config folder in a temporary place, removed when the test ends.
final class TemporaryConfig: Sendable {
    let root: URL

    init(files: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbrio-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("match"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        for (path, text) in files {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func text(_ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    /// Every file under the folder, as paths relative to it.
    func listing() -> [String] {
        let base = root.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var paths: [String] = []
        for case let url as URL in enumerator! {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            paths.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1)))
        }
        return paths.sorted()
    }
}

final class ConfigWriterTests: XCTestCase {
    func testWriteReplacesTheFileAndKeepsABackup() throws {
        let config = try TemporaryConfig(files: ["match/a.yml": "one\n"])
        let writer = ConfigWriter(root: config.root)
        try writer.write(Data("two\n".utf8), to: "match/a.yml", replacing: Data("one\n".utf8))

        XCTAssertEqual(config.text("match/a.yml"), "two\n")
        XCTAssertEqual(config.text(".abbrio/backups/match__a.yml.1.bak"), "one\n")
        // Nothing is left behind that Espanso would react to: only .yml, .bak and no stray temp file.
        XCTAssertEqual(config.listing(), [".abbrio/backups/match__a.yml.1.bak", "match/a.yml"])
    }

    func testBackupNamesNeverLookLikeConfigFiles() throws {
        let config = try TemporaryConfig(files: ["match/team/b.yaml": "0\n"])
        let writer = ConfigWriter(root: config.root)
        try writer.write(Data("1\n".utf8), to: "match/team/b.yaml", replacing: Data("0\n".utf8))
        for path in config.listing() where path.hasPrefix(".abbrio/") {
            let name = (path as NSString).lastPathComponent
            XCTAssertTrue(name.hasSuffix(".bak"), name)
            XCTAssertFalse((name as NSString).pathExtension.isEmpty)
        }
    }

    func testOnlyTheLastTwentyVersionsAreKept() throws {
        let config = try TemporaryConfig(files: ["match/a.yml": "0\n"])
        let writer = ConfigWriter(root: config.root)
        for version in 1...25 {
            try writer.write(Data("\(version)\n".utf8), to: "match/a.yml", replacing: Data("\(version - 1)\n".utf8))
        }
        let backups = writer.backups(of: "match/a.yml")
        XCTAssertEqual(backups.map(\.number), Array(6...25))
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(backups.last).url, encoding: .utf8), "24\n")
    }

    func testAChangeOnDiskStopsTheWrite() throws {
        let config = try TemporaryConfig(files: ["match/a.yml": "edited elsewhere\n"])
        let writer = ConfigWriter(root: config.root)
        XCTAssertThrowsError(try writer.write(Data("mine\n".utf8), to: "match/a.yml", replacing: Data("one\n".utf8))) {
            XCTAssertEqual($0 as? EditError, .changedOnDisk)
        }
        XCTAssertEqual(config.text("match/a.yml"), "edited elsewhere\n")
        XCTAssertFalse(config.exists(".abbrio"))
    }

    func testNewFilesMustNotExistAndPermissionsAreKept() throws {
        let config = try TemporaryConfig(files: ["match/a.yml": "one\n"])
        let writer = ConfigWriter(root: config.root)
        XCTAssertThrowsError(try writer.write(Data(), to: "match/a.yml", replacing: nil)) {
            XCTAssertEqual($0 as? EditError, .alreadyExists("a.yml"))
        }
        let url = config.root.appendingPathComponent("match/a.yml")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try writer.write(Data("two\n".utf8), to: "match/a.yml", replacing: Data("one\n".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    // MARK: Confinement and links

    func testPathsThatLeaveTheConfigFolderAreRefused() throws {
        let config = try TemporaryConfig()
        let writer = ConfigWriter(root: config.root)
        let outside = config.root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).applescript")
        defer { try? FileManager.default.removeItem(at: outside) }
        for path in ["../\(outside.lastPathComponent)", "scripts/../../\(outside.lastPathComponent)", "/tmp/x.yml", "~/x.yml", "", "match//a.yml", "./a.yml"] {
            XCTAssertThrowsError(try writer.write(Data("x".utf8), to: path, replacing: nil), path)
            XCTAssertThrowsError(try writer.read(path), path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(ConfigWriter.isConfined(".abbrio/metadata.json"))
        XCTAssertTrue(ConfigWriter.isConfined("match/packages/x/package.yml"))
    }

    func testALinkedFileIsWrittenThroughAndTheLinkStays() throws {
        let config = try TemporaryConfig()
        let synced = FileManager.default.temporaryDirectory.appendingPathComponent("synced-\(UUID().uuidString).yml")
        defer { try? FileManager.default.removeItem(at: synced) }
        try "one\n".write(to: synced, atomically: true, encoding: .utf8)
        let link = config.root.appendingPathComponent("match/linked.yml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: synced)

        let writer = ConfigWriter(root: config.root)
        XCTAssertEqual(try writer.read("match/linked.yml"), Data("one\n".utf8))
        try writer.write(Data("two\n".utf8), to: "match/linked.yml", replacing: Data("one\n".utf8))

        XCTAssertEqual(ConfigWriter.kind(at: link), .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOf: synced, encoding: .utf8), "two\n")
        XCTAssertEqual(config.text(".abbrio/backups/match__linked.yml.1.bak"), "one\n")
        // No temporary file is left next to the linked file either.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: synced.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".\(synced.lastPathComponent)") }
        XCTAssertEqual(leftovers, [])
    }

    func testDanglingLinksAndOtherKindsOfFileAreRefused() throws {
        let config = try TemporaryConfig()
        let writer = ConfigWriter(root: config.root)
        let dangling = config.root.appendingPathComponent("match/gone.yml")
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: config.root.appendingPathComponent("nowhere.yml")
        )
        XCTAssertThrowsError(try writer.write(Data("x".utf8), to: "match/gone.yml", replacing: Data()))
        XCTAssertThrowsError(try writer.write(Data("x".utf8), to: "match/gone.yml", replacing: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.root.appendingPathComponent("nowhere.yml").path))

        let pipe = config.root.appendingPathComponent("match/pipe.yml")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        // A pipe would block forever if it were opened for reading.
        XCTAssertThrowsError(try writer.read("match/pipe.yml"))
        XCTAssertThrowsError(try writer.write(Data("x".utf8), to: "match/pipe.yml", replacing: Data()))
        XCTAssertThrowsError(try writer.write(Data("x".utf8), to: "match", replacing: Data()))
    }

    func testATemporaryFileAlreadyThereIsNeverWrittenThrough() throws {
        let config = try TemporaryConfig(files: ["match/a.yml": "one\n"])
        let victim = FileManager.default.temporaryDirectory.appendingPathComponent("victim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: victim) }
        try "keep\n".write(to: victim, atomically: true, encoding: .utf8)
        // The name the old code used for its temporary file, now a link to a file outside.
        try FileManager.default.createSymbolicLink(
            at: config.root.appendingPathComponent("match/.a.yml.tmp"), withDestinationURL: victim
        )
        try ConfigWriter(root: config.root).write(Data("two\n".utf8), to: "match/a.yml", replacing: Data("one\n".utf8))
        XCTAssertEqual(config.text("match/a.yml"), "two\n")
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "keep\n")

        let file = config.root.appendingPathComponent("match/b.yml")
        try ConfigWriter.createExclusively(file, with: Data("b".utf8))
        XCTAssertThrowsError(try ConfigWriter.createExclusively(file, with: Data("c".utf8)))
        XCTAssertEqual(config.text("match/b.yml"), "b")
    }
}

final class SetManagerTests: XCTestCase {
    private let mailConfig = """
    # Mail only
    filter_class: "^com\\\\.apple\\\\.mail$"
    extra_includes:
      - "../match/_signatures.yml"   # switched off elsewhere
    extra_excludes:
      - "../match/autocorrect.yml"
      - "../match/other.yml"

    """

    private func manager(_ config: TemporaryConfig) -> SetManager {
        SetManager(writer: ConfigWriter(root: config.root)) { url in
            let trash = config.root.deletingLastPathComponent().appendingPathComponent("trash-\(config.root.lastPathComponent)")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
    }

    func testSlugs() {
        XCTAssertEqual(SetManager.slug(for: "Email Signatures!"), "email-signatures")
        XCTAssertEqual(SetManager.slug(for: "  Café — Münster  "), "cafe-munster")
        XCTAssertEqual(SetManager.slug(for: "日本語"), "untitled")
        XCTAssertEqual(SetManager.slug(for: "a/b\\c..yml"), "a-b-c-yml")
    }

    func testCreateMakesAnEmptyMatchFileWithAFreeName() throws {
        let config = try TemporaryConfig(files: ["match/_work-notes.yml": "matches: []\n"])
        let manager = manager(config)
        XCTAssertEqual(try manager.createSet(named: "Work Notes").id, "work-notes-2.yml")
        XCTAssertEqual(try manager.createSet(named: "Travel").id, "travel.yml")
        XCTAssertEqual(config.text("match/travel.yml"), "matches: []\n")
        XCTAssertTrue(ConfigLoader(root: config.root).load().sets.allSatisfy { !$0.isBroken })
    }

    func testSwitchingASetOffAndOnRenamesTheFileAndItsReferences() throws {
        let config = try TemporaryConfig(files: [
            "match/autocorrect.yml": "matches: []\n",
            "match/_signatures.yml": "matches: []\n",
            "config/default.yml": "toggle_key: OFF\n",
            "config/mail.yml": mailConfig,
        ])
        let manager = manager(config)

        let off = try manager.setEnabled(false, for: "autocorrect.yml")
        XCTAssertEqual(off, SetManager.Outcome(id: "_autocorrect.yml"))
        XCTAssertTrue(config.exists("match/_autocorrect.yml"))
        XCTAssertFalse(config.exists("match/autocorrect.yml"))
        XCTAssertEqual(config.text("config/mail.yml"),
                       mailConfig.replacingOccurrences(of: "match/autocorrect.yml", with: "match/_autocorrect.yml"))
        XCTAssertEqual(config.text("config/default.yml"), "toggle_key: OFF\n")

        let on = try manager.setEnabled(true, for: "_signatures.yml")
        XCTAssertEqual(on.id, "signatures.yml")
        XCTAssertTrue(config.text("config/mail.yml")!.contains("  - \"../match/signatures.yml\"   # switched off elsewhere"))
    }

    func testRenameKeepsTheFolderExtensionAndState() throws {
        let config = try TemporaryConfig(files: ["match/taken.yml": "matches: []\n"])
        let nested = config.root.appendingPathComponent("match/team")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "matches: []\n".write(to: nested.appendingPathComponent("_old.yaml"), atomically: true, encoding: .utf8)
        let manager = manager(config)

        XCTAssertEqual(try manager.renameSet("team/_old.yaml", to: "New Name").id, "team/_new-name.yaml")
        XCTAssertTrue(config.exists("match/team/_new-name.yaml"))
        // The same name again is nothing to do.
        XCTAssertEqual(try manager.renameSet("taken.yml", to: "Taken").id, "taken.yml")
        try "matches: []\n".write(to: config.root.appendingPathComponent("match/free.yml"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try manager.renameSet("free.yml", to: "taken")) {
            XCTAssertEqual($0 as? EditError, .alreadyExists("taken.yml"))
        }
    }

    func testDeleteMovesTheFileAwayAndDropsItsReferences() throws {
        let config = try TemporaryConfig(files: [
            "match/autocorrect.yml": "matches: []\n",
            "match/_signatures.yml": "matches: []\n",
            "config/mail.yml": mailConfig,
        ])
        let manager = manager(config)

        XCTAssertEqual(try manager.deleteSet("autocorrect.yml"), SetManager.Outcome(id: nil))
        XCTAssertFalse(config.exists("match/autocorrect.yml"))
        XCTAssertEqual(config.text("config/mail.yml"),
                       mailConfig.replacingOccurrences(of: "  - \"../match/autocorrect.yml\"\n", with: ""))

        // Removing the only entry of a list removes the key as well.
        XCTAssertEqual(try manager.deleteSet("_signatures.yml").remainingReferences, [])
        let text = try XCTUnwrap(config.text("config/mail.yml"))
        XCTAssertFalse(text.contains("extra_includes"))
        XCTAssertTrue(text.contains("extra_excludes:\n  - \"../match/other.yml\"\n"))
        XCTAssertNil(ConfigLoader(root: config.root).load().configFiles.first?.problem)
    }

    func testRemovingTheLastLineOfAConfigFileLeavesItEmpty() throws {
        let config = try TemporaryConfig(files: [
            "match/a.yml": "matches: []\n",
            "config/default.yml": "extra_excludes:\n  - \"../match/a.yml\"\n",
        ])
        XCTAssertEqual(try manager(config).deleteSet("a.yml").remainingReferences, [])
        XCTAssertEqual(config.text("config/default.yml"), "")
    }

    func testReferencesInFlowListsAreReportedWhenTheyCannotBeRemoved() throws {
        let config = try TemporaryConfig(files: [
            "match/a.yml": "matches: []\n",
            "config/default.yml": "extra_excludes: [\"../match/a.yml\"]\n",
        ])
        let outcome = try manager(config).deleteSet("a.yml")
        XCTAssertEqual(outcome.remainingReferences, ["config/default.yml"])
        XCTAssertEqual(config.text("config/default.yml"), "extra_excludes: [\"../match/a.yml\"]\n")
    }
}

final class ConfigWatcherTests: XCTestCase {
    func testReportsOutsideChangesButNotBackups() async throws {
        let config = try TemporaryConfig(files: ["match/a.yml": "matches: []\n"])
        try FileManager.default.createDirectory(
            at: config.root.appendingPathComponent(".abbrio/backups"), withIntermediateDirectories: true
        )
        let root = config.root
        // Let the events from setting the folder up pass before watching.
        try await Task.sleep(for: .seconds(1))

        func eventArrives(after change: @Sendable @escaping () throws -> Void) async throws -> Bool {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await _ in ConfigWatcher.changes(in: root, latency: 0.05) { return true }
                    return false
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(300))
                    try change()
                    try await Task.sleep(for: .seconds(2))
                    return false
                }
                let first = try await group.next() ?? false
                group.cancelAll()
                return first
            }
        }

        let sawBackup = try await eventArrives {
            try Data("x".utf8).write(to: root.appendingPathComponent(".abbrio/backups/match__a.yml.1.bak"))
        }
        XCTAssertFalse(sawBackup)
        let sawEdit = try await eventArrives {
            try Data("matches: []\n# edited\n".utf8).write(to: root.appendingPathComponent("match/a.yml"))
        }
        XCTAssertTrue(sawEdit)
    }
}
