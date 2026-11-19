import XCTest
import SQLite3
import ConfigStore
import EspansoCLI
import SnippetModel
@testable import AbbrioUI

/// Answers `espanso` commands from a table and remembers what was asked.
private final class ScriptedRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: CommandResult]
    private var log: [String] = []

    init(_ responses: [String: CommandResult]) {
        self.responses = responses
    }

    var commands: [String] { lock.withLock { log } }

    func set(_ command: String, _ result: CommandResult?) {
        lock.withLock { responses[command] = result }
    }

    func run(
        _ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> CommandResult {
        let command = arguments.joined(separator: " ")
        return try lock.withLock {
            log.append(command)
            guard let response = responses[command] else { throw CommandError.launchFailed("no stub for \(command)") }
            return response
        }
    }
}

/// A clipboard and keyboard that only write down what they are asked to do.
@MainActor
private final class FakeDevice: InsertionDevice {
    var isTrusted = true
    var askedForTrust = false
    var modifiersAreDown = false
    /// Makes the system report a modifier as down once the paste has been sent.
    var modifiersStickAfterPaste = false
    var clipboard: String? = "what the user copied"
    var clipboardChangeCount = 0
    var selection: String?
    /// What ⌘C puts on the clipboard, when the app answers it.
    var copyResult: String?
    var steps: [String] = []

    func askForTrust() { askedForTrust = true }

    func saveClipboard() -> ClipboardContents {
        steps.append("save")
        return ClipboardContents(items: clipboard.map { [["text": Data($0.utf8)]] } ?? [])
    }

    func restoreClipboard(_ contents: ClipboardContents) {
        clipboard = contents.items.first?["text"].map { String(decoding: $0, as: UTF8.self) }
        clipboardChangeCount += 1
        steps.append("restore")
    }

    func setClipboard(_ text: String) {
        clipboard = text
        clipboardChangeCount += 1
        steps.append("set(\(text))")
    }

    func paste() {
        steps.append("paste(\(clipboard ?? ""))")
        if modifiersStickAfterPaste { modifiersAreDown = true }
    }
    func moveLeft(_ count: Int) { steps.append("left(\(count))") }
    func selectedText() -> String? { selection }

    func copy() {
        steps.append("copy")
        if let copyResult {
            clipboard = copyResult
            clipboardChangeCount += 1
        }
    }

    func clipboardText() -> String? { clipboard }
}

private let workFile = """
# Work
matches:
  - trigger: ";ty"
    replace: "Thank you!"
    label: Short thanks
  - trigger: ";dear"
    replace: "Dear $|$,\\nBest"
  - trigger: ";today"
    replace: "Today is {{d}}"
    vars:
      - name: d
        type: date
        params:
          format: "%A"
  - regex: "(?P<n>\\\\d+)usd"
    replace: "$ {{n}}"

"""

@MainActor
final class CompanionTests: XCTestCase {
    private var root: URL!
    private var runtime: URL!
    private var defaults: UserDefaults!
    private var suite = ""
    private let ok = CommandResult(exitCode: 0)

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("abbrio-tests-" + UUID().uuidString)
        root = base.appendingPathComponent("config-folder")
        runtime = base.appendingPathComponent("runtime")
        for folder in [root.appendingPathComponent("match"), root.appendingPathComponent("config"), runtime!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "toggle_key: OFF\n".write(to: root.appendingPathComponent("config/default.yml"), atomically: true, encoding: .utf8)
        try workFile.write(to: root.appendingPathComponent("match/work.yml"), atomically: true, encoding: .utf8)
        suite = "abbrio-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        defaults.removePersistentDomain(forName: suite)
    }

