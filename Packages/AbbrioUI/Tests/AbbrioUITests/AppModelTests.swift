import XCTest
import EspansoCLI
import SnippetModel
@testable import AbbrioUI

/// Builds a small config folder in a temporary directory.
private func makeConfigFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("abbrio-tests-" + UUID().uuidString)
    let match = root.appendingPathComponent("match")
    try FileManager.default.createDirectory(at: match, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
    try "toggle_key: OFF\n".write(to: root.appendingPathComponent("config/default.yml"), atomically: true, encoding: .utf8)
    try """
    matches:
      - trigger: teh
        replace: the
        word: true
        propagate_case: true
      - trigger: item10
        replace: ten
      - trigger: item9
        replace: nine
        label: Number nine

    """.write(to: match.appendingPathComponent("work.yml"), atomically: true, encoding: .utf8)
    try """
    matches:
      - trigger: teh
        replace: the

    """.write(to: match.appendingPathComponent("autocorrect.yml"), atomically: true, encoding: .utf8)
    try """
    matches:
      - trigger: ";sig"
        replace: Regards from the office

    """.write(to: match.appendingPathComponent("_signatures.yml"), atomically: true, encoding: .utf8)
    return root
}

private struct NoRunner: CommandRunner {
    func run(
        _ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> CommandResult {
        throw CommandError.launchFailed("not available in tests")
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = try makeConfigFolder()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel() -> AppModel {
        AppModel(
            environment: AppEnvironment(configFolderOverride: root, fallbackConfigFolders: []),
            runner: NoRunner(),
            locator: EspansoLocator(searchPath: "", isExecutable: { _ in false })
        )
    }

    func testLoadsSetsAndSelectsTheFirst() async {
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.sets.map(\.id), ["autocorrect.yml", "_signatures.yml", "work.yml"])
        XCTAssertEqual(model.selectedSetID, "autocorrect.yml")
        XCTAssertEqual(model.selectedSnippet?.abbreviation, "teh")
        XCTAssertEqual(model.engineStatus, .notInstalled)
        XCTAssertNil(model.engineVersion)
        XCTAssertTrue(model.hasLoaded)
    }

    func testRowsAreSortedWithNumbersInOrder() async {
        let model = makeModel()
        await model.load()
        model.selectedSetID = "work.yml"
        XCTAssertEqual(model.rows.map(\.abbreviation), ["item9", "item10", "teh"])
        model.sortOrder = [KeyPathComparator(\SnippetRow.abbreviation, order: .reverse)]
        XCTAssertEqual(model.rows.map(\.abbreviation), ["teh", "item10", "item9"])
        model.sortOrder = [KeyPathComparator(\SnippetRow.expansion)]
        XCTAssertEqual(model.sortColumnName, "Expansion")
    }

    func testDuplicateIsFlaggedAndSummarized() async {
        let model = makeModel()
        await model.load()
        model.selectedSetID = "work.yml"
        let teh = model.rows.first { $0.abbreviation == "teh" }
        XCTAssertEqual(teh?.glyphs, [.caseAffectsExpansion, .wordBreak, .duplicateTrigger])
        XCTAssertEqual(model.listSummary, "3 items · 1 duplicate trigger: teh is also in Autocorrect")
    }

    func testSearchLooksInEverySet() async {
        let model = makeModel()
        await model.load()
        model.searchText = "the"
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(Set(model.rows.map(\.setName)), ["Autocorrect", "Work", "Signatures"])
        model.searchText = "\"number nine\""
        XCTAssertEqual(model.rows.map(\.abbreviation), ["item9"])
        XCTAssertEqual(model.selectedSnippet?.abbreviation, "item9")
        XCTAssertEqual(model.listSummary, "1 item")
        model.searchText = ""
        XCTAssertEqual(model.rows.count, 1)
    }

    func testCachedRowsFollowChangesToTheSets() async throws {
        let model = makeModel()
        await model.load()
        model.selectedSetID = "work.yml"
        XCTAssertEqual(model.rows.map(\.abbreviation), ["item9", "item10", "teh"])
        model.selectedSetID = "autocorrect.yml"
        XCTAssertEqual(model.rows.map(\.abbreviation), ["teh"])
        model.searchText = "nine"
        XCTAssertEqual(model.rows.map(\.abbreviation), ["item9"])
        model.searchText = ""

        // A file changed outside the app: neither a set shown before nor a search may come from the old version.
        try """
        matches:
          - trigger: item9
            replace: nine
            label: Number nine
          - trigger: item11
            replace: eleven, after nine

        """.write(to: root.appendingPathComponent("match/work.yml"), atomically: true, encoding: .utf8)
        await model.load()
        model.selectedSetID = "work.yml"
        XCTAssertEqual(model.rows.map(\.abbreviation), ["item9", "item11"])
        model.searchText = "nine"
        XCTAssertEqual(model.rows.map(\.abbreviation), ["item9", "item11"])
        model.searchText = "teh"
        XCTAssertEqual(model.rows.map(\.setName), ["Autocorrect"])
    }

    func testSelectionSurvivesAReload() async {
        let model = makeModel()
        await model.load()
        model.selectedSetID = "work.yml"
        model.selectedSnippetID = model.rows.last?.id
        await model.load()
        XCTAssertEqual(model.selectedSetID, "work.yml")
        XCTAssertEqual(model.selectedSnippet?.abbreviation, "teh")
    }

    func testNoFolderAtAll() async {
        let model = AppModel(
            environment: AppEnvironment(fallbackConfigFolders: [root.appendingPathComponent("missing")]),
            runner: NoRunner(),
            locator: EspansoLocator(searchPath: "", isExecutable: { _ in false })
        )
        await model.load()
        XCTAssertNil(model.configFolder)
        XCTAssertTrue(model.sets.isEmpty)
    }

    func testFallsBackToAnExistingFolder() async {
        let model = AppModel(
            environment: AppEnvironment(fallbackConfigFolders: [root.appendingPathComponent("missing"), root]),
            runner: NoRunner(),
            locator: EspansoLocator(searchPath: "", isExecutable: { _ in false })
        )
        await model.load()
        XCTAssertEqual(model.configFolder, root)
        XCTAssertEqual(model.sets.count, 3)
    }

    func testCasePreview() {
        var snippet = Snippet(id: .init(file: "match/a.yml", index: 0), triggers: ["btw"], expansion: .text("by the way"))
        XCTAssertNil(snippet.casePreview)
        snippet.options.propagateCase = true
        XCTAssertEqual(
            snippet.casePreview,
            "Case preview: btw → by the way · Btw → By the way · BTW → BY THE WAY"
        )
        XCTAssertEqual(snippet.caseChoice, "Case affects expansion")
        XCTAssertEqual(snippet.expandChoice, "On match")
    }
}
