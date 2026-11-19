import XCTest
import EspansoCLI
import SnippetModel
@testable import AbbrioUI

private let workFile = """
# Office snippets
matches:
  # typo
  - trigger: teh
    replace: the
    word: true

  - trigger: ";addr"
    replace: |
      1 Harbour Street
      Northport
    label: Address   # office

  - { trigger: ";flow", replace: inline }

"""

/// Answers `espanso` commands from a table. Listing the matches also writes a reload line to the log, the
/// way the service does after a file changes.
private struct ScriptedRunner: CommandRunner {
    var runtime: URL
    var isRunning = true
    var listFails = false

    func run(
        _ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> CommandResult {
        switch arguments.joined(separator: " ") {
        case "--version":
            return CommandResult(exitCode: 0, standardOutput: "2.4.1\n")
        case "path":
            return CommandResult(exitCode: 0, standardOutput: "Config: /unused\nRuntime: \(runtime.path)\n")
        case "status":
            return CommandResult(exitCode: isRunning ? 0 : 4)
        case "match list --json":
            if listFails { return CommandResult(exitCode: 2, standardError: "unable to load config\nmore detail") }
            let line = "12:00:00 [daemon] [INFO] configuration change detected, restarting worker process...\n"
            let log = runtime.appendingPathComponent("espanso.log")
            let existing = (try? Data(contentsOf: log)) ?? Data()
            try (existing + Data(line.utf8)).write(to: log)
            return CommandResult(exitCode: 0, standardOutput: "[]")
        default:
            throw CommandError.launchFailed("no answer for \(arguments)")
        }
    }
}

private struct NoRunner: CommandRunner {
    func run(
        _ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> CommandResult {
        throw CommandError.launchFailed("not available in tests")
    }
}

@MainActor
final class AppModelEditingTests: XCTestCase {
    private var root: URL!
    private var trash: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("abbrio-tests-" + UUID().uuidString)
        root = base.appendingPathComponent("config-folder")
        trash = base.appendingPathComponent("trash")
        for folder in ["match", "config"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try write("config/default.yml", "extra_excludes:\n  - \"../match/other.yml\"\n")
        try write("match/work.yml", workFile)
        try write("match/other.yml", "matches:\n  - trigger: teh\n    replace: the\n")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func text(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    private func makeModel(runner: (any CommandRunner)? = nil) async -> AppModel {
        let trash = trash!
        let model = AppModel(
            environment: AppEnvironment(configFolderOverride: root, fallbackConfigFolders: []),
            runner: runner ?? NoRunner(),
            locator: EspansoLocator(searchPath: "", isExecutable: { _ in runner != nil }),
            discard: { url in
                try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
            }
        )
        model.autosaveDelay = .seconds(60)
        await model.load()
        model.selectedSetID = "work.yml"
        return model
    }

    private func select(_ abbreviation: String, in model: AppModel) {
        model.selectedSnippetID = model.rows.first { $0.abbreviation == abbreviation }?.id
    }

    private func waitForConfirmation(_ model: AppModel) async {
        for _ in 0..<100 where model.saveState == .saved(.checking) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Editing

    func testAnEditChangesOnlyThatItemAndKeepsABackup() async {
        let model = await makeModel()
        select("teh", in: model)
        model.updateDraft { $0.body = "the " }
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(text("match/work.yml"), workFile, "nothing is written while typing")

        XCTAssertTrue(model.commitDraft())
        XCTAssertEqual(text("match/work.yml"), workFile.replacingOccurrences(of: "    replace: the\n", with: "    replace: \"the \"\n"))
        XCTAssertEqual(text(".abbrio/backups/match__work.yml.1.bak"), workFile)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.selectedSnippet?.expansion, .text("the "))

        await waitForConfirmation(model)
        XCTAssertEqual(model.saveState, .saved(.notRunning))
    }

    func testTypingIsSavedAfterAPause() async throws {
        let model = await makeModel()
        model.autosaveDelay = .milliseconds(40)
        select(";addr", in: model)
        model.updateDraft { $0.label = "Office" }
        model.updateDraft { $0.label = "Office address" }
        XCTAssertFalse(text("match/work.yml").contains("Office address"))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(text("match/work.yml").contains("    label: Office address\n"))
        XCTAssertEqual(text(".abbrio/backups/match__work.yml.2.bak"), "", "one save, one backup")
    }

    func testMovingToAnotherItemSavesTheDraft() async {
        let model = await makeModel()
        select("teh", in: model)
        model.updateDraft { $0.options.word = false }
        select(";addr", in: model)
        XCTAssertFalse(text("match/work.yml").contains("word: true"))
        XCTAssertEqual(model.draft?.abbreviation, ";addr")
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testAnEmptyAbbreviationIsNotWritten() async {
        let model = await makeModel()
        select("teh", in: model)
        model.updateDraft { $0.abbreviation = "" }
        XCTAssertEqual(model.saveState, .invalid("Enter an abbreviation."))
        XCTAssertFalse(model.commitDraft())
        XCTAssertEqual(text("match/work.yml"), workFile)
    }

    func testAdvancedItemsAndPackagesAreReadOnlyInTheForm() async {
        let model = await makeModel()
        select(";flow", in: model)
        XCTAssertNotNil(model.formLockReason)
        XCTAssertTrue(model.canEditYAML)
        model.updateDraft { $0.label = "nope" }
        XCTAssertFalse(model.hasUnsavedChanges)
        select("teh", in: model)
        XCTAssertNil(model.formLockReason)
    }

    func testDuplicateTriggersInOtherSetsAreNamed() async {
        let model = await makeModel()
        select("teh", in: model)
        XCTAssertEqual(model.draftDuplicateSetNames, ["Other"])
        select(";addr", in: model)
        XCTAssertEqual(model.draftDuplicateSetNames, [])
        model.updateDraft { $0.aliases = ["teh"] }
        XCTAssertEqual(model.draftDuplicateSetNames, ["Other", "Work"])
    }

    // MARK: Adding, duplicating, deleting

    func testANewItemIsWrittenOnceItHasAnAbbreviation() async {
        let model = await makeModel()
        model.newItem()
        XCTAssertTrue(model.isAddingItem)
        XCTAssertEqual(model.rows.count, 4)
        XCTAssertEqual(model.selectedSnippet?.abbreviation, "")
        XCTAssertFalse(model.commitDraft() && model.hasUnsavedChanges)
        XCTAssertEqual(text("match/work.yml"), workFile)

        model.updateDraft { $0.abbreviation = ";new" }
        model.updateDraft { $0.body = "Brand new" }
        XCTAssertTrue(model.commitDraft())
        XCTAssertTrue(text("match/work.yml").contains("  - { trigger: \";flow\", replace: inline }\n\n  - trigger: \";new\"\n    replace: Brand new\n"))
        XCTAssertFalse(model.isAddingItem)
        XCTAssertEqual(model.selectedSnippet?.abbreviation, ";new")
        XCTAssertEqual(model.rows.count, 4)

        // Further typing edits the same item instead of adding another.
        model.updateDraft { $0.label = "Fresh" }
        XCTAssertTrue(model.commitDraft())
        XCTAssertEqual(model.rows.count, 4)
        XCTAssertTrue(text("match/work.yml").hasSuffix("    replace: Brand new\n    label: Fresh\n"))
    }

    func testAnUnfinishedNewItemIsDroppedWhenLeft() async {
        let model = await makeModel()
        model.newItem()
        select("teh", in: model)
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertFalse(model.isAddingItem)
        XCTAssertEqual(text("match/work.yml"), workFile)
    }

    func testDuplicateDeleteUndoAndRedo() async {
        let model = await makeModel()
        select(";addr", in: model)
        model.duplicateSelectedItem()
        XCTAssertEqual(model.rows.filter { $0.abbreviation == ";addr" }.count, 2)
        XCTAssertEqual(model.selectedSnippetID?.index, 2)
        let duplicated = text("match/work.yml")

        model.deleteSelectedItem()
        XCTAssertEqual(text("match/work.yml"), workFile)
        XCTAssertNotNil(model.selectedSnippet)

        select("teh", in: model)
        model.deleteSelectedItem()
        XCTAssertFalse(text("match/work.yml").contains("# typo"))
        XCTAssertEqual(model.rows.map(\.abbreviation).sorted(), [";addr", ";flow"])

        model.undo()
        XCTAssertEqual(text("match/work.yml"), workFile)
        model.undo()
        XCTAssertEqual(text("match/work.yml"), duplicated)
        model.undo()
        XCTAssertEqual(text("match/work.yml"), workFile)
        XCTAssertFalse(model.canUndo)
        model.redo()
        XCTAssertEqual(text("match/work.yml"), duplicated)
        XCTAssertEqual(model.rows.count, 4)
    }

    func testUndoIsRefusedAfterAnOutsideChange() async throws {
        let model = await makeModel()
        select("teh", in: model)
        model.updateDraft { $0.body = "then" }
        model.commitDraft()
        try write("match/work.yml", workFile + "# touched\n")
        model.undo()
        XCTAssertNotNil(model.alertMessage)
        XCTAssertEqual(text("match/work.yml"), workFile + "# touched\n")
    }

    // MARK: Outside changes

    func testAnOutsideChangeToTheEditedItemAsksWhatToKeep() async throws {
        let model = await makeModel()
        select("teh", in: model)
        model.updateDraft { $0.body = "mine" }
        let outside = workFile.replacingOccurrences(of: "    replace: the\n", with: "    replace: theirs\n")
        try write("match/work.yml", outside)

        XCTAssertFalse(model.commitDraft())
        XCTAssertEqual(model.saveState, .conflict)
        XCTAssertEqual(text("match/work.yml"), outside)

        model.keepMine()
        XCTAssertEqual(text("match/work.yml"), workFile.replacingOccurrences(of: "    replace: the\n", with: "    replace: mine\n"))
        XCTAssertNotEqual(model.saveState, .conflict)
    }

    func testLoadFromDiskDropsTheDraft() async throws {
        let model = await makeModel()
        select("teh", in: model)
        model.updateDraft { $0.body = "mine" }
        let outside = workFile.replacingOccurrences(of: "    replace: the\n", with: "    replace: theirs\n")
        try write("match/work.yml", outside)
        model.commitDraft()
        model.loadFromDisk()
        XCTAssertEqual(model.draft?.body, "theirs")
        XCTAssertEqual(model.saveState, .idle)
        XCTAssertEqual(text("match/work.yml"), outside)
    }

    func testAnOutsideChangeElsewhereInTheFileDoesNotGetInTheWay() async throws {
        let model = await makeModel()
        select("teh", in: model)
        model.updateDraft { $0.body = "mine" }
        let outside = workFile.replacingOccurrences(of: "Address   # office", with: "Head office")
        try write("match/work.yml", outside)
        XCTAssertTrue(model.commitDraft())
        XCTAssertEqual(text("match/work.yml"), outside.replacingOccurrences(of: "    replace: the\n", with: "    replace: mine\n"))
    }

    func testTheWatcherPicksUpOutsideChanges() async throws {
        let model = await makeModel()
        try await Task.sleep(for: .milliseconds(500))
        try write("match/work.yml", workFile + "  - trigger: ;late\n    replace: arrived\n")
        for _ in 0..<60 where model.rows.count != 4 {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(model.rows.count, 4)
    }

    // MARK: YAML

    func testSavingYAMLForOneItemAndForABrokenFile() async throws {
        let model = await makeModel()
        select(";flow", in: model)
        XCTAssertNotNil(model.saveYAML("  - trigger: \";flow"))
        XCTAssertEqual(text("match/work.yml"), workFile)
        XCTAssertNil(model.saveYAML("  - trigger: \";flow\"\n    replace: block now\n"))
        XCTAssertTrue(text("match/work.yml").hasSuffix("  - trigger: \";flow\"\n    replace: block now\n"))
        XCTAssertNil(model.formLockReason)

        try write("match/broken.yml", "matches:\n  - trigger: \"open\n")
        await model.load()
        let broken = try XCTUnwrap(model.sets.first { $0.id == "broken.yml" })
        XCTAssertTrue(broken.isBroken)
        XCTAssertEqual(model.fileText(of: broken), "matches:\n  - trigger: \"open\n")
        XCTAssertNotNil(model.saveFileText("matches: nope\n", of: broken))
        XCTAssertNil(model.saveFileText("matches:\n  - trigger: open\n    replace: fixed\n", of: broken))
        XCTAssertEqual(model.sets.first { $0.id == "broken.yml" }?.isBroken, false)
    }

    // MARK: Sets

    func testCreateRenameSwitchAndDeleteASet() async {
        let model = await makeModel()
        XCTAssertTrue(model.createSet(named: "Travel Notes"))
        XCTAssertEqual(model.selectedSetID, "travel-notes.yml")
        XCTAssertEqual(text("match/travel-notes.yml"), "matches: []\n")
        XCTAssertTrue(model.canAddItem)

        XCTAssertEqual(model.fileName(forSetNamed: "Trips", renaming: "travel-notes.yml"), "trips.yml")
        XCTAssertTrue(model.renameSet("travel-notes.yml", to: "Trips", renamingFile: true))
        XCTAssertEqual(model.selectedSet?.name, "Trips")

        XCTAssertTrue(model.setEnabled(false, for: "other.yml"))
        XCTAssertEqual(model.sets.first { $0.name == "Other" }?.isEnabled, false)
        XCTAssertEqual(text("config/default.yml"), "extra_excludes:\n  - \"../match/_other.yml\"\n")

        XCTAssertFalse(model.renameSet("trips.yml", to: "Work", renamingFile: true))
        XCTAssertNotNil(model.alertMessage)

        XCTAssertTrue(model.deleteSet("_other.yml"))
        XCTAssertEqual(model.sets.map(\.id), ["trips.yml", "work.yml"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("_other.yml").path))
        XCTAssertEqual(text("config/default.yml"), "")
    }

    // MARK: Espanso's answer

    func testASaveIsConfirmedFromEspansosLog() async throws {
        let runtime = root.deletingLastPathComponent().appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let model = await makeModel(runner: ScriptedRunner(runtime: runtime))
        XCTAssertEqual(model.engineStatus, .running)
        select("teh", in: model)
        model.updateDraft { $0.label = "Typo" }
        model.commitDraft()
        XCTAssertEqual(model.saveState, .saved(.checking))
        await waitForConfirmation(model)
        XCTAssertEqual(model.saveState, .saved(.reloaded))
    }

    func testEspansoRejectingTheFolderIsReported() async throws {
        let runtime = root.deletingLastPathComponent().appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let model = await makeModel(runner: ScriptedRunner(runtime: runtime, listFails: true))
        select("teh", in: model)
        model.updateDraft { $0.label = "Typo" }
        model.commitDraft()
        await waitForConfirmation(model)
        XCTAssertEqual(model.saveState, .saved(.rejected("unable to load config")))
    }
}