    private func text(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    private func appendLog(_ line: String) throws {
        let url = runtime.appendingPathComponent("espanso.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    private func runner(running: Bool = true) -> ScriptedRunner {
        ScriptedRunner([
            "--version": CommandResult(exitCode: 0, standardOutput: "espanso 2.4.1\n"),
            "path": CommandResult(exitCode: 0, standardOutput: "Config: \(root.path)\nPackages: \(root.path)/match/packages\nRuntime: \(runtime.path)\n"),
            "status": CommandResult(exitCode: running ? 0 : 1),
            "match list --json": CommandResult(exitCode: 0, standardOutput: "[]"),
            "cmd disable": ok, "cmd enable": ok, "restart": ok, "service start": ok,
            "match exec -t ;today": ok,
        ])
    }

    private var secureInput = false

    private func makeModel(_ runner: ScriptedRunner) async -> AppModel {
        let model = AppModel(
            environment: AppEnvironment(configFolderOverride: root, fallbackConfigFolders: []),
            runner: runner,
            locator: EspansoLocator(override: URL(fileURLWithPath: "/stub/espanso"), searchPath: "", isExecutable: { $0 == "/stub/espanso" }),
            discard: { try FileManager.default.removeItem(at: $0) },
            defaults: defaults,
            isSecureInputOn: { [unowned self] in self.secureInput },
            readClipboard: { "Please send the signed agreement back by Friday." }
        )
        await model.load()
        return model
    }

    // MARK: Engine state

    func testStatusFollowsTheServiceAndTheLog() async throws {
        let runner = runner()
        let model = await makeModel(runner)
        XCTAssertEqual(model.engineStatus, .running)
        XCTAssertEqual(model.engineHeadline, "Espanso is running")

        // A pause made with Espanso's toggle key shows up only in the log.
        try appendLog("10:00:00 [worker(1)] [INFO] toggled enabled state, is_enabled = false")
        await model.refreshEngine()
        XCTAssertEqual(model.engineStatus, .paused)
        XCTAssertTrue(model.expansionsArePaused)

        // A worker restart switches expansions back on.
        try appendLog("10:00:05 [daemon(2)] [INFO] spawning the worker process...")
        await model.refreshEngine()
        XCTAssertEqual(model.engineStatus, .running)

        try appendLog("10:00:06 [worker(3)] [INFO] secure input has been acquired, preventing espanso from working correctly. Our guess is that this is caused by 'Terminal', but there are cases in which the detection is unreliable. Full path: /x")
        secureInput = true
        await model.refreshEngine()
        XCTAssertEqual(model.engineStatus, .secureInput)
        XCTAssertEqual(model.engineHeadline, "Secure Input is on, probably in Terminal")

        secureInput = false
        await model.refreshEngine()
        XCTAssertEqual(model.engineStatus, .running)
        XCTAssertNil(model.secureInputHolder)

        runner.set("status", CommandResult(exitCode: 1))
        await model.refreshEngine()
        XCTAssertEqual(model.engineStatus, .notRunning)
        XCTAssertTrue(model.canStartEngine)
    }

    func testPauseResumeRestartAndStartRunTheirCommands() async throws {
        let runner = runner()
        let model = await makeModel(runner)
        await model.pauseExpansions()
        XCTAssertEqual(model.engineStatus, .paused)
        await model.resumeExpansions()
        XCTAssertEqual(model.engineStatus, .running)
        await model.pauseExpansions()
        await model.restartEngine()
        XCTAssertEqual(model.engineStatus, .running)

        runner.set("status", CommandResult(exitCode: 1))
        await model.refreshEngine()
        runner.set("status", ok)
        await model.startEngine()
        XCTAssertEqual(model.engineStatus, .running)
        XCTAssertNil(model.engineMessage)
        let sent = runner.commands.filter { ["cmd disable", "cmd enable", "restart", "service start"].contains($0) }
        XCTAssertEqual(sent, ["cmd disable", "cmd enable", "cmd disable", "restart", "service start"])
    }

    func testAFailedCommandLeavesAMessage() async throws {
        let runner = runner()
        runner.set("cmd disable", CommandResult(exitCode: 1, standardError: "unable to send command\n"))
        let model = await makeModel(runner)
        await model.pauseExpansions()
        XCTAssertEqual(model.engineStatus, .running)
        XCTAssertEqual(model.engineMessage, "Espanso: unable to send command")
    }

    // MARK: Insertion

    private func makeSearch(_ model: AppModel, _ device: FakeDevice) -> (QuickSearchModel, hidden: () -> Int, shown: () -> Int) {
        let search = QuickSearchModel(model: model, device: device, timing: .immediate)
        var hidden = 0, shown = 0
        search.hidePanel = { hidden += 1 }
        search.showPanel = { shown += 1 }
        search.prepare()
        return (search, { hidden }, { shown })
    }

    func testPlainTextIsPastedAndTheClipboardRestored() async throws {
        let runner = runner()
        let model = await makeModel(runner)
        let device = FakeDevice()
        let (search, hidden, _) = makeSearch(model, device)
        search.query = "short thanks"
        XCTAssertEqual(search.results.map(\.abbreviation), [";ty"])
        XCTAssertEqual(search.routeDescription, "pastes the text")
        await search.insertSelected()
        XCTAssertEqual(device.steps, ["save", "set(Thank you!)", "paste(Thank you!)", "restore"])
        XCTAssertEqual(device.clipboard, "what the user copied")
        XCTAssertEqual(hidden(), 1)
        XCTAssertFalse(runner.commands.contains { $0.hasPrefix("match exec") })
        XCTAssertNil(search.message)
    }

    func testCursorMarkerMovesTheCursorBack() async throws {
        let model = await makeModel(runner())
        let device = FakeDevice()
        let (search, _, _) = makeSearch(model, device)
        search.query = ";dear"
        await search.insertSelected()
        XCTAssertEqual(device.steps, ["save", "set(Dear ,\nBest)", "paste(Dear ,\nBest)", "left(6)", "restore"])
    }

    func testDynamicItemPastesItsTriggerThenAsksEspanso() async throws {
        let runner = runner()
        let model = await makeModel(runner)
        let device = FakeDevice()
        let (search, _, _) = makeSearch(model, device)
        search.query = "today"
        XCTAssertEqual(search.routeDescription, "espanso match exec -t ;today")
        await search.insertSelected()
        // The clipboard is back before Espanso runs, so a clipboard variable sees the user's text.
        XCTAssertEqual(device.steps, ["save", "set(;today)", "paste(;today)", "restore"])
        XCTAssertEqual(runner.commands.last, "match exec -t ;today")
        XCTAssertEqual(device.clipboard, "what the user copied")
    }

    func testDynamicItemIsNotPastedWhenEspansoIsStopped() async throws {
        let runner = runner(running: false)
        let model = await makeModel(runner)
        let device = FakeDevice()
        let (search, hidden, _) = makeSearch(model, device)
        search.query = "today"
        await search.insertSelected()
        XCTAssertEqual(device.steps, [])
        XCTAssertEqual(hidden(), 0)
        XCTAssertEqual(search.message, "This item needs Espanso, which isn't running.")

        // Plain text needs no service.
        search.query = ";ty"
        await search.insertSelected()
        XCTAssertEqual(device.steps.last, "restore")
    }

    func testAFailedExpansionReopensThePanelWithTheReason() async throws {
        let runner = runner()
        runner.set("match exec -t ;today", CommandResult(exitCode: 1, standardError: "unable to exec match: Worker process is not running, please start Espanso first.\n"))
        let model = await makeModel(runner)
        let device = FakeDevice()
        let (search, _, shown) = makeSearch(model, device)
        search.query = "today"
        await search.insertSelected()
        XCTAssertEqual(shown(), 1)
        XCTAssertEqual(search.message?.hasPrefix("Espanso: unable to exec match"), true)
        XCTAssertEqual(device.clipboard, "what the user copied")
    }

    func testNothingIsSentWithoutAccessibilityPermission() async throws {
        let model = await makeModel(runner())
        let device = FakeDevice()
        device.isTrusted = false
        let (search, hidden, _) = makeSearch(model, device)
        search.query = ";ty"
        await search.insertSelected()
        XCTAssertEqual(device.steps, [])
        XCTAssertTrue(device.askedForTrust)
        XCTAssertEqual(hidden(), 0)
        XCTAssertNotNil(search.message)
    }

    func testHeldModifiersStopTheInsertion() async throws {
        let model = await makeModel(runner())
        let device = FakeDevice()
        device.modifiersAreDown = true
        let (search, _, shown) = makeSearch(model, device)
        search.query = ";ty"
        await search.insertSelected()
        XCTAssertEqual(device.steps, [])
        XCTAssertEqual(shown(), 1)
        XCTAssertEqual(search.message, InsertionError.modifiersHeld.message)
    }

    func testEspansoIsNotAskedWhileAModifierIsDown() async throws {
        let device = FakeDevice()
        device.modifiersStickAfterPaste = true
        let inserter = TextInserter(device: device, timing: .immediate)
        var asked = false
        do {
            try await inserter.insert(.engine(trigger: ";date")) { _ in asked = true }
            XCTFail("the insertion should have stopped")
        } catch {
            guard case .engine = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertFalse(asked)
        XCTAssertEqual(device.steps, ["save", "set(;date)", "paste(;date)", "restore"])
        XCTAssertEqual(device.clipboard, "what the user copied")
    }

    // MARK: Settings

    func testUntouchedSettingsAreNeverWritten() async throws {
        let model = await makeModel(runner())
        let before = text("config/default.yml")
        // Showing every option, and "setting" each to the value it already shows, writes nothing.
        for option in EngineOption.all {
            if option.key == "toggle_key" { continue }
            XCTAssertNil(model.writtenValue(of: option), option.key)
            XCTAssertTrue(model.setEngineOption(option, to: nil))
        }
        XCTAssertTrue(model.setStatistics(nil))
        XCTAssertEqual(text("config/default.yml"), before)

        let limit = try XCTUnwrap(EngineOption.option("backspace_limit"))
        XCTAssertEqual(model.shownValue(of: limit), .integer(5))
        XCTAssertTrue(model.setEngineOption(limit, to: .integer(3)))
        XCTAssertEqual(text("config/default.yml"), before + "backspace_limit: 3\n")
        XCTAssertEqual(model.writtenLines(in: .expansion), ["backspace_limit: 3", "toggle_key: OFF"])
        XCTAssertTrue(model.isWritten(limit))

        XCTAssertTrue(model.setEngineOption(limit, to: nil))
        XCTAssertEqual(text("config/default.yml"), before)
    }

    func testSettingsWriteEachKindOfValue() async throws {
        let model = await makeModel(runner())
        func option(_ key: String) throws -> EngineOption { try XCTUnwrap(EngineOption.option(key)) }
        XCTAssertTrue(model.setEngineOption(try option("backend"), to: .string("clipboard")))
        XCTAssertTrue(model.setEngineOption(try option("undo_backspace"), to: .bool(false)))
        XCTAssertTrue(model.setEngineOption(try option("paste_shortcut"), to: .string("CMD+V")))
        XCTAssertTrue(model.setEngineOption(try option("word_separators"), to: .list([" ", "\n"])))
        XCTAssertTrue(model.setStatistics(true))
        XCTAssertEqual(text("config/default.yml"), """
        toggle_key: OFF
        backend: clipboard
        undo_backspace: false
        paste_shortcut: "CMD+V"
        word_separators:
          - " "
          - "\\n"
        stats:
          enabled: true

        """)
        XCTAssertEqual(model.writtenValue(of: try option("word_separators")), .list([" ", "\n"]))
        XCTAssertTrue(model.statisticsAreOn)
        XCTAssertTrue(model.setStatistics(nil))
        XCTAssertNil(model.statisticsSetting)
    }

    func testPreferencesAreKeptAndClamped() {
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.typingSpeed, 40)
        XCTAssertEqual(preferences.insertionDelay, 200)
        XCTAssertEqual(preferences.renameFilePolicy, .ask)
        XCTAssertTrue(preferences.showsMenuBarIcon)
        XCTAssertNil(preferences.binaryURL)
        preferences.typingSpeed = 65
        preferences.renameFilePolicy = .always
        preferences.showsMainWindowAtLaunch = false
        preferences.binaryPath = "/opt/espanso"
        defaults.set(999_999, forKey: "quickSearchInsertionDelay")
        let again = AppPreferences(defaults: defaults)
        XCTAssertEqual(again.typingSpeed, 65)
        XCTAssertEqual(again.renameFilePolicy, .always)
        XCTAssertFalse(again.showsMainWindowAtLaunch)
        XCTAssertEqual(again.binaryURL?.path, "/opt/espanso")
        XCTAssertEqual(again.insertionDelay, 200)
    }

    func testTheLaunchWindowIsClosedOnceWhenThePreferenceSaysSo() async throws {
        let model = await makeModel(runner())
        XCTAssertFalse(model.takeLaunchWindowDismissal())
        let hidden = await makeModel(runner())
        hidden.preferences.showsMainWindowAtLaunch = false
        XCTAssertTrue(hidden.takeLaunchWindowDismissal())
        XCTAssertFalse(hidden.takeLaunchWindowDismissal())
    }

    // MARK: Statistics

    /// Writes a statistics database in Espanso's layout into the config folder.
    private func writeStats(_ rows: [(typed: String, stamp: String)], layout: Bool = true) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("stats.db").path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statements = [
            layout ? "CREATE TABLE triggers (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)" : "CREATE TABLE triggers (id INTEGER PRIMARY KEY)",
            "CREATE TABLE expansions (id INTEGER PRIMARY KEY, trigger_id INTEGER NOT NULL, timestamp TEXT NOT NULL)",
        ]
        if layout {
            for row in rows {
                let name = row.typed.replacingOccurrences(of: "'", with: "''")
                statements.append("INSERT OR IGNORE INTO triggers (name) VALUES ('\(name)')")
                statements.append("INSERT INTO expansions (trigger_id, timestamp) SELECT id, '\(row.stamp)' FROM triggers WHERE name = '\(name)'")
            }
        }
        for sql in statements { XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, sql) }
    }

    func testStatisticsAreReadFromTheDatabase() async throws {
        writeStats([
            (";ty", "2026-01-05 10:00:00"), (";ty", "2026-01-06 10:00:00"), (";dear", "2026-01-06 11:00:00"),
            ("12usd", "2026-01-07 09:00:00"), (";deleted", "2026-01-07 10:00:00"),
        ])
        let model = await makeModel(runner())
        model.statisticsPeriod = .all
        await model.refreshStatistics()
        XCTAssertEqual(model.statisticsSource, .database)
        XCTAssertNil(model.statisticsNote)
        let report = model.usageReport
        XCTAssertEqual(report.rows.map(\.trigger), [";ty", "(?P<n>\\d+)usd", ";dear", ";deleted"])
        XCTAssertEqual(report.rows.map(\.count), [2, 1, 1, 1])
        XCTAssertEqual(report.total, 5)
        XCTAssertEqual(report.expansions, 4)
        XCTAssertEqual(report.unattributed, 1)
        // "Thank you!" is 10 long against 3 typed, twice; "Dear ,\nBest" is 11 against 5.
        XCTAssertEqual(report.rows[0].charactersSaved, 14)
        XCTAssertEqual(report.rows[2].charactersSaved, 6)

        // Nothing in these rows is from today.
        model.statisticsPeriod = .today
        await model.refreshStatistics()
        XCTAssertEqual(model.usageReport.total, 0)
    }

    func testStatisticsFallBackToTheCommandWhenTheLayoutIsUnknown() async throws {
        writeStats([], layout: false)
        let runner = runner()
        runner.set("stats --json --period all --count 100000", CommandResult(
            exitCode: 0, standardOutput: #"{ "top": [ { "count": 3, "trigger": ";ty" } ], "total": 3, "unique": 1 }"#
        ))
        let model = await makeModel(runner)
        model.statisticsPeriod = .all
        await model.refreshStatistics()
        XCTAssertEqual(model.statisticsSource, .command)
        XCTAssertEqual(model.usageReport.rows.map(\.count), [3])
        XCTAssertNotNil(model.statisticsNote)
    }

    func testAMissingDatabaseGivesAnEmptyReportWithoutAskingEspanso() async throws {
        let runner = runner()
        let model = await makeModel(runner)
        await model.refreshStatistics()
        XCTAssertEqual(model.usageReport.total, 0)
        XCTAssertNotNil(model.statisticsNote)
        XCTAssertFalse(runner.commands.contains { $0.hasPrefix("stats") })
    }

    func testClearAndPruneRunEspansosCommands() async throws {
        let runner = runner()
        runner.set("stats clear", ok)
        runner.set("stats prune --days 30", ok)
        let model = await makeModel(runner)
        await model.clearStatistics()
        await model.pruneStatistics(olderThanDays: 30)
        XCTAssertEqual(runner.commands.filter { $0.hasPrefix("stats") }, ["stats clear", "stats prune --days 30"])
        XCTAssertNil(model.alertMessage)
        // A command Espanso refuses is reported.
        await model.pruneStatistics(olderThanDays: 7)
        XCTAssertNotNil(model.alertMessage)
    }

    func testQuickSearchRecentsIncludeWhatEspansoRecorded() async throws {
        writeStats([(";dear", "2026-01-06 11:00:00"), (";ty", "2026-01-07 10:00:00"), (";deleted", "2026-01-08 10:00:00")])
        let model = await makeModel(runner())
        let device = FakeDevice()
        let (search, _, _) = makeSearch(model, device)
        search.prepare()
        search.query = "."
        XCTAssertEqual(search.results.map(\.abbreviation), [";ty", ";dear"])
        // An insertion made from Quick Search just now comes first, and each item is listed once.
        search.query = ";dear"
        await search.insertSelected()
        search.query = "."
        XCTAssertEqual(search.results.map(\.abbreviation), [";dear", ";ty"])
    }

    func testRegexItemsAreOpenOnly() async throws {
        let model = await makeModel(runner())
        let device = FakeDevice()
        let (search, _, _) = makeSearch(model, device)
        search.query = "usd"
        XCTAssertEqual(search.results.count, 1)
        XCTAssertEqual(search.routeDescription, "open only")
        await search.insertSelected()
        XCTAssertEqual(device.steps, [])
        search.openSelected()
        XCTAssertEqual(model.selectedSnippet?.regex, "(?P<n>\\d+)usd")
    }

    func testInsertionsAreRememberedForTheDotSearch() async throws {
        let model = await makeModel(runner())
        let device = FakeDevice()
        let (search, _, _) = makeSearch(model, device)
        search.query = "."
        XCTAssertEqual(search.results.count, 0)
        search.query = ";dear"
        await search.insertSelected()
        search.query = ";ty"
        await search.insertSelected()
        search.query = "."
        XCTAssertEqual(search.results.map(\.abbreviation), [";ty", ";dear"])

        // The list is kept between launches.
        let later = await makeModel(runner())
        XCTAssertEqual(later.recentUses.map(\.trigger), [";ty", ";dear"])
    }

    func testSelectionMovesWithinTheResults() async throws {
        let model = await makeModel(runner())
        let (search, _, _) = makeSearch(model, FakeDevice())
        search.query = "t"
        XCTAssertGreaterThan(search.results.count, 1)
        search.moveSelection(by: -1)
        XCTAssertEqual(search.selection, 0)
        search.moveSelection(by: 100)
        XCTAssertEqual(search.selection, search.results.count - 1)
    }

    // MARK: Quick Define

    func testNewItemFromClipboardIsAppendedWithTheSetDefaults() async throws {
        let model = await makeModel(runner())
        XCTAssertNil(model.applySetInfo(SetInfo(defaultExpand: .wordBreak), name: "Work", to: "work.yml"))
        model.defineFromClipboard()
        XCTAssertEqual(model.quickDefine?.source, .clipboard)
        XCTAssertEqual(model.quickDefine?.text, "Please send the signed agreement back by Friday.")
        XCTAssertEqual(model.quickDefineSetID, "work.yml")

        let before = text("match/work.yml")
        let failure = model.saveQuickDefine(
            abbreviation: ";legal", description: "Legal reminder",
            text: model.quickDefine?.text ?? "", setID: "work.yml"
        )
        XCTAssertNil(failure)
        XCTAssertNil(model.quickDefine)
        let after = text("match/work.yml")
        // Everything that was in the file is still there, byte for byte, in front of the new item.
        XCTAssertTrue(after.hasPrefix(before.trimmingCharacters(in: .newlines)))
        XCTAssertTrue(after.contains("""
          - trigger: ";legal"
            replace: Please send the signed agreement back by Friday.
            label: Legal reminder
            word: true
        """), after)
        XCTAssertEqual(model.selectedSnippet?.triggers, [";legal"])
        XCTAssertEqual(defaults.string(forKey: "quickDefineSet"), "work.yml")
    }

    func testQuickDefineRefusesAnEmptyAbbreviation() async throws {
        let model = await makeModel(runner())
        let before = text("match/work.yml")
        XCTAssertNotNil(model.saveQuickDefine(abbreviation: "  ", description: "", text: "x", setID: "work.yml"))
        XCTAssertEqual(text("match/work.yml"), before)
    }

    func testSelectionIsReadThroughAccessibilityFirst() async throws {
        let model = await makeModel(runner())
        let device = FakeDevice()
        device.selection = "selected words"
        await model.defineFromSelection(using: device, wait: .milliseconds(50))
        XCTAssertEqual(model.quickDefine?.source, .selection)
        XCTAssertEqual(model.quickDefine?.text, "selected words")
        XCTAssertEqual(device.steps, [])
    }

    func testSelectionFallsBackToCopyAndRestoresTheClipboard() async throws {
        let model = await makeModel(runner())
        let device = FakeDevice()
        device.copyResult = "copied words"
        await model.defineFromSelection(using: device, wait: .milliseconds(50))
        XCTAssertEqual(model.quickDefine?.text, "copied words")
        XCTAssertEqual(device.clipboard, "what the user copied")
        XCTAssertTrue(device.steps.contains("copy"))

        // Nothing selected: the copy changes nothing, and the clipboard is still put back.
        model.quickDefine = nil
        device.copyResult = nil
        await model.defineFromSelection(using: device, wait: .milliseconds(50))
        XCTAssertNil(model.quickDefine)
        XCTAssertEqual(device.clipboard, "what the user copied")
        XCTAssertEqual(model.alertMessage, "No text is selected in the frontmost app.")
    }

    func testSelectionNeedsThePermission() async throws {
        let model = await makeModel(runner())
        let device = FakeDevice()
        device.isTrusted = false
        await model.defineFromSelection(using: device)
        XCTAssertTrue(device.askedForTrust)
        XCTAssertNil(model.quickDefine)
        XCTAssertEqual(device.steps, [])
    }
}
